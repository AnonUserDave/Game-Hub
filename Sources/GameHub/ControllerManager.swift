import AppKit
import Combine
import Foundation
import GameController
import IOKit

enum HubNavigation {
    case up, down, left, right, play, back, details, favorite, previousSection, nextSection
}

/// Owns controller discovery and hub navigation. Native games can read the same
/// GameController profiles while disabling menu navigation for their session.
@MainActor
final class ControllerManager: ObservableObject {
    @Published private(set) var controllerName: String?
    @Published private(set) var lastInput = "Connect a controller or press a button"
    @Published private(set) var buttons: [String: Bool] = [:]
    @Published private(set) var axes: [Float] = [0, 0, 0, 0]
    @Published private(set) var triggers: [Float] = [0, 0]
    @Published private(set) var usbCandidates: [String] = []
    @Published private(set) var usbStatus = ""

    var onNavigate: ((HubNavigation) -> Void)?
    var navigationEnabled = true

    private var controller: GCController?
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var heldDirection: HubNavigation?
    private var nextRepeatTime: TimeInterval = 0
    private var previousButtons: [String: Bool] = [:]
    private var previousAxes: [Int] = [0, 0, 0, 0]
    private var primeInput = true
    private var usingUSB = false
    private var nextUSBRefresh: TimeInterval = 0

    init() {
        // A hub must not respond to input intended for a separate game window.
        GCController.shouldMonitorBackgroundEvents = false
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshControllers() }
            })
        }
        refreshControllers()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.poll()
            }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit {
        pollTimer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func refreshControllers() {
        nextUSBRefresh = 0
        refreshUSBDevices()
        let available = GCController.controllers().filter { $0.extendedGamepad != nil }
        let next = available.first(where: { $0 === controller }) ?? available.first
        guard next !== controller else { return }
        controller = next
        controllerName = next?.vendorName ?? next?.productCategory
        buttons = [:]
        axes = [0, 0, 0, 0]
        triggers = [0, 0]
        previousButtons = [:]
        previousAxes = [0, 0, 0, 0]
        heldDirection = nil
        primeInput = true
        if let next {
            next.playerIndex = .index1
            lastInput = "\(controllerName ?? "Controller") connected · press a button to test"
        } else {
            lastInput = "Controller disconnected · keyboard and trackpad are ready"
        }
        // Xbox USB compatibility depends on the exact controller model, firmware,
        // and macOS support. Never infer a working controller from a USB device
        // name: only an extended profile actually exposed by macOS counts here.
        // On Mac, a wired controller can require the system's accessory approval.
    }

    private func refreshUSBDevices() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var names: [String] = []
        var device = IOIteratorNext(iterator)
        while device != 0 {
            if let name = IORegistryEntryCreateCFProperty(device, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
               ["controller", "gamepad", "xbox", "fusion", "dualshock", "dualsense"].contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                names.append(name)
            }
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
        }
        usbCandidates = Array(Set(names)).sorted()
    }

    private func poll() {
        guard NSApp.isActive else {
            if usingUSB { FusionController.shared.stop(); usingUSB = false }
            heldDirection = nil
            primeInput = true
            return
        }
        let pad = controller?.extendedGamepad
        var raw = NativeGamepadSample()
        if pad == nil {
            let now = ProcessInfo.processInfo.systemUptime
            if !usingUSB || now >= nextUSBRefresh {
                FusionController.shared.start()
                usingUSB = true
                nextUSBRefresh = now + 2
            }
            raw = FusionController.shared.sample
            let status = FusionController.shared.status
            if usbStatus != status { usbStatus = status }
            if raw.connected && controllerName != "XB1 Fusion Pro · USB" {
                controllerName = "XB1 Fusion Pro · USB"
                primeInput = true
                previousButtons = [:]
                lastInput = "Native USB input active · press a button to test"
            } else if !raw.connected && controllerName == "XB1 Fusion Pro · USB" {
                controllerName = nil
                buttons = [:]; axes = [0, 0, 0, 0]; triggers = [0, 0]
                lastInput = "USB input disconnected · keyboard and trackpad are ready"
                primeInput = true
            }
        } else if usingUSB {
            FusionController.shared.stop()
            usingUSB = false
        }
        guard pad != nil || raw.connected else { return }

        let state: [String: Bool] = pad.map { pad in [
            "A": pad.buttonA.isPressed, "B": pad.buttonB.isPressed,
            "X": pad.buttonX.isPressed, "Y": pad.buttonY.isPressed,
            "LB": pad.leftShoulder.isPressed, "RB": pad.rightShoulder.isPressed,
            "LT": pad.leftTrigger.isPressed, "RT": pad.rightTrigger.isPressed,
            "Menu": pad.buttonMenu.isPressed,
            "View": pad.buttonOptions?.isPressed ?? false,
            "L3": pad.leftThumbstickButton?.isPressed ?? false,
            "R3": pad.rightThumbstickButton?.isPressed ?? false,
            "Up": pad.dpad.up.isPressed, "Down": pad.dpad.down.isPressed,
            "Left": pad.dpad.left.isPressed, "Right": pad.dpad.right.isPressed
        ] } ?? raw.buttons
        let rawAxes: [Float] = pad.map { pad in [
            pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value,
            pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value
        ] } ?? raw.axes
        let quantizedAxes: [Int] = rawAxes.map { value in Int((value * Float(20)).rounded()) }

        if buttons != state { buttons = state }
        if quantizedAxes != previousAxes { axes = rawAxes }
        let triggerState = pad.map { [$0.leftTrigger.value, $0.rightTrigger.value] } ?? raw.triggers
        if triggerState != triggers { triggers = triggerState }
        if !primeInput {
            let changed = state.keys.sorted().filter { state[$0] != previousButtons[$0] }
            if !changed.isEmpty {
                lastInput = changed.map { "\($0) \(state[$0] == true ? "pressed" : "released")" }
                    .joined(separator: " · ")
            } else if quantizedAxes != previousAxes {
                if quantizedAxes.allSatisfy({ abs($0) <= 2 }) {
                    lastInput = "Thumbsticks centered"
                } else {
                    lastInput = String(format: "Left stick %.2f, %.2f · Right stick %.2f, %.2f",
                                       rawAxes[0], rawAxes[1], rawAxes[2], rawAxes[3])
                }
            }
        }

        defer {
            previousButtons = state
            previousAxes = quantizedAxes
            primeInput = false
        }
        guard navigationEnabled, !primeInput else {
            heldDirection = nil
            return
        }

        if state["A"] == true && previousButtons["A"] != true {
            heldDirection = nil
            onNavigate?(.play)
            return
        }
        if (state["B"] == true && previousButtons["B"] != true)
            || (state["Menu"] == true && previousButtons["Menu"] != true) {
            heldDirection = nil
            onNavigate?(.back)
            return
        }
        for (button, command) in [("X", HubNavigation.details), ("Y", .favorite), ("LB", .previousSection), ("RB", .nextSection)]
        where state[button] == true && previousButtons[button] != true {
            heldDirection = nil
            onNavigate?(command)
            return
        }

        let dpadX: Float = pad?.dpad.xAxis.value ?? ((state["Right"] == true ? 1 : 0) - (state["Left"] == true ? 1 : 0))
        let dpadY: Float = pad?.dpad.yAxis.value ?? ((state["Up"] == true ? 1 : 0) - (state["Down"] == true ? 1 : 0))
        let direction = navigationDirection(x: rawAxes[0], y: rawAxes[1], dpadX: dpadX, dpadY: dpadY)
        let now = ProcessInfo.processInfo.systemUptime
        if !sameDirection(direction, heldDirection) {
            heldDirection = direction
            nextRepeatTime = now + 0.38
            if let direction { onNavigate?(direction) }
        } else if let direction, now >= nextRepeatTime {
            nextRepeatTime = now + 0.11
            onNavigate?(direction)
        }
    }

    private func navigationDirection(x stickX: Float, y stickY: Float, dpadX: Float, dpadY: Float) -> HubNavigation? {
        let hasDpad = abs(dpadX) > 0.5 || abs(dpadY) > 0.5
        let x = hasDpad ? dpadX : stickX
        let y = hasDpad ? dpadY : stickY
        // Hysteresis prevents drift near the navigation threshold from repeating.
        let threshold: Float = heldDirection == nil ? 0.55 : 0.35
        guard max(abs(x), abs(y)) > threshold else { return nil }
        if abs(x) > abs(y) { return x > 0 ? .right : .left }
        return y > 0 ? .up : .down
    }

    private func sameDirection(_ lhs: HubNavigation?, _ rhs: HubNavigation?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil), (.up?, .up?), (.down?, .down?), (.left?, .left?),
             (.right?, .right?), (.play?, .play?), (.back?, .back?): return true
        default: return false
        }
    }
}
