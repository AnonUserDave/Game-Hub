import Foundation

// Swift port of a static reconstruction of PGA Tour 2005 CBallFlight.
//
// This mirrors Tools/pga2005_ballflight_reference.py, which implements the
// static reconstruction in docs/research/PGA2005-PHYSICS.md (Engine.dll
// decompilation; never compared with a running copy of the game). It is a
// port of that reference, not original source.
//
// Units and frame are the original's:
// - lengths in inches; one tick = 1/fps s (60 Hz for human shots); velocity in
//   inches per tick; spin in radians per tick;
// - LEFT-HANDED axes: +Y up, +Z forward for aim angle 0, +X to the right of
//   +Z (CVector3::RotateY turns +Z toward +X);
// - y tracks the ball's contact point (bottom), not its centre.
// PGABallFlightFrame converts to and from the game's right-handed meters.
//
// Arithmetic keeps the reference's operation order and its f32() stores, so
// Swift matches Python to a few ulps (Tests/Swift/PGABallFlightTests.swift
// compares golden fixtures from Tools/make_ballflight_fixtures.py). Do not
// "simplify" expressions here: reassociating them changes results.
//
// Not modelled (as in the reference): steep-wall segment tests, trees
// (section flag 0x8 only reports an event), objects, the quick/precise height
// split beyond the 1-inch rule, and the swing-control layer (see PGABallSwing,
// which is an assumption-labelled mapping, not a reconstruction).

/// IEEE single-precision store, as the original does on float writes.
@inline(__always) private func f32(_ value: Double) -> Double { Double(Float(value)) }

// MARK: - Vector

/// A vector in the original internal frame: inches, +Y up, left-handed.
struct PGABallVector: Equatable, Codable {
    var x: Double
    var y: Double
    var z: Double
    static let zero = PGABallVector(x: 0, y: 0, z: 0)
    init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
    init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    /// sqrt(x·x + y·y + z·z), summed in the reference's order (`_norm`).
    var length: Double { (x * x + y * y + z * z).squareRoot() }
    var horizontalLength: Double { hypot(x, z) }

    // The original's 2-D rotation idiom (`_rot`): a' = c·a + s·b; b' = c·b − s·a.
    @inline(__always) mutating func rotateYX(_ s: Double, _ c: Double) { let old = y; y = c * y + s * x; x = c * x - s * old }
    @inline(__always) mutating func rotateZY(_ s: Double, _ c: Double) { let old = z; z = c * z + s * y; y = c * y - s * old }
    @inline(__always) mutating func rotateZX(_ s: Double, _ c: Double) { let old = z; z = c * z + s * x; x = c * x - s * old }
}

// MARK: - Surfaces

/// Surface record flags (TCL record +0x28) and texture-section flags (+0xa).
enum PGABallSurfaceFlag {
    static let fairway: UInt32 = 0x1
    static let rough: UInt32 = 0x2
    static let green: UInt32 = 0x4
    static let bunker: UInt32 = 0x8
    static let fringe: UInt32 = 0x10
    static let unplayable: UInt32 = 0x20
    static let water: UInt32 = 0x40
    static let outOfBounds: UInt32 = 0x80
    static let hazard: UInt32 = 0x100
    static let freeDrop: UInt32 = 0x400
    static let disappears: UInt32 = 0x800
    static let tee: UInt32 = 0x1000
    /// fairway | green | fringe | tee
    static let shortGrass: UInt32 = 0x1015
    static let weed: UInt32 = 0x8000_0000
    static let sectionTree: UInt32 = 0x8
    static let sectionBlend: UInt32 = 0x80
    static let sectionAltBounce: UInt32 = 0x80000
}

/// One TCL surface record: c0…c9 (float32) and flags.
/// c0 lie power · c1 lie spin · c2 restitution · c3 friction · c4 slip gravity
/// loss · c5 slip friction · c6 break · c7 rolling resistance · c8 dent
/// divisor · c9 softness.
struct PGABallSurfaceRecord: Equatable {
    var name: String
    var flags: UInt32
    var c0, c1, c2, c3, c4, c5, c6, c7, c8, c9: Double
    var soundID: Int

    /// Coefficients are rounded to float32, as stored by the original; missing ones are 0.
    init(name: String = "", flags: UInt32, coefficients: [Double], soundID: Int = -1) {
        func c(_ index: Int) -> Double { index < coefficients.count ? f32(coefficients[index]) : 0 }
        self.name = name; self.flags = flags; self.soundID = soundID
        c0 = c(0); c1 = c(1); c2 = c(2); c3 = c(3); c4 = c(4); c5 = c(5); c6 = c(6); c7 = c(7); c8 = c(8); c9 = c(9)
    }
}

/// A material as the flight code reads it: its records and section flags.
/// Shared by reference; equality is identity.
final class PGABallSurface: Equatable, CustomStringConvertible {
    let name: String
    let sectionFlags: UInt32
    /// Never empty.
    let records: [PGABallSurfaceRecord]
    /// Collision sound key (basic.stn), when known.
    let soundID: Int?
    /// The game's surface category (record 0's flags).
    let category: PGASurface
    /// Source material, when this surface came from original course data.
    let properties: PGASurfaceProperties?

    init(name: String, sectionFlags: UInt32, records: [PGABallSurfaceRecord], soundID: Int? = nil, properties: PGASurfaceProperties? = nil) {
        self.name = name; self.sectionFlags = sectionFlags
        self.records = records.isEmpty ? [PGABallSurfaceRecord(name: "Fairway", flags: PGABallSurfaceFlag.fairway, coefficients: PGABallSurface.fairwayCoefficients)] : records
        self.soundID = soundID; self.properties = properties
        category = properties?.surface ?? PGASurfaceProperties.classify(flags: self.records[0].flags)
    }

    /// Wraps an original material (coefficients already float32 in materials.json).
    convenience init(properties: PGASurfaceProperties) {
        self.init(name: properties.materialName, sectionFlags: properties.sectionFlags,
                  records: properties.records.map { PGABallSurfaceRecord(name: $0.label, flags: $0.flags, coefficients: $0.coefficients, soundID: $0.soundID) },
                  soundID: properties.soundID, properties: properties)
    }

    static func == (a: PGABallSurface, b: PGABallSurface) -> Bool { a === b }
    var description: String { name }

    fileprivate static let fairwayCoefficients = [0.95, 0.95, 0.09, 0.25, 0.7, 0.7, 0.375, 0.3, 60.0, 0.2]

    private static func surface(_ name: String, _ section: UInt32, _ sound: Int?, _ records: [(String, UInt32, [Double])], recordSound: Int = -1) -> PGABallSurface {
        PGABallSurface(name: name, sectionFlags: section, records: records.map { PGABallSurfaceRecord(name: $0.0, flags: $0.1, coefficients: $0.2, soundID: recordSound) }, soundID: sound)
    }

    // Decoded Pebble Beach records (PBL.TCL via Tools/decode_pga2005_library.py),
    // identical to PBL_SURFACES in the Python reference.
    static let pblFairway = surface("pbl_fairway", 0x8002, 901, [("Fairway", 0x201, fairwayCoefficients)])
    static let pblGreen = surface("pbl_green", 0x2, 902, [("Green", 0x4, [0.975, 0.975, 0.07, 0.25, 0.7, 0.7, 0.375, 0.2, 36.0, 0.2])])
    static let pblFringe = surface("pbl_green_fringe", 0x808C1, 902, [("Fringe", 0x210, [0.95, 0.95, 0.07, 0.25, 0.7, 0.7, 0.375, 0.25, 48.0, 0.2])])
    static let pblTee = surface("pbl_teebox", 0x80002, 902, [("Tee Box", 0x1200, [1.0, 1.0, 0.07, 0.25, 0.7, 0.7, 0.375, 0.25, 36.0, 0.2])])
    static let pblRough = surface("pbl_rough", 0x8002, 905, [
        ("Md Rough", 0x202, [0.8, 0.7, 0.06, 0.15, 0.725, 0.725, 0.375, 0.9, 40.0, 0.3]),
        ("Lt Rough", 0x202, [0.9, 0.7, 0.06, 0.15, 0.725, 0.725, 0.375, 0.9, 40.0, 0.3]),
        ("Dp Rough", 0x202, [0.7, 0.7, 0.06, 0.15, 0.725, 0.725, 0.375, 0.9, 40.0, 0.3])])
    static let pblHeavyRough = surface("pbl_heavy_rough", 0x8002, 905, [0.63, 0.72, 0.54].map { (c0: Double) -> (String, UInt32, [Double]) in
        ("Dp Rough", 0x8000_0200, [c0, 0.6, 0.0015, 0.1, 0.75, 0.75, 0.375, 5.0, 17.33333, 0.4]) })
    static let pblBunker = surface("pbl_bunker", 0x2, 904, [
        ("Med Sand", 0x208, [0.5, 0.9, 0.008, 0.05, 0.6, 0.6, 0.375, 1.8, 5.0, 0.3]),
        ("Lt. Sand", 0x208, [0.6, 0.93, 0.008, 0.05, 0.6, 0.6, 0.375, 1.8, 5.0, 0.3]),
        ("Dp Sand", 0x208, [0.4, 0.6, 0.008, 0.05, 0.6, 0.6, 0.375, 1.8, 5.0, 0.3]),
        ("Plug Sand", 0x208, [0.3, 0.5, 0.008, 0.05, 0.6, 0.6, 0.375, 1.8, 5.0, 0.3])], recordSound: 904)
    static let pblOcean = surface("pbl_ocean", 0x402, nil, [("Unplayable", 0x960, [0.3, 0.3, 0.001, 0.01, 0.7, 0.7, 0.375, 10.0, 0.01, 0.2])])
    static let pblRoad = surface("pbl_road", 0x88042, 908, [("Unplayable", 0x2420, [1.0, 1.0, 0.69, 0.8, 0.9, 0.9, 0.375, 0.07, 600.0, 0.0])], recordSound: 908)
    /// Generated-terrain stand-in for out of bounds (no original record exists).
    static let outOfBounds = surface("out_of_bounds", 0, nil, [("Out of bounds", 0x80, fairwayCoefficients)])

    /// Keys match PBL_SURFACES in the Python reference.
    static let pebbleBeach: [String: PGABallSurface] = [
        "fairway": pblFairway, "green": pblGreen, "fringe": pblFringe, "tee": pblTee, "rough": pblRough,
        "heavy_rough": pblHeavyRough, "bunker": pblBunker, "ocean": pblOcean, "road": pblRoad,
    ]

    /// Stand-in records for generated terrain, which has no original material.
    static func fallback(for surface: PGASurface) -> PGABallSurface {
        switch surface {
        case .tee: return pblTee
        case .fairway: return pblFairway
        case .rough: return pblRough
        case .green: return pblGreen
        case .fringe: return pblFringe
        case .sand: return pblBunker
        case .water: return pblOcean
        case .unplayable: return pblRoad
        case .out: return outOfBounds
        }
    }
}

// MARK: - Terrain

/// One TerrainHeightCPP result in the internal frame.
struct PGABallTerrainSample {
    var height: Double
    /// Need not be unit length; the flight normalises it where the original does.
    var normal: PGABallVector
    var surface: PGABallSurface
}

/// Terrain seen by the flight, in internal inches. `ceiling` is a hint above
/// which floors are ignored (bridges, roofs); single-layer terrain ignores it.
/// Return nil outside the playable world (the flight then stops, out of world).
protocol PGABallFlightTerrain {
    func sample(x: Double, z: Double, ceiling: Double) -> PGABallTerrainSample?
}

/// Closure-backed terrain.
struct PGABallClosureTerrain: PGABallFlightTerrain {
    let body: (_ x: Double, _ z: Double, _ ceiling: Double) -> PGABallTerrainSample?
    init(_ body: @escaping (_ x: Double, _ z: Double, _ ceiling: Double) -> PGABallTerrainSample?) { self.body = body }
    /// Convenience for (x, z) terrain that has a single floor.
    init(xz body: @escaping (_ x: Double, _ z: Double) -> PGABallTerrainSample?) { self.body = { x, z, _ in body(x, z) } }
    func sample(x: Double, z: Double, ceiling: Double) -> PGABallTerrainSample? { body(x, z, ceiling) }
}

/// Planar terrain y = height + sx·x + sz·z (the reference's `flat_terrain`),
/// with axis-band surface regions and an optional far-Z world limit.
struct PGABallPlaneTerrain: PGABallFlightTerrain {
    struct Region {
        enum Axis: String { case x, z }
        var axis: Axis
        var lower = -Double.infinity
        var upper = Double.infinity
        var surface: PGABallSurface
        func contains(x: Double, z: Double) -> Bool {
            let value = axis == .x ? x : z
            return lower < value && value < upper
        }
    }
    var surface: PGABallSurface
    var height = 0.0
    var slopeX = 0.0
    var slopeZ = 0.0
    var regions: [Region] = []
    /// Points with z beyond this are outside the world.
    var maximumZ: Double? = nil

    func sample(x: Double, z: Double, ceiling: Double) -> PGABallTerrainSample? {
        if let maximumZ, z > maximumZ { return nil }
        var chosen = surface
        for region in regions where region.contains(x: x, z: z) { chosen = region.surface; break }
        return PGABallTerrainSample(height: height + slopeX * x + slopeZ * z, normal: PGABallVector(-slopeX, 1.0, -slopeZ), surface: chosen)
    }
}

// MARK: - Conditions, ball, launch

/// Course condition scalars read by the flight code (CBallFlight +4/+8/+0xc/+0x10/+0x14).
struct PGABallConditions: Equatable {
    /// GreenCond scale; >1 firmer/faster.
    var wet = 1.0
    /// RoughLength scale; 1.3 Light, 0.7 Heavy.
    var rough = 1.0
    /// Sand difficulty (1.0 on standard courses).
    var sand = 1.0
    /// Wind velocity of the air in mph along internal x and z (+z is a tailwind for aim 0).
    var windX = 0.0
    var windZ = 0.0
    /// CPlayer::GetMagnetEffect(); rough c0 bonus = 0.05·magnet.
    var magnet = 0.0

    static let wetScale: [Int: Double] = [1: f32(0.6), 2: f32(0.8), 3: 1.0, 4: f32(1.2), 5: f32(1.4)]
    static let roughScale: [Int: Double] = [1: f32(1.3), 2: 1.0, 3: f32(0.7)]
    /// CPlayer::GetMagnetEffect 0x1013c1a7, Novice…Expert.
    static let magnetEffect: [Int: Double] = [0: f32(0.8), 1: f32(0.45), 2: f32(0.05), 3: 0.0]
    /// CPlayer::GetAbilityFactor 0x1013bfad, Novice…Expert.
    static let abilityFactor: [Int: Double] = [0: 0.25, 1: f32(0.6), 2: f32(0.9), 3: 1.0]
    static let windMPHToInchesPerTick = 0.293333

    /// `Conditions.from_settings`: GREENCOND 1…5 and ROUGHLENGTH 1…3. With a
    /// difficulty, CGolfBall::SetupBall softens a wet scale above 1 and the
    /// player's magnet effect applies unless `magnet` is given.
    static func fromSettings(greenCondition: Int = 3, roughLength: Int = 2, difficulty: Int? = nil, magnet: Double? = nil,
                             sand: Double = 1, windX: Double = 0, windZ: Double = 0) -> PGABallConditions {
        var wet = wetScale[greenCondition] ?? 1.0
        if let difficulty, wet > 1.0 {
            let ability = abilityFactor[difficulty] ?? abilityFactor[1]!
            wet = f32(wet - (1.0 - ability) * f32(wet - 1.0))
        }
        var resolvedMagnet = magnet ?? 0.0
        if let difficulty, magnet == nil { resolvedMagnet = magnetEffect[difficulty] ?? magnetEffect[1]! }
        return PGABallConditions(wet: wet, rough: roughScale[roughLength] ?? 1.0, sand: sand, windX: windX, windZ: windZ, magnet: resolvedMagnet)
    }

    /// Wind in inches per tick at 60 Hz (CGolfBall::SetupBall, float stores).
    var windPerTick: (x: Double, z: Double) {
        let factor = f32(Self.windMPHToInchesPerTick)
        return (f32(f32(windX) * factor), f32(f32(windZ) * factor))
    }
}

/// CPlayer::GetBallCoeffs 0x10141fb6 → CBallFlight +0x3ad/+0x3b1/+0x3b5.
struct PGABallCoefficients: Equatable {
    var spinDecay: Double
    var spin: Double
    var speed: Double
    static let twoPiece = PGABallCoefficients(spinDecay: 1.0, spin: f32(0.97), speed: f32(1.02))
    static let solidCore = PGABallCoefficients(spinDecay: f32(0.95), spin: f32(1.05), speed: 1.0)
    static let woundBalata = PGABallCoefficients(spinDecay: f32(0.9), spin: f32(1.13), speed: f32(0.99))
    static let neutral = PGABallCoefficients(spinDecay: 1, spin: 1, speed: 1)
    /// Ball type byte (player +0x12ed): 0 Two-Piece, 1 Solid Core, 2 Wound Balata.
    static func type(_ index: Int) -> PGABallCoefficients { [twoPiece, solidCore, woundBalata][max(0, min(2, index))] }
}

/// Original club indices (the four f64[45] club tables). Bunker variants of
/// 1-iron…LW are `rawValue + 25` (33…44); 21…32 are chip variants (inferred).
enum PGAOriginalClub: Int, CaseIterable {
    case driver9 = 0, driver12, wood2, wood3, wood4, wood5, wood6, wood7
    case iron1 = 8, iron2, iron3, iron4, iron5, iron6, iron7, iron8, iron9
    case pitchingWedge = 17, sandWedge, lobWedge, putter
    var name: String { PGABallFlight.clubNames[rawValue] }
    /// Table index of the bunker variant (1-iron…LW only).
    var bunkerIndex: Int? { (8...19).contains(rawValue) ? rawValue + 25 : nil }
}

/// ClubAtImpactS-level launch inputs (PGA2005-PHYSICS.md §2). Angles are
/// radians in the internal frame; positive path/face turn +Z toward +X.
struct PGABallLaunch: Equatable {
    /// Original club index 0…44 (see PGAOriginalClub).
    var club: Int
    /// club+0x2c; a 100% swing is PGABallSwing.fullSwingPower; putter maximum 8.
    var power: Double
    /// club head direction, RotateY(path) of +Z.
    var path = 0.0
    /// face normal, RotateY(face) of +Z.
    var face = 0.0
    /// club+0x24 → +0x6c, added to the club's launch angle.
    var loftAdjust = 0.0
    /// club+0x20 → +0x8c, extra pitch (uphill lie), applied after spin.
    var launchAdjust = 0.0
    /// club+0x40 → +0x78.
    var spinMultiplier = 1.0
    /// club+0x38 → +0x74, bunker lies only: 0 bunker tables (club+25), half spin; 1 normal tables.
    var sandBlend = 0.0
    /// +0x90 GetTerrainVImpactReducer; 0 for every player class seen.
    var lieCompensation = 0.0
    /// CPlayer::AimAngle; the heading is RotateY(aim + aimOffset).
    var aim = 0.0
    var aimOffset = 0.0
    /// 0 Full, 1 Chip, 2 Putt, 3 Punch, 4 Flop, 5 Pitch, 6 Pick, 7 Blast (+0x281).
    var shotType = 0
    /// Sub-terrain record index at the ball (+0x99).
    var lieIndex = 0
    /// Start position (contact point), internal inches.
    var position = PGABallVector.zero
}

// MARK: - Events and results

enum PGABallFlightEvent: Equatable {
    /// Terrain Collide (every bounce, including the one-tick micro-bounces of a
    /// run-out). Speeds are in inches per tick before the bounce.
    case impact(position: PGABallVector, normalSpeed: Double, speed: Double, surface: PGABallSurface, recordIndex: Int, bounce: Int)
    /// Texture section flag 0x8: TreeCollide is not modelled; the ball is not bounced.
    case tree(position: PGABallVector)
    /// Spin-back or forward kick when the ball settles on short grass.
    case spinKick(bounce: Int, kick: Double)
    /// The ball's path first crossed the cup circle.
    case cupTouched
    /// Rim (`rim`) or wall contact in CupDynamics; lip-outs emerge from these.
    case cupContact(rim: Bool, position: PGABallVector)
    /// Fell below cup depth.
    case holed(position: PGABallVector)
    /// StopBall: the ball moves once more with this tick's velocity and the next tick ends the shot.
    case stopped(nextLieIndex: Int?)
    /// No terrain at the ball (invalid location); StopBall was called.
    case outOfWorld(position: PGABallVector)
    case stateChanged(PGABallFlight.State)
    /// The shot ended (state 0).
    case finished
}

struct PGABallTrajectoryPoint: Equatable {
    var tick: Int
    var position: PGABallVector
    var state: PGABallFlight.State
}

/// Summary of one simulated shot (the reference's ShotResult).
struct PGABallShotResult {
    var trajectory: [PGABallTrajectoryPoint]
    var finalPosition: PGABallVector
    var finalVelocity: PGABallVector
    var finalSpin: PGABallVector
    var firstBounce: PGABallVector?
    var firstBounceTick: Int?
    /// Horizontal inches from start to first ground contact.
    var carry: Double
    /// Horizontal inches from start to rest.
    var total: Double
    var roll: Double
    /// Maximum height above the start, inches.
    var apex: Double
    var ticks: Int
    var fps: Int
    var holed: Bool
    var touchedCup: Bool
    var outOfWorld: Bool
    var nextLieIndex: Int?
    var launchVelocity: PGABallVector
    var launchSpin: PGABallVector
    var bounces: Int
    var endState: PGABallFlight.State
    var endSurface: String?
    var events: [PGABallFlightEvent]

    var carryYards: Double { carry / 36 }
    var totalYards: Double { total / 36 }
    /// Seconds until first ground contact (whole shot when it never landed).
    var airTime: Double { Double(firstBounceTick ?? ticks) / Double(fps) }
    var time: Double { Double(ticks) / Double(fps) }
}

// MARK: - Flight

/// CBallFlight's state machine for one shot, as a value. Advance it with
/// `step(terrain:)` at exactly `fps` Hz; nothing allocates per tick except
/// events appended to the caller's array.
struct PGABallFlight {
    enum State: Int, Equatable { case done = 0, stopped = 1, flying = 2, slipping = 4, rolling = 8 }
    typealias OriginalClub = PGAOriginalClub

    // Constants (address: width), see docs/research/evidence/pga2005-ballflight.json.
    static let referenceFPS = 60.0                        // 0x102d6598 f32
    static let gravity60Hz = 0.1071700006723404           // 0x102d97c8 f64, in/tick² at 60 Hz
    static let ballRadius = 0.8399999737739563            // 0x102d9758
    static let ballRadiusSquared = 0.7056000232696533     // 0x102d9760
    static let ballMass = 1.6200000047683716              // 0x102d9768
    static let ballInertia = 0.45722880959510803          // 0x102d97f0 = 0.4·m·r²
    static let tangentMass = 0.4628571569919586           // 0x102d97d0 = m/3.5
    static let radiusOverInertia = 1.8371546268463135     // 0x102d97e8
    static let clubSpeedScale = 8.333333015441895         // 0x102d9750
    static let faceTangentLoss = 0.8999999761581421       // 0x102d9770
    static let puttSpeedScale = 1.7999999523162842        // 0x102d9778
    static let minimumLaunchFraction = 0.4000000059604645 // 0x102d9950
    static let lieCompensationTarget = 0.9599999785423279 // 0x102d98f8
    static let sandWoodPower = 0.699999988079071          // 0x102d9870
    static let sandIronPower = 1.5                        // 0x102d98b8
    static let sandSpinBlend = 0.5                        // 0x1038bb00
    static let windMinimumHeight = 18.0                   // 0x102d9858
    static let windFactor = 0.6000000238418579            // 0x102d98c8
    static let aeroK = 0.00047456868924200535             // 0x102d9780
    static let drag = (-0.00034868568764068186, 0.01689407043159008, 0.0007809523958712816, 0.22579047083854675)
    static let lift = (-0.0006282891263253987, 0.040709469467401505, -0.0002010476018767804, 0.08473428338766098)
    static let spinDecay = 0.003000000026077032           // 0x102d97f8
    static let headwindSpinDecay = 0.30000001192092896    // 0x102d98d0
    static let greenDent = 0.800000011920929              // 0x1038bae0
    static let fullRestitutionSpeed = 8.0                 // 0x1038bae8
    static let restitutionFalloff = 1.75                  // 0x1038baf0
    static let frictionScale = 0.30000001192092896        // 0x1038baf8
    static let roughSoftness = 0.6669999957084656         // 0x102d9948
    static let wetDentSlope = 1.399999976158142           // 0x102d9868
    static let wetRestitutionSlope = 0.10999999940395355  // 0x102d9860
    static let spinKickMinimumWet = 0.699999988079071     // 0x102d98d8
    static let spinKickMinimumDistance = 2268.0           // 0x102d98e0 (63 yd)
    static let spinKickForward = 0.10000000149011612      // 0x102d98e8
    static let spinKickScale = 4.0 / frictionScale        // 0x102d9940 / 0x1038baf8
    static let slipFriction = 1.5                         // 0x1038bb08
    static let slipTorque = 2.5                           // 0x102d9958
    static let greenBreak = 0.6000000238418579            // 0x102d98a0
    static let greenRoll = 0.574999988079071              // 0x102d9898
    static let fastGreenSlope = 1.159999966621399         // 0x102d98a8
    static let slowGreenSlope = 0.550000011920929         // 0x102d98b0
    static let snapHeight = 1.5                           // 0x102d9800
    static let cupRadius = 2.0                            // 0x102d9808
    static let cupDepth = 4.0                             // 0x102d9810
    static let cupStep = 0.125                            // 0x102d9818
    static let cupWall = (restitution: 0.03999999910593033, friction: 0.30000001192092896) // 0x102d9820/28
    static let cupRim = (restitution: 0.03999999910593033, friction: 0.6000000238418579)   // 0x102d9830/38
    static let cupFast = 3.75                             // 0x102d9840
    static let cupLipHeight = 0.800000011920929           // 0x102d9848
    static let cupSpinKeep = 0.10000000149011612          // 0x102d98c0
    static let cupNormalFudgeRadius = 2.325000047683716   // 0x102d9990 f32
    static let maxTicks = 0x800                           // BallCalculate 0x101f2a1b
    /// Native hint only: floors more than this above the ball's path are ignored.
    static let ceilingMargin = 12.0

    // Club tables: four f64[45] arrays (0x1038b540/6a8/810/978); sand variants at club+25.
    static let speedTable: [Double] = [
        0.454135047, 0.454135047, 0.438867057, 0.424762947, 0.396425746, 0.356348923,
        0.338624832, 0.319647861, 0.405253573, 0.381621402, 0.353449088, 0.342224346,
        0.334411347, 0.323632809, 0.311667667, 0.300351044, 0.287740812, 0.299902405,
        0.242010838, 0.210276444, 0.0471, 0.221774779735683, 0.20583204845815,
        0.193020925110132, 0.186473017621145, 0.18049449339207, 0.176508810572687,
        0.172523127753304, 0.169391519823789, 0.164836453744493, 0.160281387665198,
        0.140352973568282, 0.128395925110132, 0.3096, 0.29016, 0.27144, 0.26352, 0.2556,
        0.2448, 0.23544, 0.22536, 0.22032, 0.2196, 0.18144, 0.16344]
    static let launchTable: [Double] = [
        0.125260075, 0.148298645, 0.15142215, 0.15806368, 0.175466815, 0.193124225,
        0.21885955, 0.2237952, 0.135684, 0.1511555, 0.16667875, 0.196854, 0.23011625,
        0.270317, 0.3103585, 0.351, 0.41, 0.49, 0.57, 0.63896, 0.0, 0.069813170079772,
        0.104719755119658, 0.139626340159544, 0.17453292519943, 0.209439510239316,
        0.244346095279202, 0.279252680319088, 0.314159265358974, 0.366519142918803,
        0.418879020478632, 0.471238898038461, 0.541052068118233, 0.15965, 0.19982,
        0.23999, 0.28016, 0.32033, 0.36153, 0.4223, 0.5047, 0.5871, 0.67156, 0.74366,
        0.80546]
    static let pitchTable: [Double] = Array(repeating: 0.0, count: 33) + Array(repeating: 0.1, count: 12)
    static let spinTable: [Double] = [
        0.8675, 0.8032, 0.864, 0.917, 0.9657, 0.9822, 1.0372, 1.0869, 1.2662, 1.3351,
        1.3958, 1.3071, 1.2624, 1.221, 1.1977, 1.1783, 1.1648, 1.03, 1.05, 0.97]
        + Array(repeating: 1.0, count: 13)
        + [1.2662, 1.3351, 1.3958, 1.3071, 1.2624, 1.221, 1.1977, 1.1783, 1.1648, 1.1358, 1.1283, 1.1454]
    static let putter = PGAOriginalClub.putter.rawValue
    static let clubNames = ["9 Degree Driver", "12 Degree Driver", "2 Wood", "3 Wood", "4 Wood", "5 Wood",
                            "6 Wood", "7 Wood", "1 Iron", "2 Iron", "3 Iron", "4 Iron", "5 Iron", "6 Iron",
                            "7 Iron", "8 Iron", "9 Iron", "Pitching Wedge", "Sand Wedge", "Lob Wedge", "Putter"]
    /// Caddy::GetMaxClubDistance 0x101132c9, inches (caddie estimate at max power 14).
    static let caddyMaxDistance: [Double] = [
        10800, 10800, 10368, 10044, 9432, 8604, 8028, 7632, 9360, 8784, 8136,
        7776, 7416, 6912, 6408, 5940, 5292, 4752, 3708, 2952, 1260, 4536, 4320,
        4068, 3888, 3744, 3600, 3420, 3276, 3024, 2736, 2160, 1692, 2268, 2160,
        2016, 1944, 1872, 1800, 1692, 1620, 1512, 1368, 1080, 828]

    // Fixed per shot.
    let launch: PGABallLaunch
    let conditions: PGABallConditions
    let ball: PGABallCoefficients
    let fps: Int
    /// fps/60 (+0x325), 60/fps (+0x2d5) and gravity per tick² (+0x2dd).
    let k: Double
    let inv: Double
    let g: Double
    let windX: Double
    let windZ: Double
    /// Cup centre on the green surface, internal inches.
    let pin: PGABallVector?
    let start: PGABallVector
    let tickLimit: Int
    private let sinH: Double
    private let cosH: Double

    // Live state.
    private(set) var state: State = .flying
    private(set) var position: PGABallVector
    /// Position before this tick's move; interpolate toward `position` for rendering.
    private(set) var previousPosition: PGABallVector
    private(set) var velocity = PGABallVector.zero
    private(set) var spin = PGABallVector.zero
    /// Ground height under the ball (+0x2ad).
    private(set) var ground: Double
    private(set) var bounces = 0
    private(set) var tick = 0
    /// Highest y reached (absolute).
    private(set) var apex: Double
    /// Last precise terrain sample (+0x14e / TerrainData).
    private(set) var sample: PGABallTerrainSample?
    private(set) var holed = false
    private(set) var touchedCup = false
    private(set) var outOfWorld = false
    /// Lie record index chosen by StopBall (+0x99).
    private(set) var nextLieIndex: Int?
    private(set) var firstBounce: PGABallVector?
    private(set) var firstBounceTick: Int?
    private(set) var launchVelocity = PGABallVector.zero
    private(set) var launchSpin = PGABallVector.zero
    /// Lie draws in StopBall. Copy it back to the game after the shot.
    var random: PGARandom
    private var impactSpeed = 0.0                                  // +0x29d
    private var normalSpeedSquared = 0.0                           // +0x2a5
    private var effectiveNormal = PGABallVector(0, 1, 0)           // +0x285..+0x295
    private var objectRestitution = 0.0                            // +0x2e5
    private var objectFriction = 0.0                               // +0x2ed
    private var bunkerEntry: (speed: Double, position: PGABallVector)?

    /// The shot has ended (state 0) or reached the 0x800-tick limit.
    var isFinished: Bool { state == .done || tick >= tickLimit }
    /// Render position between ticks; `alpha` is the accumulator fraction 0…1.
    func interpolatedPosition(_ alpha: Double) -> PGABallVector {
        let a = max(0, min(1, alpha))
        return PGABallVector(previousPosition.x + (position.x - previousPosition.x) * a,
                             previousPosition.y + (position.y - previousPosition.y) * a,
                             previousPosition.z + (position.z - previousPosition.z) * a)
    }

    /// BallAtImpact + StartBall + Impact. Nil when there is no terrain at the start.
    init?<T: PGABallFlightTerrain>(launch: PGABallLaunch, terrain: T, conditions: PGABallConditions = PGABallConditions(),
                                   ball: PGABallCoefficients = .neutral, fps: Int = 60, pin: PGABallVector? = nil,
                                   random: PGARandom = PGARandom(state: 0), tickLimit: Int = PGABallFlight.maxTicks) {
        guard (0..<45).contains(launch.club), launch.power.isFinite, launch.power > 0, fps > 0 else { return nil }
        self.launch = launch; self.conditions = conditions; self.ball = ball; self.fps = fps
        self.pin = pin; self.random = random; self.tickLimit = tickLimit
        k = f32(Double(fps)) / f32(Self.referenceFPS)
        inv = f32(Self.referenceFPS) / f32(Double(fps))
        g = inv * inv * Self.gravity60Hz
        let wind = conditions.windPerTick
        windX = wind.x; windZ = wind.z
        start = PGABallVector(f32(launch.position.x), f32(launch.position.y), f32(launch.position.z))
        position = start; previousPosition = start; ground = start.y; apex = start.y
        let heading = -f32(f32(launch.aim) + f32(launch.aimOffset))   // +0x35d
        sinH = sin(heading); cosH = cos(heading)                     // +0x365 / +0x36d
        guard impact(terrain) else { return nil }
        position = start
        ground = start.y
        launchVelocity = velocity
        launchSpin = spin
    }

    // MARK: Stepping

    /// Advances exactly one tick (BallLoop), appending what happened.
    mutating func step<T: PGABallFlightTerrain>(terrain: T, events: inout [PGABallFlightEvent]) {
        guard !isFinished else { return }
        let before = state
        tick += 1
        _ = ballLoop(terrain, &events)
        apex = max(apex, position.y)
        if state != before { events.append(.stateChanged(state)) }
    }

    /// One tick; the returned array is empty (no allocation) on most ticks.
    mutating func step<T: PGABallFlightTerrain>(terrain: T) -> [PGABallFlightEvent] {
        var events: [PGABallFlightEvent] = []
        step(terrain: terrain, events: &events)
        return events
    }

    /// Runs a shot from impact to rest or `maxTicks` (the reference's `simulate_shot`).
    static func simulate<T: PGABallFlightTerrain>(launch: PGABallLaunch, terrain: T, conditions: PGABallConditions = PGABallConditions(),
                                                  ball: PGABallCoefficients = .neutral, fps: Int = 60, pin: PGABallVector? = nil,
                                                  random: PGARandom = PGARandom(state: 0), recordEvery: Int = 1,
                                                  maxTicks: Int = PGABallFlight.maxTicks) -> PGABallShotResult? {
        guard var flight = PGABallFlight(launch: launch, terrain: terrain, conditions: conditions, ball: ball, fps: fps,
                                         pin: pin, random: random, tickLimit: maxTicks) else { return nil }
        let every = max(1, recordEvery)
        var trajectory = [PGABallTrajectoryPoint(tick: 0, position: flight.position, state: flight.state)]
        var events: [PGABallFlightEvent] = []
        var ticks = 0
        while ticks < maxTicks {
            ticks += 1
            flight.step(terrain: terrain, events: &events)
            let alive = flight.state != .done
            if ticks % every == 0 || !alive {
                trajectory.append(PGABallTrajectoryPoint(tick: ticks, position: flight.position, state: flight.state))
            }
            if !alive { break }
        }
        let s = flight.start
        let total = hypot(flight.position.x - s.x, flight.position.z - s.z)
        let carry = flight.firstBounce.map { hypot($0.x - s.x, $0.z - s.z) } ?? total
        return PGABallShotResult(trajectory: trajectory, finalPosition: flight.position, finalVelocity: flight.velocity,
                                 finalSpin: flight.spin, firstBounce: flight.firstBounce, firstBounceTick: flight.firstBounceTick,
                                 carry: carry, total: total, roll: total - carry, apex: flight.apex - s.y, ticks: ticks, fps: fps,
                                 holed: flight.holed, touchedCup: flight.touchedCup, outOfWorld: flight.outOfWorld,
                                 nextLieIndex: flight.nextLieIndex, launchVelocity: flight.launchVelocity, launchSpin: flight.launchSpin,
                                 bounces: flight.bounces, endState: flight.state, endSurface: flight.sample?.surface.name, events: events)
    }

    // MARK: Terrain

    private func query<T: PGABallFlightTerrain>(_ terrain: T, x: Double, z: Double, ceiling: Double) -> PGABallTerrainSample? {
        guard var sample = terrain.sample(x: x, z: z, ceiling: ceiling) else { return nil }
        if let pin {
            // TerrainData::CupNormalFudge 0x101fe0b6 (inside TerrainHeightCPP).
            let px = f32(pin.x), py = f32(pin.y), pz = f32(pin.z)
            if hypot(px - f32(x), pz - f32(z)) < Self.cupNormalFudgeRadius {
                sample.normal = PGABallVector(px - f32(x), (py + 4.0) - f32(sample.height), pz - f32(z))
            }
        }
        return sample
    }

    private static func unitNormal(_ sample: PGABallTerrainSample) -> PGABallVector {
        let n = sample.normal, length = n.length
        return PGABallVector(n.x / length, n.y / length, n.z / length)
    }

    // MARK: Launch

    private mutating func applyHeading(_ vector: inout PGABallVector) {
        let x = vector.x, z = vector.z
        vector.z = cosH * z + sinH * x
        vector.x = cosH * x - sinH * z
    }

    /// TerrainData::ConsiderTerrain 0x101fd345 / 0x101fd3f3 → (record, power factor).
    /// Steps the lie index down while c0 is 0, wrapping like the reference.
    static func considerTerrain(surface: PGABallSurface, lieIndex: Int, rough: Double, sand: Double, magnet: Double) -> (record: PGABallSurfaceRecord, factor: Double) {
        let records = surface.records, count = records.count
        var index = lieIndex
        var record: PGABallSurfaceRecord
        repeat {
            record = records[((index % count) + count) % count]
            index -= 1
        } while !(record.c0 != 0.0 || index < -count)
        let c0 = record.c0
        var factor: Double
        if record.flags & PGABallSurfaceFlag.rough != 0 {
            factor = ((rough - 1.0) * 0.20000000298023224 + 1.0) * (f32(0.05 * magnet) + c0)
        } else {
            factor = c0
        }
        if record.flags & PGABallSurfaceFlag.bunker != 0 {
            factor = ((sand - 1.0) * 0.20000000298023224 + 1.0) * c0
        }
        return (record, factor)
    }

    /// CBallFlight::Impact 0x101f4e6a.
    private mutating func impact<T: PGABallFlightTerrain>(_ terrain: T) -> Bool {
        let L = launch
        let club = L.club
        var speedT = Self.speedTable[club], launchT = Self.launchTable[club]
        var pitchT = Self.pitchTable[club], spinT = Self.spinTable[club]
        guard let startSample = query(terrain, x: start.x, z: start.z, ceiling: start.y + Self.ceilingMargin) else { return false }
        sample = startSample
        let (record, factor) = Self.considerTerrain(surface: startSample.surface, lieIndex: L.lieIndex, rough: conditions.rough,
                                                    sand: conditions.sand, magnet: conditions.magnet)
        var e8 = factor
        let flags = record.flags
        if L.shotType == 5 && flags & PGABallSurfaceFlag.rough != 0 { e8 = (1.0 - e8) * 0.5 + e8 }   // Pitch out of rough
        let f74 = f32(L.sandBlend)
        if flags & PGABallSurfaceFlag.bunker != 0 && (club < 0x15 || club > 0x20) {
            if club < 8 {
                e8 = ((Self.sandWoodPower - 1.0) * f74 + 1.0) * e8
            } else {
                e8 = ((Self.sandIronPower - 1.0) * f74 + 1.0) * e8
                let sand = club + 25
                // The putter (20) and clubs 33…44 would index past the tables
                // (the reference raises IndexError); keep their own values.
                if sand < 45 {
                    speedT = (speedT - Self.speedTable[sand]) * f74 + Self.speedTable[sand]
                    launchT = (launchT - Self.launchTable[sand]) * f74 + Self.launchTable[sand]
                    spinT = (spinT - Self.spinTable[sand]) * f74 + Self.spinTable[sand]
                    pitchT = (pitchT - Self.pitchTable[sand]) * f74 + Self.pitchTable[sand]
                }
            }
        }
        if e8 < Self.lieCompensationTarget {
            e8 = (Self.lieCompensationTarget - e8) * f32(L.lieCompensation) + e8
        }
        let f40 = f32(1.0 / f32(L.power))                           // club+0x28 = 1/club+0x2c
        let scale = (speedT * Self.clubSpeedScale * inv) / f40
        let path = f32(L.path)
        let direction = PGABallVector(f32(sin(path)), 0.0, f32(cos(path)))   // CVector3::RotateY
        let face = f32(L.face)
        let faceNormal = PGABallVector(f32(sin(face)), 0.0, f32(cos(face)))
        let sb = f32(ball.speed)
        var v = PGABallVector(direction.x * scale * sb, direction.y * scale * sb, direction.z * scale * sb)
        if club == Self.putter {
            let vx = v.x, vz = v.z
            v.x = vx * cosH - vz * sinH
            v.z = vz * cosH + vx * sinH
            let n = Self.unitNormal(startSample)                       // NormalizeCoefficient 0x101fd4bc
            let d = v.x * n.x + v.y * n.y + v.z * n.z
            velocity = PGABallVector((v.x - d * n.x) * Self.puttSpeedScale, (v.y - d * n.y) * Self.puttSpeedScale,
                                     (v.z - d * n.z) * Self.puttSpeedScale)
            spin = .zero
            state = .slipping
            return true
        }
        var angle = f32(L.loftAdjust) + launchT
        let floor = f32(launchT * Self.minimumLaunchFraction)
        if floor > angle { angle = floor }
        let sa = sin(angle), ca = cos(angle)
        let n = PGABallVector(faceNormal.x, faceNormal.y * ca + faceNormal.z * sa, faceNormal.z * ca - faceNormal.y * sa)
        let dot = v.x * n.x + v.y * n.y + v.z * n.z
        let vn = PGABallVector(n.x * dot, n.y * dot, n.z * dot)
        let vt = PGABallVector(v.x - vn.x, v.y - vn.y, v.z - vn.z)
        let keep = 1.0 - Self.faceTangentLoss
        let vtk = PGABallVector(vt.x * keep, vt.y * keep, vt.z * keep)
        var launched = PGABallVector((vn.x + vtk.x) * e8, (vn.y + vtk.y) * e8, (vn.z + vtk.z) * e8)
        var s = (record.c1 * spinT) / Self.ballRadius
        if flags & PGABallSurfaceFlag.bunker != 0 {
            if club < 0x14 {
                s = (1.0 - (f32(1.0) - f74) * (1.0 - Self.sandSpinBlend)) * s
            } else if club > 0x14 {
                s = s * Self.sandSpinBlend
            }
        }
        if flags & PGABallSurfaceFlag.rough != 0 { s = f32(conditions.rough) * s }
        let tt = PGABallVector(vt.x - vtk.x, vt.y - vtk.y, vt.z - vtk.z)
        let scaleW = s * f32(ball.spin) * f32(L.spinMultiplier)
        var w = PGABallVector((tt.y * n.z - tt.z * n.y) * scaleW, (tt.z * n.x - tt.x * n.z) * scaleW, (tt.x * n.y - tt.y * n.x) * scaleW)
        let pitch = f32(L.launchAdjust) + pitchT
        let sp = sin(pitch), cp = cos(pitch)
        let vy = launched.y, vz = launched.z
        launched.y = cp * vy + sp * vz
        launched.z = cp * vz - sp * vy
        applyHeading(&launched)
        applyHeading(&w)
        velocity = launched
        spin = w
        state = .flying
        return true
    }

    // MARK: Per-tick motion

    /// CBallFlight::Flying 0x101f5b7d.
    private mutating func flying() {
        var wx = 0.0, wz = 0.0
        if position.y - ground > Self.windMinimumHeight { wx = windX; wz = windZ }
        var v = velocity, w = spin
        let k = self.k, inv = self.inv
        let r0 = v.x - wx * Self.windFactor * inv
        let r1 = v.y - Self.windFactor * 0.0 * inv
        let r2 = v.z - wz * Self.windFactor * inv
        let sp2 = r0 * r0 + r1 * r1 + r2 * r2
        let s = sp2.squareRoot()
        let spinMagnitude = w.length
        let D = Self.drag, Lc = Self.lift
        let dragInner = (D.0 * s * k + D.1) * spinMagnitude * k
        let cd = (dragInner + D.2 * s * k + D.3) * Self.aeroK
        let drag = s > 0.0 ? -(cd * sp2) / s : 0.0
        let liftInner = (Lc.0 * s * k + Lc.1) * spinMagnitude * k
        let cl = (liftInner + Lc.2 * s * k + Lc.3) * Self.aeroK
        let c0 = r2 * w.y - r1 * w.z
        let c1 = r0 * w.z - r2 * w.x
        let c2 = r1 * w.x - r0 * w.y
        let cn = (c0 * c0 + c1 * c1 + c2 * c2).squareRoot()
        // The original divides by |ω × v| unguarded; zero spin would give NaN.
        let lift = cn > 0.0 ? (cl * sp2) / cn : 0.0
        v.x = r0 * drag + c0 * lift + v.x
        v.y = (r1 * drag + c1 * lift) - g + v.y
        v.z = r2 * drag + c2 * lift + v.z
        let dot = wz * v.z + wx * v.x
        var extra = 0.0
        if dot < 0.0 {
            let vm2 = v.x * v.x + v.y * v.y + v.z * v.z
            let a = (dot * v.x) / vm2, b = (dot * v.z) / vm2
            extra = (a * a + b * b).squareRoot() * Self.headwindSpinDecay
        }
        let decay = 1.0 - (1.0 + extra) * Self.spinDecay * inv * f32(ball.spinDecay)
        w.x *= decay; w.y *= decay; w.z *= decay
        velocity = v
        spin = w
    }

    /// Projects v onto the surface keeping |v|; returns the unit travel direction.
    @inline(__always) private static func tangent(_ v: inout PGABallVector, _ n: PGABallVector) -> PGABallVector {
        let d = v.x * n.x + v.y * n.y + v.z * n.z
        var t = PGABallVector(v.x - d * n.x, v.y - d * n.y, v.z - d * n.z)
        let tl = t.length
        t = tl > 0.0 ? PGABallVector(t.x / tl, t.y / tl, t.z / tl) : .zero
        let sp = v.length
        v = PGABallVector(t.x * sp, t.y * sp, t.z * sp)
        return t
    }

    /// CBallFlight::RollingAndSlipping 0x101f6112 (putts start here).
    private mutating func rollingAndSlipping() {
        guard let sample else { return }
        let record = sample.surface.records[0]
        let c4 = record.c4, c5 = record.c5, fl = record.flags
        let n = Self.unitNormal(sample)
        var f = 1.0 - c4
        if fl & PGABallSurfaceFlag.rough != 0 {
            f = (2.0 - f32(conditions.rough)) * f
        } else if fl & PGABallSurfaceFlag.shortGrass != 0 {
            f = (2.0 - f32(conditions.wet)) * f
        }
        let g = self.g
        let gn = -g * n.y
        let d1 = gn * n.x * f, d2 = (-g - gn * n.y) * f, d3 = gn * n.z * f
        var v = velocity, w = spin
        let t = Self.tangent(&v, n)
        var friction = -g * n.y * c5 * Self.slipFriction
        if fl & PGABallSurfaceFlag.rough != 0 {
            friction = (2.0 - f32(conditions.rough)) * friction
        } else if fl & PGABallSurfaceFlag.shortGrass != 0 {
            friction = (2.0 - f32(conditions.wet)) * friction
        }
        let dw = (friction * Self.slipTorque) / Self.ballRadius
        v.x = -d1 + v.x
        v.y = d2 + v.y
        v.z = -d3 + v.z
        w.x = (t.y * n.z - t.z * n.y) * dw + w.x
        w.y = (t.z * n.x - t.x * n.z) * dw + w.y
        w.z = (t.x * n.y - t.y * n.x) * dw + w.z
        velocity = v
        spin = w
        if v.length <= w.length * Self.ballRadius { state = .rolling }
    }

    /// CBallFlight::PureRolling 0x101f6742, including the gyroscopic break.
    private mutating func pureRolling(_ events: inout [PGABallFlightEvent]) {
        guard let sample else { return }
        let record = sample.surface.records[0]
        let c6 = record.c6, c7 = record.c7, fl = record.flags
        let n = Self.unitNormal(sample)
        let g = self.g
        let R = Self.ballRadius, R2 = Self.ballRadiusSquared
        var v = velocity
        let t = Self.tangent(&v, n)
        let rx = -R * n.x, ry = -R * n.y, rz = -R * n.z
        var a = -g * rz * Self.ballMass
        var b = rx * g * Self.ballMass
        let m = (a * a + b * b).squareRoot()
        if m != 0.0 {
            let proj = abs(b * t.z + a * t.x)
            a = a * (proj / m)
            b = b * (proj / m)
            var turn = (a * a + b * b).squareRoot() * c6
            if fl & PGABallSurfaceFlag.green != 0 { turn *= Self.greenBreak }
            let w0 = (rz * v.y - ry * v.z) / R2
            let w1 = (rx * v.z - rz * v.x) / R2
            let w2 = (ry * v.x - rx * v.y) / R2
            let wl = (w0 * w0 + w1 * w1 + w2 * w2).squareRoot()
            if wl > 0.0 {
                turn = turn / (wl * Self.ballInertia)
                var u0 = b * w1, u1 = a * w2 - b * w0, u2 = -(a * w1)
                let flip = u1 < 0.0
                if flip { u0 = -u0; u1 = -u1; u2 = -u2 }
                let a1 = atan2(u0, u1)
                let s1 = sin(a1), c1 = cos(a1)
                v.rotateYX(s1, c1)
                let a2 = -atan2(u2, u1 * c1 + u0 * s1)
                let s2 = sin(a2), c2 = cos(a2)
                v.rotateZY(s2, c2)
                if !flip { turn = -turn }
                v.rotateZX(sin(turn), cos(turn))
                v.rotateZY(sin(-a2), cos(-a2))
                v.rotateYX(sin(-a1), cos(-a1))
            }
        }
        let acc = -((t.y * g * 5.0) / 7.0)
        v.x = t.x * acc + v.x
        v.y = t.y * acc + v.y
        v.z = t.z * acc + v.z
        var resist = ((g * n.y * 5.0) / 7.0) * c7
        if fl & PGABallSurfaceFlag.green != 0 { resist *= Self.greenRoll }
        if fl & PGABallSurfaceFlag.shortGrass != 0 {
            let wet = f32(conditions.wet)
            if wet > 1.0 {
                resist = (-((wet - 1.0) * Self.fastGreenSlope + 1.0) + 2.0) * resist
            } else if wet == 1.0 {
                resist = (-wet + 2.0) * resist
            } else {                                   // discontinuous at 1.0 in the original
                resist = (-wet * Self.slowGreenSlope + 2.0) * resist
            }
        }
        if fl & PGABallSurfaceFlag.rough != 0 { resist = (-f32(conditions.rough) + 2.0) * resist }
        if resist <= v.length {
            v.x = t.x * -resist + v.x
            v.y = t.y * -resist + v.y
            v.z = t.z * -resist + v.z
            velocity = v
        } else {
            velocity = v
            stopBall(&events)
        }
        spin = PGABallVector((-v.z * ry) / R2, 0.0, (ry * v.x) / R2)
    }

    // MARK: Collisions

    /// CBallFlight::Collide 0x101f3310. `normal == nil` is the object path (cup).
    private mutating func collide(normal: PGABallVector?, _ events: inout [PGABallFlightEvent]) {
        guard let sample else { return }
        let surface = sample.surface
        let alt = surface.sectionFlags & PGABallSurfaceFlag.sectionAltBounce != 0
        let recordIndex = alt && surface.records.count > 1 ? 1 : 0
        let record = surface.records[recordIndex]
        let fl = record.flags
        let short = fl & PGABallSurfaceFlag.shortGrass != 0
        let wet = f32(conditions.wet), rough = f32(conditions.rough)
        if surface.sectionFlags & PGABallSurfaceFlag.sectionTree != 0 {
            events.append(.tree(position: position))   // TreeCollide 0x101f2b24: not modelled
            return
        }
        bounces += 1
        let k = self.k
        let R = Self.ballRadius, M = Self.ballMass, TM = Self.tangentMass
        var v = velocity, w = spin, n = effectiveNormal
        let objectContact = normal == nil
        if let normal {
            let nl = normal.length
            n = PGABallVector(normal.x / nl, normal.y / nl, normal.z / nl)
            impactSpeed = v.length
            let vn = v.x * n.x + v.y * n.y + v.z * n.z
            normalSpeedSquared = pow(vn * n.z, 2) + pow(vn * n.y, 2) + pow(vn * n.x, 2)
            events.append(.impact(position: position, normalSpeed: abs(vn), speed: impactSpeed, surface: surface,
                                  recordIndex: recordIndex, bounce: bounces))
            let d = PGABallVector(-(v.x / impactSpeed + n.x), -(v.y / impactSpeed + n.y), -(v.z / impactSpeed + n.z))
            var dent = (abs(vn) / record.c8) * k
            if fl & PGABallSurfaceFlag.green != 0 { dent *= Self.greenDent }
            if fl & PGABallSurfaceFlag.fringe != 0 { dent *= Self.greenDent }
            if fl & PGABallSurfaceFlag.rough != 0 { dent = (2.0 - rough) * dent }
            if short { dent = (2.0 - ((wet - 1.0) * Self.wetDentSlope + 1.0)) * dent }
            var soft = record.c9
            if fl & PGABallSurfaceFlag.rough != 0 { soft *= Self.roughSoftness }
            if fl & PGABallSurfaceFlag.weed != 0 { soft *= 0.5 }
            if (fl & PGABallSurfaceFlag.fairway != 0 || fl & PGABallSurfaceFlag.green != 0) && bounces > 1 {
                soft *= bounces == 2 ? 0.75 : 0.5
            }
            dent += soft
            let dl = d.length
            if dent <= dl {
                n = PGABallVector((dent / dl) * d.x + n.x, (dent / dl) * d.y + n.y, (dent / dl) * d.z + n.z)
            } else {
                n = PGABallVector(-v.x, -v.y, -v.z)
            }
            let tilted = n.length
            n = PGABallVector(n.x / tilted, n.y / tilted, n.z / tilted)
            impactSpeed *= k
        }
        let r = PGABallVector(-R * n.x, -R * n.y, -R * n.z)
        let vc = PGABallVector((r.z * w.y - r.y * w.z) + v.x, (r.x * w.z - r.z * w.x) + v.y, (r.y * w.x - r.x * w.y) + v.z)
        let vcn = vc.x * n.x + vc.y * n.y + vc.z * n.z
        let vct = PGABallVector(vc.x - vcn * n.x, vc.y - vcn * n.y, vc.z - vcn * n.z)
        let lt = vct.length
        let t = lt >= 1e-10 ? PGABallVector(vct.x / lt, vct.y / lt, vct.z / lt) : PGABallVector(0.0, 0.0, 1.0)
        let a1 = atan2(n.x, n.y)
        let s1 = sin(a1), c1 = cos(a1)
        let n1y = c1 * n.y + s1 * n.x
        let t1x = t.x * c1 - t.y * s1, t1y = t.y * c1 + t.x * s1, t1z = t.z
        v.rotateYX(s1, c1)
        w.rotateYX(s1, c1)
        let a2 = -atan2(n.z, n1y)
        let s2 = sin(a2), c2 = cos(a2)
        let t2y = t1y * c2 - t1z * s2
        let t2z = t1z * c2 + t2y * s2                 // the original uses the already-rotated y here
        v.rotateZY(s2, c2)
        w.rotateZY(s2, c2)
        if v.y < 0.0 {
            let a3 = atan2(t1x, t2z)
            let s3 = sin(a3), c3 = cos(a3)
            v.rotateZX(s3, c3)
            w.rotateZX(s3, c3)
            var jx = (R * w.z + v.x) * TM
            var e: Double
            if objectContact {
                e = 1.0 + objectRestitution
            } else {
                var fall: Double
                if impactSpeed <= Self.fullRestitutionSpeed {
                    fall = 1.0
                } else if fl & PGABallSurfaceFlag.green != 0 {
                    fall = 1.0 - ((impactSpeed - Self.fullRestitutionSpeed) / (record.c8 / Self.greenDent)) * Self.restitutionFalloff
                } else {
                    fall = 1.0 - ((impactSpeed - Self.fullRestitutionSpeed) / record.c8) * Self.restitutionFalloff
                }
                var c2v = record.c2
                if fl & PGABallSurfaceFlag.fairway != 0 { c2v = f32(c2v * f32(0.9)) }
                e = c2v * fall + 1.0
                if short { e = ((wet - 1.0) * Self.wetRestitutionSlope + 1.0) * e }
            }
            let jn = e * v.y * M
            var jz = (v.z - R * w.x) * TM
            let jt = (jz * jz + jx * jx).squareRoot()
            var limit: Double
            if objectContact {
                limit = abs(jn) * objectFriction
            } else {
                limit = abs(jn) * record.c3 * Self.frictionScale
                if short { limit = wet * limit }
            }
            if limit < jt {
                var coefficient: Double
                if objectContact {
                    coefficient = objectFriction
                } else {
                    coefficient = record.c3 * Self.frictionScale
                    if short { coefficient = wet * coefficient }
                }
                let fac = abs((coefficient * jn) / jt)
                jx *= fac
                jz *= fac
            }
            v.x = v.x - jx / M
            v.y = v.y - jn / M
            v.z = v.z - jz / M
            w.x = jz * Self.radiusOverInertia + w.x
            w.z = jx * Self.radiusOverInertia + w.z
            if !objectContact {
                var damp = 1.0
                if fl & PGABallSurfaceFlag.rough != 0 && !alt { damp = 0.800000011920929 }
                if alt { damp = 0.8999999761581421 }
                if fl & PGABallSurfaceFlag.weed != 0 { damp = 0.6000000238418579 }
                if fl & PGABallSurfaceFlag.fairway != 0 { damp = 0.9700000286102295 }
                if fl & PGABallSurfaceFlag.green != 0 { damp = 0.9700000286102295 }
                v.x *= damp; v.y *= damp; v.z *= damp
                w.x *= damp; w.y *= damp; w.z *= damp
            }
            if v.y * k < 0.5 && (v.z * v.z + v.x * v.x).squareRoot() * k < 1.0 {
                if !objectContact && bounces < 6 && short && wet > Self.spinKickMinimumWet {
                    let dx = position.x - start.x, dz = position.z - start.z
                    if (dz * dz + dx * dx).squareRoot() > Self.spinKickMinimumDistance {
                        var kick = record.c3 * Self.frictionScale * Self.spinKickScale
                        if (-R * (v.x * w.z)) + ((-w.x * v.z) * -R) >= 0.0 { kick *= Self.spinKickForward }
                        v.x = v.x - (-w.z * -R) * kick
                        v.z = v.z - (-R * w.x) * kick
                        events.append(.spinKick(bounce: bounces, kick: kick))
                    }
                }
                state = .rolling
            }
            v.rotateZX(sin(-a3), cos(-a3))
            w.rotateZX(sin(-a3), cos(-a3))
        }
        v.rotateZY(sin(-a2), cos(-a2))
        w.rotateZY(sin(-a2), cos(-a2))
        v.rotateYX(sin(-a1), cos(-a1))
        w.rotateYX(sin(-a1), cos(-a1))
        velocity = v
        spin = w
        effectiveNormal = n
    }

    /// CBallFlight::StopBall 0x101f769c: state 1 and the next lie record index.
    private mutating func stopBall(_ events: inout [PGABallFlightEvent]) {
        state = .stopped
        guard let surface = sample?.surface else {
            events.append(.stopped(nextLieIndex: nextLieIndex))
            return
        }
        let fl = surface.records[0].flags
        if fl & PGABallSurfaceFlag.bunker != 0 {
            if let entry = bunkerEntry,
               !(abs(position.x - entry.position.x) >= 6.0 || abs(ground - entry.position.y) >= 6.0
                 || abs(position.z - entry.position.z) >= 6.0 || entry.speed < 10.0) {
                if entry.speed < 12.0 || random.unit() <= 0.8999999761581421 {
                    nextLieIndex = random.unit() >= 0.10000000149011612 ? 0 : 2
                } else if (entry.speed >= 14.0 && random.unit() > 0.8999999761581421) || random.unit() < 0.10000000149011612 {
                    nextLieIndex = 3
                } else {
                    nextLieIndex = 2
                }
            } else {
                nextLieIndex = 1
            }
        }
        if fl & PGABallSurfaceFlag.rough != 0 {
            if surface.sectionFlags & PGABallSurfaceFlag.sectionBlend != 0 {
                nextLieIndex = 1
            } else if random.int(2) < 1 {
                nextLieIndex = random.int(surface.records.count)
            } else {
                nextLieIndex = 0
            }
        }
        events.append(.stopped(nextLieIndex: nextLieIndex))
    }

    // MARK: Loop

    /// CBallFlight::BallLoopUpdatePos 0x101f8696.
    private mutating func updatePosition(_ events: inout [PGABallFlightEvent]) -> Bool {
        switch state {
        case .flying: flying()
        case .slipping: rollingAndSlipping()
        case .rolling: pureRolling(&events)
        case .stopped, .done:
            state = .done
            events.append(.finished)
            return false
        }
        previousPosition = position
        position.x += velocity.x
        position.y += velocity.y
        position.z += velocity.z
        return true
    }

    /// CBallFlight::BallLoopTerrainHeight 0x101f7ccb (single query model).
    /// Returns true on the quick-height path (flying ≥ 1 in above ground).
    private mutating func terrainHeight<T: PGABallFlightTerrain>(_ terrain: T, _ events: inout [PGABallFlightEvent]) -> Bool {
        let step = hypot(position.x - previousPosition.x, position.z - previousPosition.z)
        let ceiling = max(previousPosition.y, position.y) + Self.ceilingMargin + 3 * step
        guard let found = query(terrain, x: position.x, z: position.z, ceiling: ceiling) else {
            stopBall(&events)
            outOfWorld = true
            events.append(.outOfWorld(position: position))
            return false
        }
        if state == .flying && f32(found.height) + 1.0 <= f32(position.y) {
            ground = f32(found.height)          // quick-height path: no collision tests
            return true
        }
        sample = found
        ground = found.height
        return false
    }

    /// CBallFlight::BallLoopTestTerrainCollisions 0x101f8d87 (no steep-wall segment test).
    private mutating func testTerrainCollisions(high: Bool, _ events: inout [PGABallFlightEvent]) {
        if high { return }
        if state == .flying {
            if ground < position.y { return }
            position.y = ground
            if firstBounce == nil {
                firstBounce = position
                firstBounceTick = tick
            }
            guard let current = sample else { return }
            collide(normal: current.normal, &events)
            if current.surface.records[0].flags & PGABallSurfaceFlag.bunker != 0 && bunkerEntry == nil {
                bunkerEntry = (normalSpeedSquared.squareRoot(), PGABallVector(position.x, ground, position.z))
            }
        } else if position.y - ground < Self.snapHeight {
            position.y = ground
        } else {
            state = .flying
        }
    }

    /// CBallFlight::CupDynamics 0x101f9966 (LineIntersectsSquare is a segment–box stand-in).
    private mutating func cupDynamics(_ events: inout [PGABallFlightEvent]) -> Bool {
        guard let pin else { return false }
        let R = Self.ballRadius
        let cx = f32(pin.x), cy = f32(pin.y), cz = f32(pin.z)
        let state0 = state
        let x0 = previousPosition.x, y0 = previousPosition.y, z0 = previousPosition.z
        let x1 = position.x, z1 = position.z
        let half = Self.cupRadius + 0.5
        if !Self.segmentHitsSquare(f32(x0), f32(z0), f32(x1), f32(z1), cx - half, cz - half, cx + half, cz + half) { return false }
        if state0 == .flying && !(f32(position.y) < cy) { return false }
        let dx = x1 - x0, dz = z1 - z0
        let a = atan2(dx, dz)
        let s = sin(a), c = cos(a)
        let length = dz * c + dx * s
        let dxc = f32(cx - f32(x0))                 // float subtraction in the original
        let lat = dxc * c - (cz - z0) * s
        let along = (cz - z0) * c + dxc * s
        if !(abs(lat) < Self.cupRadius) { return false }
        let h = (Self.cupRadius * Self.cupRadius - lat * lat).squareRoot()
        let enter = along - h, exit = along + h
        if !(enter < length && exit > 0.0) { return false }
        if !touchedCup { events.append(.cupTouched) }
        touchedCup = true
        let rollingIn = state0 == .slipping || state0 == .rolling
        if state == .slipping || state == .rolling {
            guard length > 0.0 else { return false }      // the reference would divide by zero
            let hi = exit < length ? exit : length
            let lo = enter > 0.0 ? enter : 0.0
            let drop = ((hi - lo) / length) * g
            velocity.y -= drop
            position.y = -(drop - position.y)
            state = .flying
            if length + R < exit { return true }
        }
        let y1 = position.y
        let span = (pow(y1 - y0, 2) + length * length).squareRoot()
        guard span > 0.0, span.isFinite else { return false }   // the reference would divide by zero
        var t = 0.0
        var horiz = 0.0
        var guardSteps = 0
        while true {
            var yy = 0.0, ww = 0.0
            while true {
                t += Self.cupStep
                yy = ((y1 - y0) / span) * t + y0
                ww = (length / span) * t
                if f32(yy) < cy { break }
                if along <= ww { return true }
                guardSteps += 1
                if guardSteps > 100_000 { return true }
            }
            if f32(yy) <= cy - f32(Self.cupDepth) {
                holed = true
                events.append(.holed(position: PGABallVector(position.x, yy, position.z)))
                stopBall(&events)
                return true
            }
            let dist = (lat * lat + pow(along - ww, 2)).squareRoot()
            if Self.cupRadius <= dist && (!rollingIn || enter < ww) { return false }
            let dyc = (yy + R) - cy
            if dyc >= 0.0 {
                if length * k < Self.cupFast || Self.cupLipHeight <= dyc {
                    effectiveNormal.y = dyc
                    horiz = max(0.0, Self.ballRadiusSquared - dyc * dyc).squareRoot()
                } else {
                    horiz = Self.cupLipHeight      // normal y keeps its previous value (original quirk)
                }
            } else {
                effectiveNormal.y = 0.0
                horiz = R
            }
            if Self.cupRadius - dist < horiz && exit - length <= length - enter {
                var n = effectiveNormal
                n.x = (lat / dist) * horiz
                n.z = ((along - ww) / dist) * horiz
                let nl = n.length
                n = PGABallVector(n.x / nl, n.y / nl, n.z / nl)
                let sb = sin(-a), cb = cos(-a)
                let nx = n.x, nz = n.z
                n.z = cb * nz + sb * nx
                n.x = cb * nx - sb * nz
                effectiveNormal = n
                let back = (Self.cupRadius - horiz) - Self.cupStep
                let u = -((lat / dist) * back) + lat
                let q = -(((ww - along) / dist) * back + along) + ww
                position.x = (u * cb - q * sb) + x0
                position.z = q * cb + u * sb + z0
                position.y = yy
                let rim = n.y != 0.0
                let coefficients = rim ? Self.cupRim : Self.cupWall
                objectRestitution = coefficients.restitution
                objectFriction = coefficients.friction
                events.append(.cupContact(rim: rim, position: position))
                collide(normal: nil, &events)
                spin = PGABallVector(spin.x * Self.cupSpinKeep, spin.y * Self.cupSpinKeep, spin.z * Self.cupSpinKeep)
                return true
            }
            if !(ww < length) { return true }
            guardSteps += 1
            if guardSteps > 100_000 { return true }
        }
    }

    /// Stand-in for LineIntersectsSquare (not decompiled): 2-D segment vs. box.
    static func segmentHitsSquare(_ x0: Double, _ z0: Double, _ x1: Double, _ z1: Double,
                                  _ minX: Double, _ minZ: Double, _ maxX: Double, _ maxZ: Double) -> Bool {
        var t0 = 0.0, t1 = 1.0
        func clip(_ p: Double, _ d: Double, _ lo: Double, _ hi: Double) -> Bool {
            if d == 0.0 { return !(p < lo || p > hi) }
            var ta = (lo - p) / d, tb = (hi - p) / d
            if ta > tb { swap(&ta, &tb) }
            t0 = max(t0, ta)
            t1 = min(t1, tb)
            return !(t0 > t1)
        }
        return clip(x0, x1 - x0, minX, maxX) && clip(z0, z1 - z0, minZ, maxZ)
    }

    /// CBallFlight::BallLoop 0x101f795f.
    private mutating func ballLoop<T: PGABallFlightTerrain>(_ terrain: T, _ events: inout [PGABallFlightEvent]) -> Bool {
        if state == .done { return false }
        if !updatePosition(&events) { return false }
        let high = terrainHeight(terrain, &events)
        if state == .stopped {
            ground = position.y
        } else {
            // BallLoopTestTreeCollisions / BallLoopTestMiscCollisions: not modelled.
            if pin != nil && cupDynamics(&events) {
                ground = -1e10
            } else {
                testTerrainCollisions(high: high, &events)
            }
        }
        return state != .done
    }
}

extension PGARandom {
    /// A generator at an explicit SplitMix64 state (fixtures, replays).
    init(state: UInt64) {
        self.init(seed: "")
        self.state = state
    }
}

// MARK: - Game frame adapter

/// Converts the game's right-handed meters (PGAVector) to the flight's
/// left-handed inches and back: inches = meters / 0.0254 + origin, with Z
/// mirrored, exactly like PGACourseTransform. For original courses use the
/// course transform's origin so internal coordinates are the source's raw
/// inches (the original's float rounding then applies at the same magnitudes);
/// generated terrain uses origin zero. Directions and normals mirror Z only.
struct PGABallFlightFrame: Equatable {
    static let metersPerInch = PGACourseTransform.metersPerInch
    var origin: PGAVector

    init(origin: PGAVector = .zero) { self.origin = origin }
    init(transform: PGACourseTransform) { origin = transform.origin }

    func point(meters value: PGAVector) -> PGABallVector {
        let k = Self.metersPerInch
        return PGABallVector(value.x / k + origin.x, value.y / k + origin.y, -value.z / k + origin.z)
    }
    func meters(_ value: PGABallVector) -> PGAVector {
        let k = Self.metersPerInch
        return PGAVector(x: (value.x - origin.x) * k, y: (value.y - origin.y) * k, z: -(value.z - origin.z) * k)
    }
    func direction(meters value: PGAVector) -> PGABallVector { PGABallVector(value.x, value.y, -value.z) }
    func metersDirection(_ value: PGABallVector) -> PGAVector { PGAVector(x: value.x, y: value.y, z: -value.z) }
    /// Inches per tick → meters per second.
    func metersPerSecond(_ velocity: PGABallVector, fps: Int = 60) -> PGAVector {
        let scale = Self.metersPerInch * Double(fps)
        return PGAVector(x: velocity.x * scale, y: velocity.y * scale, z: -velocity.z * scale)
    }

    /// Our heading h points along (sin h, 0, cos h) in meters, which is
    /// (sin h, 0, −cos h) internally; the original's aim a points along
    /// (sin a, 0, cos a). So a = π − h (wrapped to [−π, π]).
    static func aim(heading: Double) -> Double { (Double.pi - heading).remainder(dividingBy: 2 * Double.pi) }
    static func heading(aim: Double) -> Double { (Double.pi - aim).remainder(dividingBy: 2 * Double.pi) }
}

/// Wraps the game's PGATerrainSampling (meters, right-handed) as flight
/// terrain. Each original material becomes one cached PGABallSurface with all
/// its records, so the launch lie index selects the record as ConsiderTerrain
/// does; generated terrain uses PGABallSurface.fallback. Not thread-safe (the
/// cache fills on first sight of a material); use one adapter per simulation.
final class PGABallTerrainAdapter: PGABallFlightTerrain {
    let terrain: PGATerrainSampling
    let frame: PGABallFlightFrame
    private var surfaces: [ObjectIdentifier: PGABallSurface] = [:]

    init(terrain: PGATerrainSampling, frame: PGABallFlightFrame = PGABallFlightFrame()) {
        self.terrain = terrain; self.frame = frame
    }

    /// The flight surface for a game floor sample.
    func surface(for sample: PGAGroundSample) -> PGABallSurface {
        guard let properties = sample.properties else { return PGABallSurface.fallback(for: sample.surface) }
        let key = ObjectIdentifier(properties)
        if let cached = surfaces[key] { return cached }
        let surface = PGABallSurface(properties: properties)
        surfaces[key] = surface
        return surface
    }

    /// Floor query in meters that tolerates hairline seams between source
    /// patches (the same probe pattern as PGASimulation.ground).
    func ground(x: Double, z: Double, ceiling: Double) -> PGAGroundSample? {
        if let sample = terrain.ground(x: x, z: z, ceiling: ceiling) { return sample }
        if let sample = terrain.ground(x: x + 0.03, z: z, ceiling: ceiling) { return sample }
        if let sample = terrain.ground(x: x - 0.03, z: z, ceiling: ceiling) { return sample }
        if let sample = terrain.ground(x: x, z: z + 0.03, ceiling: ceiling) { return sample }
        return terrain.ground(x: x, z: z - 0.03, ceiling: ceiling)
    }

    func sample(x: Double, z: Double, ceiling: Double) -> PGABallTerrainSample? {
        let k = PGABallFlightFrame.metersPerInch
        let mx = (x - frame.origin.x) * k, mz = -(z - frame.origin.z) * k
        let mc = ceiling.isFinite ? (ceiling - frame.origin.y) * k : Double.infinity
        guard let floor = ground(x: mx, z: mz, ceiling: mc) else { return nil }
        let n = floor.normal
        return PGABallTerrainSample(height: floor.height / k + frame.origin.y, normal: PGABallVector(n.x, n.y, -n.z),
                                    surface: surface(for: floor))
    }
}

// MARK: - Swing mapping (assumption-labelled)

/// Maps the game's three-click inputs onto ClubAtImpactS launch values.
///
/// Confidence is medium-low (PGA2005-PHYSICS.md §2.5 documents the swing
/// control layer but it was not reimplemented). Assumptions, each labelled:
/// - A1 power = meter × fullSwingPower (ClickSwingControlC: GetPowerPercent ·
///   GetAveragePlayerPower · shot-hit factor 1 for Full); 100% at Advanced or
///   Expert is 15.5556. The putter's maximum club power is 8, and the click
///   control multiplies putts by 0.8, so a 100% putt is 6.4 (≈103 ft on a
///   Normal green, matching the caddie's 105 ft putter maximum).
/// - A2 accuracy drives the club path only, with a square face, through
///   ComputeClubfaceDirection: path = sign(x)·|x|^0.6·MaxSliceAngle, where x
///   is the click deviation. MaxSliceAngle is 1.5°, 3.5°, 5°, 6° from Novice
///   to Expert (assumed in that order). Mishit face rotation, risk and the
///   off-tee driver penalty are not applied.
/// - A3 sign: our accuracy < 0 is a hook/pull (left). For full swings that is
///   an in-to-out path (+X internally, i.e. right of the aim) with a square
///   face, which curves left (D-plane, verified by tests). For the putter the
///   path is the start direction, so accuracy < 0 starts left (−X).
/// - A4 AddBTBAndLie divides the path by the lie accuracy factor (1 − penalty).
/// - A5 clubs below 11: loft += −(path − face)·0.5 (0x101623d4).
/// - A6 the lie's launch power (c0) is NOT an input here: Impact applies it via
///   ConsiderTerrain from `lieIndex`. Do not multiply power by a lie factor.
enum PGABallSwing {
    /// ComputeClubfaceDirection MaxSliceAngle by difficulty, degrees (A2).
    static let maxSliceDegrees = [1.5, 3.5, 5.0, 6.0]
    /// ClickSwingControlC putter power factor (A1).
    static let clickPutterFactor = 0.8
    /// GetMaxClubPower: 8 putter, 14 otherwise.
    static func maxClubPower(club: Int) -> Double { club == PGABallFlight.putter ? 8.0 : 14.0 }

    /// Stopgap mapping of the current 8-club PGAClub bag onto original indices.
    static func originalIndex(for club: PGAClub) -> Int {
        switch club {
        case .driver: return PGAOriginalClub.driver9.rawValue
        case .wood3: return PGAOriginalClub.wood3.rawValue
        case .iron5: return PGAOriginalClub.iron5.rawValue
        case .iron7: return PGAOriginalClub.iron7.rawValue
        case .iron9: return PGAOriginalClub.iron9.rawValue
        case .wedge: return PGAOriginalClub.pitchingWedge.rawValue
        case .sandWedge: return PGAOriginalClub.sandWedge.rawValue
        case .putter: return PGAOriginalClub.putter.rawValue
        }
    }

    /// Power of a 100% swing (Caddy::GetAveragePlayerPower 0x10112529 and
    /// CPlayer::GetAverageDistance 0x1013bf67): putter/chips use the club
    /// maximum; human players otherwise scale 14 by average distance / 9720.
    static func fullSwingPower(club: Int, difficulty: Int = 2, human: Bool = true, averageDistance: Double? = nil) -> Double {
        let maxPower = maxClubPower(club: club)
        if club == PGABallFlight.putter || (20 < club && club < 33) || !human { return maxPower }
        let distance = averageDistance ?? [0: 9612.0, 1: 10116.0][difficulty] ?? 10800.0
        return f32(f32(distance) / 9720.0 * maxPower)
    }

    /// Lie accuracy factor (0x10161eb0): 1 − penalty by record index (A4).
    static func lieAccuracyFactor(flags: UInt32, index: Int) -> Double {
        let penalties: [Double]
        if flags & PGABallSurfaceFlag.weed != 0 { penalties = [0.8, 0.7, 0.85] }
        else if flags & PGABallSurfaceFlag.bunker != 0 { penalties = [0.45, 0.4, 0.5, 0.55] }
        else if flags & PGABallSurfaceFlag.rough != 0 { penalties = [0.3, 0.25, 0.35] }
        else { return 1 }
        return 1 - penalties[max(0, min(penalties.count - 1, index))]
    }

    /// The lie index to launch from. Blend strips store texture indices as
    /// denormal c0 in record 0, and the faithful ConsiderTerrain would then
    /// launch at near-zero power (PGA2005-PHYSICS.md §12). Our decoded blend
    /// materials may not be what the original's physics sees, so by default a
    /// record with 0 < c0 < 0.01 is replaced by the first usable one (the same
    /// native guard as PGASurfaceProperties.lieRecord).
    static func usableLieIndex(_ index: Int, surface: PGABallSurface, faithfulBlendQuirk: Bool = false) -> Int {
        let records = surface.records
        let clamped = max(0, min(records.count - 1, index))
        guard !faithfulBlendQuirk, records[clamped].c0 > 0, records[clamped].c0 < 0.01 else { return clamped }
        return records.firstIndex { $0.c0 >= 0.01 } ?? clamped
    }

    static func launch(club: PGAOriginalClub, power: Double, accuracy: Double, heading: Double, position: PGABallVector,
                       lieIndex: Int = 0, lieAccuracy: Double = 1, difficulty: Int = 2) -> PGABallLaunch {
        launch(club: club.rawValue, power: power, accuracy: accuracy, heading: heading, position: position,
               lieIndex: lieIndex, lieAccuracy: lieAccuracy, difficulty: difficulty)
    }

    /// Builds a launch from game inputs.
    /// - club: original club index (PGAOriginalClub / originalIndex(for:)).
    /// - power: meter 0…1.047 after the original overswing (bounded to 0.01…1.05).
    /// - accuracy: −1…1, negative = hook/left (A3).
    /// - heading: our right-handed heading (direction (sin h, 0, cos h) in meters).
    /// - position: contact point in internal inches (frame.point(meters:) of the ball's bottom).
    /// - lieIndex: sub-terrain record index at the ball (use usableLieIndex).
    /// - lieAccuracy: lieAccuracyFactor for the lie (A4), 1 on clean lies.
    static func launch(club: Int, power: Double, accuracy: Double, heading: Double, position: PGABallVector,
                       lieIndex: Int = 0, lieAccuracy: Double = 1, difficulty: Int = 2) -> PGABallLaunch {
        let level = max(0, min(3, difficulty))
        var swingPower = max(0.01, min(1.05, power.isFinite ? power : 0)) * fullSwingPower(club: club, difficulty: level)
        if club == PGABallFlight.putter { swingPower *= clickPutterFactor }
        let miss = max(-1, min(1, accuracy.isFinite ? accuracy : 0))
        let sign: Double = miss < 0 ? -1 : (miss > 0 ? 1 : 0)
        let shaped = sign * pow(abs(miss), 0.6) * maxSliceDegrees[level] * Double.pi / 180 / max(0.05, lieAccuracy)
        let path = club == PGABallFlight.putter ? shaped : -shaped
        let face = 0.0
        let loftAdjust = club < 11 && club != PGABallFlight.putter ? -(path - face) * 0.5 : 0
        return PGABallLaunch(club: club, power: swingPower, path: path, face: face, loftAdjust: loftAdjust,
                             aim: PGABallFlightFrame.aim(heading: heading), shotType: club == PGABallFlight.putter ? 2 : 0,
                             lieIndex: lieIndex, position: position)
    }
}

// PGASimulation uses this model for original-course shots. Its eight-club UI
// maps to original club indices through PGABallSwing; generated practice keeps
// the native development model. Original-course shots use the round's selected
// difficulty; green/rough, Solid Core ball and calm wind remain fixed. Swing input
// mapping and post-shot rules remain approximations (PGA2005-PHYSICS.md).
