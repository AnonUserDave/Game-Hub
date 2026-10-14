import XCTest
@testable import GameHub

final class ApplePanicCoreTests: XCTestCase {
    private func resources() -> ApplePanicResources {
        let ladders = [ApplePanicLadder(x: 68, top: 15, bottom: 175)]
        let spawns = (0..<8).map { ApplePanicPosition(x: 120 - $0 * 8, y: 6) }
        return ApplePanicResources(schema: 1, sourceSHA256: ApplePanicResources.sourceIdentity,
            layouts: Array(repeating: ladders, count: 4), spawns: Array(repeating: spawns, count: 4),
            enemyCounts: [3, 5, 8], enemyTypes: Array(repeating: Array(repeating: 0, count: 8), count: 16),
            initialBackgroundIndex: 0, sprites: [:])
    }
    private func scenario(_ edit: (inout ApplePanicState) -> Void) throws -> ApplePanicSimulation {
        let res = resources()
        var snapshot = try ApplePanicSimulation(resources: res).snapshot
        for i in snapshot.state.enemies.indices { snapshot.state.enemies[i].active = false }
        snapshot.state.enemies[7].active = true
        snapshot.state.enemies[7].x = 128
        edit(&snapshot.state)
        return try ApplePanicSimulation(resources: res, snapshot: snapshot)
    }

    func testSourceInitializationAndLevelTables() throws {
        let res = resources()
        let game = try ApplePanicSimulation(resources: res)
        XCTAssertEqual(game.state.player.x, 68)
        XCTAssertEqual(game.state.player.y, 160)
        XCTAssertEqual(game.state.lives, 3)
        XCTAssertEqual(game.state.hourglass, 130)
        XCTAssertEqual(game.state.bonus, 2000)
        XCTAssertEqual(game.state.layoutIndex, 0)
        XCTAssertEqual(game.state.spawnIndex, 3)
        XCTAssertEqual(game.state.enemies.filter(\.active).count, 3)
        var snapshot = game.snapshot
        snapshot.state.level = 48
        snapshot.state.enemies = snapshot.state.enemies.map { var e = $0; e.active = false; return e }
        snapshot.state.dispatcherHalf = 1
        var last = try ApplePanicSimulation(resources: res, snapshot: snapshot)
        last.tick()
        XCTAssertEqual(last.state.phase, .completed)
        XCTAssertEqual(last.state.score, 2000)
        XCTAssertEqual(last.state.level, 48)
    }
    func testLadderMovementAndHorizontalBounds() throws {
        var game = try scenario { $0.player.x = 68 }
        for _ in 0..<16 { game.tick(input: .up) }
        XCTAssertEqual(game.state.player.y, 128)
        for _ in 0..<16 { game.tick(input: .down) }
        XCTAssertEqual(game.state.player.y, 160)
        var left = try scenario { $0.player.x = 1 }
        left.tick(input: .left)
        XCTAssertEqual(left.state.player.x, 1)
        var right = try scenario { $0.player.x = 130 }
        right.tick(input: .right)
        XCTAssertEqual(right.state.player.x, 130)
    }
    func testDigDepthMutationOnSecondActionFrameAndSourceTenFrameCycle() throws {
        var game = try scenario { $0.player.x = 35; $0.player.y = 128 }
        game.tick(input: .dig)
        XCTAssertTrue(game.state.holes.isEmpty)
        game.tick(input: .dig)
        XCTAssertEqual(game.state.holes, [ApplePanicHole(x: 42, row: 143, depth: 1)])
        for _ in 0..<40 { game.tick(input: .dig) }
        XCTAssertEqual(game.state.holes.first?.depth, 5)
        XCTAssertEqual(game.state.player.actionFrame, 2)
        for _ in 0..<10 { game.tick(input: .dig) }
        XCTAssertEqual(game.state.holes.first?.depth, 5)
    }
    func testDigRejectsBottomFloorLadderAndAdjacentHole() throws {
        var bottom = try scenario { $0.player.x = 35; $0.player.y = 160 }
        for _ in 0..<4 { bottom.tick(input: .dig) }
        XCTAssertTrue(bottom.state.holes.isEmpty)
        var ladder = try scenario { $0.player.x = 61; $0.player.y = 128 }
        for _ in 0..<4 { ladder.tick(input: .dig) }
        XCTAssertTrue(ladder.state.holes.isEmpty)
        var close = try scenario {
            $0.player.x = 43; $0.player.y = 128
            $0.holes = [ApplePanicHole(x: 42, row: 143, depth: 1)]
        }
        for _ in 0..<4 { close.tick(input: .dig) }
        XCTAssertEqual(close.state.holes.count, 1)
    }
    func testOpenHoleDropsPlayerAndOccupiedHoleBlocksHorizontalEntry() throws {
        var open = try scenario {
            $0.player.x = 41; $0.player.y = 128
            $0.holes = [ApplePanicHole(x: 42, row: 143, depth: 5)]
        }
        open.tick(input: .right)
        XCTAssertEqual(open.state.player.y, 130)
        XCTAssertFalse(open.state.player.onGround)
        for _ in 0..<16 { open.tick() }
        XCTAssertEqual(open.state.player.y, 160)
        XCTAssertTrue(open.state.player.onGround)
        var occupied = try scenario {
            $0.player.x = 41; $0.player.y = 128
            $0.holes = [ApplePanicHole(x: 42, row: 143, depth: 5, occupied: true)]
        }
        occupied.tick(input: .right)
        XCTAssertEqual(occupied.state.player.x, 41)
    }
    func testFullHoleTrapsEnemyFor128OfItsOwnUpdates() throws {
        var game = try scenario {
            $0.player.x = 35; $0.player.y = 128
            $0.enemies[0] = ApplePanicEnemy(kind: 0, x: 42, y: 134)
            $0.enemies[7].active = false
            $0.holes = [ApplePanicHole(x: 42, row: 143, depth: 5)]
        }
        game.tick()
        XCTAssertTrue(game.state.enemies[0].trapped)
        XCTAssertEqual(game.state.enemies[0].y, 143)
        XCTAssertEqual(game.state.enemies[0].trappedTicks, 128)
        XCTAssertTrue(game.state.holes[0].occupied)
        game.tick()
        XCTAssertEqual(game.state.enemies[0].trappedTicks, 128)
        game.tick()
        XCTAssertEqual(game.state.enemies[0].trappedTicks, 127)
    }
    func testFillingOccupiedHoleDropsNormalEnemyAndAwards100() throws {
        var game = try scenario {
            $0.player.x = 35; $0.player.y = 128
            $0.enemies[0] = ApplePanicEnemy(kind: 0, x: 42, y: 143, trapped: true, trappedTicks: 128, holeRow: 143)
            $0.enemies[7].active = false
            $0.holes = [ApplePanicHole(x: 42, row: 143, depth: 1, occupied: true)]
        }
        game.tick(input: .fill)
        XCTAssertEqual(game.state.holes.first?.depth, 1)
        game.tick(input: .fill)
        XCTAssertTrue(game.state.holes.isEmpty)
        game.tick()
        XCTAssertFalse(game.state.enemies[0].active)
        XCTAssertEqual(game.state.score, 100)
        XCTAssertEqual(game.state.highScore, 100)
        XCTAssertEqual(game.state.level, 1)
        game.tick()
        XCTAssertEqual(game.state.level, 2)
        XCTAssertEqual(game.state.score, 2100)
        XCTAssertEqual(game.state.enemies.filter(\.active).count, 5)
    }
    func testStrongerEnemiesRequireTwoAndThreeFloorDrops() throws {
        func drop(kind: Int, rows: [Int]) throws -> ApplePanicSimulation {
            var game = try scenario {
                $0.player.x = 35; $0.player.y = 0
                $0.enemies[0] = ApplePanicEnemy(kind: kind, x: 42, y: 79, trapped: true, trappedTicks: 128, holeRow: 79)
                $0.enemies[7].active = false
                $0.holes = rows.map { ApplePanicHole(x: 42, row: $0, depth: 5) }
            }
            game.tick()
            return game
        }
        let insufficient = try drop(kind: 1, rows: [])
        XCTAssertTrue(insufficient.state.enemies[0].active)
        XCTAssertEqual(insufficient.state.enemies[0].y, 102)
        XCTAssertEqual(insufficient.state.score, 0)
        let medium = try drop(kind: 1, rows: [111])
        XCTAssertFalse(medium.state.enemies[0].active)
        XCTAssertEqual(medium.state.score, 400)
        let strongInsufficient = try drop(kind: 2, rows: [111])
        XCTAssertTrue(strongInsufficient.state.enemies[0].active)
        let strong = try drop(kind: 2, rows: [111, 143])
        XCTAssertFalse(strong.state.enemies[0].active)
        XCTAssertEqual(strong.state.score, 900)
    }
    func testHourglassHasThreeTicksPerTwoPlayerStepsAndExpiryRestartsLife() throws {
        var game = try scenario { _ in }
        game.tick()
        XCTAssertEqual(game.state.hourglassCounter, 1)
        game.tick()
        XCTAssertEqual(game.state.hourglassCounter, 3)
        var expiry = try scenario { $0.hourglass = 1; $0.hourglassCounter = 31 }
        expiry.tick()
        XCTAssertEqual(expiry.state.lives, 2)
        XCTAssertEqual(expiry.state.hourglass, 130)
        XCTAssertEqual(expiry.state.lifeSerial, 2)
        XCTAssertEqual(expiry.state.enemyCursor, 0)
        var final = try scenario { $0.hourglass = 1; $0.hourglassCounter = 31; $0.lives = 1 }
        final.tick()
        XCTAssertEqual(final.state.phase, .gameOver)
        let ended = final.state
        final.tick(input: .right)
        XCTAssertEqual(final.state, ended)
    }
    func testBonusActuallyDecrementsOn33DispatchCallsAndExtraLifeTestsThousandsDigit() throws {
        var bonus = try scenario { $0.bonusCounter = 32 }
        bonus.tick()
        XCTAssertEqual(bonus.state.bonus, 1980)
        var extra = try scenario { $0.score = 4000 }
        extra.tick()
        XCTAssertEqual(extra.state.lives, 4)
        XCTAssertTrue(extra.state.extraLifeAwarded)
        var tenThousand = try scenario { $0.score = 10000 }
        tenThousand.tick()
        XCTAssertEqual(tenThousand.state.lives, 3)
    }
    func testPredictedEnemyPlayerCollisionRestartsWithoutAdvancingNewLifeCursor() throws {
        var game = try scenario {
            $0.player.x = 48; $0.player.y = 128
            $0.enemies[0] = ApplePanicEnemy(kind: 0, x: 42, y: 134, direction: .right)
            $0.enemies[7].active = false
        }
        game.tick()
        XCTAssertEqual(game.state.lives, 2)
        XCTAssertEqual(game.state.lifeSerial, 2)
        XCTAssertEqual(game.state.enemyCursor, 0)
        XCTAssertEqual(game.state.player.x, 68)
        XCTAssertEqual(game.state.player.y, 160)
    }
    func testSnapshotContinuesExactlyAndRejectsWrongIdentityAndMalformedCoordinates() throws {
        let res = resources()
        var game = try ApplePanicSimulation(resources: res, seed: 0xABCD)
        for _ in 0..<30 { game.tick(input: .up) }
        let data = try JSONEncoder().encode(game.snapshot)
        let snapshot = try JSONDecoder().decode(ApplePanicSnapshot.self, from: data)
        var restored = try ApplePanicSimulation(resources: res, snapshot: snapshot)
        for index in 0..<1000 {
            let input = ApplePanicInput.allCases[index % ApplePanicInput.allCases.count]
            game.tick(input: input); restored.tick(input: input)
        }
        XCTAssertEqual(game.state, restored.state)
        var wrong = snapshot
        wrong.sourceSHA256 = "different-source"
        XCTAssertThrowsError(try ApplePanicSimulation(resources: res, snapshot: wrong))
        wrong = snapshot; wrong.state.player.x = Int.max
        XCTAssertThrowsError(try ApplePanicSimulation(resources: res, snapshot: wrong))
        wrong = snapshot; wrong.state.lifeSerial = Int.max
        XCTAssertThrowsError(try ApplePanicSimulation(resources: res, snapshot: wrong))
        wrong = snapshot; wrong.state.enemies[0].trapped = true; wrong.state.enemies[0].y = 0
        XCTAssertThrowsError(try ApplePanicSimulation(resources: res, snapshot: wrong))
        wrong = snapshot; wrong.state.enemies.removeLast()
        XCTAssertThrowsError(try ApplePanicSimulation(resources: res, snapshot: wrong))
    }
    func testPreparedOriginalMediaWhenPresent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Library/Prepared/apple-panic/apple-panic.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Local original media are intentionally untracked") }
        let original = try ApplePanicResources.load(url: url)
        XCTAssertEqual(original.sprites.count, 16)
        XCTAssertEqual(original.enemyCounts, [3, 5, 8])
        XCTAssertEqual(original.enemyTypes.last, Array(repeating: 2, count: 8))
        let game = try ApplePanicSimulation(resources: original)
        XCTAssertEqual(game.state.enemies.filter(\.active).count, 3)
    }
}
