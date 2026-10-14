import XCTest
@testable import GameHub

final class Asteroids8BitCoreTests: XCTestCase {
    private func resources() throws -> Asteroids8BitResources {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let defaultPath = root.appendingPathComponent("Library/Prepared/asteroids8bit/asteroids8bit.json").path
        let path = ProcessInfo.processInfo.environment["GAMEHUB_ASTEROIDS8BIT_PACKAGE"] ?? defaultPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Prepare owner-supplied Asteroids 8-bit media with Tools/decode_asteroids8bit.py")
        }
        return try Asteroids8BitResources.load(from: URL(fileURLWithPath: path))
    }
    private func simulation(selection: UInt8 = 0, difficulty: UInt8 = 0) throws -> (Asteroids8BitSimulation, Asteroids8BitRandomStream) {
        let configuration = Asteroids8BitConfiguration(selection: selection,
            difficulties: Array(repeating: difficulty, count: 4), reflectingEdges: false, fastAsteroids: false)
        var simulation = try Asteroids8BitSimulation(resources: resources(), configuration: configuration,
            startupFractions: Array(repeating: (0, 0), count: 35))
        // Explicit fixture samples are not claimed to reproduce POKEY randomness.
        var samples = try Asteroids8BitRandomStream(samples: Array(repeating: 0, count: 65_536))
        try simulation.start(random: &samples)
        return (simulation, samples)
    }
    private let idle = Array(repeating: Asteroids8BitInput(), count: 4)
    private func restored(_ original: Asteroids8BitSimulation, _ edit: (inout Asteroids8BitSnapshot) -> Void) throws -> Asteroids8BitSimulation {
        var snapshot = original.snapshot
        edit(&snapshot)
        return try Asteroids8BitSimulation(resources: original.resources, snapshot: snapshot)
    }

    func testResourceTableIntegrityAndActualMasks() throws {
        var r = try resources()
        XCTAssertEqual(r.asteroidMask(kind: 1).count, 4)
        XCTAssertEqual(r.asteroidMask(kind: 2).count, 7)
        XCTAssertEqual(r.asteroidMask(kind: 3).count, 12)
        XCTAssertEqual(r.shipMask(image: 18).count, 5)
        r.sine[1] ^= 1
        XCTAssertThrowsError(try r.validate())
        r = try resources()
        r.shipRows.removeLast()
        XCTAssertThrowsError(try r.validate())
    }

    func testSelectedModesAndFourOriginalLives() throws {
        for selection in Asteroids8BitConfiguration.selectionValues {
            let (s, _) = try simulation(selection: selection)
            XCTAssertEqual(s.state.phase, .playing)
            XCTAssertEqual(s.state.wave, 1)
            XCTAssertEqual(s.state.asteroidCount, 4)
            XCTAssertEqual(s.state.players.prefix(s.state.configuration.players).map(\.lives),
                           Array(repeating: UInt8(4), count: s.state.configuration.players))
            XCTAssertEqual(s.state.players.prefix(4).filter { $0.entity.active }.count,
                           s.state.configuration.mode == 0 ? 1 : s.state.configuration.players)
        }
        var config = Asteroids8BitConfiguration(selection: 1, difficulties: [0, 0, 0, 0], reflectingEdges: false, fastAsteroids: false)
        XCTAssertThrowsError(try config.validate())
        config.selection = 0; config.difficulties[3] = 4
        XCTAssertThrowsError(try config.validate())
    }

    func testAlternatingVBIShipAndProjectileSchedules() throws {
        var (s, samples) = try simulation(selection: 14)
        var input = idle
        for i in input.indices { input[i].joystickNibble = 7; input[i].fire = true }
        try s.verticalBlank(inputs: input, random: &samples)
        XCTAssertEqual(s.state.players.prefix(4).map(\.heading), [0, 6, 0, 6])
        XCTAssertEqual(s.state.shots.filter(\.active).map(\.code), [1, 3])
        XCTAssertEqual(s.state.shotTimers[0], 37)
        try s.verticalBlank(inputs: input, random: &samples)
        XCTAssertEqual(s.state.players.prefix(4).map(\.heading), [6, 6, 6, 6])
        XCTAssertEqual(s.state.shots.filter(\.active).map(\.code), [1, 3, 0, 2])
        // First ten source slots update only on odd VBI callbacks.
        XCTAssertEqual(Array(s.state.shotTimers.prefix(4)), [37, 37, 38, 38])
        let oldX = s.state.asteroids[1].motion.x
        for _ in 0..<3 { try s.verticalBlank(inputs: idle, random: &samples) }
        XCTAssertEqual(s.state.asteroids[1].motion.x, oldX &+ 16)
    }

    func testThrustRetainsSourceHighByteClampAndDrag() throws {
        var (s, samples) = try simulation()
        s = try restored(s) { snapshot in
            snapshot.players[0].heading = 64
            snapshot.players[0].entity.motion.xVelocity = 0x03ff
            snapshot.players[0].entity.motion.yVelocity = 0
        }
        var input = idle; input[0].joystickNibble = 14
        try s.verticalBlank(inputs: input, random: &samples) // owner 0 waits for even callback
        try s.verticalBlank(inputs: input, random: &samples)
        XCTAssertEqual(s.state.players[0].entity.motion.xVelocity, 0x0305)
        XCTAssertEqual(s.state.players[0].entity.motion.yVelocity, 0)
        XCTAssertTrue(s.state.soundRequests.contains(15))
    }

    func testTriggerRequiresReleaseAndSourceFourShotBudget() throws {
        var (s, samples) = try simulation()
        var input = idle; input[0].fire = true
        for _ in 0..<10 { try s.verticalBlank(inputs: input, random: &samples) }
        XCTAssertEqual(s.state.shots.filter { $0.code == 0 }.count, 1)
        XCTAssertEqual(s.state.players[0].freeShots, 3)
        for _ in 0..<3 {
            for _ in 0..<2 { try s.verticalBlank(inputs: idle, random: &samples) }
            for _ in 0..<2 { try s.verticalBlank(inputs: input, random: &samples) }
        }
        XCTAssertEqual(s.state.players[0].freeShots, 0)
        for _ in 0..<2 { try s.verticalBlank(inputs: idle, random: &samples) }
        for _ in 0..<2 { try s.verticalBlank(inputs: input, random: &samples) }
        XCTAssertEqual(s.state.shots.filter { $0.code == 0 }.count, 4)
        for _ in 0..<80 { try s.verticalBlank(inputs: idle, random: &samples) }
        XCTAssertEqual(s.state.players[0].freeShots, 4)
    }

    func testDownActionDifficultyZeroShieldAndOneRelocation() throws {
        var (shield, samples) = try simulation(difficulty: 0)
        var input = idle; input[0].joystickNibble = 13; input[0].fire = true
        for _ in 0..<20 { try shield.verticalBlank(inputs: input, random: &samples) }
        XCTAssertEqual(shield.state.players[0].entity.code, 0xe0)
        let shots = shield.state.shots.filter(\.active).count
        for _ in 0..<4 { try shield.verticalBlank(inputs: input, random: &samples) }
        XCTAssertEqual(shield.state.players[0].image, 18)
        XCTAssertEqual(shield.state.players[0].entity.code, 0xe0)
        XCTAssertEqual(shield.state.shots.filter(\.active).count, shots)
        var (hyperspace, random) = try simulation(difficulty: 1)
        for _ in 0..<20 { try hyperspace.verticalBlank(inputs: input, random: &random) }
        XCTAssertEqual(hyperspace.state.players[0].entity.code, 0xf0)
        XCTAssertEqual(hyperspace.state.players[0].entity.x, 41)
        XCTAssertEqual(hyperspace.state.players[0].entity.y, 21)
        XCTAssertEqual(hyperspace.state.players[0].respawnCounter, 100)
    }

    func testProjectileHitAwardsSourceScoreAndSplitsAtNextPass() throws {
        var (s, samples) = try simulation()
        s = try restored(s) { snapshot in
            snapshot.framesIntoPass = 3
            snapshot.asteroids[1].motion.x = 0x2000
            snapshot.asteroids[1].motion.y = 0x2000
            snapshot.shots[0] = Asteroids8BitEntity(motion: Asteroids8BitMotion(x: 0x2100, y: 0x2100, xVelocity: 0, yVelocity: 0), code: 0)
            snapshot.shotTimers[0] = 38
            snapshot.players[0].freeShots = 3
        }
        try s.verticalBlank(inputs: idle, random: &samples)
        XCTAssertEqual(s.state.asteroids[1].code, 0x13)
        XCTAssertEqual(s.state.players[0].scoreUnits, 1)
        XCTAssertEqual(s.state.players[0].freeShots, 4)
        try s.verticalBlank(inputs: idle, random: &samples)
        XCTAssertEqual(s.state.asteroids[1].code, 2)
        XCTAssertEqual(s.state.asteroids[5].code, 2)
        XCTAssertEqual(s.state.asteroidCount, 5)
        XCTAssertEqual(s.state.explosions.filter { $0.remaining > 0 }.count, 1)
        XCTAssertFalse(s.explosionPixels.isEmpty)
    }

    func testLastAsteroidLeavesFieldEmptyFor240SourceFrames() throws {
        var (s, samples) = try simulation()
        s = try restored(s) { snapshot in
            for i in 1..<30 { snapshot.asteroids[i].code = 255 }
            snapshot.asteroids[1].code = 0x11
            snapshot.asteroidCount = 1
            snapshot.objectLimit = 1
            snapshot.framesIntoPass = 4
        }
        try s.verticalBlank(inputs: idle, random: &samples)
        XCTAssertEqual(s.state.waveWait, 240)
        XCTAssertEqual(s.state.asteroidCount, 0)
        XCTAssertEqual(s.state.wave, 1)
        for _ in 0..<239 { try s.verticalBlank(inputs: idle, random: &samples) }
        XCTAssertEqual(s.state.asteroidCount, 0)
        try s.verticalBlank(inputs: idle, random: &samples)
        XCTAssertEqual(s.state.wave, 2)
        XCTAssertEqual(s.state.asteroidCount, 6)
    }

    func testCompetitiveShotDeathAndSharedLivesConsequence() throws {
        var (s, samples) = try simulation(selection: 19) // two players, shared end, opponent shots enabled
        s = try restored(s) { snapshot in
            snapshot.videoCounter = 1 // next even frame updates player 0
            snapshot.players[0].lives = 1
            snapshot.shots[0] = Asteroids8BitEntity(motion: Asteroids8BitMotion(x: 0x4000, y: 0x2300, xVelocity: 0, yVelocity: 0), code: 1)
            snapshot.shotTimers[0] = 38
            snapshot.players[1].freeShots = 3
        }
        try s.verticalBlank(inputs: idle, random: &samples)
        XCTAssertEqual(s.state.players.prefix(4).map(\.lives), [0, 0, 0, 0])
        XCTAssertEqual(s.state.phase, .gameOver)
        XCTAssertEqual(s.state.players[1].scoreUnits, 50)
        XCTAssertEqual(s.state.players[1].freeShots, 4)
    }

    func testAlternatingPlayerKeepsIndependentFieldsAndTwoWaits() throws {
        var (s, samples) = try simulation(selection: 2)
        s = try restored(s) { snapshot in
            snapshot.switchRequested = 1
            snapshot.players[0].entity.code = 0xf0
            snapshot.framesIntoPass = 4
        }
        try s.verticalBlank(inputs: idle, random: &samples)
        XCTAssertEqual(s.state.transitionFrames, 480)
        XCTAssertEqual(s.state.savedFields[0].filter(\.active).count, 4)
        XCTAssertEqual(s.state.asteroidCount, 0)
        for _ in 0..<240 { try s.verticalBlank(inputs: idle, random: &samples) }
        XCTAssertEqual(s.state.currentPlayer, 1)
        XCTAssertEqual(s.state.asteroidCount, 0)
        for _ in 0..<240 { try s.verticalBlank(inputs: idle, random: &samples) }
        XCTAssertEqual(s.state.pendingPlayer, nil)
        // Player two's initial zero DE timer reaches B0, then safe active state
        // in this callback. A death instead initializes DE to100.
        XCTAssertEqual(s.state.players[1].entity.code, 0)
        XCTAssertEqual(s.state.asteroidCount, 4)
    }

    func testUFOUsesSourceDelayAndCreatesOwnProjectile() throws {
        var (s, samples) = try simulation()
        s = try restored(s) { snapshot in
            snapshot.videoCounter = 1
            snapshot.players[4].entity.code = 0
            snapshot.players[4].entity.motion.x = 0x6000
            snapshot.players[4].entity.motion.y = 0x4000
            snapshot.ufoFireCounter = 255
        }
        try s.verticalBlank(inputs: idle, random: &samples)
        XCTAssertEqual(s.state.players[4].image, 17)
        XCTAssertEqual(s.state.shots.filter(\.active).map(\.code), [4])
        XCTAssertEqual(s.state.shotTimers[0], 25)
        XCTAssertEqual(s.state.players[4].freeShots, 3)
    }

    func testColdUFOEntersThroughPendingForegroundSafeSpawn() throws {
        var (s, samples) = try simulation()
        XCTAssertEqual(s.state.players[4].entity.code, 255)
        for _ in 0..<511 { try s.verticalBlank(inputs: idle, random: &samples) }
        XCTAssertEqual(s.state.players[4].entity.code, 255)
        try s.verticalBlank(inputs: idle, random: &samples)
        // $6D34 changes FF to B0 after256 even callbacks. B0 intentionally
        // remains inactive until $62E7 scans all five pending ships.
        XCTAssertEqual(s.state.players[4].entity.code, 0xb0)
        XCTAssertFalse(s.state.players[4].entity.active)
        for _ in 0..<3 { try s.verticalBlank(inputs: idle, random: &samples) }
        XCTAssertEqual(s.state.players[4].entity.code, 0)
        XCTAssertTrue(s.state.players[4].entity.active)
        try s.verticalBlank(inputs: idle, random: &samples)
        XCTAssertEqual(s.state.players[4].image, 17)
    }

    func testAsteroidContactDestroysBothAndStartsOriginalDeathDelay() throws {
        var (s, samples) = try simulation()
        s = try restored(s) { snapshot in
            snapshot.videoCounter = 1
            snapshot.asteroids[1].motion.x = 0x3c00
            snapshot.asteroids[1].motion.y = 0x2200
            snapshot.asteroids[1].motion.xVelocity = 0
            snapshot.asteroids[1].motion.yVelocity = 0
        }
        try s.verticalBlank(inputs: idle, random: &samples)
        XCTAssertEqual(s.state.players[0].lives, 3)
        XCTAssertEqual(s.state.players[0].entity.code, 0xf0)
        XCTAssertEqual(s.state.players[0].respawnCounter, 100)
        XCTAssertEqual(s.state.asteroids[1].code, 0x13)
    }

    func testTeamShotsIgnorePartnersAndAwardOpponents() throws {
        var (s, samples) = try simulation(selection: 31)
        s = try restored(s) { snapshot in
            snapshot.videoCounter = 1
            snapshot.shots[0] = Asteroids8BitEntity(motion: Asteroids8BitMotion(x: 0x4000, y: 0x2300, xVelocity: 0, yVelocity: 0), code: 1)
            snapshot.shotTimers[0] = 38
            snapshot.players[1].freeShots = 3
        }
        try s.verticalBlank(inputs: idle, random: &samples)
        XCTAssertEqual(s.state.players[0].lives, 4)
        XCTAssertEqual(s.state.shots[0].code, 1)
        s = try restored(s) { snapshot in
            snapshot.videoCounter = 1
            snapshot.shots[0].code = 2
            snapshot.players[2].freeShots = 3
        }
        try s.verticalBlank(inputs: idle, random: &samples)
        XCTAssertEqual(s.state.players[0].lives, 3)
        XCTAssertEqual(s.state.players[2].scoreUnits, 50)
    }

    func testIndependentSoundCallbackAdvancesOriginalParameterSequence() throws {
        var (s, samples) = try simulation()
        var input = idle; input[0].fire = true
        for _ in 0..<2 { try s.verticalBlank(inputs: input, random: &samples) }
        let before = s.state.sounds
        let channel = Int(s.resources.soundRequests[12])
        XCTAssertEqual(before[channel].pointer, s.resources.soundRequests[13])
        XCTAssertEqual(before[channel].delay, 1)
        let registers = s.advanceSoundCallback()
        let next = Int(before[channel].pointer &+ 4)
        XCTAssertEqual(registers[channel], s.resources.soundSequences[next + 1])
        XCTAssertEqual(s.state.sounds[channel].delay, s.resources.soundSequences[next])
        for _ in 0..<1024 { _ = s.advanceSoundCallback() }
        XCTAssertEqual(s.state.sounds[channel].pointer, 0)
    }

    func testResourceSineAndBulletNegativeShiftAreSourceSpecific() throws {
        var (s, samples) = try simulation()
        XCTAssertEqual(s.resources.sineByte(0), 0)
        XCTAssertEqual(s.resources.sineByte(64), 127)
        XCTAssertEqual(s.resources.sineByte(127), 3)
        s = try restored(s) { snapshot in snapshot.players[0].heading = 192; snapshot.videoCounter = 1 }
        var input = idle; input[0].fire = true
        try s.verticalBlank(inputs: input, random: &samples)
        XCTAssertEqual(s.state.shots[0].motion.xVelocity, UInt16(truncatingIfNeeded: -505))
    }

    func testSampleExhaustionIsTransactionalAndPausedVBIStillCounts() throws {
        var (s, samples) = try simulation()
        let before = s.snapshot
        var exhausted = try Asteroids8BitRandomStream(samples: [])
        XCTAssertThrowsError(try s.verticalBlank(inputs: idle, random: &exhausted))
        XCTAssertEqual(s.snapshot, before)
        XCTAssertEqual(exhausted.consumed, 0)
        s.setPaused(true)
        let paused = s.snapshot
        try s.verticalBlank(inputs: idle, random: &samples)
        XCTAssertEqual(s.state.asteroids, paused.asteroids)
        XCTAssertEqual(s.state.players, paused.players)
        XCTAssertEqual(s.state.videoCounter, paused.videoCounter &+ 1)
    }

    func testSnapshotRoundTripContinuesCompleteStateAndRejectsCorruption() throws {
        var (s, samples) = try simulation(selection: 14)
        for _ in 0..<300 { try s.verticalBlank(inputs: idle, random: &samples) }
        let encoded = try JSONEncoder().encode(s.snapshot)
        let snapshot = try JSONDecoder().decode(Asteroids8BitSnapshot.self, from: encoded)
        var restored = try Asteroids8BitSimulation(resources: s.resources, snapshot: snapshot)
        var cloned = samples
        for _ in 0..<500 {
            try s.verticalBlank(inputs: idle, random: &samples)
            try restored.verticalBlank(inputs: idle, random: &cloned)
        }
        XCTAssertEqual(s.snapshot, restored.snapshot)
        XCTAssertEqual(samples, cloned)
        var bad = snapshot; bad.players[0].scoreUnits = 1_000_000
        XCTAssertThrowsError(try Asteroids8BitSimulation(resources: s.resources, snapshot: bad))
        bad = snapshot; bad.shots[0].code = 6
        XCTAssertThrowsError(try Asteroids8BitSimulation(resources: s.resources, snapshot: bad))
        bad = snapshot; bad.asteroidCount = 29
        XCTAssertThrowsError(try Asteroids8BitSimulation(resources: s.resources, snapshot: bad))
        bad = snapshot; bad.sourceSHA256 = "wrong"
        XCTAssertThrowsError(try Asteroids8BitSimulation(resources: s.resources, snapshot: bad))
    }
}
