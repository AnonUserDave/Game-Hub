import AppKit
import SceneKit

/// Original shot effects triggered like anim.stn (docs/research/PGA2005-
/// PRESENTATION.md): sand blast from bunkers, grass clippings from rough,
/// divots from full iron shots, the tee from wood/driver tee shots, water
/// splashes and bunker kick-ups on landing. Sprites, divot and tee meshes are
/// the original art (Tools/import_pga2005_effects.py). Particle counts,
/// speeds and lifetimes live in Engine.dll and are not decoded, so the motion
/// is a native approximation; every burst is short and small (≤ 150
/// particles) to stay cheap on the M1.
final class PGAOriginalEffects {
    private struct Manifest: Decodable {
        struct Mesh: Decodable { var meters_per_unit: Double; var positions: [Float]; var normals: [Float]; var uvs: [Float]; var indices: [UInt32] }
        var schema_version: Int
        var meshes: [String: Mesh]
    }

    private let sprites: [String: NSImage]
    private let meshes: [String: SCNGeometry]
    /// Divot marks stay for the rest of the hole, as in the original.
    private var marks: [SCNNode] = []
    let tee: SCNNode?

    init?(root: URL) {
        let directory = root.appendingPathComponent("Library/Imported/pga2005/effects", isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("effects.json")), data.count < 2_000_000,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.schema_version == 1 else { return nil }
        var sprites: [String: NSImage] = [:]
        for name in ["sand", "grass", "splash", "divot-mark", "divot"] {
            sprites[name] = NSImage(contentsOf: directory.appendingPathComponent("\(name).png"))
        }
        self.sprites = sprites
        var meshes: [String: SCNGeometry] = [:]
        for (name, mesh) in manifest.meshes {
            if let geometry = Self.geometry(mesh) { meshes[name] = geometry }
        }
        self.meshes = meshes
        if let peg = meshes["tee"]?.copy() as? SCNGeometry {
            let material = SCNMaterial()
            material.diffuse.contents = NSColor(calibratedWhite: 0.92, alpha: 1)
            material.lightingModel = .lambert
            peg.materials = [material]
            let node = SCNNode(geometry: peg)
            node.name = "Original tee peg"
            node.isHidden = true
            tee = node
        } else {
            tee = nil
        }
    }

    private static func geometry(_ mesh: Manifest.Mesh) -> SCNGeometry? {
        let count = mesh.positions.count / 3
        guard count > 0, mesh.normals.count == count * 3, mesh.uvs.count == count * 2,
              mesh.indices.allSatisfy({ Int($0) < count }) else { return nil }
        // Source meshes are left-handed like the course: mirror z and swap
        // the winding so faces stay outward in the right-handed scene.
        let k = Float(mesh.meters_per_unit)
        var positions = [SCNVector3](), normals = [SCNVector3](), uvs = [CGPoint]()
        for i in 0..<count {
            positions.append(SCNVector3(mesh.positions[i * 3] * k, mesh.positions[i * 3 + 1] * k, -mesh.positions[i * 3 + 2] * k))
            normals.append(SCNVector3(mesh.normals[i * 3], mesh.normals[i * 3 + 1], -mesh.normals[i * 3 + 2]))
            uvs.append(CGPoint(x: CGFloat(mesh.uvs[i * 2]), y: CGFloat(mesh.uvs[i * 2 + 1])))
        }
        var indices = [UInt32]()
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            indices += [mesh.indices[t], mesh.indices[t + 2], mesh.indices[t + 1]]
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals),
                                     SCNGeometrySource(textureCoordinates: uvs)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    /// Forget divot marks when a new hole's scene replaces the old one.
    func clearHole() { marks.forEach { $0.removeFromParentNode() }; marks.removeAll() }

    /// anim.stn "Ball impact" (event 3) rules for a strike.
    func strike(in parent: SCNNode, at ball: PGAVector, heading: Double, club: PGAClub, lieFlags: UInt32,
                powerPercent: Double, fromTee: Bool, ground: Double) {
        let forward = PGAVector(x: sin(heading), y: 0, z: cos(heading))
        let base = PGAVector(x: ball.x, y: ground, z: ball.z)
        if lieFlags & 0x8 != 0 {
            // Each original sand sprite is already a spray of grains, so a few
            // large particles read as a blast rather than a cloud.
            burst(in: parent, sprite: "sand", at: base, toward: forward, count: 20, speed: 3...7, spread: 55,
                  size: 0.12...0.26, life: 0.5...0.9, tint: NSColor(calibratedRed: 0.86, green: 0.79, blue: 0.62, alpha: 1))
        }
        if lieFlags & 0x2 != 0 && powerPercent > 10 {
            burst(in: parent, sprite: "grass", at: base, toward: forward, count: 10, speed: 2.5...6, spread: 55,
                  size: 0.035...0.06, life: 0.8...1.4, tint: .white)
        }
        let iron = PGAAudioRules.clubMask(club) & 0x4 != 0
        if iron && powerPercent > 75 && lieFlags & (0x1 | 0x1000 | 0x8000) != 0 {
            divot(in: parent, at: base, forward: forward)
        }
        let wood = PGAAudioRules.clubMask(club) & 0x3 != 0
        if fromTee && wood && powerPercent > 30, let tee, tee.parent != nil {
            // The tee peg is knocked forward and tumbles away.
            let flying = tee.clone()
            parent.addChildNode(flying)
            flying.position = tee.presentation.worldPosition
            flying.isHidden = false
            tee.isHidden = true
            fly(flying, velocity: forward * 4.5 + PGAVector(x: 0, y: 2.2, z: 0), spin: 18, life: 0.9, ground: ground)
        }
    }

    /// anim.stn "ball hits" (event 4) rules for a landing.
    func impact(in parent: SCNNode, at position: PGAVector, flags: UInt32, impactPercent: Double, incoming: PGAVector) {
        let base = PGAVector(x: position.x, y: position.y - PGASimulation.ballRadius, z: position.z)
        let along = incoming.horizontalUnit
        if flags & 0x40 != 0 && impactPercent > 20 {
            burst(in: parent, sprite: "splash", at: base, toward: along, count: 22, speed: 2.5...5.5, spread: 30,
                  size: 0.2...0.42, life: 0.6...1.0, tint: NSColor(calibratedRed: 0.9, green: 0.95, blue: 1, alpha: 1), upward: 0.85)
        } else if flags & 0x8 != 0 && impactPercent > 30 {
            burst(in: parent, sprite: "sand", at: base, toward: along, count: 12, speed: 1.2...3, spread: 50,
                  size: 0.12...0.22, life: 0.5...0.9, tint: NSColor(calibratedRed: 0.86, green: 0.79, blue: 0.62, alpha: 1), upward: 0.7)
        }
    }

    private func burst(in parent: SCNNode, sprite: String, at origin: PGAVector, toward forward: PGAVector, count: Int,
                       speed: ClosedRange<Double>, spread: Double, size: ClosedRange<Double>, life: ClosedRange<Double>,
                       tint: NSColor, upward: Double = 0.55) {
        guard let image = sprites[sprite] else { return }
        let system = SCNParticleSystem()
        system.particleImage = image
        system.birthRate = CGFloat(count) / 0.06
        system.emissionDuration = 0.06
        system.loops = false
        system.particleLifeSpan = CGFloat((life.lowerBound + life.upperBound) / 2)
        system.particleLifeSpanVariation = CGFloat((life.upperBound - life.lowerBound) / 2)
        system.particleVelocity = CGFloat((speed.lowerBound + speed.upperBound) / 2)
        system.particleVelocityVariation = CGFloat((speed.upperBound - speed.lowerBound) / 2)
        system.spreadingAngle = CGFloat(spread)
        system.particleSize = CGFloat((size.lowerBound + size.upperBound) / 2)
        system.particleSizeVariation = CGFloat((size.upperBound - size.lowerBound) / 2)
        system.particleAngleVariation = 180
        system.particleAngularVelocityVariation = 360
        system.particleColor = tint
        system.isAffectedByGravity = true
        system.acceleration = SCNVector3(0, -9.81, 0)
        system.blendMode = .alpha
        system.sortingMode = .none
        system.isLightingEnabled = false
        let fade = CAKeyframeAnimation()
        fade.values = [1, 1, 0]; fade.keyTimes = [0, 0.6, 1]
        system.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
        let direction = (forward * (1 - upward) + PGAVector(x: 0, y: upward, z: 0))
        system.emittingDirection = SCNVector3(direction.x, direction.y, direction.z)
        let node = SCNNode()
        node.position = SCNVector3(origin.x, origin.y + 0.02, origin.z)
        node.addParticleSystem(system)
        parent.addChildNode(node)
        node.runAction(.sequence([.wait(duration: life.upperBound + 0.2), .removeFromParentNode()]))
    }

    private func divot(in parent: SCNNode, at base: PGAVector, forward: PGAVector) {
        let side = PGAVector(x: -forward.z, y: 0, z: forward.x)
        let yaw = CGFloat(atan2(forward.x, forward.z))
        // The mark sits just in front of the ball, along the swing, for the rest of the hole.
        if let markImage = sprites["divot-mark"] {
            let plane = SCNPlane(width: 0.09, height: 0.18)
            let material = SCNMaterial()
            material.diffuse.contents = markImage
            material.lightingModel = .lambert
            material.blendMode = .alpha
            material.writesToDepthBuffer = false
            plane.materials = [material]
            let mark = SCNNode(geometry: plane)
            let spot = base + forward * 0.12
            mark.position = SCNVector3(spot.x, spot.y + 0.006, spot.z)
            mark.eulerAngles = SCNVector3(-CGFloat.pi / 2, yaw, 0)
            parent.addChildNode(mark)
            marks.append(mark)
            if marks.count > 24 { marks.removeFirst().removeFromParentNode() }
        }
        let name = ["divot1", "divot2", "divot3"][Int.random(in: 0..<3)]
        guard let chunk = meshes[name]?.copy() as? SCNGeometry else { return }
        let material = SCNMaterial()
        material.diffuse.contents = sprites["divot"]
        material.lightingModel = .lambert
        chunk.materials = [material]
        let node = SCNNode(geometry: chunk)
        let start = base + forward * 0.12
        node.position = SCNVector3(start.x, start.y + 0.01, start.z)
        node.eulerAngles.y = yaw
        parent.addChildNode(node)
        let kick = forward * Double.random(in: 3...4.5) + side * Double.random(in: -0.6...0.6) + PGAVector(x: 0, y: Double.random(in: 2.2...3.2), z: 0)
        fly(node, velocity: kick, spin: 9, life: 1.1, ground: base.y)
    }

    /// Simple ballistic tumble that lands on the start height and fades.
    private func fly(_ node: SCNNode, velocity: PGAVector, spin: Double, life: Double, ground: Double) {
        let start = PGAVector(node.position)
        let axis = SCNVector3(CGFloat.random(in: -1...1), 0.3, CGFloat.random(in: -1...1))
        let motion = SCNAction.customAction(duration: life) { node, elapsed in
            let t = Double(elapsed)
            var p = start + velocity * t
            p.y = max(ground + 0.01, start.y + velocity.y * t - 4.905 * t * t)
            node.position = SCNVector3(p.x, p.y, p.z)
            node.rotation = SCNVector4(axis.x, axis.y, axis.z, CGFloat(spin * min(t, 0.6)))
        }
        node.runAction(.sequence([motion, .fadeOut(duration: 0.4), .removeFromParentNode()]))
    }
}
