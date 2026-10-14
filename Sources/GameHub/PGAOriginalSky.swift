import AppKit
import Metal
import SceneKit
import simd

/// One original sky dome (install Skydome.tcl pan block SKYTYPE − 1) on the
/// GPU: 307 vertices, 480 triangles and a 1024 × 512 texture per group.
final class PGAOriginalSkyDome: @unchecked Sendable {
    struct Group { var texture: MTLTexture; var blend: Bool; var first: Int; var count: Int }
    let type: Int
    let vertices: MTLBuffer
    let indices: MTLBuffer
    let groups: [Group]

    private struct SkyFile: Decodable {
        struct Group: Decodable { var material: Int; var texture: String; var alpha_blend: Bool }
        struct Dome: Decodable { var sky_type: Int; var mesh: String; var center_xz: [Double]; var groups: [Group] }
        var schema_version: Int
        var domes: [Dome]
    }

    /// Vertices become meters around the dome centre, Z mirrored like the
    /// terrain, at height `YOffset` over the course's lowest point (the
    /// original translates the dome to courseMinY + YOffset, draw routine
    /// Engine 0x101bfdb1). The draw re-centres it on the camera.
    init(skyDirectory: URL, type: Int, ini: (scaleX: Float, scaleZ: Float, yOffset: Float), gpu: PGAOriginalSceneryGPU) throws {
        let root = skyDirectory.standardizedFileURL
        func contained(_ relative: String) throws -> URL {
            let url = root.appendingPathComponent(relative).standardizedFileURL
            guard !relative.hasPrefix("/"), url.path.hasPrefix(root.path + "/") else { throw PGAOriginalCourseData.LoadError.invalid("Sky path escapes its directory.") }
            return url
        }
        let data = try Data(contentsOf: root.appendingPathComponent("sky.json"))
        guard data.count < 20_000_000 else { throw PGAOriginalCourseData.LoadError.invalid("sky.json is too large.") }
        let file = try JSONDecoder().decode(SkyFile.self, from: data)
        guard file.schema_version == 1, let dome = file.domes.first(where: { $0.sky_type == type }), dome.center_xz.count == 2 else {
            throw PGAOriginalCourseData.LoadError.invalid("Sky type \(type) is not decoded.")
        }
        let ghom = try PGAOriginalGHOM(data: Data(contentsOf: try contained(dome.mesh)))
        let k = Float(PGACourseTransform.metersPerInch)
        let cx = Float(dome.center_xz[0]), cz = Float(dome.center_xz[1])
        var bytes = ghom.vertices
        bytes.withUnsafeMutableBytes { raw in
            for v in 0..<ghom.vertexCount {
                let base = v * PGAOriginalGHOM.vertexStride
                let x = raw.loadUnaligned(fromByteOffset: base, as: Float.self)
                let y = raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self)
                let z = raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self)
                raw.storeBytes(of: (x - cx) * k * ini.scaleX, toByteOffset: base, as: Float.self)
                raw.storeBytes(of: (y + ini.yOffset) * k, toByteOffset: base + 4, as: Float.self)
                raw.storeBytes(of: -(z - cz) * k * ini.scaleZ, toByteOffset: base + 8, as: Float.self)
            }
        }
        guard let vertices = bytes.withUnsafeBytes({ gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let indices = ghom.indices.withUnsafeBytes({ gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
            throw PGAOriginalCourseData.LoadError.invalid("Sky buffers failed.")
        }
        var groups: [Group] = []
        for range in ghom.ranges where range.count > 0 {
            guard let group = dome.groups.first(where: { $0.material == range.material }),
                  let texture = PGAOriginalTextureFile.texture(png: try contained(group.texture), device: gpu.device) else {
                throw PGAOriginalCourseData.LoadError.invalid("Sky group texture missing.")
            }
            groups.append(Group(texture: texture, blend: group.alpha_blend, first: range.first, count: range.count))
        }
        // Opaque base first, blended cloud layers over it.
        self.groups = groups.filter { !$0.blend } + groups.filter(\.blend)
        self.type = type; self.vertices = vertices; self.indices = indices
    }
}

/// Draws the dome first, without depth or fog, re-centred on the camera.
final class PGAOriginalSkyDrawer: NSObject, SCNNodeRendererDelegate, @unchecked Sendable {
    let dome: PGAOriginalSkyDome
    let gpu: PGAOriginalSceneryGPU
    var tint: SIMD3<Float>
    private var lights: PGAOriginalSceneryLights?

    init(dome: PGAOriginalSkyDome, gpu: PGAOriginalSceneryGPU, tint: SIMD3<Float>) {
        self.dome = dome; self.gpu = gpu; self.tint = tint
    }

    func renderNode(_ node: SCNNode, renderer: SCNRenderer, arguments: [String: Any]) {
        guard let encoder = renderer.currentRenderCommandEncoder, let states = gpu.states(for: renderer.currentRenderPassDescriptor),
              var frame = PGAOriginalSceneryGPU.frame(renderer: renderer, arguments: arguments, lights: &lights) else { return }
        // The dome image is the same at any radius about the eye; 5% keeps
        // it (about 90 m) inside the depth range.
        var draw = (SIMD4<Float>(tint, 1), SIMD4<Float>(0.05, 0, 0, 0))
        encoder.pushDebugGroup("Original sky dome")
        encoder.setDepthStencilState(gpu.depthNone)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(dome.vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&frame, length: MemoryLayout<PGAOriginalSceneryFrame>.stride, index: 3)
        encoder.setVertexBytes(&draw, length: 32, index: 4)
        encoder.setFragmentSamplerState(gpu.repeatSampler, index: 0)
        for group in dome.groups {
            encoder.setRenderPipelineState(group.blend ? states.skyBlend : states.sky)
            encoder.setFragmentTexture(group.texture, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: group.count, indexType: .uint32, indexBuffer: dome.indices,
                                          indexBufferOffset: group.first * 4)
        }
        encoder.popDebugGroup()
    }
}

final class PGAOriginalSkyNode: SCNNode {
    static let nodeName = "Original sky dome"
    let drawer: PGAOriginalSkyDrawer

    init(dome: PGAOriginalSkyDome, gpu: PGAOriginalSceneryGPU, skydomeDiffuse: SIMD3<Float> = SIMD3(1, 1, 1)) {
        drawer = PGAOriginalSkyDrawer(dome: dome, gpu: gpu, tint: skydomeDiffuse)
        super.init()
        name = Self.nodeName
        rendererDelegate = drawer
        castsShadow = false
        renderingOrder = -1_000
    }
    required init?(coder: NSCoder) { fatalError("Created programmatically") }
}

/// Panorama blocks of one course (TCR pan blocks, world-coordinate strips
/// with cut-out textures). Per-hole selection follows the INI's
/// `[HOLE n] HolePanId`; the CRPanorama draw code was not analysed, so
/// placement is shown as decoded and verified visually.
final class PGAOriginalPanoramaSource: @unchecked Sendable {
    struct Block { var mesh: URL; var textures: [Int: Int] }
    let blocks: [Int: Block]
    let holeBlocks: [Int: Int]

    private struct File: Decodable {
        struct Group: Decodable { var material: Int; var texture: String }
        struct Block: Decodable { var index: Int; var mesh: String; var groups: [Group] }
        struct Panoramas: Decodable { var blocks: [Block]; var per_hole_ini: [String: [String: String?]]? }
        var panoramas: Panoramas?
    }

    init(root: URL, objects: Data, texture: (String) throws -> Int) throws {
        let file = try JSONDecoder().decode(File.self, from: objects)
        guard let panoramas = file.panoramas else { throw PGAOriginalCourseData.LoadError.invalid("No panoramas.") }
        var blocks: [Int: Block] = [:]
        for block in panoramas.blocks {
            let url = root.appendingPathComponent(block.mesh).standardizedFileURL
            guard !block.mesh.hasPrefix("/"), url.path.hasPrefix(root.path + "/") else { continue }
            var textures: [Int: Int] = [:]
            for group in block.groups { textures[group.material] = try texture(group.texture) }
            blocks[block.index] = Block(mesh: url, textures: textures)
        }
        var holes: [Int: Int] = [:]
        for (key, values) in panoramas.per_hole_ini ?? [:] {
            if let hole = Int(key), let id = values["HolePanId"].flatMap({ $0 }).flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) { holes[hole] = id }
        }
        self.blocks = blocks; holeBlocks = holes
    }

    func hole(number: Int, transform: PGACourseTransform, device: MTLDevice, textures: [MTLTexture]) -> PGAOriginalHolePanorama? {
        guard let id = holeBlocks[number] ?? (blocks[number] != nil ? number : nil), let block = blocks[id] else { return nil }
        return try? PGAOriginalHolePanorama(block: block, transform: transform, device: device, textures: textures)
    }
}

/// One hole's panorama strips in hole meters.
final class PGAOriginalHolePanorama: @unchecked Sendable {
    struct Part { var texture: MTLTexture; var first: Int; var count: Int }
    let vertices: MTLBuffer
    let indices: MTLBuffer
    let parts: [Part]
    let triangles: Int

    init(block: PGAOriginalPanoramaSource.Block, transform: PGACourseTransform, device: MTLDevice, textures: [MTLTexture]) throws {
        let ghom = try PGAOriginalGHOM(data: Data(contentsOf: block.mesh))
        var bytes = ghom.vertices
        bytes.withUnsafeMutableBytes { raw in
            for v in 0..<ghom.vertexCount {
                let base = v * PGAOriginalGHOM.vertexStride
                let p = transform.meters(raw: PGAVector(x: Double(raw.loadUnaligned(fromByteOffset: base, as: Float.self)),
                                                        y: Double(raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self)),
                                                        z: Double(raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self))))
                raw.storeBytes(of: Float(p.x), toByteOffset: base, as: Float.self)
                raw.storeBytes(of: Float(p.y), toByteOffset: base + 4, as: Float.self)
                raw.storeBytes(of: Float(p.z), toByteOffset: base + 8, as: Float.self)
            }
        }
        guard ghom.vertexCount > 0,
              let vertices = bytes.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let indices = ghom.indices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
            throw PGAOriginalCourseData.LoadError.invalid("Empty panorama.")
        }
        parts = ghom.ranges.compactMap { range in
            guard range.count > 0, let index = block.textures[range.material], textures.indices.contains(index) else { return nil }
            return Part(texture: textures[index], first: range.first, count: range.count)
        }
        self.vertices = vertices; self.indices = indices; triangles = ghom.indices.count / 3
    }

    func draw(encoder: MTLRenderCommandEncoder, states: PGAOriginalSceneryGPU.States, gpu: PGAOriginalSceneryGPU) -> Int {
        encoder.setRenderPipelineState(states.panorama)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setFragmentSamplerState(gpu.clampSampler, index: 0)
        for part in parts {
            encoder.setFragmentTexture(part.texture, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: part.count, indexType: .uint32, indexBuffer: indices,
                                          indexBufferOffset: part.first * 4)
        }
        return parts.count
    }
}
