import Foundation

/// One floor query in simulation meters. `surface` selects the provisional
/// native physics; `lie` and `materialID` keep what the source data called it.
struct PGAGroundSample: Equatable {
    var height: Double
    var normal: PGAVector
    var surface: PGASurface
    var lie: String
    var materialID: UInt32?
    /// Original material data; nil for generated terrain.
    var properties: PGASurfaceProperties? = nil

    /// Height change per meter along x and z. Near-vertical source triangles
    /// are clamped so a cliff edge cannot produce an unbounded rolling force.
    var gradient: PGAVector {
        let y = max(normal.y, 0.2)
        return PGAVector(x: -normal.x / y, y: 0, z: -normal.z / y)
    }
}

/// Terrain seen by the simulation, independent of SceneKit and input devices.
/// Implementations are immutable after construction and may be shared by the
/// simulation, renderer and minimap.
protocol PGATerrainSampling: AnyObject {
    /// Highest floor at (x, z) whose height does not exceed `ceiling`; nil
    /// means the point lies outside the playable world for this hole.
    func ground(x: Double, z: Double, ceiling: Double) -> PGAGroundSample?
}

/// The generated practice holes, sampled from their analytic height field.
final class PGAProceduralTerrain: PGATerrainSampling {
    let hole: PGAHole
    init(hole: PGAHole) { self.hole = hole }

    func ground(x: Double, z: Double, ceiling: Double) -> PGAGroundSample? {
        guard x.isFinite, z.isFinite else { return nil }
        let surface = hole.surface(x: x, z: z)
        let gradient = hole.gradient(x: x, z: z)
        let normal = PGAVector(x: -gradient.x, y: 1, z: -gradient.z)
        return PGAGroundSample(height: hole.height(x: x, z: z), normal: normal * (1 / normal.length),
                               surface: surface, lie: surface.rawValue, materialID: nil)
    }
}

/// Original TCL surface data for one material, shared by every floor sample of
/// that material. Flag meanings, record selection and the c0/c7 formulas come
/// from static analysis of Engine/CourseData (docs/research/PGA2005-REA.md);
/// thresholds have not been validated against a running original.
final class PGASurfaceProperties: Equatable {
    struct Record: Equatable {
        var label: String
        var flags: UInt32
        var coefficients: [Double]
        /// c0: lie power, the launch-velocity multiplier (CBallFlight::Impact).
        var power: Double { coefficients.first ?? 1 }
        /// c7: rolling resistance (CBallFlight::PureRolling).
        var rollingResistance: Double { coefficients.count > 7 ? coefficients[7] : 0.3 }
    }

    let materialID: UInt32
    let materialName: String
    /// Texture-section flags (+0xa). 0x80 marks a blend strip whose record 0
    /// stores texture indices instead of coefficients.
    let sectionFlags: UInt32
    let records: [Record]
    let surface: PGASurface
    /// Display text when no single record label applies.
    let category: String

    /// Flags of record 0, which the original uses for bounce, roll and stop.
    var flags: UInt32 { records.first?.flags ?? 0 }
    var isBlend: Bool { sectionFlags & 0x80 != 0 }
    /// 0x400: free relief (roads and cart paths).
    var freeDrop: Bool { flags & 0x400 != 0 }

    init(materialID: UInt32, materialName: String, sectionFlags: UInt32, records: [Record]) {
        self.materialID = materialID; self.materialName = materialName
        self.sectionFlags = sectionFlags; self.records = records
        surface = Self.classify(flags: records.first?.flags ?? 0)
        let labels = Set(records.map(\.label))
        category = labels.count == 1 && Self.meaningful(labels.first!, material: materialName) ? labels.first! : surface.rawValue
    }

    static func == (a: PGASurfaceProperties, b: PGASurfaceProperties) -> Bool { a === b }

    /// Position predicates (Engine IsThis 0x10186fa2): 0x1 fairway, 0x2 rough,
    /// 0x4 green, 0x8 bunker, 0x10 fringe, 0x20 unplayable, 0x40 water, 0x80
    /// out of bounds, 0x100 hazard, 0x200 drop allowed, 0x400 free drop, 0x800
    /// ball disappears, 0x1000 tee box, 0x2000 stance allowed, 0x80000000 weed.
    static func classify(flags: UInt32) -> PGASurface {
        if flags & 0x40 != 0 { return .water }
        if flags & 0x80 != 0 { return .out }
        if flags & 0x4 != 0 { return .green }
        if flags & 0x10 != 0 { return .fringe }
        if flags & 0x1000 != 0 { return .tee }
        if flags & 0x8 != 0 { return .sand }
        if flags & 0x1 != 0 { return .fairway }
        if flags & 0x2 != 0 || flags & 0x8000_0000 != 0 { return .rough }
        if flags & 0x20 != 0 { return .unplayable }
        if flags & 0x200 != 0 { return .rough }
        return .unplayable
    }

    /// Blend strips carry truncated texture names ("pbl_teebo") as labels.
    static func meaningful(_ label: String, material: String) -> Bool {
        !label.isEmpty && !material.lowercased().hasPrefix(label.lowercased())
    }

    /// Record used for launch power and lie text. ConsiderTerrain steps down
    /// while c0 is zero; blend record 0 holds texture indices, so any record
    /// with c0 below 0.01 falls back to the first usable record (a native guard
    /// for a case whose original outcome is unvalidated).
    func lieRecord(_ index: Int) -> Record? {
        guard !records.isEmpty else { return nil }
        var i = max(0, min(records.count - 1, index))
        while i > 0 && records[i].power == 0 { i -= 1 }
        if records[i].power < 0.01, let usable = records.first(where: { $0.power >= 0.01 }) { return usable }
        return records[i]
    }

    func label(_ index: Int) -> String {
        guard let record = lieRecord(index), Self.meaningful(record.label, material: materialName) else { return category }
        return record.label
    }

    /// PureRolling deceleration g·n_y·(5/7)·c7 from record 0; greens ×0.575.
    /// Rough length and wet scale stay at their defaults (RoughLength 2 →
    /// 1.0, GreenCond 3 → 1.0).
    func rollingDeceleration(normalY: Double) -> Double {
        9.81 * max(0, normalY) * (5.0 / 7.0) * (records.first?.rollingResistance ?? 0.3) * (flags & 0x4 != 0 ? 0.575 : 1)
    }
}
