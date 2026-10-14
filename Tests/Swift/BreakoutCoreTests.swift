import XCTest
@testable import GameHub

final class BreakoutCoreTests: XCTestCase {
    private func scenario(variation: BreakoutVariation = .breakout, players: Int = 1,
                          x: Int = 12, y: Int = 84, vx: Int = 0, vy: Int = -512,
                          edit: (inout BreakoutState) -> Void = { _ in }) throws -> BreakoutSimulation {
        let simulation = BreakoutSimulation(configuration: BreakoutConfiguration(variation: variation, playerCount: players))
        var snapshot = simulation.snapshot
        snapshot.state.phase = .playing
        snapshot.state.transitionFrames = 0
        snapshot.state.transitionRebuildsWall = false
        snapshot.state.steeringLefts = [123, 123]
        snapshot.state.ball = BreakoutBall(x256: (x + 49) * 256, y256: y * 256, velocityX256: vx, velocityY256: vy)
        edit(&snapshot.state)
        snapshot.state.contacts = BreakoutSimulation.contacts(ball: snapshot.state.ball, paddles: snapshot.state.paddles, bricks: snapshot.state.bricks)
        return try BreakoutSimulation(snapshot: snapshot)
    }

    func testROMVariationFlagsAndWallValues() {
        XCTAssertEqual(BreakoutVariation.allCases.map(\.flags), [0, 16, 8, 64, 128, 144, 136, 192, 32, 48, 40, 96])
        XCTAssertEqual(BreakoutVariation.allCases.count * 4, 48)
        XCTAssertEqual(BreakoutGeometry.rowPoints.reduce(0, +) * BreakoutGeometry.columns, 432)
        XCTAssertEqual(BreakoutSimulation().state.bricks.count, 108)
        XCTAssertEqual(BreakoutSimulation().state.ballsRemaining, 5)
    }

    func testROMPackedVelocityTable() {
        let expected = [(384, 256), (256, 384), (384, 512), (128, 512), (512, 256),
                        (512, 256), (512, 512), (512, 512), (512, 864), (512, 864)]
        for index in expected.indices {
            let speed = BreakoutSimulation.velocityMagnitudes(counter: (index / 2) * 4, angle: index % 2 == 0 ? 0 : 2)
            XCTAssertEqual(speed.x, expected[index].0, "speed row \(index)")
            XCTAssertEqual(speed.y, expected[index].1, "speed row \(index)")
        }
    }

    func testServeUsesFramePhaseAndROMStartState() throws {
        var simulation = BreakoutSimulation()
        for _ in 0..<3 { simulation.tick() }
        simulation.tick(input: BreakoutInput(serve: true))
        let ball = try XCTUnwrap(simulation.state.ball)
        XCTAssertEqual(ball.x256, 65 * 256)
        XCTAssertEqual(ball.y256, 113 * 256)
        XCTAssertEqual(ball.velocityX256, 256)
        XCTAssertEqual(ball.velocityY256, 256)
        XCTAssertEqual(simulation.state.phase, .playing)
        XCTAssertEqual(simulation.events, [.served])
    }

    func testBrickValueTopRowsBoostAndCollisionLatch() throws {
        var bottom = try scenario()
        bottom.tick()
        XCTAssertEqual(bottom.state.score, 1)
        XCTAssertFalse(bottom.state.bricks[5 * 18])
        XCTAssertTrue(bottom.state.brickCollisionLatched)
        XCTAssertGreaterThan(try XCTUnwrap(bottom.state.ball).velocityY256, 0)
        XCTAssertEqual(bottom.events, [.brickHit(row: 5, column: 0, points: 1)])
        var top = try scenario(y: 48, vy: 512)
        top.tick()
        XCTAssertEqual(top.state.score, 7)
        XCTAssertEqual(top.state.speedCounter, 16)
        XCTAssertEqual(try XCTUnwrap(top.state.ball).velocityY256, -864)
    }

    func testBreakthroughDoesNotReflectOrLatch() throws {
        var simulation = try scenario(variation: .breakthrough)
        simulation.tick()
        XCTAssertEqual(simulation.state.score, 1)
        XCTAssertLessThan(try XCTUnwrap(simulation.state.ball).velocityY256, 0)
        XCTAssertFalse(simulation.state.brickCollisionLatched)
        let before = simulation.state.score
        simulation.tick()
        XCTAssertEqual(simulation.state.score, before, "A removed brick cannot score twice.")
    }

    func testCatchFollowsPaddleAndReleaseContinuesFlight() throws {
        var simulation = try scenario(variation: .catchBall, x: 81, y: 178, vx: 256, vy: 256)
        simulation.tick(input: BreakoutInput(serve: true))
        XCTAssertEqual(simulation.state.phase, .caught)
        XCTAssertEqual(try XCTUnwrap(simulation.state.ball).x, 78)
        XCTAssertEqual(try XCTUnwrap(simulation.state.ball).y, 178)
        simulation.tick(input: BreakoutInput(paddlePositions: [1], serve: true))
        XCTAssertEqual(try XCTUnwrap(simulation.state.ball).x, 146)
        simulation.tick(input: BreakoutInput(paddlePositions: [1], serve: false))
        XCTAssertEqual(simulation.state.phase, .playing)
        XCTAssertLessThan(try XCTUnwrap(simulation.state.ball).y, 178)
        XCTAssertNil(simulation.state.caughtPlayer)
    }

    func testSteeringOnlyOnAscentAndTwoPixelCorrection() throws {
        var still = try scenario(variation: .steerable, x: 80, y: 140, vx: 256, vy: -256)
        var moved = still
        still.tick(input: BreakoutInput(paddlePositions: [0.5]))
        moved.tick(input: BreakoutInput(paddlePositions: [1]))
        XCTAssertEqual(try XCTUnwrap(moved.state.ball).x - XCTUnwrap(still.state.ball).x, 2)
        var downStill = try scenario(variation: .steerable, x: 80, y: 140, vx: 256, vy: 256)
        var downMoved = downStill
        downStill.tick(input: BreakoutInput(paddlePositions: [0.5]))
        downMoved.tick(input: BreakoutInput(paddlePositions: [1]))
        XCTAssertEqual(downStill.state.ball, downMoved.state.ball)
    }

    func testCeilingShrinksBothDifficultyPaddlesAndClearsLatches() throws {
        var easy = try scenario(x: 80, y: 24, vx: 256, vy: -256) {
            $0.paddleCollisionLatched = true; $0.brickCollisionLatched = true
        }
        XCTAssertEqual(easy.state.paddleWidth, 16)
        easy.tick()
        XCTAssertEqual(easy.state.paddleWidth, 12)
        XCTAssertFalse(easy.state.paddleCollisionLatched)
        XCTAssertFalse(easy.state.brickCollisionLatched)
        var hard = try scenario(x: 80, y: 24, vx: 256, vy: -256) { $0.configuration.teamDifficulties[0] = .advanced }
        XCTAssertEqual(hard.state.paddleWidth, 12)
        hard.tick()
        XCTAssertEqual(hard.state.paddleWidth, 8)
    }

    func testScoredRebuildIsDeferredFromPaddleAnd864KeepsBall() throws {
        var simulation = try scenario { state in
            state.teams[0].score = 431
            state.teams[0].bricks = Array(repeating: false, count: 108)
            state.teams[0].bricks[90] = true
        }
        simulation.tick()
        XCTAssertEqual(simulation.state.score, 432)
        XCTAssertEqual(simulation.state.teams[0].wallsCleared, 1)
        XCTAssertTrue(simulation.state.teams[0].awaitingSecondWall)
        var next = simulation.snapshot
        next.state.ball = BreakoutBall(x256: 130 * 256, y256: 178 * 256, velocityX256: 256, velocityY256: 256)
        next.state.contacts = BreakoutContacts(paddlePlayers: [0])
        simulation = try BreakoutSimulation(snapshot: next)
        simulation.tick()
        XCTAssertEqual(simulation.state.bricks.filter { $0 }.count, 0)
        XCTAssertEqual(simulation.state.transitionFrames, 1)
        XCTAssertFalse(simulation.events.contains(.wallRebuilt))
        simulation.tick()
        XCTAssertEqual(simulation.state.bricks.filter { $0 }.count, 108)
        XCTAssertTrue(simulation.events.contains(.wallRebuilt))
        next = simulation.snapshot
        next.state.ball = BreakoutBall(x256: 61 * 256, y256: 84 * 256, velocityX256: 0, velocityY256: -512)
        next.state.contacts = BreakoutContacts(playfield: true)
        next.state.brickCollisionLatched = false
        next.state.teams[0].score = 863
        next.state.teams[0].bricks = Array(repeating: false, count: 108)
        next.state.teams[0].bricks[90] = true
        simulation = try BreakoutSimulation(snapshot: next)
        simulation.tick()
        XCTAssertEqual(simulation.state.score, 864)
        XCTAssertEqual(simulation.state.phase, .playing)
        XCTAssertNotNil(simulation.state.ball)
        XCTAssertFalse(simulation.events.contains(.ended))
        XCTAssertFalse(simulation.state.teams[0].isFinished)
    }

    func testTimedDepletedWallNeitherScoresNorRebuildsOnPaddle() throws {
        var simulation = try scenario(variation: .timed) { state in
            state.teams[0].bricks = Array(repeating: false, count: 108)
            state.teams[0].bricks[90] = true
            state.teams[0].timerTicks = 37
        }
        simulation.tick()
        XCTAssertEqual(simulation.state.score, 0)
        XCTAssertEqual(simulation.state.teams[0].timerTicks, 37)
        XCTAssertFalse(simulation.state.teams[0].awaitingSecondWall)
        var next = simulation.snapshot
        next.state.ball = BreakoutBall(x256: 130 * 256, y256: 178 * 256, velocityX256: 256, velocityY256: 256)
        next.state.contacts = BreakoutContacts(paddlePlayers: [0])
        simulation = try BreakoutSimulation(snapshot: next)
        simulation.tick()
        simulation.tick()
        XCTAssertEqual(simulation.state.bricks.filter { $0 }.count, 0)
        XCTAssertEqual(simulation.state.transitionFrames, 0)
        XCTAssertEqual(simulation.state.phase, .playing)
    }

    func testFiveBallsAndIndependentAlternatingTeams() throws {
        var simulation = BreakoutSimulation(configuration: BreakoutConfiguration(playerCount: 2))
        for lost in 0..<10 {
            var snapshot = simulation.snapshot
            snapshot.state.phase = .playing
            snapshot.state.ball = BreakoutBall(x256: 130 * 256, y256: 208 * 256, velocityX256: 0, velocityY256: 256)
            simulation = try BreakoutSimulation(snapshot: snapshot)
            let active = simulation.state.activeTeam
            let rounds = simulation.state.roundsRemaining
            simulation.tick()
            XCTAssertEqual(simulation.state.teams[active].ballsUsed, lost / 2 + 1)
            XCTAssertEqual(simulation.state.roundsRemaining, rounds - (active == 1 ? 1 : 0))
            XCTAssertNil(simulation.state.ball)
            XCTAssertEqual(simulation.state.phase, lost == 9 ? .ended : .serve)
        }
        XCTAssertEqual(simulation.state.teams.map(\.ballsUsed), [5, 5])
    }

    func testThreeAndFourPlayerSplitPaddleLimits() throws {
        var three = try scenario(players: 3) { $0.activeTeam = 1 }
        for _ in 0..<4 { three.tick(input: BreakoutInput(paddlePositions: [0, 1, 0])) }
        XCTAssertEqual(three.state.paddles.map(\.player), [1, 2])
        XCTAssertEqual(three.state.paddles.map(\.x), [77, 79])
        var four = try scenario(players: 4)
        for _ in 0..<4 { four.tick(input: BreakoutInput(paddlePositions: [0, 1])) }
        XCTAssertEqual(four.state.paddles.map(\.player), [0, 1])
        XCTAssertEqual(four.state.paddles.map(\.x), [6, 142])
    }

    func testTimerAndInvisibleFlash() throws {
        var timed = BreakoutSimulation(configuration: BreakoutConfiguration(variation: .timed))
        for _ in 0..<63 { timed.tick() }
        XCTAssertEqual(timed.state.teams[0].timerTicks, 0)
        timed.tick()
        XCTAssertEqual(timed.state.teams[0].timerTicks, 1)
        var invisible = try scenario(variation: .invisible)
        XCTAssertFalse(invisible.state.wallVisible)
        invisible.tick()
        XCTAssertFalse(invisible.state.wallVisible, "Color selection precedes the current frame's brick hit.")
        invisible.tick()
        XCTAssertTrue(invisible.state.wallVisible)
        for _ in 0..<5 { invisible.tick() }
        XCTAssertFalse(invisible.state.wallVisible)
    }

    func testCollisionIsConsumedAfterTheDisplayingFrameAndBeforeMotion() throws {
        var simulation = try scenario(y: 88, vy: -768)
        simulation.tick() // Y85 rounds to raster86: outside the final brick row.
        XCTAssertEqual(simulation.state.score, 0)
        XCTAssertFalse(simulation.state.contacts.playfield)
        simulation.tick() // Y82 is displayed inside row5; response is deferred.
        XCTAssertEqual(simulation.state.score, 0)
        XCTAssertTrue(simulation.state.contacts.playfield)
        simulation.tick()
        XCTAssertEqual(simulation.state.score, 1)
        XCTAssertEqual(simulation.events, [.brickHit(row: 5, column: 0, points: 1)])
    }

    func testRasterRoundingAndAuthoredOriginSelectionCanIgnoreAVisibleBrick() throws {
        let ball = BreakoutBall(x256: 65 * 256 + 255, y256: 55 * 256 + 255, velocityX256: 256, velocityY256: 256)
        XCTAssertEqual(ball.rasterX, 16)
        XCTAssertEqual(ball.rasterY, 56)
        // Pixels are in row1/column1; source arithmetic selects row0/column0.
        var simulation = try scenario(x: 16, y: 55, vx: 256, vy: 256) { state in
            state.teams[0].bricks = Array(repeating: false, count: 108)
            state.teams[0].bricks[19] = true
        }
        XCTAssertTrue(simulation.state.contacts.playfield)
        simulation.tick()
        XCTAssertEqual(simulation.state.score, 0)
        XCTAssertTrue(simulation.state.bricks[19])
        XCTAssertFalse(simulation.events.contains { if case .brickHit = $0 { return true }; return false })
        var authored = try scenario(x: 16, y: 55, vx: 256, vy: 256)
        authored.tick()
        XCTAssertFalse(authored.state.bricks[0])
        XCTAssertTrue(authored.state.bricks[19])
        XCTAssertEqual(authored.state.score, 7)
    }

    func testPaddleCollisionUsesDisplayedKnobBeforeNewInputAndDoesNotClamp() throws {
        var simulation = try scenario(x: 81, y: 178, vx: 256, vy: 256)
        simulation.tick(input: BreakoutInput(paddlePositions: [1]))
        XCTAssertTrue(simulation.events.contains(.paddleHit))
        XCTAssertEqual(simulation.state.paddleLefts[0], 191)
        XCTAssertEqual(try XCTUnwrap(simulation.state.ball).y256, 176 * 256 + 128)
        var ceiling = try scenario(x: 6, y: 24, vx: -256, vy: -256)
        ceiling.tick()
        XCTAssertEqual(try XCTUnwrap(ceiling.state.ball).x, 7)
        XCTAssertEqual(try XCTUnwrap(ceiling.state.ball).y, 25)
        XCTAssertTrue(ceiling.events.contains(.ceilingHit))
        XCTAssertTrue(ceiling.events.contains(.sideHit))
    }

    func testSideStripsStopAtTheDisplayBottomAndDrainUsesPriorIntegerY() throws {
        var simulation = try scenario(x: 6, y: 187, vx: -256, vy: 256)
        XCTAssertFalse(simulation.state.contacts.side)
        simulation.tick()
        XCTAssertEqual(try XCTUnwrap(simulation.state.ball).x, 5)
        var drain = try scenario(x: 80, y: 207, vy: 256)
        drain.tick()
        XCTAssertEqual(drain.state.phase, .playing)
        XCTAssertEqual(try XCTUnwrap(drain.state.ball).y, 208)
        drain.tick()
        XCTAssertEqual(drain.state.phase, .serve)
        XCTAssertEqual(drain.state.ballsRemaining, 4)
    }

    func testCapturePreservesFractionalPositionBytes() throws {
        var simulation = try scenario(variation: .catchBall, x: 81, y: 178, vx: 256, vy: 256)
        var snapshot = simulation.snapshot
        snapshot.state.ball!.x256 += 100
        snapshot.state.ball!.y256 += 173
        simulation = try BreakoutSimulation(snapshot: snapshot)
        simulation.tick(input: BreakoutInput(serve: true))
        XCTAssertEqual(try XCTUnwrap(simulation.state.ball).x256, 127 * 256 + 100)
        XCTAssertEqual(try XCTUnwrap(simulation.state.ball).y256, 178 * 256 + 173)
        simulation.tick(input: BreakoutInput(serve: false))
        XCTAssertEqual(try XCTUnwrap(simulation.state.ball).y256, 178 * 256 + 173 - 384)
    }

    func testSourceAudioRegistersAndInvisibleColorsHaveSeparateFramePhases() throws {
        var simulation = try scenario(variation: .invisible)
        simulation.tick()
        XCTAssertEqual(simulation.state.audioCounter, 6)
        XCTAssertEqual(simulation.state.audioRegisters.volume, 0)
        for frame in 1...6 {
            simulation.tick()
            XCTAssertEqual(simulation.state.audioRegisters, BreakoutAudioRegisters(frequency: 28, volume: 15))
            XCTAssertEqual(simulation.state.wallVisible, frame < 6)
        }
        simulation.tick()
        XCTAssertEqual(simulation.state.audioRegisters.volume, 0)
        var serve = BreakoutSimulation()
        serve.tick(input: BreakoutInput(serve: true))
        for _ in 0..<8 {
            serve.tick()
            XCTAssertEqual(serve.state.audioRegisters, BreakoutAudioRegisters(frequency: 4, volume: 15))
        }
        serve.tick()
        XCTAssertEqual(serve.state.audioRegisters.volume, 0)
    }

    func testSharedRoundExhaustionAndTerminalTeamComparison() throws {
        var simulation = try scenario(players: 2, y: 208, vy: 256) { state in
            state.activeTeam = 1
            state.roundsRemaining = 1
            state.teams[0].ballsUsed = 5
            state.teams[1].ballsUsed = 4
        }
        simulation.tick()
        XCTAssertEqual(simulation.state.phase, .ended)
        XCTAssertEqual(simulation.state.activeTeam, 0)
        for _ in 0..<255 { simulation.tick() }
        XCTAssertEqual(simulation.state.activeTeam, 0)
        simulation.tick()
        XCTAssertEqual(simulation.state.activeTeam, 1)
        XCTAssertEqual(simulation.state.transitionFrames, 36)
        XCTAssertTrue(simulation.events.contains(.teamChanged))
        XCTAssertEqual(simulation.state.teams.map(\.ballsUsed), [5, 5])
    }

    func testSplitKnobsUseTheTwoFrameSamplePhaseAndStateCarriesColorCodes() throws {
        var simulation = try scenario(players: 4)
        simulation.tick(input: BreakoutInput(paddlePositions: [0, 1]))
        XCTAssertEqual(simulation.state.paddleLefts.prefix(2), [55, 123])
        simulation.tick(input: BreakoutInput(paddlePositions: [1, 1]))
        XCTAssertEqual(simulation.state.paddleLefts.prefix(2), [55, 191])
        XCTAssertEqual(simulation.state.rowColorCodes, [0x46, 0x36, 0x26, 0x16, 0xc6, 0x86])
        var state = simulation.state
        state.activeTeam = 1
        XCTAssertEqual(state.paddleColorCodes, [0xd6, 0x26])
        state.configuration.monochrome = true
        XCTAssertEqual(state.paddleColorCodes, [12, 10])
        XCTAssertEqual(state.rowColorCodes, [4, 6, 8, 4, 6, 8])
    }

    func testSteeringRetainsAscentHistoryThroughDescentAndRestore() throws {
        var descending = try scenario(variation: .steerable, x: 80, y: 140, vx: 256, vy: 256)
        descending.tick(input: BreakoutInput(paddlePositions: [1]))
        XCTAssertEqual(descending.state.steeringLefts, [123, 123])
        var next = descending.snapshot
        next.state.ball!.velocityY256 = -256
        var rising = try BreakoutSimulation(snapshot: next)
        let x = try XCTUnwrap(rising.state.ball).x256
        rising.tick(input: BreakoutInput(paddlePositions: [1]))
        XCTAssertEqual(try XCTUnwrap(rising.state.ball).x256, x + 256 + 512)
        XCTAssertEqual(rising.state.steeringLefts[0], 191)
        let moved = try XCTUnwrap(rising.state.ball).x256
        rising.tick(input: BreakoutInput(paddlePositions: [1]))
        XCTAssertEqual(try XCTUnwrap(rising.state.ball).x256, moved + 256)
    }

    func testNewServeRetainsFractionalCoordinatesAcrossTeamLoss() throws {
        var simulation = try scenario(players: 2, y: 208, vy: 256)
        var snapshot = simulation.snapshot
        snapshot.state.ball!.x256 += 100
        snapshot.state.ball!.y256 += 173
        simulation = try BreakoutSimulation(snapshot: snapshot)
        simulation.tick(input: BreakoutInput(serve: true))
        XCTAssertEqual(simulation.state.activeTeam, 1)
        XCTAssertEqual(simulation.state.phase, .serve, "Drain branches around fire input for this frame.")
        simulation.tick(input: BreakoutInput(serve: true))
        XCTAssertEqual(try XCTUnwrap(simulation.state.ball).x256 & 255, 100)
        XCTAssertEqual(try XCTUnwrap(simulation.state.ball).y256, 113 * 256 + 173)
    }

    func testFrameCounterOverflowReturnsToSelectionBeforeTimerOrServe() throws {
        var simulation = BreakoutSimulation(configuration: BreakoutConfiguration(variation: .timed))
        var snapshot = simulation.snapshot
        snapshot.state.frame = 65534
        snapshot.state.teams[0].timerTicks = 999
        simulation = try BreakoutSimulation(snapshot: snapshot)
        simulation.tick()
        XCTAssertEqual(simulation.state.phase, .serve)
        simulation.tick(input: BreakoutInput(serve: true))
        XCTAssertEqual(simulation.state.phase, .selection)
        XCTAssertEqual(simulation.state.frame, 0)
        XCTAssertEqual(simulation.state.teams[0].timerTicks, 999)
        XCTAssertEqual(simulation.state.roundsRemaining, 5)
        XCTAssertEqual(simulation.events, [.selectionReturned])
        XCTAssertNil(simulation.state.ball)
        simulation.tick(input: BreakoutInput(serve: true))
        XCTAssertEqual(simulation.state.phase, .selection)
        var scoreboard = snapshot
        scoreboard.state.frame = 65535
        scoreboard.state.phase = .ended
        scoreboard.state.roundsRemaining = 0
        simulation = try BreakoutSimulation(snapshot: scoreboard)
        simulation.tick()
        XCTAssertEqual(simulation.state.phase, .selection)
        _ = try BreakoutSimulation(snapshot: simulation.snapshot)
    }

    func testPreparedHUDReadIsBoundedAndRejectsMalformedSourceData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("media.json")
        var media = BreakoutMedia(schemaVersion: 1, sourceSHA256: BreakoutSimulation.sourceSHA256,
                                 digitRows: Array(repeating: Array(repeating: 7, count: 5), count: 10))
        try JSONEncoder().encode(media).write(to: path)
        XCTAssertEqual(try BreakoutMedia.load(from: path).digitRows.count, 10)
        media.digitRows[0][0] = 8
        try JSONEncoder().encode(media).write(to: path)
        XCTAssertThrowsError(try BreakoutMedia.load(from: path))
        media.digitRows[0][0] = 7
        media.sourceSHA256 = "another cartridge"
        try JSONEncoder().encode(media).write(to: path)
        XCTAssertThrowsError(try BreakoutMedia.load(from: path))
        try Data(repeating: 32, count: 16385).write(to: path)
        XCTAssertThrowsError(try BreakoutMedia.load(from: path))
    }

    func testSnapshotReplayAndRejectsUntrustedState() throws {
        var original = BreakoutSimulation(configuration: BreakoutConfiguration(variation: .steerable))
        original.tick(input: BreakoutInput(serve: true))
        for _ in 0..<30 { original.tick() }
        let decoded = try JSONDecoder().decode(BreakoutSnapshot.self, from: JSONEncoder().encode(original.snapshot))
        var restored = try BreakoutSimulation(snapshot: decoded)
        for frame in 0..<300 {
            let input = BreakoutInput(paddlePositions: [Double(frame % 101) / 100], serve: frame % 31 == 0)
            original.tick(input: input); restored.tick(input: input)
            XCTAssertEqual(original.state, restored.state, "frame \(frame)")
        }
        var invalid = decoded
        invalid.sourceSHA256 = "another ROM"
        XCTAssertThrowsError(try BreakoutSimulation(snapshot: invalid))
        invalid = decoded
        invalid.state.teams[0].bricks.removeLast()
        XCTAssertThrowsError(try BreakoutSimulation(snapshot: invalid))
        invalid = decoded
        invalid.state.ball?.velocityX256 = Int.min
        XCTAssertThrowsError(try BreakoutSimulation(snapshot: invalid))
    }
}
