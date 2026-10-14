import Foundation

/// Exact triangle queries over the decoded primary course mesh. This supplies
/// geometry and original material IDs; it does not claim original ball-physics
/// parity or assign an unverified meaning to a material's numeric coefficients.
final class PGAOriginalCollision: @unchecked Sendable {
    struct Hit: Equatable {
        let rawHeight: Double
        let normal: PGAVector
        let terrainID: UInt32
        let triangle: UInt32
    }

    enum LoadError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
    }

    private let data: Data
    private let triangleOffset: Int
    private let vertexCount: Int
    private let columns: Int
    private let rows: Int
    private let cellSize: Double
    private let minimumX: Double
    private let minimumZ: Double
    private let maximumX: Double
    private let maximumZ: Double
    private let cells: [Int: [UInt32]]
    let triangleCount: Int
    let indexedReferences: Int

    /// Initialization is intentionally synchronous and should run on a worker.
    /// Once built, the immutable index may be shared by rendering and simulation.
    init(data: Data, cellSize: Double = 512) throws {
        guard data.count >= 44, data.prefix(4).elementsEqual([0x47, 0x48, 0x50, 0x43]),
              cellSize.isFinite, cellSize >= 16 else { throw LoadError.invalid("Expected bounded GHPC v2 terrain.") }
        let built = try data.withUnsafeBytes { bytes -> (Int, Int, Int, Int, Double, Double, Double, Double, [Int: [UInt32]], Int) in
            func u32(_ offset: Int) -> UInt32 { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            func f32(_ offset: Int) -> Double { Double(Float(bitPattern: u32(offset))) }
            guard u32(4) == 2 else { throw LoadError.invalid("Triangle collisions require GHPC v2.") }
            let vertices = Int(u32(8)), triangles = Int(u32(12))
            guard vertices > 0, vertices <= 2_000_000, triangles > 0, triangles <= 4_000_000,
                  data.count == 44 + vertices * 24 + triangles * 16 else { throw LoadError.invalid("Invalid terrain record counts.") }
            let minX = f32(20), minZ = f32(28), maxX = f32(32), maxZ = f32(40)
            guard [minX, minZ, maxX, maxZ].allSatisfy(\.isFinite), maxX > minX, maxZ > minZ else {
                throw LoadError.invalid("Invalid collision bounds.")
            }
            let colsDouble = ceil((maxX - minX) / cellSize), rowsDouble = ceil((maxZ - minZ) / cellSize)
            guard colsDouble <= 4096, rowsDouble <= 4096, colsDouble * rowsDouble <= 1_000_000 else {
                throw LoadError.invalid("Collision grid exceeds its resource bound.")
            }
            let cols = max(1, Int(colsDouble)), rows = max(1, Int(rowsDouble))
            let start = 44 + vertices * 24
            var cells: [Int: [UInt32]] = [:]
            var references = 0
            for triangle in 0..<triangles {
                if triangle % 65_536 == 0 { try Task.checkCancellation() }
                let offset = start + triangle * 16
                let indices = [u32(offset), u32(offset + 4), u32(offset + 8)]
                guard indices.allSatisfy({ $0 < vertices }), Set(indices).count == 3 else {
                    throw LoadError.invalid("Invalid source triangle index.")
                }
                let points = indices.map { index -> (Double, Double, Double) in
                    let position = 44 + Int(index) * 24
                    return (f32(position), f32(position + 4), f32(position + 8))
                }
                guard points.allSatisfy({ $0.0.isFinite && $0.1.isFinite && $0.2.isFinite }) else {
                    throw LoadError.invalid("Collision vertex is not finite.")
                }
                let xs = points.map(\.0), zs = points.map(\.2)
                let lowX = xs.min()!, highX = xs.max()!, lowZ = zs.min()!, highZ = zs.max()!
                guard lowX >= minX - 1, highX <= maxX + 1, lowZ >= minZ - 1, highZ <= maxZ + 1 else {
                    throw LoadError.invalid("Collision vertex exceeds declared course bounds.")
                }
                let col0 = max(0, min(cols - 1, Int(floor((lowX - minX) / cellSize))))
                let col1 = max(0, min(cols - 1, Int(floor((highX - minX) / cellSize))))
                let row0 = max(0, min(rows - 1, Int(floor((lowZ - minZ) / cellSize))))
                let row1 = max(0, min(rows - 1, Int(floor((highZ - minZ) / cellSize))))
                references += (col1 - col0 + 1) * (row1 - row0 + 1)
                guard references <= 32_000_000 else { throw LoadError.invalid("Collision index exceeds 32 million references.") }
                for row in row0...row1 {
                    for column in col0...col1 { cells[row * cols + column, default: []].append(UInt32(triangle)) }
                }
            }
            return (vertices, triangles, cols, rows, minX, minZ, maxX, maxZ, cells, references)
        }
        self.data = data
        vertexCount = built.0; triangleCount = built.1
        triangleOffset = 44 + built.0 * 24
        columns = built.2; rows = built.3
        minimumX = built.4; minimumZ = built.5; maximumX = built.6; maximumZ = built.7
        cells = built.8; indexedReferences = built.9
        self.cellSize = cellSize
    }

    /// Vertical intersection against original triangles; no heightfield sampling.
    /// maximumHeight can exclude surfaces above a moving ball, such as a roof.
    func sample(rawX x: Double, rawZ z: Double, maximumHeight: Double = .infinity) -> Hit? {
        guard x.isFinite, z.isFinite, !maximumHeight.isNaN,
              x >= minimumX, x <= maximumX, z >= minimumZ, z <= maximumZ else { return nil }
        let column = min(columns - 1, max(0, Int(floor((x - minimumX) / cellSize))))
        let row = min(rows - 1, max(0, Int(floor((z - minimumZ) / cellSize))))
        guard let candidates = cells[row * columns + column] else { return nil }
        return data.withUnsafeBytes { bytes in
            func uint(_ offset: Int) -> UInt32 { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            func point(_ index: UInt32) -> PGAVector {
                let offset = 44 + Int(index) * 24
                return PGAVector(x: Double(Float(bitPattern: uint(offset))), y: Double(Float(bitPattern: uint(offset + 4))), z: Double(Float(bitPattern: uint(offset + 8))))
            }
            var best: Hit?
            for triangle in candidates {
                let offset = triangleOffset + Int(triangle) * 16
                let a = point(uint(offset)), b = point(uint(offset + 4)), c = point(uint(offset + 8))
                let denominator = (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
                guard abs(denominator) > 1e-10 else { continue }
                let u = ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / denominator
                let v = ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / denominator
                let w = 1 - u - v
                guard u >= -1e-8, v >= -1e-8, w >= -1e-8 else { continue }
                let height = u * a.y + v * b.y + w * c.y
                guard height <= maximumHeight, best == nil || height > best!.rawHeight else { continue }
                let p = b - a, q = c - a
                var normal = PGAVector(x: p.y * q.z - p.z * q.y, y: p.z * q.x - p.x * q.z, z: p.x * q.y - p.y * q.x)
                if normal.y < 0 { normal = normal * -1 }
                let length = normal.length
                if length > 0 { normal = normal * (1 / length) }
                best = Hit(rawHeight: height, normal: normal, terrainID: uint(offset + 12), triangle: triangle)
            }
            return best
        }
    }
}
