import XCTest
@testable import GameHub

final class Asteroids7800CoreTests: XCTestCase {
    private func resources() throws -> Asteroids7800Resources {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Library/Prepared/asteroids7800/asteroids7800.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Prepare the hash-fenced selected original with Tools/decode_asteroids7800.py")
        }
        return try Asteroids7800Resources.load(url: url)
    }
    private func simulation() throws -> Asteroids7800Simulation {
        try .init(resources: resources(), startup: .init(existingRandomPage: (0..<256).map {UInt8($0)},
                                                        timerByte: 31, provenance: "Synthetic arithmetic fixture; not original startup evidence"))
    }
    private func steady(mode: Asteroids7800Mode = .single, difficulty: Int = 1) throws -> Asteroids7800Simulation {
        var sim = try simulation(); try sim.configure(mode: mode, difficulty: difficulty); sim.start()
        var s = sim.snapshot
        s.players[0].phase = 0; s.players[0].asteroidCount = 1; s.players[0].wave = 0
        s.players[1].phase = mode.simultaneous ? 0 : 255
        s.objects[0] = .init(code: 0x10, x: 0x0500, y: 0x0500, palette: 0x9f)
        s.objects[24] = .init(code: 0x23, x: 0x5000, y: 0x5000, image: 0xb5, palette: 0xfd)
        if mode.simultaneous { s.objects[32] = .init(code: 0x23, x: 0x7000, y: 0x5000, image: 0xb5, palette: 0xfd) }
        return try .init(resources: sim.resources, snapshot: s)
    }
    func testPackageOriginalGraphicsAndTamperFence() throws {
        var media = try resources()
        XCTAssertEqual(media.frames.count, 813)
        XCTAssertEqual(media.frames["objects-00-3"]?.width, 12)
        XCTAssertEqual(media.frames["objects-fd-1"]?.width, 4)
        XCTAssertEqual(media.tables["waveCaps"], [8,12,14,16])
        media.tables["thrustLow"]![0] ^= 1
        XCTAssertThrowsError(try media.validate())
    }
    func testStartupRequiresRAMAndPreservesUninitializedTail() throws {
        let r = try resources()
        XCTAssertThrowsError(try Asteroids7800Simulation(resources: r, startup: .init(existingRandomPage: [], timerByte: 0, provenance: "test")))
        var a = try Asteroids7800Simulation(resources: r, startup: .init(existingRandomPage: Array(repeating: 77, count: 256), timerByte: 31, provenance: "test"))
        var b = try Asteroids7800Simulation(resources: r, startup: .init(existingRandomPage: Array(repeating: 78, count: 256), timerByte: 31, provenance: "test"))
        XCTAssertEqual(a.snapshot.random.page[62], 77)
        XCTAssertEqual(b.snapshot.random.page[62], 78)
        a.start(); b.start(); a.tick(inputs: [.init(), .init()]); b.tick(inputs: [.init(), .init()])
        XCTAssertNotEqual(a.snapshot.random, b.snapshot.random)
    }
    func testModesInitialLivesAndSourceFirstWave() throws {
        for mode in Asteroids7800Mode.allCases {
            var sim = try simulation(); try sim.configure(mode: mode, difficulty: 1); sim.start()
            XCTAssertEqual(sim.players[0].lives, 3)
            XCTAssertEqual(sim.snapshot.sharedLives, 6)
            sim.tick(inputs: [.init(),.init()])
            XCTAssertEqual(sim.snapshot.dliCounter, 2)
            if mode == .alternating { XCTAssertEqual(sim.players[0].asteroidCount, 0) }
            else { XCTAssertEqual(sim.players[0].wave, 0); XCTAssertEqual(sim.players[0].asteroidCount, 3) }
        }
    }
    func testMenuRepeatAndModeOrder() throws {
        var sim = try simulation(); try sim.configure(mode: .single, difficulty: 1)
        sim.tick(inputs: [.init(),.init()])
        sim.tick(inputs: [.init(hyperspace: true),.init()])
        XCTAssertEqual(sim.snapshot.mode, .alternating)
        for _ in 0..<16 { sim.tick(inputs: [.init(hyperspace: true),.init()]) }
        XCTAssertEqual(sim.snapshot.mode, .alternating)
        sim.tick(inputs: [.init(hyperspace: true),.init()])
        XCTAssertEqual(sim.snapshot.mode, .competition)
    }
    func testRotationBothDirectionsCancelAndThrustUsesROM() throws {
        var sim = try steady()
        sim.tick(inputs: [.init(left: true,right: true,thrust: true),.init()])
        XCTAssertEqual(sim.players[0].heading, 0)
        XCTAssertEqual(sim.objects[24].velocityX, 0)
        XCTAssertEqual(sim.objects[24].velocityY, 56) // ROM FF1C=$07, FF3C=$00, with limit logic.
        sim.tick(inputs: [.init(right: true),.init()])
        XCTAssertEqual(sim.players[0].heading, 8)
        XCTAssertEqual(sim.objects[24].image, 0xb5)
    }
    func testDampingAgainstIndependentCarriedByteFormula() {
        for raw in 0...65535 {
            for fraction in [0,127,255] {
                let low = raw & 255, high = raw >> 8
                let shiftLow = low * 2 & 255, shiftHigh = (high * 2 | low >> 7) & 255
                let productLowSum = low + shiftLow
                let adjusted = (high + (high >= 128 ? 1 : 0)) & 255
                let productHigh = (adjusted + shiftHigh + (productLowSum >= 256 ? 1 : 0)) & 255
                let d0 = fraction - (productLowSum & 255)
                let d1 = low - productHigh - (d0 < 0 ? 1 : 0)
                let d2 = adjusted - (d1 < 0 ? 1 : 0)
                let result = Asteroids7800Simulation.damp(UInt16(raw), fraction: UInt8(fraction))
                XCTAssertEqual(Int(result.velocity), (d2 & 255) * 256 + (d1 & 255))
                XCTAssertEqual(Int(result.fraction), d0 & 255)
            }
        }
    }
    func testShotTapFourSlotsAndLifetime() throws {
        var sim = try steady()
        sim.tick(inputs: [.init(),.init()]) // Release start latch.
        sim.tick(inputs: [.init(fire:true),.init()])
        XCTAssertEqual(sim.objects.filter {$0.active && $0.kind == 6}.count, 1)
        for _ in 0..<2 { sim.tick(inputs: [.init(fire:true),.init()]) }
        XCTAssertEqual(sim.objects.filter {$0.active && $0.kind == 6}.count, 1)
        for _ in 0..<3 { sim.tick(inputs: [.init(),.init()]); sim.tick(inputs: [.init(fire:true),.init()]) }
        XCTAssertEqual(sim.objects.filter {$0.active && $0.kind == 6}.count, 4)
        for _ in 0..<20 { sim.tick(inputs: [.init(),.init()]) }
        XCTAssertEqual(sim.objects.filter {$0.active && $0.kind == 6}.count, 0)
    }
    func testSimultaneousShotsArePartitionedByPlayer() throws {
        var sim = try steady(mode:.team)
        sim.tick(inputs: [.init(),.init()]); sim.tick(inputs: [.init(fire:true),.init(fire:true)])
        XCTAssertTrue(sim.objects[28].active); XCTAssertTrue(sim.objects[30].active)
        XCTAssertFalse(sim.objects[29].active); XCTAssertFalse(sim.objects[31].active)
    }
    func testAsteroidSplitsAndAwardsSourceScore() throws {
        var sim = try steady()
        var s = sim.snapshot
        s.objects[0] = .init(code:0x32,x:0x2800,y:0x3000,image:0,palette:0x9d)
        s.objects[28] = .init(code:6,x:0x2d00,y:0x3800,lifetime:236)
        sim = try .init(resources:sim.resources,snapshot:s)
        sim.tick(inputs:[.init(),.init()])
        XCTAssertEqual(sim.players[0].score, 20)
        XCTAssertEqual(sim.objects[0].code, 0xb2)
        XCTAssertEqual(sim.objects.filter {$0.active && $0.kind == 1}.count, 2)
        XCTAssertEqual(sim.players[0].asteroidCount, 3) // Parent counted through its explosion.
        XCTAssertEqual(sim.objects.filter {$0.active && $0.kind == 1}.map(\.palette), [0x9e,0x9e])
    }
    func testNoviceShrinksWithoutMultiplication() throws {
        var sim = try steady(difficulty:0); var s = sim.snapshot
        s.objects[0] = .init(code:0x32,x:0x2800,y:0x3000,image:0,palette:0x9d)
        s.objects[28] = .init(code:6,x:0x2d00,y:0x3800,lifetime:236)
        sim = try .init(resources:sim.resources,snapshot:s); sim.tick(inputs:[.init(),.init()])
        XCTAssertEqual(sim.objects.filter {$0.active && $0.kind == 1}.count, 1)
    }
    func testBonusLifeAndTeamSharedScore() throws {
        for mode in [Asteroids7800Mode.single,.team] {
            var sim = try steady(mode:mode); var s = sim.snapshot
            s.players[0].score = 9980; s.sharedScore = 9980
            s.objects[0] = .init(code:0x32,x:0x2800,y:0x3000,image:0,palette:0x9d)
            s.objects[28] = .init(code:6,x:0x2d00,y:0x3800,lifetime:236)
            sim = try .init(resources:sim.resources,snapshot:s); sim.tick(inputs:[.init(),.init()])
            XCTAssertEqual(sim.players[0].score, 10_000)
            if mode == .team { XCTAssertEqual(sim.snapshot.sharedLives, 7); XCTAssertEqual(sim.players[0].lives,3) }
            else { XCTAssertEqual(sim.players[0].lives,4) }
        }
    }
    func testMovementWrapPreservesFractionAndSaucerException() throws {
        var sim = try steady(); var s = sim.snapshot
        s.objects[0].x = 0x9eff; s.objects[0].velocityX = 0x0130
        s.objects[0].y = 0xbeff; s.objects[0].velocityY = 0x0130
        sim = try .init(resources:sim.resources,snapshot:s); sim.tick(inputs:[.init(),.init()])
        XCTAssertEqual(sim.objects[0].x,0x002f); XCTAssertEqual(sim.objects[0].y,0x002f)
    }
    func testHyperspaceHidesAndSafeReentryOrFailure() throws {
        var sim = try steady()
        sim.tick(inputs:[.init(hyperspace:true),.init()])
        XCTAssertEqual(sim.players[0].phase,2); XCTAssertEqual(sim.players[0].timer,44)
        for _ in 0..<3 { sim.tick(inputs:[.init(),.init()]) }
        XCTAssertEqual(sim.objects[24].code,255)
        for _ in 0..<40 { sim.tick(inputs:[.init(),.init()]) }
        XCTAssertTrue([0,3].contains(Int(sim.players[0].phase)))
    }
    func testPauseFreezesClockAndSnapshotRestoresSequence() throws {
        var sim = try steady(); sim.tick(inputs:[.init(),.init()], console:.init(pause:true))
        XCTAssertEqual(sim.snapshot.screen,.paused)
        sim.tick(inputs:[.init(),.init()]) // Observe release while paused.
        let saved = sim.snapshot
        for _ in 0..<100 { sim.tick(inputs:[.init(thrust:true),.init()]) }
        XCTAssertEqual(sim.snapshot,saved)
        let bytes = try JSONEncoder().encode(saved)
        var restored = try Asteroids7800Simulation(resources:sim.resources,snapshot:JSONDecoder().decode(Asteroids7800Snapshot.self,from:bytes))
        sim.tick(inputs:[.init(),.init()],console:.init(pause:false))
        restored.tick(inputs:[.init(),.init()],console:.init(pause:false))
        sim.tick(inputs:[.init(),.init()],console:.init(pause:true))
        restored.tick(inputs:[.init(),.init()],console:.init(pause:true))
        for _ in 0..<200 { sim.tick(inputs:[.init(thrust:true,fire:true),.init()]); restored.tick(inputs:[.init(thrust:true,fire:true),.init()]) }
        XCTAssertEqual(sim.snapshot,restored.snapshot)
    }
    func testSnapshotRejectsMalformedOrDifferentSource() throws {
        let sim = try simulation(); var s = sim.snapshot
        s.sourceSHA256 = String(repeating:"0",count:64)
        XCTAssertThrowsError(try Asteroids7800Simulation(resources:sim.resources,snapshot:s))
        s = sim.snapshot; s.objects[0].code = 7
        XCTAssertThrowsError(try Asteroids7800Simulation(resources:sim.resources,snapshot:s))
        s = sim.snapshot; s.ufoAim = 255
        XCTAssertThrowsError(try Asteroids7800Simulation(resources:sim.resources,snapshot:s))
    }
    func testLongDeterministicAllModesStayBounded() throws {
        for mode in Asteroids7800Mode.allCases {
            var sim = try simulation(); try sim.configure(mode:mode,difficulty:3); sim.start()
            for frame in 0..<10_000 {
                let first = Asteroids7800Input(right:frame%7==0,thrust:frame%5<3,fire:frame%2==0)
                let second = Asteroids7800Input(left:frame%9==0,thrust:frame%5<2,fire:frame%3==0)
                sim.tick(inputs:[first,second]); _ = sim.takeEvents()
            }
            XCTAssertEqual(sim.objects.count,33)
            XCTAssertLessThanOrEqual(sim.snapshot.events.count,128)
            XCTAssertNoThrow(try Asteroids7800Simulation(resources:sim.resources,snapshot:sim.snapshot))
        }
    }
}
