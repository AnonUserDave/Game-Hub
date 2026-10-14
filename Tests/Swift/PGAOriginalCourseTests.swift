import Foundation
import XCTest
@testable import GameHub

final class PGAOriginalCourseTests: XCTestCase {
    private func append<T>(_ value: T, to data: inout Data) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
    private func fixture(version: UInt32 = 2, invalidIndex: Bool = false, invalidPosition: Bool = false) -> Data {
        var data = Data("GHPC".utf8)
        append(version.littleEndian, to: &data); append(UInt32(3).littleEndian, to: &data)
        if version == 2 { append(UInt32(1).littleEndian, to: &data); append(UInt32(1).littleEndian, to: &data) }
        for value: Float in [0, 0, 0, 10, 2, 10] { append(value.bitPattern.littleEndian, to: &data) }
        let positions: [[Float]] = [[0, 0, 0], [10, 0, 0], [0, 2, 10]]
        for (index, position) in positions.enumerated() {
            for (component, value) in position.enumerated() {
                append((invalidPosition && index == 0 && component == 0 ? Float.nan : value).bitPattern.littleEndian, to: &data)
            }
            data.append(contentsOf: [255, 128, 64, 255])
            append(Float(index == 1 ? 1 : 0).bitPattern.littleEndian, to: &data)
            append(Float(index == 2 ? 1 : 0).bitPattern.littleEndian, to: &data)
        }
        if version == 2 { for value: UInt32 in [0, 1, invalidIndex ? 99 : 2, 7] { append(value.littleEndian, to: &data) } }
        return data
    }
    private func withFile<T>(_ data: Data, _ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("terrain.ghpc")
        try data.write(to: file)
        return try body(file)
    }

    func testPointCloudPreservesSourcePositionsWithoutInventingFaces() throws {
        try withFile(fixture(version: 1)) { url in
            let terrain = try PGAOriginalTerrain.load(url)
            XCTAssertEqual(terrain.formatVersion, 1)
            XCTAssertEqual(terrain.sourceVertices, 3)
            XCTAssertEqual(terrain.displayedVertices, 3)
            XCTAssertEqual(terrain.triangleCount, 0)
            XCTAssertTrue(terrain.batches.isEmpty)
            XCTAssertNil(terrain.normals)
            XCTAssertFalse(terrain.sampled)
            XCTAssertEqual(terrain.positionOffset, 36)
            XCTAssertEqual(terrain.center, PGAVector(x: 5, y: 1, z: 5))
            XCTAssertEqual(terrain.colors.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }, 1)
            XCTAssertNotEqual(terrain.colors, terrain.elevationColors)
        }
    }

    func testIndexedMeshPreservesTriangleTopologyAndTerrainID() throws {
        try withFile(fixture()) { url in
            let terrain = try PGAOriginalTerrain.load(url)
            XCTAssertEqual(terrain.formatVersion, 2)
            XCTAssertEqual(terrain.positionOffset, 44)
            XCTAssertEqual(terrain.groupCount, 1)
            XCTAssertEqual(terrain.triangleCount, 1)
            XCTAssertEqual(terrain.batches.count, 1)
            XCTAssertEqual(terrain.batches[0].terrainID, 7)
            XCTAssertEqual(terrain.batches[0].indices.withUnsafeBytes { raw in (0..<3).map { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) } }, [0, 1, 2])
            XCTAssertEqual(terrain.normals?.count, 3 * 3 * 4)
            let values = terrain.normals!.withUnsafeBytes { raw in (0..<9).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
            XCTAssertTrue(values.allSatisfy(\.isFinite))
            XCTAssertGreaterThan(values[1], 0, "Provisional native lighting normals point up without changing original indices")
        }
    }

    func testCorruptOrUnsafeTerrainIsRejected() throws {
        try withFile(fixture(invalidIndex: true)) { XCTAssertThrowsError(try PGAOriginalTerrain.load($0)) }
        try withFile(fixture(invalidPosition: true)) { XCTAssertThrowsError(try PGAOriginalTerrain.load($0)) }
        var short = fixture(); short.removeLast()
        try withFile(short) { XCTAssertThrowsError(try PGAOriginalTerrain.load($0)) }
        var wrongMagic = fixture(); wrongMagic[0] = 0
        try withFile(wrongMagic) { XCTAssertThrowsError(try PGAOriginalTerrain.load($0)) }
    }

    func testMaterialManifestKeepsLocalTexturesAndRejectsPathEscape() throws {
        try withFile(fixture()) { url in
            let directory = url.deletingLastPathComponent()
            try Data().write(to: directory.appendingPathComponent("texture.png"))
            let manifest = """
            {"schema_version":1,"materials":[
              {"id":7,"name":"Source rough","texture":"texture.png","width":256,"height":256},
              {"id":8,"name":"Unsafe","texture":"../escape.png","width":256,"height":256}
            ]}
            """
            try Data(manifest.utf8).write(to: directory.appendingPathComponent("materials.json"))
            let terrain = try PGAOriginalTerrain.load(url)
            XCTAssertEqual(terrain.materialTextures.keys.sorted(), [7])
            XCTAssertEqual(terrain.materialNames[7], "Source rough")
            XCTAssertTrue(terrain.report.contains("Original material textures: 1"))
        }
    }
}
