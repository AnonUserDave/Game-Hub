import Foundation
import XCTest
@testable import GameHub

final class HubLibraryTests: XCTestCase {
    private func manifest(_ id: String, archive: String?, fidelity: String = "source", builtin: String? = nil, title: String = "Test Game") -> GameManifest {
        GameManifest(schemaVersion: 1, id: id, title: title, edition: "Reference", platform: "Atari 2600", year: 1981, genre: "Arcade", summary: "Test", sourceArchive: archive, accent: "C2EF93", artwork: "pixel",
                     launch: builtin.map { NativeLaunch(kind: "builtin", path: nil, arguments: nil, builtin: $0) }, fidelity: fidelity, notes: [], keyboard: [], controller: [])
    }

    func testTitlesGroupOriginalMediaWithItsNativeBuilds() {
        let titles = GameTitle.group([
            manifest("game-build", archive: "Game.zip", fidelity: "prototype"),
            manifest("game-source", archive: "Game.zip"),
            manifest("imported", archive: nil, fidelity: "native"),
            manifest("other-source", archive: "Other.zip"),
            manifest("second-record", archive: "Other.zip")
        ])
        XCTAssertEqual(titles.map(\.id), ["game-source", "imported", "other-source", "second-record"])
        XCTAssertEqual(titles[0].original?.id, "game-source")
        XCTAssertEqual(titles[0].builds.map(\.id), ["game-build"])
        XCTAssertNil(titles[1].original, "An imported game without original media stands alone")
        XCTAssertTrue(titles[3].builds.isEmpty, "A second original record never becomes a playable build of another")
        XCTAssertEqual(manifest("x", archive: nil, title: "PGA Tour 2005 · Original Courses").buildName, "Original Courses")
        XCTAssertEqual(manifest("x", archive: nil, title: "PGA Native Development").buildName, "PGA Native Development")
    }

    func testShelfNavigationKeepsColumnsAndCrossesShelves() {
        let rows = [["a", "b", "c"], ["d", "e"], ["f", "g", "h"]]
        XCTAssertEqual(ShelfNavigator.move(from: "c", .down, rows: rows), "e", "Down clamps to the shorter row")
        XCTAssertEqual(ShelfNavigator.move(from: "e", .down, rows: rows), "g", "Down continues onto the next shelf")
        XCTAssertEqual(ShelfNavigator.move(from: "c", .right, rows: rows), "d", "Right follows reading order")
        XCTAssertEqual(ShelfNavigator.move(from: "a", .left, rows: rows), "a")
        XCTAssertEqual(ShelfNavigator.move(from: "b", .up, rows: rows), "b")
        XCTAssertEqual(ShelfNavigator.move(from: "h", .up, rows: rows), "e")
        XCTAssertEqual(ShelfNavigator.move(from: "missing", .down, rows: rows), "a")
        XCTAssertNil(ShelfNavigator.move(from: nil, .down, rows: []))
    }

    func testLibraryShowsOneTitlePerGameAndRoutesCommands() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let catalog = directory.appendingPathComponent("Library/Manifests")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = [
            manifest("breakout-source", archive: "Breakout.zip", title: "Breakout"),
            manifest("breakout-build", archive: "Breakout.zip", fidelity: "prototype", builtin: "breakout-native-development", title: "Breakout · Native Development"),
            manifest("waiting", archive: "Waiting.zip", title: "Waiting")
        ]
        for record in records { try JSONEncoder().encode(record).write(to: catalog.appendingPathComponent(record.id + ".json")) }
        await MainActor.run {
            let store = GameStore(root: directory, loadSynchronously: true, observeExternalApplications: false)
            XCTAssertNil(store.issue)
            XCTAssertEqual(store.titles.count, 2)
            XCTAssertEqual(store.shelves.map(\.id), ["ready", "waiting"])
            let breakout = try! XCTUnwrap(store.titles.first { $0.id == "breakout-source" })
            XCTAssertTrue(store.isPlayable(breakout))
            XCTAssertEqual(store.primaryBuild(breakout)?.id, "breakout-build")
            XCTAssertEqual(store.count(.ready), 1)
            XCTAssertEqual(store.count(.queue), 1)
            XCTAssertEqual(store.status(breakout), "Prototype", "Shelves must mark development builds")
            XCTAssertEqual(store.shelves.first?.detail, "Prototypes, not finished ports")
            XCTAssertNil(store.status(store.titles.first { $0.id == "waiting" }!))

            // A title without a ready build opens its details instead of launching.
            store.selectedID = "waiting"
            store.navigate(.play)
            XCTAssertNil(store.activeGame)
            XCTAssertEqual(store.presentedTitle?.id, "waiting")
            store.navigate(.up)
            XCTAssertEqual(store.selected?.id, "waiting", "The library ignores navigation while a sheet is open")
            store.presentedTitle = nil
            store.navigate(.details)
            XCTAssertEqual(store.presentedTitle?.id, "waiting")
            store.presentedTitle = nil

            store.gridColumns = 4
            store.navigate(.up)
            XCTAssertEqual(store.selected?.id, "breakout-source", "Up moves from the waiting shelf to the ready shelf")

            store.navigate(.nextSection)
            XCTAssertEqual(store.section, .ready)
            store.navigate(.previousSection)
            store.navigate(.previousSection)
            XCTAssertEqual(store.section, .queue, "Bumpers wrap through the library lists")
            store.search = "break"
            store.navigate(.back)
            XCTAssertEqual(store.section, .all)
            XCTAssertTrue(store.search.isEmpty)

            let wasFavorite = store.isFavorite(breakout)
            store.toggleFavorite(breakout)
            XCTAssertNotEqual(store.isFavorite(breakout), wasFavorite)
            store.toggleFavorite(breakout)
            XCTAssertEqual(store.isFavorite(breakout), wasFavorite)
        }
    }

    func testSuppliedCatalogGroupsEveryBuildWithItsOriginal() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        await MainActor.run {
            let store = GameStore(root: root, loadSynchronously: true, observeExternalApplications: false)
            XCTAssertEqual(store.titles.count, store.games.filter { $0.fidelity == "source" }.count, "One library title per original game")
            XCTAssertTrue(store.titles.allSatisfy { $0.original != nil })
            XCTAssertTrue(store.titles.flatMap(\.builds).allSatisfy { $0.fidelity != "source" })
            let golf = store.titles.first { $0.id == "pga-2005" }
            XCTAssertEqual(golf?.builds.first?.id, "pga2005-original-courses", "Original courses lead the golf builds")
            XCTAssertEqual(store.titles.first?.id, "pga-2005")
        }
    }
}
