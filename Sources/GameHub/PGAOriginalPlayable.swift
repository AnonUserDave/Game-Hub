import Foundation

/// Course-condition patch layers. Each source patch carries
/// `tagPatch::PatchLayerInfoS` (u16 at descriptor +0x61): the low five bits name
/// the hole whose world owns it and the higher bits are condition variants.
/// `CourseDataManager::AddVisiblePatch` (CourseData 0x10009160) accepts a patch
/// for the same hole when it is a base patch or shares a condition bit with the
/// selector. `CHole::Load` (Engine 0x10183ca1) uses 0x420 for every standard
/// course: fairway level 0 (widest bands) and green level 0 (largest greens).
/// Bit 0x8000 is never selected in standard play. Static analysis; see
/// docs/research/PGA2005-REA.md.
struct PGACourseConditions: Codable, Equatable {
    /// Condition bits of the selector; the hole number is ORed in per hole.
    var selector: UInt32

    static let standard = PGACourseConditions(selector: 0x420)
    /// Composite-course levels as built by SetFairwayWidthLevel/SetGreenSizeLevel.
    static func composite(fairwayLevel: Int, greenLevel: Int) -> PGACourseConditions {
        PGACourseConditions(selector: (0x20 << UInt32(max(0, min(4, fairwayLevel)))) | (0x400 << UInt32(max(0, min(4, greenLevel)))))
    }
    var summary: String { selector == 0x420 ? "standard layers 0x420" : String(format: "layers 0x%X", selector) }

    func includes(layer: UInt32, hole: Int) -> Bool {
        let selected = (selector & ~0x1f) | UInt32(hole & 0x1f)
        guard (layer ^ selected) & 0x1f == 0 else { return false }
        let conditions = layer & ~0x1f
        return conditions == 0 || conditions & selected & ~0x1f != 0
    }
}

/// The single source-to-simulation transform. Source positions are inches in
/// a left-handed world (verified by the ocean lying right of Pebble Beach holes
/// 4-10 and left of 18 along their aim-point paths), so Z is mirrored to give
/// SceneKit's right-handed meters.
struct PGACourseTransform: Codable, Equatable {
    static let metersPerInch = 0.0254
    var origin: PGAVector

    func meters(raw: PGAVector) -> PGAVector {
        let k = Self.metersPerInch
        return PGAVector(x: (raw.x - origin.x) * k, y: (raw.y - origin.y) * k, z: -(raw.z - origin.z) * k)
    }
    func raw(meters value: PGAVector) -> PGAVector {
        let k = Self.metersPerInch
        return PGAVector(x: value.x / k + origin.x, y: value.y / k + origin.y, z: -value.z / k + origin.z)
    }
    /// Directions mirror the same axis and do not scale.
    func direction(raw: PGAVector) -> PGAVector { PGAVector(x: raw.x, y: raw.y, z: -raw.z) }
}

/// One original TCL surface record, kept verbatim for display and research.
struct PGAOriginalSurfaceRecord: Decodable, Equatable {
    var name: String
    var flags: UInt32
    var coefficients: [Double]
}

/// Mapped original course data shared by every hole: GHPC v3 terrain, patch
/// layers, materials and TCR hole records. Nothing is decoded per hole twice.
final class PGAOriginalCourseData: @unchecked Sendable {
    struct Patch: Equatable {
        var layer: UInt32
        var firstVertex: Int
        var vertexCount: Int
        var firstTriangle: Int
        var triangleCount: Int
        var hole: Int { Int(layer & 0x1f) }
    }
    struct Material {
        var id: UInt32
        var name: String
        var texture: URL?
        var records: [PGAOriginalSurfaceRecord]
        var properties: PGASurfaceProperties
    }
    struct SourceHole {
        var number: Int
        var par: Int
        var handicap: Int
        var tees: [PGAVector]
        var pins: [PGAVector]
        var aimPoints: [PGAVector]
        var yardagesByTee: [Int]?
    }
    enum LoadError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
    }

    let code: String
    let title: String
    let directory: URL
    let terrain: Data
    let vertexOffset: Int
    let vertexCount: Int
    let triangleOffset: Int
    let triangleCount: Int
    let boundsMin: PGAVector
    let boundsMax: PGAVector
    let patches: [Patch]
    let materials: [UInt32: Material]
    let holes: [SourceHole]
    let sourceTCRSHA256: String

    init(directory: URL, code: String) throws {
        self.directory = directory.standardizedFileURL; self.code = code
        let terrainURL = directory.appendingPathComponent("terrain.ghpc")
        let attributes = try FileManager.default.attributesOfItem(atPath: terrainURL.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 300_000_000 else {
            throw LoadError.invalid("Terrain file exceeds the 300 MB limit.")
        }
        // Mapped, read-only and clean: macOS can page it out under pressure.
        let data = try Data(contentsOf: terrainURL, options: .alwaysMapped)
        terrain = data
        let header = try data.withUnsafeBytes { bytes -> (Int, Int, Int, [Double], [Patch]) in
            guard data.count >= 48, bytes.prefix(4).elementsEqual([0x47, 0x48, 0x50, 0x43]) else {
                throw LoadError.invalid("Expected GHPC terrain. Run Tools/prepare_pga2005.py.")
            }
            func u32(_ offset: Int) -> UInt32 { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            guard u32(4) == 3 else {
                throw LoadError.invalid("Playable courses need GHPC v3 per-hole patch layers. Rerun Tools/prepare_pga2005.py.")
            }
            let vertices = Int(u32(8)), triangles = Int(u32(12)), patchCount = Int(u32(44))
            guard vertices > 0, vertices <= 2_000_000, triangles > 0, triangles <= 4_000_000, patchCount > 0, patchCount <= 100_000,
                  data.count == 48 + vertices * 24 + triangles * 16 + patchCount * 20 else {
                throw LoadError.invalid("Terrain byte count does not match its declared records.")
            }
            let bounds = (0..<6).map { Double(Float(bitPattern: u32(20 + $0 * 4))) }
            guard bounds.allSatisfy(\.isFinite), bounds[3] > bounds[0], bounds[5] > bounds[2] else {
                throw LoadError.invalid("Terrain bounds are invalid.")
            }
            let table = 48 + vertices * 24 + triangles * 16
            var patches: [Patch] = []
            patches.reserveCapacity(patchCount)
            var nextVertex = 0, nextTriangle = 0
            for index in 0..<patchCount {
                let offset = table + index * 20
                let patch = Patch(layer: u32(offset), firstVertex: Int(u32(offset + 4)), vertexCount: Int(u32(offset + 8)),
                                  firstTriangle: Int(u32(offset + 12)), triangleCount: Int(u32(offset + 16)))
                // Records must tile the vertex and triangle streams in order.
                guard patch.firstVertex == nextVertex, patch.firstTriangle == nextTriangle,
                      patch.firstVertex + patch.vertexCount <= vertices, patch.firstTriangle + patch.triangleCount <= triangles else {
                    throw LoadError.invalid("Patch table does not tile the terrain records.")
                }
                nextVertex += patch.vertexCount; nextTriangle += patch.triangleCount
                patches.append(patch)
            }
            guard nextVertex == vertices, nextTriangle == triangles else { throw LoadError.invalid("Patch table does not cover the terrain.") }
            return (vertices, triangles, patchCount, bounds, patches)
        }
        vertexOffset = 48; vertexCount = header.0; triangleCount = header.1
        triangleOffset = 48 + header.0 * 24
        boundsMin = PGAVector(x: header.3[0], y: header.3[1], z: header.3[2])
        boundsMax = PGAVector(x: header.3[3], y: header.3[4], z: header.3[5])
        patches = header.4
        materials = Self.loadMaterials(directory: self.directory)
        let holeFile = try Self.loadHoles(directory: self.directory)
        holes = holeFile.holes; title = holeFile.title; sourceTCRSHA256 = holeFile.sha
        guard !holes.isEmpty, holes.count <= 32 else { throw LoadError.invalid("Course must have 1-32 holes.") }
    }

    /// Source triangle indices for one hole under the chosen conditions.
    func triangles(hole: Int, conditions: PGACourseConditions) -> [UInt32] {
        var result: [UInt32] = []
        for patch in patches where conditions.includes(layer: patch.layer, hole: hole) {
            result.append(contentsOf: (patch.firstTriangle..<(patch.firstTriangle + patch.triangleCount)).map { UInt32($0) })
        }
        return result
    }

    func position(_ vertex: UInt32) -> PGAVector {
        terrain.withUnsafeBytes { bytes in
            let offset = vertexOffset + Int(vertex) * 24
            func f(_ o: Int) -> Double { Double(Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + o, as: UInt32.self)))) }
            return PGAVector(x: f(0), y: f(4), z: f(8))
        }
    }

    /// Default transform: horizontal center of the course bounds and its lowest point.
    var defaultTransform: PGACourseTransform {
        PGACourseTransform(origin: PGAVector(x: (boundsMin.x + boundsMax.x) / 2, y: boundsMin.y, z: (boundsMin.z + boundsMax.z) / 2))
    }

    private struct MaterialFile: Decodable {
        struct Entry: Decodable { var id: UInt32; var name: String; var texture: String; var surface_types: [PGAOriginalSurfaceRecord]; var section_flags: UInt32? }
        var schema_version: Int
        var materials: [Entry]
    }
    private static func loadMaterials(directory: URL) -> [UInt32: Material] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("materials.json")), data.count <= 3_000_000,
              let file = try? JSONDecoder().decode(MaterialFile.self, from: data), file.schema_version == 1,
              file.materials.count <= 256 else { return [:] }
        var result: [UInt32: Material] = [:]
        for entry in file.materials {
            var texture: URL?
            let url = directory.appendingPathComponent(entry.texture).standardizedFileURL
            if !entry.texture.hasPrefix("/"), url.path.hasPrefix(directory.path + "/"), url.pathExtension.lowercased() == "png",
               FileManager.default.fileExists(atPath: url.path) { texture = url }
            result[entry.id] = Material(id: entry.id, name: entry.name, texture: texture, records: entry.surface_types,
                                        properties: PGASurfaceProperties(materialID: entry.id, materialName: entry.name,
                                                                         sectionFlags: entry.section_flags ?? 0,
                                                                         records: entry.surface_types.map { .init(label: $0.name, flags: $0.flags, coefficients: $0.coefficients) }))
        }
        return result
    }

    private struct HoleFile: Decodable {
        struct Point: Decodable { var index: Int; var xyz_raw: [Double] }
        struct Hole: Decodable {
            var number: Int; var par: Int; var handicap: Int
            var tees: [Point]; var pins: [Point]; var aim_points: [Point]
            var yardages_by_tee: [Int]?
        }
        var schema_version: Int
        var course_title: String
        var source_tcr_sha256: String
        var holes: [Hole]
    }
    private static func loadHoles(directory: URL) throws -> (holes: [SourceHole], title: String, sha: String) {
        let data = try Data(contentsOf: directory.appendingPathComponent("holes.json"))
        guard data.count <= 5_000_000 else { throw LoadError.invalid("holes.json is too large.") }
        let file = try JSONDecoder().decode(HoleFile.self, from: data)
        guard file.schema_version == 1 else { throw LoadError.invalid("Unsupported holes.json schema.") }
        func vector(_ point: HoleFile.Point) throws -> PGAVector {
            guard point.xyz_raw.count == 3, point.xyz_raw.allSatisfy({ $0.isFinite && abs($0) < 1e7 }) else {
                throw LoadError.invalid("Invalid original hole coordinate.")
            }
            return PGAVector(x: point.xyz_raw[0], y: point.xyz_raw[1], z: point.xyz_raw[2])
        }
        let holes = try file.holes.enumerated().map { index, hole -> SourceHole in
            guard hole.number == index + 1, (3...6).contains(hole.par), !hole.tees.isEmpty, !hole.pins.isEmpty else {
                throw LoadError.invalid("Original hole \(index + 1) is incomplete.")
            }
            return SourceHole(number: hole.number, par: hole.par, handicap: hole.handicap,
                              tees: try hole.tees.map(vector), pins: try hole.pins.map(vector),
                              aimPoints: try hole.aim_points.map(vector), yardagesByTee: hole.yardages_by_tee)
        }
        return (holes, file.course_title, file.source_tcr_sha256)
    }
}

/// Floor queries for one hole's patches through the shared transform.
final class PGAOriginalHoleTerrain: PGATerrainSampling, @unchecked Sendable {
    let collider: PGAOriginalCollision
    let transform: PGACourseTransform
    let classes: [UInt32: PGASurfaceProperties]

    init(collider: PGAOriginalCollision, transform: PGACourseTransform, classes: [UInt32: PGASurfaceProperties]) {
        self.collider = collider; self.transform = transform; self.classes = classes
    }

    func ground(x: Double, z: Double, ceiling: Double) -> PGAGroundSample? {
        let raw = transform.raw(meters: PGAVector(x: x, y: ceiling.isFinite ? ceiling : 0, z: z))
        guard let hit = collider.sample(rawX: raw.x, rawZ: raw.z, maximumHeight: ceiling.isFinite ? raw.y : .infinity) else { return nil }
        let info = classes[hit.terrainID]
        return PGAGroundSample(height: (hit.rawHeight - transform.origin.y) * PGACourseTransform.metersPerInch,
                               normal: transform.direction(raw: hit.normal), surface: info?.surface ?? .unplayable,
                               lie: info?.category ?? "Unclassified", materialID: hit.terrainID, properties: info)
    }

    /// Successive floors from the top down, for choosing an authored surface
    /// under a tee or pin whose stored height is not authoritative.
    func layers(x: Double, z: Double, limit: Int = 32) -> [PGAGroundSample] {
        var result: [PGAGroundSample] = []
        var ceiling = Double.infinity
        while result.count < limit, let sample = ground(x: x, z: z, ceiling: ceiling) {
            result.append(sample); ceiling = sample.height - 0.001
        }
        return result
    }
}

/// An 18-hole development course assembled from original data. Ball physics,
/// penalties and the generated golfer remain provisional native code.
final class PGAOriginalPlayableCourse: @unchecked Sendable {
    struct Validation: Equatable {
        var hole: Int
        var teeSurface: PGASurface
        var teeHeightErrorInches: Double
        var pinSurface: PGASurface
        var pinHeightOffsetInches: Double
        var triangles: Int
    }

    let data: PGAOriginalCourseData
    let conditions: PGACourseConditions
    let transform: PGACourseTransform
    let teeIndex: Int
    let pinIndex: Int
    let course: PGACourse
    let terrains: [PGAOriginalHoleTerrain]
    let selections: [[UInt32]]
    let validation: [Validation]

    static let developmentTeeIndex = 3

    /// Synchronous and CPU-bound: run on a worker. Builds one bounded floor
    /// index per hole over that hole's triangles only.
    init(data: PGAOriginalCourseData, conditions: PGACourseConditions = .standard,
         teeIndex: Int = PGAOriginalPlayableCourse.developmentTeeIndex, pinIndex: Int = 0) throws {
        self.data = data; self.conditions = conditions; self.teeIndex = teeIndex; self.pinIndex = pinIndex
        let transform = data.defaultTransform
        self.transform = transform
        let classes = data.materials.mapValues(\.properties)
        var holes: [PGAHole] = [], terrains: [PGAOriginalHoleTerrain] = [], selections: [[UInt32]] = [], checks: [Validation] = []
        for source in data.holes {
            try Task.checkCancellation()
            let selection = data.triangles(hole: source.number, conditions: conditions)
            guard !selection.isEmpty else { throw PGAOriginalCourseData.LoadError.invalid("Hole \(source.number) has no source patches.") }
            let collider = try PGAOriginalCollision(data: data.terrain, selection: selection)
            let terrain = PGAOriginalHoleTerrain(collider: collider, transform: transform, classes: classes)
            let rawTee = source.tees[min(teeIndex, source.tees.count - 1)]
            let rawPin = source.pins[min(pinIndex, source.pins.count - 1)]
            let tee = Self.snap(rawTee, in: terrain, preferring: .tee, transform: transform)
            let pin = Self.snap(rawPin, in: terrain, preferring: .green, transform: transform)
            guard let tee, let pin else { throw PGAOriginalCourseData.LoadError.invalid("Hole \(source.number) tee or pin has no source floor.") }
            let aims = source.aimPoints.map { transform.meters(raw: $0) }
            let yards = source.yardagesByTee.flatMap { $0.indices.contains(teeIndex) ? $0[teeIndex] : nil }
            holes.append(PGAHole(name: "Hole \(source.number)", par: source.par, tee: tee.point, cup: pin.point,
                                 centerline: [tee.point] + aims + [pin.point], fairwayWidth: 0, greenRadius: 0, hazards: [],
                                 terrainSeed: 0, source: PGAHoleSource(number: source.number, teeIndex: teeIndex, pinIndex: pinIndex,
                                                                       handicap: source.handicap, scorecardYards: yards)))
            terrains.append(terrain); selections.append(selection)
            checks.append(Validation(hole: source.number, teeSurface: tee.surface,
                                     teeHeightErrorInches: (transform.meters(raw: rawTee).y - tee.point.y) / PGACourseTransform.metersPerInch,
                                     pinSurface: pin.surface,
                                     pinHeightOffsetInches: (transform.meters(raw: rawPin).y - pin.point.y) / PGACourseTransform.metersPerInch,
                                     triangles: selection.count))
        }
        let identity = "pga2005-\(data.code)-\(data.sourceTCRSHA256.prefix(16))-ghpc3-l\(String(conditions.selector, radix: 16))-t\(teeIndex)p\(pinIndex)"
        course = PGACourse(name: data.title, provenance: "Original \(data.code) TCR terrain, materials, tees and pins · approximate native physics",
                           holes: holes, identity: identity)
        self.terrains = terrains; self.selections = selections; validation = checks
    }

    static func load(code: String, root: URL, conditions: PGACourseConditions = .standard) throws -> PGAOriginalPlayableCourse {
        guard ["PBL", "TUR"].contains(code) else { throw PGAOriginalCourseData.LoadError.invalid("Unsupported course \(code).") }
        let directory = root.appendingPathComponent("Library/Imported/pga2005/\(code)")
        return try PGAOriginalPlayableCourse(data: PGAOriginalCourseData(directory: directory, code: code), conditions: conditions)
    }

    /// Tee and pin heights are not authoritative (hole 8 tees are stored below
    /// the course), so each is placed on the floor under its authored XZ,
    /// preferring the expected surface among the overlapping layers.
    private static func snap(_ raw: PGAVector, in terrain: PGAOriginalHoleTerrain, preferring surface: PGASurface,
                             transform: PGACourseTransform) -> (point: PGAVector, surface: PGASurface)? {
        let meters = transform.meters(raw: raw)
        let layers = terrain.layers(x: meters.x, z: meters.z)
        let chosen = layers.first(where: { $0.surface == surface }) ?? layers.min(by: { abs($0.height - meters.y) < abs($1.height - meters.y) })
        guard let chosen else { return nil }
        return (PGAVector(x: meters.x, y: chosen.height, z: meters.z), chosen.surface)
    }
}

/// One in-progress round per original course, in Application Support. The
/// file names the course identity, so changed source data or settings start a
/// fresh round instead of restoring onto different geometry.
enum PGARoundStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Game Hub/PGA2005 Rounds", isDirectory: true)
    }
    private static func url(identity: String) -> URL {
        let safe = String(identity.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" })
        return directory.appendingPathComponent("\(safe.prefix(120)).json")
    }
    static func load(identity: String) -> PGARoundSnapshot? {
        guard let data = try? Data(contentsOf: url(identity: identity)), data.count < 64_000,
              let snapshot = try? JSONDecoder().decode(PGARoundSnapshot.self, from: data),
              snapshot.courseIdentity == identity else { return nil }
        return snapshot
    }
    static func save(_ snapshot: PGARoundSnapshot) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url(identity: snapshot.courseIdentity), options: .atomic) }
    }
    static func clear(identity: String) { try? FileManager.default.removeItem(at: url(identity: identity)) }
}
