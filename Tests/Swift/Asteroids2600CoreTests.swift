import XCTest
@testable import GameHub

final class Asteroids2600CoreTests: XCTestCase {
    private func media() throws -> Asteroids2600Resources {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Library/Prepared/asteroids2600/asteroids2600.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("Owner-supplied Asteroids 2600 media is not prepared")
        }
        return try .load(from: path)
    }

    private func isolated(_ resources: Asteroids2600Resources) throws -> Asteroids2600Snapshot {
        var value = try Asteroids2600Simulation(resources: resources).snapshot
        value.upward = [.init(y: 10, horizontal: 0xd5, flags: 0)]
        value.downward = []
        value.pendingSplits = false
        value.saucerExploding = false
        value.saucerY = 0xe0
        value.collisionSchedule = 2
        value.random = .init()
        value.frame = 1 // The next dispatcher advances ship/projectiles.
        return value
    }

    func testInitialWaveMatchesSelectedResetCalls() throws {
        let game = try Asteroids2600Simulation(resources: media())
        // Independent reset decode: FA9D precedes each FA E2 flags call.
        XCTAssertEqual(game.state.upward, [.init(y: 1, horizontal: 0x37, flags: 9),
                                          .init(y: 63, horizontal: 0x64, flags: 18)])
        XCTAssertEqual(game.state.downward, [.init(y: 1, horizontal: 0xd5, flags: 5),
                                            .init(y: 63, horizontal: 0xa9, flags: 11)])
        XCTAssertEqual(game.player.lives, 4)
        XCTAssertEqual(game.state.random.high, 75)
    }

    func testAll66VariationsHaveDistinctSourceNumbers() throws {
        let resources = try media()
        let variations = Array(UInt8(0)...UInt8(63)) + [0x80, 0xa0]
        let numbers = try variations.map { try Asteroids2600Simulation(resources: resources, variation: $0).variationNumber }
        XCTAssertEqual(Set(numbers), Set(1...66))
        XCTAssertEqual(try Asteroids2600Simulation(resources: resources, variation: 0x20).variationNumber, 34)
        XCTAssertThrowsError(try Asteroids2600Simulation(resources: resources, variation: 64))
    }

    func testPositioningTablesRetainSourceRingAndDecreasingAnomaly() throws {
        let r = try media()
        var packed: UInt8 = 0x1d
        var pixels = Set<UInt8>()
        for _ in 0..<160 {
            let next = r.horizontal(packed, steps: 1, decreasing: false)
            pixels.insert(r.horizontalPixel(packed))
            packed = next
        }
        XCTAssertEqual(packed, 0x1d)
        XCTAssertEqual(pixels, Set(UInt8(0)...UInt8(159)))
        XCTAssertEqual(r.horizontalPixel(r.horizontal(0x1d, steps: 2, decreasing: false)), 80)
        XCTAssertEqual(r.horizontal(0x65, steps: 1, decreasing: true), 0x83)
        XCTAssertEqual(r.horizontalPixel(0x65), 13)
        XCTAssertEqual(r.horizontalPixel(0x83), 14)
    }

    func testContactRetainsCMPCarryAndInclusiveEdges() throws {
        let r = try media(), game = try Asteroids2600Simulation(resources: r)
        // Type 7 has extent 2. CMP's carried ADC admits the third pixel.
        XCTAssertTrue(game.contact(type: 7, y: 10, x: 0x1d, otherType: 0, otherY: 13, otherX: 0x1d))
        XCTAssertFalse(game.contact(type: 7, y: 10, x: 0x1d, otherType: 0, otherY: 14, otherX: 0x1d))
        let atEdge = r.horizontal(0x1d, steps: 3, decreasing: false)
        let beyond = r.horizontal(0x1d, steps: 4, decreasing: false)
        XCTAssertTrue(game.contact(type: 7, y: 10, x: 0x1d, otherType: 0, otherY: 10, otherX: atEdge))
        XCTAssertFalse(game.contact(type: 7, y: 10, x: 0x1d, otherType: 0, otherY: 10, otherX: beyond))
        XCTAssertFalse(game.contact(type: 11, y: 0, x: 0, otherType: 0, otherY: 0, otherX: 0))
    }

    func testInactiveCollisionSlotsRetryWithinSameFrame() throws {
        let r = try media()
        var value = try isolated(r)
        value.frame = 0; value.collisionSchedule = 0
        value.upward = [.init(y: 38, horizontal: 0x1d, flags: 0)]
        var game = try Asteroids2600Simulation(resources: r, snapshot: value)
        game.frame()
        XCTAssertEqual(game.state.shipDelay, 0x80)
        XCTAssertTrue(game.state.upward[0].markedForSplit)
        XCTAssertTrue(game.takeEvents().contains(.shipHit))
    }

    func testLargeSplitIsDeferredAndUsesOppositeFlag() throws {
        let r = try media()
        var value = try isolated(r)
        value.frame = 0; value.pendingSplits = true
        value.upward = [.init(y: 20, horizontal: 0x1d, flags: 0x40)]
        var game = try Asteroids2600Simulation(resources: r, snapshot: value)
        game.frame()
        XCTAssertEqual(game.state.upward.map(\.y), [19, 29])
        XCTAssertEqual(game.state.upward.map(\.flags), [0x29, 0xa2])
        XCTAssertEqual(game.state.upward.map(\.kind), [2, 2])
        XCTAssertFalse(game.state.pendingSplits)
    }

    func testVariation33SuppressesSecondarySplit() throws {
        let r = try media()
        var value = try isolated(r)
        value.variation = 0x80; value.pendingSplits = true
        value.upward = [.init(y: 20, horizontal: 0x1d, flags: 0x40)]
        var game = try Asteroids2600Simulation(resources: r, snapshot: value)
        game.frame()
        XCTAssertEqual(game.state.upward.count, 1)
        XCTAssertEqual(game.state.upward[0].kind, 2)
    }

    func testMediumBecomesSmallAndSmallIsRemoved() throws {
        let r = try media()
        var value = try isolated(r)
        value.pendingSplits = true
        value.upward = [.init(y: 20, horizontal: 0x1d, flags: 0x60)]
        var game = try Asteroids2600Simulation(resources: r, snapshot: value)
        game.frame()
        XCTAssertEqual(game.state.upward[0].kind, 3)
        value.upward = [.init(y: 20, horizontal: 0x1d, flags: 0x70)]
        game = try Asteroids2600Simulation(resources: r, snapshot: value)
        game.frame()
        XCTAssertTrue(game.state.upward.isEmpty)
        let oldWave = game.state.waves
        game.frame()
        XCTAssertEqual(game.state.waves, oldWave + 1)
        XCTAssertEqual(game.state.upward.count, 2)
        XCTAssertEqual(game.state.downward.count, 2)
    }

    func testSplitCapacityAndClippedPairRemainBounded() throws {
        let r = try media()
        var value = try isolated(r)
        value.pendingSplits = true
        value.upward = (0..<7).map { .init(y: UInt8(10 + $0 * 6), horizontal: 0x1d, flags: $0 == 0 ? 0x40 : 0) }
        var game = try Asteroids2600Simulation(resources: r, snapshot: value)
        game.frame()
        XCTAssertEqual(game.state.upward.count, 7)
        XCTAssertEqual(game.state.upward[0].kind, 2)
        value.upward = [.init(y: 84, horizontal: 0x1d, flags: 0x40)]
        game = try Asteroids2600Simulation(resources: r, snapshot: value)
        game.frame()
        XCTAssertEqual(game.state.upward.map(\.y), [251, 5, 84])
        XCTAssertLessThanOrEqual(game.state.upward.count, 8)
    }

    func testSourceThrustCarriesFractionAndIdleMissileAnchors() throws {
        var game = try Asteroids2600Simulation(resources: media())
        game.frame(); game.frame(input: .init(thrust: true, fire: true))
        XCTAssertEqual(game.state.velocityVertical, 0xff81)
        XCTAssertEqual(game.state.velocityHorizontal, 0)
        XCTAssertEqual(game.state.verticalFraction, 248)
        XCTAssertEqual(game.state.shipY, 40)
        XCTAssertEqual(game.state.projectiles[0].horizontal, 0xfd) // +2 source pixels
        XCTAssertEqual(game.state.projectiles[1].y, 40)
        XCTAssertEqual(game.state.projectiles[1].lifetimeAndHeading, 0x60)
    }

    func testTurnSamplingAndSimultaneousDirections() throws {
        let r = try media()
        var game = try Asteroids2600Simulation(resources: r, snapshot: isolated(r))
        game.frame(input: .init(right: true))
        XCTAssertEqual(game.player.heading, 15)
        game.frame(); game.frame(input: .init(right: true))
        XCTAssertEqual(game.player.heading, 15) // frame 4 has source bit 1 clear
        game.frame(); game.frame(input: .init(left: true, right: true))
        XCTAssertEqual(game.player.heading, 15)
    }

    func testDragUsesSourceBytesAndLimiterUsesPreviousHighByte() throws {
        let r = try media()
        var value = try isolated(r)
        value.velocityVertical = 0xff81
        var game = try Asteroids2600Simulation(resources: r, snapshot: value)
        game.frame()
        XCTAssertEqual(game.state.velocityVertical, 0xff83)
        XCTAssertEqual(game.state.shipY, 40)
        value.velocityVertical = 0x4100
        game = try Asteroids2600Simulation(resources: r, snapshot: value)
        game.frame(input: .init(thrust: true))
        // Adding -127 gives $4081. The limiter stores $3F81 while this
        // dispatcher's displacement still uses the pre-limiter $40 high byte.
        XCTAssertEqual(game.state.velocityVertical, 0x3f81)
        XCTAssertEqual(game.state.shipY, 45)
    }

    func testShipWrapPreservesFiveClippedTopRows() throws {
        let r = try media()
        var value = try isolated(r)
        value.shipY = 83; value.velocityVertical = 0x1100
        var game = try Asteroids2600Simulation(resources: r, snapshot: value)
        game.frame(input: .init(thrust: true))
        XCTAssertEqual(game.state.shipY, 0xfb)
        XCTAssertNoThrow(try Asteroids2600Simulation(resources: r, snapshot: game.snapshot))
    }

    func testHyperspaceNeedsTwoDownSamplesAndUsesSourceRNG() throws {
        let r = try media()
        var value = try isolated(r)
        value.downLatch = true
        value.velocityVertical = 0x1234; value.velocityHorizontal = 0xabcd
        var game = try Asteroids2600Simulation(resources: r, snapshot: value)
        game.frame(input: .init(down: true))
        XCTAssertEqual(game.state.shipY, 0xe0)
        XCTAssertEqual(game.state.shipHorizontal, 0x64)
        XCTAssertEqual(game.state.returnY, 52)
        XCTAssertEqual(game.state.shipDelay, 31)
        XCTAssertEqual(game.state.velocityHorizontal, 0)
        XCTAssertEqual(game.state.velocityVertical, 0)
        XCTAssertTrue(game.takeEvents().contains(.hyperspace))
    }

    func testFlipLatchAndShieldFailureFollowOptionBits() throws {
        let r = try media()
        var value = try isolated(r); value.variation = 16
        var game = try Asteroids2600Simulation(resources: r, snapshot: value)
        game.frame(input: .init(down: true))
        XCTAssertEqual(game.player.heading, 8)
        game.frame(); game.frame(input: .init(down: true))
        XCTAssertEqual(game.player.heading, 8)
        value.variation = 8; value.frame = 0
        game = try Asteroids2600Simulation(resources: r, snapshot: value)
        for _ in 0..<64 { game.frame(input: .init(down: true)) }
        XCTAssertFalse(game.state.shield)
        XCTAssertEqual(game.state.shipDelay, 0x81)
    }

    func testFireIsEdgeTriggeredAndThereAreOnlyTwoMissiles() throws {
        let r = try media()
        var game = try Asteroids2600Simulation(resources: r, snapshot: isolated(r))
        game.frame(input: .init(fire: true))
        XCTAssertFalse(game.state.projectiles[0].active)
        XCTAssertTrue(game.state.projectiles[1].active)
        for _ in 0..<4 { game.frame(input: .init(fire: true)) }
        XCTAssertFalse(game.state.projectiles[0].active)
        game.frame(); game.frame(); game.frame(input: .init(fire: true)); game.frame(input: .init(fire: true))
        XCTAssertTrue(game.state.projectiles[0].active)
        XCTAssertTrue(game.state.projectiles[1].active)
        XCTAssertFalse(game.state.projectiles[2].active)
    }

    func testNegativeProjectileStepRetainsSECBeforeADC() throws {
        let r = try media()
        var value = try isolated(r)
        value.shipDelay = 0x80
        value.projectiles[0] = .init(y: 20, horizontal: 0x1d, lifetimeAndHeading: 0x6c)
        var game = try Asteroids2600Simulation(resources: r, snapshot: value)
        game.frame()
        XCTAssertEqual(r.horizontalPixel(game.state.projectiles[0].horizontal), 83) // -4 -> +5 pixels
        XCTAssertEqual(game.state.projectiles[0].y, 20)
        value.projectiles[0].lifetimeAndHeading = 0x64
        game = try Asteroids2600Simulation(resources: r, snapshot: value)
        game.frame()
        XCTAssertEqual(r.horizontalPixel(game.state.projectiles[0].horizontal), 74)
    }

    func testProjectileLifetimeDecrementsEveryFourthFrame() throws {
        let r = try media()
        var value = try isolated(r)
        value.shipDelay = 0x80
        value.projectiles[0] = .init(y: 20, horizontal: 0x1d, lifetimeAndHeading: 0x20)
        var game = try Asteroids2600Simulation(resources: r, snapshot: value)
        game.frame() // frame 2, unchanged
        XCTAssertEqual(game.state.projectiles[0].lifetimeAndHeading, 0x20)
        game.frame(); game.frame() // frame 4
        XCTAssertEqual(game.state.projectiles[0].lifetimeAndHeading, 0x10)
        for _ in 0..<4 { game.frame() }
        XCTAssertFalse(game.state.projectiles[0].active)
        XCTAssertEqual(game.state.projectiles[0].y, 0xe0)
    }

    private func scoredHit(_ r: Asteroids2600Resources, score: Int, variation: UInt8, lives: Int = 4) throws -> Asteroids2600Simulation {
        var value = try isolated(r)
        value.frame = 0; value.collisionSchedule = 0xc0; value.variation = variation
        value.players[0] = .init(livesAndHeading: UInt8(lives << 4), scoreUnits: score)
        value.upward = [.init(y: 30, horizontal: 0x1d, flags: 0)]
        value.projectiles[0] = .init(y: 30, horizontal: 0x1d, lifetimeAndHeading: 0x60)
        var game = try Asteroids2600Simulation(resources: r, snapshot: value)
        game.frame()
        return game
    }

    func testBCDAwardsBonusIntervalsRolloverAndLifeCap() throws {
        let r = try media()
        let at5000 = try scoredHit(r, score: 499, variation: 0)
        XCTAssertEqual(at5000.player.points, 5010); XCTAssertEqual(at5000.player.lives, 5)
        XCTAssertEqual(try scoredHit(r, score: 999, variation: 2).player.lives, 5)
        XCTAssertEqual(try scoredHit(r, score: 1999, variation: 4).player.lives, 5)
        XCTAssertEqual(try scoredHit(r, score: 499, variation: 6).player.lives, 4)
        XCTAssertEqual(try scoredHit(r, score: 499, variation: 0, lives: 9).player.lives, 9)
        XCTAssertEqual(try scoredHit(r, score: 9999, variation: 0).player.points, 10)
    }

    func testSmallAndLargeSaucerHaveDifferentSourceAwards() throws {
        let r = try media()
        for small in [false, true] {
            var value = try isolated(r)
            value.frame = 0; value.collisionSchedule = 0xc0
            value.saucerY = 30; value.saucerHorizontal = 0x1d; value.saucerFlags = small ? 0x20 : 0
            value.projectiles[0] = .init(y: 30, horizontal: 0x1d, lifetimeAndHeading: 0x60)
            var game = try Asteroids2600Simulation(resources: r, snapshot: value)
            game.frame()
            XCTAssertEqual(game.player.points, small ? 1000 : 200)
            XCTAssertTrue(game.state.saucerExploding)
            XCTAssertFalse(game.state.projectiles[0].active)
        }
    }

    func testDeathConsumesLifeAfterSixEvenFrames() throws {
        let r = try media()
        var value = try isolated(r); value.frame = 0; value.shipDelay = 0x80
        value.deathOrShieldFailure = true; value.players[1].livesAndHeading = 0
        var game = try Asteroids2600Simulation(resources: r, snapshot: value)
        for _ in 0..<12 { game.frame() }
        XCTAssertEqual(game.player.lives, 3)
        XCTAssertEqual(game.state.shipDelay, 63)
        XCTAssertFalse(game.shipVisible)
        XCTAssertTrue(game.takeEvents().contains(.lifeLost(0)))
    }

    func testTwoPlayerReentryPreservesIndependentScores() throws {
        let r = try media()
        var value = try isolated(r)
        value.variation = 0x20; value.frame = 0; value.shipY = 0xe0
        value.deathOrShieldFailure = true
        value.players[0].scoreUnits = 30; value.players[1].scoreUnits = 90
        var game = try Asteroids2600Simulation(resources: r, snapshot: value)
        game.frame()
        XCTAssertEqual(game.state.currentPlayer, 1)
        XCTAssertEqual(game.player.points, 900)
        XCTAssertEqual(game.state.players[0].points, 300)
        XCTAssertTrue(game.state.upward.isEmpty)
        XCTAssertTrue(game.state.downward.isEmpty)
    }

    func testSnapshotRestoresDeterministicSourceDispatcher() throws {
        let r = try media()
        var game = try Asteroids2600Simulation(resources: r, variation: 35)
        for index in 0..<777 { game.frame(input: .init(thrust: index % 17 < 11, fire: index % 31 < 3)) }
        let data = try JSONEncoder().encode(game.snapshot)
        var restored = try Asteroids2600Simulation(resources: r,
            snapshot: JSONDecoder().decode(Asteroids2600Snapshot.self, from: data))
        for index in 0..<1000 {
            let input = Asteroids2600Input(left: index % 13 < 5, down: index % 191 == 0, fire: index % 19 < 3)
            game.frame(input: input); restored.frame(input: input)
        }
        XCTAssertEqual(game.snapshot, restored.snapshot)
        XCTAssertLessThan(data.count, 4096)
    }

    func testRejectsMalformedSnapshotsAndBoundedResources() throws {
        var r = try media()
        var value = try isolated(r)
        value.upward = Array(repeating: .init(y: 20, horizontal: 0x1d, flags: 0), count: 9)
        XCTAssertThrowsError(try Asteroids2600Simulation(resources: r, snapshot: value))
        value = try isolated(r); value.projectiles[0].lifetimeAndHeading = 3
        XCTAssertThrowsError(try Asteroids2600Simulation(resources: r, snapshot: value))
        value = try isolated(r); value.sourceSHA256 = "wrong"
        XCTAssertThrowsError(try Asteroids2600Simulation(resources: r, snapshot: value))
        r.tables["horizontalIncreasing"] = []
        XCTAssertThrowsError(try r.validate())
        r = try media(); r.masks[0].width = 1
        XCTAssertThrowsError(try r.validate())
        r = try media(); r.tables["horizontalIncreasing"]![0x1d] ^= 1
        XCTAssertEqual(r.sourceSHA256, Asteroids2600Resources.sourceIdentity)
        XCTAssertEqual(r.contentSHA256, Asteroids2600Resources.contentIdentity)
        XCTAssertThrowsError(try r.validate()) // Claimed identities cannot bless changed content.
        value = try isolated(try media()); value.currentPlayer = 2
        XCTAssertThrowsError(try Asteroids2600Simulation(resources: try media(), snapshot: value))
        value = try isolated(try media()); value.projectiles.removeLast()
        XCTAssertThrowsError(try Asteroids2600Simulation(resources: try media(), snapshot: value))
    }

    func testEveryVariationMaintainsSourceSlotAndSaveBounds() throws {
        let r = try media()
        for variant in Array(UInt8(0)...UInt8(63)) + [0x80, 0xa0] {
            var game = try Asteroids2600Simulation(resources: r, variation: variant)
            for index in 0..<256 {
                game.frame(input: .init(left: index % 37 < 19, thrust: index % 19 < 15,
                                       down: index % 47 == 0, fire: index % 13 < 3))
            }
            XCTAssertNoThrow(try Asteroids2600Simulation(resources: r, snapshot: game.snapshot), "variation \(variant)")
            XCTAssertLessThanOrEqual(game.state.upward.count, 8)
            XCTAssertLessThanOrEqual(game.state.downward.count, 8)
        }
    }
}
