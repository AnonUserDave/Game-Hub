import Foundation

// Native development simulation. These values and rules are deliberately
// independent of SceneKit, input devices, and the as-yet-undecoded 2005 engine.
// Terrain is injected through PGATerrainSampling: generated practice holes use
// their analytic height field and original courses use decoded triangles. Ball
// Generated practice retains provisional native physics. Original-course
// shots use the statically reconstructed CBallFlight model; swing inputs and
// some rules remain development approximations.
struct PGAVector: Equatable, Codable {
    var x: Double
    var y: Double
    var z: Double
    static let zero = PGAVector(x: 0, y: 0, z: 0)
    static func + (a: Self, b: Self) -> Self { Self(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func - (a: Self, b: Self) -> Self { Self(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    static func * (a: Self, b: Double) -> Self { Self(x: a.x * b, y: a.y * b, z: a.z * b) }
    var horizontalLength: Double { hypot(x, z) }
    var length: Double { sqrt(x * x + y * y + z * z) }
    var horizontalUnit: Self { horizontalLength > 0.00001 ? Self(x: x / horizontalLength, y: 0, z: z / horizontalLength) : .zero }
    func distance(to other: Self) -> Double { (self - other).horizontalLength }
}

/// Provisional physics categories. Original surfaces map onto these from their
/// source flag bits; the original coefficient semantics are not yet reconstructed.
enum PGASurface: String, Codable {
    case tee = "Tee", fairway = "Fairway", rough = "Rough", green = "Green", fringe = "Fringe", sand = "Bunker",
         water = "Water", unplayable = "Unplayable", out = "Out of bounds"
    var rollingFriction: Double {
        switch self {
        case .green: return 0.48
        case .fringe: return 0.8
        case .tee, .fairway: return 1.35
        case .unplayable: return 1.1
        case .rough: return 3.2
        case .sand: return 6.3
        case .water, .out: return 5
        }
    }
    var launchFactor: Double {
        switch self {
        case .rough: return 0.82
        case .sand: return 0.65
        case .unplayable: return 0.85
        default: return 1
        }
    }
    /// Bounce restitution and tangential retention for the provisional impact.
    /// Tuned so drives roll out roughly 10-15% of carry; the original Collide
    /// model (c2/c3/c8/c9 plus a slip phase) is not reconstructed yet.
    var impact: (restitution: Double, retention: Double) {
        switch self {
        case .sand: return (0, 0.15)
        case .green: return (0.15, 0.45)
        case .rough: return (0.12, 0.35)
        case .unplayable: return (0.45, 0.82)
        default: return (0.18, 0.5)
        }
    }
    /// A lie the provisional rules allow the player to hit from.
    var playable: Bool { self != .water && self != .out && self != .unplayable }
}

struct PGAHazard: Codable, Equatable {
    var center: PGAVector
    var radiusX: Double
    var radiusZ: Double
    var surface: PGASurface
    func contains(x: Double, z: Double) -> Bool {
        pow((x - center.x) / radiusX, 2) + pow((z - center.z) / radiusZ, 2) < 1
    }
}

/// Where an original hole's authored data came from.
struct PGAHoleSource: Codable, Equatable {
    var number: Int
    var teeIndex: Int
    var pinIndex: Int
    var handicap: Int
    /// Original INI scorecard yardage for the selected tee, when supplied.
    var scorecardYards: Int?
}

struct PGAHole: Codable, Equatable {
    var name: String
    var par: Int
    var tee: PGAVector
    var cup: PGAVector
    var centerline: [PGAVector]
    var fairwayWidth: Double
    var greenRadius: Double
    var hazards: [PGAHazard]
    var terrainSeed: Double
    var source: PGAHoleSource? = nil

    var length: Double { tee.distance(to: cup) }
    var minX: Double { min(tee.x, cup.x, centerline.map(\.x).min() ?? 0) - 100 }
    var maxX: Double { max(tee.x, cup.x, centerline.map(\.x).max() ?? 0) + 100 }
    var minZ: Double { min(tee.z, cup.z) - 55 }
    var maxZ: Double { max(tee.z, cup.z) + 65 }

    func height(x: Double, z: Double) -> Double {
        let rolling = 1.7 * sin(x * 0.024 + terrainSeed) * sin(z * 0.019)
            + 1.1 * sin(z * 0.011 + terrainSeed) + 0.7 * cos(x * 0.041 - z * 0.009)
        // Flatten the tee and green without an elevation discontinuity. The
        // putting surface retains a very gentle, predictable break.
        let greenDistance = hypot(x - cup.x, z - cup.z)
        let greenBlend = max(0, min(1, (greenDistance - greenRadius) / 14))
        let greenHeight = 0.006 * (x - cup.x) + 0.003 * (z - cup.z)
        let greenTerrain = greenHeight * (1 - greenBlend) + rolling * greenBlend
        let teeBlend = max(0, min(1, (hypot(x - tee.x, z - tee.z) - 5) / 10))
        return greenTerrain * teeBlend
    }

    func position(x: Double, z: Double) -> PGAVector { PGAVector(x: x, y: height(x: x, z: z), z: z) }

    func gradient(x: Double, z: Double) -> PGAVector {
        let e = 0.15
        return PGAVector(x: (height(x: x + e, z: z) - height(x: x - e, z: z)) / (2 * e), y: 0,
                         z: (height(x: x, z: z + e) - height(x: x, z: z - e)) / (2 * e))
    }

    func surface(x: Double, z: Double) -> PGASurface {
        guard x >= minX + 10, x <= maxX - 10, z >= minZ + 10, z <= maxZ - 10 else { return .out }
        if hypot(x - cup.x, z - cup.z) <= greenRadius { return .green }
        if abs(x - tee.x) < 4.5 && abs(z - tee.z) < 6 { return .tee }
        if let hazard = hazards.first(where: { $0.contains(x: x, z: z) }) { return hazard.surface }
        for index in 1..<centerline.count {
            let a = centerline[index - 1], b = centerline[index]
            let d = b - a, p = PGAVector(x: x - a.x, y: 0, z: z - a.z)
            let t = max(0, min(1, (p.x * d.x + p.z * d.z) / max(0.01, d.x * d.x + d.z * d.z)))
            if p.distance(to: d * t) < fairwayWidth * (0.92 + 0.12 * sin(z * 0.027)) { return .fairway }
        }
        return .rough
    }
}

struct PGACourse: Codable, Equatable {
    var name: String
    /// Provenance is persisted with the course, so a generated training course
    /// cannot silently be relabeled as an original game course by the renderer.
    var provenance: String
    var holes: [PGAHole]
    /// Stable identity of the source data and settings. Snapshots only restore
    /// onto a course whose identity matches.
    var identity: String = "generated-practice-v1"
    var isOriginal: Bool { holes.contains { $0.source != nil } }

    static let development = PGACourse(name: "Monterey Practice Links", provenance: "Generated development course · original PGA 2005 assets pending", holes: [
        PGAHole(name: "Cypress Approach", par: 4, tee: .zero, cup: PGAVector(x: 14, y: 0, z: 315),
                centerline: [.zero, PGAVector(x: -17, y: 0, z: 110), PGAVector(x: 20, y: 0, z: 220), PGAVector(x: 14, y: 0, z: 315)],
                fairwayWidth: 23, greenRadius: 15,
                hazards: [PGAHazard(center: PGAVector(x: 38, y: 0, z: 285), radiusX: 12, radiusZ: 20, surface: .sand),
                          PGAHazard(center: PGAVector(x: -20, y: 0, z: 320), radiusX: 11, radiusZ: 13, surface: .sand),
                          PGAHazard(center: PGAVector(x: -61, y: 0, z: 185), radiusX: 25, radiusZ: 48, surface: .water)], terrainSeed: 0.8),
        PGAHole(name: "The Short Crossing", par: 3, tee: .zero, cup: PGAVector(x: -12, y: 0, z: 135),
                centerline: [.zero, PGAVector(x: 13, y: 0, z: 65), PGAVector(x: -12, y: 0, z: 135)],
                fairwayWidth: 18, greenRadius: 16,
                hazards: [PGAHazard(center: PGAVector(x: -18, y: 0, z: 83), radiusX: 38, radiusZ: 16, surface: .water),
                          PGAHazard(center: PGAVector(x: 13, y: 0, z: 131), radiusX: 10, radiusZ: 15, surface: .sand)], terrainSeed: 2.4),
        PGAHole(name: "Long Way Home", par: 5, tee: .zero, cup: PGAVector(x: 37, y: 0, z: 440),
                centerline: [.zero, PGAVector(x: -19, y: 0, z: 150), PGAVector(x: -8, y: 0, z: 265), PGAVector(x: 37, y: 0, z: 440)],
                fairwayWidth: 25, greenRadius: 17,
                hazards: [PGAHazard(center: PGAVector(x: 35, y: 0, z: 230), radiusX: 16, radiusZ: 28, surface: .sand),
                          PGAHazard(center: PGAVector(x: 78, y: 0, z: 386), radiusX: 25, radiusZ: 43, surface: .water),
                          PGAHazard(center: PGAVector(x: 9, y: 0, z: 422), radiusX: 10, radiusZ: 15, surface: .sand)], terrainSeed: 4.3)
    ])
}

enum PGAClub: Int, CaseIterable {
    case driver, wood3, iron5, iron7, iron9, wedge, sandWedge, putter
    var title: String { ["Driver", "3 Wood", "5 Iron", "7 Iron", "9 Iron", "Pitching Wedge", "Sand Wedge", "Putter"][rawValue] }
    var shortTitle: String { ["DR", "3W", "5I", "7I", "9I", "PW", "SW", "PT"][rawValue] }
    var speed: Double { [68, 58, 48, 42, 36, 28, 22, 7.5][rawValue] }
    var loft: Double { [14, 19, 28, 35, 44, 53, 59, 0][rawValue] * .pi / 180 }
    var estimatedCarry: Double { self == .putter ? speed * speed / (2 * PGASurface.green.rollingFriction) : speed * speed * sin(2 * loft) / 9.81 * 0.86 }
    static func recommended(distance: Double, surface: PGASurface) -> Self {
        if surface == .green || (surface == .fringe && distance < 18) { return .putter }
        if surface == .sand && distance < 65 { return .sandWedge }
        return allCases.dropLast().reversed().first { $0.estimatedCarry >= distance } ?? .driver
    }
    /// Development caddie for original courses, using recovered per-club
    /// maximum distance rather than the generated course's launch estimates.
    static func recommendedOriginal(distance: Double, surface: PGASurface) -> Self {
        if surface == .green || (surface == .fringe && distance < 18) { return .putter }
        if surface == .sand && distance < 65 { return .sandWedge }
        return allCases.dropLast().reversed().first {
            PGABallFlight.caddyMaxDistance[PGABallSwing.originalIndex(for: $0)] * PGABallFlightFrame.metersPerInch >= distance
        } ?? .driver
    }
}

enum PGAPhase: String {
    case aiming, power, accuracy, airborne, rolling, holed, roundComplete
    var inMotion: Bool { self == .airborne || self == .rolling }
    var swinging: Bool { self == .power || self == .accuracy }
}

/// Restorable round state. Terrain is never serialized: a snapshot reattaches
/// to freshly loaded course data whose identity matches.
struct PGARoundSnapshot: Codable, Equatable {
    var schemaVersion = 1
    var courseIdentity: String
    var holeIndex: Int
    var scores: [Int]
    var strokes: Int
    var ball: PGAVector
    var heading: Double
    var club: Int
    var lieIndex: Int? = nil
    var randomState: UInt64? = nil
    /// Multiplayer rounds (absent in single-player saves from earlier builds).
    var players: [PGAPlayer]? = nil
    var currentPlayer: Int? = nil
}

/// One golfer in a hot-seat round. While it is a player's turn the
/// simulation's active fields (ball, strokes, heading, club, lie) are theirs;
/// they are written back here whenever the turn passes.
struct PGAPlayer: Codable, Equatable {
    var name: String
    var scores: [Int] = []
    var ball: PGAVector = .zero
    var strokes = 0
    var heading = 0.0
    var club = PGAClub.driver.rawValue
    var lieIndex = 0
    var holed = false
}

/// Things that happened during simulation steps, drained each frame by the
/// session for sound (and later commentary/camera). Purely informational.
enum PGASimulationEvent: Equatable {
    case strike(club: PGAClub, lie: PGASurface, power: Double, accuracy: Double, fromTee: Bool)
    case impact(position: PGAVector, surface: PGASurface, soundID: Int?, normalSpeed: Double)
    case cup
    case penalty(PGASurface)
    case rest(lie: PGASurface, distanceToPin: Double, shotDistance: Double, fromTee: Bool)
    case holed(strokes: Int, par: Int, shotDistance: Double, onGreen: Bool)
}

/// Deterministic SplitMix64, so lies drawn at rest replay identically.
struct PGARandom: Codable, Equatable {
    var state: UInt64
    init(seed: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        state = hash
    }
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func int(_ bound: Int) -> Int { bound <= 1 ? 0 : Int(next() % UInt64(bound)) }
}

struct PGASimulation {
    static let ballRadius = 0.02135
    static let fixedStep = 1.0 / 120.0
    private(set) var course: PGACourse
    private(set) var holeIndex = 0
    private(set) var ball: PGAVector = .zero
    private(set) var velocity: PGAVector = .zero
    private(set) var phase: PGAPhase = .aiming
    private(set) var strokes = 0
    private(set) var players: [PGAPlayer]
    private(set) var currentPlayer = 0
    private(set) var heading: Double = 0
    private(set) var club: PGAClub = .driver
    private(set) var meter = 0.0
    private(set) var shotPower = 0.0
    private(set) var shotAccuracy = 0.0
    private(set) var lastShotDistance = 0.0
    private(set) var message = "Aim, choose a club, then press Space or A to start your swing."
    /// Original surface record index of the resting lie (CBallFlight+0x99).
    private(set) var lieIndex = 0
    private let terrains: [PGATerrainSampling]
    /// One adapter per original hole. Its material cache is filled during play.
    private let flightTerrains: [PGABallTerrainAdapter]
    private var flight: PGABallFlight?
    private var random: PGARandom
    private var originLieIndex = 0
    private(set) var events: [PGASimulationEvent] = []
    private var shotFromTee = false
    private var shotLie = PGASurface.tee
    /// Where and how fast the ball first touched a bunker during this shot.
    private var bunkerEntry: (position: PGAVector, speed: Double)?
    private var meterTime = 0.0
    private var accumulator = 0.0
    private var shotOrigin: PGAVector = .zero
    private var lowSpeedTime = 0.0
    private var flightTime = 0.0
    private var missingFloorTime = 0.0
    var hole: PGAHole { course.holes[holeIndex] }
    var terrain: PGATerrainSampling { terrains[holeIndex] }
    var distanceToCup: Double { ball.distance(to: hole.cup) }
    /// The floor directly under a resting ball; nil only outside the world.
    var lieSample: PGAGroundSample? { ground(x: ball.x, z: ball.z, ceiling: ball.y + 0.3) }
    var lie: PGASurface { lieSample?.surface ?? .out }
    var lieLabel: String {
        guard let sample = lieSample else { return PGASurface.out.rawValue }
        return sample.properties?.label(lieIndex) ?? sample.lie
    }
    /// Launch-speed multiplier: original c0 of the lie record when present.
    var launchFactor: Double {
        guard let sample = lieSample else { return 1 }
        return sample.properties?.lieRecord(lieIndex)?.power ?? sample.surface.launchFactor
    }
    var direction: PGAVector { PGAVector(x: sin(heading), y: 0, z: cos(heading)) }
    /// The active player's completed hole scores.
    var scores: [Int] { players[currentPlayer].scores }
    var playerName: String { players[currentPlayer].name }
    var isMultiplayer: Bool { players.count > 1 }
    /// Every player has holed out (or picked up) on this hole.
    var holeComplete: Bool { players.allSatisfy(\.holed) }
    var completedStrokes: Int { scores.reduce(0, +) }
    var scoreToPar: Int { scoreToPar(player: currentPlayer) }
    func scoreToPar(player: Int) -> Int { zip(players[player].scores, course.holes).reduce(0) { $0 + $1.0 - $1.1.par } }
    var targetDistance: Double {
        let factor = lieSample?.properties != nil || lie == .rough || lie == .sand ? launchFactor : 1
        if course.isOriginal {
            let index = PGABallSwing.originalIndex(for: club)
            return PGABallFlight.caddyMaxDistance[index] * PGABallFlightFrame.metersPerInch * factor * factor
        }
        if club == .putter, let sample = lieSample, let properties = sample.properties {
            let speed = PGAClub.putter.speed * factor
            return speed * speed / (2 * max(0.05, properties.rollingDeceleration(normalY: sample.normal.y)))
        }
        return club.estimatedCarry * factor * factor
    }

    /// `terrains` supplies one sampler per hole. Omitted, the generated holes'
    /// analytic height fields are used.
    init(course: PGACourse = .development, terrains: [PGATerrainSampling]? = nil, playerNames: [String] = ["Player"]) {
        precondition(!course.holes.isEmpty, "A native golf course needs at least one hole")
        precondition(terrains == nil || terrains!.count == course.holes.count, "One terrain sampler per hole")
        precondition((1...4).contains(playerNames.count), "One to four players")
        self.course = course
        players = playerNames.map { PGAPlayer(name: $0) }
        self.terrains = terrains ?? course.holes.map { PGAProceduralTerrain(hole: $0) }
        flightTerrains = self.terrains.map { terrain in
            let frame = (terrain as? PGAOriginalHoleTerrain).map { PGABallFlightFrame(transform: $0.transform) } ?? PGABallFlightFrame()
            return PGABallTerrainAdapter(terrain: terrain, frame: frame)
        }
        random = PGARandom(seed: course.identity)
        resetHole()
    }

    mutating func takeEvents() -> [PGASimulationEvent] { defer { events.removeAll(keepingCapacity: true) }; return events }

    /// Floor query that tolerates the hairline seams between source patches.
    func ground(x: Double, z: Double, ceiling: Double = .infinity) -> PGAGroundSample? {
        if let sample = terrain.ground(x: x, z: z, ceiling: ceiling) { return sample }
        for (dx, dz) in [(0.03, 0.0), (-0.03, 0.0), (0.0, 0.03), (0.0, -0.03)] {
            if let sample = terrain.ground(x: x + dx, z: z + dz, ceiling: ceiling) { return sample }
        }
        return nil
    }

    /// Display/camera height: the highest floor not far above `reference`.
    func groundHeight(x: Double, z: Double, near reference: Double) -> Double {
        ground(x: x, z: z, ceiling: reference + 2)?.height ?? ground(x: x, z: z)?.height ?? reference
    }

    mutating func aim(_ radians: Double) {
        guard phase == .aiming else { return }
        heading = (heading + radians).truncatingRemainder(dividingBy: 2 * .pi)
    }

    mutating func changeClub(_ delta: Int) {
        guard phase == .aiming else { return }
        club = PGAClub(rawValue: min(PGAClub.putter.rawValue, max(0, club.rawValue + delta))) ?? club
    }

    mutating func selectClub(_ newClub: PGAClub) { if phase == .aiming { club = newClub } }

    mutating func alignToCup() {
        guard phase == .aiming else { return }
        heading = atan2(hole.cup.x - ball.x, hole.cup.z - ball.z)
    }

    /// Default target. Original holes follow their authored TCR aim points:
    /// the farthest point ahead of the ball within driver range, else the next
    /// one ahead. This is a development caddie, not the original aiming rule.
    /// Generated holes aim at the cup.
    var playLineTarget: PGAVector {
        guard hole.source != nil, hole.centerline.count > 2 else { return hole.cup }
        let path = hole.centerline
        var travelled = [0.0]
        for (a, b) in zip(path, path.dropFirst()) { travelled.append(travelled.last! + a.distance(to: b)) }
        // Ball progress: projection onto the nearest path segment.
        var progress = 0.0, nearest = Double.infinity
        for index in 0..<(path.count - 1) {
            let a = path[index], d = path[index + 1] - a, length = max(0.001, d.horizontalLength)
            let t = max(0, min(1, ((ball.x - a.x) * d.x + (ball.z - a.z) * d.z) / (length * length)))
            let distance = (a + d * t).distance(to: ball)
            if distance < nearest { nearest = distance; progress = travelled[index] + t * length }
        }
        let ahead = path.indices.dropFirst().filter { travelled[$0] > progress + 5 }.map { path[$0] }
        let reach = course.isOriginal ? PGABallFlight.caddyMaxDistance[0] * PGABallFlightFrame.metersPerInch : PGAClub.driver.estimatedCarry
        if hole.cup.distance(to: ball) <= reach { return hole.cup }
        return ahead.last { $0.distance(to: ball) <= reach } ?? ahead.first ?? hole.cup
    }

    mutating func alignToPlayLine() {
        guard phase == .aiming else { return }
        let target = playLineTarget
        heading = atan2(target.x - ball.x, target.z - ball.z)
        club = course.isOriginal
            ? PGAClub.recommendedOriginal(distance: target.distance(to: ball), surface: lie)
            : PGAClub.recommended(distance: target.distance(to: ball), surface: lie)
    }

    /// The same three-click swing is used by keyboard, mouse, and gamepad.
    mutating func swing() {
        switch phase {
        case .aiming:
            phase = .power; meterTime = 0; meter = 0
            message = "Press again at your desired power."
        case .power:
            shotPower = max(0.04, min(1, meter)); phase = .accuracy; meterTime = 0; meter = -1
            message = "Press as the marker crosses the center line for a straight shot."
        case .accuracy:
            strike(power: shotPower, accuracy: meter)
        default: break
        }
    }

    mutating func cancelSwing() {
        guard phase.swinging else { return }
        phase = .aiming; meter = 0; message = "Swing canceled. Adjust your aim or club."
    }

    /// Deterministic launch API, also useful for replay and regression tests.
    mutating func strike(power: Double, accuracy: Double) {
        guard phase == .aiming || phase.swinging else { return }
        shotPower = max(0.04, min(1, power)); shotAccuracy = max(-1, min(1, accuracy))
        if course.isOriginal {
            strikeOriginal()
            return
        }
        let launch = launchFactor
        shotFromTee = strokes == 0; shotLie = lie
        events.append(.strike(club: club, lie: lie, power: shotPower, accuracy: shotAccuracy, fromTee: shotFromTee))
        let angle = heading + shotAccuracy * (club == .putter ? 0.09 : 0.14)
        let speed = club.speed * shotPower * launch * (1 - abs(shotAccuracy) * 0.12)
        velocity = PGAVector(x: sin(angle) * speed * cos(club.loft), y: speed * sin(club.loft), z: cos(angle) * speed * cos(club.loft))
        shotOrigin = ball; originLieIndex = lieIndex; bunkerEntry = nil
        strokes += 1; lowSpeedTime = 0; flightTime = 0; accumulator = 0; missingFloorTime = 0
        phase = club == .putter ? .rolling : .airborne
        if phase == .airborne { ball.y += 0.01 }
        message = abs(shotAccuracy) < 0.08 ? "Clean strike" : shotAccuracy < 0 ? "Pulled left" : "Pushed right"
    }

    private mutating func strikeOriginal() {
        let adapter = flightTerrains[holeIndex]
        guard let floor = lieSample else {
            phase = .aiming; message = "No playable floor under the ball. Try another lie."
            return
        }
        let surface = adapter.surface(for: floor)
        let index = PGABallSwing.usableLieIndex(lieIndex, surface: surface)
        let start = adapter.frame.point(meters: ball - PGAVector(x: 0, y: Self.ballRadius, z: 0))
        let launch = PGABallSwing.launch(club: PGABallSwing.originalIndex(for: club), power: shotPower,
                                         accuracy: shotAccuracy, heading: heading, position: start,
                                         lieIndex: index, lieAccuracy: PGABallSwing.lieAccuracyFactor(
                                            flags: surface.records[index].flags, index: index))
        let pin = adapter.frame.point(meters: hole.cup)
        guard let started = PGABallFlight(launch: launch, terrain: adapter,
                                          conditions: .fromSettings(greenCondition: 3, roughLength: 2, difficulty: 2),
                                          ball: .solidCore, pin: pin, random: random) else {
            phase = .aiming; message = "Unable to start the shot from this lie."
            return
        }
        flight = started
        shotOrigin = ball; originLieIndex = lieIndex
        shotFromTee = strokes == 0; shotLie = lie
        strokes += 1; accumulator = 0
        velocity = adapter.frame.metersPerSecond(started.velocity)
        phase = started.state == .flying ? .airborne : .rolling
        events.append(.strike(club: club, lie: shotLie, power: shotPower, accuracy: shotAccuracy, fromTee: shotFromTee))
        message = abs(shotAccuracy) < 0.08 ? "Clean strike" : shotAccuracy < 0 ? "Pulled left" : "Pushed right"
    }

    mutating func update(deltaTime: Double) {
        guard deltaTime.isFinite, deltaTime > 0 else { return }
        let delta = min(deltaTime, 0.12)
        if phase == .power {
            meterTime += delta
            meter = 1 - abs(1 - meterTime.truncatingRemainder(dividingBy: 2.4) / 1.2)
            return
        }
        if phase == .accuracy {
            meterTime += delta
            meter = -cos(meterTime * .pi / 0.65)
            return
        }
        guard phase.inMotion else { return }
        accumulator += delta
        let stepSize = course.isOriginal ? 1.0 / PGABallFlight.referenceFPS : Self.fixedStep
        while accumulator >= stepSize && phase.inMotion {
            accumulator -= stepSize
            if course.isOriginal { stepOriginal() } else { step(Self.fixedStep) }
        }
    }

    private mutating func stepOriginal() {
        guard var active = flight else { return }
        let adapter = flightTerrains[holeIndex]
        let changes = active.step(terrain: adapter)
        flight = active
        ball = adapter.frame.meters(active.position) + PGAVector(x: 0, y: Self.ballRadius, z: 0)
        velocity = adapter.frame.metersPerSecond(active.velocity)
        lastShotDistance = ball.distance(to: shotOrigin)
        for change in changes {
            switch change {
            case let .impact(position, normalSpeed, _, surface, _, bounce):
                let flags = surface.records[0].flags
                if flags & PGABallSurfaceFlag.water != 0 { applyPenalty(.water); return }
                if flags & PGABallSurfaceFlag.outOfBounds != 0 { applyPenalty(.out); return }
                if bounce == 1 || normalSpeed >= 0.5 {
                    let point = adapter.frame.meters(position) + PGAVector(x: 0, y: Self.ballRadius, z: 0)
                    events.append(.impact(position: point, surface: surface.category, soundID: surface.soundID,
                                          normalSpeed: normalSpeed * PGABallFlightFrame.metersPerInch * PGABallFlight.referenceFPS))
                }
            case .holed:
                random = active.random
                flight = nil
                events.append(.cup)
                finishHole(); return
            case .outOfWorld:
                applyPenalty(.out); return
            default: break
            }
        }
        phase = active.state == .flying ? .airborne : .rolling
        // Rolling can enter a hazard without another impact event.
        if phase == .rolling, let floor = lieSample, floor.surface == .water || floor.surface == .out {
            applyPenalty(floor.surface); return
        }
        if active.isFinished {
            random = active.random
            lieIndex = active.nextLieIndex ?? 0
            flight = nil
            endShot()
        }
    }

    private mutating func step(_ dt: Double) {
        flightTime += dt
        if phase == .airborne {
            let previousHeight = ball.y
            let drag = 0.0019 * velocity.length
            velocity.x -= velocity.x * drag * dt
            velocity.z -= velocity.z * drag * dt
            velocity.y -= (9.81 + velocity.y * drag) * dt
            ball = ball + velocity * dt
            // Only floors at or below the ball's previous height can stop it;
            // a bridge or roof above the ball does not act as a ceiling.
            guard let floor = ground(x: ball.x, z: ball.z, ceiling: previousHeight + 0.05) else {
                // Outside this hole's world. Allow a brief miss over a gap in
                // the source mesh before treating the ball as out of bounds.
                missingFloorTime += dt
                if missingFloorTime > 0.25 && velocity.y < 0 { applyPenalty(.out); return }
                if flightTime > 35 { endShot() }
                return
            }
            missingFloorTime = 0
            if ball.y <= floor.height + Self.ballRadius {
                ball.y = floor.height + Self.ballRadius
                let n0 = floor.normal
                let impactSpeed = -(velocity.x * n0.x + velocity.y * n0.y + velocity.z * n0.z)
                events.append(.impact(position: ball, surface: floor.surface, soundID: floor.properties?.soundID, normalSpeed: impactSpeed))
                if floor.surface == .water || floor.surface == .out { applyPenalty(floor.surface); return }
                noteBunker(floor)
                // Reflect about the sampled triangle normal. Coefficients are
                // provisional per category, not decoded original values.
                let n = floor.normal
                let normalSpeed = velocity.x * n.x + velocity.y * n.y + velocity.z * n.z
                let (restitution, retention) = floor.surface.impact
                let tangential = velocity - n * normalSpeed
                if normalSpeed < -3 && restitution > 0 {
                    velocity = tangential * retention - n * (normalSpeed * restitution)
                } else {
                    velocity = tangential * retention; velocity.y = 0; phase = .rolling
                }
            }
        } else {
            guard let floor = ground(x: ball.x, z: ball.z, ceiling: ball.y + 0.3) else { applyPenalty(.out); return }
            let surface = floor.surface
            if surface == .water || surface == .out { applyPenalty(surface); return }
            noteBunker(floor)
            // Capture only a slow ball that actually crosses the cup. A fast
            // approach can roll over it, and a ball behind it cannot disappear.
            let next = ball + velocity * dt
            let travel = next - ball
            let toCup = hole.cup - ball
            let t = max(0, min(1, (toCup.x * travel.x + toCup.z * travel.z) / max(0.000001, travel.x * travel.x + travel.z * travel.z)))
            if (ball + travel * t).distance(to: hole.cup) < 0.24 && velocity.horizontalLength < 2.7 {
                events.append(.cup)
                finishHole(); return
            }
            let gradient = floor.gradient
            let speed = velocity.horizontalLength
            // Original surfaces use the recovered PureRolling deceleration;
            // the slip phase and impact model remain native approximations.
            let resistance = floor.properties?.rollingDeceleration(normalY: floor.normal.y) ?? surface.rollingFriction
            if speed > 0.001 {
                let nextSpeed = max(0, speed - resistance * dt)
                velocity = velocity.horizontalUnit * nextSpeed
            }
            // Static friction prevents an almost-stationary ball from creeping
            // forever on small terrain gradients.
            if speed > 0.18 || gradient.horizontalLength * 9.81 > resistance * 0.9 {
                velocity = velocity - gradient * (9.81 * dt)
            }
            ball = ball + velocity * dt
            let climb = max(0.3, velocity.horizontalLength * dt * 3)
            guard let landed = ground(x: ball.x, z: ball.z, ceiling: ball.y + climb) else { applyPenalty(.out); return }
            ball.y = landed.height + Self.ballRadius
            if velocity.horizontalLength < 0.14 { lowSpeedTime += dt } else { lowSpeedTime = 0 }
            if lowSpeedTime > 0.4 { endShot() }
        }
        lastShotDistance = ball.distance(to: shotOrigin)
        if flightTime > 35 { endShot() } // finite recovery for unusual imported terrain
    }

    private mutating func noteBunker(_ floor: PGAGroundSample) {
        guard bunkerEntry == nil, let flags = floor.properties?.flags, flags & 0x8 != 0 else { return }
        bunkerEntry = (ball, velocity.length)
    }

    /// Lie index chosen when the ball stops (CBallFlight::StopBall 0x101f769c).
    /// Speeds are original inches per 60 Hz tick; 6 units of movement is 6 in.
    /// The draw order of the random calls is not verified.
    private mutating func restingLieIndex(_ sample: PGAGroundSample?) -> Int {
        guard let properties = sample?.properties else { return 0 }
        let flags = properties.flags
        if flags & 0x8 != 0 {
            guard let entry = bunkerEntry else { return 1 }
            let moved = max(abs(ball.x - entry.position.x), abs(ball.y - entry.position.y), abs(ball.z - entry.position.z))
            let inch = 0.0254
            let speed = entry.speed / inch / 60
            if moved >= 6 * inch || speed < 10 { return 1 }
            if speed < 12 || random.unit() <= 0.9 { return random.unit() < 0.1 ? 2 : 0 }
            if (speed >= 14 && random.unit() > 0.9) || random.unit() < 0.1 { return 3 }
            return 2
        }
        if flags & 0x2 != 0 {
            if properties.isBlend { return 1 }
            return random.int(2) > 0 ? 0 : random.int(properties.records.count)
        }
        return 0
    }

    private mutating func applyPenalty(_ hazard: PGASurface) {
        flight = nil
        events.append(.penalty(hazard))
        strokes += 1; ball = shotOrigin; lieIndex = originLieIndex; velocity = .zero; phase = .aiming
        lastShotDistance = 0
        if strokes >= 12 { finishHole(pickedUp: true); return }
        message = "\(hazard == .water ? "Water hazard" : "Out of bounds") · one penalty stroke · replay from your previous lie"
        alignToPlayLine()
        passTurn()
    }

    private mutating func endShot() {
        velocity = .zero; phase = .aiming
        lastShotDistance = ball.distance(to: shotOrigin)
        if strokes >= 12 { finishHole(pickedUp: true); return }
        var note = ""
        let resting = lieSample
        if lie == .unplayable, let drop = nearestPlayableDrop() {
            // Original flag 0x400 grants free relief (roads, paths); other
            // unplayable surfaces cost a stroke. Drop placement is native.
            let free = resting?.properties?.freeDrop ?? true
            if !free { strokes += 1 }
            ball = drop; note = free ? " · free drop from \(resting?.lie ?? "an unplayable surface")" : " · unplayable · one-stroke drop"
        } else if !lie.playable {
            ball = shotOrigin; note = " · no playable drop found, replaying the previous lie"
        }
        if !course.isOriginal { lieIndex = restingLieIndex(lieSample) }
        events.append(.rest(lie: lie, distanceToPin: distanceToCup, shotDistance: lastShotDistance, fromTee: shotFromTee))
        alignToPlayLine()
        message = "\(lieLabel) · \(Int((distanceToCup * 1.09361).rounded())) yd to the pin\(note)"
        passTurn()
    }

    // MARK: Turns

    private mutating func saveTurn() {
        players[currentPlayer].ball = ball; players[currentPlayer].strokes = strokes
        players[currentPlayer].heading = heading; players[currentPlayer].club = club.rawValue
        players[currentPlayer].lieIndex = lieIndex
    }

    private mutating func loadTurn(_ index: Int) {
        flight = nil
        currentPlayer = index
        let player = players[index]
        ball = player.ball; strokes = player.strokes; heading = player.heading
        club = PGAClub(rawValue: player.club) ?? .driver; lieIndex = player.lieIndex
        shotOrigin = ball; originLieIndex = lieIndex; bunkerEntry = nil
        velocity = .zero; phase = .aiming; meter = 0; shotPower = 0; shotAccuracy = 0; lastShotDistance = 0
        accumulator = 0; lowSpeedTime = 0; flightTime = 0; missingFloorTime = 0
    }

    /// Who plays next: players yet to tee off go in honor order, then the
    /// player farthest from the hole ("away"), lower list order on a tie.
    private func nextPlayer() -> Int? {
        let waiting = players.indices.filter { !players[$0].holed }
        if let teeing = teeOrder.first(where: { waiting.contains($0) && players[$0].strokes == 0 }) { return teeing }
        return waiting.max { a, b in
            let da = players[a].ball.distance(to: hole.cup), db = players[b].ball.distance(to: hole.cup)
            return da == db ? a > b : da < db
        }
    }

    private mutating func passTurn() {
        guard players.count > 1, phase == .aiming else { return }
        let previous = currentPlayer
        saveTurn()
        guard let next = nextPlayer(), next != previous else { return }
        let note = message
        loadTurn(next)
        message = "\(playerName) is away · \(lieLabel) · \(Int((distanceToCup * 1.09361).rounded())) yd · (\(players[previous].name): \(note))"
    }

    /// Nearest playable floor within 30 m that is not nearer the hole.
    private func nearestPlayableDrop() -> PGAVector? {
        let limit = distanceToCup
        for radius in stride(from: 0.75, through: 30, by: 0.75) {
            let count = max(8, Int(radius * 4))
            for index in 0..<count {
                let angle = Double(index) / Double(count) * 2 * .pi
                let x = ball.x + cos(angle) * radius, z = ball.z + sin(angle) * radius
                guard hypot(hole.cup.x - x, hole.cup.z - z) >= limit,
                      let sample = ground(x: x, z: z, ceiling: ball.y + 3), sample.surface.playable,
                      sample.normal.y > 0.8 else { continue }
                return PGAVector(x: x, y: sample.height + Self.ballRadius, z: z)
            }
        }
        return nil
    }

    private mutating func finishHole(pickedUp: Bool = false) {
        flight = nil
        velocity = .zero
        players[currentPlayer].holed = true
        if !pickedUp {
            ball = PGAVector(x: hole.cup.x, y: groundHeight(x: hole.cup.x, z: hole.cup.z, near: hole.cup.y) - 0.04, z: hole.cup.z)
        }
        phase = .holed
        if !pickedUp { events.append(.holed(strokes: strokes, par: hole.par, shotDistance: lastShotDistance, onGreen: shotLie == .green || shotLie == .fringe)) }
        let difference = strokes - hole.par
        let scoreName: String
        switch difference {
        case ...(-3): scoreName = "Albatross"
        case -2: scoreName = "Eagle"
        case -1: scoreName = "Birdie"
        case 0: scoreName = "Par"
        case 1: scoreName = "Bogey"
        case 2: scoreName = "Double bogey"
        default: scoreName = "+\(difference)"
        }
        message = (isMultiplayer ? "\(playerName): " : "") +
            (pickedUp ? "Picked up at the 12-stroke limit" : "\(scoreName) · \(strokes) \(strokes == 1 ? "stroke" : "strokes")")
        saveTurn()
    }

    /// After a player holes out: the next player continues, or once everyone
    /// is in, scores are recorded and the next hole begins.
    mutating func continueRound() {
        guard phase == .holed else { return }
        if !holeComplete, let next = nextPlayer() {
            let done = message
            loadTurn(next)
            message = "\(playerName) to play · \(lieLabel) · \(Int((distanceToCup * 1.09361).rounded())) yd (\(done))"
            return
        }
        for index in players.indices { players[index].scores.append(players[index].strokes) }
        if holeIndex + 1 < course.holes.count { holeIndex += 1; resetHole() }
        else {
            phase = .roundComplete
            message = isMultiplayer ? "Round complete" : "\(course.isOriginal ? "Round" : "Practice round") complete · \(completedStrokes) strokes"
        }
    }

    mutating func restartRound() {
        holeIndex = 0
        for index in players.indices { players[index].scores = [] }
        resetHole()
    }

    /// Honors: lowest score on the previous hole tees off first.
    private var teeOrder: [Int] {
        guard holeIndex > 0 else { return Array(players.indices) }
        return players.indices.sorted { a, b in
            let sa = players[a].scores.last ?? 0, sb = players[b].scores.last ?? 0
            return sa == sb ? a < b : sa < sb
        }
    }

    mutating func resetHole() {
        flight = nil
        let tee = hole.tee
        ball = PGAVector(x: tee.x, y: groundHeight(x: tee.x, z: tee.z, near: tee.y) + Self.ballRadius, z: tee.z)
        velocity = .zero; phase = .aiming; strokes = 0; meter = 0; shotPower = 0; shotAccuracy = 0
        accumulator = 0; lowSpeedTime = 0; flightTime = 0; lastShotDistance = 0; missingFloorTime = 0
        lieIndex = 0; originLieIndex = 0; bunkerEntry = nil
        shotOrigin = ball
        alignToPlayLine()
        for index in players.indices {
            players[index].ball = ball; players[index].strokes = 0; players[index].holed = false
            players[index].heading = heading; players[index].club = club.rawValue; players[index].lieIndex = 0
        }
        currentPlayer = teeOrder.first ?? 0
        message = isMultiplayer ? "\(playerName) has the honor · Space, click or A to swing" : "Aim, choose a club, then press Space, click, or A to swing."
    }

    #if DEBUG
    /// Test helper: records a finished hole with the given strokes.
    mutating func restore(strokes: Int) {
        guard phase != .roundComplete else { return }
        for index in players.indices { players[index].strokes = strokes; players[index].holed = true }
        self.strokes = strokes; phase = .holed; continueRound()
    }
    #endif

    #if DEBUG
    /// Test helper: the active player holes out in `strokes` and play moves on.
    mutating func restoreHoleForTest(strokes: Int) {
        self.strokes = strokes
        finishHole(pickedUp: true)
        continueRound()
    }
    #endif

    /// A snapshot is taken only while the ball is at rest.
    var snapshot: PGARoundSnapshot? {
        guard phase == .aiming else { return nil }
        var copy = self
        copy.saveTurn()
        return PGARoundSnapshot(courseIdentity: course.identity, holeIndex: holeIndex, scores: scores, strokes: strokes,
                                ball: ball, heading: heading, club: club.rawValue, lieIndex: lieIndex, randomState: random.state,
                                players: copy.players, currentPlayer: currentPlayer)
    }

    enum RestoreError: LocalizedError, Equatable {
        case mismatchedCourse, invalid(String)
        var errorDescription: String? {
            switch self {
            case .mismatchedCourse: return "The saved round belongs to different course data."
            case let .invalid(reason): return reason
            }
        }
    }

    mutating func restore(_ snapshot: PGARoundSnapshot) throws {
        guard snapshot.schemaVersion == 1, snapshot.courseIdentity == course.identity else { throw RestoreError.mismatchedCourse }
        guard course.holes.indices.contains(snapshot.holeIndex), snapshot.scores.count == snapshot.holeIndex,
              snapshot.scores.allSatisfy({ (1...99).contains($0) }), (0...99).contains(snapshot.strokes),
              let restoredClub = PGAClub(rawValue: snapshot.club), snapshot.heading.isFinite,
              [snapshot.ball.x, snapshot.ball.y, snapshot.ball.z].allSatisfy(\.isFinite) else {
            throw RestoreError.invalid("The saved round contains invalid values.")
        }
        holeIndex = snapshot.holeIndex
        guard let floor = ground(x: snapshot.ball.x, z: snapshot.ball.z, ceiling: snapshot.ball.y + 0.3),
              abs(floor.height + Self.ballRadius - snapshot.ball.y) < 0.05 else {
            resetHole()
            throw RestoreError.invalid("The saved ball position is not on this hole's floor.")
        }
        resetHole()
        if let saved = snapshot.players, let current = snapshot.currentPlayer {
            guard saved.count == players.count, saved.indices.contains(current),
                  zip(saved, players).allSatisfy({ $0.0.name == $0.1.name }),
                  saved.allSatisfy({ $0.scores.count == snapshot.holeIndex && $0.scores.allSatisfy { (1...99).contains($0) }
                                     && (0...99).contains($0.strokes) && $0.heading.isFinite && PGAClub(rawValue: $0.club) != nil
                                     && [$0.ball.x, $0.ball.y, $0.ball.z].allSatisfy(\.isFinite) }) else {
                throw RestoreError.invalid("The saved players do not match this round.")
            }
            players = saved
            loadTurn(current)
        } else {
            guard players.count == 1 else { throw RestoreError.invalid("The saved round has no player list.") }
            players[0].scores = snapshot.scores
            strokes = snapshot.strokes
            ball = snapshot.ball; shotOrigin = ball; heading = snapshot.heading; club = restoredClub
            lieIndex = max(0, min(8, snapshot.lieIndex ?? 0)); originLieIndex = lieIndex
            saveTurn()
        }
        if let state = snapshot.randomState { random.state = state }
        message = "Round restored · \(lieLabel) · \(Int((distanceToCup * 1.09361).rounded())) yd to the pin"
    }
}

/// Round formats computed from recorded hole scores only.
enum PGAGameType: String, Codable, CaseIterable {
    case stroke, match, skins
    var title: String { ["Stroke play", "Match play", "Skins"][Self.allCases.firstIndex(of: self)!] }
}

enum PGAStandings {
    /// Hole-by-hole match status for two players: positive means player 0 up.
    static func match(_ a: [Int], _ b: [Int], holes: Int = 18) -> (status: Int, played: Int, decided: String?) {
        var status = 0, played = 0
        for (x, y) in zip(a, b) {
            played += 1
            if x < y { status += 1 } else if y < x { status -= 1 }
            let remaining = holes - played
            if abs(status) > remaining { return (status, played, remaining == 0 ? "\(abs(status)) UP" : "\(abs(status))&\(remaining)") }
        }
        return (status, played, nil)
    }

    /// Skins won per player; a tied hole carries its skin to the next.
    static func skins(_ scores: [[Int]]) -> (won: [Int], carried: Int) {
        var won = Array(repeating: 0, count: scores.count), carry = 0
        let holes = scores.map(\.count).min() ?? 0
        for hole in 0..<holes {
            let values = scores.map { $0[hole] }
            let best = values.min()!
            let winners = values.indices.filter { values[$0] == best }
            carry += 1
            if winners.count == 1 { won[winners[0]] += carry; carry = 0 }
        }
        return (won, carry)
    }

    static func summary(type: PGAGameType, players: [PGAPlayer], holes: Int, complete: Bool) -> String? {
        guard players.count > 1 else { return nil }
        switch type {
        case .stroke:
            let totals = players.map { $0.scores.reduce(0, +) }
            guard let best = totals.min() else { return nil }
            let leaders = players.indices.filter { totals[$0] == best }.map { players[$0].name }
            return complete ? (leaders.count == 1 ? "\(leaders[0]) wins with \(best)" : "Tied at \(best): \(leaders.joined(separator: ", "))")
                            : "Leader: \(leaders.joined(separator: ", ")) (\(best))"
        case .match:
            guard players.count == 2 else { return "Match play needs two players; showing stroke totals" }
            let result = match(players[0].scores, players[1].scores, holes: holes)
            let leader = result.status > 0 ? players[0].name : players[1].name
            if let decided = result.decided { return "\(leader) wins \(decided)" }
            if result.played == 0 { return "Match play · all square" }
            return result.status == 0 ? "All square thru \(result.played)" : "\(leader) \(abs(result.status)) UP thru \(result.played)"
        case .skins:
            let result = skins(players.map(\.scores))
            let text = players.indices.map { "\(players[$0].name) \(result.won[$0])" }.joined(separator: " · ")
            return "Skins: \(text)" + (result.carried > 0 ? " · \(result.carried) carried" : "")
        }
    }
}
