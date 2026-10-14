import AppKit
import SceneKit

/// Rain from the light- and heavy-rain presets (PGA2005-RENDER-PRESETS.md §6):
/// a drop pool of density × 10,000, drops spawned around the camera out to
/// rainDistance, falling at dropVelocity and drifting with the wind at
/// mph · 17.6 · 0.468 in/s, drawn as dropLength streaks in the preset colour.
/// The original's per-frame active count (pool · detail/4 modulated over
/// time, clamped to 1,000–10,000) is held at its mean, capped at 3,000
/// particles for the M1, and the ground ripples are omitted.
final class PGARain {
    let node = SCNNode()
    private var system: SCNParticleSystem?

    init() { node.name = "Original rain" }

    func use(_ rain: PGARenderState.Rain?, wind: PGAWind) {
        node.removeAllParticleSystems()
        system = nil
        guard let rain else { return }
        let k = PGACourseTransform.metersPerInch
        let distance = rain.distance * k, fall = rain.dropVelocity * k
        let windSpeed = wind.mph * 17.6 * 0.468 * k
        let drift = SIMD3<Double>(sin(wind.direction) * windSpeed, -fall, cos(wind.direction) * windSpeed)
        let speed = simd_length(drift)
        let pool = Double(Int(rain.density * 10_000))
        let count = min(3_000, max(1_000, pool * 0.45))
        let lifespan = distance * 1.5 / fall
        let particles = SCNParticleSystem()
        particles.emitterShape = SCNBox(width: distance * 2, height: 0.1, length: distance * 2, chamferRadius: 0)
        particles.birthLocation = .volume
        particles.birthRate = CGFloat(count / lifespan)
        particles.particleLifeSpan = CGFloat(lifespan)
        particles.emittingDirection = SCNVector3(drift.x / speed, drift.y / speed, drift.z / speed)
        particles.spreadingAngle = 0
        particles.particleVelocity = CGFloat(speed)
        particles.particleVelocityVariation = CGFloat(speed * 0.1)
        particles.particleSize = 0.006
        // Streak length dropLength along the motion, as the original's lines.
        particles.stretchFactor = CGFloat(rain.dropLength * k / speed)
        particles.particleColor = NSColor(srgbRed: CGFloat(rain.color.x), green: CGFloat(rain.color.y), blue: CGFloat(rain.color.z), alpha: 0.55)
        particles.particleColorVariation = SCNVector4(0, 0, 0, 0.3)
        particles.blendMode = .alpha
        particles.isLightingEnabled = false
        particles.isAffectedByGravity = false
        particles.sortingMode = .none
        particles.isLocal = false
        particles.warmupDuration = CGFloat(lifespan)
        node.position = SCNVector3(0, distance * 0.75, 0)
        node.addParticleSystem(particles)
        system = particles
    }
}
