import AppKit
import CryptoKit
import ImageIO
import SceneKit

/// Batches actual source placements/faces by material. This is an original
/// scene foundation, not a completed skating game or reconstructed renderer.
/// Display conversion is (x, -y, z); source values remain intact in the loader.
@MainActor
struct THPS2OriginalScene {
    enum TextureChoice { case originalPaletted, suppliedPCBMP }
    struct Result {
        let scene: SCNScene
        let triangleCount: Int
        let drawGroups: Int
        let minimum: SIMD3<Float>
        let maximum: SIMD3<Float>
        let unresolvedTextureIDs: Set<UInt32>
    }
    private struct Key: Hashable {
        let layer: Int
        let textureIndex: Int?
        let flatTranslucent: Bool
    }
    private final class Group {
        var vertices = Data()
        var count = 0
    }
    private struct Image {
        let image: CGImage
        let width: Int
        let height: Int
        let logicalWidth: Int
        let logicalHeight: Int
    }

    static func build(_ level: THPS2OriginalLevel, textureChoice: TextureChoice = .originalPaletted) throws -> Result {
        var groups: [Key: Group] = [:]
        var images: [Key: Image] = [:]
        var missing: Set<UInt32> = []
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        var triangles = 0, corners = 0, decodedPixels = 0
        for (li, layer) in level.layers.enumerated() where layer.role != "texture-library" {
            let source = layer.content
            for oi in source.objects.indices {
                let object = source.objects[oi], model = source.models[object.modelIndex]
                for fi in 0..<model.faces.count {
                    guard let face = source.face(model: object.modelIndex, index: fi), face.visible else { continue }
                    // Flat GPU opcode bit 1 is semitransparency. Gouraud faces
                    // replace the opcode bytes with color indices, so no blend
                    // mode is guessed from that byte's unrelated low bits.
                    let translucent = face.flags & 0x800 == 0 && face.colorBytes.w & 2 != 0
                    let key = Key(layer: li, textureIndex: face.textureIndex, flatTranslucent: translucent)
                    if let ti = face.textureIndex, images[key] == nil {
                        let id = source.textureNames[ti]
                        if let image = try image(level, layerIndex: li, textureIndex: ti, choice: textureChoice) {
                            decodedPixels += image.width * image.height
                            guard decodedPixels <= 8_000_000 else { throw THPS2PSX.LoadError.resourceLimit }
                            images[key] = image
                        } else { missing.insert(id) }
                    }
                    // PSX GPU quads use the 0,1,2 / 2,1,3 diagonal. Negating
                    // source Y reverses handedness, so these source index
                    // orders face the preserved native normal after reflection.
                    let order = face.cornerCount == 3 ? [0, 1, 2] : [0, 1, 2, 2, 1, 3]
                    corners += order.count
                    guard corners <= 2_000_000 else { throw THPS2PSX.LoadError.resourceLimit }
                    let group = groups[key] ?? Group()
                    let normal = source.plane(model: object.modelIndex, index: face.plane)!
                    let n = SIMD3(Float(normal.x) / 4096, -Float(normal.y) / 4096, Float(normal.z) / 4096)
                    for corner in order {
                        let point = source.sourceWorldPosition(object: oi, vertex: Int(face.indices[corner]))!
                        let p = SIMD3(Float(point.x), -Float(point.y), Float(point.z))
                        for axis in 0..<3 { lo[axis] = min(lo[axis], p[axis]); hi[axis] = max(hi[axis], p[axis]) }
                        let color: SIMD4<UInt8>
                        if face.flags & 0x800 != 0 { color = source.gouraudColor(face.colorBytes[corner])! }
                        else { color = face.colorBytes }
                        // PS1 textured colors use 128 as neutral modulation.
                        // Native constant shading preserves original per-corner
                        // colors; exact saturation/blend matching is pending.
                        let denominator: Float = face.textureIndex == nil ? 255 : 128
                        let c = SIMD3(Float(color.x) / denominator, Float(color.y) / denominator, Float(color.z) / denominator)
                        var uv = SIMD2<Float>.zero
                        if let coords = face.uv, let image = images[key] {
                            uv = SIMD2(Float(coords[corner].x) / Float(image.logicalWidth),
                                       1 - Float(coords[corner].y) / Float(image.logicalHeight))
                        }
                        for value in [p.x, p.y, p.z, n.x, n.y, n.z, c.x, c.y, c.z, uv.x, uv.y] {
                            var bits = value.bitPattern.littleEndian
                            withUnsafeBytes(of: &bits) { group.vertices.append(contentsOf: $0) }
                        }
                        group.count += 1
                    }
                    groups[key] = group
                    triangles += order.count / 3
                }
            }
        }
        let scene = SCNScene()
        let world = SCNNode(); world.name = "THPS2 original placements (display Y reflected)"
        scene.rootNode.addChildNode(world)
        for (key, group) in groups {
            let data = group.vertices
            func source(_ semantic: SCNGeometrySource.Semantic, _ offset: Int, _ components: Int) -> SCNGeometrySource {
                SCNGeometrySource(data: data, semantic: semantic, vectorCount: group.count, usesFloatComponents: true,
                                  componentsPerVector: components, bytesPerComponent: 4, dataOffset: offset, dataStride: 44)
            }
            let indices = (0..<group.count).map { UInt32($0).littleEndian }
            let indexData = indices.withUnsafeBytes { Data($0) }
            let element = SCNGeometryElement(data: indexData, primitiveType: .triangles, primitiveCount: group.count / 3, bytesPerIndex: 4)
            let geometry = SCNGeometry(sources: [source(.vertex, 0, 3), source(.normal, 12, 3), source(.color, 24, 3), source(.texcoord, 36, 2)], elements: [element])
            let material = SCNMaterial(); material.lightingModel = .constant
            material.isDoubleSided = false
            if let image = images[key] { material.diffuse.contents = image.image }
            else { material.diffuse.contents = NSColor.white }
            material.diffuse.wrapS = .repeat; material.diffuse.wrapT = .repeat
            material.diffuse.minificationFilter = .linear; material.diffuse.magnificationFilter = .nearest
            material.diffuse.mipFilter = .linear
            material.transparencyMode = .aOne
            // This source flag remains explicit; PS1 blend modes and ordering
            // tables require engine reconstruction before fidelity qualification.
            if key.flatTranslucent { material.transparency = 0.5; material.writesToDepthBuffer = false }
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.name = "source layer \(key.layer), texture index \(key.textureIndex.map(String.init) ?? "untextured")"
            world.addChildNode(node)
        }
        if corners == 0 { lo = .zero; hi = .zero }
        return Result(scene: scene, triangleCount: triangles, drawGroups: groups.count, minimum: lo, maximum: hi, unresolvedTextureIDs: missing)
    }

    private static func image(_ level: THPS2OriginalLevel, layerIndex: Int, textureIndex: Int, choice: TextureChoice) throws -> Image? {
        let source = level.layers[layerIndex].content, id = source.textureNames[textureIndex]
        // Preserve library-index identity where possible: repeated checksums
        // are valid indexed names and must not silently collapse source images.
        var native: (THPS2PSX, Int)?
        let candidates = [level.layers[layerIndex]] + level.layers.filter { $0.role == "texture-library" }
        for layer in candidates {
            let matches = layer.content.textures.indices.filter {
                layer.content.textureNames[layer.content.textures[$0].nameIndex] == id
            }
            if matches.isEmpty { continue }
            if layer.content.textureNames == source.textureNames,
               let exact = matches.first(where: { layer.content.textures[$0].nameIndex == textureIndex }) {
                native = (layer.content, exact)
            } else {
                if matches.count > 1 {
                    let first = layer.content.textures[matches[0]]
                    let rgba = layer.content.rgba(texture: matches[0])
                    // Actual libraries contain indexed aliases. Collapse only
                    // byte-identical decoded images. Raw texture flags stay
                    // in the loader and remain semantically unqualified. Conflicting same-ID
                    // textures still require source engine disambiguation.
                    guard matches.dropFirst().allSatisfy({
                        let other = layer.content.textures[$0]
                        return other.width == first.width && other.height == first.height
                            && layer.content.rgba(texture: $0) == rgba
                    }) else { throw THPS2PSX.LoadError.unsupported }
                }
                native = (layer.content, matches[0])
            }
            break
        }
        guard let native else { return nil }
        let originalTexture = native.0.textures[native.1]
        if choice == .suppliedPCBMP,
           let reference = level.receipt.textures[String(format: "%08X", id)]?.first(where: { $0.kind == "pc-bmp" }) {
            let url = try THPS2OriginalLevel.child(root: level.preparedRoot, path: reference.path)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attrs[.size] as? NSNumber, size.uint64Value <= 16 * 1024 * 1024 else { throw THPS2PSX.LoadError.resourceLimit }
            let data = try Data(contentsOf: url)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == reference.sha256,
                  let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == reference.width,
                  (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == reference.height,
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { throw THPS2PSX.LoadError.identity }
            return Image(image: image, width: reference.width, height: reference.height,
                         logicalWidth: originalTexture.width, logicalHeight: originalTexture.height)
        }
        guard let data = native.0.rgba(texture: native.1), let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: originalTexture.width, height: originalTexture.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: originalTexture.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw THPS2PSX.LoadError.malformed }
        return Image(image: image, width: originalTexture.width, height: originalTexture.height,
                     logicalWidth: originalTexture.width, logicalHeight: originalTexture.height)
    }
}
