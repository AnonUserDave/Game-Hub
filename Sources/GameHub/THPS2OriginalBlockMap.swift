import Foundation

/// Original PSX tag 0x0a spatial membership, retained separately from the
/// skating collision solver. Queries enumerate source object IDs only.
struct THPS2BlockMap {
    let minimumFixed24: SIMD2<Int32>
    let maximumFixed24: SIMD2<Int32>
    let width: Int
    let height: Int
    private let cells: [Range<Int>]
    private let references: [UInt32]
    var referenceCount: Int { references.count }

    init(data: Data, objectCount: Int) throws {
        guard data.count <= 64 * 1024 * 1024, objectCount >= 0, objectCount <= 100_000 else {
            throw THPS2PSX.LoadError.resourceLimit
        }
        func extent(_ p: Int, _ count: Int) throws {
            guard p >= 0, count >= 0, p <= data.count, count <= data.count - p else { throw THPS2PSX.LoadError.malformed }
        }
        func word(_ p: Int) throws -> UInt32 {
            try extent(p, 4)
            return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: p, as: UInt32.self)) }
        }
        try extent(0, 20)
        let lo = SIMD2(Int32(bitPattern: try word(0)), Int32(bitPattern: try word(4)))
        let hi = SIMD2(Int32(bitPattern: try word(8)), Int32(bitPattern: try word(12)))
        let width = Int(data[16]) | Int(data[17]) << 8, height = Int(data[18]) | Int(data[19]) << 8
        guard lo.x < hi.x, lo.y < hi.y, width > 0, height > 0, width * height <= 100_000 else {
            throw THPS2PSX.LoadError.malformed
        }
        var position = 20, refs: [UInt32] = [], cells: [Range<Int>] = []
        cells.reserveCapacity(width * height)
        for _ in 0..<(width * height) {
            try extent(position, 12)
            guard try word(position) == 0, try word(position + 4) == 0 else { throw THPS2PSX.LoadError.unsupported }
            let count = Int(try word(position + 8)); position += 12
            guard count <= 2_000_000 - refs.count else { throw THPS2PSX.LoadError.resourceLimit }
            try extent(position, count * 4 + 4)
            let first = refs.count
            for i in 0..<count {
                let object = try word(position + i * 4)
                guard object < objectCount else { throw THPS2PSX.LoadError.malformed }
                refs.append(object)
            }
            position += count * 4
            guard try word(position) == 0 else { throw THPS2PSX.LoadError.unsupported }
            position += 4
            cells.append(first..<refs.count)
        }
        guard position == data.count else { throw THPS2PSX.LoadError.malformed }
        minimumFixed24 = lo; maximumFixed24 = hi; self.width = width; self.height = height
        self.cells = cells; references = refs
    }

    func objectIndices(cellX: Int, cellZ: Int) -> ArraySlice<UInt32>? {
        guard cellX >= 0, cellX < width, cellZ >= 0, cellZ < height else { return nil }
        return references[cells[cellZ * width + cellX]]
    }

    /// Mathematical lookup in the source grid. Upper bounds are excluded;
    /// native solver edge handling has not been compared with the original.
    func candidates(xFixed24: Int32, zFixed24: Int32) -> ArraySlice<UInt32>? {
        guard xFixed24 >= minimumFixed24.x, xFixed24 < maximumFixed24.x,
              zFixed24 >= minimumFixed24.y, zFixed24 < maximumFixed24.y else { return nil }
        let x = (Int64(xFixed24) - Int64(minimumFixed24.x)) * Int64(width)
            / (Int64(maximumFixed24.x) - Int64(minimumFixed24.x))
        let z = (Int64(zFixed24) - Int64(minimumFixed24.y)) * Int64(height)
            / (Int64(maximumFixed24.y) - Int64(minimumFixed24.y))
        return objectIndices(cellX: Int(x), cellZ: Int(z))
    }
}
