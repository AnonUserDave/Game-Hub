import AppKit
import SwiftUI

private let hubBackground = Color(hex: "111419")
private let panelBackground = Color(hex: "191D24")
private let hubGreen = Color(hex: "C2EF93")
private let mutedText = Color(hex: "9199A7")

struct HubView: View {
    @ObservedObject var store: GameStore
    @ObservedObject var controller: ControllerManager
    @State private var showingControls = false
    @State private var portGame: GameManifest?
    @State private var showingIntegration = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            if let game = store.activeGame {
                NativeGameContainer(game: game) { store.activeGame = nil }
            } else {
                HStack(spacing: 0) {
                    sidebar
                    Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
                    VStack(spacing: 0) {
                        toolbar
                        ScrollViewReader { reader in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 25) {
                                    if let game = store.selected { featured(game) }
                                    libraryHeader
                                    if store.filtered.isEmpty { emptyState }
                                    else {
                                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 3), spacing: 20) {
                                            ForEach(store.filtered) { game in gameCard(game).id(game.id) }
                                        }
                                    }
                                    HStack(spacing: 8) {
                                        Image(systemName: "cpu")
                                        Text("NATIVE MAC LIBRARY")
                                        Text("·").padding(.horizontal, 3)
                                        Text("Original archives preserved")
                                        Spacer()
                                        Button("Integration guide") { showingIntegration = true }.buttonStyle(.plain).foregroundStyle(hubGreen)
                                    }
                                    .font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(0.4).foregroundStyle(mutedText).padding(.top, 8)
                                }
                                .padding(.horizontal, 32).padding(.top, 12).padding(.bottom, 28)
                            }
                            .onChange(of: store.selectedID) { _, id in
                                if let id { withAnimation(.easeOut(duration: 0.18)) { reader.scrollTo(id, anchor: .center) } }
                            }
                        }
                        footer
                    }
                }
            }
        }
        .background(hubBackground)
        .onAppear {
            controller.onNavigate = { direction in
                guard !showingControls, portGame == nil, !showingIntegration, !searchFocused else { return }
                if case .play = direction, let game = store.selected, store.readiness(game) != nil { portGame = game; return }
                store.navigate(direction)
            }
        }
        .onChange(of: store.activeGame?.id) { _, id in controller.navigationEnabled = id == nil }
        .onChange(of: store.search) { _, _ in
            if !store.filtered.contains(where: { $0.id == store.selectedID }) { store.selectedID = store.filtered.first?.id }
        }
        .background(KeyboardHandler { event in
            guard store.activeGame == nil, !showingControls, portGame == nil, !showingIntegration else { return false }
            guard !(NSApp.keyWindow?.firstResponder is NSTextView) else { return false }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            switch event.keyCode {
            case 123: store.navigate(.left)
            case 124: store.navigate(.right)
            case 125: store.navigate(.down)
            case 126: store.navigate(.up)
            case 36:
                if let game = store.selected {
                    if store.readiness(game) == nil { store.launch(game) } else { portGame = game }
                }
            case 53: store.navigate(.back)
            default: return false
            }
            return true
        })
        .sheet(isPresented: $showingControls) { ControlsSheet(controller: controller) }
        .sheet(item: $portGame) { game in PortSheet(game: game, store: store) }
        .sheet(isPresented: $showingIntegration) { IntegrationSheet(store: store) }
        .alert(item: $store.issue) { issue in Alert(title: Text(issue.title), message: Text(issue.message), dismissButton: .default(Text("OK"))) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(hubGreen).frame(width: 37, height: 37)
                    Image(systemName: "gamecontroller.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color(hex: "172111"))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("GAME HUB").font(.system(size: 14, weight: .black)).tracking(1.3)
                    Text("YOUR COLLECTION").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.9).foregroundStyle(mutedText)
                }
            }.padding(.top, 44).padding(.bottom, 40).padding(.horizontal, 23)
            Text("LIBRARY").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.8).foregroundStyle(mutedText).padding(.leading, 26).padding(.bottom, 13)
            ForEach(LibrarySection.allCases) { section in
                Button {
                    store.section = section
                    store.selectedID = store.filtered.first?.id
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: section.icon).font(.system(size: 14)).frame(width: 18)
                        Text(section.rawValue).font(.system(size: 12, weight: store.section == section ? .semibold : .medium))
                        Spacer()
                        if section == .all { Text("\(store.games.count)").font(.system(size: 10, weight: .semibold, design: .monospaced)).opacity(0.7) }
                        if section == .ready { Text("\(store.readyCount)").font(.system(size: 10, weight: .semibold, design: .monospaced)).opacity(0.7) }
                    }
                    .foregroundStyle(store.section == section ? hubGreen : mutedText)
                    .padding(.horizontal, 14).padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 8).fill(store.section == section ? hubGreen.opacity(0.09) : .clear))
                    .overlay(alignment: .leading) { if store.section == section { Capsule().fill(hubGreen).frame(width: 2, height: 19) } }
                }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 4)
            }
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.horizontal, 26).padding(.vertical, 25)
            Text("WORKSPACE").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.8).foregroundStyle(mutedText).padding(.leading, 26).padding(.bottom, 17)
            sidebarAction("Controls & devices", icon: "gamecontroller") { showingControls = true }
            sidebarAction("Add a native game", icon: "plus.square") { store.importNativeApp() }
            sidebarAction("Choose library folder", icon: "folder.badge.plus") { store.chooseLibraryFolder() }
            sidebarAction("Open library folder", icon: "folder") { NSWorkspace.shared.open(store.root.appendingPathComponent("Library")) }
            Spacer()
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 8) {
                    Circle().fill(hubGreen).frame(width: 5, height: 5)
                    Text("APPLE SILICON").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.4)
                }.foregroundStyle(hubGreen)
                Text("One home. Every game.").font(.system(size: 11)).foregroundStyle(mutedText)
                HStack(spacing: 6) { Image(systemName: "display"); Text("Retina ready"); Spacer(); Text("v0.1") }
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(mutedText.opacity(0.65))
            }.padding(18).background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.025))).padding(16)
        }
        .frame(width: 216).background(Color(hex: "0D1015"))
    }

    private func sidebarAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) { Image(systemName: icon).frame(width: 18); Text(title); Spacer() }
                .font(.system(size: 11)).foregroundStyle(mutedText).padding(.horizontal, 26).padding(.vertical, 11)
        }.buttonStyle(.plain)
    }

    private var toolbar: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("THE GOOD GAMES, ALL TOGETHER").font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(1.6).foregroundStyle(hubGreen.opacity(0.9))
                Text("Your collection").font(.system(size: 27, weight: .bold)).tracking(-0.7)
            }
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(mutedText)
                TextField("Find a game…", text: $store.search).textFieldStyle(.plain).font(.system(size: 12)).focused($searchFocused)
                if !store.search.isEmpty { Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(mutedText) }.buttonStyle(.plain) }
            }
            .padding(.horizontal, 13).padding(.vertical, 11).frame(width: 205)
            .background(RoundedRectangle(cornerRadius: 8).fill(panelBackground)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.06)))
            Button { store.importNativeApp() } label: {
                HStack(spacing: 7) { Image(systemName: "plus"); Text("Add game") }.font(.system(size: 11, weight: .semibold)).padding(.horizontal, 15).padding(.vertical, 11)
            }.buttonStyle(.plain).background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
        }.padding(.horizontal, 32).padding(.top, 35).padding(.bottom, 23)
    }

    private func featured(_ game: GameManifest) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 6) {
                    Circle().fill(game.tint).frame(width: 5, height: 5)
                    Text(game.isPrototype ? "NATIVE DEVELOPMENT BUILD" : game.id == "pga-2005" ? "PORT PRIORITY 01" : store.readiness(game) == nil ? "READY TO PLAY" : "IN YOUR COLLECTION")
                        .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.8)
                }.foregroundStyle(game.tint)
                Text(game.title).font(.system(size: 31, weight: .bold)).tracking(-0.7).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(game.summary).font(.system(size: 11)).foregroundStyle(mutedText).lineSpacing(4).lineLimit(2)
                HStack(spacing: 14) {
                    Button {
                        if store.readiness(game) == nil { store.launch(game) } else { portGame = game }
                    } label: {
                        Label(store.readiness(game) == nil ? "Play game" : "View port progress", systemImage: store.readiness(game) == nil ? "play.fill" : "arrow.up.right")
                            .font(.system(size: 11, weight: .bold)).padding(.horizontal, 17).padding(.vertical, 11)
                            .foregroundStyle(Color(hex: "141B11")).background(game.tint, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                    Text(store.readiness(game) == nil ? (game.isPrototype ? "NATIVE PROTOTYPE" : "NATIVE MAC BUILD") : "\(game.platform) · \(game.year)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(mutedText)
                    Button { portGame = game } label: { Image(systemName: "info.circle").font(.system(size: 14)).foregroundStyle(mutedText) }.buttonStyle(.plain).help("Game details and controls")
                }.padding(.top, 5)
            }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
            GameArtwork(game: game, hero: true).frame(width: 295)
                .overlay(alignment: .leading) { LinearGradient(colors: [panelBackground, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 65) }
        }
        .frame(height: 224).background(panelBackground).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.07)))
    }

    private var libraryHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(store.section == .all ? "All games" : store.section.rawValue).font(.system(size: 16, weight: .semibold))
            Text("\(store.filtered.count)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(mutedText).padding(.horizontal, 7).padding(.vertical, 4).background(.white.opacity(0.05), in: Capsule())
            Spacer()
            Menu {
                ForEach(store.platforms, id: \.self) { value in Button(value) { store.platform = value; store.selectedID = store.filtered.first?.id } }
            } label: { HStack(spacing: 7) { Text(store.platform); Image(systemName: "chevron.down").font(.system(size: 8)) }.font(.system(size: 10)).foregroundStyle(mutedText) }
            .menuStyle(.borderlessButton).fixedSize()
            Button { store.reload() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)).foregroundStyle(mutedText) }.buttonStyle(.plain).help("Refresh library (⌘R)")
        }
    }

    private func gameCard(_ game: GameManifest) -> some View {
        let ready = store.readiness(game) == nil
        return VStack(alignment: .leading, spacing: 0) {
            GameArtwork(game: game).frame(height: 137)
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 5) {
                        Circle().fill(ready ? hubGreen : Color(hex: "E5B97A")).frame(width: 4, height: 4)
                        Text(ready ? (game.isPrototype ? "DEVELOPMENT PROTOTYPE" : game.fidelity == "verified" ? "VERIFIED NATIVE PORT" : "NATIVE MAC BUILD") : game.id == "pga-2005" ? "PORT PRIORITY 01" : "NATIVE PORT QUEUE")
                            .font(.system(size: 7, weight: .bold, design: .monospaced)).tracking(0.9)
                    }.foregroundStyle(.white.opacity(0.9)).padding(.horizontal, 8).padding(.vertical, 6).background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4)).padding(12)
                }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(game.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { store.toggleFavorite(game) } label: { Image(systemName: store.favorites.contains(game.id) ? "heart.fill" : "heart").font(.system(size: 10)).foregroundStyle(store.favorites.contains(game.id) ? game.tint : mutedText.opacity(0.65)) }.buttonStyle(.plain).help("Favorite \(game.title)")
                }
                HStack { Text(game.edition); Spacer(); Text(game.genre.uppercased()).font(.system(size: 7, weight: .medium, design: .monospaced)).tracking(0.5) }.font(.system(size: 9)).foregroundStyle(mutedText)
            }.padding(.horizontal, 13).padding(.vertical, 13)
        }
        .background(panelBackground).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(store.selectedID == game.id ? game.tint.opacity(0.85) : .white.opacity(0.06), lineWidth: store.selectedID == game.id ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if ready { store.launch(game) } else { portGame = game } }
        .onTapGesture { store.selectedID = game.id }
        .contextMenu {
            Button(ready ? "Play game" : "View port progress") { if ready { store.launch(game) } else { portGame = game } }
            Button("Game details & controls") { portGame = game }
            Button(store.favorites.contains(game.id) ? "Remove favorite" : "Add favorite") { store.toggleFavorite(game) }
            if let source = game.sourceArchive { Button("Show original archive") { NSWorkspace.shared.activateFileViewerSelecting([store.resolve(source)]) } }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("\(game.title), \(game.edition), \(game.statusLabel)")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: store.section == .ready ? "hammer.circle" : "square.grid.2x2").font(.system(size: 36, weight: .light)).foregroundStyle(hubGreen)
            Text(store.loadingLibrary ? "Opening your collection…" : store.section == .ready ? "Native games will live here" : "No games here yet").font(.system(size: 18, weight: .semibold))
            Text(store.section == .ready ? "Your original archives are in the port queue. Add an Apple Silicon game to start playing from the hub." : "Try another filter or add a native Mac game.")
                .font(.system(size: 12)).foregroundStyle(mutedText).multilineTextAlignment(.center).frame(maxWidth: 400)
            Button("Add native game") { store.importNativeApp() }.buttonStyle(.bordered)
            Button("Choose library folder…") { store.chooseLibraryFolder() }.buttonStyle(.bordered)
        }.frame(maxWidth: .infinity, minHeight: 245).background(panelBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    private var footer: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) { Image(systemName: "keyboard"); Text("↑ ↓ ← → Navigate"); Text("↵ Details / Play").padding(.leading, 6) }
            Spacer()
            if store.loadingLibrary {
                ProgressView().controlSize(.mini)
                Text(store.libraryStatus).lineLimit(1)
            }
            if let game = store.externalGame {
                Button { store.returnToExternalGame() } label: { Label("Return to \(game.title)", systemImage: "play.fill") }.buttonStyle(.plain).foregroundStyle(hubGreen)
            } else {
                Button { showingControls = true } label: {
                    HStack(spacing: 6) { Circle().fill(controller.controllerName == nil ? mutedText : hubGreen).frame(width: 5, height: 5); Text(controller.controllerName ?? "Keyboard + trackpad"); Image(systemName: controller.controllerName == nil ? "cursorarrow" : "gamecontroller") }
                }.buttonStyle(.plain)
            }
        }.font(.system(size: 9)).foregroundStyle(mutedText).padding(.horizontal, 32).padding(.vertical, 13)
            .background(Color(hex: "0F1217")).overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
    }
}

struct KeyboardHandler: NSViewRepresentable {
    let handler: (NSEvent) -> Bool
    func makeNSView(context: Context) -> NSView { context.coordinator.install(handler); return NSView() }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.handler = handler }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var handler: ((NSEvent) -> Bool)?
        var monitor: Any?
        func install(_ handler: @escaping (NSEvent) -> Bool) {
            self.handler = handler
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.handler?(event) == true ? nil : event }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
