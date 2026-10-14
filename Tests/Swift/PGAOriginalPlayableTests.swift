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

    func testConditionMasksSelectOneVariantPerGroupAndOnlyTheHole() {
        let conditions = PGACourseConditions(fairwayLevel: 2, greenLevel: 1, includeLayer8000: false)
        XCTAssertTrue(conditions.includes(layer: 0x0001, hole: 1))
        XCTAssertFalse(conditions.includes(layer: 0x0002, hole: 1), "Another hole's world never leaks in")
        // Fairway level 2 selects bit 0x80: bands 0xE0/0x1E0 stay fairway and
        // their complements 0x300/0x200 are excluded.
        XCTAssertTrue(conditions.includes(layer: 0x00e1, hole: 1))
        XCTAssertFalse(conditions.includes(layer: 0x0301, hole: 1))
        XCTAssertFalse(conditions.includes(layer: 0x0061, hole: 1))
        XCTAssertTrue(conditions.includes(layer: 0x0381, hole: 1))
        for pair: (UInt32, UInt32) in [(0x20, 0x3c0), (0x60, 0x380), (0xe0, 0x300), (0x1e0, 0x200)] {
            for level in 0..<5 {
                let c = PGACourseConditions(fairwayLevel: level, greenLevel: 0, includeLayer8000: true)
                XCTAssertNotEqual(c.includes(layer: pair.0 | 3, hole: 3), c.includes(layer: pair.1 | 3, hole: 3),
                                  "Complementary bands cover a gap exactly once")
            }
        }
        // Green level 1 selects bit 0x800.
        XCTAssertTrue(conditions.includes(layer: 0x0c01, hole: 1))
        XCTAssertFalse(conditions.includes(layer: 0x0401, hole: 1))
        XCTAssertFalse(conditions.includes(layer: 0x8001, hole: 1))
        XCTAssertTrue(PGACourseConditions.development.includes(layer: 0x8001, hole: 1))
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

    func testOriginalFlagBitsMapToProvisionalCategories() {
        let samples: [(UInt32, PGASurface)] = [(0x201, .fairway), (0x202, .rough), (0x8000_0200, .rough), (0x4, .green), (0x210, .fringe),
                                               (0x1200, .tee), (0x208, .sand), (0x960, .water), (0x2420, .unplayable), (0x120, .unplayable), (0, .unplayable)]
        for (flags, surface) in samples { XCTAssertEqual(PGAOriginalSurfaceClass.classify(flags: flags), surface, String(format: "0x%x", flags)) }
        let rough = PGAOriginalSurfaceClass(materialName: "pbl_rough.tga", records: ["Md Rough", "Lt Rough", "Dp Rough"].map { .init(name: $0, flags: 0x202, coefficients: []) })
        XCTAssertEqual(rough.lie, "Rough", "Unresolved record choice falls back to the category label")
        let fringe = PGAOriginalSurfaceClass(materialName: "pbl_green_fringe.tga", records: [.init(name: "Fringe", flags: 0x210, coefficients: [])])
        XCTAssertEqual(fringe.lie, "Fringe")
        let truncated = PGAOriginalSurfaceClass(materialName: "pbl_teebox_rough1.tga", records: [.init(name: "pbl_teebo", flags: 0x202, coefficients: [])])
        XCTAssertEqual(truncated.lie, "Rough", "Truncated texture names are not original lie text")
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
