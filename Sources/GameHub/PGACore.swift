import Foundation

// Native development simulation. These values and rules are deliberately
// independent of SceneKit, input devices, and the as-yet-undecoded 2005 engine.
// Replace PGACourse.development with a decoded course to retain the same runtime.
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

enum PGASurface: String, Codable {
    case tee = "Tee", fairway = "Fairway", rough = "Rough", green = "Green", sand = "Bunker", water = "Water", out = "Out of bounds"
    var rollingFriction: Double {
        switch self {
        case .green: return 0.48
        case .tee, .fairway: return 1.35
        case .rough: return 3.2
        case .sand: return 6.3
        case .water, .out: return 5
        }
    }
    var launchFactor: Double {
        switch self {
        case .rough: return 0.82
        case .sand: return 0.65
        default: return 1
        }
    }
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
        if surface == .green { return .putter }
        if surface == .sand && distance < 65 { return .sandWedge }
        return allCases.dropLast().reversed().first { $0.estimatedCarry >= distance } ?? .driver
    }
}

enum PGAPhase: String {
    case aiming, power, accuracy, airborne, rolling, holed, roundComplete
    var inMotion: Bool { self == .airborne || self == .rolling }
    var swinging: Bool { self == .power || self == .accuracy }
}

struct PGASimulation {
    static let ballRadius = 0.02135
    static let fixedStep = 1.0 / 120.0
    var course: PGACourse
    private(set) var holeIndex = 0
    private(set) var ball: PGAVector = .zero
    private(set) var velocity: PGAVector = .zero
    private(set) var phase: PGAPhase = .aiming
    private(set) var strokes = 0
    private(set) var scores: [Int] = []
    private(set) var heading: Double = 0
    private(set) var club: PGAClub = .driver
    private(set) var meter = 0.0
    private(set) var shotPower = 0.0
    private(set) var shotAccuracy = 0.0
    private(set) var lastShotDistance = 0.0
    private(set) var message = "Aim, choose a club, then press Space or A to start your swing."
    private var meterTime = 0.0
    private var accumulator = 0.0
    private var shotOrigin: PGAVector = .zero
    private var lowSpeedTime = 0.0
    private var flightTime = 0.0
    var hole: PGAHole { course.holes[holeIndex] }
    var distanceToCup: Double { ball.distance(to: hole.cup) }
    var lie: PGASurface { hole.surface(x: ball.x, z: ball.z) }
    var direction: PGAVector { PGAVector(x: sin(heading), y: 0, z: cos(heading)) }
    var completedStrokes: Int { scores.reduce(0, +) }
    var scoreToPar: Int { zip(scores, course.holes).reduce(0) { $0 + $1.0 - $1.1.par } }
    var targetDistance: Double { club.estimatedCarry * (lie == .rough || lie == .sand ? lie.launchFactor * lie.launchFactor : 1) }

    init(course: PGACourse = .development) {
        precondition(!course.holes.isEmpty, "A native golf course needs at least one hole")
        self.course = course
        resetHole()
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
        let angle = heading + shotAccuracy * (club == .putter ? 0.09 : 0.14)
        let speed = club.speed * shotPower * lie.launchFactor * (1 - abs(shotAccuracy) * 0.12)
        velocity = PGAVector(x: sin(angle) * speed * cos(club.loft), y: speed * sin(club.loft), z: cos(angle) * speed * cos(club.loft))
        shotOrigin = ball; strokes += 1; lowSpeedTime = 0; flightTime = 0; accumulator = 0
        phase = club == .putter ? .rolling : .airborne
        if phase == .airborne { ball.y += 0.01 }
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
        while accumulator >= Self.fixedStep && phase.inMotion {
            accumulator -= Self.fixedStep
            step(Self.fixedStep)
        }
    }

    private mutating func step(_ dt: Double) {
        flightTime += dt
        if phase == .airborne {
            let drag = 0.0019 * velocity.length
            velocity.x -= velocity.x * drag * dt
            velocity.z -= velocity.z * drag * dt
            velocity.y -= (9.81 + velocity.y * drag) * dt
            ball = ball + velocity * dt
            let ground = hole.height(x: ball.x, z: ball.z) + Self.ballRadius
            if ball.y <= ground {
                ball.y = ground
                if lie == .water || lie == .out { applyPenalty(); return }
                if velocity.y < -3 && lie != .sand {
                    velocity.y = -velocity.y * 0.28
                    velocity.x *= 0.74; velocity.z *= 0.74
                } else {
                    phase = .rolling; velocity.y = 0
                }
            }
        } else {
            let surface = lie
            if surface == .water || surface == .out { applyPenalty(); return }
            // Capture only a slow ball that actually crosses the cup. A fast
            // approach can roll over it, and a ball behind it cannot disappear.
            let next = ball + velocity * dt
            let travel = next - ball
            let toCup = hole.cup - ball
            let t = max(0, min(1, (toCup.x * travel.x + toCup.z * travel.z) / max(0.000001, travel.x * travel.x + travel.z * travel.z)))
            if (ball + travel * t).distance(to: hole.cup) < 0.24 && velocity.horizontalLength < 2.7 {
                finishHole(); return
            }
            let gradient = hole.gradient(x: ball.x, z: ball.z)
            let speed = velocity.horizontalLength
            if speed > 0.001 {
                let nextSpeed = max(0, speed - surface.rollingFriction * dt)
                velocity = velocity.horizontalUnit * nextSpeed
            }
            // Static friction prevents an almost-stationary ball from creeping
            // forever on small terrain gradients.
            if speed > 0.18 || gradient.horizontalLength * 9.81 > surface.rollingFriction * 0.9 {
                velocity = velocity - gradient * (9.81 * dt)
            }
            ball = ball + velocity * dt
            ball.y = hole.height(x: ball.x, z: ball.z) + Self.ballRadius
            if velocity.horizontalLength < 0.14 { lowSpeedTime += dt } else { lowSpeedTime = 0 }
            if lowSpeedTime > 0.4 { endShot() }
        }
        lastShotDistance = ball.distance(to: shotOrigin)
        if flightTime > 35 { endShot() } // finite recovery for unusual imported terrain
    }

    private mutating func applyPenalty() {
        let hazard = lie
        strokes += 1; ball = shotOrigin; velocity = .zero; phase = .aiming
        message = "\(hazard == .water ? "Water hazard" : "Out of bounds") · one penalty stroke · replay from your previous lie"
        alignToCup(); club = PGAClub.recommended(distance: distanceToCup, surface: lie)
    }

    private mutating func endShot() {
        velocity = .zero; phase = .aiming
        lastShotDistance = ball.distance(to: shotOrigin)
        if strokes >= 12 { finishHole(pickedUp: true); return }
        alignToCup(); club = PGAClub.recommended(distance: distanceToCup, surface: lie)
        message = "\(lie.rawValue) · \(Int((distanceToCup * 1.09361).rounded())) yd to the pin"
    }

    private mutating func finishHole(pickedUp: Bool = false) {
        velocity = .zero
        if !pickedUp { ball = hole.position(x: hole.cup.x, z: hole.cup.z); ball.y -= 0.04 }
        phase = .holed
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
        message = pickedUp ? "Picked up at the 12-stroke practice limit" : "\(scoreName) · \(strokes) \(strokes == 1 ? "stroke" : "strokes")"
    }

    mutating func continueRound() {
        guard phase == .holed else { return }
        scores.append(strokes)
        if holeIndex + 1 < course.holes.count { holeIndex += 1; resetHole() }
        else { phase = .roundComplete; message = "Practice round complete · \(completedStrokes) strokes" }
    }

    mutating func restartRound() {
        holeIndex = 0; scores = []; resetHole()
    }

    mutating func resetHole() {
        ball = hole.position(x: hole.tee.x, z: hole.tee.z); ball.y += Self.ballRadius
        velocity = .zero; phase = .aiming; strokes = 0; meter = 0; shotPower = 0; shotAccuracy = 0
        accumulator = 0; lowSpeedTime = 0; flightTime = 0; lastShotDistance = 0
        shotOrigin = ball
        heading = atan2(hole.cup.x - ball.x, hole.cup.z - ball.z)
        club = PGAClub.recommended(distance: distanceToCup, surface: lie)
        message = "Aim, choose a club, then press Space, click, or A to swing."
    }
}
