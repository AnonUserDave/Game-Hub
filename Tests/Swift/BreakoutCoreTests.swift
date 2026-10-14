import XCTest
@testable import GameHub

final class BreakoutCoreTests: XCTestCase {
    private func scenario(variation: BreakoutVariation = .breakout, players: Int = 1,
                          x: Int = 12, y: Int = 87, vx: Int = 0, vy: Int = -512,
                          edit: (inout BreakoutState) -> Void = { _ in }) throws -> BreakoutSimulation {
        let simulation = BreakoutSimulation(configuration: BreakoutConfiguration(variation: variation, playerCount: players))
        var snapshot = simulation.snapshot
        snapshot.state.phase = .playing
        snapshot.state.ball = BreakoutBall(x256: (x + 49) * 256, y256: y * 256, velocityX256: vx, velocityY256: vy)
        edit(&snapshot.state)
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
        XCTAssertEqual(ball.x256, 64 * 256)
        XCTAssertEqual(ball.y256, 112 * 256)
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
        var simulation = try scenario(variation: .catchBall, x: 81, y: 175, vx: 256, vy: 256)
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
        var easy = try scenario(x: 80, y: 26, vx: 256, vy: -256) {
            $0.paddleCollisionLatched = true; $0.brickCollisionLatched = true
        }
        XCTAssertEqual(easy.state.paddleWidth, 16)
        easy.tick()
        XCTAssertEqual(easy.state.paddleWidth, 12)
        XCTAssertFalse(easy.state.paddleCollisionLatched)
        XCTAssertFalse(easy.state.brickCollisionLatched)
        var hard = try scenario(x: 80, y: 26, vx: 256, vy: -256) { $0.configuration.teamDifficulties[0] = .advanced }
        XCTAssertEqual(hard.state.paddleWidth, 12)
        hard.tick()
        XCTAssertEqual(hard.state.paddleWidth, 8)
    }

    func testTwoWallsAnd864PointCompletion() throws {
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
        next.state.ball = BreakoutBall(x256: 130 * 256, y256: 175 * 256, velocityX256: 256, velocityY256: 256)
        simulation = try BreakoutSimulation(snapshot: next)
        simulation.tick()
        XCTAssertEqual(simulation.state.bricks.filter { $0 }.count, 108)
        XCTAssertTrue(simulation.events.contains(.wallRebuilt))
        next = simulation.snapshot
        next.state.ball = BreakoutBall(x256: 61 * 256, y256: 87 * 256, velocityX256: 0, velocityY256: -512)
        next.state.brickCollisionLatched = false
        next.state.teams[0].score = 863
        next.state.teams[0].bricks = Array(repeating: false, count: 108)
        next.state.teams[0].bricks[90] = true
        simulation = try BreakoutSimulation(snapshot: next)
        simulation.tick()
        XCTAssertEqual(simulation.state.score, 864)
        XCTAssertEqual(simulation.state.phase, .ended)
        XCTAssertNil(simulation.state.ball)
        XCTAssertTrue(simulation.events.contains(.ended))
    }

    func testFiveBallsAndIndependentAlternatingTeams() throws {
        var simulation = BreakoutSimulation(configuration: BreakoutConfiguration(playerCount: 2))
        for lost in 0..<10 {
            var snapshot = simulation.snapshot
            snapshot.state.phase = .playing
            snapshot.state.ball = BreakoutBall(x256: 130 * 256, y256: 207 * 256, velocityX256: 0, velocityY256: 256)
            simulation = try BreakoutSimulation(snapshot: snapshot)
            let active = simulation.state.activeTeam
            simulation.tick()
            XCTAssertEqual(simulation.state.teams[active].ballsUsed, lost / 2 + 1)
            XCTAssertNil(simulation.state.ball)
            XCTAssertEqual(simulation.state.phase, lost == 9 ? .ended : .serve)
        }
        XCTAssertEqual(simulation.state.teams.map(\.ballsUsed), [5, 5])
    }

    func testThreeAndFourPlayerSplitPaddleLimits() throws {
        var three = try scenario(players: 3) { $0.activeTeam = 1 }
        three.tick(input: BreakoutInput(paddlePositions: [0, 1, 0]))
        XCTAssertEqual(three.state.paddles.map(\.player), [1, 2])
        XCTAssertEqual(three.state.paddles.map(\.x), [77, 79])
        var four = try scenario(players: 4)
        four.tick(input: BreakoutInput(paddlePositions: [0, 1]))
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
        XCTAssertTrue(invisible.state.wallVisible)
        for _ in 0..<6 { invisible.tick() }
        XCTAssertFalse(invisible.state.wallVisible)
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
