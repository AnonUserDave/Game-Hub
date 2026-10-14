import AppKit
import SwiftUI

private let sheetGreen = Color(hex: "C2EF93")
private let sheetMuted = Color(hex: "9199A7")

struct ControlsSheet: View {
    @ObservedObject var controller: ControllerManager
    @Environment(\.dismiss) private var dismiss
    @State private var keyboardInput = "Press a key, click, or scroll here to test"

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            sheetHeader("Controls & devices", subtitle: "Input diagnostics for this Mac", dismiss: { dismiss() })
            HStack(spacing: 14) {
                Image(systemName: "gamecontroller").font(.system(size: 31)).foregroundStyle(sheetGreen)
                VStack(alignment: .leading, spacing: 5) {
                    Text(controller.controllerName ?? "No controller detected").font(.system(size: 16, weight: .semibold))
                    Text(controller.controllerName == nil ? "Plug in your Xbox controller, then approve the accessory if macOS asks." : controller.controllerName?.contains("· USB") == true ? "Native user-space USB input · physical bindings need validation." : "macOS is exposing an extended gamepad profile.")
                        .font(.system(size: 11)).foregroundStyle(sheetMuted)
                }
                Spacer()
                Button("Refresh") { controller.refreshControllers() }.buttonStyle(.bordered)
            }
            if controller.controllerName == nil, !controller.usbCandidates.isEmpty {
                Label("USB seen: \(controller.usbCandidates.joined(separator: ", ")). macOS has not provided a usable gamepad profile.", systemImage: "cable.connector")
                    .font(.system(size: 11)).foregroundStyle(Color(hex: "E5B97A")).fixedSize(horizontal: false, vertical: true)
            }
            if !controller.usbStatus.isEmpty, controller.controllerName == nil {
                Text(controller.usbStatus).font(.system(size: 10, design: .monospaced)).foregroundStyle(sheetMuted)
            }
            HStack(spacing: 18) {
                stick("LEFT STICK", x: controller.axes[0], y: controller.axes[1])
                stick("RIGHT STICK", x: controller.axes[2], y: controller.axes[3])
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(["A", "B", "X", "Y", "LB", "RB", "LT", "RT", "Menu", "View", "L3", "R3", "Up", "Down", "Left", "Right"].chunked(into: 4), id: \.self) { row in
                        HStack(spacing: 7) {
                            ForEach(row, id: \.self) { name in
                                Text(name).font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .frame(width: 41, height: 26)
                                    .foregroundStyle(controller.buttons[name] == true ? Color.black : sheetMuted)
                                    .background(controller.buttons[name] == true ? sheetGreen : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                    }
                }
            }.padding(18).background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 20) {
                ForEach(0..<2, id: \.self) { index in
                    HStack(spacing: 8) {
                        Text(index == 0 ? "LT" : "RT").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(sheetMuted)
                        ProgressView(value: Double(controller.triggers[index])).tint(sheetGreen)
                    }
                }
            }
            Text(controller.lastInput).font(.system(size: 11, design: .monospaced)).foregroundStyle(sheetGreen).frame(height: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 9) {
                Label("Keyboard + trackpad", systemImage: "keyboard").font(.system(size: 14, weight: .semibold))
                Text(keyboardInput).font(.system(size: 11, design: .monospaced)).foregroundStyle(sheetGreen)
                Text("In the hub: arrow keys or left stick / D-pad select games; Return or A opens a game; Escape or B clears filters. Each native game defines its own bindings, shown in its details.")
                    .font(.system(size: 11)).foregroundStyle(sheetMuted).lineSpacing(4)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
            Text("Supported macOS controllers use extended gamepad profiles. The XB1 Fusion Pro can use this app’s native USB adapter. Physical bindings and future ports still need testing with your controller.")
                .font(.system(size: 10)).foregroundStyle(sheetMuted).lineSpacing(3)
        }
        .padding(30).frame(width: 610).background(Color(hex: "14181F"))
        .background(InputDiagnostics(message: $keyboardInput))
        .onAppear { controller.refreshControllers() }
    }

    private func stick(_ title: String, x: Float, y: Float) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(.white.opacity(0.025)).frame(width: 88, height: 88)
                Circle().stroke(.white.opacity(0.14)).frame(width: 88, height: 88)
                Rectangle().fill(.white.opacity(0.08)).frame(width: 88, height: 1)
                Rectangle().fill(.white.opacity(0.08)).frame(width: 1, height: 88)
                Circle().fill(sheetGreen).frame(width: 14, height: 14).offset(x: CGFloat(x) * 35, y: -CGFloat(y) * 35)
            }
            Text(title).font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(0.7).foregroundStyle(sheetMuted)
        }
    }
}

struct PortSheet: View {
    let game: GameManifest
    @ObservedObject var store: GameStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sheetHeader(game.title, subtitle: "\(game.edition) · \(game.platform)", dismiss: { dismiss() })
            HStack(spacing: 9) {
                Circle().fill(game.tint).frame(width: 6, height: 6)
                Text(game.statusLabel.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1)
                Spacer()
            }.foregroundStyle(game.tint)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(game.summary).font(.system(size: 13)).lineSpacing(5)
                    VStack(alignment: .leading, spacing: 11) {
                        ForEach(game.notes, id: \.self) { note in
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: "circle.fill").font(.system(size: 4)).padding(.top, 6).foregroundStyle(game.tint)
                                Text(note).font(.system(size: 11)).foregroundStyle(sheetMuted).lineSpacing(4)
                            }
                        }
                    }
                    if let source = game.sourceArchive {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ORIGINAL MEDIA").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(game.tint)
                            Text(source).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).foregroundStyle(sheetMuted)
                            Text(FileManager.default.fileExists(atPath: store.resolve(source).path) ? "Archive present on this Mac. This is reference material for the rewrite." : "Archive is not at the configured library location. Restore it from your own copy.")
                                .font(.system(size: 11)).foregroundStyle(sheetMuted)
                        }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                    }
                    controlList("KEYBOARD & TRACKPAD", lines: game.keyboard)
                    controlList("XBOX / EXTENDED GAMEPAD", lines: game.controller)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 390)
            HStack {
                if let source = game.sourceArchive {
                    Button("Reveal original archive") { NSWorkspace.shared.activateFileViewerSelecting([store.resolve(source)]) }
                        .disabled(!FileManager.default.fileExists(atPath: store.resolve(source).path))
                }
                Spacer()
                if store.readiness(game) == nil {
                    Button(game.isPrototype ? "Open prototype" : "Play game") { dismiss(); store.launch(game) }.buttonStyle(.borderedProminent).tint(game.tint).foregroundStyle(.black)
                } else {
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent).tint(game.tint).foregroundStyle(.black)
                }
            }.font(.system(size: 11))
        }.padding(30).frame(width: 620).background(Color(hex: "14181F"))
    }

    private func controlList(_ title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(game.tint)
            ForEach(lines, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(sheetMuted).lineSpacing(3) }
        }
    }
}

struct IntegrationSheet: View {
    @ObservedObject var store: GameStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            sheetHeader("A library that grows with you", subtitle: "Add future native games without rebuilding the hub", dismiss: { dismiss() })
            ForEach(Array([
                ("1", "Build your native game", "Use an Apple Silicon or Universal Mac .app or executable. Games keep their own assets, saves, and settings."),
                ("2", "Add a game manifest", "Use Add game to select the build, or place a game.json in Library/NativeGames/<game-id>/. The hub discovers it on Refresh."),
                ("3", "Document and test the controls", "Record keyboard, trackpad, and Xbox bindings in the manifest. Test the real game at 2560 × 1600 and with the physical controller before calling it verified.")
            ].enumerated()), id: \.offset) { _, step in
                HStack(alignment: .top, spacing: 15) {
                    Text(step.0).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(sheetGreen).frame(width: 30, height: 30).background(sheetGreen.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(step.1).font(.system(size: 14, weight: .semibold))
                        Text(step.2).font(.system(size: 11)).foregroundStyle(sheetMuted).lineSpacing(4)
                    }
                }
            }
            Text("Original media, development prototypes, native builds, and verified ports have distinct statuses. A catalog entry by itself does not make a game playable.")
                .font(.system(size: 11)).foregroundStyle(sheetMuted).lineSpacing(4).padding(15).background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
            HStack {
                Button("Open integration guide") {
                    let local = store.root.appendingPathComponent("docs/INTEGRATION.md")
                    if FileManager.default.fileExists(atPath: local.path) { NSWorkspace.shared.open(local) }
                    else if let resource = Bundle.main.resourceURL { NSWorkspace.shared.open(resource.appendingPathComponent("INTEGRATION.md")) }
                }
                Spacer()
                Button("Add native game…") { dismiss(); store.importNativeApp() }.buttonStyle(.borderedProminent).tint(sheetGreen).foregroundStyle(.black)
            }.font(.system(size: 11))
        }.padding(30).frame(width: 590).background(Color(hex: "14181F"))
    }
}

private func sheetHeader(_ title: String, subtitle: String, dismiss: @escaping () -> Void) -> some View {
    HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .bold)).tracking(-0.4)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(sheetMuted)
        }
        Spacer(minLength: 12)
        Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(sheetMuted).frame(width: 26, height: 26).background(.white.opacity(0.06), in: Circle()) }
            .buttonStyle(.plain).keyboardShortcut(.escape, modifiers: []).help("Close")
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
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
