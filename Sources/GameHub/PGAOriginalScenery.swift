import AppKit
import Metal
import MetalKit
import SceneKit
import simd

/// Values the original reads from the active renderN.ini, as plain parameters
/// with neutral defaults. Render presets supply them; this module never parses
/// render INIs itself.
struct PGAOriginalSceneryStyle: Equatable {
    /// [SKY] SKYTYPE, 1–8; the dome is pan block SKYTYPE − 1. 1 is the clear sky.
    var skyType = 1
    /// [GlobalLightingValues] SkydomeDiffuse, a linear RGB multiplier.
    var skydomeDiffuse = SIMD3<Float>(1, 1, 1)
    /// Tree colour multiplier (composite-course tree colour, weather tint).
    var treeTint = SIMD3<Float>(1, 1, 1)
    /// [TreeContrast] MidValue, Scale and Shift. The original formula is not
    /// recovered; this applies ((light − mid) · scale + mid) · shift, which is
    /// neutral for the shipped values (1, 1, 1).
    var treeContrastMid: Float = 1
    var treeContrastScale: Float = 1
    var treeContrastShift: Float = 1
    /// [TreeAmbient] value in the original's byte units. The original adds it
    /// to each baked lighting byte before doubling, so it adds 2 · value / 255.
    var treeAmbient: Float = 0
    /// [GlobalLightingValues] Diffuse: multiplied into terrain (and trees via `treeTint`).
    var diffuse = SIMD3<Float>(1, 1, 1)
    /// [TerrainContrast] (MidValue, Scale, Shift), applied to the baked terrain
    /// vertex lighting when Scale ≠ 1 (see PGARenderState.terrainLight).
    var terrainContrast = SIMD3<Float>(1, 1, 1)

    static let standard = PGAOriginalSceneryStyle()

    /// The scenery values of one blended render preset. Tree contrast and
    /// TreeAmbient act on baked tree lighting the native trees do not carry
    /// yet, so trees take only the global diffuse tint.
    init(state: PGARenderState) {
        skyType = state.skyType
        skydomeDiffuse = state.skydomeDiffuse
        treeTint = state.diffuse
        diffuse = state.diffuse
        terrainContrast = state.terrainContrast
    }
    init() {}

    var neutralTerrain: Bool { diffuse == SIMD3(1, 1, 1) && abs(terrainContrast.y - 1) <= 1e-4 }
}

/// Per-frame values shared by every original scenery shader. Layout matches
/// `Frame` in `PGAOriginalSceneryGPU.source`.
struct PGAOriginalSceneryFrame {
    var viewProjection = matrix_identity_float4x4
    var camera = SIMD4<Float>.zero
    var right = SIMD4<Float>(1, 0, 0, 0)
    var up = SIMD4<Float>(0, 1, 0, 0)
    var sun = SIMD4<Float>(0, 1, 0, 0)
    var sunColor = SIMD4<Float>.zero
    var ambient = SIMD4<Float>(1, 1, 1, 0)
    var fogColor = SIMD4<Float>.zero
    var fog = SIMD4<Float>(0, 0, 1, 0)
    var tint = SIMD4<Float>(1, 1, 1, 0)
    var contrast = SIMD4<Float>(1, 1, 1, 150.0 / 255.0)
    /// Clip planes (x, y sides) in node space for CPU culling; not uploaded.
    var planes: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
    var reverseZ = true
}

/// One runtime-compiled Metal library and the pipeline states original scenery
/// needs inside SceneKit's own render pass (SCNNodeRendererDelegate). The
/// pass formats are read from the live render pass, so the game view
/// (sRGB, 4× MSAA) and offscreen snapshots both work.
final class PGAOriginalSceneryGPU: @unchecked Sendable {
    struct States {
        var barkOpaque: MTLRenderPipelineState
        var barkCutout: MTLRenderPipelineState
        var leaves: MTLRenderPipelineState
        var billboards: MTLRenderPipelineState
        var panorama: MTLRenderPipelineState
        var sky: MTLRenderPipelineState
        var skyBlend: MTLRenderPipelineState
    }
    private struct Key: Hashable { var colors: [UInt]; var depth: UInt; var stencil: UInt; var samples: Int }

    static let shared: PGAOriginalSceneryGPU? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        do { return try PGAOriginalSceneryGPU(device: device) } catch {
            NSLog("Original scenery shaders failed to compile: %@", String(describing: error)); return nil
        }
    }()

    let device: MTLDevice
    let library: MTLLibrary
    let repeatSampler: MTLSamplerState
    let clampSampler: MTLSamplerState
    let depthReverse: MTLDepthStencilState
    let depthForward: MTLDepthStencilState
    let depthNone: MTLDepthStencilState
    /// Index pattern for up to `quadCapacity` quads (0 1 2, 2 1 3, + 4 per quad).
    let quadIndices: MTLBuffer
    static let quadCapacity = 4096
    private let lock = NSLock()
    private var states: [Key: States] = [:]

    init(device: MTLDevice) throws {
        self.device = device
        library = try device.makeLibrary(source: Self.source, options: nil)
        func sampler(_ address: MTLSamplerAddressMode) -> MTLSamplerState? {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = .linear; descriptor.magFilter = .linear; descriptor.mipFilter = .linear
            descriptor.sAddressMode = address; descriptor.tAddressMode = address
            descriptor.maxAnisotropy = 4
            return device.makeSamplerState(descriptor: descriptor)
        }
        func depth(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState? {
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.depthCompareFunction = compare; descriptor.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: descriptor)
        }
        var pattern: [UInt16] = []
        pattern.reserveCapacity(Self.quadCapacity * 6)
        for quad in 0..<Self.quadCapacity {
            let base = UInt16(quad * 4)
            pattern.append(contentsOf: [base, base + 1, base + 2, base + 2, base + 1, base + 3])
        }
        guard let repeatSampler = sampler(.repeat), let clampSampler = sampler(.clampToEdge),
              let depthReverse = depth(.greaterEqual, write: true), let depthForward = depth(.lessEqual, write: true),
              let depthNone = depth(.always, write: false),
              let quads = device.makeBuffer(bytes: pattern, length: pattern.count * 2, options: .storageModeShared) else {
            throw PGAOriginalCourseData.LoadError.invalid("Metal state creation failed.")
        }
        self.repeatSampler = repeatSampler; self.clampSampler = clampSampler
        self.depthReverse = depthReverse; self.depthForward = depthForward; self.depthNone = depthNone
        quadIndices = quads
    }

    /// Pipelines matching the live pass, compiled once per attachment layout.
    func states(for pass: MTLRenderPassDescriptor) -> States? {
        var colors: [UInt] = []
        for index in 0..<8 {
            guard let texture = pass.colorAttachments[index].texture else { break }
            colors.append(texture.pixelFormat.rawValue)
        }
        guard let first = pass.colorAttachments[0].texture, !colors.isEmpty else { return nil }
        let key = Key(colors: colors, depth: pass.depthAttachment.texture?.pixelFormat.rawValue ?? 0,
                      stencil: pass.stencilAttachment.texture?.pixelFormat.rawValue ?? 0, samples: first.sampleCount)
        lock.lock(); defer { lock.unlock() }
        if let cached = states[key] { return cached }
        func make(_ vertex: String, _ fragment: String, coverage: Bool = false, blend: Bool = false) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            for (index, raw) in key.colors.enumerated() {
                descriptor.colorAttachments[index].pixelFormat = MTLPixelFormat(rawValue: raw) ?? .invalid
                if index > 0 { descriptor.colorAttachments[index].writeMask = [] }
            }
            if blend {
                let color = descriptor.colorAttachments[0]!
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .sourceAlpha; color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .zero; color.destinationAlphaBlendFactor = .one
            }
            descriptor.depthAttachmentPixelFormat = MTLPixelFormat(rawValue: key.depth) ?? .invalid
            descriptor.stencilAttachmentPixelFormat = MTLPixelFormat(rawValue: key.stencil) ?? .invalid
            descriptor.rasterSampleCount = key.samples
            // Alpha to coverage softens the original's alpha-tested edges
            // under MSAA at no extra cost; the threshold stays ALPHAREF 150.
            descriptor.isAlphaToCoverageEnabled = coverage && key.samples > 1
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        do {
            let cutout = key.samples > 1 ? "coverageFragment" : "cutoutFragment"
            let built = States(barkOpaque: try make("barkVertex", "opaqueFragment"),
                               barkCutout: try make("barkVertex", cutout, coverage: true),
                               leaves: try make("leafVertex", cutout, coverage: true),
                               billboards: try make("billboardVertex", cutout, coverage: true),
                               panorama: try make("panoramaVertex", cutout, coverage: true),
                               sky: try make("skyVertex", "skyFragment"),
                               skyBlend: try make("skyVertex", "skyFragment", blend: true))
            states[key] = built
            return built
        } catch {
            NSLog("Original scenery pipeline failed: %@", String(describing: error))
            return nil
        }
    }

    /// Camera, lights and fog for the pass SceneKit is drawing. Node-space
    /// values: the scenery nodes sit at the identity under the hole node.
    static func frame(renderer: SCNRenderer, arguments: [String: Any], lights: inout PGAOriginalSceneryLights?) -> PGAOriginalSceneryFrame? {
        guard let model = (arguments[SCNModelTransform] as? NSValue)?.scnMatrix4Value,
              let view = (arguments[SCNViewTransform] as? NSValue)?.scnMatrix4Value,
              let projection = (arguments[SCNProjectionTransform] as? NSValue)?.scnMatrix4Value else { return nil }
        let modelView = simd_float4x4(view) * simd_float4x4(model)
        let viewProjection = simd_float4x4(projection) * modelView
        let inverse = modelView.inverse
        var frame = PGAOriginalSceneryFrame()
        frame.viewProjection = viewProjection
        frame.camera = SIMD4(inverse.columns.3.x, inverse.columns.3.y, inverse.columns.3.z, 0)
        frame.right = SIMD4(simd_normalize(SIMD3(inverse.columns.0.x, inverse.columns.0.y, inverse.columns.0.z)), 0)
        frame.up = SIMD4(simd_normalize(SIMD3(inverse.columns.1.x, inverse.columns.1.y, inverse.columns.1.z)), 0)
        let m = viewProjection.transpose   // rows as columns
        frame.planes = (m.columns.3 + m.columns.0, m.columns.3 - m.columns.0, m.columns.3 + m.columns.1, m.columns.3 - m.columns.1)
        frame.reverseZ = renderer.usesReverseZ
        if lights == nil, let scene = renderer.scene { lights = PGAOriginalSceneryLights(scene: scene) }
        if let lights {
            frame.sun = SIMD4(lights.sunDirection, 0)
            frame.sunColor = SIMD4(lights.sunColor, 0)
            frame.ambient = SIMD4(lights.ambient, 0)
        }
        if let scene = renderer.scene, scene.fogEndDistance > scene.fogStartDistance {
            let start = Float(scene.fogStartDistance), end = Float(scene.fogEndDistance)
            frame.fogColor = SIMD4(PGAOriginalSceneryLights.linear(scene.fogColor), 1)
            frame.fog = SIMD4(1 / (end - start), -start / (end - start), Float(max(0.01, scene.fogDensityExponent)), 0)
        }
        return frame
    }

    /// Runtime Metal source; the build compiles Swift only, so shaders are
    /// compiled once per process on first use (about 0.1 s).
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Frame {
        float4x4 viewProjection;
        float4 camera;
        float4 right;
        float4 up;
        float4 sun;
        float4 sunColor;
        float4 ambient;
        float4 fogColor;
        float4 fog;
        float4 tint;
        float4 contrast;
    };
    struct Instance {
        packed_float3 position;
        float scale;
        float cosA;
        float sinA;
        float halfWidth;
        float height;
    };
    struct MeshVertex {
        packed_float3 position;
        packed_float3 normal;
        packed_float2 uv;
        uchar4 color;
    };
    struct Leaf {
        packed_float3 center;
        float size;
        packed_float2 uvMin;
        packed_float2 uvMax;
        uint material;
    };
    struct Draw {
        float4 crown;
        float height;
        uint firstLeaf;
        float2 extra;
    };
    struct Varyings {
        float4 position [[position]];
        float2 uv;
        half4 light;
    };

    static float3 place(device const Instance &i, float3 v) {
        return float3(i.position) + i.scale * float3(v.x * i.cosA + v.z * i.sinA, v.y, v.x * i.sinA - v.z * i.cosA);
    }
    static float3 turn(device const Instance &i, float3 n) {
        return float3(n.x * i.cosA + n.z * i.sinA, n.y, n.x * i.sinA - n.z * i.cosA);
    }
    static half fogAt(constant Frame &f, float3 p) {
        if (f.fogColor.w == 0.0) { return 0.0h; }
        return half(pow(saturate(length(p - f.camera.xyz) * f.fog.x + f.fog.y), f.fog.z));
    }
    static half4 shade(constant Frame &f, float3 normal, float wrap, float occlusion, float3 p) {
        float3 n = normalize(normal);
        float d = saturate((dot(n, f.sun.xyz) + wrap) / (1.0 + wrap));
        float3 light = (f.ambient.rgb + f.sunColor.rgb * d) * occlusion + f.tint.w;
        light = ((light - f.contrast.x) * f.contrast.y + f.contrast.x) * f.contrast.z;
        return half4(half3(max(light, 0.0) * f.tint.rgb), fogAt(f, p));
    }

    vertex Varyings barkVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                               device const MeshVertex *vertices [[buffer(0)]],
                               device const Instance *instances [[buffer(1)]],
                               device const uint *ids [[buffer(2)]],
                               constant Frame &f [[buffer(3)]],
                               constant Draw &d [[buffer(4)]]) {
        device const MeshVertex &v = vertices[vid];
        device const Instance &i = instances[ids[iid]];
        float3 local = float3(v.position);
        float3 p = place(i, local);
        // Gentle occlusion toward the trunk base.
        float base = mix(0.6, 1.0, saturate(local.y / max(d.height * 0.25, 1e-3)));
        Varyings o;
        o.position = f.viewProjection * float4(p, 1.0);
        o.uv = float2(v.uv);
        o.light = shade(f, turn(i, float3(v.normal)), 0.0, base, p);
        o.light.rgb *= half3(v.color.rgb) / 255.0h;
        return o;
    }

    constant float leafTwist[5] = { -0.47, -0.21, 0.04, 0.26, 0.49 };

    vertex Varyings leafVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                               device const Leaf *leaves [[buffer(0)]],
                               device const Instance *instances [[buffer(1)]],
                               device const uint *ids [[buffer(2)]],
                               constant Frame &f [[buffer(3)]],
                               constant Draw &d [[buffer(4)]]) {
        uint index = d.firstLeaf + vid / 4u;
        uint corner = vid & 3u;
        device const Leaf &leaf = leaves[index];
        device const Instance &i = instances[ids[iid]];
        // Camera-facing square (CRVegetation::RotateLeaves) with one of five
        // in-plane twists, as the original assigns per leaf.
        float2 c = float2((corner & 1u) ? 1.0 : -1.0, (corner & 2u) ? -1.0 : 1.0);
        float t = leafTwist[index % 5u];
        float ct = cos(t), st = sin(t);
        float2 r = float2(c.x * ct - c.y * st, c.x * st + c.y * ct);
        float3 center = float3(leaf.center);
        float3 p = place(i, center) + (f.right.xyz * r.x + f.up.xyz * r.y) * (leaf.size * i.scale);
        // Crown-relative normal and occlusion: inner and lower leaves darker.
        float3 fromCrown = center - d.crown.xyz;
        float reach = length(fromCrown);
        float occlusion = mix(0.62, 1.0, saturate(reach / max(d.crown.w, 1e-3)))
                        * mix(0.82, 1.0, saturate(center.y / max(d.height, 1e-3)));
        Varyings o;
        o.position = f.viewProjection * float4(p, 1.0);
        o.uv = float2(c.x < 0.0 ? leaf.uvMin[0] : leaf.uvMax[0], c.y > 0.0 ? leaf.uvMin[1] : leaf.uvMax[1]);
        o.light = shade(f, turn(i, reach > 1e-4 ? fromCrown : float3(0.0, 1.0, 0.0)), 0.5, occlusion, p);
        return o;
    }

    vertex Varyings billboardVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                    device const Instance *instances [[buffer(1)]],
                                    device const uint *ids [[buffer(2)]],
                                    constant Frame &f [[buffer(3)]]) {
        device const Instance &i = instances[ids[iid]];
        // LOD3: one quad on the instance, turned about Y toward the camera
        // (CreateLowLODBuffers / TransformLowLODs), UV (0,0) at the top left.
        float2 c = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 0.0 : 1.0);
        float3 base = float3(i.position);
        float2 toCamera = f.camera.xz - base.xz;
        float distance = length(toCamera);
        float2 facing = distance > 1e-4 ? toCamera / distance : float2(0.0, 1.0);
        float3 p = base + float3(facing.y, 0.0, -facing.x) * (c.x * i.halfWidth) + float3(0.0, c.y * i.height, 0.0);
        Varyings o;
        o.position = f.viewProjection * float4(p, 1.0);
        o.uv = float2(c.x * 0.5 + 0.5, 1.0 - c.y);
        o.light = shade(f, float3(facing.x * 0.6, 1.0, facing.y * 0.6), 0.5, mix(0.8, 1.0, c.y), p);
        return o;
    }

    vertex Varyings panoramaVertex(uint vid [[vertex_id]],
                                   device const MeshVertex *vertices [[buffer(0)]],
                                   constant Frame &f [[buffer(3)]]) {
        device const MeshVertex &v = vertices[vid];
        float3 p = float3(v.position);
        Varyings o;
        o.position = f.viewProjection * float4(p, 1.0);
        o.uv = float2(v.uv);
        o.light = half4(half3(v.color.rgb) / 255.0h, fogAt(f, p));
        return o;
    }

    fragment half4 opaqueFragment(Varyings in [[stage_in]], texture2d<half> tex [[texture(0)]],
                                  sampler s [[sampler(0)]], constant Frame &f [[buffer(0)]]) {
        half3 rgb = tex.sample(s, in.uv).rgb * in.light.rgb;
        return half4(mix(rgb, half3(f.fogColor.rgb), in.light.a), 1.0h);
    }
    fragment half4 cutoutFragment(Varyings in [[stage_in]], texture2d<half> tex [[texture(0)]],
                                  sampler s [[sampler(0)]], constant Frame &f [[buffer(0)]]) {
        half4 c = tex.sample(s, in.uv);
        if (float(c.a) < f.contrast.w) { discard_fragment(); }
        half3 rgb = c.rgb * in.light.rgb;
        return half4(mix(rgb, half3(f.fogColor.rgb), in.light.a), 1.0h);
    }
    // ALPHAREF 150 as the 50% coverage point, sharpened by the alpha's screen
    // derivative, so cut-out edges are antialiased by 4x MSAA.
    fragment half4 coverageFragment(Varyings in [[stage_in]], texture2d<half> tex [[texture(0)]],
                                    sampler s [[sampler(0)]], constant Frame &f [[buffer(0)]]) {
        half4 c = tex.sample(s, in.uv);
        float a = float(c.a);
        float coverage = saturate((a - f.contrast.w) / max(fwidth(a), 1.0 / 255.0) + 0.5);
        if (coverage <= 0.0) { discard_fragment(); }
        half3 rgb = c.rgb * in.light.rgb;
        return half4(mix(rgb, half3(f.fogColor.rgb), in.light.a), half(coverage));
    }

    struct SkyDraw { float4 tint; float4 params; };
    struct SkyVaryings {
        float4 position [[position]];
        float2 uv;
        half4 color;
    };
    vertex SkyVaryings skyVertex(uint vid [[vertex_id]],
                                 device const MeshVertex *vertices [[buffer(0)]],
                                 constant Frame &f [[buffer(3)]],
                                 constant SkyDraw &d [[buffer(4)]]) {
        device const MeshVertex &v = vertices[vid];
        // Positions are meters around the dome centre, at height YOffset over
        // the course's lowest point. The dome follows the camera horizontally
        // and is shrunk toward the eye (same image) to stay inside the depth
        // range and fog start.
        float3 relative = float3(v.position) - float3(0.0, f.camera.y, 0.0);
        float3 p = f.camera.xyz + relative * d.params.x;
        SkyVaryings o;
        o.position = f.viewProjection * float4(p, 1.0);
        o.uv = float2(v.uv);
        o.color = half4(half3(d.tint.rgb) * half3(v.color.rgb) / 255.0h, half(v.color.a) / 255.0h);
        return o;
    }
    fragment half4 skyFragment(SkyVaryings in [[stage_in]], texture2d<half> tex [[texture(0)]],
                               sampler s [[sampler(0)]]) {
        half4 c = tex.sample(s, in.uv);
        return half4(c.rgb * in.color.rgb, c.a * in.color.a);
    }
    """
}

/// The scene's directional and ambient lights in linear RGB (SceneKit's
/// intensity 1000 = 1.0), read once per drawer.
struct PGAOriginalSceneryLights {
    var sunDirection = SIMD3<Float>(0, 1, 0)
    var sunColor = SIMD3<Float>(0, 0, 0)
    var ambient = SIMD3<Float>(0.5, 0.5, 0.5)

    init(scene: SCNScene) {
        var ambientTotal = SIMD3<Float>(0, 0, 0)
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let light = node.light else { return }
            let color = Self.linear(light.color) * Float(light.intensity / 1000)
            if light.type == .directional, sunColor == .zero {
                let front = node.presentation.simdWorldFront
                sunDirection = simd_normalize(-front); sunColor = color
            } else if light.type == .ambient {
                ambientTotal += color
            }
        }
        ambient = ambientTotal
    }

    static func linear(_ value: Any?) -> SIMD3<Float> {
        let color: NSColor?
        if let value = value as? NSColor { color = value }
        else if let value, CFGetTypeID(value as CFTypeRef) == CGColor.typeID { color = NSColor(cgColor: value as! CGColor) }
        else { color = nil }
        guard let rgb = color?.usingColorSpace(.sRGB) else { return SIMD3(1, 1, 1) }
        func decode(_ component: CGFloat) -> Float {
            let x = Float(component)
            return x <= 0.04045 ? x / 12.92 : powf((x + 0.055) / 1.055, 2.4)
        }
        return SIMD3(decode(rgb.redComponent), decode(rgb.greenComponent), decode(rgb.blueComponent))
    }
}

/// Original DirectX textures loaded as their own block-compressed formats
/// (BC1/BC2/BC3 with the authored mip chains), about a quarter to an eighth of
/// the RGBA8 size. PNGs are used only when a DDS is missing or unsupported.
enum PGAOriginalTextureFile {
    static func texture(png: URL, device: MTLDevice) -> MTLTexture? {
        let dds = png.deletingPathExtension().appendingPathExtension("dds")
        if let data = try? Data(contentsOf: dds), let texture = Self.dds(data, device: device) { return texture }
        let loader = MTKTextureLoader(device: device)
        return try? loader.newTexture(URL: png, options: [.SRGB: true, .generateMipmaps: true,
                                                          .textureStorageMode: MTLStorageMode.private.rawValue])
    }

    static func dds(_ data: Data, device: MTLDevice) -> MTLTexture? {
        guard data.count >= 128 else { return nil }
        return data.withUnsafeBytes { raw -> MTLTexture? in
            func u32(_ offset: Int) -> UInt32 { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            guard u32(0) == 0x2053_4444, u32(4) == 124 else { return nil }
            let height = Int(u32(12)), width = Int(u32(16))
            let levels = max(1, (u32(8) & 0x20000) != 0 ? Int(u32(28)) : 1)
            let pixelFlags = u32(80), fourCC = u32(84), bits = u32(88)
            let format: MTLPixelFormat, blockBytes: Int, compressed: Bool
            switch fourCC {
            case 0x3154_5844: format = .bc1_rgba_srgb; blockBytes = 8; compressed = true    // DXT1
            case 0x3354_5844: format = .bc2_rgba_srgb; blockBytes = 16; compressed = true   // DXT3
            case 0x3554_5844: format = .bc3_rgba_srgb; blockBytes = 16; compressed = true   // DXT5
            default:
                guard pixelFlags & 0x40 != 0, bits == 32, u32(92) == 0xff0000, u32(96) == 0xff00, u32(100) == 0xff else { return nil }
                format = .bgra8Unorm_srgb; blockBytes = 4; compressed = false
            }
            if compressed && !device.supportsBCTextureCompression { return nil }
            guard (1...8192).contains(width), (1...8192).contains(height), levels <= 16 else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: levels > 1)
            descriptor.mipmapLevelCount = levels
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            var offset = 128
            for level in 0..<levels {
                let w = max(1, width >> level), h = max(1, height >> level)
                let rowBytes = compressed ? max(1, (w + 3) / 4) * blockBytes : w * 4
                let rows = compressed ? max(1, (h + 3) / 4) : h
                guard offset + rowBytes * rows <= data.count, let base = raw.baseAddress else { return nil }
                texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: level,
                                withBytes: base.advanced(by: offset), bytesPerRow: rowBytes)
                offset += rowBytes * rows
            }
            return texture
        }
    }
}

/// GHOM v1 meshes written by Tools/decode_pga2005_objects.py: 36-byte
/// vertices (position, normal, uv, rgba), u32 triangles, material ranges and
/// 36-byte leaf cards. The vertex and leaf records are uploaded verbatim.
struct PGAOriginalGHOM {
    struct Range { var material: Int; var first: Int; var count: Int }
    static let vertexStride = 36
    static let leafStride = 36
    var vertexCount: Int
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>
    var vertices: Data
    var indices: [UInt32]
    var ranges: [Range]
    /// Leaf records grouped by material, with each group's leaf range.
    var leaves: Data
    var leafRanges: [Range]
    var leafCenters: [SIMD3<Float>]

    init(data: Data) throws {
        func fail(_ message: String) -> Error { PGAOriginalCourseData.LoadError.invalid("GHOM: \(message)") }
        guard data.count >= 64 else { throw fail("truncated header") }
        let header = data.withUnsafeBytes { raw -> [UInt32] in (0..<16).map { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) } }
        guard header[0] == 0x4d4f_4847, header[1] == 1, header[6] == 36 else { throw fail("not a GHOM v1 file") }
        let nv = Int(header[2]), ni = Int(header[3]), nr = Int(header[4]), nl = Int(header[5])
        guard nv <= 1_000_000, ni <= 3_000_000, nr <= 4096, nl <= 1_000_000, ni % 3 == 0,
              data.count == 64 + nv * 36 + ni * 4 + nr * 12 + nl * 36 else { throw fail("size does not match counts") }
        vertexCount = nv
        boundsMin = SIMD3(Float(bitPattern: header[8]), Float(bitPattern: header[9]), Float(bitPattern: header[10]))
        boundsMax = SIMD3(Float(bitPattern: header[11]), Float(bitPattern: header[12]), Float(bitPattern: header[13]))
        let vertexStart = data.startIndex + 64
        vertices = data.subdata(in: vertexStart..<(vertexStart + nv * 36))
        var offset = 64 + nv * 36
        var indices = [UInt32](repeating: 0, count: ni)
        var ranges: [Range] = []
        var leafRecords: [(material: Int, bytes: Data, center: SIMD3<Float>)] = []
        try data.withUnsafeBytes { raw in
            for k in 0..<ni {
                let index = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + k * 4, as: UInt32.self))
                guard Int(index) < nv else { throw fail("index out of range") }
                indices[k] = index
            }
            offset += ni * 4
            for k in 0..<nr {
                func u(_ field: Int) -> Int { Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + k * 12 + field * 4, as: UInt32.self))) }
                let range = Range(material: u(0), first: u(1), count: u(2))
                guard range.first + range.count <= ni, range.count % 3 == 0 else { throw fail("range out of bounds") }
                ranges.append(range)
            }
            offset += nr * 12
            for k in 0..<nl {
                let start = offset + k * 36
                func f(_ field: Int) -> Float { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: start + field * 4, as: UInt32.self))) }
                let material = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: start + 32, as: UInt32.self)))
                leafRecords.append((material, data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + 36)), SIMD3(f(0), f(1), f(2))))
            }
        }
        self.indices = indices; self.ranges = ranges
        var leaves = Data(capacity: nl * 36), leafRanges: [Range] = [], centers: [SIMD3<Float>] = []
        for material in Set(leafRecords.map(\.material)).sorted() {
            let group = leafRecords.filter { $0.material == material }
            leafRanges.append(Range(material: material, first: centers.count, count: group.count))
            for record in group { leaves.append(record.bytes); centers.append(record.center) }
        }
        self.leaves = leaves; self.leafRanges = leafRanges; leafCenters = centers
    }
}
