import XCTest
@testable import GameHub

final class RetroInputTests: XCTestCase {
    func testPauseBlocksContinuousActionsUntilReleaseButAllowsMenu() {
        var latch = RetroControllerLatch()
        let released = NativeGamepadSample(connected: true, buttons: [:])
        let held = NativeGamepadSample(connected: true, buttons: ["A": true, "Menu": true])
        _ = latch.sample(released, identity: "pad", focused: true)
        let paused = latch.sample(held, identity: "pad", focused: true, actionsEnabled: false)
        XCTAssertEqual(paused.pressed, ["Menu"])
        XCTAssertEqual(paused.held, ["Menu"])
        XCTAssertFalse(latch.sample(held, identity: "pad", focused: true).held.contains("A"))
        _ = latch.sample(released, identity: "pad", focused: true)
        XCTAssertTrue(latch.sample(held, identity: "pad", focused: true).pressed.contains("A"))
    }
    func testShortKeyboardServeTapIsQueued() async {
        await MainActor.run {
            let session = BreakoutSession()
            session.start()
            XCTAssertTrue(session.key(49, down: true))
            XCTAssertTrue(session.key(49, down: false))
            XCTAssertTrue(session.pendingServe)
            XCTAssertTrue(session.keys.isEmpty)
            session.togglePause()
            XCTAssertFalse(session.pendingServe)
        }
    }
    func testFocusReturnHeldButtonsAndReconnectionRequireRelease() {
        var latch = RetroControllerLatch()
        let held = NativeGamepadSample(connected: true, buttons: ["A": true])
        let released = NativeGamepadSample(connected: true, buttons: ["A": false])
        XCTAssertTrue(latch.sample(held, identity: "pad1", focused: true).held.isEmpty)
        XCTAssertTrue(latch.sample(held, identity: "pad1", focused: true).pressed.isEmpty)
        _ = latch.sample(released, identity: "pad1", focused: true)
        XCTAssertEqual(latch.sample(held, identity: "pad1", focused: true).pressed, ["A"])
        _ = latch.sample(held, identity: "pad1", focused: false)
        XCTAssertTrue(latch.sample(held, identity: "pad1", focused: true).held.isEmpty)
        _ = latch.sample(released, identity: "pad1", focused: true)
        XCTAssertEqual(latch.sample(held, identity: "pad1", focused: true).held, ["A"])
        XCTAssertTrue(latch.sample(held, identity: "pad2", focused: true).pressed.isEmpty)
        _ = latch.sample(NativeGamepadSample(), identity: "none", focused: true)
        XCTAssertTrue(latch.sample(held, identity: "pad2", focused: true).held.isEmpty)
    }
}
