import Foundation
import XCTest
import FusionUSB
@testable import GameHub

final class ControllerInputTests: XCTestCase {
    func testGIPInputRejectsTruncationAndOtherCommands() {
        var state = FusionUSBState()
        for count in 0..<18 {
            var bytes = [UInt8](repeating: 0, count: 18)
            bytes[0] = 0x20; bytes[3] = 14
            XCTAssertFalse(bytes.withUnsafeBufferPointer { FusionUSBDecodeInput($0.baseAddress, count, &state) })
        }
        var other = [UInt8](repeating: 0, count: 18)
        other[0] = 0x03; other[3] = 14
        XCTAssertFalse(other.withUnsafeBufferPointer { FusionUSBDecodeInput($0.baseAddress, $0.count, &state) })
        other[0] = 0x20; other[3] = 30
        XCTAssertFalse(other.withUnsafeBufferPointer { FusionUSBDecodeInput($0.baseAddress, $0.count, &state) })
        XCTAssertFalse(state.connected)
        XCTAssertEqual(state.reportCount, 0)
    }

    func testGIPButtonsTriggersAndSignedAxisExtremes() {
        let bytes: [UInt8] = [0x20,0,1,14, 0x14,0x15, 0xff,3,0,2, 0,0x80,0xff,0x7f,0,0,0,0xc0]
        var state = FusionUSBState()
        XCTAssertTrue(bytes.withUnsafeBufferPointer { FusionUSBDecodeInput($0.baseAddress, $0.count, &state) })
        let sample = FusionController.sample(from: state)
        XCTAssertTrue(sample.connected)
        XCTAssertEqual(sample.reportCount, 1)
        for button in ["A", "Menu", "Up", "Left", "LB", "LT", "RT"] { XCTAssertEqual(sample.buttons[button], true, button) }
        for button in ["B", "X", "Y", "Down", "Right", "RB", "View", "L3", "R3"] { XCTAssertEqual(sample.buttons[button], false, button) }
        XCTAssertEqual(sample.axes[0], -1)
        XCTAssertEqual(sample.axes[1], 1)
        XCTAssertEqual(sample.axes[2], 0)
        XCTAssertEqual(sample.axes[3], -0.5)
        XCTAssertEqual(sample.triggers[0], 1)
        XCTAssertEqual(sample.triggers[1], Float(512) / 1023, accuracy: 0.0001)
        XCTAssertTrue(bytes.withUnsafeBufferPointer { FusionUSBDecodeInput($0.baseAddress, $0.count, &state) })
        XCTAssertEqual(state.reportCount, 2)
    }

    func testDisconnectedStateCannotLeaveButtonsHeld() {
        var state = FusionUSBState()
        state.buttons = 0xffff
        state.leftX = 32767
        let sample = FusionController.sample(from: state)
        XCTAssertFalse(sample.connected)
        XCTAssertTrue(sample.buttons.isEmpty)
        XCTAssertTrue(sample.axes.allSatisfy { $0 == 0 })
    }
}
