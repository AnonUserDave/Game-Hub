import AppKit
import SwiftUI

@main
struct GameHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = GameStore()
    @StateObject private var controller = ControllerManager()
    var body: some Scene {
        Window("Game Hub", id: "library") {
            HubView(store: store, controller: controller)
                .frame(minWidth: 1080, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1360, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add a Game…") { store.importNativeApp() }.keyboardShortcut("o").disabled(busy)
                Button("Refresh Library") { store.reload() }.keyboardShortcut("r")
            }
            // The hub has one search field; ⌘F goes straight to it.
            CommandGroup(replacing: .textEditing) {
                Button("Find a Game") { store.searchFocusRequest += 1 }.keyboardShortcut("f").disabled(busy)
            }
            CommandGroup(before: .toolbar) {
                ForEach(Array(LibrarySection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.rawValue) { store.section = section; store.platform = GameStore.allPlatforms }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)"))).disabled(busy)
                }
                Divider()
            }
            CommandMenu("Game") {
                Button("Play") { if let title = store.selected { store.play(title) } }.keyboardShortcut(.return, modifiers: .command).disabled(busy || store.selected == nil)
                Button("Show Details") { store.presentedTitle = store.selected }.keyboardShortcut("i").disabled(busy || store.selected == nil)
                Button(store.selected.map(store.isFavorite) == true ? "Remove from Favorites" : "Add to Favorites") { if let title = store.selected { store.toggleFavorite(title) } }
                    .keyboardShortcut("d").disabled(busy || store.selected == nil)
                Divider()
                Button("Controls & Devices…") { store.utilitySheet = .controls }.disabled(busy)
                Button("Return to Library") { store.activeGame = nil }.keyboardShortcut(.escape, modifiers: [])
                Button("Reveal Game Hub Folder") { NSWorkspace.shared.open(store.root) }
            }
        }
    }

    /// Library commands wait while a game, sheet or alert is in front.
    private var busy: Bool { store.activeGame != nil || store.sheetOpen || store.issue != nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
