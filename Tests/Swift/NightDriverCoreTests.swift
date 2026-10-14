import XCTest
@testable import GameHub

final class NightDriverCoreTests: XCTestCase {
    func testOriginalForegroundAccelerationAndSpeedBands() {
        var simulation = NightDriverSimulation()
        simulation.start()
        simulation.controlStep(NightDriverInput(accelerate: true))
        XCTAssertEqual(simulation.state.speed256, 255)
        simulation.controlStep(NightDriverInput(accelerate: true))
        XCTAssertEqual(simulation.state.speed256, 510)
        simulation.controlStep(NightDriverInput(accelerate: true))
        XCTAssertEqual(simulation.state.speed256, 525)
        XCTAssertEqual(simulation.state.gear, 3)
        XCTAssertEqual([0, 1, 60, 61, 150, 151, 250].map(NightDriverSimulation.gear), [0, 3, 3, 2, 2, 1, 1])
    }

    func testTimerUsesDecimalBorrowAndEndsAtHighByteZero() {
        var simulation = NightDriverSimulation()
        simulation.start()
        for _ in 0..<100 { simulation.timerInterrupt() }
        XCTAssertEqual(simulation.state.timerTicks, 9899)
        XCTAssertEqual(simulation.state.timeDisplay, 98)
        for _ in 0..<9800 { simulation.timerInterrupt() }
        XCTAssertEqual(simulation.state.timerTicks, 99)
        simulation.timerInterrupt()
        XCTAssertEqual(simulation.state.timerTicks, 99)
        simulation.controlStep()
        XCTAssertEqual(simulation.state.phase, .ended)
    }

    func testForegroundSpeedUpdatePrecedesExpiryAndCollisionChecks() throws {
        var state = NightDriverSimulation().state
        state.phase = .driving; state.timerTicks = 99
        var expiring = try NightDriverSimulation(snapshot: NightDriverSnapshot(state: state))
        expiring.controlStep(NightDriverInput(accelerate: true))
        XCTAssertEqual(expiring.state.phase, .ended)
        XCTAssertEqual(expiring.state.speed256, 255)

        state.timerTicks = 9999
        state.roadOrigin256 = 30 * 256
        state.roadCenters = Array(repeating: 30, count: 19)
        var crashing = try NightDriverSimulation(snapshot: NightDriverSnapshot(state: state))
        crashing.controlStep(NightDriverInput(accelerate: true))
        XCTAssertEqual(crashing.state.phase, .crashed)
        XCTAssertEqual(crashing.state.speed256, 255)
        XCTAssertEqual(crashing.takeEvents(), [.crash])
    }

    func testInterruptMotionCarryAndEightProgressStepsPerDistance() throws {
        var state = NightDriverSimulation().state
        state.phase = .driving
        state.timerTicks = 9999
        state.speed256 = 128 * 256
        var simulation = try NightDriverSimulation(snapshot: NightDriverSnapshot(state: state))
        simulation.timerInterrupt()
        XCTAssertEqual(simulation.state.roadPhase, 0)
        XCTAssertEqual(simulation.state.motionFraction, 128)
        simulation.timerInterrupt()
        XCTAssertEqual(simulation.state.roadPhase, 1)
        XCTAssertEqual(simulation.state.motionFraction, 0)
        XCTAssertEqual(simulation.state.bend256, 0x8004)
        XCTAssertEqual(simulation.state.roadOrigin256, 0x13f6)
        XCTAssertEqual(simulation.state.roadCenters, Array(repeating: 19, count: 19))
        for _ in 0..<14 { simulation.timerInterrupt() }
        XCTAssertEqual(simulation.state.distance, 1)
        XCTAssertEqual(simulation.state.distanceFraction, 0)
    }

    func testSteeringPriorityAndPaddleFixedPoint() throws {
        func move(_ input: NightDriverInput) throws -> Int {
            var state = NightDriverSimulation().state
            state.phase = .driving; state.timerTicks = 9999
            state.speed256 = 250 * 256; state.motionFraction = 255
            var simulation = try NightDriverSimulation(snapshot: NightDriverSnapshot(state: state))
            simulation.timerInterrupt(input)
            return simulation.state.roadOrigin256
        }
        XCTAssertEqual(try move(NightDriverInput(left: true)), 0x13f6 + 200)
        XCTAssertEqual(try move(NightDriverInput(left: true, right: true)), 0x13f6 - 200)
        XCTAssertEqual(try move(NightDriverInput(paddle: 255)), 0x13f6 + 254)
    }

    func testExtendedPlayAt600OnceAndHighScore() throws {
        var state = NightDriverSimulation().state
        state.phase = .driving; state.timerTicks = 99; state.distance = 600
        var simulation = try NightDriverSimulation(snapshot: NightDriverSnapshot(state: state))
        simulation.controlStep()
        XCTAssertTrue(simulation.state.extendedPlay)
        XCTAssertEqual(simulation.state.timerTicks, 5099)
        XCTAssertEqual(simulation.takeEvents(), [.extendedPlay])
        for _ in 0..<5000 { simulation.timerInterrupt() }
        simulation.controlStep()
        XCTAssertEqual(simulation.state.phase, .ended)
        XCTAssertEqual(simulation.state.highScore, 600)
    }

    func testSourcePostCellsAndFourPhaseSchedule() {
        let simulation = NightDriverSimulation()
        XCTAssertTrue(simulation.roadCells.contains(NightDriverCell(column: 19, row: 0, character: 8)))
        XCTAssertTrue(simulation.roadCells.contains(NightDriverCell(column: 21, row: 0, character: 8)))
        XCTAssertTrue(simulation.roadCells.contains(NightDriverCell(column: 16, row: 4, character: 15)))
        XCTAssertEqual(NightDriverSimulation.depthSchedules[3], [0, 2, 3, 4, 7, 9, 13, 17])
    }

    func testRandomSequenceAndSnapshotDeterminism() throws {
        var seed: UInt16 = 0xffff
        let sequence = (0..<8).map { _ in NightDriverSimulation.nextRandom(&seed) }
        XCTAssertEqual(sequence, [109, 134, 194, 33, 232, 246, 22, 242])
        var simulation = NightDriverSimulation(); simulation.start()
        for _ in 0..<1000 {
            simulation.controlStep(NightDriverInput(accelerate: true))
            simulation.timerInterrupt()
            simulation.advanceCrashStage()
        }
        var restored = try NightDriverSimulation(snapshot: simulation.snapshot)
        for _ in 0..<1000 {
            simulation.controlStep(NightDriverInput(accelerate: true, left: true))
            restored.controlStep(NightDriverInput(accelerate: true, left: true))
            simulation.timerInterrupt(); restored.timerInterrupt()
            simulation.advanceCrashStage(); restored.advanceCrashStage()
        }
        XCTAssertEqual(restored.state, simulation.state)
        var bad = simulation.snapshot; bad.state.roadCenters[0] ^= 1
        XCTAssertThrowsError(try NightDriverSimulation(snapshot: bad))
    }

    func testPreparedOriginalMediaWhenPresent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Library/SourceMedia/retro/night-driver-c64/native-media.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Original media intentionally omitted from clean clones") }
        let media = try NightDriverMedia.load(from: file)
        XCTAssertEqual(media.graphics.instructions.count, 880)
        XCTAssertEqual(media.graphics.crashPhases.count, 4)
        XCTAssertEqual(media.graphics.scoreDigitRows.count, 11)
        XCTAssertEqual(media.graphics.scoreDigitRows[0], media.graphics.scoreDigitRows[10])
    }

    func testMediaRejectsMalformedHUDBeforePresentation() throws {
        let zeroRow = Array(repeating: 0, count: 8)
        let hud: [String: Any] = ["gear": Array(repeating: 0, count: 5), "speed": Array(repeating: 0, count: 5),
                                  "time": Array(repeating: 0, count: 4), "highScore": Array(repeating: 0, count: 17),
                                  "extendedPlay": Array(repeating: 0, count: 17), "timeLabel": Array(repeating: 0, count: 17),
                                  "colors": Array(repeating: 1, count: 17)]
        var graphics: [String: Any] = ["characterRows": Array(repeating: zeroRow, count: 256),
                                       "digitSprites": Array(repeating: Array(repeating: 0, count: 63), count: 10),
                                       "scoreDigitRows": Array(repeating: zeroRow, count: 11),
                                       "instructions": Array(repeating: 0, count: 880), "hud": hud,
                                       "car": Array(repeating: Array(repeating: 0, count: 18), count: 5),
                                       "crashPhases": Array(repeating: [[Int]](), count: 4)]
        var object: [String: Any] = ["schemaVersion": 1, "gameSHA256": NightDriverSimulation.sourceSHA256,
                                    "sourceProgramSHA256": "c8be3efca0b9cb49418e3e1fd3659a40b651aa864c53743a4a4a232c33394ad8",
                                    "graphics": graphics]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("night-driver-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        XCTAssertNoThrow(try NightDriverMedia.load(from: file))
        for (key, value) in [("gear", [1]), ("speed", [Int](repeating: 256, count: 5)),
                             ("colors", [Int](repeating: 16, count: 17))] {
            var invalidHUD = hud
            invalidHUD[key] = value
            graphics["hud"] = invalidHUD; object["graphics"] = graphics
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            XCTAssertThrowsError(try NightDriverMedia.load(from: file), "Accepted invalid HUD \(key)")
        }
    }
}
