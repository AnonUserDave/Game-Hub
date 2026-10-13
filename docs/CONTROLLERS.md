# Controller findings

## Device observed on this Mac

The user connected an Amazon-purchased third-party Xbox-style wired controller. macOS IORegistry identified:

| Field | Value |
| --- | --- |
| Product | XB1 Fusion Pro |
| Vendor | BDA |
| USB VID:PID | `24c6:591a` |
| USB class | 255 (vendor specific) |
| Native GameController count | 0 after initial discovery/run-loop probe |
| Usable controller HID profile | None observed in the initial inventory |

USB presence and accessory authorization do not demonstrate readable buttons/sticks. The foreground application and actual button input must still be tested. An unrelated Chrome USB user client was also present in IORegistry; whether it owns a needed interface is unverified.

The hub uses Apple's GameController extended-gamepad profiles, with hot-plug discovery and separate USB diagnostics. The PGA module must keep the same mapping and neutralize held inputs after losing focus, pausing, or disconnecting. Keyboard and trackpad support is required independently of controller availability.

## Follow-up

1. Test Controls & devices while the native app is foreground and press each control.
2. If no native profile appears, investigate whether safe task-local user-space USB access can support this exact device. Check the actual protocol/firmware and interface ownership; do not assume all Xbox-style devices share a working profile.
3. Do not install unsupported legacy kernel extensions or weaken startup security. A supported controller is a fallback only if the current device cannot be supported safely in the app.
4. Record button/axis ranges, dead zones, triggers, D-pad, menu, held-button behavior, reconnect, focus loss, and each game's actions before declaring support verified.

Primary platform references: [Apple controller discovery](https://developer.apple.com/documentation/gamecontroller/discovering-game-controllers), [Apple controller connection guide](https://support.apple.com/en-ie/111099), and [PowerA Fusion Pro manual](https://www.powera.com/contentassets/9d8d40779b1347c5ac91fd0312d7d936/powera-fusion-pro-wired-controller-for-xbox-one_user-manual_1625879335.pdf). Local hardware observations take precedence over product compatibility assumptions.
