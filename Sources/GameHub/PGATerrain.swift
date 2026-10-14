import Foundation

/// One floor query in simulation meters. `surface` selects the provisional
/// native physics; `lie` and `materialID` keep what the source data called it.
struct PGAGroundSample: Equatable {
    var height: Double
    var normal: PGAVector
    var surface: PGASurface
    var lie: String
    var materialID: UInt32?

    /// Height change per meter along x and z. Near-vertical source triangles
    /// are clamped so a cliff edge cannot produce an unbounded rolling force.
    var gradient: PGAVector {
        let y = max(normal.y, 0.2)
        return PGAVector(x: -normal.x / y, y: 0, z: -normal.z / y)
    }
}

/// Terrain seen by the simulation, independent of SceneKit and input devices.
/// Implementations are immutable after construction and may be shared by the
/// simulation, renderer and minimap.
protocol PGATerrainSampling: AnyObject {
    /// Highest floor at (x, z) whose height does not exceed `ceiling`; nil
    /// means the point lies outside the playable world for this hole.
    func ground(x: Double, z: Double, ceiling: Double) -> PGAGroundSample?
}

/// The generated practice holes, sampled from their analytic height field.
final class PGAProceduralTerrain: PGATerrainSampling {
    let hole: PGAHole
    init(hole: PGAHole) { self.hole = hole }

    func ground(x: Double, z: Double, ceiling: Double) -> PGAGroundSample? {
        guard x.isFinite, z.isFinite else { return nil }
        let surface = hole.surface(x: x, z: z)
        let gradient = hole.gradient(x: x, z: z)
        let normal = PGAVector(x: -gradient.x, y: 1, z: -gradient.z)
        return PGAGroundSample(height: hole.height(x: x, z: z), normal: normal * (1 / normal.length),
                               surface: surface, lie: surface.rawValue, materialID: nil)
    }
}
