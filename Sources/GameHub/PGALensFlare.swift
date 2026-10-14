import AppKit
import SceneKit

/// The original lens flare (LensFlare::NextFrame / Draw, PGA2005-RENDER-
/// PRESETS.md §5): a sun quad, coronas rotating with the camera and flares on
/// the line from the sun's screen point through the screen centre, with the
/// blended preset's sizes and opacities. Quads live on a plane 1 m in front of
/// the camera, so they cost a few draws and no depth work. Sizes use the
/// original pixel units against an 800-pixel-wide reference. The original
/// occludes with 16 × 16 GPU passes over trees, terrain and golfers; this
/// version hides the flare when the terrain blocks the sun (CPU ray march)
/// and fades over a fifth of a second instead of popping.
final class PGALensFlare {
    let node = SCNNode()
    private var sprites: [SCNNode] = []
    /// Texture1…9 of the render inis: sun1, corona, flare1–4, lflarea/b, rainbow.
    private var textures: [(image: NSImage, size: CGSize)?] = []
    private var visibility = 0.0
    private var current: PGARenderState.Flare?

    init(images: [NSImage?]) {
        node.name = "Original lens flare"
        textures = images.map { image in image.map { ($0, $0.size) } }
        node.renderingOrder = 10_000
    }

    /// Rebuilds the quads when a new hole's preset arrives.
    func use(_ flare: PGARenderState.Flare?) {
        current = flare
        sprites.forEach { $0.removeFromParentNode() }
        sprites.removeAll()
        guard let flare else { node.isHidden = true; return }
        func sprite(_ texture: Int, additive: Bool) -> SCNNode {
            let plane = SCNPlane(width: 1, height: 1)
            let material = SCNMaterial()
            material.diffuse.contents = textures.indices.contains(texture) ? textures[texture]?.image : nil
            material.lightingModel = .constant
            material.blendMode = additive ? .add : .alpha
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            material.isDoubleSided = true
            plane.materials = [material]
            let sprite = SCNNode(geometry: plane)
            sprite.renderingOrder = 10_000
            sprite.castsShadow = false
            node.addChildNode(sprite)
            sprites.append(sprite)
            return sprite
        }
        _ = sprite(0, additive: false)
        for corona in flare.coronas { _ = sprite(corona.texture, additive: true) }
        for item in flare.flares { _ = sprite(item.texture, additive: true) }
    }

    /// `sunDirection` is the world direction from the camera toward the sun;
    /// `blocked` reports whether terrain covers it.
    func update(camera: SCNNode, fieldOfView: Double, aspect: Double, sunDirection: PGAVector, blocked: Bool, delta: Double) {
        guard let flare = current, !sprites.isEmpty else { node.isHidden = true; return }
        let local = camera.convertVector(SCNVector3(sunDirection.x, sunDirection.y, sunDirection.z), from: nil)
        let tanY = tan(fieldOfView * .pi / 360), tanX = tanY * aspect
        let depth = -Double(local.z)
        let onScreen: Bool
        var ndc = (x: 0.0, y: 0.0)
        if depth > 1e-4 {
            ndc = (Double(local.x) / depth / tanX, Double(local.y) / depth / tanY)
            // The original rejects suns outside the screen widened by W/8 per side.
            onScreen = abs(ndc.x) <= 1.25 && abs(ndc.y) <= 1.25
        } else {
            onScreen = false
        }
        let target = onScreen && !blocked ? 1.0 : 0.0
        visibility += (target - visibility) * min(1, delta * 7)
        node.isHidden = visibility < 0.01
        guard !node.isHidden else { return }
        // One original pixel on an 800-wide reference is 1/400 of the NDC width.
        func place(_ sprite: SCNNode, x: Double, y: Double, halfPixels: Double, opacity: Double, roll: Double = 0) {
            let half = halfPixels / 400
            sprite.position = SCNVector3(x * tanX, y * tanY, -1)
            sprite.scale = SCNVector3(2 * half * tanX, 2 * half * tanX, 1)
            sprite.eulerAngles.z = CGFloat(roll)
            sprite.opacity = CGFloat(max(0, min(1, opacity * visibility)))
        }
        place(sprites[0], x: ndc.x, y: ndc.y, halfPixels: 8 * flare.sunSize, opacity: flare.sunOpacity)
        // θ from the camera's orientation; coronas turn at (i + 5)·θ.
        let theta = Double(camera.presentation.eulerAngles.y)
        for (i, corona) in flare.coronas.enumerated() {
            let size = textures.indices.contains(corona.texture) ? Double(textures[corona.texture]?.size.width ?? 128) : 128
            place(sprites[1 + i], x: ndc.x, y: ndc.y, halfPixels: size * corona.size * 0.5, opacity: flare.coronaOpacity, roll: Double(i + 5) * theta)
        }
        let base = 1 + flare.coronas.count
        for (i, item) in flare.flares.enumerated() where base + i < sprites.count {
            // C + (C − S)·position in screen terms: −1 is the sun, +1 its mirror.
            let x = -ndc.x * item.position, y = -ndc.y * item.position
            let size = textures.indices.contains(item.texture) ? Double(textures[item.texture]?.size.width ?? 64) : 64
            place(sprites[base + i], x: x, y: y, halfPixels: size * item.size * 0.5, opacity: flare.flareOpacity)
        }
    }

    /// Sun direction in the simulation's meter frame for a preset Position (raw
    /// inches, left-handed) seen from a camera `heightAboveCourseMinimum`
    /// meters up: the original pins the sun's height above the course's
    /// lowest point while it follows the camera in x and z.
    static func sunDirection(position: SIMD3<Double>, heightAboveCourseMinimum: Double) -> PGAVector {
        let v = PGAVector(x: position.x, y: position.y - heightAboveCourseMinimum / 0.0254, z: -position.z)
        let length = max(1e-9, v.length)
        return PGAVector(x: v.x / length, y: v.y / length, z: v.z / length)
    }
}
