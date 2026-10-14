// Original user-space backend for the observed BDA/PowerA 24c6:591a device.
// Protocol facts are documented in docs/CONTROLLER.md. No kernel component,
// device capture/seize, firmware write, audio, rumble, or virtual input device.
#import "FusionUSB.h"
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>

bool FusionUSBDecodeInput(const uint8_t *bytes, size_t count, FusionUSBState *state) {
    if (!bytes || !state || count < 18 || bytes[0] != 0x20 || bytes[3] < 14 || bytes[3] > count - 4) return false;
    state->buttons = (uint16_t)(bytes[4] | bytes[5] << 8);
    state->leftTrigger = (uint16_t)(bytes[6] | bytes[7] << 8);
    state->rightTrigger = (uint16_t)(bytes[8] | bytes[9] << 8);
    state->leftX = (int16_t)(bytes[10] | bytes[11] << 8);
    state->leftY = (int16_t)(bytes[12] | bytes[13] << 8);
    state->rightX = (int16_t)(bytes[14] | bytes[15] << 8);
    state->rightY = (int16_t)(bytes[16] | bytes[17] << 8);
    state->connected = true;
    state->reportCount += 1;
    return true;
}

@interface FusionUSBSession : NSObject
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSThread *thread;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) IOUSBHostInterface *interface;
@property(nonatomic, strong) IOUSBHostPipe *input;
@property(nonatomic, strong) IOUSBHostPipe *output;
@property(nonatomic, copy) NSString *status;
@property(nonatomic) uint64_t generation;
@property(nonatomic) FusionUSBState state;
- (void)start;
- (void)stopWithStatus:(NSString *)status;
- (void)readNext:(uint64_t)generation;
- (void)initializePacket:(NSUInteger)index generation:(uint64_t)generation;
- (void)performUSBBlock:(dispatch_block_t)block;
- (void)stop;
@end

@implementation FusionUSBSession
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.gamehub.fusion-usb", DISPATCH_QUEUE_SERIAL);
        _lock = [NSLock new];
        _status = @"USB adapter idle";
        _thread = [[NSThread alloc] initWithTarget:self selector:@selector(runUSBThread) object:nil];
        _thread.name = @"Game Hub USB input";
        [_thread start];
    }
    return self;
}

- (void)runUSBThread {
    @autoreleasepool {
        NSRunLoop *runLoop = NSRunLoop.currentRunLoop;
        [runLoop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
        while (!NSThread.currentThread.cancelled) {
            @autoreleasepool { [runLoop runMode:NSDefaultRunLoopMode beforeDate:NSDate.distantFuture]; }
        }
    }
}
- (void)performUSBBlock:(dispatch_block_t)block { block(); }
- (void)onUSBThread:(dispatch_block_t)block {
    [self performSelector:@selector(performUSBBlock:) onThread:self.thread withObject:[block copy] waitUntilDone:NO];
}
- (void)stop { [self stopWithStatus:@"USB adapter idle"]; }

- (void)setDiagnostic:(NSString *)status {
    [self.lock lock]; _status = [status copy]; [self.lock unlock];
}

- (void)stopWithStatus:(NSString *)status {
    self.generation += 1;
    [self.input abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
    [self.output abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
    [self.interface destroy];
    self.input = nil; self.output = nil; self.interface = nil;
    [self.lock lock];
    _state = (FusionUSBState){0};
    _status = [status copy];
    [self.lock unlock];
}

- (void)start {
    if (self.interface) return;
    [self setDiagnostic:@"Looking for XB1 Fusion Pro USB input"];
    CFMutableDictionaryRef matching = [IOUSBHostDevice createMatchingDictionaryWithVendorID:@0x24c6 productID:@0x591a bcdDevice:nil deviceClass:nil deviceSubclass:nil deviceProtocol:nil speed:nil productIDArray:nil];
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service) { [self setDiagnostic:@"XB1 Fusion Pro is not connected over USB"]; return; }
    NSError *error = nil;
    IOUSBHostDevice *device = [[IOUSBHostDevice alloc] initWithIOService:service options:0 queue:nil error:&error interestHandler:nil];
    IOObjectRelease(service);
    if (!device) {
        [self setDiagnostic:[NSString stringWithFormat:@"USB access unavailable (%08x); keyboard and trackpad are ready", (uint32_t)error.code]];
        return;
    }
    BOOL configured = device.configurationDescriptor != NULL;
    if (!configured) configured = [device configureWithValue:1 matchInterfaces:YES error:&error];
    [device destroy];
    if (!configured) { [self setDiagnostic:@"Could not select the controller's USB configuration"]; return; }
    // Configuration publication can lag the SET_CONFIGURATION completion.
    io_service_t interfaceService = 0;
    for (NSUInteger n = 0; n < 10 && !interfaceService; n++) {
        CFMutableDictionaryRef interfaceMatch = [IOUSBHostInterface createMatchingDictionaryWithVendorID:@0x24c6 productID:@0x591a bcdDevice:nil interfaceNumber:@0 configurationValue:@1 interfaceClass:@255 interfaceSubclass:@71 interfaceProtocol:@208 speed:nil productIDArray:nil];
        interfaceService = IOServiceGetMatchingService(kIOMainPortDefault, interfaceMatch);
        if (!interfaceService) [NSThread sleepForTimeInterval:0.05];
    }
    if (!interfaceService) { [self setDiagnostic:@"Controller gamepad interface is unavailable"]; return; }
    self.interface = [[IOUSBHostInterface alloc] initWithIOService:interfaceService options:0 queue:nil error:&error interestHandler:nil];
    IOObjectRelease(interfaceService);
    if (!self.interface) { [self setDiagnostic:@"Controller gamepad interface is in use or access was denied"]; return; }
    self.input = [self.interface copyPipeWithAddress:0x81 error:&error];
    self.output = [self.interface copyPipeWithAddress:0x02 error:&error];
    if (!self.input || !self.output) { [self stopWithStatus:@"Controller interrupt endpoints are unavailable"]; return; }
    self.generation += 1;
    [self setDiagnostic:@"USB connected · initializing gamepad input"];
    [self initializePacket:0 generation:self.generation];
}

- (void)initializePacket:(NSUInteger)index generation:(uint64_t)generation {
    if (generation != self.generation) return;
    const uint8_t power[] = {0x05,0x20,0x00,0x01,0x00};
    const uint8_t led[] = {0x0a,0x20,0x01,0x03,0x00,0x01,0x14};
    const uint8_t ready[] = {0x06,0x20,0x02,0x02,0x01,0x00};
    if (index == 3) { [self setDiagnostic:@"USB open · waiting for an input report"]; [self readNext:generation]; return; }
    const uint8_t *bytes = index == 0 ? power : index == 1 ? led : ready;
    NSUInteger length = index == 0 ? sizeof(power) : index == 1 ? sizeof(led) : sizeof(ready);
    NSMutableData *data = [NSMutableData dataWithBytes:bytes length:length];
    __block BOOL complete = NO;
    NSError *error = nil;
    BOOL submitted = [self.output enqueueIORequestWithData:data completionTimeout:0 error:&error completionHandler:^(IOReturn result, NSUInteger transferred) {
        [self onUSBThread:^{
            complete = YES;
            if (generation != self.generation) return;
            if (result != kIOReturnSuccess || transferred != data.length) { [self stopWithStatus:@"Controller initialization failed"]; return; }
            [self initializePacket:index + 1 generation:generation];
        }];
    }];
    if (!submitted) { [self stopWithStatus:@"Controller initialization request was denied"]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), self.queue, ^{
        [self onUSBThread:^{
            if (!complete && generation == self.generation) [self stopWithStatus:@"Controller initialization timed out"];
        }];
    });
}

- (void)readNext:(uint64_t)generation {
    if (generation != self.generation || !self.input) return;
    NSMutableData *data = [NSMutableData dataWithLength:64];
    NSError *error = nil;
    BOOL submitted = [self.input enqueueIORequestWithData:data completionTimeout:0 error:&error completionHandler:^(IOReturn result, NSUInteger count) {
        [self onUSBThread:^{
            if (generation != self.generation) return;
            if (result != kIOReturnSuccess) { [self stopWithStatus:@"USB controller disconnected or input stopped"]; return; }
            [self.lock lock];
            BOOL decoded = FusionUSBDecodeInput(data.bytes, count, &self->_state);
            if (decoded) self->_status = @"XB1 Fusion Pro USB input active";
            [self.lock unlock];
            [self readNext:generation];
        }];
    }];
    if (!submitted) [self stopWithStatus:@"Controller input request failed"];
}
@end

static FusionUSBSession *session(void) {
    static FusionUSBSession *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [FusionUSBSession new]; });
    return shared;
}
void FusionUSBStart(void) { FusionUSBSession *s = session(); [s performSelector:@selector(start) onThread:s.thread withObject:nil waitUntilDone:NO]; }
void FusionUSBStop(void) { FusionUSBSession *s = session(); [s performSelector:@selector(stop) onThread:s.thread withObject:nil waitUntilDone:NO]; }
FusionUSBState FusionUSBCopyState(void) { FusionUSBSession *s = session(); [s.lock lock]; FusionUSBState state = s.state; [s.lock unlock]; return state; }
void FusionUSBCopyStatus(char *destination, size_t capacity) {
    if (!destination || capacity == 0) return;
    FusionUSBSession *s = session(); [s.lock lock]; strlcpy(destination, s.status.UTF8String, capacity); [s.lock unlock];
}
