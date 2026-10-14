import Foundation
import FusionUSB

struct NativeGamepadSample {
    var connected = false
    var buttons: [String: Bool] = [:]
    /// LX, LY, RX, RY, normalized to -1...1; positive Y is up.
    var axes: [Float] = [0, 0, 0, 0]
    var triggers: [Float] = [0, 0]
    var reportCount: UInt64 = 0
}

/// Shared in-app fallback for the exact controller observed in this project.
/// macOS-supported controllers continue through GameController. External games
/// must implement their own input; this does not inject global keyboard events.
final class FusionController {
    static let shared = FusionController()
    private init() {}
    func start() { FusionUSBStart() }
    func stop() { FusionUSBStop() }
    var status: String {
        var buffer = [CChar](repeating: 0, count: 256)
        buffer.withUnsafeMutableBufferPointer { FusionUSBCopyStatus($0.baseAddress, $0.count) }
        return String(cString: buffer)
    }
    var sample: NativeGamepadSample { Self.sample(from: FusionUSBCopyState()) }

    static func sample(from state: FusionUSBState) -> NativeGamepadSample {
        guard state.connected else { return NativeGamepadSample() }
        let bits: [String: UInt16] = [
            "Menu": 1 << 2, "View": 1 << 3,
            "A": 1 << 4, "B": 1 << 5, "X": 1 << 6, "Y": 1 << 7,
            "Up": 1 << 8, "Down": 1 << 9, "Left": 1 << 10, "Right": 1 << 11,
            "LB": 1 << 12, "RB": 1 << 13, "L3": 1 << 14, "R3": 1 << 15
        ]
        var buttons = bits.mapValues { state.buttons & $0 != 0 }
        let triggers = [min(Float(state.leftTrigger) / 1023, 1), min(Float(state.rightTrigger) / 1023, 1)]
        buttons["LT"] = triggers[0] > 0.5
        buttons["RT"] = triggers[1] > 0.5
        let axes = [state.leftX, state.leftY, state.rightX, state.rightY].map { value in
            value < 0 ? Float(value) / 32768 : Float(value) / 32767
        }
        return NativeGamepadSample(connected: true, buttons: buttons, axes: axes, triggers: triggers, reportCount: state.reportCount)
    }
}
