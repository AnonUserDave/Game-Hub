import Foundation

/// Original THUG/THUG2 collision geometry prepared offline. This is an asset loader,
/// not a reconstruction of the original collision solver or skating physics.
/// Raw source axes and units are preserved deliberately.
struct SkateOriginalCollision {
    struct Object {
        let checksum: UInt32
        let flags: UInt32
        let vertices: Range<Int>
        let triangles: Range<Int>
    }
    struct Triangle {
        let indices: SIMD3<UInt32>
        let flags: UInt16
        let terrain: UInt16
    }
    enum LoadError: Error { case malformed, resourceLimit }

    private let data: Data
    let objects: [Object]
    let vertexCount: Int
    let triangleCount: Int
    private let vertexOffset: Int
    private let triangleOffset: Int
    let minimum: SIMD3<Float>
    let maximum: SIMD3<Float>

    init(url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber, number.uint64Value <= 64 * 1024 * 1024 else {
            throw LoadError.resourceLimit
        }
        try self.init(data: Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    init(data: Data) throws {
        guard data.count <= 64 * 1024 * 1024 else { throw LoadError.resourceLimit }
        guard data.count >= 20, Array(data.prefix(4)) == Array("GHSC".utf8), Self.u32(data, 4) == 1 else {
            throw LoadError.malformed
        }
        let count = Int(Self.u32(data, 8))
        let vertices = Int(Self.u32(data, 12))
        let triangles = Int(Self.u32(data, 16))
        guard count <= 100_000, vertices <= 2_000_000, triangles <= 4_000_000 else {
            throw LoadError.resourceLimit
        }
        let voffset = 20 + count * 24
        let toffset = voffset + vertices * 12
        guard toffset + triangles * 16 == data.count else { throw LoadError.malformed }
        var result: [Object] = []
        result.reserveCapacity(count)
        var nextVertex = 0, nextTriangle = 0
        for index in 0..<count {
            let offset = 20 + index * 24
            let startV = Int(Self.u32(data, offset + 8))
            let lengthV = Int(Self.u32(data, offset + 12))
            let startT = Int(Self.u32(data, offset + 16))
            let lengthT = Int(Self.u32(data, offset + 20))
            guard startV == nextVertex, startT == nextTriangle,
                  startV + lengthV <= vertices, startT + lengthT <= triangles else {
                throw LoadError.malformed
            }
            let object = Object(checksum: Self.u32(data, offset), flags: Self.u32(data, offset + 4),
                                vertices: startV..<(startV + lengthV), triangles: startT..<(startT + lengthT))
            for t in object.triangles {
                let offset = toffset + t * 16
                for corner in 0..<3 {
                    guard object.vertices.contains(Int(Self.u32(data, offset + corner * 4))) else {
                        throw LoadError.malformed
                    }
                }
            }
            result.append(object)
            nextVertex += lengthV
            nextTriangle += lengthT
        }
        guard nextVertex == vertices, nextTriangle == triangles else { throw LoadError.malformed }
        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = SIMD3<Float>(repeating: -.infinity)
        for index in 0..<vertices {
            let offset = voffset + index * 12
            let position = SIMD3<Float>(Float(bitPattern: Self.u32(data, offset)),
                                       Float(bitPattern: Self.u32(data, offset + 4)),
                                       Float(bitPattern: Self.u32(data, offset + 8)))
            for axis in 0..<3 {
                guard position[axis].isFinite else { throw LoadError.malformed }
                lo[axis] = min(lo[axis], position[axis])
                hi[axis] = max(hi[axis], position[axis])
            }
        }
        self.data = data
        objects = result
        vertexCount = vertices
        triangleCount = triangles
        vertexOffset = voffset
        triangleOffset = toffset
        minimum = vertices == 0 ? .zero : lo
        maximum = vertices == 0 ? .zero : hi
    }

    func vertex(at index: Int) -> SIMD3<Float>? {
        guard index >= 0, index < vertexCount else { return nil }
        let offset = vertexOffset + index * 12
        return SIMD3(Float(bitPattern: Self.u32(data, offset)),
                     Float(bitPattern: Self.u32(data, offset + 4)),
                     Float(bitPattern: Self.u32(data, offset + 8)))
    }

    func triangle(at index: Int) -> Triangle? {
        guard index >= 0, index < triangleCount else { return nil }
        let offset = triangleOffset + index * 16
        return Triangle(indices: SIMD3(Self.u32(data, offset), Self.u32(data, offset + 4), Self.u32(data, offset + 8)),
                        flags: Self.u16(data, offset + 12), terrain: Self.u16(data, offset + 14))
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
}
