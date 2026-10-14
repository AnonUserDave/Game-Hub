import AppKit
import SwiftUI

struct HubView: View {
    @ObservedObject var store: GameStore
    /// Not observed here: stick and button updates arrive at up to 60 Hz, so
    /// only the small views that show controller state subscribe to them.
    let controller: ControllerManager
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            if let game = store.activeGame {
                NativeGameContainer(game: game, root: store.root) { store.activeGame = nil }
            } else {
                HStack(spacing: 0) {
                    sidebar
                    Rectangle().fill(Hub.rule).frame(width: 1)
                    library
                    Rectangle().fill(Hub.rule).frame(width: 1)
                    Group {
                        if let title = store.selected { TitleInspector(title: title, store: store) }
                        else { Text("Select a game to see it here.").font(.system(size: 13)).foregroundStyle(Hub.dust).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }
                    .frame(width: 340).background(Hub.panel)
                }
            }
        }
        .background(Hub.walnut)
        .foregroundStyle(Hub.label)
        .onAppear {
            controller.onNavigate = handleController
            // Start on the shelves, not in the search field.
            DispatchQueue.main.async { searchFocused = false }
        }
        .onChange(of: store.activeGame?.id) { _, id in controller.navigationEnabled = id == nil }
        .onChange(of: store.search) { _, _ in keepSelectionVisible() }
        .onChange(of: store.section) { _, _ in keepSelectionVisible() }
        .onChange(of: store.platform) { _, _ in keepSelectionVisible() }
        .onChange(of: store.searchFocusRequest) { _, _ in searchFocused = true }
        .background(KeyboardHandler(handler: handleKey))
        .sheet(item: $store.utilitySheet) { sheet in
            switch sheet {
            case .controls: ControlsSheet(controller: controller)
            case .integration: IntegrationSheet(store: store)
            }
        }
        .sheet(item: $store.presentedTitle) { title in TitleSheet(title: title, store: store) }
        .alert(item: $store.issue) { issue in Alert(title: Text(issue.title), message: Text(issue.message), dismissButton: .default(Text("OK"))) }
    }

    /// Library keys. Sheets, alerts and open panels handle their own keys.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard store.activeGame == nil, !store.sheetOpen, store.issue == nil, NSApp.modalWindow == nil else { return false }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let navigation: [UInt16: HubNavigation] = [123: .left, 124: .right, 125: .down, 126: .up, 36: .play, 76: .play, 49: .details, 53: .back]
        if NSApp.keyWindow?.firstResponder is NSTextView {
            // Escape or Down returns to the shelves. With an empty field, arrows
            // and Return act on the library at once, so a field focused by
            // AppKit at launch never swallows navigation.
            let leaveOnly = event.keyCode == 53 || event.keyCode == 125
            guard leaveOnly || (store.search.isEmpty && [123, 124, 126, 36, 76].contains(event.keyCode)) else { return false }
            searchFocused = false
            NSApp.keyWindow?.makeFirstResponder(nil)
            if leaveOnly { return true }
        }
        guard let command = navigation[event.keyCode] else { return false }
        store.navigate(command)
        return true
    }

    /// Controller input reaches whatever is in front first, so B backs out
    /// of alerts and sheets before it touches the library.
    private func handleController(_ command: HubNavigation) {
        if store.issue != nil {
            switch command { case .play, .back: store.issue = nil; default: break }
            return
        }
        // Open and save panels are app-modal; the poll timer still runs.
        guard NSApp.modalWindow == nil else { return }
        switch store.utilitySheet {
        case .controls?: return  // Every button stays testable in the diagnostics sheet.
        case .integration?: if case .back = command { store.utilitySheet = nil }; return
        case nil: break
        }
        if let title = store.presentedTitle {
            switch command {
            case .back, .details: store.presentedTitle = nil
            case .play where store.isPlayable(title): store.presentedTitle = nil; store.play(title)
            default: break
            }
            return
        }
        if searchFocused {
            searchFocused = false
            if case .back = command { return }
        }
        store.navigate(command)
    }

    private func keepSelectionVisible() {
        // An import reloads the catalog; keep its new selection until it lands.
        guard !store.loadingLibrary else { return }
        let visible = store.shelves.flatMap(\.titles)
        if !visible.contains(where: { $0.id == store.selectedID }) { store.selectedID = visible.first?.id }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Game Hub").font(Hub.display(30)).padding(.horizontal, 22).padding(.top, 48)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Hub.dust)
                TextField("Find a game", text: $store.search).textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
                    .onSubmit { searchFocused = false }
                if !store.search.isEmpty {
                    Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Hub.dust) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(Hub.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(searchFocused ? Hub.amber.opacity(0.7) : Hub.rule))
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(LibrarySection.allCases) { section in
                        sidebarRow(section.rawValue, count: store.count(section), selected: store.platform == GameStore.allPlatforms && store.section == section) {
                            Image(systemName: section.icon).font(.system(size: 13))
                        } action: { store.section = section; store.platform = GameStore.allPlatforms }
                    }
                    if store.systems.count > 1 {
                        Text("Systems").font(.system(size: 12, weight: .semibold)).foregroundStyle(Hub.dust).padding(.horizontal, 10).padding(.top, 20).padding(.bottom, 6)
                        ForEach(store.systems, id: \.name) { system in
                            sidebarRow(system.name, count: system.count, selected: store.platform == system.name) {
                                MediaGlyph(kind: MediaKind(platform: system.name))
                            } action: { store.platform = system.name; store.section = .all }
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            Rectangle().fill(Hub.rule).frame(height: 1)
            VStack(alignment: .leading, spacing: 2) {
                ControllerRow(controller: controller) { store.utilitySheet = .controls }
                utilityRow("Add a game…", icon: "plus") { store.importNativeApp() }
                Menu {
                    Button("Show in Finder") { NSWorkspace.shared.open(store.root.appendingPathComponent("Library")) }
                    Button("Choose Another Folder…") { store.chooseLibraryFolder() }
                    Button("Refresh Library") { store.reload() }
                    Divider()
                    Button("Adding Your Own Games…") { store.utilitySheet = .integration }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder").frame(width: 18)
                        Text("Library folder")
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                    }
                    .font(.system(size: 12)).foregroundStyle(Hub.dust).padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            }
            .padding(.horizontal, 10).padding(.vertical, 12)
        }
        .frame(width: 212).background(Hub.den)
    }

    private func sidebarRow<Icon: View>(_ title: String, count: Int, selected: Bool, @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon().frame(width: 18, height: 16).foregroundStyle(selected ? Hub.amber : Hub.dust)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).foregroundStyle(selected ? Hub.label : Hub.label.opacity(0.78)).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                if count > 0 { Text("\(count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Hub.dust) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? Hub.raised : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func utilityRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { UtilityLabel(title: title, icon: icon, lit: false) }.buttonStyle(.plain)
    }

    // MARK: Library

    private var heading: String {
        if !store.search.isEmpty { return "Results for “\(store.search)”" }
        return store.platform == GameStore.allPlatforms ? store.section.rawValue : store.platform
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Text(heading).font(Hub.display(34)).lineLimit(1).truncationMode(.tail)
                if !store.search.isEmpty {
                    let visible = store.filtered.count
                    Text(visible == 1 ? "1 game" : "\(visible) games").font(.system(size: 13)).foregroundStyle(Hub.dust)
                }
                Spacer()
            }
            .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 6)
            GeometryReader { geometry in
                let usable = geometry.size.width - 40
                let columns = max(2, Int(usable / 158))
                let cell = floor(usable / CGFloat(columns))
                let shelves = store.shelves
                let visible = shelves.flatMap(\.titles)
                let selectedID = (visible.first { $0.id == store.selectedID } ?? visible.first)?.id
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 30) {
                            ForEach(shelves) { shelf in
                                shelfSection(shelf, columns: columns, cell: cell, selectedID: selectedID)
                            }
                            if shelves.isEmpty { emptyState.padding(.top, 40) }
                        }
                        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 36)
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: store.selectedID) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(id) } }
                    }
                }
                .onAppear { store.gridColumns = columns }
                .onChange(of: columns) { _, value in store.gridColumns = value }
            }
            HintsBar(store: store, controller: controller)
        }
        .frame(maxWidth: .infinity)
    }

    private func shelfSection(_ shelf: LibraryShelf, columns: Int, cell: CGFloat, selectedID: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(shelf.name).font(.system(size: 16, weight: .semibold))
                if let detail = shelf.detail { Text(detail).font(.system(size: 12)).foregroundStyle(Hub.dust).lineLimit(1) }
            }
            .padding(.horizontal, 8)
            ForEach(shelf.titles.chunked(into: columns), id: \.first?.id) { row in
                ZStack(alignment: .topLeading) {
                    Plank().frame(height: 20).padding(.top, ShelfItem.objectArea)
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(row) { title in
                            ShelfItem(title: title, selected: selectedID == title.id, playable: store.isPlayable(title), status: store.status(title), favorite: store.isFavorite(title), width: cell)
                                .id(title.id)
                                .onTapGesture { searchFocused = false; store.selectedID = title.id }
                                .simultaneousGesture(TapGesture(count: 2).onEnded { store.play(title) })
                                .contextMenu { titleMenu(title) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func titleMenu(_ title: GameTitle) -> some View {
        ForEach(title.builds.filter { store.readiness($0) == nil }) { build in
            Button("Play \(build.buildName)") { store.launch(build) }
        }
        Button("Show Details") { store.presentedTitle = title }
        Button(store.isFavorite(title) ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite(title) }
        if let source = title.display.sourceArchive {
            Divider()
            Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.resolve(source)]) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            if store.loadingLibrary && store.games.isEmpty {
                ProgressView().controlSize(.small)
                Text("Opening your collection…").font(.system(size: 15, weight: .semibold))
            } else if store.games.isEmpty {
                Text("Choose your Game Hub folder").font(.system(size: 17, weight: .semibold))
                Text("Game Hub reads its library from the folder that holds Library and your original archives.").font(.system(size: 13)).foregroundStyle(Hub.dust).multilineTextAlignment(.center)
                Button("Choose Folder…") { store.chooseLibraryFolder() }.buttonStyle(HubPrimaryButtonStyle(compact: true)).padding(.top, 4)
            } else if !store.search.isEmpty {
                Text("No games match “\(store.search)”").font(.system(size: 17, weight: .semibold))
                Text("Try a shorter name, a system such as Apple II, or a genre.").font(.system(size: 13)).foregroundStyle(Hub.dust)
                Button("Clear Search") { store.search = "" }.buttonStyle(HubSecondaryButtonStyle(compact: true)).padding(.top, 4)
            } else if store.section == .favorites {
                Text("No favorites yet").font(.system(size: 17, weight: .semibold))
                Text("Add one from a game's details, or press Y on your controller.").font(.system(size: 13)).foregroundStyle(Hub.dust)
            } else {
                Text("Nothing here yet").font(.system(size: 17, weight: .semibold))
                Button("Show All Games") { store.navigate(.back) }.buttonStyle(HubSecondaryButtonStyle(compact: true)).padding(.top, 4)
            }
        }
        .frame(maxWidth: 420).frame(maxWidth: .infinity)
    }

}

/// Controller and keyboard state in the sidebar; opens Controls & devices.
private struct ControllerRow: View {
    @ObservedObject var controller: ControllerManager
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            UtilityLabel(title: controller.controllerName ?? "Keyboard & trackpad", icon: controller.controllerName == nil ? "keyboard" : "gamecontroller.fill", lit: controller.controllerName != nil)
        }
        .buttonStyle(.plain).help("Controls & devices")
    }
}

private struct UtilityLabel: View {
    let title: String
    let icon: String
    let lit: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(lit ? Hub.amber : Hub.dust)
            Text(title).lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .font(.system(size: 12)).foregroundStyle(lit ? Hub.label : Hub.dust).padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
    }
}

/// Key hints for the input in use, plus library and external-game status.
private struct HintsBar: View {
    @ObservedObject var store: GameStore
    @ObservedObject var controller: ControllerManager

    var body: some View {
        HStack(spacing: 16) {
            ViewThatFits(in: .horizontal) {
                hints(compact: false)
                hints(compact: true)
                Color.clear.frame(width: 1, height: 1)
            }
            Spacer(minLength: 12)
            if store.loadingLibrary {
                ProgressView().controlSize(.mini)
                Text(store.libraryStatus).lineLimit(1)
            }
            if let game = store.externalGame {
                Button { store.returnToExternalGame() } label: { Label("Return to \(game.title)", systemImage: "play.fill") }
                    .buttonStyle(HubPrimaryButtonStyle(compact: true))
            } else if let message = store.importMessage {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(Hub.amber)
                    .task(id: message) { try? await Task.sleep(for: .seconds(4)); if store.importMessage == message { store.importMessage = nil } }
            }
        }
        .font(.system(size: 11)).foregroundStyle(Hub.dust)
        .padding(.horizontal, 28).frame(height: 42)
        .overlay(alignment: .top) { Rectangle().fill(Hub.rule).frame(height: 1) }
    }

    private func hints(compact: Bool) -> some View {
        HStack(spacing: 16) {
            if controller.controllerName != nil {
                hint(["A"], "Play"); hint(["B"], "Back"); hint(["X"], "Details")
                if !compact { hint(["Y"], "Favorite"); hint(["LB", "RB"], "Lists") }
            } else {
                if !compact { hint(["←", "→", "↑", "↓"], "Browse") }
                hint(["Return"], "Play"); hint(["Space"], "Details")
                if !compact { hint(["Esc"], "Show all") }
            }
        }
        .fixedSize()
    }

    private func hint(_ keys: [String], _ action: String) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { KeyCap(text: $0) }
            Text(action).padding(.leading, 2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A shelf board running under one row of games.
struct Plank: View {
    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(LinearGradient(colors: [Color(hex: "5A4432"), Color(hex: "35271D")], startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.13)).frame(height: 1) }
                .frame(height: 7)
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom).frame(height: 13)
        }
        .allowsHitTesting(false)
    }
}

/// One game standing on the shelf, lit by its own accent color.
struct ShelfItem: View {
    static let objectArea: CGFloat = 156
    let title: GameTitle
    let selected: Bool
    let playable: Bool
    /// The playable build's fidelity, or why a build cannot open yet.
    let status: String?
    let favorite: Bool
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let kind = MediaKind(platform: title.platform)
        let box = CGSize(width: width - 34, height: 128)
        let object = kind.fit(in: box)
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottom) {
                // Each game's own light, kept above the shelf board.
                RadialGradient(colors: [title.display.tint.opacity(selected ? 0.42 : 0.12), .clear], center: UnitPoint(x: 0.5, y: 0.78), startRadius: 0, endRadius: width * 0.5)
                Ellipse()
                    .fill(RadialGradient(colors: [.black.opacity(selected ? 0.45 : 0.7), .clear], center: .center, startRadius: 0, endRadius: object.width * 0.5))
                    .frame(width: object.width * (selected ? 1.05 : 1.15), height: selected ? 12 : 9).offset(y: 4)
                MediaObject(game: title.display)
                    .frame(width: box.width, height: box.height)
                    .offset(y: selected ? -10 : 0)
            }
            .frame(width: width, height: Self.objectArea)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(title.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(selected ? Hub.label : Hub.label.opacity(0.88)).lineLimit(1)
                    if favorite { Image(systemName: "heart.fill").font(.system(size: 9)).foregroundStyle(Hub.amber).accessibilityHidden(true) }
                }
                Text(title.platform).font(.system(size: 11)).foregroundStyle(Hub.dust).lineLimit(1)
                if let status {
                    Label(status, systemImage: playable ? "hammer" : "exclamationmark.circle")
                        .labelStyle(StatusLabelStyle()).font(.system(size: 11)).foregroundStyle(Hub.dust.opacity(0.9)).lineLimit(1)
                }
                Capsule().fill(Hub.amber).frame(width: 26, height: 3).padding(.top, 6).opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 14).padding(.top, 22)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title.name), \(title.platform) \(kind.noun), \(playable ? "playable" : "not playable yet")\(status.map { ", \($0)" } ?? "")\(favorite ? ", favorite" : "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.system(size: 9)); configuration.title }
    }
}

/// The selected game: lit on a display stand, with what you can do with it.
struct TitleInspector: View {
    let title: GameTitle
    @ObservedObject var store: GameStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let primary = store.primaryBuild(title)
        ScrollViewReader { reader in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                stage.id("top")
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title.name).font(Hub.display(38)).lineLimit(3).minimumScaleFactor(0.6).fixedSize(horizontal: false, vertical: true)
                        Text("\(title.platform), \(String(title.display.year))").font(.system(size: 13)).foregroundStyle(Hub.dust)
                        if let played = store.lastPlayed(title) {
                            Text("Last played \(played.formatted(.relative(presentation: .named)))").font(.system(size: 12)).foregroundStyle(Hub.dust)
                        }
                    }
                    if title.builds.isEmpty {
                        notice(icon: "hourglass", heading: "Not playable yet", detail: "This game is waiting for its native Mac version. Your original copy stays in the library.")
                    } else {
                        VStack(spacing: 8) { ForEach(title.builds) { build in buildRow(build, primary: build.id == primary?.id) } }
                    }
                    let summary = (primary ?? title.display).summary
                    if !summary.isEmpty { Text(summary).font(.system(size: 13)).foregroundStyle(Hub.label.opacity(0.84)).lineSpacing(4).fixedSize(horizontal: false, vertical: true) }
                    if let primary { controls(primary) }
                    HStack(spacing: 8) {
                        Button { store.toggleFavorite(title) } label: {
                            Label(store.isFavorite(title) ? "Favorite" : "Add to Favorites", systemImage: store.isFavorite(title) ? "heart.fill" : "heart")
                        }
                        .buttonStyle(HubSecondaryButtonStyle(compact: true))
                        Button { store.presentedTitle = title } label: { Label("Details", systemImage: "info.circle") }
                            .buttonStyle(HubSecondaryButtonStyle(compact: true)).help("Details (Space)")
                    }
                }
                .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 28)
            }
        }
        .scrollIndicators(.never)
        .onChange(of: title.id) { _, _ in reader.scrollTo("top", anchor: .top) }
        }
    }

    private var stage: some View {
        let tint = title.display.tint
        return ZStack(alignment: .bottom) {
            SpotlightShape().fill(LinearGradient(colors: [tint.opacity(0.2), tint.opacity(0.04)], startPoint: .top, endPoint: .bottom))
            RadialGradient(colors: [tint.opacity(0.32), .clear], center: UnitPoint(x: 0.5, y: 0.82), startRadius: 0, endRadius: 200)
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    Ellipse().fill(RadialGradient(colors: [.black.opacity(0.7), .clear], center: .center, startRadius: 0, endRadius: 120)).frame(width: 240, height: 16).offset(y: 6)
                    MediaObject(game: title.display).frame(width: 236, height: 184)
                        .id(title.id).transition(.opacity)
                }
                Plank().frame(height: 20)
            }
        }
        .frame(height: 292).clipped()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: title.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title.platform) \(MediaKind(platform: title.platform).noun)")
    }

    private func buildRow(_ build: GameManifest, primary: Bool) -> some View {
        let reason = store.readiness(build)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(build.buildName).font(.system(size: 14, weight: .semibold))
                    Text(build.statusLabel).font(.system(size: 12)).foregroundStyle(Hub.dust)
                }
                Spacer(minLength: 8)
                if reason == nil, !primary {
                    Button("Play") { store.launch(build) }.buttonStyle(HubSecondaryButtonStyle(compact: true))
                }
            }
            if let reason {
                Label(reason, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Hub.amber.opacity(0.85))
            } else if primary {
                Button { store.launch(build) } label: {
                    HStack { Image(systemName: "play.fill"); Text(build.isPrototype ? "Play prototype" : "Play"); Spacer(); Text("Return").font(.system(size: 11, weight: .medium)).opacity(0.6) }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HubPrimaryButtonStyle())
            }
        }
        .padding(14)
        .background(Hub.raised.opacity(primary ? 0.9 : 0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Hub.rule))
    }

    private func notice(icon: String, heading: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Hub.amber).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(heading).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Hub.dust).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Hub.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Hub.rule))
    }

    @ViewBuilder
    private func controls(_ build: GameManifest) -> some View {
        let groups = [("keyboard", build.keyboard), ("gamecontroller", build.controller)].filter { !$0.1.isEmpty }
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Controls").font(.system(size: 13, weight: .semibold))
                ForEach(groups, id: \.0) { icon, lines in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Hub.dust).frame(width: 18).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(lines.prefix(3), id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(Hub.label.opacity(0.8)).fixedSize(horizontal: false, vertical: true) }
                            if lines.count > 3 {
                                Button("All controls in Details") { store.presentedTitle = title }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Hub.amber)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Soft cone of light falling on the display stand.
struct SpotlightShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - rect.width * 0.16, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.16, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX + rect.width * 0.1, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX - rect.width * 0.1, y: rect.maxY))
        path.closeSubpath()
        return path
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
