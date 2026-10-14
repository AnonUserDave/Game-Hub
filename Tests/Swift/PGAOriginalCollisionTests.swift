import Foundation
import XCTest
@testable import GameHub

final class PGAOriginalCollisionTests: XCTestCase {
    private func mesh() -> Data {
        var data = Data([0x47, 0x48, 0x50, 0x43])
        func uint(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func float(_ value: Float) { uint(value.bitPattern) }
        uint(2); uint(6); uint(2); uint(2)
        for value: Float in [0, 0, 0, 100, 50, 100] { float(value) }
        for point: [Float] in [[0, 0, 0], [100, 10, 0], [0, 20, 100], [0, 30, 0], [100, 40, 0], [0, 50, 100]] {
            point.forEach(float); data.append(contentsOf: [255, 255, 255, 255]); float(0); float(0)
        }
        for value: UInt32 in [0, 1, 2, 7, 3, 4, 5, 10] { uint(value) }
        return data
    }

    func testBarycentricHeightAndOriginalMaterialAtOverlappingLayers() throws {
        let collider = try PGAOriginalCollision(data: mesh(), cellSize: 32)
        let top = try XCTUnwrap(collider.sample(rawX: 25, rawZ: 25))
        XCTAssertEqual(top.rawHeight, 37.5, accuracy: 1e-6)
        XCTAssertEqual(top.terrainID, 10)
        let ground = try XCTUnwrap(collider.sample(rawX: 25, rawZ: 25, maximumHeight: 20))
        XCTAssertEqual(ground.rawHeight, 7.5, accuracy: 1e-6)
        XCTAssertEqual(ground.terrainID, 7)
        XCTAssertGreaterThan(ground.normal.y, 0)
        XCTAssertEqual(ground.normal.length, 1, accuracy: 1e-6)
    }

    func testNoInventedHeightOutsideTrianglesOrOnInvalidInput() throws {
        let collider = try PGAOriginalCollision(data: mesh(), cellSize: 32)
        XCTAssertNil(collider.sample(rawX: 90, rawZ: 90))
        XCTAssertNil(collider.sample(rawX: -1, rawZ: 0))
        XCTAssertNil(collider.sample(rawX: .nan, rawZ: 0))
        XCTAssertNotNil(collider.sample(rawX: 0, rawZ: 0))
    }

    func testMalformedCountsRejectedBeforeIndexAllocation() {
        var data = mesh()
        data.replaceSubrange(8...11, with: [UInt8](arrayLiteral: 255, 255, 255, 127))
        XCTAssertThrowsError(try PGAOriginalCollision(data: data))
    }
}
