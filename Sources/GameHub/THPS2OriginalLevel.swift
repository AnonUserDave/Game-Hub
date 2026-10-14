import Foundation
import CryptoKit

/// Bounded, mapped original THPS2 PSX v4 content. Source axes, integer units,
/// flags and extension bytes are retained; this is not a skating/script VM.
struct THPS2PSX {
    enum LoadError: Error { case malformed, resourceLimit, unsupported, identity }
    struct Object {
        let flags: UInt32
        let positionFixed24: SIMD3<Int32>
        let modelIndex: Int
        let unknown32: SIMD3<UInt32>
        let unknown16: UInt16
        let unknownXY: SIMD2<Int16>
        let palettePointer: Int
    }
    struct Model {
        let offset: Int
        let flags: UInt16
        let radiusFixed24: UInt32
        /// Source order: xmax, xmin, ymax, ymin, zmax, zmin.
        let bounds: [Int16]
        let unknown: UInt32
        let vertices: Range<Int>
        let planes: Range<Int>
        let faces: Range<Int>
        let vertexOffset: Int
        let planeOffset: Int
    }
    struct Face {
        let sourceOffset: Int
        let flags: UInt16
        let surfaceFlags: UInt16
        let indices: SIMD4<UInt8>
        /// Palette indices for gouraud faces; RGB + GPU command for flat faces.
        let colorBytes: SIMD4<UInt8>
        let plane: Int
        let textureIndex: Int?
        let uv: [SIMD2<UInt8>]?
        let extensionRange: Range<Int>
        var cornerCount: Int { flags & 0x10 == 0 ? 4 : 3 }
        var visible: Bool { flags & 0x80 == 0 }
    }
    struct Texture {
        let flags: UInt32
        let paletteName: UInt32
        let nameIndex: Int
        let colors: Int
        let width: Int
        let height: Int
        let storageWidth: Int
        let paletteOffset: Int
        let pixelOffset: Int
        let pixelCount: Int
    }
    struct Chunk { let type: UInt32; let range: Range<Int> }
    private let data: Data
    let objects: [Object]
    let models: [Model]
    let modelNames: [UInt32]
    let textureNames: [UInt32]
    let textures: [Texture]
    let chunks: [Chunk]
    let blockMaps: [THPS2BlockMap]
    let gouraudRange: Range<Int>?
    let vertexCount: Int
    let planeCount: Int
    let faceCount: Int
    private let faceOffsets: [Int]

    init(url: URL, sha256: String? = nil) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.uint64Value <= 64 * 1024 * 1024 else {
            throw LoadError.resourceLimit
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        if let sha256 {
            guard sha256.count == 64, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else {
                throw LoadError.identity
            }
        }
        try self.init(data: data)
    }

    init(data: Data) throws {
        guard data.count <= 64 * 1024 * 1024 else { throw LoadError.resourceLimit }
        let reader = THPS2Reader(data)
        guard try reader.u16(0) == 4, try reader.u16(2) == 2 else { throw LoadError.unsupported }
        let tagged = Int(try reader.u32(4))
        let no = try reader.count(8)
        var position = 12 + no * 36
        try reader.extent(12, no * 36)
        let nm = try reader.count(position)
        position += 4
        try reader.extent(position, nm * 4)
        let offsets = try (0..<nm).map { Int(try reader.u32(position + $0 * 4)) }
        position += nm * 4
        guard position <= tagged, tagged <= data.count - 4,
              Set(offsets).count == nm, offsets.allSatisfy({ $0 >= position && $0 < tagged }) else {
            throw LoadError.malformed
        }
        let sorted = offsets.sorted()
        let limits = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element, $0.offset + 1 < sorted.count ? sorted[$0.offset + 1] : tagged) })
        var models: [Model] = [], faces: [Int] = []
        var totalV = 0, totalP = 0
        models.reserveCapacity(nm)
        for offset in offsets {
            let end = limits[offset]!
            try reader.extent(offset, 28, end)
            let flags = try reader.u16(offset)
            let nv = Int(try reader.u16(offset + 2)), np = Int(try reader.u16(offset + 4)), nf = Int(try reader.u16(offset + 6))
            guard totalV + nv <= 2_000_000, totalP + np <= 2_000_000, faces.count + nf <= 2_000_000 else {
                throw LoadError.resourceLimit
            }
            let vo = offset + 28, po = vo + nv * 8
            try reader.extent(vo, (nv + np) * 8, end)
            var cursor = po + np * 8
            let firstF = faces.count
            for _ in 0..<nf {
                try reader.extent(cursor, 16, end)
                let f = try reader.u16(cursor), length = Int(try reader.u16(cursor + 2))
                guard length >= 16, length % 4 == 0 else { throw LoadError.malformed }
                try reader.extent(cursor, length, end)
                for corner in 0..<4 {
                    guard Int(data[cursor + 4 + corner]) < nv else { throw LoadError.malformed }
                }
                guard Int(try reader.u16(cursor + 12)) < np else { throw LoadError.malformed }
                let parsed = 16 + (f & 2 == 0 ? 0 : 4) + (f & 1 == 0 ? 0 : 8)
                guard parsed <= length else { throw LoadError.malformed }
                if f & 2 != 0, flags & 1 != 0 { throw LoadError.unsupported }
                faces.append(cursor)
                cursor += length
            }
            guard cursor == end else { throw LoadError.malformed }
            models.append(Model(offset: offset, flags: flags, radiusFixed24: try reader.u32(offset + 8),
                                bounds: try (0..<6).map { try reader.i16(offset + 12 + $0 * 2) }, unknown: try reader.u32(offset + 24),
                                vertices: totalV..<(totalV + nv), planes: totalP..<(totalP + np), faces: firstF..<faces.count,
                                vertexOffset: vo, planeOffset: po))
            totalV += nv; totalP += np
        }
        position = tagged
        var chunks: [Chunk] = [], palette: Range<Int>?
        while true {
            let type = try reader.u32(position); position += 4
            if type == UInt32.max { break }
            let size = Int(try reader.u32(position)); position += 4
            try reader.extent(position, size)
            guard chunks.count < 1024 else { throw LoadError.resourceLimit }
            let range = position..<(position + size)
            chunks.append(Chunk(type: type, range: range))
            if type == 0x73424752 {
                guard size > 0, size <= 1024, size % 4 == 0, palette == nil else { throw LoadError.malformed }
                palette = range
            }
            position += size
        }
        try reader.extent(position, nm * 4)
        let names = try (0..<nm).map { try reader.u32(position + $0 * 4) }; position += nm * 4
        let nt = try reader.count(position); position += 4
        try reader.extent(position, nt * 4)
        let textureNames = try (0..<nt).map { try reader.u32(position + $0 * 4) }; position += nt * 4
        var paletteOffsets: [Int: [UInt32: Int]] = [:]
        for colors in [16, 256] {
            let n = try reader.count(position); position += 4
            var entries: [UInt32: Int] = [:]
            for _ in 0..<n {
                let key = try reader.u32(position); position += 4
                guard entries[key] == nil else { throw LoadError.malformed }
                try reader.extent(position, colors * 2)
                entries[key] = position
                position += colors * 2
            }
            paletteOffsets[colors] = entries
        }
        let ntex = try reader.count(position); position += 4
        try reader.extent(position, ntex * 4)
        let texOffsets = try (0..<ntex).map { Int(try reader.u32(position + $0 * 4)) }; position += ntex * 4
        var textures: [Texture] = [], pixelCount = 0
        for offset in texOffsets {
            guard offset == position else { throw LoadError.malformed }
            try reader.extent(offset, 20)
            let colors = Int(try reader.u32(offset + 4)), key = try reader.u32(offset + 8)
            let ni = Int(try reader.u32(offset + 12)), width = Int(try reader.u16(offset + 16)), height = Int(try reader.u16(offset + 18))
            guard [16, 256].contains(colors), width > 0, height > 0, width <= 2048, height <= 2048, ni < nt else {
                throw LoadError.unsupported
            }
            guard let po = paletteOffsets[colors]?[key] else { throw LoadError.malformed }
            let alignment = colors == 16 ? 4 : 2
            let storageWidth = (width + alignment - 1) & -alignment
            pixelCount += storageWidth * height
            guard pixelCount <= 8_000_000 else { throw LoadError.resourceLimit }
            let size = storageWidth * height / (colors == 16 ? 2 : 1)
            try reader.extent(offset + 20, size)
            textures.append(Texture(flags: try reader.u32(offset), paletteName: key, nameIndex: ni, colors: colors,
                                    width: width, height: height, storageWidth: storageWidth, paletteOffset: po,
                                    pixelOffset: offset + 20, pixelCount: size))
            position += 20 + size
        }
        guard position == data.count else { throw LoadError.malformed }
        var objects: [Object] = []
        objects.reserveCapacity(no)
        for i in 0..<no {
            let offset = 12 + i * 36
            let model = Int(try reader.u16(offset + 22)), palettePointer = Int(try reader.u32(offset + 32))
            guard model < nm else { throw LoadError.malformed }
            if palettePointer != 0 { try reader.extent(palettePointer, 4) }
            objects.append(Object(flags: try reader.u32(offset),
                                  positionFixed24: SIMD3(try reader.i32(offset + 4), try reader.i32(offset + 8), try reader.i32(offset + 12)),
                                  modelIndex: model, unknown32: SIMD3(try reader.u32(offset + 16), try reader.u32(offset + 28), UInt32(palettePointer)),
                                  unknown16: try reader.u16(offset + 20), unknownXY: SIMD2(try reader.i16(offset + 24), try reader.i16(offset + 26)),
                                  palettePointer: palettePointer))
        }
        for offset in faces {
            let flags = try reader.u16(offset)
            if flags & 2 != 0 {
                guard Int(try reader.u32(offset + 16)) < nt else { throw LoadError.malformed }
            }
            if flags & 0x800 != 0 {
                guard let palette else { throw LoadError.malformed }
                for i in 0..<(flags & 0x10 == 0 ? 4 : 3) {
                    guard Int(data[offset + 8 + i]) * 4 + 4 <= palette.count else { throw LoadError.malformed }
                }
            }
        }
        blockMaps = try chunks.filter { $0.type == 10 }.map {
            try THPS2BlockMap(data: data.subdata(in: $0.range), objectCount: no)
        }
        self.data = data
        self.objects = objects; self.models = models; modelNames = names
        self.textureNames = textureNames; self.textures = textures; self.chunks = chunks
        gouraudRange = palette; vertexCount = totalV; planeCount = totalP; faceCount = faces.count; faceOffsets = faces
    }

    func vertex(model: Int, index: Int) -> SIMD4<Int16>? {
        guard models.indices.contains(model), index >= 0, index < models[model].vertices.count else { return nil }
        let p = models[model].vertexOffset + index * 8
        return SIMD4(i16(p), i16(p + 2), i16(p + 4), i16(p + 6))
    }
    func plane(model: Int, index: Int) -> SIMD4<Int16>? {
        guard models.indices.contains(model), index >= 0, index < models[model].planes.count else { return nil }
        let p = models[model].planeOffset + index * 8
        return SIMD4(i16(p), i16(p + 2), i16(p + 4), i16(p + 6))
    }
    func face(model: Int, index: Int) -> Face? {
        guard models.indices.contains(model), index >= 0, index < models[model].faces.count else { return nil }
        let p = faceOffsets[models[model].faces.lowerBound + index], flags = u16(p)
        var cursor = p + 16
        let ti: Int? = flags & 2 == 0 ? nil : Int(u32(cursor))
        if ti != nil { cursor += 4 }
        var uv: [SIMD2<UInt8>]?
        if flags & 1 != 0 {
            uv = (0..<4).map { SIMD2(data[cursor + $0 * 2], data[cursor + $0 * 2 + 1]) }
            cursor += 8
        }
        return Face(sourceOffset: p, flags: flags, surfaceFlags: u16(p + 14),
                    indices: SIMD4(data[p + 4], data[p + 5], data[p + 6], data[p + 7]),
                    colorBytes: SIMD4(data[p + 8], data[p + 9], data[p + 10], data[p + 11]), plane: Int(u16(p + 12)),
                    textureIndex: ti, uv: uv, extensionRange: cursor..<(p + Int(u16(p + 2))))
    }
    func sourceWorldPosition(object: Int, vertex: Int) -> SIMD3<Double>? {
        guard objects.indices.contains(object), let v = self.vertex(model: objects[object].modelIndex, index: vertex) else { return nil }
        let o = objects[object].positionFixed24
        return SIMD3(Double(o.x) / 16_777_216 + Double(v.x) / 4096,
                     Double(o.y) / 16_777_216 + Double(v.y) / 4096,
                     Double(o.z) / 16_777_216 + Double(v.z) / 4096)
    }
    func gouraudColor(_ index: UInt8) -> SIMD4<UInt8>? {
        guard let palette = gouraudRange, Int(index) * 4 + 4 <= palette.count else { return nil }
        let p = palette.lowerBound + Int(index) * 4
        return SIMD4(data[p], data[p + 1], data[p + 2], data[p + 3])
    }
    func sourceBytes(in range: Range<Int>) -> Data? {
        guard range.lowerBound >= 0, range.upperBound <= data.count else { return nil }
        return data.subdata(in: range)
    }
    /// Zero-valued palette entry is transparent. Nonzero entries are opaque;
    /// source STP/add/subtract blending is retained but not reconstructed here.
    func rgba(texture index: Int) -> Data? {
        guard textures.indices.contains(index) else { return nil }
        let t = textures[index]
        var palette: [SIMD4<UInt8>] = []
        for i in 0..<t.colors {
            let value = u16(t.paletteOffset + i * 2)
            palette.append(SIMD4(UInt8((value & 31) * 255 / 31), UInt8(((value >> 5) & 31) * 255 / 31),
                                 UInt8(((value >> 10) & 31) * 255 / 31), value == 0 ? 0 : 255))
        }
        var out = Data(count: t.width * t.height * 4)
        out.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for y in 0..<t.height {
                for x in 0..<t.width {
                    let pixel = y * t.storageWidth + x
                    let index: Int
                    if t.colors == 16 { index = Int((data[t.pixelOffset + pixel / 2] >> ((pixel & 1) * 4)) & 15) }
                    else { index = Int(data[t.pixelOffset + pixel]) }
                    let c = palette[index], p = (y * t.width + x) * 4
                    bytes[p] = c.x; bytes[p + 1] = c.y; bytes[p + 2] = c.z; bytes[p + 3] = c.w
                }
            }
        }
        return out
    }
    private func u16(_ p: Int) -> UInt16 { data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: p, as: UInt16.self)) } }
    private func i16(_ p: Int) -> Int16 { Int16(bitPattern: u16(p)) }
    private func u32(_ p: Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: p, as: UInt32.self)) } }
}

/// TRG records are mapped independently. Restart/rail/link fields are decoded;
/// the remaining command/actor payload bytes stay source addressed, never run.
struct THPS2TRG {
    struct Node {
        let type: UInt16
        let range: Range<Int>
        let links: [UInt16]
        let positionFixed12: SIMD3<Int32>?
        let parameters: [UInt16]
        let name: String?
        let objectChecksum: UInt32?
        let undecoded: Range<Int>
    }
    private let data: Data
    let nodes: [Node]
    init(url: URL, sha256: String? = nil) throws {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard let size, size.uint64Value <= 64 * 1024 * 1024 else { throw THPS2PSX.LoadError.resourceLimit }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        if let sha256 {
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else { throw THPS2PSX.LoadError.identity }
        }
        try self.init(data: data)
    }
    init(data: Data) throws {
        guard data.count <= 64 * 1024 * 1024 else { throw THPS2PSX.LoadError.resourceLimit }
        let r = THPS2Reader(data)
        guard try r.u32(0) == 0x4752545f, try r.u32(4) == 2 else { throw THPS2PSX.LoadError.unsupported }
        let n = try r.count(8)
        guard n > 0 else { throw THPS2PSX.LoadError.malformed }
        try r.extent(12, n * 4)
        let offsets = try (0..<n).map { Int(try r.u32(12 + $0 * 4)) }
        guard offsets[0] == 12 + n * 4, offsets.last == data.count - 2,
              zip(offsets, offsets.dropFirst()).allSatisfy({ $0.0 < $0.1 }), try r.u16(data.count - 2) == 255 else {
            throw THPS2PSX.LoadError.malformed
        }
        var nodes: [Node] = []
        for (i, start) in offsets.enumerated() {
            let end = i + 1 < n ? offsets[i + 1] : data.count
            try r.extent(start, 2, end)
            let type = try r.u16(start)
            var pos = start + 2, links: [UInt16] = [], position: SIMD3<Int32>?, parameters: [UInt16] = [], name: String?, checksum: UInt32?
            if [3, 6, 8, 10, 11, 12, 14].contains(type) {
                try r.extent(pos, 2, end)
                let count = Int(try r.u16(pos)); pos += 2
                try r.extent(pos, count * 2, end)
                links = try (0..<count).map { try r.u16(pos + $0 * 2) }; pos += count * 2
                guard links.allSatisfy({ $0 < n }) else { throw THPS2PSX.LoadError.malformed }
                pos = (pos + 3) & ~3
                if [3, 8, 10, 11].contains(type) {
                    try r.extent(pos, 12, end)
                    position = SIMD3(try r.i32(pos), try r.i32(pos + 4), try r.i32(pos + 8)); pos += 12
                    if [8, 10, 11].contains(type) {
                        let count = type == 8 ? 3 : 1
                        try r.extent(pos, count * 2, end)
                        parameters = try (0..<count).map { try r.u16(pos + $0 * 2) }; pos += count * 2
                    }
                    if type == 8 {
                        let begin = pos
                        while pos < end && data[pos] != 0 && pos - begin <= 256 { pos += 1 }
                        guard pos < end, pos - begin <= 256, let decoded = String(data: data.subdata(in: begin..<pos), encoding: .ascii) else {
                            throw THPS2PSX.LoadError.malformed
                        }
                        name = decoded
                        pos = (pos + 2) & ~1
                    }
                } else {
                    try r.extent(pos, 4, end)
                    checksum = try r.u32(pos); pos += 4
                }
            } else if type == 13 {
                try r.extent(pos, 2, end)
                links = [try r.u16(pos)]; pos = (pos + 5) & ~3
                try r.extent(pos, 16, end)
                position = SIMD3(try r.i32(pos), try r.i32(pos + 4), try r.i32(pos + 8)); pos += 12
                parameters = [try r.u16(pos), try r.u16(pos + 2)]; pos += 4
            }
            guard pos <= end else { throw THPS2PSX.LoadError.malformed }
            nodes.append(Node(type: type, range: start..<end, links: links, positionFixed12: position,
                              parameters: parameters, name: name, objectChecksum: checksum, undecoded: pos..<end))
        }
        self.data = data; self.nodes = nodes
    }
    func sourcePayload(node: Int) -> Data? {
        guard nodes.indices.contains(node) else { return nil }
        return data.subdata(in: nodes[node].undecoded)
    }
}

private struct THPS2Reader {
    let data: Data
    init(_ data: Data) { self.data = data }
    func extent(_ offset: Int, _ size: Int, _ limit: Int? = nil) throws {
        guard offset >= 0, size >= 0, offset <= min(limit ?? data.count, data.count),
              size <= min(limit ?? data.count, data.count) - offset else { throw THPS2PSX.LoadError.malformed }
    }
    func u16(_ offset: Int) throws -> UInt16 {
        try extent(offset, 2)
        return data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }
    func i16(_ offset: Int) throws -> Int16 { Int16(bitPattern: try u16(offset)) }
    func u32(_ offset: Int) throws -> UInt32 {
        try extent(offset, 4)
        return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
    func i32(_ offset: Int) throws -> Int32 { Int32(bitPattern: try u32(offset)) }
    func count(_ offset: Int) throws -> Int {
        let count = Int(try u32(offset))
        guard count <= 100_000 else { throw THPS2PSX.LoadError.resourceLimit }
        return count
    }
}

/// Explicitly selected original scene and texture variants prepared offline.
/// Loads at most three source layers; no global content/texture cache exists.
struct THPS2OriginalLevel {
    struct Receipt: Decodable {
        struct Layer: Decodable { let role: String; let path: String; let sha256: String }
        struct Trigger: Decodable { let path: String; let sha256: String; let nodes: Int }
        struct Image: Decodable {
            let kind: String
            let sourcePath: String
            let sourceSha256: String
            let path: String
            let width: Int
            let height: Int
            let sha256: String
            let nameIndex: Int?
        }
        let schema: Int
        let title: String
        let sceneStem: String
        let layers: [Layer]
        let trigger: Trigger
        let textures: [String: [Image]]
    }
    struct Layer { let role: String; let path: String; let content: THPS2PSX }
    let receipt: Receipt
    let layers: [Layer]
    let triggers: THPS2TRG
    let preparedRoot: URL
    let originalRoot: URL

    init(originalRoot: URL, preparedRoot: URL) throws {
        let url = preparedRoot.appendingPathComponent("level.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs[.size] as? NSNumber, size.uint64Value <= 1024 * 1024 else { throw THPS2PSX.LoadError.resourceLimit }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let receipt = try decoder.decode(Receipt.self, from: Data(contentsOf: url))
        guard receipt.schema == 1, receipt.title == "thps2", !receipt.layers.isEmpty, receipt.layers.count <= 3,
              receipt.layers.filter({ $0.role == "level" }).count == 1,
              receipt.layers.filter({ $0.role == "texture-library" }).count <= 1,
              Set(receipt.layers.map(\.role)).count == receipt.layers.count,
              receipt.layers.allSatisfy({ ["level", "texture-library", "objects"].contains($0.role) }),
              receipt.textures.count <= 4096 else { throw THPS2PSX.LoadError.malformed }
        var totalSourceBytes: UInt64 = 0
        func source(_ path: String) throws -> URL {
            let url = try Self.child(root: originalRoot, path: path)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attrs[.size] as? NSNumber else { throw THPS2PSX.LoadError.malformed }
            totalSourceBytes += size.uint64Value
            guard totalSourceBytes <= 64 * 1024 * 1024 else { throw THPS2PSX.LoadError.resourceLimit }
            return url
        }
        var layers: [Layer] = []
        for layer in receipt.layers {
            let url = try source(layer.path)
            let decoded = try THPS2PSX(url: url, sha256: layer.sha256)
            if layer.role == "texture-library", !decoded.objects.isEmpty || !decoded.models.isEmpty {
                throw THPS2PSX.LoadError.malformed
            }
            layers.append(Layer(role: layer.role, path: layer.path, content: decoded))
        }
        let triggers = try THPS2TRG(url: source(receipt.trigger.path), sha256: receipt.trigger.sha256)
        guard triggers.nodes.count == receipt.trigger.nodes else { throw THPS2PSX.LoadError.malformed }
        var pixels = 0
        for (key, images) in receipt.textures {
            guard key.count == 8, UInt32(key, radix: 16) != nil, images.count <= 8 else { throw THPS2PSX.LoadError.malformed }
            for image in images {
                guard image.width > 0, image.height > 0, image.width <= 2048, image.height <= 2048,
                      image.sha256.count == 64, image.sourceSha256.count == 64,
                      ["psx-paletted", "pc-bmp"].contains(image.kind) else { throw THPS2PSX.LoadError.malformed }
                pixels += image.width * image.height
                guard pixels <= 8_000_000 else { throw THPS2PSX.LoadError.resourceLimit }
                _ = try Self.child(root: preparedRoot, path: image.path)
                _ = try Self.child(root: originalRoot, path: image.sourcePath)
            }
        }
        self.receipt = receipt; self.layers = layers; self.triggers = triggers
        self.preparedRoot = preparedRoot; self.originalRoot = originalRoot
    }

    static func child(root: URL, path: String) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw THPS2PSX.LoadError.malformed
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let child = base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard child.path.hasPrefix(base.path + "/") else { throw THPS2PSX.LoadError.malformed }
        return child
    }
}
