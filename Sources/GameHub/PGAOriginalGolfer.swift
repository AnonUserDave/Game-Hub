import AppKit
import ImageIO
import SceneKit
import simd

// The original Tiger Woods golfer (01char.xbx), his clubs (GlbChar.xbx CLB)
// and swing clips (motions.tbf), as decoded by Tools/decode_pga2005_golfer.py
// into the ignored Library/Imported/pga2005/golfer. See
// docs/research/PGA2005-GOLFER.md for the formats and their evidence.
//
// Model space: +Y up, the golfer faces +Z with his left side on +X, and the
// ball sits at the rig origin on the ground with the target line along +X.
// The engine mirrors X into its left-handed world and the course transform
// mirrors Z back, so the composite is a proper rotation: the stored geometry
// is placed unmirrored, and a right-handed golfer stays right-handed.

/// Rigid bone transform: rotate, then translate (model units).
struct PGAGolferTransform: Equatable {
    var rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var translation = SIMD3<Float>(repeating: 0)

    /// `self` as a parent's world transform applied to a child's local one.
    func then(_ local: PGAGolferTransform) -> PGAGolferTransform {
        PGAGolferTransform(rotation: simd_normalize(rotation * local.rotation),
                           translation: translation + rotation.act(local.translation))
    }

    var matrix: simd_float4x4 {
        var m = simd_float4x4(rotation)
        m.columns.3 = SIMD4<Float>(translation, 1)
        return m
    }

    /// Shortest-arc slerp of the rotation and lerp of the translation.
    static func mix(_ a: Self, _ b: Self, _ t: Float) -> Self {
        let target = simd_dot(a.rotation.vector, b.rotation.vector) < 0 ? simd_quatf(vector: -b.rotation.vector) : b.rotation
        return Self(rotation: simd_slerp(a.rotation, target, t), translation: a.translation + (b.translation - a.translation) * t)
    }
}

/// Which original club model and motion set a simulation club uses. There is
/// no Tiger fairway-wood or 5/9-iron clip: woods use the driver motion, the
/// 5-iron the 3-iron set and the 9-iron the 7-iron set.
enum PGAGolferClubKind: String, CaseIterable {
    case driver, fairwayWood = "fairway_wood", iron3, iron7, wedge, putter

    init(_ club: PGAClub) {
        switch club {
        case .driver: self = .driver
        case .wood3, .wood5: self = .fairwayWood
        case .iron3, .iron4, .iron5: self = .iron3
        case .iron6, .iron7, .iron8, .iron9: self = .iron7
        case .wedge, .sandWedge, .lobWedge: self = .wedge
        case .putter: self = .putter
        }
    }
}

enum PGAGolferAssetError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case let .invalid(reason): return "Original golfer data: \(reason)" }
    }
}

/// Decoded golfer data, loaded once per golf session on a worker and reused
/// across holes. Immutable after loading. About 4 MB of clips, 0.4 MB of
/// geometry and 3 MB of RGBA textures (before mipmaps).
final class PGAOriginalGolferAssets: @unchecked Sendable {
    struct Mesh {
        struct Part { var firstIndex: Int; var indexCount: Int; var firstVertex: Int; var vertexCount: Int }
        static let stride = 40
        let vertexCount: Int
        /// PGAGMSH1 records: f32 position[3], normal[3], uv[2], u8 joints[4], u8 weights[4].
        let vertices: Data
        let indices: [UInt32]
        let parts: [Part]

        static func parse(_ data: Data) throws -> Mesh {
            guard data.count >= 56, data.prefix(8) == Data("PGAGMSH1".utf8) else { throw PGAGolferAssetError.invalid("not a PGAGMSH1 mesh") }
            func u32(_ offset: Int) -> Int { Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })) }
            guard u32(8) == 1 else { throw PGAGolferAssetError.invalid("unsupported mesh version") }
            let vertexCount = u32(12), indexCount = u32(16), partCount = u32(20), wide = u32(28) & 1 != 0
            var p = 56
            guard vertexCount > 0, p + vertexCount * stride <= data.count else { throw PGAGolferAssetError.invalid("truncated vertices") }
            let vertices = data.subdata(in: p..<(p + vertexCount * stride))
            p += vertexCount * stride
            let size = wide ? 4 : 2
            guard p + indexCount * size <= data.count else { throw PGAGolferAssetError.invalid("truncated indices") }
            let indices: [UInt32] = data.withUnsafeBytes { bytes in
                (0..<indexCount).map { i in
                    wide ? UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: p + 4 * i, as: UInt32.self))
                         : UInt32(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: p + 2 * i, as: UInt16.self)))
                }
            }
            p += indexCount * size
            p += (4 - p % 4) % 4
            guard p + partCount * 16 <= data.count else { throw PGAGolferAssetError.invalid("truncated submeshes") }
            let parts = (0..<partCount).map { i in Part(firstIndex: u32(p + 16 * i), indexCount: u32(p + 16 * i + 4),
                                                         firstVertex: u32(p + 16 * i + 8), vertexCount: u32(p + 16 * i + 12)) }
            for part in parts {
                guard part.firstIndex + part.indexCount <= indices.count, part.firstVertex + part.vertexCount <= vertexCount,
                      indices[part.firstIndex..<(part.firstIndex + part.indexCount)].allSatisfy({ Int($0) >= part.firstVertex && Int($0) < part.firstVertex + part.vertexCount })
                else { throw PGAGolferAssetError.invalid("submesh range") }
            }
            return Mesh(vertexCount: vertexCount, vertices: vertices, indices: indices, parts: parts)
        }
    }

    struct Layer: Hashable {
        var texture: String
        /// (scale u, scale v, offset u, offset v), the shader's TEXTURE_XFORM.
        var transform: SIMD4<Float>
    }

    struct Submesh {
        var part: Mesh.Part
        var base: Layer?
        var decal: Layer?
        var sets: [String]
    }

    /// Dense local transforms per frame (PGAGCLP1), played at the stored rate.
    struct Clip {
        let name: String
        let fps: Float
        let frameCount: Int
        let boneCount: Int
        let events: [UInt32: Float]
        let frames: [Float]
        var duration: Float { Float(max(0, frameCount - 1)) / fps }
        /// Swing events (seconds): 0 takeaway, 1 top of backswing, 2 impact.
        var takeaway: Float { events[0] ?? 0 }
        var top: Float { max(takeaway, events[1] ?? takeaway) }
        var impact: Float { max(top, events[2] ?? duration) }

        static func parse(_ data: Data, name: String) throws -> Clip {
            guard data.count >= 32, data.prefix(8) == Data("PGAGCLP1".utf8) else { throw PGAGolferAssetError.invalid("\(name) is not a PGAGCLP1 clip") }
            func u32(_ offset: Int) -> Int { Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })) }
            func f32(_ offset: Int) -> Float { Float(bitPattern: UInt32(u32(offset))) }
            let bones = u32(12), frameCount = u32(16), fps = f32(20), eventCount = u32(24)
            guard bones > 0, bones < 256, frameCount > 0, fps.isFinite, fps > 0, eventCount < 64 else { throw PGAGolferAssetError.invalid("\(name) header") }
            var events: [UInt32: Float] = [:]
            for i in 0..<eventCount where 32 + 8 * i + 8 <= data.count {
                let id = UInt32(u32(32 + 8 * i)), seconds = f32(36 + 8 * i)
                if events[id] == nil { events[id] = seconds }
            }
            var p = 32 + 8 * eventCount + bones
            p += (4 - p % 4) % 4
            let count = frameCount * bones * 7
            guard p + count * 4 <= data.count else { throw PGAGolferAssetError.invalid("\(name) frames truncated") }
            let frames: [Float] = data.withUnsafeBytes { bytes in
                (0..<count).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: p + 4 * $0, as: UInt32.self))) }
            }
            return Clip(name: name, fps: fps, frameCount: frameCount, boneCount: bones, events: events, frames: frames)
        }

        /// Interpolated local pose at `seconds`, clamped to the clip.
        func sample(_ seconds: Float, into pose: inout [PGAGolferTransform]) {
            let f = max(0, min(Float(frameCount - 1), seconds * fps))
            let i0 = min(frameCount - 1, Int(f)), i1 = min(frameCount - 1, i0 + 1), a = f - Float(i0)
            let count = min(boneCount, pose.count)
            frames.withUnsafeBufferPointer { values in
                for bone in 0..<count {
                    let o0 = (i0 * boneCount + bone) * 7, o1 = (i1 * boneCount + bone) * 7
                    let q0 = simd_quatf(ix: values[o0], iy: values[o0 + 1], iz: values[o0 + 2], r: values[o0 + 3])
                    let t0 = SIMD3<Float>(values[o0 + 4], values[o0 + 5], values[o0 + 6])
                    if a <= 0 || i0 == i1 { pose[bone] = PGAGolferTransform(rotation: q0, translation: t0); continue }
                    let q1 = simd_quatf(ix: values[o1], iy: values[o1 + 1], iz: values[o1 + 2], r: values[o1 + 3])
                    let t1 = SIMD3<Float>(values[o1 + 4], values[o1 + 5], values[o1 + 6])
                    pose[bone] = .mix(PGAGolferTransform(rotation: q0, translation: t0), PGAGolferTransform(rotation: q1, translation: t1), a)
                }
            }
        }
    }

    struct Club {
        var kind: PGAGolferClubKind
        /// IG_driver_head local translation: the club's own length (clips carry none).
        var headTranslation: SIMD3<Float>
        var submeshes: [Submesh]
        var inverseBinds: [Int: simd_float4x4]
        var swing: String
        var address: String
    }

    struct Texture {
        var image: CGImage
        var translucent: Bool
    }

    let names: [String]
    let parents: [Int]
    let bindLocal: [PGAGolferTransform]
    let inverseBind: [simd_float4x4]
    let headBone: Int
    let body: Mesh
    let bodySubmeshes: [Submesh]
    let clubMesh: Mesh
    let clubs: [PGAGolferClubKind: Club]
    let clips: [String: Clip]
    let textures: [String: Texture]
    /// Assumed world size (golfer.json): one model unit is one yard.
    let metersPerUnit: Float
    let footprintBytes: Int

    static func directory(root: URL) -> URL { root.appendingPathComponent("Library/Imported/pga2005/golfer", isDirectory: true) }

    static func load(root: URL) throws -> PGAOriginalGolferAssets {
        let folder = directory(root: root)
        func json(_ name: String) throws -> [String: Any] {
            guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(name))) as? [String: Any] else {
                throw PGAGolferAssetError.invalid("\(name) is not an object")
            }
            return value
        }
        let manifest = try json("golfer.json"), skeleton = try json("skeleton.json")
        guard let boneList = skeleton["bones"] as? [[String: Any]], !boneList.isEmpty else { throw PGAGolferAssetError.invalid("skeleton has no bones") }
        var names: [String] = [], parents: [Int] = [], bind: [PGAGolferTransform] = [], inverse: [simd_float4x4] = []
        for (index, bone) in boneList.enumerated() {
            let parent = (bone["parent"] as? NSNumber)?.intValue ?? -1
            guard parent < index, let local = transform(bone["bind_local"]), let matrix = matrix(bone["inverse_bind_matrix"]) else {
                throw PGAGolferAssetError.invalid("bone \(index)")
            }
            names.append(bone["name"] as? String ?? ""); parents.append(parent); bind.append(local); inverse.append(matrix)
        }
        guard let headBone = names.firstIndex(of: "IG_driver_head") else { throw PGAGolferAssetError.invalid("no club head bone") }

        var textures: [String: Texture] = [:]
        for (name, value) in manifest["textures"] as? [String: [String: Any]] ?? [:] {
            guard let file = value["file"] as? String,
                  let source = CGImageSourceCreateWithURL(folder.appendingPathComponent(file) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            textures[name] = Texture(image: image, translucent: ((value["translucent_texels"] as? NSNumber)?.intValue ?? 0) > 0)
        }

        func layer(_ any: Any?) -> Layer? {
            guard let value = any as? [String: Any], let texture = value["texture"] as? String else { return nil }
            let t = floats(value["uv_transform"])
            return Layer(texture: texture, transform: t.count == 4 ? SIMD4(t[0], t[1], t[2], t[3]) : SIMD4(1, 1, 0, 0))
        }
        func submeshes(_ list: [[String: Any]], mesh: Mesh) throws -> [Submesh] {
            guard list.count == mesh.parts.count else { throw PGAGolferAssetError.invalid("submesh table") }
            return zip(list, mesh.parts).map { Submesh(part: $1, base: layer($0["base"]), decal: layer($0["decal"]), sets: $0["sets"] as? [String] ?? []) }
        }
        guard let meshInfo = manifest["mesh"] as? [String: Any], let clubInfo = manifest["clubs"] as? [String: Any],
              let kinds = clubInfo["kinds"] as? [String: [String: Any]] else { throw PGAGolferAssetError.invalid("manifest lacks mesh or clubs") }
        let body = try Mesh.parse(Data(contentsOf: folder.appendingPathComponent("golfer_mesh.bin")))
        let bodySubmeshes = try submeshes(meshInfo["submeshes"] as? [[String: Any]] ?? [], mesh: body)
        let clubMesh = try Mesh.parse(Data(contentsOf: folder.appendingPathComponent(clubInfo["file"] as? String ?? "club_mesh.bin")))
        let clubSubmeshes = try submeshes(clubInfo["submeshes"] as? [[String: Any]] ?? [], mesh: clubMesh)

        var clubs: [PGAGolferClubKind: Club] = [:], clipNames: Set<String> = []
        for kind in PGAGolferClubKind.allCases {
            guard let info = kinds[kind.rawValue], let bones = info["bones"] as? [String: [String: Any]],
                  let motions = info["motions"] as? [String: Any],
                  let swing = motions["swing"] as? String, let address = motions["address"] as? String,
                  let head = bones[String(headBone)], let headLocal = transform(head["bind_local"]) else {
                throw PGAGolferAssetError.invalid("club \(kind.rawValue)")
            }
            var inverseBinds: [Int: simd_float4x4] = [:]
            for (key, value) in bones { if let index = Int(key), let m = matrix(value["inverse_bind_matrix"]) { inverseBinds[index] = m } }
            let parts = (info["submeshes"] as? [NSNumber] ?? []).map(\.intValue).filter { clubSubmeshes.indices.contains($0) }
            clubs[kind] = Club(kind: kind, headTranslation: headLocal.translation, submeshes: parts.map { clubSubmeshes[$0] },
                               inverseBinds: inverseBinds, swing: swing, address: address)
            clipNames.formUnion([swing, address])
        }
        var clips: [String: Clip] = [:]
        for name in clipNames {
            let clip = try Clip.parse(Data(contentsOf: folder.appendingPathComponent("clips/\(name).pgaclip")), name: name)
            guard clip.boneCount == names.count else { throw PGAGolferAssetError.invalid("\(name) has \(clip.boneCount) channels") }
            clips[name] = clip
        }
        let metersPerUnit = (manifest["assumed_meters_per_unit"] as? NSNumber)?.floatValue ?? 0.9144
        let footprint = body.vertices.count + clubMesh.vertices.count + 4 * (body.indices.count + clubMesh.indices.count)
            + clips.values.reduce(0) { $0 + 4 * $1.frames.count } + textures.values.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height }
        return PGAOriginalGolferAssets(names: names, parents: parents, bindLocal: bind, inverseBind: inverse, headBone: headBone,
                                       body: body, bodySubmeshes: bodySubmeshes, clubMesh: clubMesh, clubs: clubs, clips: clips,
                                       textures: textures, metersPerUnit: metersPerUnit, footprintBytes: footprint)
    }

    private init(names: [String], parents: [Int], bindLocal: [PGAGolferTransform], inverseBind: [simd_float4x4], headBone: Int,
                 body: Mesh, bodySubmeshes: [Submesh], clubMesh: Mesh, clubs: [PGAGolferClubKind: Club], clips: [String: Clip],
                 textures: [String: Texture], metersPerUnit: Float, footprintBytes: Int) {
        self.names = names; self.parents = parents; self.bindLocal = bindLocal; self.inverseBind = inverseBind; self.headBone = headBone
        self.body = body; self.bodySubmeshes = bodySubmeshes; self.clubMesh = clubMesh; self.clubs = clubs; self.clips = clips
        self.textures = textures; self.metersPerUnit = metersPerUnit; self.footprintBytes = footprintBytes
    }

    private static func floats(_ any: Any?) -> [Float] { (any as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue } ?? [] }
    private static func matrix(_ any: Any?) -> simd_float4x4? {
        let v = floats(any)
        guard v.count == 16 else { return nil }
        return simd_float4x4(columns: (SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
                                       SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15])))
    }
    private static func transform(_ any: Any?) -> PGAGolferTransform? {
        guard let value = any as? [String: Any] else { return nil }
        let r = floats(value["rotation"]), t = floats(value["translation"])
        guard r.count == 4, t.count == 3 else { return nil }
        return PGAGolferTransform(rotation: simd_normalize(simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])), translation: SIMD3(t[0], t[1], t[2]))
    }

    /// World (rig-space) transforms for a local pose, with the club head bone
    /// at the given club's length.
    func world(_ local: [PGAGolferTransform], club: PGAGolferClubKind, into world: inout [PGAGolferTransform]) {
        let head = clubs[club]?.headTranslation
        for i in 0..<min(local.count, parents.count) {
            var bone = local[i]
            if i == headBone, let head { bone.translation = head }
            world[i] = parents[i] < 0 ? bone : world[parents[i]].then(bone)
        }
    }
}

// MARK: - Animation driver

/// Explicit-time pose driver: no SceneKit animation timers. Each update maps
/// the simulation's phase and original tri-click meter onto clip time and
/// samples the clip, blending briefly where the motion changes source.
///
/// - Aiming: the club's address waggle loops (crossfaded at the seam).
/// - Lift (meter state 1): address into the takeaway.
/// - Backswing (state 2): takeaway to the top in step with the marker's
///   travel from its lift peak to 12 o'clock (100 %); overswing holds the top.
/// - States 3–4: hold the pose reached at the power click.
/// - Downswing: the marker returns counter-clockwise at the level's top speed
///   and the ball launches when it reaches 311°, accuracy click or not. The
///   downswing starts `rate × (impact − top)` degrees before 311°, so it runs
///   at about the clip's own speed and impact coincides with the launch.
/// - Airborne/rolling: follow-through from impact at clip speed, then the
///   finish holds.
/// The putt clip starts at the top of the backstroke, so the backstroke blends
/// from the putter address pose (the waggle's soled last frame) to it.
struct PGAGolferAnimator {
    enum Stage: Equatable { case address, lift, backswing, top, downswing, followThrough }

    let assets: PGAOriginalGolferAssets
    private(set) var stage = Stage.address
    private(set) var kind = PGAGolferClubKind.driver
    /// Time in the clip being sampled (the address waggle while aiming).
    private(set) var clipTime: Float = 0
    /// Downswing progress 0…1 (1 = impact).
    private(set) var downswing: Float = 0
    private(set) var pose: [PGAGolferTransform]
    private var target: [PGAGolferTransform]
    private var scratch: [PGAGolferTransform]
    private var blendFrom: [PGAGolferTransform]
    private var held: [PGAGolferTransform]
    private var blendElapsed: Float = 0
    private var blendDuration: Float = 0
    private var idleTime: Float = 0
    private var followTime: Float = 0
    private var liftPeak = Float(PGATriClickMeter.rest)
    private var started = false

    init(assets: PGAOriginalGolferAssets) {
        self.assets = assets
        pose = assets.bindLocal; target = pose; scratch = pose; blendFrom = pose; held = pose
    }

    /// Forget the current motion; the next update starts without a blend.
    mutating func reset() { started = false }

    mutating func advance(phase: PGAPhase, club: PGAClub, meter: PGATriClickMeter?, delta: Double, sample: Bool = true) {
        let dt = Float(max(0, min(delta, 0.25)))
        let newKind = PGAGolferClubKind(club)
        guard let motion = assets.clubs[newKind], let swing = assets.clips[motion.swing], let idle = assets.clips[motion.address] else { return }
        let desired: Stage
        switch phase {
        case .aiming, .holed, .roundComplete: desired = .address
        case .airborne, .rolling: desired = .followThrough
        case .power, .accuracy:
            guard let meter else { desired = .address; break }
            switch meter.state {
            case 1: desired = .lift
            case 2: desired = .backswing
            case 3: desired = .top
            case 4, 5: desired = Float(meter.angle) >= downswingStart(meter, swing) || stage == .downswing ? .downswing : .top
            default: desired = .downswing
            }
        }
        if !started {
            started = true; stage = desired; kind = newKind
            idleTime = 0; followTime = 0; downswing = 0; blendDuration = 0
        } else if desired != stage || newKind != kind {
            let duration: Float
            switch (stage, desired) {
            case (.followThrough, .address): duration = 0            // the ball moved: start fresh
            case (_, .address): duration = 0.3                       // cancelled swing or new club
            case (_, .lift): duration = 0.25
            case (.downswing, .followThrough): duration = downswing >= 0.999 ? 0 : 0.06
            case (_, .followThrough): duration = 0.08
            default: duration = 0
            }
            beginBlend(duration)
            if desired == .top || (desired == .downswing && stage != .top) { held = pose }
            if desired == .address { idleTime = 0 }
            if desired == .lift { liftPeak = Float(PGATriClickMeter.rest) }
            if desired == .downswing { downswing = 0 }
            if desired == .followThrough { followTime = 0 }
            stage = desired; kind = newKind
        }

        switch stage {
        case .address:
            idleTime += dt
            if idleTime > idle.duration {
                idleTime = idle.duration > 0 ? idleTime.truncatingRemainder(dividingBy: idle.duration) : 0
                beginBlend(0.35)                                     // crossfade the loop seam
            }
            clipTime = idleTime
            if sample { idle.sample(idleTime, into: &target) }
        case .lift:
            let angle = Float(meter?.angle ?? PGATriClickMeter.rest)
            liftPeak = max(liftPeak, angle)
            let fraction = max(0, min(1, (angle - Float(PGATriClickMeter.rest)) / 28))
            clipTime = swing.takeaway * fraction
            if sample { addressPose(swing, idle, into: &target) }
            if sample, swing.top - swing.takeaway > 0.5 / swing.fps { swing.sample(clipTime, into: &target) }
        case .backswing:
            let angle = Float(meter?.angle ?? PGATriClickMeter.fullPower)
            liftPeak = max(liftPeak, angle)
            let span = max(1, liftPeak - Float(PGATriClickMeter.fullPower))
            let progress = max(0, min(1, (liftPeak - angle) / span))
            if swing.top - swing.takeaway > 0.5 / swing.fps {
                clipTime = swing.takeaway + progress * (swing.top - swing.takeaway)
                if sample { swing.sample(clipTime, into: &target) }
            } else {
                clipTime = swing.top
                if sample {
                    addressPose(swing, idle, into: &scratch)
                    swing.sample(swing.top, into: &target)
                    for i in target.indices { target[i] = .mix(scratch[i], target[i], progress) }
                }
            }
        case .top:
            if sample { target = held }
        case .downswing:
            if let meter {
                let start = downswingStart(meter, swing)
                let progress = meter.state >= 6 ? 1 : max(0, min(1, (Float(meter.angle) - start) / max(1, Float(PGATriClickMeter.maxAngle) - start)))
                downswing = max(downswing, progress)
            } else {
                downswing = 1
            }
            clipTime = swing.top + downswing * (swing.impact - swing.top)
            if sample {
                swing.sample(clipTime, into: &target)
                for i in target.indices { target[i] = .mix(held[i], target[i], downswing) }
            }
        case .followThrough:
            followTime += dt
            clipTime = min(swing.duration, swing.impact + followTime)
            if sample { swing.sample(clipTime, into: &target) }
        }

        guard sample else { blendElapsed += dt; return }
        if blendElapsed < blendDuration {
            blendElapsed += dt
            let x = max(0, min(1, blendElapsed / blendDuration)), w = x * x * (3 - 2 * x)
            for i in pose.indices { pose[i] = .mix(blendFrom[i], target[i], w) }
        } else {
            pose = target
        }
    }

    private mutating func beginBlend(_ duration: Float) {
        guard duration > 0 else { blendDuration = 0; blendElapsed = 0; return }
        blendFrom = pose; blendElapsed = 0; blendDuration = duration
    }

    /// Address pose: the swing clip's first frame, or for the putt (whose clip
    /// starts at the top of the backstroke) the waggle's soled last frame.
    private func addressPose(_ swing: PGAOriginalGolferAssets.Clip, _ idle: PGAOriginalGolferAssets.Clip, into pose: inout [PGAGolferTransform]) {
        if swing.top - swing.takeaway > 0.5 / swing.fps { swing.sample(0, into: &pose) } else { idle.sample(idle.duration, into: &pose) }
    }

    /// Marker angle at which the downswing begins so that it reaches impact
    /// as the marker reaches 311° (the launch).
    private func downswingStart(_ meter: PGATriClickMeter, _ swing: PGAOriginalGolferAssets.Clip) -> Float {
        let rate = Float(meter.putter ? meter.level.putterRate : meter.level.rate)
        let span = max(20, min(150, rate * (swing.impact - swing.top)))
        return Float(PGATriClickMeter.maxAngle) - span
    }
}

// MARK: - Scene node

/// The golfer in the scene: GPU-skinned (SCNSkinner, ≤ 3 influences per
/// vertex) body and club, posed each frame from the animator through flat
/// rig-space bone nodes. One node tree is built per session and moved to the
/// ball for every shot and hole.
final class PGAOriginalGolfer {
    /// Category of the cast-only shadow proxy; the game camera excludes it.
    static let shadowCategory = 1 << 4
    /// Beyond this camera distance (m) the golfer is hidden and not posed.
    static let maxVisibleDistance = 60.0

    let assets: PGAOriginalGolferAssets
    /// World placement: at the ball on the ground, rotated to the aim and
    /// scaled from model units to meters.
    let node = SCNNode()
    private let rig = SCNNode()
    private var bones: [SCNNode] = []
    private var posedBones: [Int] = []
    private var clubNodes: [PGAGolferClubKind: SCNNode] = [:]
    private(set) var animator: PGAGolferAnimator
    private var world: [PGAGolferTransform]
    /// Ball position the golfer addressed (the shot origin during flight).
    private(set) var anchor: PGAVector?
    private var anchorHeading = 0.0
    /// Draw calls (main pass) and skinned vertices of the visible golfer.
    private(set) var drawCalls = 0
    private(set) var vertexCount = 0
    private var clubDrawCalls: [PGAGolferClubKind: (draws: Int, vertices: Int)] = [:]
    private var bodyStats = (draws: 0, vertices: 0)

    init(assets: PGAOriginalGolferAssets) {
        self.assets = assets
        animator = PGAGolferAnimator(assets: assets)
        world = assets.bindLocal
        node.name = "Original golfer (Tiger Woods 01char)"
        rig.name = "Golfer rig"
        node.addChildNode(rig)
        bones = assets.names.enumerated().map { index, name in
            let bone = SCNNode(); bone.name = name; rig.addChildNode(bone); return bone
        }
        var used = Set<Int>()
        let visible = assets.bodySubmeshes.filter { $0.sets.contains("default") || $0.sets.contains("GloveOn") }
        if let (body, stats, palette) = makeSkinnedNode(mesh: assets.body, submeshes: visible, name: "Golfer body",
                                                        inverseBind: { assets.inverseBind[$0] }) {
            body.castsShadow = false
            rig.addChildNode(body); bodyStats = stats; used.formUnion(palette)
        }
        // The original's own shadow proxy (268 vertices) casts the sun shadow.
        if let (shadow, _, palette) = makeSkinnedNode(mesh: assets.body, submeshes: assets.bodySubmeshes.filter { $0.sets == ["shadow"] },
                                                      name: "Golfer shadow proxy", inverseBind: { assets.inverseBind[$0] }, shadowOnly: true) {
            shadow.categoryBitMask = Self.shadowCategory
            shadow.castsShadow = true
            rig.addChildNode(shadow); used.formUnion(palette)
        }
        for (kind, club) in assets.clubs {
            guard let (clubNode, stats, palette) = makeSkinnedNode(mesh: assets.clubMesh, submeshes: club.submeshes, name: "Club \(kind.rawValue)",
                                                                   inverseBind: { club.inverseBinds[$0] ?? assets.inverseBind[$0] }) else { continue }
            clubNode.castsShadow = true
            clubNode.isHidden = true
            rig.addChildNode(clubNode); clubNodes[kind] = clubNode; clubDrawCalls[kind] = stats; used.formUnion(palette)
        }
        posedBones = used.sorted()
        let s = CGFloat(assets.metersPerUnit)
        node.scale = SCNVector3(s, s, s)
        node.isHidden = true
    }

    /// Place, pose and show or hide the golfer for this frame.
    func update(_ simulation: PGASimulation, cameraPosition: PGAVector, delta: Double, sceneReady: Bool) {
        let phase = simulation.phase
        if phase == .aiming || phase.swinging || anchor == nil { anchor = simulation.ball; anchorHeading = simulation.heading }
        guard sceneReady, phase != .holed, phase != .roundComplete, let anchor else {
            node.isHidden = true; animator.reset(); return
        }
        let visible = (cameraPosition - anchor).length < Self.maxVisibleDistance
        animator.advance(phase: phase, club: simulation.club, meter: simulation.swingMeter, delta: delta, sample: visible)
        node.isHidden = !visible
        guard visible else { return }
        node.simdPosition = SIMD3<Float>(Float(anchor.x), Float(anchor.y - PGASimulation.ballRadius), Float(anchor.z))
        // Model +X (target line) onto the aim direction (sin h, 0, cos h).
        node.simdOrientation = simd_quatf(angle: Float(anchorHeading - .pi / 2), axis: SIMD3(0, 1, 0))
        assets.world(animator.pose, club: animator.kind, into: &world)
        for index in posedBones { bones[index].simdTransform = world[index].matrix }
        for (kind, club) in clubNodes { club.isHidden = kind != animator.kind }
        let club = clubDrawCalls[animator.kind] ?? (0, 0)
        drawCalls = bodyStats.draws + club.draws
        vertexCount = bodyStats.vertices + club.vertices
    }

    /// World position (m) of a bone in the current pose, for tests and cameras.
    func worldPosition(of name: String) -> PGAVector? {
        guard let index = assets.names.firstIndex(of: name) else { return nil }
        let p = node.simdConvertPosition(world[index].translation, to: nil)
        return PGAVector(x: Double(p.x), y: Double(p.y), z: Double(p.z))
    }

    /// Lowest world point (m) of the active club's vertices in the current pose.
    func clubLowestPoint() -> PGAVector? {
        guard let club = assets.clubs[animator.kind] else { return nil }
        var lowest: SIMD3<Float>?
        assets.clubMesh.vertices.withUnsafeBytes { bytes in
            for sub in club.submeshes {
                for v in sub.part.firstVertex..<(sub.part.firstVertex + sub.part.vertexCount) {
                    let o = v * PGAOriginalGolferAssets.Mesh.stride
                    let p = SIMD4<Float>(bytes.loadUnaligned(fromByteOffset: o, as: Float.self), bytes.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                         bytes.loadUnaligned(fromByteOffset: o + 8, as: Float.self), 1)
                    let bone = Int(bytes[o + 32])
                    guard let inverse = club.inverseBinds[bone] else { continue }
                    let rig = world[bone].matrix * inverse * p
                    let point = node.simdConvertPosition(SIMD3(rig.x, rig.y, rig.z), to: nil)
                    if lowest == nil || point.y < lowest!.y { lowest = point }
                }
            }
        }
        return lowest.map { PGAVector(x: Double($0.x), y: Double($0.y), z: Double($0.z)) }
    }

    // MARK: Geometry

    private func makeSkinnedNode(mesh: PGAOriginalGolferAssets.Mesh, submeshes: [PGAOriginalGolferAssets.Submesh], name: String,
                                 inverseBind: (Int) -> simd_float4x4, shadowOnly: Bool = false)
        -> (SCNNode, (draws: Int, vertices: Int), [Int])? {
        guard !submeshes.isEmpty else { return nil }
        var remap = [Int32](repeating: -1, count: mesh.vertexCount)
        var positions: [Float] = [], normals: [Float] = [], uvs: [Float] = [], weights: [Float] = [], joints: [UInt16] = []
        var palette: [Int] = [], paletteIndex: [Int: UInt16] = [:]
        mesh.vertices.withUnsafeBytes { bytes in
            for sub in submeshes {
                for v in sub.part.firstVertex..<(sub.part.firstVertex + sub.part.vertexCount) where remap[v] < 0 {
                    remap[v] = Int32(positions.count / 3)
                    let o = v * PGAOriginalGolferAssets.Mesh.stride
                    func f(_ k: Int) -> Float { bytes.loadUnaligned(fromByteOffset: o + 4 * k, as: Float.self) }
                    positions += [f(0), f(1), f(2)]; normals += [f(3), f(4), f(5)]; uvs += [f(6), f(7)]
                    for k in 0..<4 {
                        let bone = Int(bytes[o + 32 + k]), weight = Float(bytes[o + 36 + k]) / 255
                        var slot: UInt16 = 0
                        if weight > 0 {
                            if let existing = paletteIndex[bone] { slot = existing } else {
                                slot = UInt16(palette.count); paletteIndex[bone] = slot; palette.append(bone)
                            }
                        }
                        joints.append(slot); weights.append(weight)
                    }
                }
            }
        }
        let count = positions.count / 3
        guard count > 0, count < Int(UInt16.max), !palette.isEmpty else { return nil }
        // One element per material (base texture + decal): 22 body draws.
        var groups: [(key: String, base: PGAOriginalGolferAssets.Layer?, decal: PGAOriginalGolferAssets.Layer?, indices: [UInt16])] = []
        for sub in submeshes {
            let key = shadowOnly ? "shadow" : "\(sub.base?.texture ?? "-")|\(sub.decal.map { "\($0.texture)\($0.transform)" } ?? "-")"
            let indices = mesh.indices[sub.part.firstIndex..<(sub.part.firstIndex + sub.part.indexCount)].map { UInt16(remap[Int($0)]) }
            if let g = groups.firstIndex(where: { $0.key == key }) { groups[g].indices += indices }
            else { groups.append((key, sub.base, sub.decal, indices)) }
        }
        func source<T>(_ values: [T], _ semantic: SCNGeometrySource.Semantic, components: Int, float: Bool) -> SCNGeometrySource {
            let size = MemoryLayout<T>.size
            return SCNGeometrySource(data: values.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: semantic, vectorCount: count,
                                     usesFloatComponents: float, componentsPerVector: components, bytesPerComponent: size,
                                     dataOffset: 0, dataStride: size * components)
        }
        let elements = groups.map { group in
            group.indices.withUnsafeBufferPointer { SCNGeometryElement(data: Data(buffer: $0), primitiveType: .triangles,
                                                                       primitiveCount: group.indices.count / 3, bytesPerIndex: 2) }
        }
        let geometry = SCNGeometry(sources: [source(positions, .vertex, components: 3, float: true), source(normals, .normal, components: 3, float: true),
                                             source(uvs, .texcoord, components: 2, float: true)], elements: elements)
        geometry.materials = groups.map { shadowOnly ? Self.shadowMaterial() : material(base: $0.base, decal: $0.decal) }
        // Skinned poses leave the bind-pose bounds; keep culling conservative
        // (rig space, model units: the full swing and finish stay inside).
        geometry.boundingBox = (SCNVector3(-3, -0.5, -3), SCNVector3(3, 3.2, 3))
        let skinner = SCNSkinner(baseGeometry: geometry, bones: palette.map { bones[$0] },
                                 boneInverseBindTransforms: palette.map { NSValue(scnMatrix4: SCNMatrix4(inverseBind($0))) },
                                 boneWeights: source(weights, .boneWeights, components: 4, float: true),
                                 boneIndices: source(joints, .boneIndices, components: 4, float: false))
        skinner.skeleton = rig
        let result = SCNNode(geometry: geometry)
        result.name = name
        result.skinner = skinner
        return (result, (groups.count, count), palette)
    }

    private static let decalModifier = """
        #pragma arguments
        texture2d<float> decalTexture;
        float4 decalTransform;
        #pragma body
        constexpr sampler decalSampler(filter::linear, address::clamp_to_zero);
        float4 decal = decalTexture.sample(decalSampler, _surface.diffuseTexcoord * decalTransform.xy + decalTransform.zw);
        _surface.diffuse.rgb = mix(_surface.diffuse.rgb, decal.rgb, decal.a);
        """

    static let equipmentModifier = """
        #pragma arguments
        float3 maskRed;
        float3 maskGreen;
        float3 maskBlue;
        #pragma body
        float3 m = _surface.diffuse.rgb;
        _surface.diffuse.rgb = m.r * maskRed + m.g * maskGreen + m.b * maskBlue;
        """

    /// Colours for the red, green and blue channels of a generic mask.
    static func equipmentColors(_ texture: String) -> [SIMD3<Float>]? {
        if texture.contains("gr1") { return [SIMD3(0.55, 0.55, 0.55), SIMD3(0.75, 0.1, 0.08), SIMD3(0.07, 0.07, 0.07)] }
        if texture.hasPrefix("fwd") { return [SIMD3(0.8, 0.8, 0.8), SIMD3(0.7, 0.08, 0.06), SIMD3(0.12, 0.12, 0.13)] }
        if texture.contains("sh1") { return [SIMD3(0.55, 0.55, 0.57), SIMD3(0.35, 0.35, 0.37), SIMD3(0.78, 0.79, 0.8)] }
        return nil
    }

    /// Lambert (sun + ambient) like the original-course terrain; no specular.
    /// Base and decal are one pass, as in the original's two texture stages.
    private func material(base: PGAOriginalGolferAssets.Layer?, decal: PGAOriginalGolferAssets.Layer?) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .lambert
        // Triangles were reoriented counter-clockwise about their normals and
        // the placement is a proper rotation, so back faces can be culled.
        material.isDoubleSided = false
        if let base, let texture = assets.textures[base.texture] {
            material.name = base.texture
            material.diffuse.contents = texture.image
            material.diffuse.wrapS = .repeat; material.diffuse.wrapT = .repeat
            material.diffuse.minificationFilter = .linear; material.diffuse.magnificationFilter = .linear
            material.diffuse.mipFilter = .linear
            if base.transform != SIMD4(1, 1, 0, 0) {
                material.diffuse.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeScale(CGFloat(base.transform.x), CGFloat(base.transform.y), 1),
                                                                    SCNMatrix4MakeTranslation(CGFloat(base.transform.z), CGFloat(base.transform.w), 0))
            }
            if texture.translucent {
                // Lashes and teeth edges: blended like the original SRCALPHA golfer pass.
                material.blendMode = .alpha
                material.transparencyMode = .aOne
                material.writesToDepthBuffer = false
            }
        } else {
            material.diffuse.contents = NSColor(white: 0.7, alpha: 1)
        }
        if let base, base.texture.hasSuffix("gen"), let colors = Self.equipmentColors(base.texture) {
            // Generic shaft/grip art is a channel mask the original tints with the
            // player's equipment colours (.plr data not decoded). Native colours:
            // graphite wood shafts, steel iron shafts, black grips.
            material.shaderModifiers = [.surface: Self.equipmentModifier]
            for (key, color) in zip(["maskRed", "maskGreen", "maskBlue"], colors) {
                material.setValue(NSValue(scnVector3: SCNVector3(color.x, color.y, color.z)), forKey: key)
            }
        }
        if let decal, let texture = assets.textures[decal.texture] {
            material.shaderModifiers = [.surface: Self.decalModifier]
            material.setValue(SCNMaterialProperty(contents: texture.image), forKey: "decalTexture")
            let t = decal.transform
            material.setValue(NSValue(scnVector4: SCNVector4(CGFloat(t.x), CGFloat(t.y), CGFloat(t.z), CGFloat(t.w))), forKey: "decalTransform")
        }
        return material
    }

    private static func shadowMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.colorBufferWriteMask = []
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        return material
    }
}

// MARK: - Renderer integration

extension PGARenderer {
    /// Loads the decoded golfer on a worker, then adds it on the main thread.
    /// Without prepared golfer data the generated placeholder stays.
    func loadOriginalGolfer(root: URL) {
        guard originalGolfer == nil, !originalGolferLoading else { return }
        originalGolferLoading = true
        Task { [weak self] in
            let work = Task.detached(priority: .utility) { try? PGAOriginalGolferAssets.load(root: root) }
            let assets = await work.value
            if let assets { self?.useOriginalGolfer(assets) }
            self?.originalGolferLoading = false
        }
    }

    /// Replaces the placeholder golfer with the original one (once per session).
    func useOriginalGolfer(_ assets: PGAOriginalGolferAssets?) {
        guard let assets, originalGolfer == nil else { return }
        let golfer = PGAOriginalGolfer(assets: assets)
        scene.rootNode.addChildNode(golfer.node)
        camera.camera?.categoryBitMask &= ~PGAOriginalGolfer.shadowCategory
        originalGolfer = golfer
    }
}
