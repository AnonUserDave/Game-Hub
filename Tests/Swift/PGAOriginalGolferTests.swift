import AppKit
import SceneKit
import XCTest
@testable import GameHub

final class PGAOriginalGolferTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testPreparedGolferCreatesSkinnedSceneAndFollowsShot() async throws {
        guard FileManager.default.fileExists(atPath: PGAOriginalGolferAssets.directory(root: root).appendingPathComponent("golfer.json").path) else {
            throw XCTSkip("Prepare the ignored original golfer data first")
        }
        let assets = try PGAOriginalGolferAssets.load(root: root)
        XCTAssertEqual(assets.names.count, 102)
        XCTAssertEqual(assets.clubs.count, 6)
        XCTAssertGreaterThan(assets.body.vertexCount, 5_000)
        XCTAssertLessThan(assets.footprintBytes, 16 * 1024 * 1024)

        await MainActor.run {
            _ = NSApplication.shared
            let renderer = PGARenderer()
            renderer.useOriginalGolfer(assets)
            guard let original = renderer.originalGolfer else { return XCTFail("Golfer was not installed") }
            let body = original.node.childNode(withName: "Golfer body", recursively: true)
            let club = original.node.childNode(withName: "Club driver", recursively: true)
            XCTAssertNotNil(body?.skinner)
            XCTAssertNotNil(club?.skinner)
            XCTAssertTrue(original.node.isHidden)

            var game = PGASimulation()
            renderer.build(hole: game.hole)
            renderer.update(game, cameraMode: 0, zoom: 1, delta: 1 / 60)
            XCTAssertFalse(original.node.isHidden)
            XCTAssertGreaterThan(original.drawCalls, 0)
            XCTAssertGreaterThan(original.vertexCount, 5_000)
            let address = original.worldPosition(of: "IG_Root")
            XCTAssertNotNil(address)

            game.swing()
            for _ in 0..<180 where game.phase.swinging {
                game.update(deltaTime: 1 / 60)
                renderer.update(game, cameraMode: 0, zoom: 1, delta: 1 / 60)
            }
            XCTAssertEqual(game.phase, .airborne)
            XCTAssertFalse(original.node.isHidden, "Follow-through must remain visible after launch")
            XCTAssertNotEqual(original.worldPosition(of: "IG_Root"), address)
            XCTAssertNotNil(original.clubLowestPoint())
        }
    }
}
