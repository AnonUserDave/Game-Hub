import Foundation
import XCTest
@testable import GameHub

final class PGACoreTests: XCTestCase {
    private func fixture(cupDistance: Double = 100, width: Double = 25, hazards: [PGAHazard] = []) -> PGACourse {
        PGACourse(name: "Simulation test course", provenance: "Synthetic test fixture", holes: [
            PGAHole(name: "Test", par: 3, tee: .zero, cup: PGAVector(x: 0, y: 0, z: cupDistance),
                    centerline: [.zero, PGAVector(x: 0, y: 0, z: cupDistance)], fairwayWidth: width,
                    greenRadius: cupDistance < 5 ? 12 : 5, hazards: hazards, terrainSeed: 0)
        ])
    }

    @discardableResult
    private func settle(_ game: inout PGASimulation, delta: Double = 1.0 / 60.0) -> Int {
        var steps = 0
        while game.phase.inMotion && steps < 5000 { game.update(deltaTime: delta); steps += 1 }
        XCTAssertLessThan(steps, 5000, "A shot must always finish in finite time")
        return steps
    }

    func testCourseDataRoundTripsAndTerrainIsFinite() throws {
        let course = PGACourse.development
        XCTAssertEqual(try JSONDecoder().decode(PGACourse.self, from: JSONEncoder().encode(course)), course)
        XCTAssertEqual(course.holes.count, 3)
        XCTAssertTrue(course.provenance.contains("Generated"))
        for hole in course.holes {
            XCTAssertEqual(hole.surface(x: hole.cup.x, z: hole.cup.z), .green)
            XCTAssertEqual(hole.surface(x: hole.tee.x, z: hole.tee.z), .tee)
            for x in stride(from: hole.minX, through: hole.maxX, by: 5) {
                for z in stride(from: hole.minZ, through: hole.maxZ, by: 5) {
                    XCTAssertTrue(hole.height(x: x, z: z).isFinite)
                    XCTAssertTrue(hole.gradient(x: x, z: z).length.isFinite)
                }
            }
        }
    }

    func testThreeClickSwingTransitionsAndCancel() {
        var game = PGASimulation()
        game.swing()
        XCTAssertEqual(game.phase, .power)
        for _ in 0..<6 { game.update(deltaTime: 0.1) }
        XCTAssertEqual(game.meter, 0.5, accuracy: 0.001)
        game.swing()
        XCTAssertEqual(game.phase, .accuracy)
        XCTAssertEqual(game.shotPower, 0.5, accuracy: 0.001)
        game.cancelSwing()
        XCTAssertEqual(game.phase, .aiming)
        XCTAssertEqual(game.strokes, 0)
        game.swing()
        for _ in 0..<12 { game.update(deltaTime: 0.1) }
        game.swing()
        for _ in 0..<39 { game.update(deltaTime: 1.0 / 120) }
        XCTAssertEqual(game.meter, 0, accuracy: 0.001)
        game.swing()
        XCTAssertEqual(game.phase, .airborne)
        XCTAssertEqual(game.strokes, 1)
    }

    func testAirborneShotsRejectNewSwingClubAndAim() {
        var game = PGASimulation()
        let heading = game.heading, club = game.club
        game.strike(power: 1, accuracy: 0)
        game.swing(); game.strike(power: 0.5, accuracy: 1)
        game.changeClub(2); game.aim(1)
        XCTAssertEqual(game.strokes, 1)
        XCTAssertEqual(game.heading, heading)
        XCTAssertEqual(game.club, club)
        for _ in 0..<60 { game.update(deltaTime: 1.0 / 120) }
        XCTAssertGreaterThan(game.ball.y, 3)
        XCTAssertGreaterThan(game.ball.z, 20)
        settle(&game)
        XCTAssertEqual(game.phase, .aiming)
        XCTAssertGreaterThan(game.lastShotDistance, 160)
        XCTAssertEqual(game.velocity, .zero)
        XCTAssertEqual(game.ball.y, game.hole.height(x: game.ball.x, z: game.ball.z) + PGASimulation.ballRadius, accuracy: 0.001)
    }

    func testFixedStepTrajectoryIndependentOfRenderRate() {
        var slow = PGASimulation(), fast = PGASimulation()
        slow.strike(power: 0.87, accuracy: 0.2); fast.strike(power: 0.87, accuracy: 0.2)
        for _ in 0..<180 { slow.update(deltaTime: 1.0 / 30) }
        for _ in 0..<720 { fast.update(deltaTime: 1.0 / 120) }
        XCTAssertEqual(slow.phase, fast.phase)
        XCTAssertEqual(slow.ball.x, fast.ball.x, accuracy: 0.00001)
        XCTAssertEqual(slow.ball.y, fast.ball.y, accuracy: 0.00001)
        XCTAssertEqual(slow.ball.z, fast.ball.z, accuracy: 0.00001)
        // Invalid external frame times must not poison position or the meter.
        let before = fast.ball
        fast.update(deltaTime: .nan); fast.update(deltaTime: -.infinity)
        XCTAssertEqual(fast.ball, before)
    }

    func testWaterPenaltyRestoresPreviousLieAndAddsOneStroke() {
        let water = PGAHazard(center: PGAVector(x: 0, y: 0, z: 8), radiusX: 40, radiusZ: 2, surface: .water)
        var game = PGASimulation(course: fixture(cupDistance: 30, hazards: [water]))
        let before = game.ball
        game.selectClub(.putter); game.strike(power: 1, accuracy: 0)
        settle(&game)
        XCTAssertEqual(game.phase, .aiming)
        XCTAssertEqual(game.strokes, 2)
        XCTAssertEqual(game.ball, before)
        XCTAssertTrue(game.message.contains("Water hazard"))
    }

    func testOutOfBoundsPenaltyAndHoleReset() {
        var game = PGASimulation(course: fixture())
        let before = game.ball
        game.selectClub(.driver); game.aim(.pi); game.strike(power: 1, accuracy: 0)
        settle(&game)
        XCTAssertEqual(game.strokes, 2)
        XCTAssertEqual(game.ball, before)
        XCTAssertTrue(game.message.contains("Out of bounds"))
        game.resetHole()
        XCTAssertEqual(game.strokes, 0)
        XCTAssertEqual(game.phase, .aiming)
        XCTAssertEqual(game.ball, before)
        XCTAssertEqual(game.scores, [])
    }

    func testSlowPuttHoledAndRoundCompletesOnce() {
        var game = PGASimulation(course: fixture(cupDistance: 1))
        XCTAssertEqual(game.club, .putter)
        game.strike(power: 0.16, accuracy: 0)
        settle(&game)
        XCTAssertEqual(game.phase, .holed)
        XCTAssertEqual(game.strokes, 1)
        XCTAssertLessThan(game.distanceToCup, 0.001)
        game.continueRound(); game.continueRound()
        XCTAssertEqual(game.phase, .roundComplete)
        XCTAssertEqual(game.scores, [1])
        XCTAssertEqual(game.completedStrokes, 1)
        XCTAssertEqual(game.scoreToPar, -2)
        game.restartRound()
        XCTAssertEqual(game.scores, [])
        XCTAssertEqual(game.phase, .aiming)
        XCTAssertEqual(game.strokes, 0)
    }

    func testFastPuttRollsOverCupAndRoughSlowsRoll() {
        var fast = PGASimulation(course: fixture(cupDistance: 1))
        fast.strike(power: 1, accuracy: 0)
        settle(&fast)
        XCTAssertEqual(fast.phase, .aiming, "Cup capture is speed limited")
        XCTAssertGreaterThan(fast.distanceToCup, 2)
        var rough = PGASimulation(course: fixture(width: 2)), fairway = PGASimulation(course: fixture(width: 100))
        for key in [0, 1] {
            if key == 0 { rough.selectClub(.putter); rough.aim(.pi / 2); rough.strike(power: 1, accuracy: 0) }
            else { fairway.selectClub(.putter); fairway.aim(.pi / 2); fairway.strike(power: 1, accuracy: 0) }
        }
        settle(&rough); settle(&fairway)
        XCTAssertLessThan(rough.lastShotDistance, fairway.lastShotDistance)
    }

    func testHotSeatTurnsFollowHonorsAndAwayRules() {
        var game = PGASimulation(course: fixture(cupDistance: 60, width: 60), playerNames: ["Dad", "Pablo"])
        XCTAssertEqual(game.playerName, "Dad", "First hole: list order has the honor")
        game.selectClub(.wedge); game.strike(power: 0.5, accuracy: 0)
        settle(&game)
        XCTAssertEqual(game.playerName, "Pablo", "Everyone tees off before anyone plays a second shot")
        XCTAssertEqual(game.strokes, 0)
        game.selectClub(.wedge); game.strike(power: 0.25, accuracy: 0)
        settle(&game)
        // Pablo's shorter drive leaves him away, so he plays again.
        let pabloAway = game.players[1].ball.distance(to: game.hole.cup) > game.players[0].ball.distance(to: game.hole.cup)
        XCTAssertEqual(game.playerName, pabloAway ? "Pablo" : "Dad")
        // Play both out with putts/chips until the hole completes.
        var guardCount = 0
        while game.phase != .roundComplete && game.holeIndex == 0 && guardCount < 80 {
            if game.phase == .holed {
                XCTAssertTrue(game.players[game.currentPlayer].holed)
                game.continueRound()
            } else {
                game.selectClub(game.distanceToCup > 20 ? .wedge : .putter); game.alignToCup()
                let power = game.club == .putter ? min(1, sqrt(2 * PGASurface.green.rollingFriction * game.distanceToCup) / PGAClub.putter.speed) : min(1, game.distanceToCup / 70)
                game.strike(power: power, accuracy: 0); settle(&game)
            }
            guardCount += 1
        }
        XCTAssertEqual(game.phase, .roundComplete, "One-hole fixture completes after both players hole out")
        XCTAssertEqual(game.players.map(\.scores.count), [1, 1])
        XCTAssertTrue(game.players.allSatisfy { ($0.scores.first ?? 0) >= 1 })
    }

    func testNextTeeHonorAndMultiplayerSnapshot() throws {
        var game = PGASimulation(course: PGACourse.development, playerNames: ["Dad", "Pablo", "Guest"])
        // Record hole 1 as Dad 5, Pablo 3, Guest 4 through the public flow helper.
        var strokes = [5, 3, 4]
        for _ in 0..<3 {
            game.selectClub(.putter)
            let player = game.currentPlayer
            game.restoreHoleForTest(strokes: strokes[player])
            strokes[player] = 0
        }
        XCTAssertEqual(game.holeIndex, 1)
        XCTAssertEqual(game.players.map(\.scores), [[5], [3], [4]])
        XCTAssertEqual(game.playerName, "Pablo", "Lowest score on the previous hole has the honor")
        let snapshot = try XCTUnwrap(game.snapshot)
        var restored = PGASimulation(course: PGACourse.development, playerNames: ["Dad", "Pablo", "Guest"])
        try restored.restore(try JSONDecoder().decode(PGARoundSnapshot.self, from: JSONEncoder().encode(snapshot)))
        XCTAssertEqual(restored.players, game.players)
        XCTAssertEqual(restored.playerName, "Pablo")
        var wrong = PGASimulation(course: PGACourse.development, playerNames: ["Dad"])
        XCTAssertThrowsError(try wrong.restore(snapshot))
    }
}
