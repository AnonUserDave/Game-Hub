import AppKit
import SceneKit
import XCTest
@testable import GameHub

final class PGARendererTests: XCTestCase {
    func testDevelopmentForestRetainsCoursePositionsAndClearTeeCamera() async {
        await MainActor.run {
            _ = NSApplication.shared
            for hole in PGACourse.development.holes {
                let renderer = PGARenderer()
                let course = PGACourse(name: "Renderer fixture", provenance: "Generated regression fixture", holes: [hole])
                let simulation = PGASimulation(course: course)
                renderer.build(hole: hole)
                renderer.update(simulation, cameraMode: 0, zoom: 1, delta: 1)
                guard let forest = renderer.scene.rootNode.childNode(withName: "Development forest", recursively: true) else {
                    XCTFail("Expected the generated forest to retain its scene hierarchy"); continue
                }
                XCTAssertGreaterThan(forest.childNodes.count, 10)
                let bounds = forest.boundingBox
                XCTAssertGreaterThan(bounds.max.x - bounds.min.x, 50, "Tree transforms must span the course instead of collapsing to the tee")
                XCTAssertGreaterThan(bounds.max.z - bounds.min.z, 100)
                for tree in forest.childNodes {
                    XCTAssertGreaterThan(hypot(Double(tree.position.x) - hole.tee.x, Double(tree.position.z) - hole.tee.z), 65)
                }
                let aim = simulation.ball + simulation.direction * 75
                let hits = forest.hitTestWithSegment(from: renderer.camera.position, to: SCNVector3(aim.x, aim.y, aim.z),
                                                     options: [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue,
                                                               SCNHitTestOption.backFaceCulling.rawValue: false])
                XCTAssertTrue(hits.isEmpty, "The initial player-camera sightline must not run through a tree canopy")
            }
        }
    }
}
