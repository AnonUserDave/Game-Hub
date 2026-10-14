import XCTest
import SceneKit
@testable import GameHub

final class THPS2OriginalLevelTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func fixture() -> Data {
        var data = Data()
        func u16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func i16(_ n: Int16) { u16(UInt16(bitPattern: n)) }
        u16(4); u16(2); u32(0); u32(1)
        for n: UInt32 in [0x42, 16777216, UInt32(bitPattern: -8388608), 0, 0] { u32(n) }
        u16(0); u16(0); i16(0); i16(0); u32(0); u32(0)
        u32(1); u32(56)
        [8, 3, 1, 1].forEach { u16(UInt16($0)) }; u32(16777216)
        [4096, 0, 4096, 0, 0, 0].forEach { i16(Int16($0)) }; u32(0xffff7fff)
        for n: Int16 in [0, 0, 0, 0, 4096, 0, 0, 0, 0, 4096, 0, 0] { i16(n) }
        [0, 0, -4096, 0].forEach { i16(Int16($0)) }
        u16(0x1813); u16(28); data.append(contentsOf: [0, 1, 2, 0, 0, 1, 2, 0]); u16(0); u16(0x10); u32(0)
        data.append(contentsOf: [0, 0, 3, 0, 0, 2, 0, 0])
        var tag = UInt32(data.count).littleEndian
        withUnsafeBytes(of: &tag) { data.replaceSubrange(4..<8, with: $0) }
        u32(0x73424752); u32(12); data.append(contentsOf: [128, 128, 128, 0, 255, 0, 0, 0, 0, 255, 0, 0])
        u32(UInt32.max); u32(0x12345678); u32(1); u32(0xa5cf46b6)
        u32(1); u32(0xa5cf46b6)
        u16(0); u16(0x001f); u16(0x03e0); for _ in 0..<13 { u16(0x8000) }
        u32(0); u32(1); u32(UInt32(data.count + 4))
        u32(0); u32(16); u32(0xa5cf46b6); u32(0); u16(3); u16(3)
        data.append(contentsOf: [0x10, 0x32, 0x10, 0x32, 0x10, 0x32])
        return data
    }
    private func triggers() -> Data {
        var out = Data("_TRG".utf8)
        func put<T: FixedWidthInteger>(_ n: T) { var n = n.littleEndian; withUnsafeBytes(of: &n) { out.append(contentsOf: $0) } }
        put(UInt32(2)); put(UInt32(2)); put(UInt32(20)); put(UInt32(50))
        put(UInt16(8)); put(UInt16(0)); put(Int32(4096)); put(Int32(-4096)); put(Int32(8192))
        put(UInt16(0)); put(UInt16(512)); put(UInt16(0)); out.append(contentsOf: Array("Start\0".utf8)); put(UInt16.max)
        put(UInt16(255))
        return out
    }

    func testSourceFieldsFixedPointColorAndOddTextureHeight() throws {
        let source = try THPS2PSX(data: fixture())
        XCTAssertEqual(source.objects[0].flags, 0x42)
        XCTAssertEqual(source.objects[0].positionFixed24, SIMD3(16777216, -8388608, 0))
        XCTAssertEqual(source.sourceWorldPosition(object: 0, vertex: 1), SIMD3<Double>(2, -0.5, 0))
        let face = try XCTUnwrap(source.face(model: 0, index: 0))
        XCTAssertEqual(face.flags, 0x1813); XCTAssertEqual(face.surfaceFlags, 0x10)
        XCTAssertEqual(face.uv, [SIMD2(0, 0), SIMD2(3, 0), SIMD2(0, 2), SIMD2(0, 0)])
        XCTAssertEqual(source.gouraudColor(1), SIMD4<UInt8>(255, 0, 0, 0))
        let rgba = try XCTUnwrap(source.rgba(texture: 0))
        XCTAssertEqual(rgba.count, 36)
        XCTAssertEqual(Array(rgba.prefix(12)), [0, 0, 0, 0, 255, 0, 0, 255, 0, 255, 0, 255])
        XCTAssertEqual(rgba.subdata(in: 0..<12), rgba.subdata(in: 12..<24))
        XCTAssertNil(source.face(model: 0, index: 1)); XCTAssertNil(source.vertex(model: -1, index: 0))
    }

    func testMalformedSourceExtentCountsFaceReferencesAndTexturePointers() {
        let raw = fixture()
        for count in [0, 7, 51, 80, raw.count - 1] {
            XCTAssertThrowsError(try THPS2PSX(data: raw.prefix(count)))
        }
        for (offset, bytes) in [(8, [0xa1, 0x86, 0x01, 0]), (52, [12, 0, 0, 0]), (118, [12, 0]), (120, [9]), (132, [99, 0, 0, 0])] {
            var bad = raw
            bad.replaceSubrange(offset..<(offset + bytes.count), with: bytes.map(UInt8.init))
            XCTAssertThrowsError(try THPS2PSX(data: bad))
        }
    }

    func testRestartCoordinatesAndUndecodedPayload() throws {
        let source = try THPS2TRG(data: triggers())
        XCTAssertEqual(source.nodes.count, 2)
        XCTAssertEqual(source.nodes[0].name, "Start")
        XCTAssertEqual(source.nodes[0].positionFixed12, SIMD3<Int32>(4096, -4096, 8192))
        XCTAssertEqual(source.nodes[0].parameters, [0, 512, 0])
        XCTAssertEqual(source.sourcePayload(node: 0), Data([255, 255]))
        XCTAssertEqual(source.nodes[1].type, 255)
        var invalid = triggers(); invalid[16] = 20
        XCTAssertThrowsError(try THPS2TRG(data: invalid))
        XCTAssertThrowsError(try THPS2TRG(data: invalid.dropLast()))
    }

    func testBlockmapSourceMembershipBoundaryAndMalformedCounts() throws {
        var data = Data()
        func put<T: FixedWidthInteger>(_ n: T) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        for value: Int32 in [-4096, -4096, 4096, 4096] { put(value) }
        put(UInt16(2)); put(UInt16(2))
        for cell: [UInt32] in [[0], [], [1], [0, 1]] {
            put(UInt32(0)); put(UInt32(0)); put(UInt32(cell.count)); cell.forEach { put($0) }; put(UInt32(0))
        }
        let grid = try THPS2BlockMap(data: data, objectCount: 2)
        XCTAssertEqual(grid.referenceCount, 4)
        XCTAssertEqual(Array(try XCTUnwrap(grid.candidates(xFixed24: -4096, zFixed24: -4096))), [0])
        XCTAssertEqual(Array(try XCTUnwrap(grid.candidates(xFixed24: 0, zFixed24: 0))), [0, 1])
        XCTAssertNil(grid.candidates(xFixed24: 4096, zFixed24: 0))
        XCTAssertNil(grid.objectIndices(cellX: -1, cellZ: 0))
        data[32] = 2
        XCTAssertThrowsError(try THPS2BlockMap(data: data, objectCount: 2))
        XCTAssertThrowsError(try THPS2BlockMap(data: data.dropLast(), objectCount: 2))
    }

    func testRealHangarSourceCountsIdentityAndNodesIfAvailable() throws {
        let original = root.appendingPathComponent("Library/Imported/thps2/original/data")
        let url = original.appendingPathComponent("SKHAN.PSX")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Ignored original THPS2 source absent") }
        let scene = try THPS2PSX(url: url, sha256: "56cc7f02ac45e0772621e6d9866fda4562e8a71669a0dee826bd93512fe9e6f8")
        XCTAssertEqual(scene.objects.count, 470); XCTAssertEqual(scene.models.count, 471)
        XCTAssertEqual(scene.vertexCount, 5368); XCTAssertEqual(scene.faceCount, 3231)
        XCTAssertEqual(scene.blockMaps.count, 1); XCTAssertEqual(scene.blockMaps[0].width, 20); XCTAssertEqual(scene.blockMaps[0].height, 20)
        let library = try THPS2PSX(url: original.appendingPathComponent("SKHAN_L.PSX"), sha256: "d4b3c2ea67f95a00faa79076709381c34da73b9cb18dff069ffeca70e9b1a64a")
        XCTAssertEqual(library.textures.count, 105)
        XCTAssertEqual(Set(scene.textureNames), Set(library.textureNames))
        XCTAssertNotEqual(scene.textureNames, library.textureNames, "Actual source orders differ; resolve texture IDs, not file-table position")
        let trigger = try THPS2TRG(url: original.appendingPathComponent("SKHAN_T.TRG"), sha256: "3946dc1ef6c7393512de65153cdbeea147f1433bc2976ba3d7c944c60cf7ae81")
        XCTAssertEqual(trigger.nodes.count, 713); XCTAssertEqual(trigger.nodes.filter { $0.type == 8 }.count, 14)
        XCTAssertEqual(trigger.nodes.filter { $0.type == 10 }.count, 181); XCTAssertEqual(trigger.nodes[0].name, "Start")
        XCTAssertThrowsError(try THPS2PSX(url: url, sha256: String(repeating: "0", count: 64)))
    }

    @MainActor
    func testActualPreparedHangarNativeSceneIfAvailable() throws {
        let original = root.appendingPathComponent("Library/Imported/thps2/original")
        let prepared = root.appendingPathComponent("Library/Imported/thps2/levels/hangar")
        guard FileManager.default.fileExists(atPath: prepared.appendingPathComponent("level.json").path) else {
            throw XCTSkip("Original THPS2 scene preparation absent")
        }
        let level = try THPS2OriginalLevel(originalRoot: original, preparedRoot: prepared)
        XCTAssertEqual(level.layers.count, 3)
        let result = try THPS2OriginalScene.build(level)
        XCTAssertEqual(result.triangleCount, 4706)
        XCTAssertGreaterThan(result.drawGroups, 20)
        XCTAssertLessThan(result.drawGroups, 180)
        XCTAssertTrue(result.unresolvedTextureIDs.isEmpty)
        XCTAssertEqual(result.scene.rootNode.childNodes[0].childNodes.count, result.drawGroups)
        XCTAssertTrue(result.minimum.x < result.maximum.x && result.minimum.y < result.maximum.y && result.minimum.z < result.maximum.z)
        let pc = try THPS2OriginalScene.build(level, textureChoice: .suppliedPCBMP)
        XCTAssertEqual(pc.triangleCount, result.triangleCount)
        XCTAssertEqual(pc.minimum, result.minimum)
        XCTAssertTrue(pc.unresolvedTextureIDs.isEmpty)
    }

    @MainActor
    func testAllTenPreparedOriginalSceneVariantsIfAvailable() throws {
        let original = root.appendingPathComponent("Library/Imported/thps2/original")
        let prepared = root.appendingPathComponent("Library/Imported/thps2/levels")
        let expected: [(String, Int, Int)] = [
            ("hangar", 4706, 127), ("school-ii", 9888, 220), ("new-york", 8420, 194),
            ("marseille", 6080, 191), ("venice", 9332, 169), ("skatestreet", 5891, 135),
            ("philadelphia", 8048, 196), ("bullring", 6577, 109), ("chopper-drop", 1267, 66), ("skate-heaven", 8039, 93)
        ]
        guard expected.allSatisfy({ FileManager.default.fileExists(atPath: prepared.appendingPathComponent($0.0 + "/level.json").path) }) else {
            throw XCTSkip("All ten ignored THPS2 original scene preparations are not present")
        }
        for (name, triangles, groups) in expected {
            try autoreleasepool {
                let level = try THPS2OriginalLevel(originalRoot: original, preparedRoot: prepared.appendingPathComponent(name))
                let original = try THPS2OriginalScene.build(level)
                let pc = try THPS2OriginalScene.build(level, textureChoice: .suppliedPCBMP)
                XCTAssertEqual(original.triangleCount, triangles, name)
                XCTAssertEqual(original.drawGroups, groups, name)
                XCTAssertEqual(pc.triangleCount, triangles, name)
                XCTAssertTrue(original.unresolvedTextureIDs.isEmpty, name)
                XCTAssertTrue(pc.unresolvedTextureIDs.isEmpty, name)
            }
        }
    }

    func testPreparedMediaPathsCannotEscapeTheirRoot() {
        for path in ["../a", "/a", "a//b", "a/./b", "a\\b", ""] {
            XCTAssertThrowsError(try THPS2OriginalLevel.child(root: root, path: path))
        }
    }
}
