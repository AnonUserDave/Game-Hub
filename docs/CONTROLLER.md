# Native controller input

The hub supports standard macOS `GameController` extended profiles and an original user-space USB adapter for the specific wired controller connected during development: **BDA / PowerA XB1 Fusion Pro**, vendor `0x24c6`, product `0x591a`. The USB adapter runs inside the native application; it installs no kernel driver, virtual device, or background service and changes no security setting. It does not inject global keyboard or mouse events.

## Evidence on this Mac, October 13, 2026

1. USB registry inventory identified the device, while an actual `GCController` discovery probe returned zero profiles.
2. An ordinary `IOUSBHostDevice` open failed inside the restricted tool sandbox with `kIOReturnNotPermitted` (`0xe00002e2`). The same bounded descriptor probe outside that tool sandbox succeeded with options zero: no capture and no seize.
3. The device had one configuration and was initially **unconfigured**. Its advertised configuration 1 described a gamepad interface 0 with vendor class `0xff`, subclass `0x47`, protocol `0xd0`, interrupt OUT `0x02` and IN `0x81`, both 64-byte packets at interval 4. Other interfaces were left alone.
4. Selecting configuration 1 exposed the three interfaces. An ordinary open of interface 0 succeeded despite a Chrome device user-client object also appearing in the registry. No app was closed or controlled to obtain access.
5. Bounded asynchronous interrupt transfers successfully sent generic GIP power-on, LED-on, and ready messages. The controller returned an **18-byte command `0x20` input report**, with neutral buttons, triggers, and all four stick axes, along with status reports. This demonstrates native transport and input-report reception.

The user exercised A/B/X/Y, both triggers and both sticks in the integrated Controls & devices panel and reported that it was working. The native UI showed XB1 Fusion Pro · USB and an RT released event. D-pad, shoulders, menu actions, hot unplug/replug and complete gameplay mappings still need explicit checks. Neutral reception and synthetic parser tests alone do not prove physical mappings. The Xbox guide button, vibration, audio, rear-paddle independence, and other controller models are outside the implemented adapter.

## Implementation

`Sources/FusionUSB/` contains the Objective-C IOUSBHost transport and C packet decoder. It selects configuration 1 only if the exact target is unconfigured, opens interface 0 with ordinary options, initializes the gamepad, and listens asynchronously. Initialization has a timeout; disconnect clears sampled input. It never captures or seizes another owner's device. The backend exposes thread-safe state copies through `FusionUSB.h`.

`FusionController.shared.sample` exposes `connected`, button names, normalized sticks `[LX, LY, RX, RY]` with positive Y up, triggers `[LT, RT]`, and a report counter. Hub and PGA development gameplay consume that same state when a standard macOS profile is unavailable. The hub stops USB access when the app loses focus so another game can use the controller; library navigation is disabled while an internal game is running.

The adapter is specific to this app. Separately imported native applications provide their own controller support. Future built-in modules can consume the shared sample. A future standalone rewrite can integrate the C target independently, but needs its own device lifecycle and physical input tests.

## Diagnostics and validation

The hub's **Controls & devices** sheet reports the active path, live buttons and sticks, and trigger levels. For the wired fallback, it reports **XB1 Fusion Pro · USB** only after a valid input report has arrived. USB enumeration alone is never considered usable input.

In the library, the left stick or D-pad moves between games, A plays the selected game (or opens its details when nothing is ready), B dismisses an alert or closes the open sheet (except Controls & devices, where every button stays testable), or clears filters, X opens details, Y toggles a favorite, and LB/RB switch between All games, Playable builds, Favorites and In the works. The keyboard equivalents are the arrow keys, Return, Escape, Space and ⌘1–⌘4. These hub mappings are covered by unit tests; physical validation on the XB1 Fusion Pro is still required.

`Tools/probe_controller.sh` builds a bounded descriptor diagnostic for this VID/PID. By default it reads descriptors only. `--configure` selects the advertised configuration only while the device is unconfigured. `--input` sends the three initialization messages and reads reports for at most three seconds. Interrupt APIs require timeout zero; the probe enforces its own 250 ms transfer deadline with an abort. Running the tool inside a restrictive executor sandbox can yield permission denial even when the ordinary native app can access the controller.

The test suite validates malformed/truncated packet rejection, button bits, trigger normalization, signed stick limits, and release of held state on disconnect. Actual buttons, analog response, unplug/replug, app focus transitions, the hub, and gameplay still need physical validation.

## Primary references

- Apple IOUSBHost headers included with the installed macOS SDK document ordinary opens, configuration selection, interrupt endpoints, asynchronous transfers, and capture/seize semantics. The implementation uses the public framework without capture/seize options.
- [Linux xpad source](https://github.com/torvalds/linux/blob/master/drivers/input/joystick/xpad.c) documents Xbox One GIP initialization and input packet field positions. It does not establish support for this exact model on macOS.
- [xone protocol implementation](https://github.com/medusalix/xone/blob/master/bus/protocol.c) provides another primary GIP reference.

The transport code is original. Protocol message values and field positions are independently encoded interface facts; no Linux driver is installed or embedded.
