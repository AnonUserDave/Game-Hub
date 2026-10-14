import Foundation
import XCTest
@testable import GameHub

final class AsteroidsNativeIntegrationTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private var records: [(String, String)] {
        [("asteroids2600-native-development", Asteroids2600Presentation.path),
         ("asteroids7800-native-development", Asteroids7800Presentation.mediaPath),
         ("asteroids8bit-native-development", Asteroids8BitPresentation.path)]
    }
    func testEveryAsteroidsEntryRequiresItsOriginalBoundedMedia() throws {
        for (id, path) in records {
            XCTAssertTrue(NativeGameFactory.availableIDs.contains(id))
            XCTAssertTrue(RetroOriginalMedia.requiredIDs.contains(id))
            XCTAssertFalse(RetroOriginalMedia.readiness(id: id, root: URL(fileURLWithPath: "/nonexistent-gamehub")).isEmpty)
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
                XCTAssertEqual(RetroOriginalMedia.readiness(id: id, root: root), "")
            }
        }
    }
    func testAllEditionsRecheckMediaImmediatelyBeforeNativeLaunch() async throws {
        for (id, path) in records {
            let original = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: original.path) else { throw XCTSkip("Prepare all three selected original editions") }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temp) }
            let media = temp.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: original).write(to: media)
            let catalog = temp.appendingPathComponent("Library/Manifests")
            try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
            try Data(contentsOf: root.appendingPathComponent("Library/Manifests/\(id).json")).write(to: catalog.appendingPathComponent("game.json"))
            let store = await MainActor.run { GameStore(root: temp, loadSynchronously: true, observeExternalApplications: false) }
            await MainActor.run { XCTAssertNil(store.readiness(store.games[0]), id) }
            try FileManager.default.removeItem(at: media)
            await MainActor.run { store.launch(store.games[0]) }
            for _ in 0..<100 {
                if await MainActor.run(body: { store.launchingGameID == nil }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            await MainActor.run {
                XCTAssertNil(store.activeGame, id); XCTAssertNil(store.launchingGameID, id)
                XCTAssertEqual(store.issue?.title, "Original media changed", id)
                XCTAssertNotNil(store.readiness(store.games[0]), id)
            }
        }
    }
}
