// Bounded diagnostic for the connected PowerA / BDA XB1 Fusion Pro only.
// No device capture/seize, firmware writes, drivers, or privilege changes.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>

static BOOL boundedTransfer(IOUSBHostPipe *pipe, NSMutableData *data, NSUInteger *count, NSError **error) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block IOReturn status = kIOReturnSuccess;
    __block NSUInteger transferred = 0;
    BOOL submitted = [pipe enqueueIORequestWithData:data completionTimeout:0 error:error completionHandler:^(IOReturn result, NSUInteger bytes) {
        status = result;
        transferred = bytes;
        dispatch_semaphore_signal(done);
    }];
    if (!submitted) return NO;
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC)) != 0) {
        [pipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
        if (error) *error = [NSError errorWithDomain:@"ProbeTimeout" code:1 userInfo:nil];
        return NO;
    }
    if (count) *count = transferred;
    if (status != kIOReturnSuccess && error) *error = [NSError errorWithDomain:@"IOUSBHostErrorDomain" code:status userInfo:nil];
    return status == kIOReturnSuccess;
}

static NSDictionary *probeInput(void) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    CFMutableDictionaryRef matching = [IOUSBHostInterface createMatchingDictionaryWithVendorID:@0x24c6 productID:@0x591a bcdDevice:nil interfaceNumber:@0 configurationValue:@1 interfaceClass:@255 interfaceSubclass:@71 interfaceProtocol:@208 speed:nil productIDArray:nil];
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    result[@"interfaceFound"] = @(service != 0);
    if (!service) return result;
    NSError *error = nil;
    IOUSBHostInterface *interface = [[IOUSBHostInterface alloc] initWithIOService:service options:0 queue:nil error:&error interestHandler:nil];
    result[@"interfaceOpenedWithoutSeize"] = @(interface != nil);
    if (interface) {
        IOUSBHostPipe *output = [interface copyPipeWithAddress:0x02 error:&error];
        IOUSBHostPipe *input = [interface copyPipeWithAddress:0x81 error:&error];
        result[@"pipesOpened"] = @(input != nil && output != nil);
        if (input && output) {
            // Independently encoded protocol facts: generic GIP power-on,
            // LED-on, and authentication-complete messages. No rumble, firmware
            // requests, audio endpoints, kernel driver, or report injection.
            const uint8_t power[] = {0x05,0x20,0x00,0x01,0x00};
            const uint8_t led[] = {0x0a,0x20,0x01,0x03,0x00,0x01,0x14};
            const uint8_t ready[] = {0x06,0x20,0x02,0x02,0x01,0x00};
            NSArray *packets = @[[NSData dataWithBytes:power length:sizeof(power)], [NSData dataWithBytes:led length:sizeof(led)], [NSData dataWithBytes:ready length:sizeof(ready)]];
            NSMutableArray *writes = [NSMutableArray array];
            for (NSData *packet in packets) {
                NSUInteger count = 0;
                BOOL ok = boundedTransfer(output, [packet mutableCopy], &count, &error);
                [writes addObject:@{@"command": @(((const uint8_t *)packet.bytes)[0]), @"success": @(ok), @"bytes": @(count)}];
                if (!ok) break;
            }
            result[@"initializationWrites"] = writes;
            NSMutableArray *reads = [NSMutableArray array];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
            for (NSUInteger n = 0; n < 32 && deadline.timeIntervalSinceNow > 0; n++) {
                NSMutableData *data = [NSMutableData dataWithLength:64];
                NSUInteger count = 0;
                NSError *readError = nil;
                BOOL ok = boundedTransfer(input, data, &count, &readError);
                if (!ok || count == 0) continue;
                const uint8_t *bytes = data.bytes;
                NSMutableDictionary *entry = [@{@"command": @(bytes[0]), @"bytes": @(count)} mutableCopy];
                if (bytes[0] == 0x20 && count >= 18) {
                    entry[@"buttonsLow"] = @(bytes[4]);
                    entry[@"buttonsHigh"] = @(bytes[5]);
                    entry[@"leftTrigger"] = @(bytes[6] | bytes[7] << 8);
                    entry[@"rightTrigger"] = @(bytes[8] | bytes[9] << 8);
                    NSMutableArray *axes = [NSMutableArray array];
                    for (NSUInteger at = 10; at < 18; at += 2) [axes addObject:@((int16_t)(bytes[at] | bytes[at + 1] << 8))];
                    entry[@"axes"] = axes;
                }
                [reads addObject:entry];
            }
            result[@"reports"] = reads;
        }
        [interface destroy];
    }
    if (error) {
        result[@"errorDescription"] = error.localizedDescription;
        result[@"errorHex"] = [NSString stringWithFormat:@"0x%08x", (uint32_t)error.code];
    }
    IOObjectRelease(service);
    return result;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL configure = argc == 2 && strcmp(argv[1], "--configure") == 0;
        NSMutableDictionary *report = [@{@"vendorID": @0x24c6, @"productID": @0x591a,
                                        @"captureOrSeize": @NO, @"configuredByProbe": @NO} mutableCopy];
        CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
        CFDictionarySetValue(matching, CFSTR("idVendor"), (__bridge CFNumberRef)@0x24c6);
        CFDictionarySetValue(matching, CFSTR("idProduct"), (__bridge CFNumberRef)@0x591a);
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
        report[@"deviceFound"] = @(service != 0);
        if (service) {
            NSError *error = nil;
            IOUSBHostDevice *device = [[IOUSBHostDevice alloc] initWithIOService:service options:0 queue:nil error:&error interestHandler:nil];
            report[@"openedWithoutSeize"] = @(device != nil);
            if (device) {
                const IOUSBDeviceDescriptor *descriptor = device.deviceDescriptor;
                if (descriptor) report[@"configurationCount"] = @(descriptor->bNumConfigurations);
                const IOUSBConfigurationDescriptor *current = device.configurationDescriptor;
                report[@"activeConfiguration"] = current ? @(current->bConfigurationValue) : @0;
                const IOUSBConfigurationDescriptor *available = [device configurationDescriptorWithIndex:0 error:&error];
                if (available) {
                    NSUInteger total = OSSwapLittleToHostInt16(available->wTotalLength);
                    report[@"descriptorBytes"] = @(total);
                    report[@"availableConfiguration"] = @(available->bConfigurationValue);
                    report[@"interfaceCount"] = @(available->bNumInterfaces);
                    if (total >= sizeof(IOUSBConfigurationDescriptor) && total <= 4096) {
                        const uint8_t *bytes = (const uint8_t *)available;
                        NSMutableArray *descriptors = [NSMutableArray array];
                        for (NSUInteger offset = 0; offset + 2 <= total;) {
                            uint8_t length = bytes[offset], type = bytes[offset + 1];
                            if (length < 2 || offset + length > total) break;
                            NSMutableDictionary *entry = [@{@"type": @(type), @"length": @(length)} mutableCopy];
                            if (type == 4 && length >= 9) {
                                entry[@"interface"] = @(bytes[offset + 2]);
                                entry[@"alternate"] = @(bytes[offset + 3]);
                                entry[@"endpointCount"] = @(bytes[offset + 4]);
                                entry[@"class"] = @(bytes[offset + 5]);
                                entry[@"subclass"] = @(bytes[offset + 6]);
                                entry[@"protocol"] = @(bytes[offset + 7]);
                            } else if (type == 5 && length >= 7) {
                                entry[@"address"] = @(bytes[offset + 2]);
                                entry[@"attributes"] = @(bytes[offset + 3]);
                                entry[@"maxPacketSize"] = @(bytes[offset + 4] | bytes[offset + 5] << 8);
                                entry[@"interval"] = @(bytes[offset + 6]);
                            }
                            [descriptors addObject:entry];
                            offset += length;
                        }
                        report[@"descriptors"] = descriptors;
                    }
                    // Explicit optional bounded operation; never overrides an
                    // existing configuration or another owner's open device.
                    if (configure && !current) {
                        BOOL ok = [device configureWithValue:available->bConfigurationValue matchInterfaces:YES error:&error];
                        report[@"configuredByProbe"] = @(ok);
                    }
                }
                [device destroy];
            }
            if (error) {
                report[@"errorDomain"] = error.domain;
                report[@"errorCode"] = @(error.code);
                report[@"errorHex"] = [NSString stringWithFormat:@"0x%08x", (uint32_t)error.code];
                report[@"errorDescription"] = error.localizedDescription;
            }
            IOObjectRelease(service);
        }
        if (argc == 2 && strcmp(argv[1], "--input") == 0) report[@"inputProbe"] = probeInput();
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        fwrite(json.bytes, 1, json.length, stdout);
        puts("");
        return 0;
    }
}
