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
                Button("Add Native Game…") { store.importNativeApp() }.keyboardShortcut("o")
                Button("Refresh Library") { store.reload() }.keyboardShortcut("r")
            }
            CommandMenu("Game") {
                Button("Play Selected Game") { if let game = store.selected { store.launch(game) } }.keyboardShortcut(.return, modifiers: .command)
                Button("Return to Library") { store.activeGame = nil }.keyboardShortcut(.escape, modifiers: [])
                Button("Reveal Game Hub Folder") { NSWorkspace.shared.open(store.root) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
