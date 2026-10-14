import XCTest
@testable import GameHub

final class SkateOriginalCollisionTests: XCTestCase {
    private func fixture() -> Data {
        var data = Data("GHSC".utf8)
        func put(_ value: UInt32) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        [1, 1, 3, 1, 0x12345678, 2, 0, 3, 0, 1].forEach { put(UInt32($0)) }
        for value: Float in [0, 0, 0, 4, 0, 0, 0, 2, 0] { put(value.bitPattern) }
        [0, 1, 2].forEach { put(UInt32($0)) }
        data.append(contentsOf: [0x00, 0x30, 0x0e, 0x00])
        return data
    }

    func testOriginalFieldsAndMappedAccess() throws {
        let asset = try SkateOriginalCollision(data: fixture())
        XCTAssertEqual(asset.objects[0].checksum, 0x12345678)
        XCTAssertEqual(asset.vertexCount, 3)
        XCTAssertEqual(asset.triangleCount, 1)
        XCTAssertEqual(asset.vertex(at: 1), SIMD3<Float>(4, 0, 0))
        XCTAssertEqual(asset.maximum, SIMD3<Float>(4, 2, 0))
        XCTAssertEqual(asset.triangle(at: 0)?.terrain, 14)
        XCTAssertEqual(asset.triangle(at: 0)?.flags, 0x3000)
        XCTAssertNil(asset.vertex(at: -1))
        XCTAssertNil(asset.triangle(at: 1))
    }

    func testRejectsTruncationCrossObjectIndexAndNonfiniteVertex() {
        var data = fixture()
        XCTAssertThrowsError(try SkateOriginalCollision(data: data.dropLast()))
        data[80] = 3 // First triangle index lies beyond its three vertices.
        XCTAssertThrowsError(try SkateOriginalCollision(data: data))
        data = fixture()
        data.replaceSubrange(44..<48, with: [0, 0, 0xc0, 0x7f])
        XCTAssertThrowsError(try SkateOriginalCollision(data: data))
    }

    func testPreparedOriginalNewJerseyIfAvailable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Library/Imported/thug/collision/2a407b04f76335c659a30c1d90e2d6ef3a48368e179e03ae7130fa0fbf15bb40.ghsc")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Owned source media have not been prepared on this machine")
        }
        let asset = try SkateOriginalCollision(url: url)
        XCTAssertEqual(asset.objects.count, 1700)
        XCTAssertEqual(asset.vertexCount, 48761)
        XCTAssertEqual(asset.triangleCount, 38202)
    }

    func testPreparedOriginalThug2AirportIfAvailable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Library/Imported/thug2/collision/f0f6509448b31ec1e2f0a956ccbeac150430fc0a74a62b94d0ab0e244ab5bcf2.ghsc")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Owned THUG2 source media have not been prepared on this machine")
        }
        let asset = try SkateOriginalCollision(url: url)
        XCTAssertEqual(asset.objects.count, 739)
        XCTAssertEqual(asset.vertexCount, 51797)
        XCTAssertEqual(asset.triangleCount, 45428)
    }
}
