import XCTest
@testable import GameHub

final class CrossfireCoreTests: XCTestCase {
    private func quiet() throws -> CrossfireSimulation {
        var snapshot = CrossfireSimulation().snapshot
        // A source-valid byte counter of255 suppresses new actor admission.
        snapshot.activeEnemies = 255
        return try CrossfireSimulation(snapshot: snapshot)
    }

    func testSourceSpawnGroupsAndObstacleGeometry() {
        let sim = CrossfireSimulation()
        XCTAssertEqual(sim.enemies.count, 11)
        XCTAssertEqual(sim.enemies.prefix(3).map(\.position), [CrossfirePoint(x: 0, y: 48), CrossfirePoint(x: 0, y: 112), CrossfirePoint(x: 0, y: 176)])
        XCTAssertEqual(sim.enemies[3].spawn, CrossfirePoint(x: 224, y: 80))
        XCTAssertEqual(sim.enemies[10].spawn, CrossfirePoint(x: 208, y: 0))
        XCTAssertEqual(CrossfireSimulation.obstacles.count, 42)
        XCTAssertEqual(CrossfireSimulation.obstacles.last, CrossfirePoint(x: 200, y: 168))
        XCTAssertEqual(sim.lives, 3)
        XCTAssertEqual(sim.ammunition, 35)
        XCTAssertEqual(sim.snapshot.freeProjectiles, Array(0..<6))
    }

    func testMovementRetainsAxisUntilIntersectionAndSpaceStops() throws {
        var sim = try quiet()
        sim.press("L")
        sim.advance(iterations: 32)
        XCTAssertEqual(sim.player, CrossfirePoint(x: 130, y: 160))
        sim.press("I")
        sim.advance(iterations: 15 * 32)
        XCTAssertEqual(sim.player, CrossfirePoint(x: 160, y: 160))
        sim.advance(iterations: 32)
        XCTAssertEqual(sim.player, CrossfirePoint(x: 160, y: 158))
        sim.press(" ")
        sim.advance(iterations: 15 * 32)
        XCTAssertEqual(sim.player, CrossfirePoint(x: 160, y: 128))
        sim.advance(iterations: 32)
        XCTAssertEqual(sim.player, CrossfirePoint(x: 160, y: 128))
    }

    func testShootingHasIndependentKeysAndOneConsumedLatch() throws {
        var s = try quiet().snapshot
        s.fireDelay = 0
        var sim = try CrossfireSimulation(snapshot: s)
        sim.press("E")
        sim.advance(iterations: 32)
        XCTAssertEqual(sim.player, CrossfirePoint(x: 128, y: 160))
        XCTAssertEqual(sim.ammunition, 34)
        XCTAssertEqual(sim.projectiles[5].kind, 2)
        XCTAssertEqual(sim.projectiles[5].position, CrossfirePoint(x: 128, y: 152))
        XCTAssertEqual(sim.projectiles[5].velocity, CrossfirePoint(x: 0, y: -2))
        sim.advance(iterations: 13 * 32)
        XCTAssertEqual(sim.ammunition, 34, "Source consumes the firing latch; repeat requires a new key event")
    }

    func testCannotFireAcrossObstacleBetweenCorridors() throws {
        var s = try quiet().snapshot
        s.player = CrossfirePoint(x: 130, y: 160)
        s.velocity = CrossfirePoint(x: 2, y: 0)
        s.movementKey = 0xCC
        s.fireDelay = 0
        var sim = try CrossfireSimulation(snapshot: s)
        sim.shoot(.up)
        sim.advance(iterations: 32)
        XCTAssertEqual(sim.ammunition, 35)
        XCTAssertTrue(sim.projectiles.allSatisfy { $0.kind == 0 })
        sim.advance(iterations: 14 * 32)
        XCTAssertEqual(sim.player.x, 160)
        XCTAssertEqual(sim.ammunition, 34)
    }

    func testHostilePoolReservesOneSlotForPlayer() throws {
        var s = try quiet().snapshot
        for i in s.enemies.indices { s.enemies[i].state = 2; s.enemies[i].stage = 3 }
        var sim = try CrossfireSimulation(snapshot: s)
        for i in 0..<6 {
            s = sim.snapshot
            s.enemyIndex = i; s.enemyDivider = 1; s.enemyFireDivider = 1
            s.rng = Array(repeating: 0, count: 6)
            sim = try CrossfireSimulation(snapshot: s)
            sim.advance()
        }
        XCTAssertEqual(sim.projectiles.filter { $0.kind == 1 }.count, 5)
        XCTAssertEqual(sim.snapshot.freeProjectiles.count, 1)
        s = sim.snapshot; s.fireDelay = 0; s.playerDivider = 1
        sim = try CrossfireSimulation(snapshot: s)
        sim.shoot(.right); sim.advance()
        XCTAssertEqual(sim.snapshot.freeProjectiles.count, 0)
        XCTAssertEqual(sim.projectiles.filter { $0.kind == 2 }.count, 1)
    }

    private func hit(_ sim: CrossfireSimulation, stage: Int) throws -> CrossfireSimulation {
        var s = sim.snapshot
        s.enemies[0].state = 2; s.enemies[0].stage = stage
        s.enemies[0].position = CrossfirePoint(x: 128, y: 144)
        s.enemyIndex = 0; s.enemyDivider = 8
        s.projectiles = Array(repeating: CrossfireProjectile(), count: 6)
        s.freeProjectiles = Array(0..<5)
        s.projectiles[5] = CrossfireProjectile(position: CrossfirePoint(x: 128, y: 152), velocity: CrossfirePoint(x: 0, y: -2), delay: 1, kind: 2)
        s.projectileIndex = 5
        var next = try CrossfireSimulation(snapshot: s)
        next.advance()
        return next
    }

    func testFourSourceKillsRespawnThenEliminate() throws {
        var sim = try quiet()
        for stage in 0..<4 {
            sim = try hit(sim, stage: stage)
            XCTAssertEqual(sim.enemies[0].state, 5)
            sim.advance(iterations: 447)
            XCTAssertEqual(sim.enemies[0].stage, stage + 1)
            if stage < 3 {
                XCTAssertEqual(sim.enemies[0].state, 0)
                XCTAssertEqual(sim.enemies[0].position, sim.enemies[0].spawn)
            }
        }
        XCTAssertEqual(sim.score, 150)
        XCTAssertTrue(sim.enemies[0].isEliminated)
        XCTAssertEqual(sim.remainingEnemies, 10)
    }

    func testBCDScoreExtraLivesAtBothThousandsTransitions() throws {
        for old in [4_990, 9_990, 14_990] {
            var s = try quiet().snapshot
            s.score = old; s.highScore = old
            let sim = try hit(CrossfireSimulation(snapshot: s), stage: 0)
            XCTAssertEqual(sim.score, old + 10)
            XCTAssertEqual(sim.lives, 4)
            XCTAssertEqual(sim.highScore, old + 10)
        }
    }

    func testAmmoTenSpawnsMirrorResupplyAndExactContactRefills() throws {
        var s = try quiet().snapshot
        s.ammunition = 11; s.fireDelay = 0; s.playerDivider = 1
        var sim = try CrossfireSimulation(snapshot: s)
        sim.shoot(.up); sim.advance()
        XCTAssertEqual(sim.ammunition, 10)
        XCTAssertEqual(sim.snapshot.resupply, CrossfirePoint(x: 96, y: 32))
        s = sim.snapshot; s.player = CrossfirePoint(x: 96, y: 34); s.velocity = CrossfirePoint(x: 0, y: -2)
        s.playerDivider = 1
        sim = try CrossfireSimulation(snapshot: s)
        sim.move(.up); sim.advance()
        XCTAssertEqual(sim.player, CrossfirePoint(x: 96, y: 32))
        XCTAssertEqual(sim.ammunition, 35)
        XCTAssertNil(sim.snapshot.resupply)
    }

    func testSourceRNGCarryShiftAndFirstRoamingStep() throws {
        var s = CrossfireSimulation(seed: 81).snapshot
        s.enemies[0].state = 2
        s.enemies[0].position = CrossfirePoint(x: 0, y: 32)
        s.activeEnemies = 4; s.roamDivider = 1
        var sim = try CrossfireSimulation(snapshot: s)
        sim.advance(iterations: 8)
        XCTAssertEqual(sim.snapshot.rng, [245, 245, 82, 81, 81, 81])
        XCTAssertFalse(sim.snapshot.rngCarry)
        XCTAssertEqual(sim.enemies[0].state, 3)
        XCTAssertEqual(sim.enemies[0].position, CrossfirePoint(x: 2, y: 32))
    }

    func testHostileContactCostsOneLifeAndEndsAfterSourceWait() throws {
        var s = try quiet().snapshot
        s.lives = 1
        s.projectiles[5] = CrossfireProjectile(position: CrossfirePoint(x: 128, y: 168), velocity: CrossfirePoint(x: 0, y: -2), delay: 1, kind: 1)
        s.freeProjectiles = Array(0..<5); s.projectileIndex = 5
        var sim = try CrossfireSimulation(snapshot: s)
        sim.advance()
        XCTAssertEqual(sim.lives, 0)
        XCTAssertTrue(sim.snapshot.playerDead)
        XCTAssertFalse(sim.ended)
        sim.advance(iterations: 3326)
        XCTAssertTrue(sim.ended)
    }

    func testCompletedWaveResetsStagesAndDecreasesAmmoCapacity() throws {
        var s = try quiet().snapshot
        for i in s.enemies.indices { s.enemies[i].state = 4; s.enemies[i].stage = 4 }
        s.transitionRemaining = 1
        var sim = try CrossfireSimulation(snapshot: s)
        sim.advance()
        XCTAssertEqual(sim.wave, 2)
        XCTAssertEqual(sim.ammunition, 30)
        XCTAssertEqual(sim.remainingEnemies, 11)
        XCTAssertTrue(sim.enemies.allSatisfy { $0.stage == 0 && $0.state == 0 })
        XCTAssertEqual(sim.player, CrossfirePoint(x: 128, y: 160))
    }

    func testSnapshotRoundTripIsDeterministicAndCorruptIndicesFail() throws {
        var original = CrossfireSimulation(seed: 17)
        original.move(.left); original.advance(iterations: 3000)
        let data = try JSONEncoder().encode(original.snapshot)
        var restored = try CrossfireSimulation(snapshot: JSONDecoder().decode(CrossfireSnapshot.self, from: data))
        for direction in CrossfireDirection.allCases {
            original.shoot(direction); restored.shoot(direction)
            original.advance(iterations: 2000); restored.advance(iterations: 2000)
        }
        XCTAssertEqual(original.snapshot, restored.snapshot)
        var bad = restored.snapshot; bad.projectileIndex = 6
        XCTAssertThrowsError(try CrossfireSimulation(snapshot: bad))
        bad = restored.snapshot; bad.sourceIdentity = "different revision"
        XCTAssertThrowsError(try CrossfireSimulation(snapshot: bad))
        bad = restored.snapshot; bad.freeProjectiles.append(bad.freeProjectiles.first ?? 0)
        XCTAssertThrowsError(try CrossfireSimulation(snapshot: bad))
        bad = restored.snapshot; bad.rng = []
        XCTAssertThrowsError(try CrossfireSimulation(snapshot: bad))
    }
}
