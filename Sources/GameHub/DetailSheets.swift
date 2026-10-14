import AppKit
import SwiftUI

struct ControlsSheet: View {
    @ObservedObject var controller: ControllerManager
    @Environment(\.dismiss) private var dismiss
    @State private var keyboardInput = "Press a key, click, or scroll here to test"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sheetHeader("Controls & devices", subtitle: "Check that this Mac sees your controller, keyboard and trackpad.") { dismiss() }
            HStack(spacing: 14) {
                Image(systemName: controller.controllerName == nil ? "gamecontroller" : "gamecontroller.fill").font(.system(size: 28)).foregroundStyle(controller.controllerName == nil ? Hub.dust : Hub.amber)
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.controllerName ?? "No controller found").font(.system(size: 16, weight: .semibold))
                    Text(controller.controllerName == nil ? "Plug in your Xbox controller, then approve the accessory if macOS asks." : controller.controllerName?.contains("· USB") == true ? "Using Game Hub's own USB input. Physical bindings still need testing." : "macOS reports a standard extended gamepad.")
                        .font(.system(size: 12)).foregroundStyle(Hub.dust).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Look Again") { controller.refreshControllers() }.buttonStyle(HubSecondaryButtonStyle(compact: true))
            }
            if controller.controllerName == nil, !controller.usbCandidates.isEmpty {
                Label("USB sees \(controller.usbCandidates.joined(separator: ", ")), but macOS has not offered a usable gamepad profile.", systemImage: "cable.connector")
                    .font(.system(size: 12)).foregroundStyle(Hub.amber).fixedSize(horizontal: false, vertical: true)
            }
            if !controller.usbStatus.isEmpty, controller.controllerName == nil {
                Text(controller.usbStatus).font(.system(size: 11)).foregroundStyle(Hub.dust)
            }
            HStack(spacing: 22) {
                stick("Left stick", x: controller.axes[0], y: controller.axes[1])
                stick("Right stick", x: controller.axes[2], y: controller.axes[3])
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(["A", "B", "X", "Y", "LB", "RB", "LT", "RT", "Menu", "View", "L3", "R3", "Up", "Down", "Left", "Right"].chunked(into: 4), id: \.self) { row in
                        HStack(spacing: 6) {
                            ForEach(row, id: \.self) { name in
                                let down = controller.buttons[name] == true
                                Text(name).font(.system(size: 11, weight: .semibold))
                                    .frame(width: 44, height: 26)
                                    .foregroundStyle(down ? Hub.onAmber : Hub.dust)
                                    .background(down ? Hub.amber : Hub.raised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                    }
                    HStack(spacing: 12) {
                        ForEach(0..<2, id: \.self) { index in
                            HStack(spacing: 6) {
                                Text(index == 0 ? "LT" : "RT").font(.system(size: 11, weight: .medium)).foregroundStyle(Hub.dust)
                                ProgressView(value: Double(controller.triggers[index])).tint(Hub.amber)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(18).background(Hub.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(controller.lastInput).font(.system(size: 12, weight: .medium)).foregroundStyle(Hub.amber).frame(height: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                Label("Keyboard & trackpad", systemImage: "keyboard").font(.system(size: 14, weight: .semibold))
                Text(keyboardInput).font(.system(size: 12, weight: .medium)).foregroundStyle(Hub.amber)
                Text("In the library, arrow keys or the left stick move between games. Return or A plays, Space or X shows details, Y marks a favorite, LB and RB switch lists, and Escape or B goes back. Each game lists its own controls in its details.")
                    .font(.system(size: 12)).foregroundStyle(Hub.dust).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Hub.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Controllers with a macOS extended gamepad profile work here. The XB1 Fusion Pro can also use Game Hub's own USB adapter. Each game's bindings still need testing with your controller.")
                .font(.system(size: 11)).foregroundStyle(Hub.dust).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(28).frame(width: 620).background(Hub.panel).foregroundStyle(Hub.label)
        .background(InputDiagnostics(message: $keyboardInput))
        .onAppear { controller.refreshControllers() }
    }

    private func stick(_ title: String, x: Float, y: Float) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Hub.walnut).frame(width: 88, height: 88)
                Circle().strokeBorder(.white.opacity(0.12)).frame(width: 88, height: 88)
                Rectangle().fill(.white.opacity(0.07)).frame(width: 88, height: 1)
                Rectangle().fill(.white.opacity(0.07)).frame(width: 1, height: 88)
                Circle().fill(Hub.amber).frame(width: 14, height: 14).offset(x: CGFloat(x) * 35, y: -CGFloat(y) * 35)
            }
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Hub.dust)
        }
    }
}

/// Everything about one game: each native build with its own status, notes
/// and controls, and the original copy kept for reference.
struct TitleSheet: View {
    let title: GameTitle
    @ObservedObject var store: GameStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let primary = store.primaryBuild(title)
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                MediaObject(game: title.display).frame(width: 72, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.name).font(Hub.display(30)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text("\(title.display.genre), \(title.platform), \(String(title.display.year))").font(.system(size: 12)).foregroundStyle(Hub.dust)
                }
                Spacer(minLength: 12)
                SheetCloseButton { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if title.builds.isEmpty {
                        section {
                            Text("Not playable yet").font(.system(size: 15, weight: .semibold))
                            Text("This game is waiting for its native Mac version. Having the original copy in the library never makes it playable on its own.").font(.system(size: 12)).foregroundStyle(Hub.dust).lineSpacing(3)
                        }
                    }
                    ForEach(title.builds) { build in buildSection(build) }
                    if let original = title.original { originalSection(original) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 470)
            HStack {
                if let source = title.display.sourceArchive {
                    Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.resolve(source)]) }
                        .buttonStyle(HubSecondaryButtonStyle(compact: true))
                        .disabled(!FileManager.default.fileExists(atPath: store.resolve(source).path))
                }
                Spacer()
                if let primary {
                    Button { dismiss(); store.launch(primary) } label: { Label(title.builds.count > 1 ? "Play \(primary.buildName)" : primary.isPrototype ? "Play prototype" : "Play", systemImage: "play.fill") }
                        .buttonStyle(HubPrimaryButtonStyle(compact: true)).keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { dismiss() }.buttonStyle(HubPrimaryButtonStyle(compact: true)).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28).frame(width: 640).background(Hub.panel).foregroundStyle(Hub.label)
    }

    private func buildSection(_ build: GameManifest) -> some View {
        let reason = store.readiness(build)
        return section {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(build.buildName).font(.system(size: 15, weight: .semibold))
                    Text("\(build.statusLabel). \(build.edition)").font(.system(size: 12)).foregroundStyle(Hub.dust)
                }
                Spacer(minLength: 8)
                if let reason {
                    Label(reason, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Hub.amber)
                } else if title.builds.count > 1 {
                    Button("Play") { dismiss(); store.launch(build) }.buttonStyle(HubSecondaryButtonStyle(compact: true))
                }
            }
            Text(build.summary).font(.system(size: 13)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            notes(build.notes)
            controlList("Keyboard & trackpad", icon: "keyboard", lines: build.keyboard)
            controlList("Controller", icon: "gamecontroller", lines: build.controller)
        }
    }

    private func originalSection(_ original: GameManifest) -> some View {
        let present = original.sourceArchive.map { FileManager.default.fileExists(atPath: store.resolve($0).path) } ?? false
        return section {
            Text("Original copy").font(.system(size: 15, weight: .semibold))
            Text("Kept for reference while the native version is built. Game Hub never runs the original files.").font(.system(size: 12)).foregroundStyle(Hub.dust).lineSpacing(3)
            if original.summary != title.builds.first?.summary { Text(original.summary).font(.system(size: 13)).lineSpacing(4).fixedSize(horizontal: false, vertical: true) }
            if let source = original.sourceArchive {
                HStack(spacing: 8) {
                    Image(systemName: present ? "checkmark.circle.fill" : "questionmark.circle").foregroundStyle(present ? Hub.amber : Hub.dust)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                        Text(present ? "On this Mac" : "Not in the library folder. Restore it from your own copy.").font(.system(size: 11)).foregroundStyle(Hub.dust)
                    }
                }
            }
            notes(original.notes)
        }
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Hub.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Hub.rule))
    }

    @ViewBuilder
    private func notes(_ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(lines, id: \.self) { note in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(title.display.tint).frame(width: 4, height: 4).padding(.top, 6)
                        Text(note).font(.system(size: 12)).foregroundStyle(Hub.dust).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func controlList(_ heading: String, icon: String, lines: [String]) -> some View {
        if !lines.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Hub.dust).frame(width: 18).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(heading).font(.system(size: 12, weight: .semibold))
                    ForEach(lines, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(Hub.label.opacity(0.8)).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
    }
}

struct IntegrationSheet: View {
    @ObservedObject var store: GameStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sheetHeader("Adding your own games", subtitle: "Native Mac games join the library without rebuilding Game Hub.") { dismiss() }
            ForEach(Array([
                ("Build the game for this Mac", "Use an Apple Silicon or Universal .app or executable. Games keep their own assets, saves and settings."),
                ("Add it to the library", "Choose Add a game and select the build, or place a game.json in Library/NativeGames/<game-id>/. Refresh the library to see it."),
                ("Write down and test the controls", "List the keyboard, trackpad and controller bindings in the manifest. Test the real game at 2560 × 1600 with the physical controller before calling it verified.")
            ].enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 14) {
                    Text("\(index + 1)").font(Hub.display(18)).foregroundStyle(Hub.onAmber).frame(width: 30, height: 30).background(Hub.amber, in: Circle())
                    VStack(alignment: .leading, spacing: 5) {
                        Text(step.0).font(.system(size: 14, weight: .semibold))
                        Text(step.1).font(.system(size: 12)).foregroundStyle(Hub.dust).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("Original copies, development builds, native games and verified ports each keep their own status. A library entry on its own never makes a game playable.")
                .font(.system(size: 12)).foregroundStyle(Hub.dust).lineSpacing(3).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Hub.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                Button("Open Integration Guide") {
                    let local = store.root.appendingPathComponent("docs/INTEGRATION.md")
                    if FileManager.default.fileExists(atPath: local.path) { NSWorkspace.shared.open(local) }
                    else if let resource = Bundle.main.resourceURL { NSWorkspace.shared.open(resource.appendingPathComponent("INTEGRATION.md")) }
                }
                .buttonStyle(HubSecondaryButtonStyle(compact: true))
                Spacer()
                Button("Add a Game…") { dismiss(); store.importNativeApp() }.buttonStyle(HubPrimaryButtonStyle(compact: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 580).background(Hub.panel).foregroundStyle(Hub.label)
    }
}

private func sheetHeader(_ title: String, subtitle: String, dismiss: @escaping () -> Void) -> some View {
    HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Hub.display(30))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Hub.dust)
        }
        Spacer(minLength: 12)
        SheetCloseButton(action: dismiss)
    }
}

private struct InputDiagnostics: NSViewRepresentable {
    @Binding var message: String
    func makeNSView(context: Context) -> NSView {
        context.coordinator.install { message = $0 }
        return NSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.handler = { message = $0 } }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var monitor: Any?
        var handler: ((String) -> Void)?
        func install(_ handler: @escaping (String) -> Void) {
            self.handler = handler
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
                let text: String
                switch event.type {
                case .keyDown: text = "Key: \(event.charactersIgnoringModifiers ?? "") · code \(event.keyCode)"
                case .leftMouseDown: text = "Trackpad / mouse: primary click"
                case .rightMouseDown: text = "Trackpad / mouse: secondary click"
                default: text = String(format: "Trackpad / mouse: scroll %.1f, %.1f", event.scrollingDeltaX, event.scrollingDeltaY)
                }
                self?.handler?(text)
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
