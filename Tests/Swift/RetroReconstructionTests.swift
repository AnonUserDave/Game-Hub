import Foundation
import XCTest
@testable import GameHub

final class RetroReconstructionTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func syntheticNightMedia() throws -> Data {
        let hud: [String: Any] = ["gear": [Int](repeating: 0, count: 5), "speed": [Int](repeating: 0, count: 5), "time": [Int](repeating: 0, count: 4),
                                  "highScore": [Int](repeating: 0, count: 17), "extendedPlay": [Int](repeating: 0, count: 17), "timeLabel": [Int](repeating: 0, count: 17), "colors": [Int](repeating: 1, count: 17)]
        let graphics: [String: Any] = ["characterRows": [[Int]](repeating: [Int](repeating: 0, count: 8), count: 256),
                                      "digitSprites": [[Int]](repeating: [Int](repeating: 0, count: 63), count: 10),
                                      "scoreDigitRows": [[Int]](repeating: [Int](repeating: 0, count: 8), count: 11),
                                      "instructions": [Int](repeating: 32, count: 880), "hud": hud,
                                      "car": [[Int]](repeating: [Int](repeating: 0, count: 18), count: 5), "crashPhases": [[], [], [], []]]
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "sourceProgramSHA256": "c8be3efca0b9cb49418e3e1fd3659a40b651aa864c53743a4a4a232c33394ad8",
                                                          "gameSHA256": NightDriverSimulation.sourceSHA256, "graphics": graphics])
    }
    func testFocusedDriverBlocksBothSticksAfterPauseFocusLossAndReconnect() async {
        await MainActor.run {
            let driver = RetroSessionDriver()
            let neutral = NativeGamepadSample(connected: true)
            let held = NativeGamepadSample(connected: true, buttons: ["A": true], axes: [1, 0, 0, -1])
            _ = driver.frame(now: 0, focused: true, enabled: true, sample: held, identity: "first")
            XCTAssertEqual(driver.frame(now: 1, focused: true, enabled: true, sample: held, identity: "first").axes, [0, 0, 0, 0])
            _ = driver.frame(now: 2, focused: true, enabled: true, sample: neutral, identity: "first")
            XCTAssertEqual(driver.frame(now: 3, focused: true, enabled: true, sample: held, identity: "first").axes, [1, 0, 0, -1])
            _ = driver.frame(now: 4, focused: false, enabled: true, sample: held, identity: "first")
            let returned = driver.frame(now: 10, focused: true, enabled: true, sample: held, identity: "first")
            XCTAssertEqual(returned.delta, 0); XCTAssertEqual(returned.axes, [0, 0, 0, 0]); XCTAssertTrue(returned.held.isEmpty)
            _ = driver.frame(now: 11, focused: true, enabled: true, sample: neutral, identity: "first")
            _ = driver.frame(now: 12, focused: true, enabled: false, sample: held, identity: "first")
            XCTAssertEqual(driver.frame(now: 13, focused: true, enabled: true, sample: held, identity: "first").axes, [0, 0, 0, 0])
            _ = driver.frame(now: 14, focused: true, enabled: true, sample: neutral, identity: "first")
            XCTAssertEqual(driver.frame(now: 15, focused: true, enabled: true, sample: held, identity: "second").axes, [0, 0, 0, 0])
            driver.stop(); XCTAssertFalse(driver.running)
        }
    }
    func testInputQueuePreservesShortTapAndDropsInactiveCommands() async {
        await MainActor.run {
            let driver = RetroSessionDriver()
            let sample = NativeGamepadSample()
            _ = driver.frame(now: 0, focused: true, enabled: true, sample: sample, identity: "none")
            driver.key(0, down: true, queue: true); driver.key(0, down: false)
            XCTAssertTrue(driver.keys.isEmpty); XCTAssertEqual(driver.takeKey(), 0)
            driver.key(1, down: true, queue: true)
            _ = driver.frame(now: 1, focused: false, enabled: true, sample: sample, identity: "none")
            XCTAssertTrue(driver.keys.isEmpty); XCTAssertNil(driver.takeKey())
        }
    }
    func testSourceKeyboardMappingsAndIndependentSticks() async {
        await MainActor.run {
            XCTAssertEqual([UInt16(40), 38, 34, 46, 0, 1].compactMap(ApplePanicSession.input), [.right, .left, .up, .down, .dig, .fill])
            XCTAssertEqual([UInt16(34), 38, 40, 37, 14, 1, 2, 3, 49].compactMap(CrossfireSession.originalKey), ["I", "J", "K", "L", "E", "S", "D", "F", " "])
            XCTAssertEqual(CrossfireSession.direction(x: 1, y: 0), .right)
            XCTAssertEqual(CrossfireSession.direction(x: 0, y: -1), .down)
            XCTAssertNil(CrossfireSession.direction(x: 0.1, y: 0.1))
            XCTAssertEqual([-1.0, 0, 1].map(NightDriverSession.paddle), [255, 128, 0], "Rightward drag and stick input must both use the source's decreasing paddle values")
            XCTAssertEqual(NightDriverSession.paddle(for: .nan), 128)
        }
    }
    func testNightDriverSchedulesAndPauseDoNotFollowDisplayFrames() async throws {
        try await MainActor.run {
            let session = NightDriverSession(); session.simulation.start(); session.setup = false
            session.frame(now: 0, focused: true, sample: NativeGamepadSample(), identity: "none")
            XCTAssertTrue(session.key(0, down: true)); XCTAssertTrue(session.key(0, down: false))
            session.frame(now: 0, focused: true, sample: NativeGamepadSample(), identity: "none")
            XCTAssertEqual(session.driver.pendingKeys, [0], "A zero-delta display frame must not consume a short tap")
            session.frame(now: 1.0 / 60, focused: true, sample: NativeGamepadSample(), identity: "none")
            XCTAssertGreaterThan(session.simulation.state.speed256, 0)
            for frame in 2...60 { session.frame(now: Double(frame) / 60, focused: true, sample: NativeGamepadSample(), identity: "none") }
            XCTAssertEqual(session.simulation.state.controlCount, 120)
            XCTAssertEqual(session.simulation.state.interruptCount, 50)
            XCTAssertEqual(session.simulation.state.timerTicks, 9949)
            let before = session.simulation.snapshot
            session.togglePause()
            session.frame(now: 10, focused: true, sample: NativeGamepadSample(), identity: "none")
            XCTAssertEqual(session.simulation.snapshot, before)
            try session.snapshot.validate()
            let decoded = try JSONDecoder().decode(NightDriverSessionSave.self, from: JSONEncoder().encode(session.snapshot))
            try decoded.validate(); XCTAssertEqual(decoded.game, session.snapshot.game)
            var corrupted = decoded; corrupted.interruptFraction = .nan
            XCTAssertThrowsError(try corrupted.validate())
        }
    }
    func testCrossfireShortKeyboardCommandsAreConsumedInOrder() async {
        await MainActor.run {
            let session = CrossfireSession(); session.setup = false
            session.frame(now: 0, focused: true, sample: NativeGamepadSample(), identity: "none")
            _ = session.key(37, down: true); _ = session.key(37, down: false)
            _ = session.key(14, down: true); _ = session.key(14, down: false)
            session.frame(now: 0, focused: true, sample: NativeGamepadSample(), identity: "none")
            XCTAssertEqual(session.simulation.state.pendingKey, 0xCC)
            for frame in 1...8 { session.frame(now: Double(frame) / 60, focused: true, sample: NativeGamepadSample(), identity: "none") }
            XCTAssertEqual(session.simulation.state.movementKey, 0xCC)
            XCTAssertEqual(session.simulation.state.lastKey, 0xC5)
            XCTAssertEqual(session.simulation.ammunition, session.simulation.state.ammunitionCapacity, "Upward shots are blocked between vertical corridors")
            for frame in 9...40 { session.frame(now: Double(frame) / 60, focused: true, sample: NativeGamepadSample(), identity: "none") }
            XCTAssertLessThan(session.simulation.ammunition, session.simulation.state.ammunitionCapacity)
        }
    }
    func testCrossfirePauseQueuesSourceStopUntilNextIntersection() async {
        await MainActor.run {
            let session = CrossfireSession(); session.setup = false
            let neutral = NativeGamepadSample(connected: true), right = NativeGamepadSample(connected: true, axes: [1, 0, 0, 0])
            session.frame(now: 0, focused: true, sample: neutral, identity: "pad")
            for frame in 1...4 { session.frame(now: Double(frame) / 60, focused: true, sample: right, identity: "pad") }
            XCTAssertEqual(session.simulation.state.movementKey, 0xCC)
            session.togglePause(); XCTAssertEqual(session.simulation.state.pendingKey, 0xA0)
            session.frame(now: 1, focused: true, sample: neutral, identity: "pad")
            session.togglePause()
            session.frame(now: 1, focused: true, sample: neutral, identity: "pad")
            for frame in 1...50 { session.frame(now: 1 + Double(frame) / 60, focused: true, sample: neutral, identity: "pad") }
            XCTAssertEqual(session.simulation.state.movementKey, 0xA0)
            XCTAssertEqual(session.simulation.player.x, 160, "Original Space stops at the next intersection, preserving source movement rules")
        }
    }
    func testNightDriverTapWaitsForItsOwnScheduledUpdate() async {
        await MainActor.run {
            let session = NightDriverSession(); session.simulation.start(); session.setup = false
            session.frame(now: 0, focused: true, sample: NativeGamepadSample(), identity: "none")
            _ = session.key(0, down: true); _ = session.key(0, down: false)
            session.frame(now: 0.001, focused: true, sample: NativeGamepadSample(), identity: "none")
            XCTAssertEqual(session.driver.pendingKeys, [0]); XCTAssertEqual(session.simulation.state.controlCount, 0)
            session.frame(now: 0.010, focused: true, sample: NativeGamepadSample(), identity: "none")
            XCTAssertEqual(session.simulation.state.speed256, 255); XCTAssertTrue(session.driver.pendingKeys.isEmpty)
            _ = session.key(37, down: true); _ = session.key(37, down: false)
            session.frame(now: 0.018, focused: true, sample: NativeGamepadSample(), identity: "none")
            XCTAssertEqual(session.driver.pendingKeys, [37], "Steering waits for the independent source interrupt")
            session.frame(now: 0.021, focused: true, sample: NativeGamepadSample(), identity: "none")
            XCTAssertTrue(session.driver.pendingKeys.isEmpty)
        }
    }
    func testOriginalPresentationPackagesIfPrepared() throws {
        for (id, path) in [("apple-panic-native-development", RetroOriginalMedia.applePath), ("crossfire-native-development", RetroOriginalMedia.crossfirePath), ("night-driver-native-development", RetroOriginalMedia.nightPath)] where FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            XCTAssertEqual(RetroOriginalMedia.readiness(id: id, root: root), "", id)
        }
        XCTAssertFalse(RetroOriginalMedia.readiness(id: "night-driver-native-development", root: URL(fileURLWithPath: "/nonexistent-gamehub")).isEmpty)
    }
    func testNightDriverOriginalHUDAndInstructionCellsAreBounded() throws {
        let media = try JSONDecoder().decode(NightDriverMedia.self, from: syntheticNightMedia())
        let game = NightDriverSimulation(highScore: 1234)
        let cells = NightDriverScreen.cells(game: game, media: media)
        XCTAssertEqual(cells.count, 1000)
        XCTAssertEqual([0x368, 0x369, 0x36b, 0x36c].map { cells[$0].character }, [49, 50, 51, 52])
        XCTAssertEqual([0x354, 0x37c, 0x3a4, 0x3cc].map { cells[$0].color }, [7, 6, 6, 6])
        XCTAssertTrue(cells.allSatisfy { (0..<40).contains($0.column) && (0..<25).contains($0.row) && (0...255).contains($0.character) && (0..<16).contains($0.color) })
        XCTAssertEqual(NightDriverScreen.cells(game: game, media: media, instructions: true).count, 880)
    }
    func testPreparedMediaIsRecheckedBeforeNativeLaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(RetroOriginalMedia.nightPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try syntheticNightMedia().write(to: url)
        let catalog = folder.appendingPathComponent("Library/Manifests")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        let manifest = try Data(contentsOf: root.appendingPathComponent("Library/Manifests/night-driver-native-development.json"))
        try manifest.write(to: catalog.appendingPathComponent("night.json"))
        let store = await MainActor.run { GameStore(root: folder, loadSynchronously: true, observeExternalApplications: false) }
        await MainActor.run { XCTAssertNil(store.readiness(store.games[0])) }
        try FileManager.default.removeItem(at: url)
        await MainActor.run { store.launch(store.games[0]) }
        for _ in 0..<100 {
            if await MainActor.run(body: { store.launchingGameID == nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await MainActor.run {
            XCTAssertNil(store.activeGame); XCTAssertNil(store.launchingGameID)
            XCTAssertNotNil(store.readiness(store.games[0])); XCTAssertEqual(store.issue?.title, "Original media changed")
        }
    }
    func testNightDriverScreenBatchesAdjacentOriginalCellsWithoutTileBorders() throws {
        var media = try JSONDecoder().decode(NightDriverMedia.self, from: syntheticNightMedia())
        media.graphics.characterRows[7] = [Int](repeating: 255, count: 8)
        let presentation = NightDriverPresentation(media: media, coloredDigits: [:])
        let image = try presentation.screenImage(cells: [NightDriverCell(column: 0, row: 0, character: 7), NightDriverCell(column: 1, row: 0, character: 7)])
        XCTAssertEqual(image.width, 320); XCTAssertEqual(image.height, 200)
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        XCTAssertEqual(Array(data.prefix(16 * 4)), [UInt8](repeating: 255, count: 16 * 4), "Adjacent fully filled glyphs must form one continuous original bitmap")
        XCTAssertEqual(Array(data[16 * 4..<17 * 4]), [0, 0, 0, 0])
        XCTAssertThrowsError(try presentation.screenImage(cells: [NightDriverCell(column: 40, row: 0, character: 7)]))
    }
}
