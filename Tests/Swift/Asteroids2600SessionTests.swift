import AppKit
import XCTest
@testable import GameHub

final class Asteroids2600SessionTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func media() throws -> Asteroids2600Presentation {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(Asteroids2600Presentation.path).path) else {
            throw XCTSkip("Owner-supplied Asteroids 2600 original masks are not prepared")
        }
        return try .load(root: root)
    }
    @MainActor private func session(variation: UInt8 = 0) throws -> Asteroids2600Session {
        let value = Asteroids2600Session(); value.presentation = try media()
        value.selectedVariation = variation; value.start()
        return value
    }

    func testKeyboardTapWaitsForEvenSourcePassAndZeroDeltaDoesNotConsume() async throws {
        try await MainActor.run {
            let game = try session(), neutral = NativeGamepadSample()
            game.frame(now: 0, focused: true, sample: neutral, identity: "none")
            XCTAssertTrue(game.key(49, down: true)); XCTAssertTrue(game.key(49, down: false))
            game.frame(now: 0, focused: true, sample: neutral, identity: "none")
            XCTAssertEqual(game.driver.pendingKeys, [49])
            game.frame(now: 1.0 / 60, focused: true, sample: neutral, identity: "none")
            XCTAssertEqual(game.driver.pendingKeys, [49]); XCTAssertEqual(game.simulation?.state.totalFrames, 1)
            XCTAssertFalse(try XCTUnwrap(game.simulation).state.projectiles[1].active)
            game.frame(now: 2.0 / 60, focused: true, sample: neutral, identity: "none")
            XCTAssertTrue(game.driver.pendingKeys.isEmpty)
            XCTAssertTrue(try XCTUnwrap(game.simulation).state.projectiles[1].active)
        }
    }

    func testControllerTapSurvivesOddPassButDisconnectDropsIt() async throws {
        try await MainActor.run {
            let neutral = NativeGamepadSample(connected: true), fire = NativeGamepadSample(connected: true, buttons: ["X": true])
            let game = try session()
            game.frame(now: 0, focused: true, sample: neutral, identity: "first")
            game.frame(now: 1.0 / 60, focused: true, sample: fire, identity: "first")
            XCTAssertEqual(game.pendingControllerActions, [.fire])
            game.frame(now: 2.0 / 60, focused: true, sample: neutral, identity: "first")
            XCTAssertTrue(try XCTUnwrap(game.simulation).state.projectiles[1].active)

            let disconnected = try session()
            disconnected.frame(now: 0, focused: true, sample: neutral, identity: "first")
            disconnected.frame(now: 0, focused: true, sample: fire, identity: "first")
            XCTAssertEqual(disconnected.pendingControllerActions, [.fire])
            disconnected.frame(now: 0, focused: true, sample: NativeGamepadSample(), identity: "none")
            XCTAssertTrue(disconnected.pendingControllerActions.isEmpty)
            for index in 1...2 { disconnected.frame(now: Double(index) / 60, focused: true, sample: NativeGamepadSample(), identity: "none") }
            XCTAssertFalse(try XCTUnwrap(disconnected.simulation).state.projectiles[1].active, "A disconnected pad's pending press must not manufacture a shot")
        }
    }

    func testControllerIdentityChangeDropsOnlyControllerQueueAndRequiresRelease() async throws {
        try await MainActor.run {
            let game = try session(), neutral = NativeGamepadSample(connected: true)
            let fire = NativeGamepadSample(connected: true, buttons: ["X": true])
            game.frame(now: 0, focused: true, sample: neutral, identity: "first")
            game.frame(now: 0, focused: true, sample: fire, identity: "first")
            _ = game.key(13, down: true); _ = game.key(13, down: false)
            game.frame(now: 0, focused: true, sample: fire, identity: "second")
            XCTAssertTrue(game.pendingControllerActions.isEmpty)
            XCTAssertEqual(game.driver.pendingKeys, [13], "Keyboard taps are independent of controller replacement")
            for index in 1...2 { game.frame(now: Double(index) / 60, focused: true, sample: fire, identity: "second") }
            XCTAssertFalse(try XCTUnwrap(game.simulation).state.projectiles[1].active)
            XCTAssertNotEqual(game.simulation?.state.velocityVertical, 0)
            game.frame(now: 3.0 / 60, focused: true, sample: neutral, identity: "second")
            game.frame(now: 4.0 / 60, focused: true, sample: fire, identity: "second")
            XCTAssertTrue(try XCTUnwrap(game.simulation).state.projectiles[1].active)
        }
    }

    func testTwoShortFireTapsGetAnInterveningSourceRelease() async throws {
        try await MainActor.run {
            let game = try session(), neutral = NativeGamepadSample()
            game.frame(now: 0, focused: true, sample: neutral, identity: "none")
            for _ in 0..<2 { _ = game.key(49, down: true); _ = game.key(49, down: false) }
            for index in 1...2 { game.frame(now: Double(index) / 60, focused: true, sample: neutral, identity: "none") }
            XCTAssertEqual(game.driver.pendingKeys, [49])
            for index in 3...4 { game.frame(now: Double(index) / 60, focused: true, sample: neutral, identity: "none") }
            XCTAssertFalse(try XCTUnwrap(game.simulation).state.fireLatch)
            XCTAssertEqual(game.driver.pendingKeys, [49])
            for index in 5...6 { game.frame(now: Double(index) / 60, focused: true, sample: neutral, identity: "none") }
            let shots = try XCTUnwrap(game.simulation).state.projectiles
            XCTAssertTrue(shots[0].active && shots[1].active)
            XCTAssertTrue(game.driver.pendingKeys.isEmpty)
        }
    }

    func testFocusAndPauseClearTapsAndHeldControllerCannotPressOnReturn() async throws {
        try await MainActor.run {
            let game = try session(), neutral = NativeGamepadSample(connected: true)
            let held = NativeGamepadSample(connected: true, buttons: ["X": true], axes: [1, 0, 0, 0])
            game.frame(now: 0, focused: true, sample: neutral, identity: "pad")
            game.frame(now: 0, focused: true, sample: held, identity: "pad")
            _ = game.key(49, down: true); _ = game.key(49, down: false)
            game.frame(now: 5, focused: false, sample: held, identity: "pad")
            XCTAssertTrue(game.pendingControllerActions.isEmpty); XCTAssertTrue(game.driver.pendingKeys.isEmpty)
            game.frame(now: 6, focused: true, sample: held, identity: "pad")
            XCTAssertEqual(game.simulation?.state.totalFrames, 0)
            for index in 1...2 { game.frame(now: 6 + Double(index) / 60, focused: true, sample: held, identity: "pad") }
            XCTAssertFalse(try XCTUnwrap(game.simulation).state.projectiles[1].active)
            XCTAssertEqual(game.simulation?.player.heading, 0)
            game.togglePause(); _ = game.key(49, down: true); _ = game.key(49, down: false)
            let before = try XCTUnwrap(game.simulation).snapshot
            game.frame(now: 10, focused: true, sample: held, identity: "pad")
            XCTAssertEqual(game.simulation?.snapshot, before)
            game.togglePause(); game.frame(now: 10, focused: true, sample: held, identity: "pad")
            for index in 1...2 { game.frame(now: 10 + Double(index) / 60, focused: true, sample: held, identity: "pad") }
            XCTAssertFalse(try XCTUnwrap(game.simulation).state.projectiles[1].active)
            game.frame(now: 11, focused: true, sample: neutral, identity: "pad")
            game.frame(now: 11.04, focused: true, sample: held, identity: "pad")
            XCTAssertTrue(try XCTUnwrap(game.simulation).state.projectiles[1].active)

            let detached = try session()
            detached.frame(now: 0, focused: true, sample: neutral, identity: "pad")
            detached.attach(nil)
            detached.frame(now: 0, focused: true, sample: held, identity: "pad")
            for index in 1...2 { detached.frame(now: Double(index) / 60, focused: true, sample: held, identity: "pad") }
            XCTAssertFalse(try XCTUnwrap(detached.simulation).state.projectiles[1].active)
            XCTAssertTrue(detached.pendingControllerActions.isEmpty, "Reattaching a game window must prime the current held sample")
        }
    }

    func testSaveRestoresPausedSourceFractionVariationAndBothSwitches() async throws {
        try await MainActor.run {
            let game = try session(variation: 0xa0), neutral = NativeGamepadSample()
            game.playerOneSaucers = false; game.playerTwoSaucers = true
            game.frame(now: 0, focused: true, sample: neutral, identity: "none")
            game.frame(now: 0.025, focused: true, sample: neutral, identity: "none")
            let saved = try XCTUnwrap(game.snapshot)
            XCTAssertEqual(saved.frameFraction, 0.5, accuracy: 1e-9)
            let decoded = try JSONDecoder().decode(Asteroids2600SessionSave.self, from: JSONEncoder().encode(saved))
            let restored = try session(); try restored.restore(decoded)
            XCTAssertTrue(restored.paused); XCTAssertFalse(restored.setup)
            XCTAssertEqual(restored.selectedVariation, 0xa0)
            XCTAssertFalse(restored.playerOneSaucers); XCTAssertTrue(restored.playerTwoSaucers)
            XCTAssertEqual(restored.simulation?.snapshot, saved.game)
            restored.frame(now: 100, focused: true, sample: neutral, identity: "none")
            XCTAssertEqual(restored.simulation?.snapshot, saved.game)
            restored.togglePause(); restored.frame(now: 100, focused: true, sample: neutral, identity: "none")
            restored.frame(now: 100 + 1.0 / 120, focused: true, sample: neutral, identity: "none")
            XCTAssertEqual(restored.simulation?.state.totalFrames, saved.game.totalFrames + 1)
            var invalid = decoded; invalid.frameFraction = 1
            XCTAssertThrowsError(try invalid.validate(resources: try XCTUnwrap(game.presentation).resources))
            invalid = decoded; invalid.saucerSwitches = [true]
            XCTAssertThrowsError(try restored.restore(invalid))
            invalid = decoded; invalid.contentSHA256 = "changed"
            XCTAssertThrowsError(try restored.restore(invalid))
            invalid = decoded; invalid.frameFraction = 1 - 5e-10
            try restored.restore(invalid); restored.togglePause()
            restored.frame(now: 200, focused: true, sample: neutral, identity: "none")
            restored.frame(now: 200, focused: true, sample: neutral, identity: "none")
            XCTAssertEqual(restored.simulation?.snapshot, invalid.game, "A near-full saved fraction must not advance at zero elapsed time")
        }
    }

    func testOriginalMasksReflectionClippedRowsAndVariationMappings() async throws {
        let original = try media()
        try await MainActor.run {
            XCTAssertEqual(original.sprites.count, 29); XCTAssertEqual(original.reflectedShips.count, 9)
            let image = try XCTUnwrap(original.sprites["ship-1"]), reflected = try XCTUnwrap(original.reflectedShips["ship-1"])
            let pixels = try XCTUnwrap(image.dataProvider?.data) as Data
            let mirrored = try XCTUnwrap(reflected.dataProvider?.data) as Data
            for y in 0..<image.height { for x in 0..<image.width {
                XCTAssertEqual(pixels[(y * image.width + x) * 4 + 3], mirrored[(y * image.width + image.width - 1 - x) * 4 + 3])
            } }
            var snapshot = try Asteroids2600Simulation(resources: original.resources).snapshot
            snapshot.shipY = 0xfb; snapshot.players[0].livesAndHeading = 0x4f
            let game = try Asteroids2600Simulation(resources: original.resources, snapshot: snapshot)
            let ship = try XCTUnwrap(Asteroids2600Screen.placements(game: game).first { $0.name.hasPrefix("ship-") })
            XCTAssertEqual(ship.y, -5); XCTAssertEqual(ship.name, "ship-1"); XCTAssertTrue(ship.reflected)
            XCTAssertEqual(ship.x, 78)
            XCTAssertEqual(Set(Asteroids2600Session.variationValues.map(Asteroids2600Session.variationNumber)), Set(1...66))
            XCTAssertEqual([UInt16(123), 124, 126, 125, 49].compactMap(Asteroids2600Session.action), [.left, .right, .thrust, .down, .fire])
            XCTAssertEqual(Asteroids2600Screen.sourceRow(255), -1)
        }
    }

    func testCancelledLoadingCannotRepopulateStoppedSession() async throws {
        let value = await MainActor.run { () -> Asteroids2600Session in
            let value = Asteroids2600Session()
            _ = NSApplication.shared
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
                                  styleMask: [.titled], backing: .buffered, defer: true)
            value.attach(window); XCTAssertTrue(value.driver.running)
            value.load(root: root); value.stop()
            XCTAssertFalse(value.driver.running)
            return value
        }
        try await Task.sleep(for: .milliseconds(100))
        await MainActor.run {
            XCTAssertNil(value.presentation); XCTAssertNil(value.simulation)
            XCTAssertFalse(value.loading); XCTAssertFalse(value.driver.running)
        }
    }
}
