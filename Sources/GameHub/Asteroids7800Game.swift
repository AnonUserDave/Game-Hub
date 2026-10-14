import AppKit
import Combine
import Foundation
import SwiftUI

/// Immutable original pixels, prepared off the UI thread. Grayscale preserves the
/// three ROM indexes; neither these shades nor complete MARIA output are qualified RGB.
struct Asteroids7800Presentation: @unchecked Sendable {
    static let mediaPath = "Library/Prepared/asteroids7800/asteroids7800.json"
    let resources: Asteroids7800Resources
    let sprites: [String: CGImage]
    static func load(root: URL) throws -> Self {
        let resources = try Asteroids7800Resources.load(url: root.appendingPathComponent(mediaPath))
        return try prepare(resources: resources)
    }
    static func prepare(resources: Asteroids7800Resources) throws -> Self {
        try resources.validate()
        var sprites: [String: CGImage] = [:]
        for (name, frame) in resources.frames {
            if Task.isCancelled { throw CancellationError() }
            // Source 160A pixels are twice as wide as scan lines. Bound all bitmaps
            // at preparation; display scaling does not inflate the original cache.
            let width = frame.width * 2
            var pixels = [UInt8](repeating: 0, count: width * frame.height * 4)
            for row in 0..<frame.height { for column in 0..<frame.width {
                let index = frame.pixels[row * frame.width + column]
                if index == 0 { continue }
                let shade = index * 85
                for half in 0...1 {
                    let offset = (row * width + column * 2 + half) * 4
                    pixels[offset] = shade; pixels[offset + 1] = shade
                    pixels[offset + 2] = shade; pixels[offset + 3] = 255
                }
            } }
            sprites[name] = try RetroOriginalMedia.rgbaImage(width: width, height: frame.height, data: Data(pixels))
        }
        return Self(resources: resources, sprites: sprites)
    }
    struct Stamp: Equatable {
        var name: String
        var x: Int
        var y: Int
        var sourcePalette: UInt8
    }
    /// $D16D and $D113: authored option/title stamps. This preview uses their
    /// original locations and widths, without claiming RGB or full screens.
    func menu(mode: Asteroids7800Mode, difficulty: Int) -> [Stamp] {
        guard (0...3).contains(difficulty) else { return [] }
        let table = resources.tables
        let modeOption = mode == .single ? 14 : 15 + mode.rawValue
        let ships: [Int]
        switch mode { case .single: ships = [22]; case .alternating: ships = [23,24]
        case .team: ships = [25,26]; case .competition: ships = [27,28] }
        let indices = Array((0...9).reversed()) + [10 + difficulty, modeOption] + ships
        return indices.map { index in
            let image = table["menuImages"]![index], palette = table["menuPalettes"]![index]
            return Stamp(name: String(format:"menu-%02x-%d", image, 32 - Int(palette & 31)),
                         x: Int(table["menuX"]![index]) * 2, y: Int(table["menuY"]![index]), sourcePalette: palette)
        }
    }
    /// $FBF4 emits high object slots first. Wrapped copies retain original integer
    /// seams; the saucer's offscreen entry is excluded from horizontal wrapping.
    func objects(_ objects: [Asteroids7800Object]) -> [Stamp] {
        guard objects.count == 33 else { return [] }
        var stamps: [Stamp] = []
        for slot in (0..<33).reversed() {
            let object = objects[slot]
            guard object.code != 255 else { continue }
            let image = object.kind == 6 ? UInt8(254) : object.image
            let width = object.kind == 6 ? 1 : 32 - Int(object.palette & 31)
            let name = String(format: "objects-%02x-%d", image, width)
            guard sprites[name] != nil else { continue }
            let x = Int(object.x >> 8), y = Int(object.y >> 8)
            let xs = slot != 25 && x >= 151 && x < 240 ? [x, x - 159] : [x]
            let ys = y > 176 && y < 192 ? [y, y - 192] : [y]
            for row in ys { for column in xs {
                stamps.append(Stamp(name: name, x: column * 2, y: row, sourcePalette: object.palette))
            } }
        }
        return stamps
    }
    /// Original digit glyph selection follows $DEB9's suppressed leading zeroes.
    /// The session's score-strip placement remains an explicit development layout.
    static func scoreGlyphs(_ score: Int) -> [Int] {
        guard (0..<100_000_000).contains(score) else { return [] }
        let digits = String(score).utf8.map { Int($0 - 48) + 1 }
        return Array(repeating: 0, count: 8 - digits.count) + digits
    }
}

struct Asteroids7800SessionSave: Codable, Sendable {
    static let startupProvenance = "Synthetic development startup v1: reproducible RAM byte ramp 0...255 and timer31; not original console startup evidence."
    var schema = 1
    var sourceSHA256 = Asteroids7800Resources.sourceIdentity
    var startupPolicy = "synthetic-development-v1"
    var game: Asteroids7800Snapshot
    /// Fraction of one source main pass, not display frames or elapsed real time.
    var mainFraction: Double
    func validate(resources: Asteroids7800Resources) throws {
        guard schema == 1, sourceSHA256 == Asteroids7800Resources.sourceIdentity,
              startupPolicy == "synthetic-development-v1", game.randomStartupProvenance == Self.startupProvenance,
              mainFraction.isFinite, mainFraction >= 0, mainFraction < 1 else {
            throw RetroMediaError.invalid("The 7800 save is incompatible or has an invalid source clock/startup.")
        }
        _ = try Asteroids7800Simulation(resources: resources, snapshot: game)
    }
}

@MainActor
final class Asteroids7800Session: ObservableObject {
    @Published var simulation: Asteroids7800Simulation?
    @Published var presentation: Asteroids7800Presentation?
    @Published var mode: Asteroids7800Mode = .single
    @Published var difficulty = 1
    @Published var setup = true
    @Published var paused = false
    @Published var loading = false
    @Published var message = ""
    let driver = RetroSessionDriver()
    static let saveID = "asteroids-atari-7800-development-v1"
    static let developmentMainRate = 30.0
    static let modeLabels: [Asteroids7800Mode:String] = [.single:"One player", .alternating:"Two players alternating", .team:"Two players team", .competition:"Two players competition"]
    static let difficultyLabels = ["Novice", "Intermediate", "Advanced", "Expert"]
    private var loadTask: Task<Void,Never>?
    private var loadWorker: Task<Result<Asteroids7800Presentation,Error>,Never>?
    private var loadGeneration = UUID()
    private var stopped = false
    private(set) var mainFraction = 0.0
    private var pendingController = Asteroids7800Input()
    private var pendingControllerPlayer = 0
    private var lastSample: NativeGamepadSample?
    private var lastControllerIdentity: String?
    private var lastControllerConnected: Bool?
    var snapshot: Asteroids7800SessionSave? {
        simulation.map { Asteroids7800SessionSave(game: $0.snapshot, mainFraction: mainFraction) }
    }
    var hasSave: Bool {
        guard let presentation, let saved = RetroSaveStore.load(Asteroids7800SessionSave.self, id: Self.saveID) else { return false }
        return (try? saved.validate(resources: presentation.resources)) != nil
    }
    var sourceFault: String? { simulation?.state.sourceFault }
    func load(root: URL) {
        loadTask?.cancel(); loadWorker?.cancel(); loading = true; message = ""; stopped = false
        let generation = UUID(); loadGeneration = generation
        let worker = Task.detached(priority: .userInitiated) { Result { try Asteroids7800Presentation.load(root: root) } }
        loadWorker = worker
        loadTask = Task { [weak self] in
            let result = await worker.value
            guard !Task.isCancelled, let self, !self.stopped, self.loadGeneration == generation else { return }
            self.loading = false; self.loadTask = nil; self.loadWorker = nil
            switch result {
            case let .success(media): self.install(media: media)
            case let .failure(error):
                self.presentation = nil; self.simulation = nil
                self.message = error.localizedDescription + " Prepare the supplied 7800 media with Tools/decode_asteroids7800.py."
            }
        }
    }
    func install(media: Asteroids7800Presentation) {
        do {
            let startup = Asteroids7800Startup(existingRandomPage: (0..<256).map { UInt8($0) },
                timerByte: 31, provenance: Asteroids7800SessionSave.startupProvenance)
            simulation = try Asteroids7800Simulation(resources: media.resources, startup: startup)
            presentation = media; setup = true; paused = false; mainFraction = 0; stopped = false
            message = "Synthetic development startup. Original boot randomness and firmware remain unqualified."
        } catch { presentation = nil; simulation = nil; message = error.localizedDescription }
    }
    func attach(_ window: NSWindow?) { driver.attach(window) { [weak self] now in self?.frame(now: now) } }
    func start() {
        guard presentation != nil, (0...3).contains(difficulty), simulation != nil else { return }
        do { try simulation?.configure(mode: mode, difficulty: difficulty) }
        catch { message = error.localizedDescription; return }
        simulation?.start(); setup = false; paused = false; mainFraction = 0
        message = "Synthetic development startup; original comparison pending."; neutralizeInput()
    }
    func restore(_ saved: Asteroids7800SessionSave) throws {
        guard let presentation else { throw RetroMediaError.invalid("Original 7800 media is unavailable.") }
        try saved.validate(resources: presentation.resources)
        simulation = try Asteroids7800Simulation(resources: presentation.resources, snapshot: saved.game)
        mode = saved.game.mode; difficulty = saved.game.difficulty; mainFraction = saved.mainFraction
        setup = false; paused = true; neutralizeInput(); message = "Synthetic development game restored, paused."
    }
    func resumeSave() {
        guard let saved = RetroSaveStore.load(Asteroids7800SessionSave.self, id: Self.saveID) else {
            message = "Saved game is unavailable."; return
        }
        do { try restore(saved) } catch { message = error.localizedDescription }
    }
    func save() {
        guard !setup, let saved = snapshot else { return }
        message = RetroSaveStore.save(saved, id: Self.saveID) ? "Game saved." : "Could not save game."
    }
    func stop() {
        stopped = true; loadGeneration = UUID(); loadTask?.cancel(); loadWorker?.cancel()
        loadTask = nil; loadWorker = nil; loading = false
        save(); driver.stop(); pendingController = .init(); lastSample = nil
        // Release immutable pixel caches and native state on return to the hub.
        presentation = nil; simulation = nil; lastControllerIdentity = nil; lastControllerConnected = nil
    }
    func togglePause() {
        guard !setup, simulation != nil else { return }
        paused.toggle(); neutralizeInput()
    }
    func newGame() { save(); setup = true; paused = false; mainFraction = 0; neutralizeInput() }
    private func neutralizeInput() {
        driver.block(lastSample ?? PGAControllerInput.current().sample)
        pendingController = .init()
    }
    enum Action: Equatable { case left, right, thrust, hyperspace, fire, secondButton }
    static func action(for key: UInt16) -> (player: Int, action: Action)? {
        switch key {
        case 123: return (0,.left); case 124: return (0,.right); case 126: return (0,.thrust)
        case 125: return (0,.hyperspace); case 49: return (0,.fire); case 14: return (0,.secondButton)
        case 0: return (1,.left); case 2: return (1,.right); case 13: return (1,.thrust)
        case 1: return (1,.hyperspace); case 3: return (1,.fire); case 5: return (1,.secondButton)
        default: return nil
        }
    }
    private static func apply(_ action: Action, to input: inout Asteroids7800Input) {
        switch action { case .left: input.left = true; case .right: input.right = true
        case .thrust: input.thrust = true; case .hyperspace: input.hyperspace = true
        case .fire: input.fire = true; case .secondButton: input.secondButton = true }
    }
    private static func merge(_ first: Asteroids7800Input, _ second: Asteroids7800Input) -> Asteroids7800Input {
        .init(left: first.left || second.left, right: first.right || second.right,
              thrust: first.thrust || second.thrust, hyperspace: first.hyperspace || second.hyperspace,
              fire: first.fire || second.fire, secondButton: first.secondButton || second.secondButton)
    }
    func key(_ code: UInt16, down: Bool) -> Bool {
        if code == 53 { guard !setup else { return false }; if down { togglePause() }; return true }
        if setup && (code == 36 || code == 49) { if down { start() }; return true }
        guard !setup else { return false }
        guard Self.action(for: code) != nil else { return false }
        guard !setup, !paused, sourceFault == nil else { return true }
        driver.key(code, down: down, queue: down); return true
    }
    static func controllerInput(_ frame: RetroSessionDriver.Frame) -> Asteroids7800Input {
        .init(left: frame.held.contains("Left") || frame.axes[0] < -0.35,
              right: frame.held.contains("Right") || frame.axes[0] > 0.35,
              thrust: frame.held.contains("Up") || frame.axes[1] > 0.35,
              hyperspace: frame.held.contains("Down") || frame.axes[1] < -0.35 || frame.held.contains("X"),
              fire: frame.held.contains("A"), secondButton: frame.held.contains("Y"))
    }
    func frame(now: Double, focused: Bool? = nil, sample: NativeGamepadSample? = nil, identity: String? = nil) {
        guard !stopped else { return }
        let controller = sample.map { (identity: identity ?? "test", name: Optional<String>.none, sample: $0) } ?? PGAControllerInput.current()
        let changed = lastControllerIdentity != controller.identity || lastControllerConnected != controller.sample.connected
        if changed { pendingController = .init() }
        lastControllerIdentity = controller.identity; lastControllerConnected = controller.sample.connected
        lastSample = controller.sample
        let active = focused ?? driver.focused
        let frame = driver.frame(now: now, focused: active, enabled: !paused && sourceFault == nil,
                                 sample: controller.sample, identity: controller.identity)
        if active && (frame.pressed.contains("Menu") || frame.pressed.contains("B")) { togglePause(); return }
        if active && setup && frame.pressed.contains("A") { start(); return }
        guard active, !setup, !paused, sourceFault == nil, simulation != nil else {
            pendingController = .init(); return
        }
        let command = Self.controllerInput(frame)
        let player = mode == .alternating ? simulation!.state.activePlayer : 0
        if pendingControllerPlayer != player { pendingController = .init(); pendingControllerPlayer = player }
        pendingController = Self.merge(pendingController, command)
        guard frame.delta > 0 else { return }
        mainFraction += frame.delta * Self.developmentMainRate
        while mainFraction >= 1 - 1e-9 {
            var inputs = [Asteroids7800Input(),Asteroids7800Input()]
            for key in driver.keys {
                if let binding = Self.action(for: key) { Self.apply(binding.action, to: &inputs[binding.player]) }
            }
            if let tap = driver.takeKey(), let binding = Self.action(for: tap) { Self.apply(binding.action, to: &inputs[binding.player]) }
            let routedPlayer = mode == .alternating ? simulation!.state.activePlayer : 0
            if pendingControllerPlayer != routedPlayer { pendingController = .init() }
            inputs[routedPlayer] = Self.merge(inputs[routedPlayer], Self.merge(command, pendingController))
            pendingController = .init()
            simulation?.tick(inputs: inputs)
            _ = simulation?.takeEvents() // Sound output remains unqualified; keep the source event queue bounded.
            mainFraction = max(0, mainFraction - 1)
            if let fault = sourceFault { message = fault; neutralizeInput(); break }
        }
    }
}

struct Asteroids7800GameView: View {
    let root: URL
    let onExit: () -> Void
    @StateObject private var session = Asteroids7800Session()
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("ASTEROIDS · ATARI 7800").font(.headline)
                Spacer(); Text("Development reconstruction").foregroundStyle(.secondary)
                Button("Library", action: onExit)
            }
            if session.presentation == nil {
                RetroLoadingPanel(message: session.message, loading: session.loading) { session.load(root: root) }
            } else if let media = session.presentation {
                HStack(alignment: .top, spacing: 24) {
                    RetroPixelCanvas(width: 320, height: 192) { draw(media: media, context: &$0) }
                    VStack(alignment: .leading, spacing: 14) {
                        if session.setup {
                            Text("Synthetic development startup").font(.title2)
                            Text("Uses a reproducible synthetic startup. Original console boot randomness and optional firmware are still unqualified.").font(.callout)
                            Picker("Mode", selection: $session.mode) {
                                ForEach([Asteroids7800Mode.single,.alternating,.team,.competition], id: \.self) { mode in Text(Asteroids7800Session.modeLabels[mode]!).tag(mode) }
                            }
                            Picker("Difficulty", selection: $session.difficulty) {
                                ForEach(0..<4) { difficulty in Text(Asteroids7800Session.difficultyLabels[difficulty]).tag(difficulty) }
                            }
                            Button("Start synthetic development game") { session.start() }.buttonStyle(.borderedProminent)
                            Button("Resume saved game") { session.resumeSave() }.disabled(!session.hasSave)
                        } else if let game = session.simulation {
                            score(label: "PLAYER 1", player: game.players[0], media: media)
                            if session.mode != .single { score(label: "PLAYER 2", player: game.players[1], media: media) }
                            if session.mode == .team { Text("TEAM \(game.state.sharedScore) · RESERVE \(game.state.sharedLives)").monospacedDigit() }
                            Text(session.paused ? "PAUSED" : game.state.screen == .playing ? "WAVE \(Int(game.players[game.state.activePlayer].wave) + 1)" : "ROUND ENDED").foregroundStyle(Color(hex:"C2EF93"))
                            if let fault = session.sourceFault { Text(fault).foregroundStyle(.orange) }
                            Button(session.paused ? "Continue" : "Pause") { session.togglePause() }
                            Button("Save game") { session.save() }
                            Button("New game") { session.newGame() }
                        }
                        Text("P1: arrows turn / thrust / hyperspace\nSpace fires · E second button\nP2: A D turn · W thrust · S hyperspace\nF fires · G second button\nEscape pauses").font(.caption)
                        Text("Controller: stick / D-pad turns and thrusts\nA fires · X hyperspace · Y second button\nB / Menu pauses\nAlternating mode follows the active player.").font(.caption).foregroundStyle(.secondary)
                        Text(session.message).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Original indexed masks in grayscale. HUD layout, RGB, audio and original cadence unqualified. Development pacing: 30 main passes / second. Original comparison and M1 acceptance pending.").font(.caption).foregroundStyle(.secondary)
                    }.frame(width: 320)
                }
            }
        }.padding(24).background(Color(hex:"101318"))
            .background(RetroKeys(handler: session.key).frame(width: 0,height: 0))
            .background(RetroWindow(attached: session.attach).frame(width: 0,height: 0))
            .onAppear { session.load(root: root) }.onDisappear { session.stop() }
    }
    private func score(label: String, player: Asteroids7800Player, media: Asteroids7800Presentation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(label) · RESERVE \(player.lives)").font(.caption.monospacedDigit())
            Canvas { context, _ in
                for (index, glyph) in Asteroids7800Presentation.scoreGlyphs(player.score).enumerated() where glyph != 0 {
                    retroSprite(media.sprites["glyph-\(glyph)"], x: index * 8, y: 0, context: &context)
                }
            }.frame(width: 64,height: 8).scaleEffect(2,anchor:.leading).frame(height:18)
        }
    }
    private func draw(media: Asteroids7800Presentation, context: inout GraphicsContext) {
        let stamps: [Asteroids7800Presentation.Stamp]
        if !session.setup, let game = session.simulation, game.state.screen == .playing || game.state.screen == .paused {
            stamps = media.objects(game.objects)
        } else { stamps = media.menu(mode: session.mode, difficulty: session.difficulty) }
        for stamp in stamps { retroSprite(media.sprites[stamp.name], x: stamp.x, y: stamp.y, context: &context) }
    }
}
