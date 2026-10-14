import AppKit
import Foundation
import XCTest
@testable import GameHub

final class Asteroids7800SessionTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func media() throws -> Asteroids7800Presentation {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(Asteroids7800Presentation.mediaPath).path) else {
            throw XCTSkip("Prepare the selected original 7800 package first.")
        }
        return try Asteroids7800Presentation.load(root: root)
    }
    @MainActor private func session(media: Asteroids7800Presentation, mode: Asteroids7800Mode = .single, active: Int = 0) throws -> Asteroids7800Session {
        let session = Asteroids7800Session(); session.install(media: media); session.mode = mode; session.start()
        var state = try XCTUnwrap(session.simulation?.snapshot)
        state.activePlayer = active
        for p in 0..<2 {
            state.players[p].phase = mode == .single && p == 1 ? 255 : 0
            state.players[p].asteroidCount = 1; state.players[p].wave = 0; state.players[p].fireLatch = false
        }
        state.objects[0] = .init(code:0x10,x:0x0500,y:0x0500,palette:0x9f)
        state.objects[24] = .init(code:0x23,x:0x5000,y:0x5000,image:0xb5,palette:0x1e)
        if mode != .single { state.objects[32] = .init(code:0x23,x:0x7000,y:0x5000,image:0xb5,palette:0x3e) }
        session.simulation = try .init(resources:media.resources,snapshot:state)
        return session
    }
    @MainActor private func shots(_ session: Asteroids7800Session) -> Int {
        session.simulation?.objects.filter {$0.active && $0.kind == 6}.count ?? 0
    }
    func testOriginalFramesPreserveIndexesAndDoubleSourcePixelWidth() throws {
        let media = try media()
        let source = try XCTUnwrap(media.resources.frames["objects-b5-2"])
        let image = try XCTUnwrap(media.sprites["objects-b5-2"])
        XCTAssertEqual(image.width,source.width * 2); XCTAssertEqual(image.height,source.height)
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        for index in source.pixels.indices {
            let value = source.pixels[index]
            let shade = value * 85
            let expected: [UInt8] = value == 0 ? [0,0,0,0] : [shade,shade,shade,255]
            XCTAssertEqual(Array(data[index * 8..<index * 8 + 4]),expected)
            XCTAssertEqual(Array(data[index * 8 + 4..<index * 8 + 8]),expected)
        }
    }
    func testAuthoredMenuPlacementAndAllModes() throws {
        let media = try media()
        for mode in Asteroids7800Mode.allCases {
            for difficulty in 0..<4 {
                let menu = media.menu(mode:mode,difficulty:difficulty)
                XCTAssertEqual(menu.count,mode == .single ? 13 : 14)
                XCTAssertTrue(menu.allSatisfy {media.sprites[$0.name] != nil})
                XCTAssertTrue(menu.allSatisfy {(0..<320).contains($0.x) && (0..<192).contains($0.y)})
            }
        }
        XCTAssertEqual(media.menu(mode:.single,difficulty:1)[0].x,70)
        XCTAssertEqual(media.menu(mode:.single,difficulty:1)[0].y,0)
        XCTAssertEqual(Asteroids7800Presentation.scoreGlyphs(0),[0,0,0,0,0,0,0,1])
        XCTAssertEqual(Asteroids7800Presentation.scoreGlyphs(1234),[0,0,0,0,2,3,4,5])
    }
    func testProjectileUsesOriginalPointAndWrappedObjectsKeepSourceSeam() throws {
        let media = try media()
        var objects = Array(repeating:Asteroids7800Object(),count:33)
        objects[0] = .init(code:0x32,x:0x9800,y:0xb100,image:0,palette:0x9d)
        objects[28] = .init(code:6,x:0x3000,y:0x2000,palette:0x7f)
        let stamps = media.objects(objects)
        XCTAssertEqual(stamps.first?.name,"objects-fe-1")
        XCTAssertEqual(stamps.filter {$0.name == "objects-00-3"}.map(\.x),[304,-14,304,-14])
        XCTAssertEqual(stamps.filter {$0.name == "objects-00-3"}.map(\.y),[177,177,-15,-15])
        XCTAssertTrue(media.objects([]).isEmpty)
    }
    func testKeyboardAdaptersKeepBothPlayersDistinct() async {
        await MainActor.run {
            XCTAssertEqual(Asteroids7800Session.action(for:123)?.player,0)
            XCTAssertEqual(Asteroids7800Session.action(for:123)?.action,.left)
            XCTAssertEqual(Asteroids7800Session.action(for:0)?.player,1)
            XCTAssertEqual(Asteroids7800Session.action(for:0)?.action,.left)
            XCTAssertEqual(Asteroids7800Session.action(for:49)?.action,.fire)
            XCTAssertEqual(Asteroids7800Session.action(for:3)?.action,.fire)
            XCTAssertNil(Asteroids7800Session.action(for:52))
        }
    }
    func testShortKeyboardTapWaitsForThirtyPassSourceSchedule() async throws {
        let media = try media()
        try await MainActor.run {
            let session = try session(media:media)
            session.frame(now:0,focused:true,sample:.init(),identity:"none")
            _ = session.key(49,down:true); _ = session.key(49,down:false)
            session.frame(now:0.010,focused:true,sample:.init(),identity:"none")
            XCTAssertEqual(shots(session),0); XCTAssertEqual(session.driver.pendingKeys,[49])
            session.frame(now:0.020,focused:true,sample:.init(),identity:"none")
            XCTAssertEqual(shots(session),0); XCTAssertEqual(session.driver.pendingKeys,[49])
            session.frame(now:0.034,focused:true,sample:.init(),identity:"none")
            XCTAssertEqual(shots(session),1); XCTAssertTrue(session.driver.pendingKeys.isEmpty)
            XCTAssertEqual(session.simulation?.state.dliCounter,2)
            XCTAssertEqual(session.mainFraction,0.02,accuracy:1e-9)
        }
    }
    func testControllerTapSurvivesZeroDeltaUntilScheduledPass() async throws {
        let media = try media()
        try await MainActor.run {
            let session = try session(media:media), neutral = NativeGamepadSample(connected:true)
            session.frame(now:0,focused:true,sample:neutral,identity:"pad")
            session.frame(now:0,focused:true,sample:.init(connected:true,buttons:["A":true]),identity:"pad")
            session.frame(now:0.010,focused:true,sample:neutral,identity:"pad")
            XCTAssertEqual(shots(session),0)
            session.frame(now:0.034,focused:true,sample:neutral,identity:"pad")
            XCTAssertEqual(shots(session),1)
        }
    }
    func testDisconnectAndIdentityChangeClearPrivateQueuedControllerTaps() async throws {
        let media = try media()
        try await MainActor.run {
            for identityChange in [false,true] {
                let session = try session(media:media), neutral = NativeGamepadSample(connected:true)
                session.frame(now:0,focused:true,sample:neutral,identity:"first")
                session.frame(now:0,focused:true,sample:.init(connected:true,buttons:["A":true]),identity:"first")
                let sample = identityChange ? neutral : NativeGamepadSample()
                let identity = identityChange ? "second" : "first"
                session.frame(now:0.010,focused:true,sample:sample,identity:identity)
                session.frame(now:0.034,focused:true,sample:sample,identity:identity)
                XCTAssertEqual(shots(session),0)
            }
        }
    }
    func testFocusLossClearsPendingKeyboardAndControllerCommands() async throws {
        let media = try media()
        try await MainActor.run {
            let session = try session(media:media), neutral = NativeGamepadSample(connected:true)
            session.frame(now:0,focused:true,sample:neutral,identity:"pad")
            _ = session.key(49,down:true); _ = session.key(49,down:false)
            session.frame(now:0,focused:true,sample:.init(connected:true,buttons:["A":true]),identity:"pad")
            session.frame(now:0.001,focused:false,sample:neutral,identity:"pad")
            session.frame(now:2,focused:true,sample:neutral,identity:"pad")
            session.frame(now:2.034,focused:true,sample:neutral,identity:"pad")
            XCTAssertEqual(shots(session),0); XCTAssertTrue(session.driver.pendingKeys.isEmpty)
        }
    }
    func testPauseRequiresNeutralControllerBeforeHeldThrustReturns() async throws {
        let media = try media()
        try await MainActor.run {
            let session = try session(media:media), neutral = NativeGamepadSample(connected:true)
            let held = NativeGamepadSample(connected:true,buttons:["A":true],axes:[0,1,0,0])
            session.frame(now:0,focused:true,sample:neutral,identity:"pad")
            session.frame(now:0.010,focused:true,sample:held,identity:"pad")
            let beforePause = session.simulation?.snapshot
            session.togglePause()
            session.frame(now:1,focused:true,sample:held,identity:"pad")
            let pausedState = session.simulation?.snapshot
            XCTAssertEqual(pausedState,beforePause)
            session.togglePause()
            session.frame(now:2,focused:true,sample:held,identity:"pad")
            session.frame(now:2.034,focused:true,sample:held,identity:"pad")
            XCTAssertEqual(shots(session),0); XCTAssertEqual(session.simulation?.objects[24].velocityY,0)
            XCTAssertEqual(session.simulation?.state.mainPasses,(pausedState?.mainPasses ?? 0) + 1)
            session.frame(now:2.04,focused:true,sample:neutral,identity:"pad")
            session.frame(now:2.08,focused:true,sample:held,identity:"pad")
            XCTAssertGreaterThan(session.simulation?.objects[24].velocityY ?? 0,0)
        }
    }
    func testControllerFollowsAlternatingActivePlayer() async throws {
        let media = try media()
        try await MainActor.run {
            let session = try session(media:media,mode:.alternating,active:1)
            let neutral = NativeGamepadSample(connected:true)
            session.frame(now:0,focused:true,sample:neutral,identity:"pad")
            session.frame(now:0.034,focused:true,sample:.init(connected:true,axes:[0,1,0,0]),identity:"pad")
            XCTAssertEqual(session.simulation?.objects[24].velocityY,0)
            XCTAssertGreaterThan(session.simulation?.objects[32].velocityY ?? 0,0)
        }
    }
    func testSaveWrapperPreservesSourceStartupClockAndPausedRestore() async throws {
        let media = try media()
        try await MainActor.run {
            let session = try session(media:media,mode:.competition)
            session.frame(now:0,focused:true,sample:.init(),identity:"none")
            session.frame(now:0.010,focused:true,sample:.init(),identity:"none")
            let saved = try XCTUnwrap(session.snapshot)
            XCTAssertEqual(saved.mainFraction,0.3,accuracy:1e-9)
            XCTAssertEqual(saved.game.randomStartupProvenance,Asteroids7800SessionSave.startupProvenance)
            let decoded = try JSONDecoder().decode(Asteroids7800SessionSave.self,from:JSONEncoder().encode(saved))
            try decoded.validate(resources:media.resources)
            let restored = Asteroids7800Session(); restored.install(media:media); try restored.restore(decoded)
            XCTAssertTrue(restored.paused); XCTAssertFalse(restored.setup)
            XCTAssertEqual(restored.simulation?.snapshot,saved.game)
            XCTAssertEqual(restored.mainFraction,saved.mainFraction)
            restored.frame(now:100,focused:true,sample:.init(),identity:"none")
            XCTAssertEqual(restored.simulation?.snapshot,saved.game)
            var bad = decoded; bad.mainFraction = .nan
            XCTAssertThrowsError(try bad.validate(resources:media.resources))
            bad = decoded; bad.game.randomStartupProvenance = "Original boot (unsupported claim)"
            XCTAssertThrowsError(try bad.validate(resources:media.resources))
        }
    }
    func testStopReleasesMediaStateAndCancelsPendingLoad() async throws {
        let session = await MainActor.run { Asteroids7800Session() }
        await MainActor.run {
            session.load(root:URL(fileURLWithPath:"/nonexistent-7800-media")); session.stop()
            XCTAssertFalse(session.loading); XCTAssertFalse(session.driver.running)
            XCTAssertNil(session.presentation); XCTAssertNil(session.simulation)
        }
        try await Task.sleep(for:.milliseconds(50))
        await MainActor.run { XCTAssertNil(session.presentation); XCTAssertNil(session.simulation); XCTAssertFalse(session.loading) }
    }
}
