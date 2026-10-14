import AppKit
import Metal
import SceneKit
import SwiftUI
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
        let code = ProcessInfo.processInfo.environment["GAMEHUB_SNAPSHOT_COURSE"] ?? "PBL"
        let course = try PGAOriginalPlayableCourse.load(code: code, root: root)
        XCTAssertNotNil(PGACameraDirector(root: root), "Prepared original camera scripts are required for tee-view captures")
        let golferAssets = try? PGAOriginalGolferAssets.load(root: root)
        let holes = ProcessInfo.processInfo.environment["GAMEHUB_SNAPSHOT_HOLES"]?.split(separator: ",").compactMap { Int($0) } ?? Array(1...18)
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cameras = (ProcessInfo.processInfo.environment["GAMEHUB_SNAPSHOT_CAMERAS"] ?? "0,2").split(separator: ",").compactMap { Int($0) }
        try await MainActor.run {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw XCTSkip("Metal device unavailable in this test environment")
            }
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
                let renderer = PGARenderer(assetRoot: root.appendingPathComponent("Library/Imported/pga2005/\(code)"))
                // GAMEHUB_SNAPSHOT_WEATHER="weather,time" applies an original render preset (e.g. "0,0" clear sunrise).
                let weather = ProcessInfo.processInfo.environment["GAMEHUB_SNAPSHOT_WEATHER"]?.split(separator: ",").compactMap { Int($0) }
                let render = weather.flatMap { w in w.count == 2 ? PGARenderPresets.load(root: root)?.state(weather: w[0], time: w[1], hole: number) : nil }
                renderer.build(original: PGAOriginalSceneBuilder.node(for: mesh, course: course, textures: textures,
                                                                      style: render.map(PGAOriginalSceneryStyle.init(state:)) ?? .standard),
                               hole: single.holes[0], flagImage: art.courseImage("FLAG", course: code), holeImage: art.image("hole-decal"), render: render)
                XCTAssertNotNil(renderer.scene.rootNode.childNode(withName: PGAOriginalSkyNode.nodeName, recursively: true),
                                "Decoded sky must be present in the original-course scene")
                let trees = renderer.scene.rootNode.childNode(withName: PGAOriginalVegetationNode.nodeName, recursively: true) as? PGAOriginalVegetationNode
                XCTAssertNotNil(trees, "Decoded trees must be present in the original-course scene")
                renderer.useOriginalBallShadow(art.image("ball-shadow"))
                renderer.useOriginalAimArrow(art.image("aim-arrow"))
                if let golferAssets { renderer.useOriginalGolfer(golferAssets) }
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
                    try write(image, to: directory.appendingPathComponent(String(format: "%@-hole%02d-camera%d.png", code.lowercased(), number, camera)))
                    if let trees {
                        let stats = trees.drawer.stats
                        XCTAssertGreaterThan(stats.drawCalls, 0, "Original scenery must submit Metal draws")
                        XCTAssertGreaterThan(stats.lodTrees[0] + stats.lodTrees[1] + stats.lodTrees[2] + stats.lodTrees[3], 0,
                                             "At least one decoded tree must be visible")
                        print(String(format: "Hole %d camera %d vegetation: %d draws, %d vertices, LOD0-3 %d/%d/%d/%d, %d culled%@", number, camera,
                                     stats.drawCalls, stats.vertices, stats.lodTrees[0], stats.lodTrees[1], stats.lodTrees[2], stats.lodTrees[3],
                                     stats.culled, stats.meshCapApplied ? ", mesh cap applied" : ""))
                    }
                }
                if let map = mesh.map.image {
                    try write(NSImage(cgImage: map, size: .zero), to: directory.appendingPathComponent(String(format: "%@-hole%02d-map.png", code.lowercased(), number)))
                }
                print(String(format: "Hole %d: %d vertices, %d triangles, %d materials, mesh build %.3f s, lie %@",
                             number, mesh.vertexCount, mesh.batches.map(\.triangles).reduce(0, +), mesh.batches.count, built, game.lieLabel))
            }
        }
    }

    func testRenderOriginalHUD() async throws {
        guard let output = ProcessInfo.processInfo.environment["GAMEHUB_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set GAMEHUB_SNAPSHOT_DIR to capture HUD snapshots")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let course = try PGAOriginalPlayableCourse.load(code: "PBL", root: root)
        var game = PGASimulation(course: course.course, terrains: course.terrains, playerNames: ["Dad", "Pablo"])
        for strokes in [[4, 5], [5, 4], [3, 3]] {
            for _ in 0..<2 { game.restoreHoleForTest(strokes: strokes[game.currentPlayer]) }
        }
        var swinging = PGASimulation(course: course.course, terrains: course.terrains)
        swinging.swing()
        while !(swinging.swingMeter!.acceptsPowerClick && swinging.meter >= 0.8) { swinging.update(deltaTime: 1.0 / 60) }
        swinging.swing()   // power click at 80 %, marker returning
        let swingingGame = swinging, scoredGame = game
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await MainActor.run {
            let game = scoredGame
            let art = PGAHUDImages(root: root)
            let views: [(String, AnyView, CGSize)] = [
                ("hud-scorecard", AnyView(PGAOriginalScorecard(images: art, simulation: game).frame(width: 760)), CGSize(width: 760, height: 458)),
                ("hud-loading", AnyView(PGAOriginalLoadingScreen(images: art, message: "Loading original PBL terrain…")), CGSize(width: 1280, height: 800)),
                ("hud-meter", AnyView(PGAOriginalSwingMeter(simulation: swingingGame, images: art)), CGSize(width: 256, height: 256)),
                ("hud-setup", AnyView(PGARoundSetupView(session: { let s = PGAGameSession(choice: .original(code: "PBL"), onExit: {}); s.setup.players = ["Dad", "Pablo", "Player 3", "Player 4"]; return s }())), CGSize(width: 1280, height: 800))
            ]
            for (name, view, size) in views {
                let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).background(Color.black))
                renderer.scale = 2
                guard let image = renderer.nsImage else { throw CocoaError(.fileWriteUnknown) }
                try write(image, to: directory.appendingPathComponent("\(name).png"))
            }
        }
    }

    private func write(_ image: NSImage, to url: URL) throws {
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
