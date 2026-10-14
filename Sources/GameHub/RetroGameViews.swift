import AppKit
import Combine
import SwiftUI

// These two native modules remain development reconstructions. Source-specific
// logic lives in their separate Foundation cores; neither runs the source CPU.

enum RetroSaveStore {
    static func url(_ id: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameHub/NativeRetro", isDirectory: true).appendingPathComponent(id + ".json")
    }
    static func load<T: Decodable>(_ type: T.Type, id: String) -> T? {
        let file = url(id)
        guard let bytes = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= 256 * 1024,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    @discardableResult static func save<T: Encodable>(_ value: T, id: String) -> Bool {
        do {
            let file = url(id)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: file, options: .atomic)
            return true
        } catch { return false }
    }
}

/// Controller history is updated while inactive; returning with a held action
/// cannot manufacture a press. Continuous fire also waits for a release.
struct RetroControllerLatch {
    private var previous = NativeGamepadSample()
    private var identity = ""
    private var blocked = Set<String>()
    mutating func blockActions(_ current: NativeGamepadSample) {
        blocked.formUnion(current.buttons.filter { $0.value && $0.key != "Menu" && $0.key != "B" }.map(\.key))
    }
    mutating func sample(_ current: NativeGamepadSample, identity nextIdentity: String, focused: Bool, actionsEnabled: Bool = true) -> (pressed: Set<String>, held: Set<String>) {
        let down = Set(current.buttons.filter { $0.value }.map(\.key))
        defer { previous = current; identity = nextIdentity }
        if !focused || nextIdentity != identity || current.connected != previous.connected {
            blocked = down
            return ([], [])
        }
        blocked.formIntersection(down)
        if !actionsEnabled { blockActions(current) }
        let usable = down.subtracting(blocked)
        return (Set(usable.filter { previous.buttons[$0] != true }), usable)
    }
}

struct RetroKeys: NSViewRepresentable {
    let handler: (UInt16, Bool) -> Bool
    var modifiedHandler: ((UInt16, Bool, NSEvent.ModifierFlags) -> Bool)? = nil
    func makeNSView(context: Context) -> KeyView { KeyView(handler: handler, modifiedHandler: modifiedHandler) }
    func updateNSView(_ view: KeyView, context: Context) { view.handler = handler; view.modifiedHandler = modifiedHandler }
    final class KeyView: NSView {
        var handler: (UInt16, Bool) -> Bool
        var modifiedHandler: ((UInt16, Bool, NSEvent.ModifierFlags) -> Bool)?
        private var monitor: Any?
        init(handler: @escaping (UInt16, Bool) -> Bool, modifiedHandler: ((UInt16, Bool, NSEvent.ModifierFlags) -> Bool)?) {
            self.handler = handler
            self.modifiedHandler = modifiedHandler
            super.init(frame: .zero)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, NSApp.isActive, self.window?.isKeyWindow == true,
                      !(self.window?.firstResponder is NSTextView),
                      event.modifierFlags.intersection([.command, .option]).isEmpty else { return event }
                if event.modifierFlags.contains(.control) {
                    return self.modifiedHandler?(event.keyCode, event.type == .keyDown, event.modifierFlags) == true ? nil : event
                }
                if event.type == .keyDown && event.isARepeat { return nil }
                return self.handler(event.keyCode, event.type == .keyDown) ? nil : event
            }
        }
        required init?(coder: NSCoder) { nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

@MainActor
final class BreakoutSession: ObservableObject {
    @Published var simulation = BreakoutSimulation()
    @Published var setup = true
    @Published var paused = false
    @Published var configuration = BreakoutConfiguration()
    @Published var saveMessage = ""
    let originalHUD = try? BreakoutMedia.load(from: GameStore.workspaceRoot().appendingPathComponent("Library/Imported/breakout2600/media.json"))
    var knobs = [0.5, 0.5, 0.5, 0.5]
    var keys = Set<UInt16>()
    var pendingServe = false
    private var latch = RetroControllerLatch()
    private var timer: Timer?
    private var lastTime = 0.0
    private var accumulator = 0.0
    private var window: NSWindow?
    var hasSave: Bool { RetroSaveStore.load(BreakoutSnapshot.self, id: "breakout-atari-2600") != nil }

    func attach(_ window: NSWindow?) {
        self.window = window
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.frame(now: ProcessInfo.processInfo.systemUptime)
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    deinit { timer?.invalidate() }
    func stop() { timer?.invalidate(); timer = nil; window = nil; keys.removeAll(); pendingServe = false; if !setup { save() } }
    func start() {
        simulation = BreakoutSimulation(configuration: configuration)
        keys.removeAll(); pendingServe = false; accumulator = 0; setup = false; paused = false; saveMessage = ""
    }
    func resumeSave() {
        guard let snapshot = RetroSaveStore.load(BreakoutSnapshot.self, id: "breakout-atari-2600"),
              let restored = try? BreakoutSimulation(snapshot: snapshot) else { saveMessage = "Saved round is unavailable or incompatible."; return }
        simulation = restored; configuration = restored.state.configuration
        knobs = restored.state.paddleLefts.enumerated().map { player, value in
            let split = configuration.playerCount == 4 || (configuration.playerCount == 3 && player > 0)
            let left = configuration.playerCount == 3 ? player == 1 : player % 2 == 0
            let bounds = split ? (left ? (55, 126) : (128, 191)) : (55, 191)
            return min(1, max(0, Double(value - bounds.0) / Double(bounds.1 - bounds.0)))
        }
        keys.removeAll(); pendingServe = false; accumulator = 0; setup = false; paused = true
    }
    func save() { saveMessage = RetroSaveStore.save(simulation.snapshot, id: "breakout-atari-2600") ? "Round saved." : "Could not save this round." }
    func togglePause() {
        paused.toggle(); keys.removeAll(); pendingServe = false
        latch.blockActions(PGAControllerInput.current().sample)
    }
    func key(_ code: UInt16, down: Bool) -> Bool {
        if code == 53 { if down && !setup { togglePause() }; return true }
        let supported: Set<UInt16> = [123, 124, 0, 2, 38, 37, 3, 4, 49]
        guard !setup, supported.contains(code) else { return false }
        if down { keys.insert(code); if code == 49 && !paused { pendingServe = true } } else { keys.remove(code) }
        return true
    }
    func pointer(_ position: Double) {
        guard !setup, !paused, let player = simulation.state.activePlayers.first else { return }
        knobs[player] = max(0, min(1, position))
    }
    func frame(now: Double) {
        let focused = NSApp.isActive && window?.isKeyWindow == true
        let controller = PGAControllerInput.current()
        let input = latch.sample(controller.sample, identity: controller.identity, focused: focused, actionsEnabled: !setup && !paused)
        let delta = lastTime == 0 ? 0 : max(0, min(0.25, now - lastTime))
        lastTime = now
        if !focused { keys.removeAll(); pendingServe = false; accumulator = 0; return }
        if input.pressed.contains("Menu") || input.pressed.contains("B") { if !setup { togglePause() } }
        guard !setup, !paused else { accumulator = 0; return }
        pendingServe = pendingServe || input.pressed.contains("A")
        accumulator += delta
        let left: [UInt16] = [123, 0, 38, 3], right: [UInt16] = [124, 2, 37, 4]
        // Fixed 60Hz simulation; bounded catch-up prevents a stall from flooding
        // the main thread. Focus/pause resets elapsed time, so neither advances.
        while accumulator >= 1.0 / 60 {
            for i in 0..<4 {
                let axis = (keys.contains(right[i]) ? 1.0 : 0) - (keys.contains(left[i]) ? 1.0 : 0)
                knobs[i] = max(0, min(1, knobs[i] + axis / 90))
            }
            if controller.sample.connected, let player = simulation.state.activePlayers.first {
                let axis = Double(controller.sample.axes.first ?? 0)
                let direction = input.held.contains("Right") ? 1.0 : input.held.contains("Left") ? -1.0 : abs(axis) > 0.15 ? axis : 0
                knobs[player] = max(0, min(1, knobs[player] + direction / 90))
            }
            simulation.tick(input: BreakoutInput(paddlePositions: knobs, serve: pendingServe || keys.contains(49) || input.held.contains("A")))
            pendingServe = false
            accumulator -= 1.0 / 60
        }
    }
}

struct RetroWindow: NSViewRepresentable {
    let attached: (NSWindow?) -> Void
    func makeNSView(context: Context) -> WindowView { WindowView(attached: attached) }
    func updateNSView(_ view: WindowView, context: Context) { view.attached = attached }
    final class WindowView: NSView {
        var attached: (NSWindow?) -> Void
        init(attached: @escaping (NSWindow?) -> Void) { self.attached = attached; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attached(window) }
    }
}

struct BreakoutGameView: View {
    let onExit: () -> Void
    @StateObject private var session = BreakoutSession()
    // Source COLU codes select these provisional RGB swatches; calibrated
    // NTSC color conversion and original display comparison remain pending.
    private func color(_ code: Int) -> Color {
        let hues = [0x10: "DFA63A", 0x20: "DF833A", 0x30: "D6653A", 0x40: "D34A3A", 0x80: "678BDB", 0xC0: "7ACD68"]
        if code < 16 { return Color(white: Double(code & 14) / 14) }
        return Color(hex: hues[code & 0xf0] ?? "FFFFFF")
    }
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("BREAKOUT · ATARI 2600").font(.headline)
                Spacer()
                Text("Development reconstruction").foregroundStyle(.secondary)
                Button("Library", action: onExit)
            }
            if session.setup { setup }
            else {
                HStack(alignment: .top, spacing: 24) {
                    GeometryReader { geometry in
                        let scale = min(geometry.size.width / 160, geometry.size.height / 210)
                        let size = CGSize(width: 160 * scale, height: 210 * scale)
                        Canvas { context, _ in draw(context: &context, scale: scale) }
                            .frame(width: size.width, height: size.height).background(.black)
                            .gesture(DragGesture(minimumDistance: 0).onChanged { session.pointer($0.location.x / size.width) })
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        Text(session.configuration.variation.title).font(.title2)
                        Text("\(session.configuration.playerCount) PLAYER\(session.configuration.playerCount == 1 ? "" : "S") · WALL \(session.simulation.state.wallNumber)")
                        ForEach(session.simulation.state.teams.indices, id: \.self) { index in
                            let team = session.simulation.state.teams[index]
                            Text("TEAM \(index + 1)  \(team.score)" + (session.configuration.variation.isTimed ? "  TIME \(team.timerTicks % 1000)" : ""))
                                .foregroundStyle(index == session.simulation.state.activeTeam ? .white : .gray)
                        }
                        Text("\(session.simulation.state.ballsRemaining) balls remaining")
                        Text(session.paused ? "PAUSED" : session.simulation.state.phase == .selection ? "Returned to game selection" : session.simulation.state.phase == .serve ? "Space / A to serve" : session.simulation.state.phase == .caught ? "Release Space / A" : session.simulation.state.phase == .ended ? "GAME OVER" : "Keep the ball in play")
                            .foregroundStyle(Color(hex: "C2EF93"))
                        if session.simulation.state.phase == .serve {
                            Button("Serve") { session.pendingServe = true }.disabled(session.paused)
                        }
                        Button(session.paused ? "Continue" : "Pause") { session.togglePause() }
                        Button("Save round") { session.save() }
                        Button("New game") { session.paused = true; session.setup = true; session.keys.removeAll() }
                        Text(session.saveMessage).foregroundStyle(.secondary)
                        Spacer()
                        Text("Drag the paddle or use ← →.\nSpace / A: serve and hold to catch.\nStick / D-pad: move. Esc / Menu / B: pause.\nOther paddles: A/D, J/L, F/H.")
                            .font(.system(size: 11, design: .monospaced)).lineSpacing(5)
                        Text("Collision, display colors, audio and device sampling still need original comparison. M1 performance unverified.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(width: 265)
                }
            }
        }.padding(24).background(Color(hex: "111419"))
            .background(RetroKeys { session.key($0, down: $1) })
            .background(RetroWindow { session.attach($0) })
            .onDisappear { session.stop() }
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Select a game").font(.largeTitle)
            Picker("Variation", selection: $session.configuration.variation) {
                ForEach(BreakoutVariation.allCases, id: \.rawValue) { Text($0.title).tag($0) }
            }
            Picker("Players", selection: $session.configuration.playerCount) {
                ForEach(1...4, id: \.self) { Text(String($0)).tag($0) }
            }
            ForEach(0..<2, id: \.self) { index in
                Picker("Team \(index + 1) difficulty", selection: $session.configuration.teamDifficulties[index]) {
                    ForEach(BreakoutDifficulty.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0) }
                }
            }
            Toggle("Original black-and-white switch", isOn: $session.configuration.monochrome)
            Text("The original 12 variations and 1–4 player selections. Two-player games alternate; 3–4 players share team paddles. One gamepad controls the first active paddle; keyboard pairs control the others.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Button("Start") { session.start() }.buttonStyle(.borderedProminent)
                if session.hasSave { Button("Resume saved round") { session.resumeSave() } }
            }
            Text(session.saveMessage).foregroundStyle(.secondary)
            Text("Source-derived pixel contacts and delayed collision rules. Scanline edges, calibrated colors, sound, original comparison and M1 acceptance remain pending.").font(.caption).foregroundStyle(.secondary)
        }.padding(40).frame(maxWidth: 640).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func draw(context: inout GraphicsContext, scale: Double) {
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: Color) {
            context.fill(Path(CGRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale)), with: .color(color))
        }
        let state = session.simulation.state
        rect(0, 12, 8, 176, .white); rect(152, 12, 8, 176, .white); rect(0, 12, 160, 14, .white)
        if state.wallVisible {
            for index in state.bricks.indices where state.bricks[index] {
                let row = index / 18, column = index % 18
                rect(8 + Double(column) * 8, 50 + Double(row) * 6, 8, 6, color(state.rowColorCodes[row]))
            }
        }
        for (index, paddle) in state.paddles.enumerated() { rect(paddle.x, paddle.y, paddle.width, paddle.height, color(state.paddleColorCodes[index])) }
        if let ball = state.ball, ball.rasterY < 188 { rect(Double(ball.rasterX), Double(ball.rasterY), 2, Double(min(4, 188 - ball.rasterY)), .white) }
        let displayed = state.configuration.variation.isTimed ? state.teams[state.activeTeam].timerTicks % 1000 : state.score
        if let hud = session.originalHUD {
            let digits = String(format: "%03d", displayed).utf8.map { Int($0 - 48) }
            for (index, digit) in digits.enumerated() { for row in 0..<5 { for column in 0..<3 where hud.digitRows[digit][row] & (4 >> column) != 0 {
                rect(68 + Double(index * 8 + column * 2), Double(row * 2), 2, 2, .white)
            } } }
        } else {
            let score = Text(String(format: "%03d", displayed)).font(.system(size: 10 * scale, weight: .bold, design: .monospaced)).foregroundStyle(.white)
            context.draw(score, at: CGPoint(x: 80 * scale, y: 5 * scale))
        }
    }
}

@MainActor
final class ConflictSession: ObservableObject {
    @Published var game = ConflictSimulation()
    @Published var scenario = ConflictScenario()
    @Published var setup = true
    @Published var paused = false
    @Published var angle = 90
    @Published var power = 100
    @Published var speed = 500
    @Published var heading = 90
    @Published var transfer = 1000
    @Published var dock: ConflictDock = .planet
    @Published var message = ""
    private var timer: Timer?
    private var latch = RetroControllerLatch()
    private var window: NSWindow?
    var shapes: [[[Int]]] = []
    var hasSave: Bool { RetroSaveStore.load(ConflictSnapshot.self, id: "conflict-2500-apple-ii") != nil }
    init() {
        let url = GameStore.workspaceRoot().appendingPathComponent("Library/SourceMedia/retro/conflict-2500-apple-ii/conflict-content.json")
        struct Content: Decodable { let schemaVersion: Int; let sourceSHA256: String; let shapes: [[[Int]]] }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 16384,
           let bytes = try? Data(contentsOf: url), let content = try? JSONDecoder().decode(Content.self, from: bytes),
           content.schemaVersion == 1, content.sourceSHA256 == ConflictSimulation.sourceIdentity,
           content.shapes.count == 5, content.shapes.allSatisfy({ $0.count == 10 && $0.allSatisfy({ $0.count == 2 && $0.allSatisfy({ (0...6).contains($0) }) }) }) {
            shapes = content.shapes
        }
    }
    deinit { timer?.invalidate() }
    func attach(_ window: NSWindow?) {
        self.window = window
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let sample = PGAControllerInput.current()
                let input = self.latch.sample(sample.sample, identity: sample.identity, focused: NSApp.isActive && self.window?.isKeyWindow == true)
                guard !self.setup else { return }
                if input.pressed.contains("Menu") || input.pressed.contains("B") { self.paused.toggle() }
                guard !self.paused else { return }
                if input.pressed.contains("A") { self.game.nextShip() }
                if input.pressed.contains("X") { self.game.fire(angle: self.angle, power: self.power) }
                if input.pressed.contains("Y") { self.game.advanceTurn() }
                if input.pressed.contains("RB") { self.changeDisplay() }
            }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func start() { game = ConflictSimulation(scenario: scenario, seed: UInt64.random(in: 1...UInt64.max)); setup = false; paused = false; message = "" }
    func resumeSave() {
        guard let saved = RetroSaveStore.load(ConflictSnapshot.self, id: "conflict-2500-apple-ii"), let restored = ConflictSimulation(snapshot: saved) else { message = "Saved scenario is unavailable or incompatible."; return }
        game = restored; scenario = restored.scenario; setup = false; paused = false
    }
    func save() { message = RetroSaveStore.save(game.snapshot, id: "conflict-2500-apple-ii") ? "Scenario saved." : "Could not save this scenario." }
    func stop() { timer?.invalidate(); timer = nil; window = nil; if !setup { save() } }
    func changeDisplay() {
        switch game.display { case .map: game.display = .tactical; case .tactical: game.display = .status; case .status: game.display = .map }
    }
    func key(_ code: UInt16, down: Bool) -> Bool {
        guard !setup else { return false }
        if code == 53 { if down { paused.toggle() }; return true }
        guard !paused else { return false }
        guard down else { return [3, 45, 14, 9, 1, 0].contains(code) }
        switch code {
        case 3: game.fire(angle: angle, power: power)
        case 45: game.nextShip()
        case 14: game.advanceTurn()
        case 9: changeDisplay()
        case 1: game.setMine()
        case 0: game.armMine()
        default: return false
        }
        return true
    }
}

struct ConflictGameView: View {
    let onExit: () -> Void
    @StateObject private var session = ConflictSession()
    var body: some View {
        VStack(spacing: 16) {
            HStack { Text("CONFLICT 2500 · APPLE II").font(.headline); Spacer()
                Text("Development reconstruction").foregroundStyle(.secondary); Button("Library", action: onExit) }
            if session.setup { setup }
            else {
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 14) {
                        HStack {
                            Picker("View", selection: $session.game.display) { ForEach(ConflictDisplay.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                            Text("TURN \(session.game.turn)").monospacedDigit()
                        }
                        if session.game.display == .map { map }
                        else if session.game.display == .tactical { tactical }
                        else { status }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(session.game.messages.enumerated()), id: \.offset) { Text($0.element).frame(maxWidth: .infinity, alignment: .leading) }
                            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(hex: "A6DB91"))
                        }.frame(maxWidth: .infinity).frame(height: 125).padding(12).background(.black.opacity(0.6))
                    }
                    controls.frame(width: 285)
                }.disabled(session.paused)
                HStack {
                    Button(session.paused ? "Continue" : "Pause") { session.paused.toggle() }
                    Button("Save scenario") { session.save() }
                    Button("New scenario") { session.setup = true }
                    Text(session.message).foregroundStyle(.secondary)
                    Spacer()
                    if session.game.ended { Text(session.game.victory ? "YOU SAVED THE UNIVERSE" : "YOU LOSE").foregroundStyle(.green) }
                }
            }
        }.padding(24).background(Color(hex: "111419"))
            .background(RetroKeys { session.key($0, down: $1) })
            .background(RetroWindow { session.attach($0) })
            .onDisappear { session.stop() }
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Scenario development").font(.largeTitle)
            Stepper("Your ships: \(session.scenario.ships)", value: $session.scenario.ships, in: 1...10)
            Stepper("Computer ships: \(session.scenario.enemies)", value: $session.scenario.enemies, in: 1...20)
            Stepper("Planets: \(session.scenario.planets)", value: $session.scenario.planets, in: 1...10)
            Stepper("Bases: \(session.scenario.bases)", value: $session.scenario.bases, in: 1...10)
            Text("Protect your planets and bases from planet pulverizers. Set headings (0 up, 90 right, 180 down, 270 left), fire once per ship each turn, dock to refuel and leave armed mines behind. Each ship carries two mines.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Button("Start scenario") { session.start() }.buttonStyle(.borderedProminent)
                if session.hasSave { Button("Resume saved scenario") { session.resumeSave() } } }
            Text(session.message).foregroundStyle(.secondary)
            Text("Rules translated from the supplied BASIC program. Native RNG, numeric precision, displays and timing need original comparison. M1 performance unverified.").font(.caption).foregroundStyle(.secondary)
        }.padding(40).frame(maxWidth: 640).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var map: some View {
        VStack(spacing: 8) {
            Text("GALACTIC MAP · 1000 × 1000 MM / SECTOR").font(.caption)
            Grid(horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow { Text(" "); ForEach(1...13, id: \.self) { Text(String(UnicodeScalar(64 + $0)!)) } }
                ForEach(1...9, id: \.self) { row in
                    GridRow {
                        Text(String(row)).foregroundStyle(.secondary)
                        ForEach(1...13, id: \.self) { column in
                            let selected = session.game.currentShip.x / 1000 == column && session.game.currentShip.y / 1000 == row
                            Text(session.game.mapCell(column: column, row: row)).lineLimit(1).minimumScaleFactor(0.5)
                                .frame(maxWidth: .infinity, minHeight: 24)
                                .background(selected ? Color(hex: "245033") : .clear)
                        }
                    }
                }
            }.font(.system(size: 15, design: .monospaced)).foregroundStyle(Color(hex: "A6DB91"))
            Text("B base · 0–9 ships · P planet · M armed mine. Enemy ships appear in tactical view.").font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
    }
    private var tactical: some View {
        GeometryReader { geometry in
            let cell = min(geometry.size.width / 40, geometry.size.height / 40)
            let game = session.game
            let shapes = session.shapes
            Canvas { context, _ in
                func pixel(_ x: Int, _ y: Int, _ color: Color) {
                    guard (0...39).contains(x), (0...39).contains(y) else { return }
                    context.fill(Path(CGRect(x: Double(x) * cell, y: Double(y) * cell, width: cell, height: cell)), with: .color(color))
                }
                for i in 0...39 { pixel(0, i, .green); pixel(39, i, .green); pixel(i, 0, .green); pixel(i, 39, .green) }
                for i in -6...6 { pixel(19 + i, 19 + i, .green); pixel(19 + i, 19 - i, .green) }
                let origin = game.currentShip
                func object(_ x: Int, _ y: Int, _ type: Int) {
                    guard abs(x - origin.x) + abs(y - origin.y) < 2000 else { return }
                    let rx = 18 + Double(x - origin.x) / 50, ry = 18 + Double(y - origin.y) / 40
                    let shape = shapes.count == 5 ? shapes[type - 1] : [[0, 0]]
                    for point in shape {
                        let x = Int(rx + Double(point[0])), y = Int(ry + Double(point[1]))
                        // BASIC810 keeps COLOR12 border/crosshair pixels intact.
                        guard x != 0, x != 39, y != 0, y != 39,
                              !((13...25).contains(x) && (x == y || x + y == 38)) else { continue }
                        pixel(x, y, type == 2 || type == 4 ? .red : .orange)
                    }
                }
                for unit in game.bases where unit.energy > 0 { object(unit.x, unit.y, 1) }
                for unit in game.enemies where unit.energy > 0 { object(unit.x, unit.y, 2) }
                for i in game.ships.indices where i != game.selected && !game.ships[i].destroyed { object(game.ships[i].x, game.ships[i].y, 3) }
                for unit in game.mines where unit.energy > 0 { object(unit.x, unit.y, 4) }
                for unit in game.planets where unit.energy > 0 { object(unit.x, unit.y, 5) }
            }.frame(width: cell * 40, height: cell * 40).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
        }
    }
    private var status: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(session.game.ships.indices, id: \.self) { i in
                    let ship = session.game.ships[i]
                    Button { session.game.selectShip(i) } label: {
                        Text(ship.destroyed ? "SHIP #\(i) DESTROYED" : "SHIP #\(i)  SEC \(ship.sector)  ENERGY \(ship.energy)\nVELOCITY \(Int(hypot(Double(ship.dx), Double(ship.dy))))  HEADING \(ship.displayedHeading)°  DESTROYED \(ship.kills)")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(i == session.game.selected ? Color(hex: "245033") : .clear)
                    }.buttonStyle(.plain).disabled(ship.destroyed)
                }
            }.font(.system(size: 14, design: .monospaced)).foregroundStyle(Color(hex: "A6DB91"))
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
    }
    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("SHIP #\(session.game.selected) · \(session.game.currentShip.sector)").font(.title2)
                Text("ENERGY \(session.game.currentShip.energy)").font(.system(.headline, design: .monospaced))
                HStack { Button("Next ship") { session.game.nextShip() }; Button("End turn") { session.game.advanceTurn() } }
                Divider()
                number("Firing angle", value: $session.angle, range: 0...360)
                number("Power", value: $session.power, range: 0...200)
                Button("Fire") { session.game.fire(angle: session.angle, power: session.power) }.disabled(session.game.currentShip.fired || session.game.ended)
                Divider()
                number("Velocity", value: $session.speed, range: 0...5000)
                number("Heading", value: $session.heading, range: 0...359)
                Button("Change course") { session.game.changeCourse(speed: session.speed, heading: session.heading) }
                Divider()
                Picker("Dock with", selection: $session.dock) { ForEach(ConflictDock.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) } }
                if session.dock == .ship { number("Transfer energy", value: $session.transfer, range: -30000...30000) }
                Button("Dock") { session.game.dock(session.dock, transfer: session.transfer) }
                HStack { Button("Set mine") { session.game.setMine() }; Button("Arm mine") { session.game.armMine() } }
                Text("\(max(0, session.game.mines.count - 1 - session.game.placedMine)) mines available").foregroundStyle(.secondary)
                Divider()
                Text("F fire · N next ship · E end turn\nV view · S set mine · A arm\nEsc / Menu / B pause\nController: X fire · A next · Y end\nRB change view")
                    .font(.system(size: 10, design: .monospaced)).lineSpacing(3)
            }.disabled(session.game.ended)
        }
    }
    private func number(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack { Text(label); Spacer(); TextField(label, value: value, format: .number).frame(width: 72).textFieldStyle(.roundedBorder) }
    }
}
