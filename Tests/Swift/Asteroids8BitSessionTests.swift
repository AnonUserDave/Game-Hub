import Foundation
import XCTest
@testable import GameHub

final class Asteroids8BitSessionTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func media() throws -> Asteroids8BitPresentation {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(Asteroids8BitPresentation.path).path) else {
            throw XCTSkip("Prepare the selected original with Tools/decode_asteroids8bit.py")
        }
        return try .load(root: root)
    }
    func testFourKeyboardJoysticksRetainSourceActiveLowBits() {
        XCTAssertEqual(Asteroids8BitSession.keyAction(126)?.player, 0)
        XCTAssertEqual(Asteroids8BitSession.keyAction(3)?.player, 1)
        XCTAssertEqual(Asteroids8BitSession.keyAction(31)?.player, 2)
        XCTAssertEqual(Asteroids8BitSession.keyAction(9)?.player, 3)
        XCTAssertEqual(Asteroids8BitSession.input(bits: 1).joystickNibble, 14)
        XCTAssertEqual(Asteroids8BitSession.input(bits: 12).joystickNibble, 3)
        XCTAssertTrue(Asteroids8BitSession.input(bits: 16).fire)
        XCTAssertFalse(Asteroids8BitSession.input(bits: 15).fire)
    }
    func testShortFireTapWaitsForCorrectJoystickHalf() async throws {
        let media = try media()
        await MainActor.run {
            let session = Asteroids8BitSession(); session.presentation = media; session.start()
            let neutral = NativeGamepadSample()
            session.frame(now: 0, focused: true, sample: neutral, identity: "none")
            _ = session.key(49, down: true); _ = session.key(49, down: false)
            session.frame(now: 0, focused: true, sample: neutral, identity: "none")
            XCTAssertEqual(session.simulation?.state.frames, 0)
            session.frame(now: 1.0 / 60, focused: true, sample: neutral, identity: "none")
            XCTAssertEqual(session.simulation?.state.frames, 1)
            XCTAssertEqual(session.simulation?.state.players[0].freeShots, 4)
            session.frame(now: 2.0 / 60, focused: true, sample: neutral, identity: "none")
            XCTAssertEqual(session.simulation?.state.players[0].freeShots, 3)
            XCTAssertEqual(session.simulation?.state.shots.filter { $0.active && $0.code == 0 }.count, 1)
        }
    }
    func testPendingTapIsDiscardedAcrossFocusLoss() async throws {
        let media = try media()
        await MainActor.run {
            let session = Asteroids8BitSession(); session.presentation = media; session.start()
            let neutral = NativeGamepadSample()
            session.frame(now: 0, focused: true, sample: neutral, identity: "none")
            _ = session.key(49, down: true); _ = session.key(49, down: false)
            session.frame(now: 1.0 / 60, focused: true, sample: neutral, identity: "none")
            session.frame(now: 0.1, focused: false, sample: neutral, identity: "none")
            let before = session.simulation?.snapshot
            session.frame(now: 20, focused: true, sample: neutral, identity: "none")
            XCTAssertEqual(session.simulation?.snapshot, before, "Focus return discards host-time catchup")
            session.frame(now: 20 + 1.0 / 60, focused: true, sample: neutral, identity: "none")
            XCTAssertEqual(session.simulation?.state.players[0].freeShots, 4)
        }
    }
    func testQueuedControllerShotIsDiscardedOnDisconnect() async throws {
        let media = try media()
        await MainActor.run {
            let session = Asteroids8BitSession(); session.presentation = media; session.start()
            let neutral = NativeGamepadSample(connected: true)
            let fire = NativeGamepadSample(connected: true, buttons: ["A": true])
            session.frame(now: 0, focused: true, sample: neutral, identity: "pad")
            session.frame(now: 0, focused: true, sample: fire, identity: "pad")
            session.frame(now: 1.0 / 60, focused: true, sample: NativeGamepadSample(), identity: "none")
            session.frame(now: 2.0 / 60, focused: true, sample: NativeGamepadSample(), identity: "none")
            XCTAssertEqual(session.simulation?.state.players[0].freeShots, 4)
            session.frame(now: 3.0 / 60, focused: true, sample: fire, identity: "new-pad")
            session.frame(now: 4.0 / 60, focused: true, sample: fire, identity: "new-pad")
            XCTAssertEqual(session.simulation?.state.players[0].freeShots, 4, "Reconnect requires release before firing")
            session.frame(now: 5.0 / 60, focused: true, sample: neutral, identity: "new-pad")
            session.frame(now: 6.0 / 60, focused: true, sample: fire, identity: "new-pad")
            XCTAssertEqual(session.simulation?.state.players[0].freeShots, 3)
        }
    }
    func testFullSampleSaveIsBoundedAndRestoresPausedWithoutDiskMutation() async throws {
        let media = try media()
        try await MainActor.run {
            let session = Asteroids8BitSession(); session.presentation = media; session.start()
            let neutral = NativeGamepadSample()
            session.frame(now: 0, focused: true, sample: neutral, identity: "none")
            for frame in 1...12 { session.frame(now: Double(frame) / 60, focused: true, sample: neutral, identity: "none") }
            let save = try XCTUnwrap(session.snapshot)
            try save.validate(resources: media.resources)
            let bytes = try JSONEncoder().encode(save)
            XCTAssertLessThanOrEqual(bytes.count, 256 * 1024, "Every saved sample/cursor must fit the native save bound")
            let restored = Asteroids8BitSession(); restored.presentation = media
            try restored.restore(JSONDecoder().decode(Asteroids8BitSessionSave.self, from: bytes))
            XCTAssertTrue(restored.paused)
            XCTAssertEqual(restored.simulation?.snapshot, save.game)
            XCTAssertTrue(restored.random == save.random, "Saved sample sequence and cursor must restore exactly")
            restored.frame(now: 40, focused: true, sample: neutral, identity: "none")
            XCTAssertEqual(restored.simulation?.snapshot, save.game)
            restored.togglePause()
            restored.frame(now: 40, focused: true, sample: neutral, identity: "none")
            for frame in 1...8 {
                restored.frame(now: 40 + Double(frame) / 60, focused: true, sample: neutral, identity: "none")
                session.frame(now: 0.2 + Double(frame) / 60, focused: true, sample: neutral, identity: "none")
            }
            XCTAssertEqual(restored.simulation?.state.frames, session.simulation?.state.frames)
            XCTAssertEqual(restored.random?.consumed, session.random?.consumed)
            XCTAssertTrue(restored.simulation?.snapshot == session.simulation?.snapshot, "Resumed complete source state must match uninterrupted play")
            XCTAssertTrue(restored.random == session.random, "Resumed complete sample sequence/cursor must match uninterrupted play")
        }
    }
    func testSaveRejectsChangedSamplesCursorClockAndSourcePause() async throws {
        let media = try media()
        try await MainActor.run {
            let session = Asteroids8BitSession(); session.presentation = media; session.start()
            let original = try XCTUnwrap(session.snapshot)
            var invalid = original; invalid.random.samples[0] ^= 1
            XCTAssertThrowsError(try invalid.validate(resources: media.resources))
            invalid = original; invalid.game.randomReads &+= 1
            XCTAssertThrowsError(try invalid.validate(resources: media.resources))
            invalid = original; invalid.game.paused = true
            XCTAssertThrowsError(try invalid.validate(resources: media.resources))
            invalid = original; invalid.fraction = .infinity
            XCTAssertThrowsError(try invalid.validate(resources: media.resources))
        }
    }
    func testNearFullSavedFractionDoesNotAdvanceAtZeroElapsedTime() async throws {
        let media = try media()
        try await MainActor.run {
            let session = Asteroids8BitSession(); session.presentation = media; session.start()
            var save = try XCTUnwrap(session.snapshot); save.fraction = 1 - 5e-10
            try session.restore(save); session.togglePause()
            session.frame(now: 100, focused: true, sample: NativeGamepadSample(), identity: "none")
            session.frame(now: 100, focused: true, sample: NativeGamepadSample(), identity: "none")
            XCTAssertEqual(session.simulation?.state.frames, save.game.frames)
            XCTAssertEqual(session.random?.consumed, save.random.consumed)
        }
    }
    func testRestoredShieldAndFireLatchReleaseBeforeFreshTap() async throws {
        let media = try media()
        try await MainActor.run {
            let session = Asteroids8BitSession(); session.presentation = media; session.start()
            var save = try XCTUnwrap(session.snapshot)
            save.game.players[0].triggerLatch = true; save.game.players[0].entity.code = 0xe0; save.game.players[0].downCounter = 1
            try session.restore(save); session.togglePause()
            let neutral = NativeGamepadSample()
            session.frame(now: 0, focused: true, sample: neutral, identity: "none")
            _ = session.key(49, down: true); _ = session.key(49, down: false)
            for frame in 1...2 { session.frame(now: Double(frame) / 60, focused: true, sample: neutral, identity: "none") }
            XCTAssertEqual(session.simulation?.state.players[0].entity.code, 0)
            XCTAssertEqual(session.simulation?.state.players[0].downCounter, 0)
            XCTAssertEqual(session.simulation?.state.players[0].freeShots, 4)
            for frame in 3...4 { session.frame(now: Double(frame) / 60, focused: true, sample: neutral, identity: "none") }
            XCTAssertFalse(session.simulation!.state.players[0].triggerLatch)
            for frame in 5...6 { session.frame(now: Double(frame) / 60, focused: true, sample: neutral, identity: "none") }
            XCTAssertEqual(session.simulation?.state.players[0].freeShots, 3)
        }
    }
    func testControllerOnlyEpochDoesNotRetriggerHeldKeyboardFire() async throws {
        let media = try media()
        await MainActor.run {
            let session = Asteroids8BitSession(); session.presentation = media; session.start()
            session.frame(now: 0, focused: true, sample: NativeGamepadSample(), identity: "none")
            _ = session.key(49, down: true)
            for frame in 1...2 { session.frame(now: Double(frame) / 60, focused: true, sample: NativeGamepadSample(), identity: "none") }
            XCTAssertEqual(session.simulation?.state.players[0].freeShots, 3)
            let pad = NativeGamepadSample(connected: true)
            for frame in 3...6 { session.frame(now: Double(frame) / 60, focused: true, sample: pad, identity: frame < 5 ? "first" : "second") }
            XCTAssertEqual(session.simulation?.state.players[0].freeShots, 3)
        }
    }
    func testTwoShortKeyboardShotsHaveAnActualNeutralSourceHalf() async throws {
        let media = try media()
        await MainActor.run {
            let session = Asteroids8BitSession(); session.presentation = media; session.start()
            let neutral = NativeGamepadSample()
            session.frame(now: 0, focused: true, sample: neutral, identity: "none")
            _ = session.key(49, down: true); _ = session.key(49, down: false)
            for frame in 1...4 { session.frame(now: Double(frame) / 60, focused: true, sample: neutral, identity: "none") }
            XCTAssertEqual(session.simulation?.state.players[0].freeShots, 3)
            XCTAssertFalse(session.simulation!.state.players[0].triggerLatch)
            _ = session.key(49, down: true); _ = session.key(49, down: false)
            for frame in 5...6 { session.frame(now: Double(frame) / 60, focused: true, sample: neutral, identity: "none") }
            XCTAssertEqual(session.simulation?.state.players[0].freeShots, 2)
        }
    }
    func testSourceRasterHasFixedSmallBounds() throws {
        let media = try media()
        var game = try Asteroids8BitSimulation(resources: media.resources,
                                              configuration: .init(selection: 0, difficulties: [0, 0, 0, 0], reflectingEdges: false, fastAsteroids: false),
                                              startupFractions: Array(repeating: (0, 0), count: 35))
        var random = try Asteroids8BitRandomStream(samples: Asteroids8BitSession.developmentSamples)
        try game.start(random: &random)
        let image = try media.image(game: game)
        XCTAssertEqual(image.width, 160); XCTAssertEqual(image.height, 96)
        XCTAssertEqual(image.bytesPerRow * image.height, 61_440)
    }
}
