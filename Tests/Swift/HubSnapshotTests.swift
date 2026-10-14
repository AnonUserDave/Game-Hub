import AppKit
import SwiftUI
import XCTest
@testable import GameHub

/// Opt-in visual capture of the library window:
/// GAMEHUB_HUB_SNAPSHOT_DIR=/path ./Tools/test.sh -XCTest GameHubTests.HubSnapshotTests
/// Renders the hub offscreen at the default window size and the M1 Air's
/// default 1440 × 900 desktop, both at 2× backing scale. The hub draws only
/// code-generated artwork and manifest text, but keep captures outside Git
/// with every other build output. GAMEHUB_HUB_SNAPSHOT_ROOT selects another
/// library folder; it defaults to this checkout.
final class HubSnapshotTests: XCTestCase {
    func testRenderLibraryWindow() async throws {
        guard let output = ProcessInfo.processInfo.environment["GAMEHUB_HUB_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set GAMEHUB_HUB_SNAPSHOT_DIR to capture the library window")
        }
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = ProcessInfo.processInfo.environment["GAMEHUB_HUB_SNAPSHOT_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? checkout
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await MainActor.run {
            _ = NSApplication.shared
            let store = GameStore(root: root, loadSynchronously: true, observeExternalApplications: false)
            let controller = ControllerManager()
            for (name, size) in [("hub-1360x900", CGSize(width: 1360, height: 900)), ("hub-1440x900", CGSize(width: 1440, height: 900)), ("hub-1080x720", CGSize(width: 1080, height: 720))] {
                try capture(HubView(store: store, controller: controller), size: size, to: directory.appendingPathComponent(name + ".png"))
            }
            // The remaining shelf, with a title that has no native build selected.
            store.section = .queue
            store.selectedID = store.shelves.first?.titles.last?.id
            try capture(HubView(store: store, controller: controller), size: CGSize(width: 1360, height: 900), to: directory.appendingPathComponent("hub-queue.png"))
            store.section = .all
            for title in [store.titles.first, store.titles.first { $0.builds.isEmpty }].compactMap({ $0 }) {
                try capture(TitleSheet(title: title, store: store), size: CGSize(width: 640, height: 760), to: directory.appendingPathComponent("sheet-\(title.id).png"))
            }
            try capture(ControlsSheet(controller: controller), size: CGSize(width: 620, height: 760), to: directory.appendingPathComponent("sheet-controls.png"))
            try capture(IntegrationSheet(store: store), size: CGSize(width: 580, height: 520), to: directory.appendingPathComponent("sheet-integration.png"))
        }
    }

    @MainActor
    private func capture(_ view: some View, size: CGSize, to url: URL) throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).preferredColorScheme(.dark))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        // Let SwiftUI settle its first layout and any onAppear state.
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw XCTSkip("Bitmap unavailable") }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        window.contentView = nil
    }
}
