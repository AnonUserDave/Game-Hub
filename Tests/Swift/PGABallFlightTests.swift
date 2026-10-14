import Foundation
import XCTest
@testable import GameHub

/// Golden comparisons of the Swift ball flight (PGABallFlight.swift) against
/// the Python reference (Tools/pga2005_ballflight_reference.py) through
/// Tests/Fixtures/pga2005_ballflight_golden.json, written by
/// Tools/make_ballflight_fixtures.py. Both implement the same static
/// reconstruction; neither is runtime evidence of the original game.
final class PGABallFlightTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    // Tolerances (inches, or inches per tick for velocities). Swift mirrors
    // the reference's operation order and f32 stores and uses the same libm,
    // so results agree to rounding; these bounds leave room for libm or
    // compiler differences without hiding a porting error (≪ 0.5% / 1 in).
    private static let distanceTolerance = 0.01      // carry, total, roll, apex, positions
    private static let velocityTolerance = 1e-6      // launch and final velocity, spin

    // MARK: Fixture

    struct Fixture: Decodable {
        struct Tables: Decodable { var speed, launch, pitch, spin, caddy_max_distance: [Double] }
        struct Power: Decodable { var club: Int; var difficulty: Int; var power: Double }
        struct Conditions: Decodable {
            var green_cond: Int; var rough_length: Int; var difficulty: Int?
            var wet: Double; var rough: Double; var magnet: Double
        }
        struct Consider: Decodable {
            var surface: String; var lie_index: Int; var rough: Double; var sand: Double; var magnet: Double
            var record: String; var factor: Double
        }
        struct Scenario: Decodable {
            struct Launch: Decodable {
                var club: Int; var power: Double
                var path: Double?; var face: Double?; var loft_adjust: Double?; var launch_adjust: Double?
                var spin_mult: Double?; var sand_blend: Double?; var lie_comp: Double?; var aim: Double?
                var aim_offset: Double?; var shot_type: Int?; var lie_index: Int?; var position: [Double]?
            }
            struct Region: Decodable { var axis: String; var min: Double?; var max: Double?; var surface: String }
            struct Terrain: Decodable {
                var surface: String; var height: Double?; var slope: [Double]?; var regions: [Region]?; var max_z: Double?
            }
            struct ConditionValues: Decodable { var wet: Double; var rough: Double; var sand: Double; var wind_mph: [Double]; var magnet: Double }
            struct Result: Decodable {
                var carry: Double; var total: Double; var roll: Double; var apex: Double
                var ticks: Int; var first_bounce_tick: Int?
                var holed: Bool; var touched_cup: Bool; var out_of_world: Bool
                var next_lie_index: Int?; var bounces: Int; var end_state: Int; var end_surface: String?
                var final_position: [Double]; var final_velocity: [Double]
                var launch_velocity: [Double]; var launch_spin: [Double]
                var events: [String]; var samples: [[Double]]
            }
            var name: String
            var launch: Launch
            var terrain: Terrain
            var conditions: ConditionValues
            var ball: Int
            var fps: Int
            var pin: [Double]?
            var seed: UInt64
            var result: Result
        }
        var schema_version: Int
        var tables: Tables
        var full_swing_power: [Power]
        var conditions: [Conditions]
        var consider_terrain: [Consider]
        var scenarios: [Scenario]
    }

    private static let fixture: Result<Fixture, Error> = Result {
        let url = repository.appendingPathComponent("Tests/Fixtures/pga2005_ballflight_golden.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func loadFixture() throws -> Fixture {
        let fixture = try Self.fixture.get()
        XCTAssertEqual(fixture.schema_version, 1)
        return fixture
    }

    private static func vector(_ values: [Double]) -> PGABallVector { PGABallVector(values[0], values[1], values[2]) }

    private static func surface(_ name: String) throws -> PGABallSurface {
        try XCTUnwrap(PGABallSurface.pebbleBeach[name], "Unknown fixture surface \(name)")
    }

    private static func terrain(_ spec: Fixture.Scenario.Terrain) throws -> PGABallPlaneTerrain {
        let regions = try (spec.regions ?? []).map { region in
            PGABallPlaneTerrain.Region(axis: region.axis == "x" ? .x : .z, lower: region.min ?? -.infinity,
                                       upper: region.max ?? .infinity, surface: try surface(region.surface))
        }
        return PGABallPlaneTerrain(surface: try surface(spec.surface), height: spec.height ?? 0, slopeX: spec.slope?[0] ?? 0,
                                   slopeZ: spec.slope?[1] ?? 0, regions: regions, maximumZ: spec.max_z)
    }

    private static func launch(_ spec: Fixture.Scenario.Launch) -> PGABallLaunch {
        PGABallLaunch(club: spec.club, power: spec.power, path: spec.path ?? 0, face: spec.face ?? 0, loftAdjust: spec.loft_adjust ?? 0,
                      launchAdjust: spec.launch_adjust ?? 0, spinMultiplier: spec.spin_mult ?? 1, sandBlend: spec.sand_blend ?? 0,
                      lieCompensation: spec.lie_comp ?? 0, aim: spec.aim ?? 0, aimOffset: spec.aim_offset ?? 0,
                      shotType: spec.shot_type ?? 0, lieIndex: spec.lie_index ?? 0, position: spec.position.map(vector) ?? .zero)
    }

    private static func run(_ scenario: Fixture.Scenario) throws -> PGABallShotResult {
        let c = scenario.conditions
        let conditions = PGABallConditions(wet: c.wet, rough: c.rough, sand: c.sand, windX: c.wind_mph[0], windZ: c.wind_mph[1], magnet: c.magnet)
        return try XCTUnwrap(PGABallFlight.simulate(launch: launch(scenario.launch), terrain: try terrain(scenario.terrain),
                                                    conditions: conditions, ball: .type(scenario.ball), fps: scenario.fps,
                                                    pin: scenario.pin.map(vector), random: PGARandom(state: scenario.seed)),
                             scenario.name)
    }

    private static func kinds(_ events: [PGABallFlightEvent]) -> [String] {
        events.compactMap { event in
            switch event {
            case .spinKick: return "spin_kick"
            case .holed: return "holed"
            case let .cupContact(rim, _): return rim ? "cup_rim" : "cup_wall"
            case .tree: return "tree"
            default: return nil
            }
        }
    }

    // MARK: Golden comparisons

    func testClubTablesAndConstantsMatchReference() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(PGABallFlight.speedTable, fixture.tables.speed)
        XCTAssertEqual(PGABallFlight.launchTable, fixture.tables.launch)
        XCTAssertEqual(PGABallFlight.pitchTable, fixture.tables.pitch)
        XCTAssertEqual(PGABallFlight.spinTable, fixture.tables.spin)
        XCTAssertEqual(PGABallFlight.caddyMaxDistance, fixture.tables.caddy_max_distance)
        XCTAssertEqual(PGABallFlight.gravity60Hz * 3600 * 0.0254, 9.80, accuracy: 0.005)
        XCTAssertEqual(PGABallFlight.ballInertia, 0.4 * PGABallFlight.ballMass * PGABallFlight.ballRadiusSquared, accuracy: 1e-7)
        XCTAssertEqual(PGAOriginalClub.putter.rawValue, 20)
        XCTAssertEqual(PGAOriginalClub.iron1.bunkerIndex, 33)
        XCTAssertNil(PGAOriginalClub.putter.bunkerIndex)
    }

    func testSwingPowerConditionsAndConsiderTerrainMatchReference() throws {
        let fixture = try loadFixture()
        for entry in fixture.full_swing_power {
            XCTAssertEqual(PGABallSwing.fullSwingPower(club: entry.club, difficulty: entry.difficulty), entry.power,
                           "club \(entry.club) difficulty \(entry.difficulty)")
        }
        for entry in fixture.conditions {
            let c = PGABallConditions.fromSettings(greenCondition: entry.green_cond, roughLength: entry.rough_length, difficulty: entry.difficulty)
            let label = "green \(entry.green_cond) rough \(entry.rough_length) difficulty \(String(describing: entry.difficulty))"
            XCTAssertEqual(c.wet, entry.wet, label); XCTAssertEqual(c.rough, entry.rough, label); XCTAssertEqual(c.magnet, entry.magnet, label)
        }
        for entry in fixture.consider_terrain {
            let result = PGABallFlight.considerTerrain(surface: try Self.surface(entry.surface), lieIndex: entry.lie_index,
                                                       rough: entry.rough, sand: entry.sand, magnet: entry.magnet)
            let label = "\(entry.surface) lie \(entry.lie_index) rough \(entry.rough)"
            XCTAssertEqual(result.record.name, entry.record, label)
            XCTAssertEqual(result.factor, entry.factor, label)
        }
    }

    func testGoldenScenariosMatchPythonReference() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.scenarios.count, 100)
        var worstDistance = (0.0, ""), worstVelocity = (0.0, ""), bitIdentical = 0
        for scenario in fixture.scenarios {
            let name = scenario.name, expected = scenario.result
            let result = try Self.run(scenario)
            func distance(_ actual: Double, _ wanted: Double, _ what: String) {
                let error = abs(actual - wanted)
                if error > worstDistance.0 { worstDistance = (error, "\(name) \(what)") }
                XCTAssertLessThanOrEqual(error, Self.distanceTolerance, "\(name) \(what): \(actual) vs \(wanted)")
            }
            func velocity(_ actual: PGABallVector, _ wanted: [Double], _ what: String) {
                let error = max(abs(actual.x - wanted[0]), abs(actual.y - wanted[1]), abs(actual.z - wanted[2]))
                if error > worstVelocity.0 { worstVelocity = (error, "\(name) \(what)") }
                XCTAssertLessThanOrEqual(error, Self.velocityTolerance, "\(name) \(what)")
            }
            distance(result.carry, expected.carry, "carry")
            distance(result.total, expected.total, "total")
            distance(result.roll, expected.roll, "roll")
            distance(result.apex, expected.apex, "apex")
            distance(result.finalPosition.x, expected.final_position[0], "final x")
            distance(result.finalPosition.y, expected.final_position[1], "final y")
            distance(result.finalPosition.z, expected.final_position[2], "final z")
            velocity(result.launchVelocity, expected.launch_velocity, "launch velocity")
            velocity(result.launchSpin, expected.launch_spin, "launch spin")
            velocity(result.finalVelocity, expected.final_velocity, "final velocity")
            XCTAssertEqual(result.ticks, expected.ticks, "\(name) ticks")
            XCTAssertEqual(result.firstBounceTick, expected.first_bounce_tick, "\(name) first bounce tick")
            XCTAssertEqual(result.holed, expected.holed, "\(name) holed")
            XCTAssertEqual(result.touchedCup, expected.touched_cup, "\(name) touched cup")
            XCTAssertEqual(result.outOfWorld, expected.out_of_world, "\(name) out of world")
            XCTAssertEqual(result.nextLieIndex, expected.next_lie_index, "\(name) next lie")
            XCTAssertEqual(result.bounces, expected.bounces, "\(name) bounces")
            XCTAssertEqual(result.endState.rawValue, expected.end_state, "\(name) end state")
            XCTAssertEqual(result.endSurface, expected.end_surface, "\(name) end surface")
            XCTAssertEqual(Self.kinds(result.events), expected.events, "\(name) events")
            let byTick = Dictionary(result.trajectory.map { ($0.tick, $0) }, uniquingKeysWith: { a, _ in a })
            for sample in expected.samples {
                let tick = Int(sample[0])
                guard let point = byTick[tick] else { XCTFail("\(name) missing tick \(tick)"); continue }
                distance(point.position.x, sample[1], "x@\(tick)")
                distance(point.position.y, sample[2], "y@\(tick)")
                distance(point.position.z, sample[3], "z@\(tick)")
                XCTAssertEqual(point.state.rawValue, Int(sample[4]), "\(name) state@\(tick)")
            }
            if result.total == expected.total && result.finalPosition == Self.vector(expected.final_position)
                && result.launchVelocity == Self.vector(expected.launch_velocity) { bitIdentical += 1 }
        }
        print("PGABallFlight golden: \(fixture.scenarios.count) scenarios, \(bitIdentical) bit-identical; "
              + "max distance error \(worstDistance.0) in (\(worstDistance.1)); max velocity error \(worstVelocity.0) (\(worstVelocity.1))")
    }

    // MARK: Stepping API

    func testSteppingReproducesSimulateAndReportsEvents() throws {
        let fixture = try loadFixture()
        for name in ["full_00_9_degree_driver", "cup_p2.6", "cup_p3", "land_bunker_sw_seed38", "out_of_world_driver"] {
            let scenario = try XCTUnwrap(fixture.scenarios.first { $0.name == name })
            let terrain = try Self.terrain(scenario.terrain)
            let c = scenario.conditions
            var flight = try XCTUnwrap(PGABallFlight(launch: Self.launch(scenario.launch), terrain: terrain,
                                                     conditions: PGABallConditions(wet: c.wet, rough: c.rough, sand: c.sand, windX: c.wind_mph[0],
                                                                                   windZ: c.wind_mph[1], magnet: c.magnet),
                                                     ball: .type(scenario.ball), fps: scenario.fps, pin: scenario.pin.map(Self.vector),
                                                     random: PGARandom(state: scenario.seed)))
            var events: [PGABallFlightEvent] = []
            events.reserveCapacity(64)
            var impacts = 0, stopped = 0, finished = 0, holed = 0, outOfWorld = 0
            while !flight.isFinished {
                events.removeAll(keepingCapacity: true)
                flight.step(terrain: terrain, events: &events)
                for event in events {
                    switch event {
                    case let .impact(_, normalSpeed, speed, _, _, bounce):
                        impacts += 1
                        XCTAssertLessThanOrEqual(normalSpeed, speed + 1e-9); XCTAssertEqual(bounce, flight.bounces)
                    case let .stopped(lie): stopped += 1; XCTAssertEqual(lie, flight.nextLieIndex)
                    case .finished: finished += 1
                    case .holed: holed += 1
                    case .outOfWorld: outOfWorld += 1
                    default: break
                    }
                }
            }
            XCTAssertEqual(flight.tick, scenario.result.ticks, name)
            XCTAssertEqual(flight.position, Self.vector(scenario.result.final_position), name)
            XCTAssertEqual(flight.nextLieIndex, scenario.result.next_lie_index, name)
            XCTAssertEqual(finished, 1, name); XCTAssertEqual(stopped, 1, name)
            XCTAssertEqual(holed, scenario.result.holed ? 1 : 0, name)
            XCTAssertEqual(outOfWorld, scenario.result.out_of_world ? 1 : 0, name)
            if !scenario.result.out_of_world && scenario.launch.club != PGABallFlight.putter { XCTAssertGreaterThan(impacts, 0, name) }
            // A finished flight ignores further steps.
            let frozen = flight.position
            XCTAssertTrue(flight.step(terrain: terrain).isEmpty)
            XCTAssertEqual(flight.position, frozen)
            XCTAssertEqual(flight.interpolatedPosition(0.5), flight.interpolatedPosition(0.5))
        }
    }

    // MARK: Frame and handedness

    /// A plane in game meters: height = sx·x + sz·z.
    private final class MetersPlane: PGATerrainSampling {
        let slopeX: Double, slopeZ: Double, surface: PGASurface, properties: PGASurfaceProperties?
        var queries = 0
        init(slopeX: Double = 0, slopeZ: Double = 0, surface: PGASurface = .fairway, properties: PGASurfaceProperties? = nil) {
            self.slopeX = slopeX; self.slopeZ = slopeZ; self.surface = surface; self.properties = properties
        }
        func ground(x: Double, z: Double, ceiling: Double) -> PGAGroundSample? {
            queries += 1
            let n = PGAVector(x: -slopeX, y: 1, z: -slopeZ)
            return PGAGroundSample(height: slopeX * x + slopeZ * z, normal: n * (1 / n.length), surface: properties?.surface ?? surface,
                                   lie: surface.rawValue, materialID: nil, properties: properties)
        }
    }

    func testFrameConvertsMetersToLeftHandedInches() {
        let frame = PGABallFlightFrame(origin: PGAVector(x: 1000, y: 500, z: -300))
        let meters = PGAVector(x: 2, y: 0.5, z: 3)
        let inches = frame.point(meters: meters)
        XCTAssertEqual(inches.x, 2 / 0.0254 + 1000, accuracy: 1e-9)
        XCTAssertEqual(inches.y, 0.5 / 0.0254 + 500, accuracy: 1e-9)
        XCTAssertEqual(inches.z, -3 / 0.0254 - 300, accuracy: 1e-9, "Z is mirrored")
        let back = frame.meters(inches)
        XCTAssertEqual(back.x, meters.x, accuracy: 1e-12); XCTAssertEqual(back.y, meters.y, accuracy: 1e-12); XCTAssertEqual(back.z, meters.z, accuracy: 1e-12)
        XCTAssertEqual(PGABallFlightFrame(transform: PGACourseTransform(origin: frame.origin)), frame)
        // Matches the course transform used for original data.
        let raw = PGACourseTransform(origin: frame.origin).raw(meters: meters)
        XCTAssertEqual(inches, PGABallVector(raw.x, raw.y, raw.z))
        // Velocity: 1 in/tick forward internally is 1.524 m/s along −Z in meters.
        let v = frame.metersPerSecond(PGABallVector(0, 0, 1))
        XCTAssertEqual(v.z, -1.524, accuracy: 1e-12)
        // Heading ⇄ aim: the internal aim direction equals the mirrored heading direction.
        for heading in stride(from: -3.0, through: 3.0, by: 0.37) {
            let aim = PGABallFlightFrame.aim(heading: heading)
            let mirrored = frame.direction(meters: PGAVector(x: sin(heading), y: 0, z: cos(heading)))
            XCTAssertEqual(sin(aim), mirrored.x, accuracy: 1e-12); XCTAssertEqual(cos(aim), mirrored.z, accuracy: 1e-12)
            XCTAssertEqual(cos(PGABallFlightFrame.heading(aim: aim) - heading), 1, accuracy: 1e-12)
        }
    }

    func testOriginalSimulationAdvancesRecoveredFlightAtSixtyHertz() throws {
        let source = PGAHoleSource(number: 1, teeIndex: 3, pinIndex: 0, handicap: 1)
        let hole = PGAHole(name: "Flight bridge", par: 4, tee: .zero, cup: PGAVector(x: 0, y: 0, z: 500),
                           centerline: [.zero, PGAVector(x: 0, y: 0, z: 500)], fairwayWidth: 100,
                           greenRadius: 10, hazards: [], terrainSeed: 0, source: source)
        let course = PGACourse(name: "Original flight fixture", provenance: "Synthetic original-course fixture",
                               holes: [hole], identity: "original-flight-bridge")
        let terrain = MetersPlane()
        var game = PGASimulation(course: course, terrains: [terrain])
        game.selectClub(.driver)
        game.alignToCup()
        let start = game.ball
        let adapter = PGABallTerrainAdapter(terrain: terrain)
        let launch = PGABallSwing.launch(club: .driver9, power: 0.85, accuracy: 0.2, heading: game.heading,
                                         position: adapter.frame.point(meters: start - PGAVector(x: 0, y: PGASimulation.ballRadius, z: 0)))
        var direct = try XCTUnwrap(PGABallFlight(launch: launch, terrain: adapter,
                                                 conditions: .fromSettings(greenCondition: 3, roughLength: 2, difficulty: 2),
                                                 ball: .solidCore, pin: adapter.frame.point(meters: hole.cup),
                                                 random: PGARandom(seed: course.identity)))
        game.strike(power: 0.85, accuracy: 0.2)
        XCTAssertEqual(game.strokes, 1)
        for _ in 0..<15 {
            _ = direct.step(terrain: adapter)
            game.update(deltaTime: 1.0 / 60.0)
            let expected = adapter.frame.meters(direct.position) + PGAVector(x: 0, y: PGASimulation.ballRadius, z: 0)
            XCTAssertEqual(game.ball.x, expected.x, accuracy: 1e-9)
            XCTAssertEqual(game.ball.y, expected.y, accuracy: 1e-9)
            XCTAssertEqual(game.ball.z, expected.z, accuracy: 1e-9)
            XCTAssertEqual(game.velocity.z, adapter.frame.metersPerSecond(direct.velocity).z, accuracy: 1e-9)
            XCTAssertEqual(game.phase, direct.state == .flying ? .airborne : .rolling)
        }
        XCTAssertGreaterThan(game.ball.z, start.z)
        var ticks = 15
        while !direct.isFinished && ticks < PGABallFlight.maxTicks {
            _ = direct.step(terrain: adapter)
            game.update(deltaTime: 1.0 / 60.0)
            ticks += 1
        }
        XCTAssertTrue(direct.isFinished)
        XCTAssertEqual(game.phase, .aiming)
        let rest = adapter.frame.meters(direct.position) + PGAVector(x: 0, y: PGASimulation.ballRadius, z: 0)
        XCTAssertEqual(game.ball.x, rest.x, accuracy: 1e-9)
        XCTAssertEqual(game.ball.z, rest.z, accuracy: 1e-9)
        XCTAssertEqual(game.lieIndex, direct.nextLieIndex ?? 0)
        XCTAssertEqual(game.velocity, .zero)
    }

    /// Lateral offset to the LEFT of travel in our right-handed meters frame,
    /// seen from behind the ball (the same convention as the ocean-side test:
    /// right = (−forward.z, 0, forward.x)).
    private static func leftOffset(_ point: PGAVector, start: PGAVector, heading: Double) -> Double {
        let left = PGAVector(x: cos(heading), y: 0, z: -sin(heading))
        let d = point - start
        return d.x * left.x + d.z * left.z
    }

    private static func forwardOffset(_ point: PGAVector, start: PGAVector, heading: Double) -> Double {
        let d = point - start
        return d.x * sin(heading) + d.z * cos(heading)
    }

    func testHookCurvesLeftAndSliceRightInGameFrame() throws {
        let frame = PGABallFlightFrame(origin: PGAVector(x: 5000, y: 0, z: -2000))
        let adapter = PGABallTerrainAdapter(terrain: MetersPlane(), frame: frame)
        let start = PGAVector(x: 12, y: 0, z: -7)
        for heading in [0.0, 0.8, -2.4] {
            var lateral: [Double: Double] = [:]
            for accuracy in [-0.7, 0.0, 0.7] {
                let launch = PGABallSwing.launch(club: .driver9, power: 1, accuracy: accuracy, heading: heading,
                                                 position: frame.point(meters: start))
                var flight = try XCTUnwrap(PGABallFlight(launch: launch, terrain: adapter, ball: .solidCore))
                while !flight.isFinished { _ = flight.step(terrain: adapter) }
                let landing = frame.meters(try XCTUnwrap(flight.firstBounce))
                let rest = frame.meters(flight.position)
                lateral[accuracy] = Self.leftOffset(rest, start: start, heading: heading)
                XCTAssertGreaterThan(Self.forwardOffset(rest, start: start, heading: heading), 200, "Driver travels along the heading")
                // Curvature: compare the landing with the straight launch line.
                let v0 = frame.metersDirection(flight.launchVelocity)
                let launchLeft = Self.leftOffset(start + v0, start: start, heading: heading) / Self.forwardOffset(start + v0, start: start, heading: heading)
                let curve = Self.leftOffset(landing, start: start, heading: heading) - launchLeft * Self.forwardOffset(landing, start: start, heading: heading)
                if accuracy < 0 { XCTAssertGreaterThan(curve, 10, "Hook curves left (heading \(heading))") }
                if accuracy > 0 { XCTAssertLessThan(curve, -10, "Slice curves right (heading \(heading))") }
                if accuracy == 0 { XCTAssertEqual(curve, 0, accuracy: 0.001, "A square strike flies along the heading") }
            }
            XCTAssertGreaterThan(lateral[-0.7]!, 15, "Hook finishes left of the target line")
            XCTAssertLessThan(lateral[0.7]!, -15, "Slice finishes right of the target line")
            // The run-out's micro-bounces drift a few cm off-axis on diagonal
            // headings (Collide's tangent-rotation and ω.z quirks, kept as in the reference).
            XCTAssertEqual(lateral[0.0]!, 0, accuracy: 0.1)
        }
    }

    func testPuttsBreakDownhillInGameFrameAndPullLeft() throws {
        let green = PGASurfaceProperties(materialID: 6, materialName: "pbl_green.tga", sectionFlags: 2,
                                         records: [.init(label: "Green", flags: 0x4, coefficients: [0.975, 0.975, 0.07, 0.25, 0.7, 0.7, 0.375, 0.2, 36.0, 0.2])])
        let start = PGAVector.zero, heading = 0.0
        // Ground falls toward +x, which is LEFT of a putt along +z in our frame.
        let fallsLeft = PGABallTerrainAdapter(terrain: MetersPlane(slopeX: -0.02, properties: green))
        let fallsRight = PGABallTerrainAdapter(terrain: MetersPlane(slopeX: 0.02, properties: green))
        func putt(_ adapter: PGABallTerrainAdapter, accuracy: Double = 0) throws -> PGAVector {
            let launch = PGABallSwing.launch(club: .putter, power: 0.45, accuracy: accuracy, heading: heading, position: adapter.frame.point(meters: start))
            XCTAssertEqual(launch.shotType, 2)
            let result = try XCTUnwrap(PGABallFlight.simulate(launch: launch, terrain: adapter))
            XCTAssertEqual(result.endSurface, "pbl_green.tga")
            return adapter.frame.meters(result.finalPosition)
        }
        let left = try putt(fallsLeft), right = try putt(fallsRight)
        XCTAssertGreaterThan(Self.leftOffset(left, start: start, heading: heading), 0.1, "Breaks downhill to the left")
        XCTAssertLessThan(Self.leftOffset(right, start: start, heading: heading), -0.1, "Breaks downhill to the right")
        XCTAssertEqual(Self.leftOffset(left, start: start, heading: heading), -Self.leftOffset(right, start: start, heading: heading), accuracy: 1e-4)
        let flat = PGABallTerrainAdapter(terrain: MetersPlane(properties: green))
        XCTAssertGreaterThan(Self.leftOffset(try putt(flat, accuracy: -0.5), start: start, heading: heading), 0.05, "Pulled putt starts left")
        XCTAssertLessThan(Self.leftOffset(try putt(flat, accuracy: 0.5), start: start, heading: heading), -0.05, "Pushed putt starts right")
    }

    func testAdapterUsesOriginalMaterialRecordsAndCachesThem() throws {
        func record(_ label: String, _ flags: UInt32, _ power: Double) -> PGASurfaceProperties.Record {
            .init(label: label, flags: flags, coefficients: [power, 0.7, 0.06, 0.15, 0.725, 0.725, 0.375, 0.9, 40, 0.3], soundID: -1)
        }
        let rough = PGASurfaceProperties(materialID: 2, materialName: "pbl_rough.tga", sectionFlags: 0x8002,
                                         records: [record("Md Rough", 0x202, 0.8), record("Lt Rough", 0x202, 0.9), record("Dp Rough", 0x202, 0.7)],
                                         sectionSoundID: 905)
        let plane = MetersPlane(slopeX: 0.1, slopeZ: -0.05, properties: rough)
        let frame = PGABallFlightFrame(origin: PGAVector(x: 1000, y: 500, z: -300))
        let adapter = PGABallTerrainAdapter(terrain: plane, frame: frame)
        let point = frame.point(meters: PGAVector(x: 2, y: 0, z: 3))
        let sample = try XCTUnwrap(adapter.sample(x: point.x, z: point.z, ceiling: .infinity))
        XCTAssertEqual(sample.height, (0.1 * 2 - 0.05 * 3) / 0.0254 + 500, accuracy: 1e-9)
        // Ground rising toward meters −Z rises toward internal +Z, so the normal leans to internal −Z.
        let length = PGAVector(x: -0.1, y: 1, z: 0.05).length
        XCTAssertEqual(sample.normal.x, -0.1 / length, accuracy: 1e-12)
        XCTAssertEqual(sample.normal.z, -0.05 / length, accuracy: 1e-12)
        XCTAssertEqual(sample.surface.records.count, 3)
        XCTAssertEqual(sample.surface.records[1].c0, Double(Float(0.9)))
        XCTAssertEqual(sample.surface.category, .rough)
        XCTAssertEqual(sample.surface.soundID, 905)
        XCTAssertTrue(sample.surface.properties === rough)
        XCTAssertTrue(adapter.sample(x: point.x + 10, z: point.z, ceiling: .infinity)!.surface === sample.surface, "One surface per material")
        // The launch lie index selects the record as ConsiderTerrain does.
        XCTAssertEqual(PGABallFlight.considerTerrain(surface: sample.surface, lieIndex: 2, rough: 1, sand: 1, magnet: 0).record.name, "Dp Rough")
        // Generated terrain falls back to decoded Pebble Beach records.
        let generated = PGABallTerrainAdapter(terrain: MetersPlane(surface: .sand))
        XCTAssertTrue(generated.sample(x: 0, z: 0, ceiling: .infinity)!.surface === PGABallSurface.pblBunker)
        // Blend strips: the native guard avoids the denormal-c0 launch unless asked for the quirk.
        let blend = PGABallSurface(properties: PGASurfaceProperties(materialID: 13, materialName: "pbl_bunker_rough.tga", sectionFlags: 0x8c1,
                                                                     records: [record("pbl_bunke", 0x208, 7.006e-45), record("pbl_bunke", 0x208, 0.95)]))
        XCTAssertEqual(PGABallSwing.usableLieIndex(0, surface: blend), 1)
        XCTAssertEqual(PGABallSwing.usableLieIndex(0, surface: blend, faithfulBlendQuirk: true), 0)
        XCTAssertEqual(PGABallSwing.usableLieIndex(5, surface: sample.surface), 2)
    }

    func testSwingMappingAssumptions() throws {
        XCTAssertEqual(PGABallSwing.originalIndex(for: .driver), 0)
        XCTAssertEqual(PGAClub.allCases.map(PGABallSwing.originalIndex(for:)), [0, 3, 12, 14, 16, 17, 18, 20])
        let full = PGABallSwing.launch(club: .driver9, power: 1, accuracy: 0, heading: 0, position: .zero)
        XCTAssertEqual(full.power, 15.5555553, accuracy: 1e-6, "100% at Advanced is 15.556")
        XCTAssertEqual(full.path, 0); XCTAssertEqual(full.face, 0); XCTAssertEqual(full.loftAdjust, 0)
        XCTAssertEqual(PGABallSwing.launch(club: .driver9, power: 1, accuracy: 0, heading: 0, position: .zero, difficulty: 3).power, full.power)
        XCTAssertEqual(PGABallSwing.launch(club: .driver9, power: 1, accuracy: 0, heading: 0, position: .zero, difficulty: 0).power,
                       Double(Float(Double(Float(9612)) / 9720 * 14)))
        let putt = PGABallSwing.launch(club: .putter, power: 1, accuracy: 0, heading: 0, position: .zero)
        XCTAssertEqual(putt.power, 6.4, accuracy: 1e-12, "Putter maximum 8 × click factor 0.8")
        let hook = PGABallSwing.launch(club: .driver9, power: 1, accuracy: -1, heading: 0, position: .zero)
        XCTAssertEqual(hook.path, 5 * .pi / 180, accuracy: 1e-12, "Full miss is MaxSliceAngle (Advanced 5°), in-to-out")
        XCTAssertEqual(hook.loftAdjust, -hook.path * 0.5, accuracy: 1e-12)
        XCTAssertEqual(PGABallSwing.launch(club: .iron7, power: 1, accuracy: -1, heading: 0, position: .zero).loftAdjust, 0, "Only clubs < 11")
        let rough = PGABallSwing.launch(club: .iron7, power: 1, accuracy: 0.5, heading: 0, position: .zero,
                                        lieAccuracy: PGABallSwing.lieAccuracyFactor(flags: 0x202, index: 2))
        XCTAssertEqual(rough.path, -pow(0.5, 0.6) * 5 * .pi / 180 / 0.65, accuracy: 1e-12, "Dp rough divides the path by 0.65")
        XCTAssertEqual(PGABallSwing.lieAccuracyFactor(flags: 0x208, index: 3), 0.45, accuracy: 1e-12)
        XCTAssertEqual(PGABallSwing.lieAccuracyFactor(flags: 0x8000_0200, index: 0), 0.2, accuracy: 1e-12)
        XCTAssertEqual(PGABallSwing.lieAccuracyFactor(flags: 0x201, index: 0), 1)
        // A full 7-iron from the game's inputs lands near the caddie's table distance.
        let adapter = PGABallTerrainAdapter(terrain: MetersPlane())
        let seven = try XCTUnwrap(PGABallFlight.simulate(launch: PGABallSwing.launch(club: .iron7, power: 1, accuracy: 0, heading: 1.0, position: .zero),
                                                         terrain: adapter, ball: .twoPiece))
        XCTAssertEqual(seven.total / PGABallFlight.caddyMaxDistance[14], 1, accuracy: 0.1)
    }

    // MARK: Original course

    private static let pebble: Result<PGAOriginalPlayableCourse, Error>? = {
        let terrain = repository.appendingPathComponent("Library/Imported/pga2005/PBL/terrain.ghpc")
        guard FileManager.default.fileExists(atPath: terrain.path) else { return nil }
        return Result { try PGAOriginalPlayableCourse.load(code: "PBL", root: repository) }
    }()

    func testPebbleBeachTeeShotsRunToRestOnOriginalFloor() throws {
        guard let loaded = Self.pebble else { throw XCTSkip("Original PBL data not prepared; run Tools/prepare_pga2005.py") }
        let pebble = try loaded.get()
        let frame = PGABallFlightFrame(transform: pebble.transform)
        var ticks = 0, elapsed = 0.0
        for (index, hole) in pebble.course.holes.enumerated() {
            let adapter = PGABallTerrainAdapter(terrain: pebble.terrains[index], frame: frame)
            let target = hole.centerline.count > 2 ? hole.centerline[1] : hole.cup
            let heading = atan2(target.x - hole.tee.x, target.z - hole.tee.z)
            let lie = try XCTUnwrap(adapter.ground(x: hole.tee.x, z: hole.tee.z, ceiling: hole.tee.y + 0.3), "Hole \(index + 1) tee floor")
            XCTAssertEqual(lie.surface, .tee, "Hole \(index + 1)")
            let club = hole.par == 3 ? PGAOriginalClub.iron7 : .driver9
            let surface = adapter.surface(for: lie)
            let launch = PGABallSwing.launch(club: club, power: 1, accuracy: 0, heading: heading, position: frame.point(meters: hole.tee),
                                             lieIndex: PGABallSwing.usableLieIndex(0, surface: surface))
            let began = Date()
            let result = try XCTUnwrap(PGABallFlight.simulate(launch: launch, terrain: adapter, conditions: .fromSettings(difficulty: 2),
                                                              ball: .solidCore, pin: frame.point(meters: hole.cup), recordEvery: 1000),
                                       "Hole \(index + 1)")
            elapsed += Date().timeIntervalSince(began); ticks += result.ticks
            XCTAssertLessThan(result.ticks, PGABallFlight.maxTicks, "Hole \(index + 1) comes to rest")
            XCTAssertEqual(result.endState, .done, "Hole \(index + 1)")
            let rest = frame.meters(result.finalPosition)
            XCTAssertTrue([rest.x, rest.y, rest.z].allSatisfy(\.isFinite))
            if !result.outOfWorld {
                let floor = try XCTUnwrap(adapter.ground(x: rest.x, z: rest.z, ceiling: rest.y + 0.3), "Hole \(index + 1) rest floor")
                XCTAssertEqual(rest.y, floor.height, accuracy: 0.04, "Hole \(index + 1) rests on its floor")
            }
            let yards = result.total / 36
            if index == 0 {
                // Hole 1, 376 yd par 4 doglegging right: a straight Advanced drive.
                XCTAssertFalse(result.outOfWorld)
                XCTAssertGreaterThan(yards, 200); XCTAssertLessThan(yards, 340)
                XCTAssertGreaterThan(result.carry / 36, 200)
                XCTAssertGreaterThan(Self.forwardOffset(rest, start: hole.tee, heading: heading), 180)
                XCTAssertLessThan(abs(Self.leftOffset(rest, start: hole.tee, heading: heading)), 20, "No sideways drift from a square strike")
            }
            XCTAssertLessThan(yards, 360, "Hole \(index + 1) total \(yards) yd")
        }
        print(String(format: "PGABallFlight on PBL: 18 tee shots, %d ticks, %.2f µs per tick (debug build, this Mac; not M1 acceptance)",
                     ticks, elapsed / Double(max(1, ticks)) * 1e6))
    }
}
