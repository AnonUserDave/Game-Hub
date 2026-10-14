import Foundation
import XCTest
@testable import GameHub

final class GameHubTests: XCTestCase {
    private func manifest(id: String = "test-game", launch: NativeLaunch? = nil, fidelity: String = "source") -> GameManifest {
        GameManifest(schemaVersion: 1, id: id, title: "Test Game", edition: "Reference", platform: "Test", year: 2026, genre: "Test", summary: "Test", sourceArchive: nil, accent: "C2EF93", artwork: "native", launch: launch, fidelity: fidelity, notes: [], keyboard: [], controller: [])
    }

    func testStarterCatalogCoversEverySuppliedArchiveWithoutClaimingFinishedPorts() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Library/Manifests")
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        let games = try urls.map { try JSONDecoder().decode(GameManifest.self, from: Data(contentsOf: $0)) }
        let archives = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "zip" }
        // A Git clone can omit proprietary source archives; the complete catalog
        // must still exist, and any archives present locally must be represented.
        let catalogSources = Set(games.compactMap(\.sourceArchive))
        XCTAssertTrue(Set(archives.map(\.lastPathComponent)).isSubset(of: catalogSources))
        XCTAssertEqual(games.filter { $0.fidelity == "source" }.count, 17)
        let prototypes = games.filter { $0.fidelity == "prototype" }
        XCTAssertEqual(Set(prototypes.map(\.id)), ["pga2005-native-development", "pga2005-original-courses"])
        XCTAssertTrue(prototypes.allSatisfy { NativeGameFactory.availableIDs.contains($0.launch?.builtin ?? "") })
        XCTAssertEqual(Set(games.map(\.id)).count, games.count)
        XCTAssertFalse(games.contains { $0.fidelity == "verified" })
        XCTAssertTrue(games.filter { $0.fidelity == "source" }.allSatisfy { $0.launch == nil })
        let shooter = try XCTUnwrap(games.first { $0.id == "space-invaders-arcade" })
        XCTAssertEqual(shooter.platform, "Taito arcade")
        XCTAssertTrue(shooter.notes.joined().contains("Bally"))
        await MainActor.run {
            let store = GameStore(root: root, loadSynchronously: true, observeExternalApplications: false)
            XCTAssertEqual(store.games.count, games.count)
            XCTAssertNil(store.issue)
        }
    }

    func testManifestValidationRejectsNonNativeLaunchAndUnsafeID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = manifest()
        let invalidID = manifest(id: "../other-game")
        let windows = manifest(launch: NativeLaunch(kind: "executable", path: "game.exe"), fidelity: "native")
        let sourceLaunch = manifest(launch: NativeLaunch(kind: "executable", path: "game"))
        try await MainActor.run {
            let store = GameStore(root: directory, loadSynchronously: true, observeExternalApplications: false)
            XCTAssertNoThrow(try store.validate(source))
            XCTAssertThrowsError(try store.validate(invalidID))
            XCTAssertThrowsError(try store.validate(windows))
            XCTAssertThrowsError(try store.validate(sourceLaunch))
            XCTAssertNotNil(store.readiness(source), "An archive alone must never be playable")
        }
    }

    func testArchitectureProbeRejectsIntelAndAcceptsArm64() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let arm = directory.appendingPathComponent("arm")
        let intel = directory.appendingPathComponent("intel")
        let truncated = directory.appendingPathComponent("truncated")
        let universal = directory.appendingPathComponent("universal")
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1]).write(to: arm)
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x07, 0, 0, 1]).write(to: intel)
        try Data([0xcf, 0xfa]).write(to: truncated)
        try Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 1, 1, 0, 0, 0x0c] + Array(repeating: UInt8(0), count: 16)).write(to: universal)
        await MainActor.run {
            XCTAssertTrue(GameStore.isNativeMachO(arm))
            XCTAssertFalse(GameStore.isNativeMachO(intel))
            XCTAssertFalse(GameStore.isNativeMachO(truncated))
            XCTAssertTrue(GameStore.isNativeMachO(universal))
        }
    }

    func testDuplicateIDsAreReportedAndFiltersStayConsistent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let catalog = directory.appendingPathComponent("Library/Manifests")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try JSONEncoder().encode(manifest())
        try data.write(to: catalog.appendingPathComponent("one.json"))
        try data.write(to: catalog.appendingPathComponent("two.json"))
        await MainActor.run {
            let store = GameStore(root: directory, loadSynchronously: true, observeExternalApplications: false)
            XCTAssertEqual(store.games.count, 1)
            XCTAssertNotNil(store.issue)
            store.search = "does not exist"
            XCTAssertTrue(store.filtered.isEmpty)
            XCTAssertNil(store.selected, "Featured game must respect the active search")
            store.search = ""
            store.section = .ready
            XCTAssertTrue(store.filtered.isEmpty)
            store.section = .queue
            XCTAssertEqual(store.filtered.count, 1)
        }
    }
}
