import XCTest
@testable import GameHub

final class AsteroidsCoreTests: XCTestCase {
    func testReferencesAreIndependent() {
        XCTAssertEqual(AsteroidsEdition.allCases.count, 3)
        XCTAssertEqual(Set(AsteroidsEdition.allCases.map(\.sourceSHA256)).count, 3)
    }

    func test2600AllStatesAgainstInstructionArithmetic() {
        // Independent expression follows the source's ASL/EOR/ASL/ASL/ROL/ROL chain.
        for state in 0...65535 {
            let low = UInt8(truncatingIfNeeded: state)
            let high = UInt8(state >> 8)
            let xor = ((Int(low) * 2) & 255) ^ Int(low)
            let carryIntoHigh = (xor * 2 & 255) >> 7
            let expectedHigh = UInt8((Int(high) * 2 & 255) | carryIntoHigh)
            let expectedLow = UInt8((Int(low) * 2 & 255) | (Int(high) >> 7))
            var generator = Asteroids2600Random(low: low, high: high)
            XCTAssertEqual(generator.next(), expectedHigh, "state \(state)")
            XCTAssertEqual(generator.low, expectedLow, "state \(state)")
        }
    }

    func test2600ResetSequenceAndSnapshot() throws {
        var generator = Asteroids2600Random()
        XCTAssertEqual((0..<8).map { _ in generator.next() }, [105, 210, 165, 75, 151, 46, 92, 184])
        let saved = try JSONEncoder().encode(generator)
        var restored = try JSONDecoder().decode(Asteroids2600Random.self, from: saved)
        XCTAssertEqual((0..<100).map { _ in generator.next() }, (0..<100).map { _ in restored.next() })
    }

    func test7800TurningUsesMagnitudeAndWrap() {
        XCTAssertEqual(Asteroids7800Rotation.turnStep(xVelocityHigh: 0, yVelocityHigh: 0), 8)
        XCTAssertEqual(Asteroids7800Rotation.turnStep(xVelocityHigh: 2, yVelocityHigh: 0xff), 5)
        XCTAssertEqual(Asteroids7800Rotation.turnStep(xVelocityHigh: 0x80, yVelocityHigh: 0x80), 9)
        XCTAssertEqual(Asteroids7800Rotation.heading(254, step: 8, increasing: true), 6)
        XCTAssertEqual(Asteroids7800Rotation.heading(2, step: 8, increasing: false), 250)
        XCTAssertEqual(Set((0...255).map { Asteroids7800Rotation.imageCode(heading: UInt8($0)) }).count, 16)
    }

    func test7800WavesKeepChainedCarries() {
        XCTAssertEqual(Asteroids7800Wave.after(previous: 0, difficulty: .one),
                       Asteroids7800Wave(number: 1, asteroidCount: 4, countLimit: 12, saucerTimer: 164))
        XCTAssertEqual(Asteroids7800Wave.after(previous: 0, difficulty: .zero).saucerTimer, 252)
        XCTAssertEqual(Asteroids7800Wave.after(previous: 253, difficulty: .three).asteroidCount, 4)
        for difficulty in Asteroids7800Wave.Difficulty.allCases {
            for previous in 0...255 {
                let next = Asteroids7800Wave.after(previous: UInt8(previous), difficulty: difficulty)
                XCTAssertLessThanOrEqual(next.asteroidCount, next.countLimit)
                XCTAssertEqual(next.number, UInt8(previous) &+ 1)
            }
        }
    }

    func test7800RandomKeepsPreexistingRAMAndWrapsAt55() throws {
        var random = try Asteroids7800Random(existingPage: Array(repeating: 77, count: 256),
                                            romSeedTable: Array(0...54), timerByte: 31)
        XCTAssertEqual(random.firstIndex, 31)
        XCTAssertEqual(random.secondIndex, 62)
        XCTAssertEqual(random.next(), 108) // 31 + original RAM byte 77, not an invented zero.
        for _ in 0..<31 { _ = random.next() }
        XCTAssertEqual(random.firstIndex, 54)
        XCTAssertEqual(random.secondIndex, 30)
        XCTAssertThrowsError(try Asteroids7800Random(existingPage: [], romSeedTable: [], timerByte: 0))
        XCTAssertThrowsError(try Asteroids7800Random(existingPage: Array(repeating: 0, count: 256),
                                                    romSeedTable: [], timerByte: 0))
    }

    func test8BitMotionUsesFractionalCarryAndReportsIntegerChange() {
        var moving = Asteroids8BitMotion(x: 0x10f0, y: 0x2080, xVelocity: 0x0030, yVelocity: 0xffc0)
        XCTAssertTrue(moving.advance(size: 0, boundary: .wrap))
        XCTAssertEqual(moving.x, 0x1120)
        XCTAssertEqual(moving.y, 0x2040)
        var fractional = Asteroids8BitMotion(x: 0x1030, y: 0x2040, xVelocity: 1, yVelocity: 1)
        XCTAssertFalse(fractional.advance(size: 0, boundary: .wrap))
        XCTAssertEqual(fractional.x, 0x1031)
    }

    func test8BitWrapAndReflectionPreserveFraction() {
        var wrapping = Asteroids8BitMotion(x: 0x9eff, y: 0x5700, xVelocity: 1, yVelocity: 0)
        wrapping.advance(size: 0, boundary: .wrap)
        XCTAssertEqual(wrapping.x, 0x0100)
        XCTAssertEqual(wrapping.y, 0x5700)
        var reflecting = Asteroids8BitMotion(x: 0x9e70, y: 0x5770, xVelocity: 0x30, yVelocity: 0x30)
        reflecting.advance(size: 1, boundary: .reflect)
        XCTAssertEqual(reflecting.xVelocity, 0xffcf) // one's complement, not $FFD0.
        XCTAssertEqual(reflecting.yVelocity, 0xffcf)
        XCTAssertEqual(reflecting.x, 0x9da0)
        XCTAssertEqual(reflecting.y, 0x56a0)
        var lowEdge = Asteroids8BitMotion(x: 0x0000, y: 0x0000, xVelocity: 0xffc0, yVelocity: 0xffc0)
        lowEdge.advance(size: 0, boundary: .wrap)
        XCTAssertEqual(lowEdge.x, 0x9ec0)
        XCTAssertEqual(lowEdge.y, 0x57c0)
    }

    func test8BitSpawnUsesSeparateHardwareSamples() {
        let velocity = Asteroids8BitMotion.spawnVelocity(xMagnitude: 0, yMagnitude: 1,
                                                        xSign: 0, ySign: 0x80, fast: false)
        XCTAssertEqual(velocity.x, 0x0010)
        XCTAssertEqual(velocity.y, 0xffee)
        let fast = Asteroids8BitMotion.spawnVelocity(xMagnitude: 0, yMagnitude: 1,
                                                    xSign: 0, ySign: 0x80, fast: true)
        XCTAssertEqual(fast.x, 0x0090)
        XCTAssertEqual(fast.y, 0xff6e)
        let edges = Asteroids8BitMotion.spawnIntegerPosition(xSample: 0, ySample: 0x80)
        XCTAssertEqual(edges.x, 0x8f)
        XCTAssertEqual(edges.y, 2)
    }

    func test8BitProjectileCollisionKeepsOriginalEdges() {
        func hit(_ x: UInt8, _ y: UInt8, extent: UInt8 = 5, object: UInt8 = 2, projectile: UInt8 = 0) -> Bool {
            Asteroids8BitCollision.projectileHits(objectCode: object, objectX: 10, objectY: 20,
                                                  extent: extent, projectileCode: projectile,
                                                  projectileX: x, projectileY: y)
        }
        XCTAssertFalse(hit(10, 21))
        XCTAssertFalse(hit(11, 20))
        XCTAssertTrue(hit(15, 25))
        XCTAssertFalse(hit(16, 25))
        XCTAssertFalse(hit(15, 26))
        XCTAssertFalse(hit(11, 21, object: 0x12))
        XCTAssertFalse(hit(11, 21, projectile: 0xff))
        XCTAssertFalse(hit(11, 21, extent: 255)) // source byte addition wraps to 9.
    }

    func test8BitDecimalScoreRolloverDifficultyAndLifeSaturation() throws {
        var score = try Asteroids8BitScore(units: 990, lives: 3)
        XCTAssertEqual(score.add(.five, difficultyCode: 2), 1) // two increments, not a generic multiplier.
        XCTAssertEqual(score.units, 1_000)
        XCTAssertEqual(score.lives, 4)
        score = try Asteroids8BitScore(units: 999_999, lives: 255)
        XCTAssertEqual(score.add(.one, difficultyCode: 0), 1)
        XCTAssertEqual(score.units, 0)
        XCTAssertEqual(score.lives, 255)
        XCTAssertThrowsError(try Asteroids8BitScore(units: -1, lives: 0))
        XCTAssertThrowsError(try Asteroids8BitScore(units: 1_000_000, lives: 0))
    }

    func test8BitActiveLowControlAndTurnPriority() {
        XCTAssertEqual(Asteroids8BitControl.heading(254, joystickNibble: 7), 4)
        XCTAssertEqual(Asteroids8BitControl.heading(2, joystickNibble: 11), 252)
        XCTAssertEqual(Asteroids8BitControl.heading(2, joystickNibble: 3), 8)
        XCTAssertEqual(Asteroids8BitControl.heading(2, joystickNibble: 15), 2)
        XCTAssertTrue(Asteroids8BitControl.thrustRequested(joystickNibble: 14))
        XCTAssertFalse(Asteroids8BitControl.thrustRequested(joystickNibble: 15))
    }
}
