import AppKit
import Foundation
import SwiftUI

struct NativeLaunch: Codable, Equatable {
    var kind: String
    var path: String?
    var arguments: [String]?
    var builtin: String?
}

struct GameManifest: Codable, Identifiable, Equatable {
    var schemaVersion: Int
    var id: String
    var title: String
    var edition: String
    var platform: String
    var year: Int
    var genre: String
    var summary: String
    var sourceArchive: String?
    var accent: String
    var artwork: String
    var launch: NativeLaunch?
    var fidelity: String
    var notes: [String]
    var keyboard: [String]
    var controller: [String]

    var tint: Color { Color(hex: accent) }
    var isPrototype: Bool { fidelity == "prototype" }
    var statusLabel: String {
        switch fidelity {
        case "prototype": return "Development prototype"
        case "verified": return "Verified native port"
        case "native": return "Native Mac build"
        default: return "Original media · port needed"
        }
    }
}

enum LibrarySection: String, CaseIterable, Identifiable {
    case all = "All games", favorites = "Favorites", ready = "Playable builds", queue = "Port queue"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .favorites: return "heart"
        case .ready: return "play.circle"
        case .queue: return "hammer"
        }
    }
}

struct HubIssue: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class GameStore: ObservableObject {
    @Published var games: [GameManifest] = []
    @Published var selectedID: String?
    @Published var section: LibrarySection = .all
    @Published var search = ""
    @Published var platform = "All platforms"
    @Published var favorites: Set<String> = []
    @Published var lastPlayed: [String: Double] = [:]
    @Published var issue: HubIssue?
    @Published var activeGame: GameManifest?
    @Published var externalGame: GameManifest?
    @Published private(set) var launchingGameID: String?
    @Published var importMessage: String?
    @Published private(set) var root: URL
    @Published private(set) var loadingLibrary = false
    @Published private(set) var libraryStatus = ""
    private var loadGeneration = 0
    private var nativeReadiness: [String: String] = [:]
    private var process: Process?
    private var runningApplication: NSRunningApplication?
    private var terminationObserver: NSObjectProtocol?

    init(root: URL = GameStore.workspaceRoot(), loadSynchronously: Bool = false, observeExternalApplications: Bool = true) {
        self.root = root
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
        lastPlayed = UserDefaults.standard.dictionary(forKey: "lastPlayed") as? [String: Double] ?? [:]
        if loadSynchronously {
            apply(CatalogLoader.load(root: root, builtinIDs: Self.builtinIDs))
        } else {
            loadingLibrary = true
            libraryStatus = "Opening collection…"
            // Construct the window before any Desktop/TCC or external-drive IO.
            Task { [weak self] in
                guard let self else { return }
                let bundled = Bundle.main.resourceURL?.appendingPathComponent("Manifests")
                let starter = await Task.detached(priority: .userInitiated) {
                    CatalogLoader.load(root: root, builtinIDs: NativeGameFactory.availableIDs, catalog: bundled, includeNativeGames: false)
                }.value
                self.apply(starter)
                self.reload()
            }
        }
        if observeExternalApplications {
            terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                guard let self, self.runningApplication?.processIdentifier == app.processIdentifier else { return }
                self.runningApplication = nil
                self.externalGame = nil
                NSApp.activate(ignoringOtherApps: true)
            }
            }
        }
    }

    deinit {
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
    }

    nonisolated static func workspaceRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["GAMEHUB_LIBRARY_ROOT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // The built app and the original archives live beside each other. Moving
        // the entire Game Hub folder keeps relative native game paths working.
        return Bundle.main.bundleURL.deletingLastPathComponent()
    }

    var selected: GameManifest? { filtered.first { $0.id == selectedID } ?? filtered.first }
    var readyCount: Int { games.filter { readiness($0) == nil }.count }
    var platforms: [String] { ["All platforms"] + Set(games.map(\.platform)).sorted() }
    var filtered: [GameManifest] {
        games.filter { game in
            let sectionMatches: Bool
            switch section {
            case .all: sectionMatches = true
            case .favorites: sectionMatches = favorites.contains(game.id)
            case .ready: sectionMatches = readiness(game) == nil
            case .queue: sectionMatches = readiness(game) != nil
            }
            return sectionMatches
                && (platform == "All platforms" || platform == game.platform)
                && (search.isEmpty || "\(game.title) \(game.edition) \(game.platform) \(game.genre)".localizedCaseInsensitiveContains(search))
        }
    }

    func reload() {
        loadGeneration += 1
        let generation = loadGeneration, root = self.root
        loadingLibrary = true
        libraryStatus = "Reading library…"
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                CatalogLoader.load(root: root, builtinIDs: NativeGameFactory.availableIDs)
            }.value
            guard let self, self.loadGeneration == generation else { return }
            if !result.games.isEmpty { self.apply(result) }
            else if !result.errors.isEmpty { self.issue = HubIssue(title: "Library needs access", message: result.errors.joined(separator: "\n")) }
            self.loadingLibrary = false
            self.libraryStatus = result.games.isEmpty ? "Choose your Game Hub folder to load the library" : "Library up to date"
        }
    }

    private func apply(_ result: CatalogLoadResult) {
        nativeReadiness = result.readiness
        games = result.games.sorted {
            let priorityA = $0.id == "pga2005-native-development" ? 0 : $0.id == "pga-2005" ? 1 : 2
            let priorityB = $1.id == "pga2005-native-development" ? 0 : $1.id == "pga-2005" ? 1 : 2
            if priorityA != priorityB { return priorityA < priorityB }
            let a = readiness($0) == nil, b = readiness($1) == nil
            return a == b ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : a
        }
        if !games.contains(where: { $0.id == selectedID }) { selectedID = games.first?.id }
        if !result.errors.isEmpty { issue = HubIssue(title: "Some manifests could not load", message: result.errors.joined(separator: "\n")) }
    }

    nonisolated func validate(_ game: GameManifest) throws { try Self.validateManifest(game) }

    nonisolated static func validateManifest(_ game: GameManifest) throws {
        guard game.schemaVersion == 1 else { throw ManifestError.invalid("Unsupported manifest version") }
        guard !game.id.isEmpty, game.id.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil else {
            throw ManifestError.invalid("Use a stable lowercase game ID with letters, digits, dots, or hyphens")
        }
        guard !game.title.isEmpty else { throw ManifestError.invalid("A game title is required") }
        guard ["source", "prototype", "native", "verified"].contains(game.fidelity) else {
            throw ManifestError.invalid("fidelity must be source, prototype, native, or verified")
        }
        guard game.accent.range(of: "^#?[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
            throw ManifestError.invalid("accent must be a six-digit RGB hex color")
        }
        guard game.fidelity != "source" || game.launch == nil else {
            throw ManifestError.invalid("Source-only entries cannot have a launch configuration")
        }
        if let launch = game.launch {
            guard ["builtin", "app", "executable"].contains(launch.kind) else {
                throw ManifestError.invalid("Only native builtin, app, and executable launches are supported")
            }
            if launch.kind == "builtin" {
                guard Self.builtinIDs.contains(launch.builtin ?? "") else { throw ManifestError.invalid("Unknown built-in native game") }
            } else {
                guard let path = launch.path, !path.isEmpty else { throw ManifestError.invalid("A native launch path is required") }
                guard !["exe", "com", "bat", "cmd", "iso", "bin", "rom", "dsk"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else {
                    throw ManifestError.invalid("Windows executables, disc images, and ROMs are source material, not native Mac games")
                }
            }
        }
    }

    nonisolated static var builtinIDs: Set<String> { NativeGameFactory.availableIDs }

    func resolve(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path).standardizedFileURL
    }

    /// Returns an actionable reason when a title cannot be launched. Having an
    /// archive in the library never makes an unimplemented port appear playable.
    func readiness(_ game: GameManifest) -> String? {
        guard let launch = game.launch else { return "Native rewrite needed" }
        if launch.kind == "builtin" {
            guard Self.builtinIDs.contains(launch.builtin ?? "") else { return "Native module unavailable" }
            if !RetroOriginalMedia.requiredIDs.contains(launch.builtin ?? "") { return nil }
        }
        guard let cached = nativeReadiness[game.id] else { return "Checking native build…" }
        return cached.isEmpty ? nil : cached
    }

    /// Catalog readiness is cached for responsive browsing. Check again before
    /// launch because an external build can move or change after Refresh.
    nonisolated static func externalBuildReadiness(_ launch: NativeLaunch, root: URL) -> String {
        guard let path = launch.path else { return "Native build not found" }
        let target = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path).standardizedFileURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { return "Native build not found" }
        if launch.kind == "app" {
            guard let executable = Bundle(url: target)?.executableURL,
                  fm.isExecutableFile(atPath: executable.path),
                  isNativeMachO(executable) else { return "App needs an executable Apple Silicon build" }
            return ""
        }
        return fm.isExecutableFile(atPath: target.path) && isNativeMachO(target) ? "" : "An executable Apple Silicon build is required"
    }

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose your Game Hub folder"
        panel.message = "Select the folder containing Library and your original game archives. This grants access through macOS."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        root = url
        reload()
    }

    nonisolated static func isNativeMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), data.count >= 8 else { return false }
        let bytes = [UInt8](data)
        func u32(_ offset: Int, little: Bool) -> UInt32 {
            let b = Array(bytes[offset..<(offset + 4)])
            return little ? UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
                          : UInt32(b[3]) | UInt32(b[2]) << 8 | UInt32(b[1]) << 16 | UInt32(b[0]) << 24
        }
        if bytes.prefix(4).elementsEqual([0xcf, 0xfa, 0xed, 0xfe]) { return u32(4, little: true) == 0x0100000c }
        let fat32 = bytes.prefix(4).elementsEqual([0xca, 0xfe, 0xba, 0xbe])
        let fat64 = bytes.prefix(4).elementsEqual([0xca, 0xfe, 0xba, 0xbf])
        if fat32 || fat64 {
            let count = Int(u32(4, little: false)), stride = fat64 ? 32 : 20
            guard count <= 64, 8 + count * stride <= bytes.count else { return false }
            return (0..<count).contains { u32(8 + $0 * stride, little: false) == 0x0100000c }
        }
        return false
    }

    func toggleFavorite(_ game: GameManifest) {
        if favorites.contains(game.id) { favorites.remove(game.id) } else { favorites.insert(game.id) }
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
    }

    func recordPlay(_ game: GameManifest) {
        lastPlayed[game.id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(lastPlayed, forKey: "lastPlayed")
    }

    func launch(_ game: GameManifest) {
        guard launchingGameID == nil else { return }
        guard externalGame == nil, activeGame == nil else {
            issue = HubIssue(title: "A game is already running", message: "Return to or close \(externalGame?.title ?? activeGame?.title ?? "the current game") before starting another game.")
            return
        }
        if let reason = readiness(game) {
            let explanation = RetroOriginalMedia.requiredIDs.contains(game.launch?.builtin ?? "") ? "This native development module requires its prepared original graphics." : game.title + " has not been rewritten for this Mac."
            issue = HubIssue(title: reason, message: ([explanation] + game.notes).joined(separator: "\n\n"))
            return
        }
        guard let launch = game.launch else { return }
        if launch.kind == "builtin" {
            guard RetroOriginalMedia.requiredIDs.contains(launch.builtin ?? "") else { recordPlay(game); activeGame = game; return }
            let mediaRoot = root, builtin = launch.builtin ?? ""
            launchingGameID = game.id
            Task { [weak self] in
                let reason = await Task.detached(priority: .userInitiated) { RetroOriginalMedia.readiness(id: builtin, root: mediaRoot) }.value
                guard let self else { return }
                self.launchingGameID = nil
                guard self.root == mediaRoot else { return }
                self.nativeReadiness[game.id] = reason
                guard reason.isEmpty else { self.issue = HubIssue(title: "Original media changed", message: "\(game.title) needs its prepared original graphics. Run the title's preparation tool and refresh the library."); return }
                self.recordPlay(game); self.activeGame = game
            }
            return
        }
        let currentReadiness = Self.externalBuildReadiness(launch, root: root)
        guard currentReadiness.isEmpty else {
            nativeReadiness[game.id] = currentReadiness
            issue = HubIssue(title: "Native build changed", message: "\(game.title): \(currentReadiness). Refresh the library after updating the build.")
            return
        }
        let url = resolve(launch.path!)
        if launch.kind == "app" {
            launchingGameID = game.id
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = launch.arguments ?? []
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.launchingGameID = nil
                    if let error { self.issue = HubIssue(title: "Couldn't open game", message: error.localizedDescription) }
                    else { self.runningApplication = app; self.externalGame = game; self.recordPlay(game) }
                }
            }
        } else {
            let child = Process()
            child.executableURL = url
            child.arguments = launch.arguments ?? []
            child.currentDirectoryURL = url.deletingLastPathComponent()
            var environment = ProcessInfo.processInfo.environment
            environment["GAMEHUB_LIBRARY_ROOT"] = root.path
            environment["GAMEHUB_GAME_ID"] = game.id
            child.environment = environment
            child.terminationHandler = { [weak self] task in
                Task { @MainActor in
                    guard let self else { return }
                    self.externalGame = nil
                    self.process = nil
                    NSApp.activate(ignoringOtherApps: true)
                    if task.terminationStatus != 0 { self.issue = HubIssue(title: "Game stopped", message: "\(game.title) exited with code \(task.terminationStatus). Check the game's own logs.") }
                }
            }
            do { try child.run(); process = child; externalGame = game; recordPlay(game) }
            catch { issue = HubIssue(title: "Couldn't start game", message: error.localizedDescription) }
        }
    }

    func returnToExternalGame() {
        if let runningApplication { runningApplication.activate(options: [.activateAllWindows]) }
        else if let pid = process?.processIdentifier { NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows]) }
    }

    func navigate(_ direction: HubNavigation) {
        guard activeGame == nil else { return }
        let visible = filtered
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == selectedID } ?? 0
        switch direction {
        case .play: launch(visible[index])
        case .back: search = ""; section = .all; platform = "All platforms"
        case .left: selectedID = visible[max(0, index - 1)].id
        case .right: selectedID = visible[min(visible.count - 1, index + 1)].id
        case .up: selectedID = visible[max(0, index - 3)].id
        case .down: selectedID = visible[min(visible.count - 1, index + 3)].id
        }
    }

    func importNativeApp() {
        let panel = NSOpenPanel()
        panel.title = "Add a native Apple Silicon game"
        panel.message = "Choose a native Mac .app, arm64 executable, or game.json manifest. Your game stays in its original location."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var game: GameManifest
            if url.pathExtension == "json" {
                game = try JSONDecoder().decode(GameManifest.self, from: Data(contentsOf: url))
                // Paths in an imported standalone manifest are relative to that
                // manifest. Store absolute references; never copy a huge game.
                if let path = game.launch?.path, !path.hasPrefix("/") { game.launch?.path = url.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL.path }
            } else {
                let isApp = url.pathExtension.lowercased() == "app"
                let executable = isApp ? Bundle(url: url)?.executableURL : url
                guard let executable, Self.isNativeMachO(executable), FileManager.default.isExecutableFile(atPath: executable.path) else {
                    throw ManifestError.invalid("Choose a native arm64 or Universal Mac .app or executable. Original Windows games and ROMs need a native rewrite first.")
                }
                let title = url.deletingPathExtension().lastPathComponent
                let slug = title.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                game = GameManifest(schemaVersion: 1, id: "native-" + (slug.isEmpty ? UUID().uuidString.lowercased() : slug), title: title, edition: "Native Mac", platform: "macOS", year: Calendar.current.component(.year, from: Date()), genre: "Native game", summary: "A native Apple Silicon game in your collection.", sourceArchive: nil, accent: "B8ED82", artwork: "native", launch: NativeLaunch(kind: isApp ? "app" : "executable", path: url.path), fidelity: "native", notes: ["The game provides its own graphics, save files, and controller bindings. Import checks architecture; it does not certify game fidelity or controller support."], keyboard: ["Use the game's keyboard and trackpad settings."], controller: ["Controller support depends on the imported game."])
            }
            try validate(game)
            guard !games.contains(where: { $0.id == game.id }) else { throw ManifestError.invalid("A game with this ID is already in your library. Edit its existing manifest to update it.") }
            let directory = root.appendingPathComponent("Library/Manifests")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(game).write(to: directory.appendingPathComponent(game.id + ".json"), options: .atomic)
            reload(); selectedID = game.id; section = .all; search = ""; platform = "All platforms"
            importMessage = "Added \(game.title)"
        } catch { issue = HubIssue(title: "Couldn't add native game", message: error.localizedDescription) }
    }
}

private struct CatalogLoadResult {
    var games: [GameManifest] = []
    var errors: [String] = []
    var readiness: [String: String] = [:]
}

/// Runs only on a background worker in the application. Catalog directories are
/// shallow and explicit; native asset trees and app bundles are never traversed.
private enum CatalogLoader {
    static func load(root: URL, builtinIDs: Set<String>, catalog: URL? = nil, includeNativeGames: Bool = true) -> CatalogLoadResult {
        var result = CatalogLoadResult()
        let fm = FileManager.default
        let manifestDirectory = catalog ?? root.appendingPathComponent("Library/Manifests")
        var urls = list(manifestDirectory, errors: &result.errors).filter { $0.pathExtension.lowercased() == "json" }
        if includeNativeGames {
            let native = root.appendingPathComponent("Library/NativeGames")
            urls += list(native, errors: &result.errors).map { $0.appendingPathComponent("game.json") }.filter { fm.fileExists(atPath: $0.path) }
        }
        for url in urls.sorted(by: { $0.path < $1.path }) {
            do {
                let game = try JSONDecoder().decode(GameManifest.self, from: Data(contentsOf: url))
                try GameStore.validateManifest(game)
                guard !result.games.contains(where: { $0.id == game.id }) else { throw ManifestError.invalid("Duplicate game ID: \(game.id)") }
                result.games.append(game)
                if let launch = game.launch {
                    result.readiness[game.id] = launch.kind == "builtin" ? RetroOriginalMedia.readiness(id: launch.builtin ?? "", root: root) : GameStore.externalBuildReadiness(launch, root: root)
                }
            } catch { result.errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return result
    }

    private static func list(_ directory: URL, errors: inout [String]) -> [URL] {
        do { return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) }
        catch {
            let nsError = error as NSError
            if nsError.code != NSFileReadNoSuchFileError { errors.append("\(directory.lastPathComponent): \(error.localizedDescription). Use Choose library folder to grant access.") }
            return []
        }
    }
}

enum ManifestError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xB8ED82
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}
