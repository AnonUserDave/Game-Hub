#ifndef GAMEHUB_FUSION_USB_H
#define GAMEHUB_FUSION_USB_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

typedef struct {
    bool connected;
    uint16_t buttons;
    uint16_t leftTrigger, rightTrigger;
    int16_t leftX, leftY, rightX, rightY;
    uint64_t reportCount;
} FusionUSBState;

void FusionUSBStart(void);
void FusionUSBStop(void);
FusionUSBState FusionUSBCopyState(void);
void FusionUSBCopyStatus(char *destination, size_t capacity);
bool FusionUSBDecodeInput(const uint8_t *bytes, size_t count, FusionUSBState *state);
#endif
