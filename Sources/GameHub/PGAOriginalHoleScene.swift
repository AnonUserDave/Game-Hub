import AppKit
import SceneKit

/// One hole's original triangles as compact render buffers in simulation
/// meters. Built on a worker; only this hole's vertices reach the GPU, while
/// the mapped course file stays shared across holes.
struct PGAOriginalHoleMesh {
    struct Batch { var material: UInt32; var indices: Data; var triangles: Int }
    var holeIndex: Int
    var vertexCount: Int
    var positions: Data
    var normals: Data
    var uvs: Data
    var colors: Data
    var batches: [Batch]
    var map: PGAHoleMap

    /// `hole` is the round's hole (its tee and pin set the minimap framing);
    /// it defaults to the course's default tee/pin hole.
    static func build(course: PGAOriginalPlayableCourse, holeIndex: Int, hole: PGAHole? = nil) -> PGAOriginalHoleMesh {
        let data = course.data, transform = course.transform
        let selection = course.selections[holeIndex]
        var remap = [Int32](repeating: -1, count: data.vertexCount)
        var positions: [Float] = [], uvs: [Float] = [], colors: [Float] = []
        var grouped: [UInt32: [UInt32]] = [:]
        var faces: [(UInt32, UInt32, UInt32)] = []
        faces.reserveCapacity(selection.count)
        // Blend strips (texture-section flag 0x80: fringe, sand and tee
        // edges) are overlays lying exactly on base terrain. Lift them 1.2 cm
        // in the render buffers only, so they never z-fight the base; floor
        // queries still use the exact source triangles.
        let overlays = Set(data.materials.values.filter(\.properties.isBlend).map(\.id))
        data.terrain.withUnsafeBytes { bytes in
            func u32(_ offset: Int) -> UInt32 { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            func f32(_ offset: Int) -> Double { Double(Float(bitPattern: u32(offset))) }
            func local(_ vertex: UInt32, lift: Double) -> UInt32 {
                if remap[Int(vertex)] >= 0 { return UInt32(remap[Int(vertex)]) }
                let offset = data.vertexOffset + Int(vertex) * 24
                var p = transform.meters(raw: PGAVector(x: f32(offset), y: f32(offset + 4), z: f32(offset + 8)))
                p.y += lift
                positions.append(contentsOf: [Float(p.x), Float(p.y), Float(p.z)])
                for component in 0..<4 { colors.append(Float(bytes[offset + 12 + component]) / 255) }
                uvs.append(contentsOf: [Float(f32(offset + 16)), Float(f32(offset + 20))])
                let index = Int32(positions.count / 3 - 1)
                remap[Int(vertex)] = index
                return UInt32(index)
            }
            for triangle in selection {
                let offset = data.triangleOffset + Int(triangle) * 16
                let lift = overlays.contains(u32(offset + 12)) ? 0.012 : 0
                let a = local(u32(offset), lift: lift), b = local(u32(offset + 4), lift: lift), c = local(u32(offset + 8), lift: lift)
                // The Z mirror reverses handedness, so emit (a, c, b) to keep
                // the original front faces counter-clockwise for SceneKit.
                grouped[u32(offset + 12), default: []].append(contentsOf: [a, c, b])
                faces.append((a, b, c))
            }
        }
        let count = positions.count / 3
        // Shading normals oriented upward; source winding is not relied upon
        // because the left-to-right-handed mirror reverses it.
        var normals = [Float](repeating: 0, count: count * 3)
        for (a, b, c) in faces {
            let i = Int(a) * 3, j = Int(b) * 3, k = Int(c) * 3
            let ux = positions[j] - positions[i], uy = positions[j + 1] - positions[i + 1], uz = positions[j + 2] - positions[i + 2]
            let vx = positions[k] - positions[i], vy = positions[k + 1] - positions[i + 1], vz = positions[k + 2] - positions[i + 2]
            var nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx
            if ny < 0 { nx = -nx; ny = -ny; nz = -nz }
            for v in [i, j, k] { normals[v] += nx; normals[v + 1] += ny; normals[v + 2] += nz }
        }
        for v in stride(from: 0, to: normals.count, by: 3) {
            let length = (normals[v] * normals[v] + normals[v + 1] * normals[v + 1] + normals[v + 2] * normals[v + 2]).squareRoot()
            if length > 1e-6 { normals[v] /= length; normals[v + 1] /= length; normals[v + 2] /= length } else { normals[v + 1] = 1 }
        }
        func pack<T>(_ values: [T]) -> Data { values.withUnsafeBufferPointer { Data(buffer: $0) } }
        let batches = grouped.keys.sorted().map { key in Batch(material: key, indices: pack(grouped[key]!), triangles: grouped[key]!.count / 3) }
        let classes = data.materials.mapValues(\.properties.surface)
        var mapTriangles: [(UInt32, UInt32, UInt32)] = [], mapSurfaces: [PGASurface] = []
        for (key, indices) in grouped {
            let surface = classes[key] ?? .unplayable
            for start in stride(from: 0, to: indices.count, by: 3) {
                mapTriangles.append((indices[start], indices[start + 1], indices[start + 2])); mapSurfaces.append(surface)
            }
        }
        let map = PGAHoleMap.render(hole: hole ?? course.course.holes[holeIndex], positions: positions, triangles: mapTriangles, surfaces: mapSurfaces)
        return PGAOriginalHoleMesh(holeIndex: holeIndex, vertexCount: count, positions: pack(positions), normals: pack(normals),
                                   uvs: pack(uvs), colors: pack(colors), batches: batches, map: map)
    }
}

/// Original textures for one course. All 181 PBL images total about 60 MB as
/// RGBA8 with mipmaps, so they are kept for the whole session and reused by
/// every hole rather than decoded again.
final class PGAOriginalTextureCache {
    private var images: [UInt32: NSImage] = [:]
    func image(for material: PGAOriginalCourseData.Material) -> NSImage? {
        if let cached = images[material.id] { return cached }
        guard let url = material.texture, let image = NSImage(contentsOf: url) else { return nil }
        images[material.id] = image
        return image
    }
}

enum PGAOriginalSceneBuilder {
    /// SceneKit node for one hole. Ground categories render opaque: several
    /// original ground textures carry alpha whose blending role is unknown.
    @MainActor
    static func node(for mesh: PGAOriginalHoleMesh, course: PGAOriginalPlayableCourse, textures: PGAOriginalTextureCache) -> SCNNode {
        let count = mesh.vertexCount
        let sources = [
            SCNGeometrySource(data: mesh.positions, semantic: .vertex, vectorCount: count, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12),
            SCNGeometrySource(data: mesh.normals, semantic: .normal, vectorCount: count, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12),
            SCNGeometrySource(data: mesh.uvs, semantic: .texcoord, vectorCount: count, usesFloatComponents: true,
                              componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0, dataStride: 8),
            SCNGeometrySource(data: mesh.colors, semantic: .color, vectorCount: count, usesFloatComponents: true,
                              componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        ]
        let elements = mesh.batches.map { SCNGeometryElement(data: $0.indices, primitiveType: .triangles, primitiveCount: $0.triangles, bytesPerIndex: 4) }
        let geometry = SCNGeometry(sources: sources, elements: elements)
        geometry.materials = mesh.batches.map { batch in
            let material = SCNMaterial()
            let source = course.data.materials[batch.material]
            material.name = "Original material \(batch.material) · \(source?.name ?? "unmapped")"
            // Original baked grayscale vertex lighting modulates the texture;
            // a native sun/ambient term on top is a deliberate, cheap
            // modernization (the original fixed-function blend is unverified).
            material.lightingModel = .lambert
            let surface = source?.properties.surface ?? .unplayable
            // Ground is closed and consistently wound, so back faces are culled
            // (the original default cull mode is CCW); thin objects such as
            // fences and signs stay double-sided.
            material.isDoubleSided = surface == .unplayable
            if let source, let image = textures.image(for: source) {
                material.diffuse.contents = image
                material.diffuse.wrapS = .repeat; material.diffuse.wrapT = .repeat
                material.diffuse.minificationFilter = .linear; material.diffuse.magnificationFilter = .linear
                material.diffuse.mipFilter = .linear; material.diffuse.maxAnisotropy = 8
            } else {
                material.diffuse.contents = NSColor(calibratedWhite: 0.6, alpha: 1)
            }
            if source?.properties.isBlend == true {
                // Overlay strips blend over the base terrain with their alpha,
                // as the original's transparent edges imply.
                material.blendMode = .alpha
                material.transparencyMode = .aOne
                material.writesToDepthBuffer = false
            } else if surface != .unplayable {
                material.blendMode = .replace
            }
            if surface == .water {
                // Gentle moving sheen on open water: a slow texture drift plus
                // a little specular. Costs one texture transform per frame.
                material.lightingModel = .blinn
                material.specular.contents = NSColor(white: 0.55, alpha: 1)
                material.shininess = 0.35
                let drift = CABasicAnimation(keyPath: "contentsTransform")
                drift.fromValue = NSValue(scnMatrix4: SCNMatrix4Identity)
                drift.toValue = NSValue(scnMatrix4: SCNMatrix4MakeTranslation(1, 0.5, 0))
                drift.duration = 240; drift.repeatCount = .infinity
                material.diffuse.addAnimation(SCNAnimation(caAnimation: drift), forKey: "drift")
                // Modern touch, a few ALU ops per water pixel: two crossing
                // procedural ripples tilt the normal for moving sun glints, and
                // a Fresnel term mixes in sky colour at grazing angles.
                material.shaderModifiers = [.surface: Self.waterSurface]
            }
            return material
        }
        let node = SCNNode(geometry: geometry)
        node.name = "Original hole \(mesh.holeIndex + 1) terrain"
        node.castsShadow = false
        return node
    }

    static let waterSurface = """
    float t = scn_frame.time;
    float2 p = _surface.diffuseTexcoord * 6.2831853;
    float3 ripple = float3(sin(p.x * 3.1 + t * 0.9) + 0.6 * sin(p.y * 4.7 - t * 1.3), 0.0,
                           cos(p.y * 3.7 + t * 0.7) + 0.6 * cos(p.x * 5.3 + t * 1.1));
    _surface.normal = normalize(_surface.normal + ripple * 0.045);
    float facing = saturate(dot(_surface.normal, _surface.view));
    float fresnel = 0.08 + 0.55 * pow(1.0 - facing, 4.0);
    _surface.diffuse.rgb = mix(_surface.diffuse.rgb, float3(0.56, 0.66, 0.78), fresnel);
    """
}

/// A top-down minimap rendered from the hole's own triangles, rotated so the
/// tee is at the bottom, the pin at the top and the player's right on the right.
struct PGAHoleMap {
    static let size = CGSize(width: 175, height: 210)
    var image: CGImage?
    var center: PGAVector
    var angle: Double
    var scale: Double

    private var forward: PGAVector { PGAVector(x: sin(angle), y: 0, z: cos(angle)) }
    /// Right of travel in the right-handed simulation space.
    private var right: PGAVector { PGAVector(x: -cos(angle), y: 0, z: sin(angle)) }

    func point(_ v: PGAVector, in size: CGSize = PGAHoleMap.size) -> CGPoint {
        let d = v - center
        let along = d.x * forward.x + d.z * forward.z, across = d.x * right.x + d.z * right.z
        let factor = size.width / Self.size.width
        return CGPoint(x: size.width / 2 + across * scale * factor, y: size.height / 2 - along * scale * factor)
    }

    static func color(_ surface: PGASurface) -> (CGFloat, CGFloat, CGFloat) {
        switch surface {
        case .fairway: return (0.47, 0.60, 0.36)
        case .rough: return (0.24, 0.33, 0.20)
        case .green: return (0.66, 0.76, 0.49)
        case .fringe: return (0.56, 0.69, 0.41)
        case .tee: return (0.55, 0.68, 0.43)
        case .sand: return (0.84, 0.77, 0.60)
        case .water: return (0.36, 0.58, 0.66)
        case .unplayable, .out: return (0.36, 0.34, 0.31)
        }
    }

    /// Fits the authored path (tee, aim points, pin) with a 40 m margin.
    static func fitted(to hole: PGAHole) -> PGAHoleMap {
        var map = PGAHoleMap(image: nil, center: hole.tee, angle: atan2(hole.cup.x - hole.tee.x, hole.cup.z - hole.tee.z), scale: 1)
        let along = hole.centerline.map { ($0 - map.center).x * map.forward.x + ($0 - map.center).z * map.forward.z }
        let across = hole.centerline.map { ($0 - map.center).x * map.right.x + ($0 - map.center).z * map.right.z }
        let alongMid = (along.max()! + along.min()!) / 2, acrossMid = (across.max()! + across.min()!) / 2
        map.center = map.center + map.forward * alongMid + map.right * acrossMid
        map.scale = min(size.width / max(60, across.max()! - across.min()! + 80), size.height / max(60, along.max()! - along.min()! + 80))
        return map
    }

    static func render(hole: PGAHole, positions: [Float], triangles: [(UInt32, UInt32, UInt32)], surfaces: [PGASurface]) -> PGAHoleMap {
        var map = fitted(to: hole)
        let width = Int(size.width * 2), height = Int(size.height * 2)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return map }
        context.setFillColor(CGColor(red: 0.20, green: 0.27, blue: 0.18, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = CGSize(width: width, height: height)
        // Lower categories first so greens, sand and tees stay visible.
        let rank: [PGASurface: Int] = [.unplayable: 0, .out: 0, .water: 1, .rough: 2, .fairway: 3, .fringe: 4, .tee: 5, .sand: 6, .green: 7]
        let ordered = zip(triangles, surfaces).sorted { rank[$0.1, default: 0] < rank[$1.1, default: 0] }
        for ((a, b, c), surface) in ordered {
            let points = [a, b, c].map { index -> CGPoint in
                let i = Int(index) * 3
                let p = map.point(PGAVector(x: Double(positions[i]), y: 0, z: Double(positions[i + 2])), in: pixels)
                return CGPoint(x: p.x, y: CGFloat(height) - p.y)
            }
            guard points.contains(where: { $0.x >= -40 && $0.x <= CGFloat(width) + 40 && $0.y >= -40 && $0.y <= CGFloat(height) + 40 }) else { continue }
            let rgb = color(surface)
            let color = CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
            context.setFillColor(color); context.setStrokeColor(color); context.setLineWidth(0.8)
            // Stroking in the fill color closes anti-aliasing seams between triangles.
            context.beginPath(); context.addLines(between: points); context.closePath(); context.drawPath(using: .fillStroke)
        }
        map.image = context.makeImage()
        return map
    }
}
