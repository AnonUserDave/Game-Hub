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
    private let vertexOffset: Int
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
    /// `selection` restricts the index to the given source triangles, such as
    /// one hole's patches; bounds then come from those triangles alone.
    init(data: Data, cellSize: Double = 512, selection: [UInt32]? = nil) throws {
        guard data.count >= 44, data.prefix(4).elementsEqual([0x47, 0x48, 0x50, 0x43]),
              cellSize.isFinite, cellSize >= 16 else { throw LoadError.invalid("Expected bounded GHPC v2 or v3 terrain.") }
        let built = try data.withUnsafeBytes { bytes -> (Int, Int, Int, Int, Int, Double, Double, Double, Double, [Int: [UInt32]], Int) in
            func u32(_ offset: Int) -> UInt32 { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            func f32(_ offset: Int) -> Double { Double(Float(bitPattern: u32(offset))) }
            let version = u32(4)
            guard version == 2 || version == 3 else { throw LoadError.invalid("Triangle collisions require GHPC v2 or v3.") }
            let header = version == 3 ? 48 : 44
            let vertices = Int(u32(8)), triangles = Int(u32(12))
            let patches = version == 3 && data.count >= 48 ? Int(u32(44)) : 0
            guard vertices > 0, vertices <= 2_000_000, triangles > 0, triangles <= 4_000_000, patches <= 100_000,
                  data.count == header + vertices * 24 + triangles * 16 + patches * 20 else { throw LoadError.invalid("Invalid terrain record counts.") }
            let start = header + vertices * 24
            func point(_ index: UInt32) -> (Double, Double, Double) {
                let position = header + Int(index) * 24
                return (f32(position), f32(position + 4), f32(position + 8))
            }
            var minX = f32(20), minZ = f32(28), maxX = f32(32), maxZ = f32(40)
            if let selection {
                guard !selection.isEmpty, selection.count <= triangles else { throw LoadError.invalid("Empty or oversized triangle selection.") }
                minX = .infinity; minZ = .infinity; maxX = -.infinity; maxZ = -.infinity
                for triangle in selection {
                    guard Int(triangle) < triangles else { throw LoadError.invalid("Selected triangle is outside the source.") }
                    for corner in 0..<3 {
                        let index = u32(start + Int(triangle) * 16 + corner * 4)
                        guard Int(index) < vertices else { throw LoadError.invalid("Invalid source triangle index.") }
                        let p = point(index)
                        minX = min(minX, p.0); maxX = max(maxX, p.0); minZ = min(minZ, p.2); maxZ = max(maxZ, p.2)
                    }
                }
            }
            guard [minX, minZ, maxX, maxZ].allSatisfy(\.isFinite), maxX > minX, maxZ > minZ else {
                throw LoadError.invalid("Invalid collision bounds.")
            }
            let colsDouble = ceil((maxX - minX) / cellSize), rowsDouble = ceil((maxZ - minZ) / cellSize)
            guard colsDouble <= 4096, rowsDouble <= 4096, colsDouble * rowsDouble <= 1_000_000 else {
                throw LoadError.invalid("Collision grid exceeds its resource bound.")
            }
            let cols = max(1, Int(colsDouble)), rows = max(1, Int(rowsDouble))
            var cells: [Int: [UInt32]] = [:]
            var references = 0
            let count = selection?.count ?? triangles
            for item in 0..<count {
                if item % 65_536 == 0 { try Task.checkCancellation() }
                let triangle = selection.map { Int($0[item]) } ?? item
                let offset = start + triangle * 16
                let indices = [u32(offset), u32(offset + 4), u32(offset + 8)]
                guard indices.allSatisfy({ $0 < vertices }), Set(indices).count == 3 else {
                    throw LoadError.invalid("Invalid source triangle index.")
                }
                let points = indices.map(point)
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
            return (header, vertices, count, cols, rows, minX, minZ, maxX, maxZ, cells, references)
        }
        self.data = data
        vertexOffset = built.0; vertexCount = built.1; triangleCount = built.2
        triangleOffset = built.0 + built.1 * 24
        columns = built.3; rows = built.4
        minimumX = built.5; minimumZ = built.6; maximumX = built.7; maximumZ = built.8
        cells = built.9; indexedReferences = built.10
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
                let offset = vertexOffset + Int(index) * 24
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
