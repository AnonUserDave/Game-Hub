import Foundation
import XCTest
@testable import GameHub

final class PGAOriginalPlayableTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    // One load is shared: building 18 floor indexes is the expensive part.
    private static let pebble: Result<PGAOriginalPlayableCourse, Error>? = {
        let terrain = repository.appendingPathComponent("Library/Imported/pga2005/PBL/terrain.ghpc")
        guard FileManager.default.fileExists(atPath: terrain.path) else { return nil }
        return Result { try PGAOriginalPlayableCourse.load(code: "PBL", root: repository) }
    }()
    private func pebbleCourse() throws -> PGAOriginalPlayableCourse {
        guard let pebble = Self.pebble else { throw XCTSkip("Original PBL data not prepared; run Tools/prepare_pga2005.py") }
        return try pebble.get()
    }

    func testStandardSelectorMatchesOriginalAddVisiblePatchPredicate() {
        let standard = PGACourseConditions.standard
        XCTAssertEqual(standard.selector, 0x420)
        XCTAssertTrue(standard.includes(layer: 0x0001, hole: 1), "Base patches always load")
        XCTAssertFalse(standard.includes(layer: 0x0002, hole: 1), "Another hole's world never leaks in")
        // Level 0 keeps every fairway band (0x20 bit) and drops their rough complements.
        for band: UInt32 in [0x20, 0x60, 0xe0, 0x1e0] { XCTAssertTrue(standard.includes(layer: band | 7, hole: 7)) }
        for rough: UInt32 in [0x3c0, 0x380, 0x300, 0x200] { XCTAssertFalse(standard.includes(layer: rough | 7, hole: 7)) }
        // Largest green: every ring holding 0x400; the fairway-ring variants drop out.
        for ring: UInt32 in [0x400, 0xc00, 0x1c00, 0x3c00, 0x7c00] { XCTAssertTrue(standard.includes(layer: ring | 7, hole: 7)) }
        for ring: UInt32 in [0x4000, 0x6000, 0x7000, 0x7800] { XCTAssertFalse(standard.includes(layer: ring | 7, hole: 7)) }
        XCTAssertFalse(standard.includes(layer: 0x8001, hole: 1), "0x8000 is never selected in standard play")
        // Composite levels select one bit per group, and complements cover each gap once.
        let composite = PGACourseConditions.composite(fairwayLevel: 2, greenLevel: 1)
        XCTAssertEqual(composite.selector, 0x80 | 0x800)
        for pair: (UInt32, UInt32) in [(0x20, 0x3c0), (0x60, 0x380), (0xe0, 0x300), (0x1e0, 0x200)] {
            for level in 0..<5 {
                let c = PGACourseConditions.composite(fairwayLevel: level, greenLevel: 0)
                XCTAssertNotEqual(c.includes(layer: pair.0 | 3, hole: 3), c.includes(layer: pair.1 | 3, hole: 3))
            }
        }
    }

    func testTransformRoundTripsAndMirrorsLeftHandedSource() {
        let transform = PGACourseTransform(origin: PGAVector(x: 1000, y: 80000, z: -500))
        let raw = PGAVector(x: 77816.2265625, y: 84046.78125, z: 77672.8984375)
        let meters = transform.meters(raw: raw)
        let back = transform.raw(meters: meters)
        XCTAssertEqual(back.x, raw.x, accuracy: 1e-6); XCTAssertEqual(back.y, raw.y, accuracy: 1e-6); XCTAssertEqual(back.z, raw.z, accuracy: 1e-6)
        XCTAssertEqual(meters.x, (raw.x - 1000) * 0.0254, accuracy: 1e-9)
        XCTAssertEqual(meters.z, -(raw.z + 500) * 0.0254, accuracy: 1e-9, "Source +Z maps to SceneKit -Z")
        // A left-handed source "right" of travel stays on the right after mirroring.
        let forward = PGAVector(x: 0, y: 0, z: 1), sourceRight = PGAVector(x: 1, y: 0, z: 0)
        let f = transform.direction(raw: forward), r = transform.direction(raw: sourceRight)
        let up = PGAVector(x: f.y * r.z - f.z * r.y, y: f.z * r.x - f.x * r.z, z: f.x * r.y - f.y * r.x)
        XCTAssertLessThan(up.y, 0, "In right-handed space, forward × right points down")
    }

    func testOriginalFlagBitsMapToCategoriesAndRecordsDriveLies() {
        let samples: [(UInt32, PGASurface)] = [(0x201, .fairway), (0x202, .rough), (0x8000_0200, .rough), (0x4, .green), (0x210, .fringe),
                                               (0x1200, .tee), (0x208, .sand), (0x960, .water), (0x2420, .unplayable), (0x120, .unplayable),
                                               (0x80, .out), (0, .unplayable)]
        for (flags, surface) in samples { XCTAssertEqual(PGASurfaceProperties.classify(flags: flags), surface, String(format: "0x%x", flags)) }
        func record(_ label: String, _ flags: UInt32, power: Double, rolling: Double = 0.9) -> PGASurfaceProperties.Record {
            .init(label: label, flags: flags, coefficients: [power, 0.7, 0.06, 0.15, 0.725, 0.725, 0.375, rolling, 40, 0.3])
        }
        let rough = PGASurfaceProperties(materialID: 2, materialName: "pbl_rough.tga", sectionFlags: 0x8002,
                                         records: [record("Md Rough", 0x202, power: 0.8), record("Lt Rough", 0x202, power: 0.9), record("Dp Rough", 0x202, power: 0.7)])
        XCTAssertEqual(rough.category, "Rough", "No single record label, so the category is shown")
        XCTAssertEqual(rough.label(2), "Dp Rough")
        XCTAssertEqual(rough.lieRecord(1)?.power, 0.9)
        XCTAssertEqual(rough.rollingDeceleration(normalY: 1), 9.81 * 5 / 7 * 0.9, accuracy: 1e-9, "PureRolling g·n_y·(5/7)·c7")
        let green = PGASurfaceProperties(materialID: 6, materialName: "pbl_green.tga", sectionFlags: 2, records: [record("Green", 0x4, power: 0.975, rolling: 0.2)])
        XCTAssertEqual(green.rollingDeceleration(normalY: 1), 9.81 * 5 / 7 * 0.2 * 0.575, accuracy: 1e-9, "Greens ×0.575")
        // Blend strips store texture indices in record 0; launch power falls back to a usable record.
        let blend = PGASurfaceProperties(materialID: 13, materialName: "pbl_bunker_rough.tga", sectionFlags: 0x8c1,
                                         records: [record("pbl_bunke", 0x208, power: 1e-44), record("pbl_bunke", 0x208, power: 0.95)])
        XCTAssertTrue(blend.isBlend)
        XCTAssertEqual(blend.lieRecord(0)?.power, 0.95)
        XCTAssertEqual(blend.label(0), "Bunker", "Truncated texture names are not original lie text")
        let road = PGASurfaceProperties(materialID: 3, materialName: "pbl_road.tga", sectionFlags: 0x88042, records: [record("Unplayable", 0x2420, power: 1)])
        XCTAssertTrue(road.freeDrop)
        let cliff = PGASurfaceProperties(materialID: 14, materialName: "tbcliff.tga", sectionFlags: 0x20002, records: [record("Unplayable", 0x120, power: 0.75)])
        XCTAssertFalse(cliff.freeDrop)
    }

    func testStandardSelectionLoadsTheOriginalPatchCount() throws {
        let pebble = try pebbleCourse()
        let loaded = pebble.data.patches.filter { patch in (1...18).contains { pebble.conditions.includes(layer: patch.layer, hole: $0) } }.count
        XCTAssertEqual(pebble.data.patches.count, 6_943)
        XCTAssertEqual(loaded, 6_609, "CHole::Load with 0x420 keeps 6,609 PBL patches")
    }

    func testPebbleBeachHasEighteenHolesWithTeesOnTeeBoxesAndPinsOnGreens() throws {
        let pebble = try pebbleCourse()
        XCTAssertEqual(pebble.course.holes.count, 18)
        XCTAssertEqual(pebble.course.holes.map(\.par).reduce(0, +), 72)
        XCTAssertTrue(pebble.course.isOriginal)
        XCTAssertTrue(pebble.course.identity.hasPrefix("pga2005-PBL-"))
        for check in pebble.validation {
            XCTAssertEqual(check.teeSurface, .tee, "Hole \(check.hole) tee")
            XCTAssertEqual(check.pinSurface, .green, "Hole \(check.hole) pin")
            if check.hole != 8 { XCTAssertLessThan(abs(check.teeHeightErrorInches), 3, "Hole \(check.hole) authored tee height") }
            XCTAssertGreaterThan(check.triangles, 20_000)
        }
        // Tee index 3 matches the championship card in the original INI.
        XCTAssertEqual(pebble.course.holes.compactMap { $0.source?.scorecardYards }, [376, 502, 374, 327, 187, 500, 106, 416, 462, 430, 373, 201, 393, 572, 396, 401, 178, 543])
        for (index, hole) in pebble.course.holes.enumerated() {
            let yards = Double(hole.source?.scorecardYards ?? 0)
            let straight = hole.length * 1.09361
            XCTAssertLessThan(straight, yards * 1.3 + 10, "Hole \(index + 1) geometry is in yards scale (pin 0 may sit off the card reference)")
            XCTAssertGreaterThan(straight, yards * 0.7, "Hole \(index + 1) geometry is in yards scale")
        }
    }

    func testOceanSidesMatchRealPebbleCoast() throws {
        let pebble = try pebbleCourse()
        // Real Pebble Beach: Carmel Bay right of holes 9 and 10, left of 18.
        func oceanSide(_ index: Int) -> Double {
            let hole = pebble.course.holes[index], terrain = pebble.terrains[index]
            var balance = 0.0
            for (a, b) in zip(hole.centerline, hole.centerline.dropFirst()) {
                let d = b - a, length = d.horizontalLength
                guard length > 1 else { continue }
                let forward = d * (1 / length), right = PGAVector(x: -forward.z, y: 0, z: forward.x)
                for along in stride(from: 0.0, to: length, by: 10) {
                    for lateral in stride(from: -110.0, through: 110, by: 10) where lateral != 0 {
                        let p = a + forward * along + right * lateral
                        if terrain.ground(x: p.x, z: p.z, ceiling: .infinity)?.surface == .water { balance += lateral > 0 ? 1 : -1 }
                    }
                }
            }
            return balance
        }
        XCTAssertGreaterThan(oceanSide(8), 0); XCTAssertGreaterThan(oceanSide(9), 0)
        XCTAssertLessThan(oceanSide(17), 0)
    }

    func testEveryHoleSettlesDeterministicallyOnOriginalFloor() throws {
        let pebble = try pebbleCourse()
        var game = PGASimulation(course: pebble.course, terrains: pebble.terrains)
        var twin = game
        for index in 0..<18 {
            XCTAssertEqual(game.holeIndex, index)
            XCTAssertEqual(game.lie, .tee, "Hole \(index + 1) starts on its tee box")
            game.strike(power: 0.9, accuracy: 0.1); twin.strike(power: 0.9, accuracy: 0.1)
            var steps = 0
            while game.phase.inMotion && steps < 8000 {
                game.update(deltaTime: 1.0 / 60); twin.update(deltaTime: 1.0 / 30); twin.update(deltaTime: 0)
                if let floor = game.ground(x: game.ball.x, z: game.ball.z, ceiling: game.ball.y + 0.05) {
                    XCTAssertGreaterThanOrEqual(game.ball.y, floor.height + PGASimulation.ballRadius - 0.02, "Hole \(index + 1) ball stays above its floor")
                }
                steps += 1
            }
            while twin.phase.inMotion { twin.update(deltaTime: 1.0 / 30) }
            XCTAssertLessThan(steps, 8000, "Hole \(index + 1) shot finishes")
            XCTAssertEqual(game.ball.x, twin.ball.x, accuracy: 1e-6, "Fixed step is independent of frame rate")
            XCTAssertEqual(game.ball.z, twin.ball.z, accuracy: 1e-6)
            XCTAssertTrue(game.lie.playable || game.phase == .aiming, "Hole \(index + 1) ends on a playable lie or replays")
            // Hand the ball to the cup to advance through the whole round.
            game = Self.holeOut(game); twin = Self.holeOut(twin)
        }
        XCTAssertEqual(game.phase, .roundComplete)
        XCTAssertEqual(game.scores.count, 18)
    }

    private static func holeOut(_ game: PGASimulation) -> PGASimulation {
        var game = game
        var attempts = 0
        while game.phase == .aiming && attempts < 40 {
            game.selectClub(game.distanceToCup > 25 ? .wedge : .putter)
            game.alignToCup()
            let power = game.club == .putter ? min(1, sqrt(2 * PGASurface.green.rollingFriction * game.distanceToCup) / PGAClub.putter.speed) : min(1, game.distanceToCup / 100)
            game.strike(power: power, accuracy: 0)
            while game.phase.inMotion { game.update(deltaTime: 1.0 / 60) }
            attempts += 1
        }
        game.continueRound()
        return game
    }

    func testWindArrowFollowsTheOriginalSixteenDirections() {
        XCTAssertEqual(PGAWind(mph: 10, direction: 0.3).arrowIndex(heading: 0.3), 1, "tailwind points up the screen")
        XCTAssertEqual(PGAWind(mph: 10, direction: 0.3 + .pi).arrowIndex(heading: 0.3), 9, "headwind points down")
        // Our right of travel for heading h is (−cos h, 0, sin h), i.e. heading h − π/2.
        XCTAssertEqual(PGAWind(mph: 10, direction: -.pi / 2).arrowIndex(heading: 0), 5, "left-to-right wind points right")
        XCTAssertEqual(PGAWind(mph: 10, direction: .pi / 2).arrowIndex(heading: 0), 13)
        // Original Wind1 rows: even "Still" moves the air a little.
        XCTAssertEqual(PGAConditions().windRow.normal, 0.86...2.3)
        XCTAssertEqual(PGAConditions(windSpeed: 5).windRow.gust, 18...34)
        XCTAssertEqual(PGAConditions(windSpeed: 4).windRow.gustChance, 0.51)
    }

    func testConditionsReachTheReconstructedFlight() throws {
        let course = try pebbleCourse()
        var setup = PGARoundSetup(); setup.teeIndex = 3
        let base = try course.course(for: setup)
        func carry(_ wind: PGAWind?, greens: Int = 3) -> Double {
            var game = PGASimulation(course: base, terrains: course.terrains)
            var conditions = PGAConditions(); conditions.windSpeed = wind == nil ? 1 : 5; conditions.greenSpeed = greens
            game.conditions = conditions
            game.resetHole()
            game.alignToCup(); game.selectClub(.iron7)
            game.overrideWindForTest(wind.map { PGAWind(mph: $0.mph, direction: game.heading + $0.direction) } ?? .still)
            XCTAssertEqual(game.wind.mph, wind?.mph ?? 0)
            game.strike(power: 1, accuracy: 0)
            for _ in 0..<3000 where game.phase.inMotion { game.update(deltaTime: 1.0 / 60) }
            XCTAssertEqual(game.phase, .aiming)
            return game.lastShotDistance
        }
        let still = carry(nil), tail = carry(PGAWind(mph: 25, direction: 0)), head = carry(PGAWind(mph: 25, direction: .pi))
        XCTAssertGreaterThan(tail, still * 1.04, "tailwind carries further")
        XCTAssertLessThan(head, still * 0.96, "headwind holds the ball up")
    }

    func testWindFollowsTheOriginalTableBetweenShots() throws {
        let course = try pebbleCourse()
        let base = try course.course(for: PGARoundSetup())
        var game = PGASimulation(course: base, terrains: course.terrains)
        var conditions = PGAConditions(); conditions.windSpeed = 3; conditions.windSeed = 77
        game.conditions = conditions
        var directions: [Double] = [], speeds: Set<Double> = []
        for hole in 0..<18 {
            _ = hole
            let row = conditions.windRow
            XCTAssertTrue(row.normal.contains(game.wind.mph) || row.gust.contains(game.wind.mph) || game.wind.mph == row.normal.lowerBound.rounded(.towardZero))
            XCTAssertEqual(game.wind.mph, game.wind.mph.rounded(.towardZero), "integer mph, as ForecastWind stores")
            directions.append(game.wind.direction); speeds.insert(game.wind.mph)
            game.restoreHoleForTest(strokes: 4)
        }
        // Directions swing about one fixed base: at most ±36° (Breezy gusts) apart from each other's centre.
        let spread = directions.max()! - directions.min()!
        XCTAssertLessThanOrEqual(spread, 2 * 36 * .pi / 180 + 1e-9)
        XCTAssertGreaterThan(speeds.count, 1, "wind re-rolls between shots")
        // Restoring a round reproduces the shot's wind.
        var replay = PGASimulation(course: base, terrains: course.terrains)
        replay.conditions = conditions
        let first = replay.wind
        var again = PGASimulation(course: base, terrains: course.terrains)
        again.conditions = conditions
        XCTAssertEqual(again.wind, first)
    }

    func testIntersectLineCodesFollowUtilsDLL() {
        let s = { (x: Double, y: Double) in SIMD2(x, y) }
        XCTAssertEqual(PGAHoleBoundaries.intersect(s(0, 0), s(10, 10), s(0, 10), s(10, 0)), 1, "proper crossing")
        XCTAssertEqual(PGAHoleBoundaries.intersect(s(0, 0), s(10, 0), s(20, -5), s(20, 5)), 0, "beyond the segment")
        XCTAssertEqual(PGAHoleBoundaries.intersect(s(0, 0), s(5, 5), s(0, 10), s(10, 0)), 3, "ending exactly on the line")
        XCTAssertEqual(PGAHoleBoundaries.intersect(s(0, 0), s(10, 10), s(5, 5), s(10, 0)), 4, "through the line's start")
        XCTAssertEqual(PGAHoleBoundaries.intersect(s(0, 0), s(10, 0), s(0, 1), s(10, 1)), 0, "parallel")
    }

    func testOriginalLinesKeepThePlayAreaInPlay() throws {
        let course = try pebbleCourse()
        for (index, source) in course.data.holes.enumerated() {
            let hole = course.course.holes[index]
            let lines = try XCTUnwrap(hole.boundaries, "hole \(index + 1) has OB lines")
            for pin in source.pins { XCTAssertEqual(lines.check(course.transform.meters(raw: pin)), 0, "hole \(index + 1) pin in play") }
            for aim in source.aimPoints { XCTAssertEqual(lines.check(course.transform.meters(raw: aim)), 0) }
            XCTAssertEqual(lines.check(hole.tee), 0, "hole \(index + 1) selected tee in play")
        }
        // Far off to the side of hole 1 is out of bounds.
        let one = course.course.holes[0], along = (one.cup - one.tee).horizontalUnit
        let side = PGAVector(x: -along.z, y: 0, z: along.x)
        let flags = [one.tee + side * 400, one.tee - side * 400].map { one.boundaries!.check($0) }
        XCTAssertTrue(flags.contains(PGAHoleBoundaries.outOfBounds), "\(flags)")
    }

    func testOceanShotOnEighteenDropsBackWithOnePenalty() throws {
        let course = try pebbleCourse()
        var setup = PGARoundSetup(); setup.teeIndex = 3
        let base = try course.course(for: setup)
        var game = PGASimulation(course: base, terrains: course.terrains)
        game.restoreHoleForTest(strokes: 4)
        for _ in 0..<16 { game.restoreHoleForTest(strokes: 4) }
        XCTAssertEqual(game.holeIndex, 17)
        game.alignToCup(); game.selectClub(.iron7)
        game.aim(0.6)   // positive aim turns left: into Carmel Bay
        game.strike(power: 1, accuracy: 0)
        for _ in 0..<4000 where game.phase.inMotion { game.update(deltaTime: 1.0 / 60) }
        XCTAssertEqual(game.phase, .aiming)
        XCTAssertEqual(game.strokes, 2, "the stroke played plus one penalty")
        XCTAssertTrue(game.lie.playable, "dropped on a playable lie: \(game.lieLabel)")
        XCTAssertEqual(game.hole.boundaries?.check(game.ball), 0)
        XCTAssertTrue(game.message.hasPrefix("Water hazard"), game.message)
    }

    func testOriginalPinRotationAndTeeSets() {
        var setup = PGARoundSetup()
        XCTAssertEqual(setup.teeIndex, 2, "Amateur tees by default, as CGameSettings")
        XCTAssertEqual(PGARoundSetup.offeredTees, 0..<4)
        setup.pins = .varied; setup.seed = 123
        let pins = setup.pinIndices(holeCount: 18, available: Array(repeating: 10, count: 18))
        XCTAssertTrue(pins.allSatisfy { [1, 3, 5, 7, 9].contains($0) }, "(byte % 5) * 2 + 1 for pin type 0: \(pins)")
        XCTAssertGreaterThan(Set(pins).count, 1)
        XCTAssertTrue(setup.pinIndices(holeCount: 2, available: [1, 4]).enumerated().allSatisfy { $1 < [1, 4][$0] }, "clamped to the hole's pins")
        XCTAssertEqual(setup.pinIndices(holeCount: 1, available: [1]), [0])
    }

    func testRoundSetupKeepsConditionsAcrossSaves() throws {
        var setup = PGARoundSetup()
        setup.conditions = PGAConditions(greenSpeed: 5, roughLength: 3, windSpeed: 4, windSeed: 4242)
        let decoded = try JSONDecoder().decode(PGARoundSetup.self, from: JSONEncoder().encode(setup))
        XCTAssertEqual(decoded.conditions, setup.conditions)
        let old = try JSONDecoder().decode(PGARoundSetup.self, from: Data(#"{"players":["A"],"teeIndex":3,"pins":"standard","seed":1}"#.utf8))
        XCTAssertNil(old.conditions, "rounds saved before conditions use the course defaults")
        setup.conditions?.windSpeed = 9
        XCTAssertFalse(setup.valid)
    }

    func testSnapshotRestoresOnlyOntoMatchingCourseData() throws {
        let pebble = try pebbleCourse()
        var game = PGASimulation(course: pebble.course, terrains: pebble.terrains)
        game.strike(power: 0.7, accuracy: 0)
        while game.phase.inMotion { game.update(deltaTime: 1.0 / 60) }
        let snapshot = try XCTUnwrap(game.snapshot)
        let encoded = try JSONEncoder().encode(snapshot)
        var restored = PGASimulation(course: pebble.course, terrains: pebble.terrains)
        try restored.restore(try JSONDecoder().decode(PGARoundSnapshot.self, from: encoded))
        XCTAssertEqual(restored.ball, game.ball)
        XCTAssertEqual(restored.strokes, game.strokes)
        XCTAssertEqual(restored.lie, game.lie)
        var practice = PGASimulation()
        XCTAssertThrowsError(try practice.restore(snapshot)) { XCTAssertEqual($0 as? PGASimulation.RestoreError, .mismatchedCourse) }
        var floating = snapshot; floating.ball.y += 5
        XCTAssertThrowsError(try restored.restore(floating))
    }
}
