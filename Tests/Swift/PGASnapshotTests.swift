import AppKit
import Metal
import SceneKit
import XCTest
@testable import GameHub

/// Opt-in visual capture: GAMEHUB_SNAPSHOT_DIR=/path ./Tools/test.sh -XCTest GameHubTests.PGASnapshotTests
/// renders each original Pebble Beach tee view offscreen at 2560 × 1600 with
/// 4× MSAA, plus its minimap. Images contain original course textures, so the
/// output directory must stay outside Git. Offscreen timing is not an M1
/// performance measurement.
final class PGASnapshotTests: XCTestCase {
    func testRenderOriginalTeeViews() async throws {
        guard let output = ProcessInfo.processInfo.environment["GAMEHUB_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set GAMEHUB_SNAPSHOT_DIR to capture original-course snapshots")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let course = try PGAOriginalPlayableCourse.load(code: "PBL", root: root)
        let holes = ProcessInfo.processInfo.environment["GAMEHUB_SNAPSHOT_HOLES"]?.split(separator: ",").compactMap { Int($0) } ?? Array(1...18)
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cameras = (ProcessInfo.processInfo.environment["GAMEHUB_SNAPSHOT_CAMERAS"] ?? "0,2").split(separator: ",").compactMap { Int($0) }
        try await MainActor.run {
            _ = NSApplication.shared
            let textures = PGAOriginalTextureCache()
            let art = PGAHUDImages(root: root)
            for number in holes where (1...course.course.holes.count).contains(number) {
                let index = number - 1
                let started = ProcessInfo.processInfo.systemUptime
                let mesh = PGAOriginalHoleMesh.build(course: course, holeIndex: index)
                let built = ProcessInfo.processInfo.systemUptime - started
                let single = PGACourse(name: course.course.name, provenance: course.course.provenance,
                                       holes: [course.course.holes[index]], identity: course.course.identity)
                var game = PGASimulation(course: single, terrains: [course.terrains[index]])
                let renderer = PGARenderer()
                renderer.build(original: PGAOriginalSceneBuilder.node(for: mesh, course: course, textures: textures), hole: single.holes[0],
                               flagImage: art.courseImage("FLAG"), holeImage: art.image("hole-decal"))
                renderer.useOriginalBallShadow(art.image("ball-shadow"))
                let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
                let snapshot = SCNRenderer(device: device, options: nil)
                snapshot.scene = renderer.scene
                for camera in cameras {
                    if camera == 9 {
                        // Approach view: ball restored 12 m short of the pin on the play line.
                        let hole = single.holes[0], toward = (hole.tee - hole.cup).horizontalUnit
                        let spot = hole.cup + toward * 12
                        guard let floor = game.ground(x: spot.x, z: spot.z) else { continue }
                        try game.restore(PGARoundSnapshot(courseIdentity: single.identity, holeIndex: 0, scores: [], strokes: 1,
                                                          ball: PGAVector(x: spot.x, y: floor.height + PGASimulation.ballRadius, z: spot.z),
                                                          heading: atan2(hole.cup.x - spot.x, hole.cup.z - spot.z), club: PGAClub.putter.rawValue))
                        game.selectClub(.putter)
                    }
                    renderer.resetCamera()
                    renderer.update(game, cameraMode: camera == 9 ? 0 : camera, zoom: 1, delta: 1)
                    snapshot.pointOfView = renderer.camera
                    let image = snapshot.snapshot(atTime: 1.3, with: CGSize(width: 2560, height: 1600), antialiasingMode: .multisampling4X)
                    try write(image, to: directory.appendingPathComponent(String(format: "pbl-hole%02d-camera%d.png", number, camera)))
                }
                if let map = mesh.map.image {
                    try write(NSImage(cgImage: map, size: .zero), to: directory.appendingPathComponent(String(format: "pbl-hole%02d-map.png", number)))
                }
                print(String(format: "Hole %d: %d vertices, %d triangles, %d materials, mesh build %.3f s, lie %@",
                             number, mesh.vertexCount, mesh.batches.map(\.triangles).reduce(0, +), mesh.batches.count, built, game.lieLabel))
            }
        }
    }

    private func write(_ image: NSImage, to url: URL) throws {
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
