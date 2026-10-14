import AppKit
import Metal
import SceneKit
import simd

/// Original course objects for one course (objects.json, instances.json,
/// GHOM tree meshes and their DDS textures), decoded by
/// Tools/decode_pga2005_objects.py. Loaded once per course on a worker and
/// shared by every hole: about 1 MB of meshes and 9–10 MB of BC textures.
final class PGAOriginalVegetationLibrary: @unchecked Sendable {
    /// One GHOM tree LOD on the GPU.
    struct Mesh {
        struct Part { var texture: Int; var cutout: Bool; var first: Int; var count: Int }
        var vertices: MTLBuffer?
        var indices: MTLBuffer?
        var bark: [Part]
        var leaves: MTLBuffer?
        var leafParts: [Part]
        var vertexCount: Int
        var leafCount: Int
        var triangleCount: Int
        /// Model-unit height and crown centre/radius (leaf shading).
        var height: Float
        var crown: SIMD4<Float>
    }
    struct Model {
        var name: String
        /// Mesh index per LOD 0…2 (fewer when the library has fewer LODs).
        var lods: [Int]
        var billboardTexture: Int
        /// Billboard width in model units (small polyObject X extent).
        var billboardWidth: Float
        /// LOD0 bounding radius about the origin in model units (culling).
        var radius: Float
        var height: Float
    }
    /// Raw instance in source inches (instances.json row).
    struct Tree {
        var type: UInt16
        var rotation: UInt8
        var layer: UInt16
        var position: SIMD3<Float>
        var scale: Float
        var maxY: Float
    }

    let device: MTLDevice
    let gpu: PGAOriginalSceneryGPU
    let textures: [MTLTexture]
    let meshes: [Mesh]
    let models: [Model]
    /// TCR object type → model index.
    let typeModels: [Int]
    /// Trees per hole number (layer & 0x1f), all condition variants.
    let trees: [Int: [Tree]]
    let skyINI: (scaleX: Float, scaleZ: Float, yOffset: Float)
    let panoramas: PGAOriginalPanoramaSource?
    let textureBytes: Int

    /// The original's tree LOD radii in inches (CRenderSettings::RestoreDefaults):
    /// LOD0 to 540, LOD1 to 1800, LOD2 to 14400, billboards beyond.
    static let lodDistancesInches = SIMD3<Float>(540, 1800, 14_400)
    /// Original float32 2π/5 rotation step (0x1002adb0).
    static let rotationStep = Float(bitPattern: 0x3fa0_d97c)

    private struct ObjectsFile: Decodable {
        struct TypeEntry: Decodable { var type: Int; var model: String }
        struct Material: Decodable { var texture: String; var kind: String; var alpha_test: Bool? }
        struct LOD: Decodable { var lod: Int; var mesh: String; var materials: [Material] }
        struct Billboard: Decodable { var texture: String; var width_local: Double; var y_local: [Double] }
        struct ModelEntry: Decodable { var name: String; var lods: [LOD]; var billboard: Billboard }
        struct SkyINI: Decodable { var SkyDome: [String: String]? }
        var schema_version: Int
        var types: [TypeEntry]
        var models: [String: ModelEntry]
        var sky_ini: SkyINI?
    }
    private struct InstancesFile: Decodable {
        var schema_version: Int
        var fields: [String]
        var holes: [String: [[Double]]]
    }

    /// Synchronous file and GPU-resource work: call on a worker.
    init(directory: URL) throws {
        guard let gpu = PGAOriginalSceneryGPU.shared else { throw PGAOriginalCourseData.LoadError.invalid("Metal is unavailable.") }
        self.gpu = gpu; device = gpu.device
        let root = directory.appendingPathComponent("objects", isDirectory: true).standardizedFileURL
        func contained(_ relative: String) throws -> URL {
            let url = root.appendingPathComponent(relative).standardizedFileURL
            guard !relative.hasPrefix("/"), url.path.hasPrefix(root.path + "/") else {
                throw PGAOriginalCourseData.LoadError.invalid("Object path escapes the course directory.")
            }
            return url
        }
        let objectsData = try Data(contentsOf: root.appendingPathComponent("objects.json"))
        let instancesData = try Data(contentsOf: root.appendingPathComponent("instances.json"))
        guard objectsData.count < 20_000_000, instancesData.count < 40_000_000 else {
            throw PGAOriginalCourseData.LoadError.invalid("Object files are too large.")
        }
        let objects = try JSONDecoder().decode(ObjectsFile.self, from: objectsData)
        let instances = try JSONDecoder().decode(InstancesFile.self, from: instancesData)
        guard objects.schema_version == 1, instances.schema_version == 1, objects.types.count <= 256,
              instances.fields.prefix(6) == ["type", "x", "y", "z", "rotation_index", "scale"],
              let maxYField = instances.fields.firstIndex(of: "max_y"), let layerField = instances.fields.firstIndex(of: "layer") else {
            throw PGAOriginalCourseData.LoadError.invalid("Unsupported objects.json/instances.json schema.")
        }
        var textureIndex: [String: Int] = [:], textures: [MTLTexture] = [], bytes = 0
        func texture(_ relative: String) throws -> Int {
            if let index = textureIndex[relative] { return index }
            guard let loaded = PGAOriginalTextureFile.texture(png: try contained(relative), device: gpu.device) else {
                throw PGAOriginalCourseData.LoadError.invalid("Texture \(relative) failed to load.")
            }
            bytes += loaded.allocatedSize
            textureIndex[relative] = textures.count; textures.append(loaded)
            return textures.count - 1
        }
        var meshIndex: [String: Int] = [:], meshes: [Mesh] = [], models: [Model] = [], modelIndex: [String: Int] = [:]
        for key in objects.models.keys.sorted() {
            guard let entry = objects.models[key] else { continue }
            var lods: [Int] = [], radius: Float = 0, height: Float = 0
            for lod in entry.lods.sorted(by: { $0.lod < $1.lod }).prefix(3) {
                let parts = try lod.materials.map { ($0, try texture($0.texture)) }
                let cacheKey = lod.mesh + "|" + parts.map { "\($0.1)" }.joined(separator: ",")
                if let existing = meshIndex[cacheKey] { lods.append(existing); continue }
                let ghom = try PGAOriginalGHOM(data: Data(contentsOf: try contained(lod.mesh)))
                func part(_ range: PGAOriginalGHOM.Range) throws -> Mesh.Part {
                    guard parts.indices.contains(range.material) else { throw PGAOriginalCourseData.LoadError.invalid("Mesh material out of range.") }
                    let material = parts[range.material]
                    return Mesh.Part(texture: material.1, cutout: material.0.alpha_test ?? false, first: range.first, count: range.count)
                }
                let bark = try ghom.ranges.filter { $0.count > 0 }.map(part)
                let leafParts = try ghom.leafRanges.map(part)
                guard leafParts.allSatisfy({ $0.count <= PGAOriginalSceneryGPU.quadCapacity }) else {
                    throw PGAOriginalCourseData.LoadError.invalid("Too many leaves in one tree material.")
                }
                let centroid = ghom.leafCenters.isEmpty ? SIMD3<Float>(0, ghom.boundsMax.y * 0.6, 0)
                    : ghom.leafCenters.reduce(SIMD3<Float>.zero, +) / Float(ghom.leafCenters.count)
                let reach = ghom.leafCenters.map { simd_length($0 - centroid) }.max() ?? 1
                let mesh = Mesh(vertices: ghom.vertexCount > 0 ? ghom.vertices.withUnsafeBytes { gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) } : nil,
                                indices: ghom.indices.isEmpty ? nil : ghom.indices.withUnsafeBytes { gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) },
                                bark: bark,
                                leaves: ghom.leaves.isEmpty ? nil : ghom.leaves.withUnsafeBytes { gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) },
                                leafParts: leafParts, vertexCount: ghom.vertexCount, leafCount: ghom.leafCenters.count,
                                triangleCount: ghom.indices.count / 3, height: max(ghom.boundsMax.y, 1e-3),
                                crown: SIMD4(centroid, max(reach, 1e-3)))
                meshIndex[cacheKey] = meshes.count; lods.append(meshes.count); meshes.append(mesh)
                if lod.lod == 0 || radius == 0 {
                    let corners = [ghom.boundsMin, ghom.boundsMax]
                    radius = corners.map { simd_length(SIMD2($0.x, $0.z)) }.max() ?? 0
                    height = ghom.boundsMax.y
                }
            }
            let billboardTexture = try texture(entry.billboard.texture)
            height = max(height, Float(entry.billboard.y_local.last ?? 0))
            modelIndex[key] = models.count
            models.append(Model(name: entry.name, lods: lods, billboardTexture: billboardTexture,
                                billboardWidth: Float(entry.billboard.width_local), radius: max(radius, Float(entry.billboard.width_local) / 2),
                                height: height))
        }
        let typeModels = try objects.types.sorted { $0.type < $1.type }.enumerated().map { offset, entry in
            guard entry.type == offset, let model = modelIndex[entry.model] else { throw PGAOriginalCourseData.LoadError.invalid("Object type table is incomplete.") }
            return model
        }
        self.typeModels = typeModels
        var trees: [Int: [Tree]] = [:]
        for (key, rows) in instances.holes {
            guard let hole = Int(key), (0...31).contains(hole) else { continue }
            trees[hole] = try rows.map { row in
                guard row.count > max(maxYField, layerField), let type = UInt16(exactly: row[0]), Int(type) < typeModels.count,
                      row[1...5].allSatisfy(\.isFinite), row[5] > 0 else {
                    throw PGAOriginalCourseData.LoadError.invalid("Invalid tree instance in hole \(hole).")
                }
                return Tree(type: type, rotation: UInt8(clamping: Int(row[4]) % 5), layer: UInt16(clamping: Int(row[layerField])),
                            position: SIMD3(Float(row[1]), Float(row[2]), Float(row[3])), scale: Float(row[5]), maxY: Float(row[maxYField]))
            }
        }
        let dome = objects.sky_ini?.SkyDome ?? [:]
        func number(_ key: String) -> Float { dome[key].flatMap { Float($0.trimmingCharacters(in: .whitespaces)) } ?? 1 }
        skyINI = (number("ScaleX"), number("ScaleZ"), number("YOffset"))
        do { panoramas = try PGAOriginalPanoramaSource(root: root, objects: objectsData, texture: texture) } catch {
            panoramas = nil
            NSLog("Original panoramas unavailable: %@", error.localizedDescription)
        }
        self.textures = textures; self.meshes = meshes; self.models = models; self.trees = trees
        textureBytes = bytes
    }
}

/// Lazily loaded original scenery for one course, shared by all its holes.
/// Thread-safe: the first hole build (on a worker) loads the library.
final class PGAOriginalScenery: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var library: PGAOriginalVegetationLibrary?
    private var failed = false
    private var skies: [Int: PGAOriginalSkyDome] = [:]

    init(directory: URL) { self.directory = directory }

    func vegetationLibrary() -> PGAOriginalVegetationLibrary? {
        lock.lock(); defer { lock.unlock() }
        if let library { return library }
        guard !failed else { return nil }
        do { library = try PGAOriginalVegetationLibrary(directory: directory) } catch {
            failed = true
            NSLog("Original vegetation unavailable for %@: %@", directory.lastPathComponent, error.localizedDescription)
        }
        return library
    }

    /// Sky dome `skyType` (1–8), cached per course.
    func sky(type: Int) -> PGAOriginalSkyDome? {
        let type = min(max(type, 1), 8)
        guard let library = vegetationLibrary() else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let cached = skies[type] { return cached }
        let dome = try? PGAOriginalSkyDome(skyDirectory: directory.deletingLastPathComponent().appendingPathComponent("sky", isDirectory: true),
                                           type: type, ini: library.skyINI, gpu: library.gpu)
        skies[type] = dome
        return dome
    }
}

/// One hole's trees on the GPU: a 32-byte record per instance in hole meters
/// plus CPU copies for per-frame LOD selection and culling. About 0.2 MB per
/// hole; released with the hole's scene node.
final class PGAOriginalHoleVegetation: @unchecked Sendable {
    struct GPUInstance { var x, y, z, scale, cosA, sinA, halfWidth, height: Float }
    let library: PGAOriginalVegetationLibrary
    let holeNumber: Int
    let count: Int
    let instances: MTLBuffer?
    /// Ground point (xyz) and bounding radius (w) in meters.
    let spheres: [SIMD4<Float>]
    /// Bounding-sphere centre height above the ground point.
    let lifts: [Float]
    let models: [UInt16]
    let panorama: PGAOriginalHolePanorama?

    init?(course: PGAOriginalPlayableCourse, holeIndex: Int, library: PGAOriginalVegetationLibrary) {
        let number = course.data.holes[holeIndex].number
        let transform = course.transform
        let trees = (library.trees[number] ?? []).filter { course.conditions.includes(layer: UInt32($0.layer), hole: number) }
        var gpu: [GPUInstance] = [], spheres: [SIMD4<Float>] = [], lifts: [Float] = [], models: [UInt16] = []
        gpu.reserveCapacity(trees.count); spheres.reserveCapacity(trees.count)
        let k = Float(PGACourseTransform.metersPerInch)
        for tree in trees {
            let model = library.models[library.typeModels[Int(tree.type)]]
            let p = transform.meters(raw: PGAVector(x: Double(tree.position.x), y: Double(tree.position.y), z: Double(tree.position.z)))
            let angle = Float(tree.rotation) * PGAOriginalVegetationLibrary.rotationStep
            let scale = tree.scale * k
            let height = max(0.1, (tree.maxY - tree.position.y) * k)
            gpu.append(GPUInstance(x: Float(p.x), y: Float(p.y), z: Float(p.z), scale: scale, cosA: cosf(angle), sinA: sinf(angle),
                                   halfWidth: 0.5 * model.billboardWidth * scale, height: height))
            let top = max(height, model.height * scale)
            spheres.append(SIMD4(Float(p.x), Float(p.y), Float(p.z), simd_length(SIMD2(model.radius * scale, top / 2))))
            lifts.append(top / 2)
            models.append(UInt16(library.typeModels[Int(tree.type)]))
        }
        holeNumber = number; count = gpu.count; self.library = library
        instances = gpu.isEmpty ? nil : library.device.makeBuffer(bytes: gpu, length: gpu.count * MemoryLayout<GPUInstance>.stride, options: .storageModeShared)
        self.spheres = spheres; self.lifts = lifts; self.models = models
        panorama = library.panoramas?.hole(number: number, transform: transform, device: library.device, textures: library.textures)
        if count == 0 && panorama == nil { return nil }
    }
}

/// Draws one hole's trees inside SceneKit's pass with instanced Metal draws:
/// each frame every tree is culled against the view and assigned the
/// original LOD by distance (LOD0 ≤ 540 in, LOD1 ≤ 1800 in, LOD2 ≤ 14400 in,
/// LOD3 billboard beyond), then each (mesh, texture) group is one draw.
/// No per-frame allocation: ids go into a small ring of shared buffers.
final class PGAOriginalVegetationDrawer: NSObject, SCNNodeRendererDelegate, @unchecked Sendable {
    struct Stats: Equatable {
        var drawCalls = 0
        /// Visible trees drawn at LOD0, LOD1, LOD2 and as LOD3 billboards.
        var lodTrees = SIMD4<Int>.zero
        var culled = 0
        /// Vertices submitted (bark indices, 4 per leaf card and billboard).
        var vertices = 0
        var meshCapApplied = false
    }
    private struct DrawParams { var crown: SIMD4<Float>; var height: Float; var firstLeaf: UInt32; var extra = SIMD2<Float>.zero }

    let hole: PGAOriginalHoleVegetation
    var style: PGAOriginalSceneryStyle
    /// LOD radii in meters (original defaults).
    var lodDistances = PGAOriginalVegetationLibrary.lodDistancesInches * Float(PGACourseTransform.metersPerInch)
    /// Mesh-tree budget for the M1: past it the farthest LOD2 trees become
    /// billboards for that frame; the original LOD distances apply otherwise.
    var maximumMeshTrees = 1_100
    private(set) var stats = Stats()

    private static let slots = 6
    private static let histogramBins = 64
    private let ring: MTLBuffer?
    private var slot = 0
    private var bucketOf: [UInt16]
    private var distances: [Float]
    private var counts: [Int]
    private var offsets: [Int]
    private var cursor: [Int]
    private var histogram: [Int]
    private var lights: PGAOriginalSceneryLights?
    private let bucketCount: Int
    private var culledBucket: UInt16 { UInt16(bucketCount - 1) }

    init(hole: PGAOriginalHoleVegetation, style: PGAOriginalSceneryStyle) {
        self.hole = hole; self.style = style
        bucketCount = hole.library.models.count * 4 + 1
        ring = hole.count > 0 ? hole.library.device.makeBuffer(length: hole.count * 4 * Self.slots, options: .storageModeShared) : nil
        bucketOf = [UInt16](repeating: 0, count: hole.count)
        distances = [Float](repeating: 0, count: hole.count)
        counts = [Int](repeating: 0, count: bucketCount)
        offsets = [Int](repeating: 0, count: bucketCount)
        cursor = [Int](repeating: 0, count: bucketCount)
        histogram = [Int](repeating: 0, count: Self.histogramBins)
        super.init()
    }

    func renderNode(_ node: SCNNode, renderer: SCNRenderer, arguments: [String: Any]) {
        guard let encoder = renderer.currentRenderCommandEncoder,
              let states = hole.library.gpu.states(for: renderer.currentRenderPassDescriptor),
              var frame = PGAOriginalSceneryGPU.frame(renderer: renderer, arguments: arguments, lights: &lights) else { return }
        frame.tint = SIMD4(style.treeTint, 2 * style.treeAmbient / 255)
        frame.contrast = SIMD4(style.treeContrastMid, style.treeContrastScale, style.treeContrastShift, 150.0 / 255.0)
        let gpu = hole.library.gpu
        encoder.pushDebugGroup("Original vegetation")
        defer { encoder.popDebugGroup() }
        encoder.setDepthStencilState(frame.reverseZ ? gpu.depthReverse : gpu.depthForward)
        encoder.setCullMode(.none)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<PGAOriginalSceneryFrame>.stride, index: 0)
        encoder.setVertexBytes(&frame, length: MemoryLayout<PGAOriginalSceneryFrame>.stride, index: 3)
        var stats = Stats()
        if let panorama = hole.panorama { stats.drawCalls += panorama.draw(encoder: encoder, states: states, gpu: gpu) }
        if hole.count > 0, let ring, let instances = hole.instances {
            classify(frame: frame, stats: &stats)
            let slotOffset = slot * hole.count * 4
            slot = (slot + 1) % Self.slots
            let ids = ring.contents().advanced(by: slotOffset).bindMemory(to: UInt32.self, capacity: hole.count)
            var running = 0
            for bucket in 0..<bucketCount { offsets[bucket] = running; cursor[bucket] = running; running += counts[bucket] }
            let culled = culledBucket
            bucketOf.withUnsafeBufferPointer { buckets in
                cursor.withUnsafeMutableBufferPointer { cursor in
                    for index in 0..<buckets.count where buckets[index] != culled {
                        let bucket = Int(buckets[index])
                        ids[cursor[bucket]] = UInt32(index); cursor[bucket] += 1
                    }
                }
            }
            encoder.setVertexBuffer(instances, offset: 0, index: 1)
            encoder.setVertexBuffer(ring, offset: slotOffset, index: 2)
            draw(encoder: encoder, states: states, stats: &stats)
        }
        self.stats = stats
    }

    /// Culls each tree's bounding sphere against the four side planes and
    /// assigns its bucket (model × 4 + LOD; the last bucket is culled).
    private func classify(frame: PGAOriginalSceneryFrame, stats: inout Stats) {
        let camera = SIMD3(frame.camera.x, frame.camera.y, frame.camera.z)
        let l0 = lodDistances.x * lodDistances.x, l1 = lodDistances.y * lodDistances.y, l2 = lodDistances.z * lodDistances.z
        let culled = culledBucket
        func unit(_ plane: SIMD4<Float>) -> SIMD4<Float> { plane / max(simd_length(SIMD3(plane.x, plane.y, plane.z)), 1e-6) }
        let p0 = unit(frame.planes.0), p1 = unit(frame.planes.1), p2 = unit(frame.planes.2), p3 = unit(frame.planes.3)
        var meshTrees = 0, lod2Trees = 0
        hole.spheres.withUnsafeBufferPointer { spheres in
            hole.lifts.withUnsafeBufferPointer { lifts in
                hole.models.withUnsafeBufferPointer { models in
                    bucketOf.withUnsafeMutableBufferPointer { buckets in
                        distances.withUnsafeMutableBufferPointer { distances in
                            for index in 0..<spheres.count {
                                let sphere = spheres[index]
                                let center = SIMD4<Float>(sphere.x, sphere.y + lifts[index], sphere.z, 1)
                                let r = -sphere.w
                                if simd_dot(p0, center) < r || simd_dot(p1, center) < r || simd_dot(p2, center) < r || simd_dot(p3, center) < r {
                                    buckets[index] = culled; continue
                                }
                                let delta = SIMD3(sphere.x, sphere.y, sphere.z) - camera
                                let d2 = simd_dot(delta, delta)
                                distances[index] = d2
                                let lod = d2 <= l0 ? 0 : d2 <= l1 ? 1 : d2 <= l2 ? 2 : 3
                                if lod < 3 { meshTrees += 1 }
                                if lod == 2 { lod2Trees += 1 }
                                buckets[index] = UInt16(Int(models[index]) * 4 + lod)
                            }
                        }
                    }
                }
            }
        }
        if meshTrees > maximumMeshTrees {
            // Keep the nearest LOD2 trees within budget: a 64-bin histogram of
            // squared distance over the LOD2 band gives the cut-off.
            stats.meshCapApplied = true
            let bins = Self.histogramBins, band = max(l2 - l1, 1)
            for bin in 0..<bins { histogram[bin] = 0 }
            for index in 0..<hole.count where bucketOf[index] != culled && bucketOf[index] % 4 == 2 {
                histogram[min(bins - 1, max(0, Int((distances[index] - l1) / band * Float(bins))))] += 1
            }
            var allowed = maximumMeshTrees - (meshTrees - lod2Trees), cutoff = l1
            for bin in 0..<bins {
                allowed -= histogram[bin]
                if allowed < 0 { break }
                cutoff = l1 + band * Float(bin + 1) / Float(bins)
            }
            for index in 0..<hole.count where bucketOf[index] != culled && bucketOf[index] % 4 == 2 && distances[index] > cutoff {
                bucketOf[index] += 1
            }
        }
        for bucket in 0..<bucketCount { counts[bucket] = 0 }
        for index in 0..<hole.count { counts[Int(bucketOf[index])] += 1 }
        for bucket in 0..<(bucketCount - 1) { stats.lodTrees[bucket % 4] += counts[bucket] }
        stats.culled = counts[bucketCount - 1]
    }

    private func draw(encoder: MTLRenderCommandEncoder, states: PGAOriginalSceneryGPU.States, stats: inout Stats) {
        let library = hole.library, gpu = library.gpu
        var bound: MTLRenderPipelineState?
        func use(_ state: MTLRenderPipelineState) { if bound !== state { encoder.setRenderPipelineState(state); bound = state } }
        encoder.setFragmentSamplerState(gpu.repeatSampler, index: 0)
        for (modelIndex, model) in library.models.enumerated() {
            for lod in 0..<min(3, model.lods.count) {
                let bucket = modelIndex * 4 + lod, count = counts[bucket]
                guard count > 0 else { continue }
                let mesh = library.meshes[model.lods[lod]]
                var params = DrawParams(crown: mesh.crown, height: mesh.height, firstLeaf: 0)
                if let vertices = mesh.vertices, let indices = mesh.indices {
                    encoder.setVertexBuffer(vertices, offset: 0, index: 0)
                    for part in mesh.bark {
                        use(part.cutout ? states.barkCutout : states.barkOpaque)
                        encoder.setVertexBytes(&params, length: MemoryLayout<DrawParams>.stride, index: 4)
                        encoder.setFragmentTexture(library.textures[part.texture], index: 0)
                        encoder.drawIndexedPrimitives(type: .triangle, indexCount: part.count, indexType: .uint32, indexBuffer: indices,
                                                      indexBufferOffset: part.first * 4, instanceCount: count, baseVertex: 0,
                                                      baseInstance: offsets[bucket])
                        stats.drawCalls += 1; stats.vertices += part.count * count
                    }
                }
                if let leaves = mesh.leaves {
                    use(states.leaves)
                    encoder.setVertexBuffer(leaves, offset: 0, index: 0)
                    for part in mesh.leafParts {
                        params.firstLeaf = UInt32(part.first)
                        encoder.setVertexBytes(&params, length: MemoryLayout<DrawParams>.stride, index: 4)
                        encoder.setFragmentTexture(library.textures[part.texture], index: 0)
                        encoder.drawIndexedPrimitives(type: .triangle, indexCount: part.count * 6, indexType: .uint16, indexBuffer: gpu.quadIndices,
                                                      indexBufferOffset: 0, instanceCount: count, baseVertex: 0, baseInstance: offsets[bucket])
                        stats.drawCalls += 1; stats.vertices += part.count * 4 * count
                    }
                }
            }
        }
        // LOD3: one instanced 4-vertex strip per billboard texture.
        encoder.setFragmentSamplerState(gpu.clampSampler, index: 0)
        for (modelIndex, model) in library.models.enumerated() {
            let bucket = modelIndex * 4 + 3, count = counts[bucket]
            guard count > 0 else { continue }
            use(states.billboards)
            encoder.setFragmentTexture(library.textures[model.billboardTexture], index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count, baseInstance: offsets[bucket])
            stats.drawCalls += 1; stats.vertices += 4 * count
        }
    }
}

/// Scene node for one hole's original vegetation (and panorama strips). It
/// owns its drawer because SceneKit keeps renderer delegates unretained. The
/// node is drawn after SceneKit's own content so its depth test sees the
/// terrain and no SceneKit draw follows the custom encoder state.
final class PGAOriginalVegetationNode: SCNNode {
    static let nodeName = "Original vegetation"
    let drawer: PGAOriginalVegetationDrawer

    init(hole: PGAOriginalHoleVegetation, style: PGAOriginalSceneryStyle = .standard) {
        drawer = PGAOriginalVegetationDrawer(hole: hole, style: style)
        super.init()
        name = Self.nodeName
        rendererDelegate = drawer
        castsShadow = false
        renderingOrder = 1_000
    }
    required init?(coder: NSCoder) { fatalError("Created programmatically") }
}
