import AppKit
import Combine
import Foundation
import SwiftUI

/// Bounded source masks composed into a native raster. This does not implement
/// ANTIC/GTIA, calibrated Atari colors or original raster-latch timing.
struct Asteroids8BitPresentation {
    let resources: Asteroids8BitResources
    static let path = "Library/Prepared/asteroids8bit/asteroids8bit.json"
    static func load(root: URL) throws -> Self {
        Self(resources: try Asteroids8BitResources.load(from: root.appendingPathComponent(path)))
    }
    func image(game: Asteroids8BitSimulation) throws -> CGImage {
        var bitmap = [Bool](repeating: false, count: 160 * 96)
        func pixel(_ x: Int, _ y: Int, xor: Bool = false) {
            guard (0..<160).contains(x), (0..<96).contains(y) else { return }
            let p = y * 160 + x
            bitmap[p] = xor ? !bitmap[p] : true
        }
        func mask(_ rows: [UInt16], x: Int, y: Int) {
            for row in rows.indices { for column in 0..<16 where rows[row] & (0x8000 >> column) != 0 {
                pixel(x + column, y + row, xor: true)
            } }
        }
        for entity in game.state.asteroids.dropFirst() where entity.active {
            mask(resources.asteroidMask(kind: entity.code & 15), x: Int(entity.x), y: Int(entity.y))
        }
        for p in game.explosionPixels { bitmap[p].toggle() }
        for player in game.state.players where player.entity.active {
            mask(resources.shipMask(image: player.image), x: Int(player.entity.x), y: Int(player.entity.y))
        }
        // Source projectile anchors are retained. Hardware missile width,
        // overlap priority and display-list alignment remain unqualified.
        for shot in game.state.shots where shot.active { pixel(Int(shot.x), Int(shot.y)) }
        return try RetroOriginalMedia.image(width: 160, height: 96) { bitmap[$1 * 160 + $0] }
    }
}

struct Asteroids8BitSessionSave: Codable {
    static let startupDescription = "Synthetic development samples v1; zero startup fractions; not original POKEY/OS evidence"
    var schema = 1
    var game: Asteroids8BitSnapshot
    var random: Asteroids8BitRandomStream
    var startupProvenance = Self.startupDescription
    var fraction: Double
    func validate(resources: Asteroids8BitResources) throws {
        guard schema == 1, startupProvenance == Self.startupDescription,
              fraction.isFinite, (0..<1).contains(fraction),
              random.samples.count == 65_536, (0...random.samples.count).contains(random.consumed),
              game.randomReads == UInt64(random.consumed), !game.paused,
              random.samples == Asteroids8BitSession.developmentSamples else { throw Asteroids8BitSimulation.Invalid.snapshot }
        _ = try Asteroids8BitSimulation(resources: resources, snapshot: game)
    }
}

@MainActor
final class Asteroids8BitSession: ObservableObject {
    @Published var simulation: Asteroids8BitSimulation?
    @Published var presentation: Asteroids8BitPresentation?
    @Published var setup = true
    @Published var paused = false
    @Published var loading = false
    @Published var message = ""
    @Published var selection: UInt8 = 0
    @Published var difficulties: [UInt8] = [0, 0, 0, 0]
    @Published var reflectingEdges = false
    @Published var fastAsteroids = false
    let driver = RetroSessionDriver()
    private var loadTask: Task<Void, Never>?
    private var mediaTask: Task<Asteroids8BitPresentation, Error>?
    private var loadGeneration = UUID()
    private var latestSample = NativeGamepadSample()
    private(set) var fraction = 0.0
    private(set) var random: Asteroids8BitRandomStream?
    private var pending = [UInt8](repeating: 0, count: 4)
    private var pendingController = [UInt8](repeating: 0, count: 4)
    private var releasePrime = [UInt8](repeating: 0, count: 4)
    private var priorController: UInt8 = 0
    private var priorIdentity = ""
    private var priorConnected = false
    static let saveID = "asteroids-atari-8bit"
    static let developmentRate = 60.0
    // An explicit finite fixture stream, not an implementation of POKEY RANDOM.
    nonisolated static let developmentSamples = (0..<65_536).map { UInt8(truncatingIfNeeded: ($0 * 73 + 41) ^ ($0 >> 8)) }
    // Bit0 thrust, bit1 special/down, bit2 left, bit3 right, bit4 fire.
    nonisolated static let keyMaps: [[UInt16]] = [
        [126, 125, 123, 124, 49], [13, 1, 0, 2, 3],
        [34, 40, 38, 37, 31], [17, 11, 5, 4, 9]
    ]
    var configuration: Asteroids8BitConfiguration {
        .init(selection: selection, difficulties: difficulties, reflectingEdges: reflectingEdges, fastAsteroids: fastAsteroids)
    }
    var snapshot: Asteroids8BitSessionSave? {
        guard let simulation, let random else { return nil }
        return .init(game: simulation.snapshot, random: random, fraction: fraction)
    }
    var hasSave: Bool {
        guard let media = presentation, let save = RetroSaveStore.load(Asteroids8BitSessionSave.self, id: Self.saveID) else { return false }
        return (try? save.validate(resources: media.resources)) != nil
    }
    func load(root: URL) {
        cancelLoad(); setup = true; paused = false; simulation = nil; presentation = nil; random = nil
        resetInput(); loading = true; message = ""
        let generation = UUID(); loadGeneration = generation
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try Asteroids8BitPresentation.load(root: root)
            try Task.checkCancellation()
            return result
        }
        mediaTask = worker
        loadTask = Task { [weak self] in
            do {
                let media = try await worker.value
                guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
                self.presentation = media; self.loading = false; self.mediaTask = nil; self.loadTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
                self.loading = false; self.mediaTask = nil; self.loadTask = nil
                self.message = error.localizedDescription + " Prepare the selected media with Tools/decode_asteroids8bit.py."
            }
        }
    }
    private func cancelLoad() { loadGeneration = UUID(); loadTask?.cancel(); mediaTask?.cancel(); loadTask = nil; mediaTask = nil; loading = false }
    func attach(_ window: NSWindow?) { driver.attach(window) { [weak self] now in self?.frame(now: now) } }
    func start() {
        guard let media = presentation else { return }
        do {
            var game = try Asteroids8BitSimulation(resources: media.resources, configuration: configuration,
                                                  startupFractions: Array(repeating: (0, 0), count: 35))
            var supply = try Asteroids8BitRandomStream(samples: Self.developmentSamples)
            try game.start(random: &supply)
            simulation = game; random = supply; setup = false; paused = false; message = ""
            resetInput()
        } catch { message = "Could not start the selected original rule configuration: " + error.localizedDescription }
    }
    func restore(_ save: Asteroids8BitSessionSave) throws {
        guard let media = presentation else { throw Asteroids8BitSimulation.Invalid.snapshot }
        try save.validate(resources: media.resources)
        let game = try Asteroids8BitSimulation(resources: media.resources, snapshot: save.game)
        simulation = game; random = save.random; fraction = save.fraction
        selection = save.game.configuration.selection; difficulties = save.game.configuration.difficulties
        reflectingEdges = save.game.configuration.reflectingEdges; fastAsteroids = save.game.configuration.fastAsteroids
        setup = false; paused = true
        blockInput(resetFraction: false)
        message = "Saved game restored paused."
    }
    func resumeSave() {
        guard let save = RetroSaveStore.load(Asteroids8BitSessionSave.self, id: Self.saveID) else { message = "Saved game unavailable or incompatible."; return }
        do { try restore(save) } catch { message = "Saved game unavailable or incompatible." }
    }
    private func blockInput(resetFraction: Bool) {
        pending = Array(repeating: 0, count: 4); pendingController = Array(repeating: 0, count: 4); priorController = 0
        for p in 0..<4 { releasePrime[p] = sourceReleaseBits(player: p) }
        driver.block(PGAControllerInput.current().sample)
        driver.block(latestSample)
        if resetFraction { fraction = 0 }
    }
    func resetInput() { blockInput(resetFraction: true) }
    private func sourceReleaseBits(player: Int) -> UInt8 {
        guard let simulation else { return 0 }
        let state = simulation.state.players[player]
        return (state.triggerLatch ? 16 : 0) | (state.downCounter != 0 || state.entity.code == 0xe0 ? 2 : 0)
    }
    func togglePause() { guard !setup else { return }; paused.toggle(); blockInput(resetFraction: false) }
    func save() {
        guard !setup, let snapshot else { return }
        message = RetroSaveStore.save(snapshot, id: Self.saveID) ? "Game saved." : "Could not save game."
    }
    func stop() {
        cancelLoad(); save(); driver.stop(); pending = Array(repeating: 0, count: 4); pendingController = Array(repeating: 0, count: 4); priorController = 0
        simulation = nil; presentation = nil; random = nil; fraction = 0; setup = true; paused = false
    }
    func newGame() { save(); setup = true; paused = false; resetInput() }
    func key(_ code: UInt16, down: Bool) -> Bool {
        if code == 53 { guard !setup else { return false }; if down { togglePause() }; return true }
        if setup, code == 49 { if down { start() }; return true }
        guard !setup else { return false }
        guard Self.keyMaps.contains(where: { $0.contains(code) }) else { return false }
        if !setup, !paused { driver.key(code, down: down, queue: true) }
        return true
    }
    nonisolated static func keyAction(_ code: UInt16) -> (player: Int, bits: UInt8)? {
        for player in keyMaps.indices { if let action = keyMaps[player].firstIndex(of: code) { return (player, UInt8(1 << action)) } }
        return nil
    }
    nonisolated static func input(bits: UInt8) -> Asteroids8BitInput {
        .init(joystickNibble: (~bits) & 15, fire: bits & 16 != 0)
    }
    func frame(now: Double, focused: Bool? = nil, sample: NativeGamepadSample? = nil, identity: String? = nil) {
        let pad = sample.map { (identity: identity ?? "test", name: Optional<String>.none, sample: $0) } ?? PGAControllerInput.current()
        latestSample = pad.sample
        let active = focused ?? driver.focused
        if pad.identity != priorIdentity || pad.sample.connected != priorConnected {
            pendingController = Array(repeating: 0, count: 4); priorController = 0
            let player = simulation?.state.configuration.mode == 0 ? simulation?.state.currentPlayer ?? 0 : 0
            let keys = Self.keyMaps[player]
            // A held keyboard channel is still the same source joystick input.
            // Priming it on a pad-only change would manufacture a second shot.
            let keyboardHeld: UInt8 = (driver.keys.contains(keys[4]) ? 16 : 0) | (driver.keys.contains(keys[1]) ? 2 : 0)
            releasePrime[player] |= sourceReleaseBits(player: player) & ~keyboardHeld
        }
        priorIdentity = pad.identity; priorConnected = pad.sample.connected
        let input = driver.frame(now: now, focused: active, enabled: !paused, sample: pad.sample, identity: pad.identity)
        if active, input.pressed.contains("Menu") || input.pressed.contains("B") { togglePause() }
        if active, setup, input.pressed.contains("A") { start(); return }
        guard active, !setup, !paused, simulation?.state.phase == .playing else {
            if !active {
                pending = Array(repeating: 0, count: 4); pendingController = Array(repeating: 0, count: 4); priorController = 0
                for p in 0..<4 { releasePrime[p] = sourceReleaseBits(player: p) }
            }
            return
        }
        while let key = driver.takeKey() { if let action = Self.keyAction(key) { pending[action.player] |= action.bits } }
        let player = simulation!.state.configuration.mode == 0 ? simulation!.state.currentPlayer : 0
        var controller: UInt8 = 0
        if input.held.contains("Up") || input.axes[1] > 0.35 { controller |= 1 }
        if input.held.contains("Down") || input.held.contains("X") || input.axes[1] < -0.35 { controller |= 2 }
        if input.held.contains("Left") || input.axes[0] < -0.35 { controller |= 4 }
        if input.held.contains("Right") || input.axes[0] > 0.35 { controller |= 8 }
        if input.held.contains("A") || input.held.contains("RB") { controller |= 16 }
        pendingController[player] |= controller & ~priorController
        priorController = controller
        var held = [UInt8](repeating: 0, count: 4)
        for key in driver.keys { if let action = Self.keyAction(key) { held[action.player] |= action.bits } }
        held[player] |= controller
        guard input.delta > 0 else { return }
        fraction += input.delta * Self.developmentRate
        while fraction >= 1 - 1e-9 {
            let nextEven = ((simulation!.state.videoCounter &+ 1) & 1) == 0
            var inputs = [Asteroids8BitInput](repeating: .init(), count: 4)
            let primed = releasePrime
            let sampling = nextEven ? [0, 2] : [1, 3]
            let eligible = (0..<4).map { p in
                p < simulation!.state.configuration.players &&
                    (simulation!.state.configuration.mode != 0 || p == simulation!.state.currentPlayer) &&
                    simulation!.state.players[p].lives > 0 && [0, 0xe0].contains(simulation!.state.players[p].entity.code)
            }
            for p in 0..<4 { inputs[p] = Self.input(bits: (held[p] | pending[p] | pendingController[p]) & ~primed[p]) }
            do {
                try simulation!.verticalBlank(inputs: inputs, random: &random!)
                // Only the scheduled source joystick half consumes its tap.
                // A display callback without that update is insufficient.
                for p in sampling {
                    // Shield exit bypasses source firing for one half. Keep a
                    // fresh tap until the actual source latch has been released.
                    releasePrime[p] &= sourceReleaseBits(player: p)
                    pending[p] &= eligible[p] ? primed[p] : 0
                    pendingController[p] &= eligible[p] ? primed[p] : 0
                }
                fraction = max(0, fraction - 1)
            } catch {
                paused = true; fraction = min(fraction, 0.999999)
                blockInput(resetFraction: false)
                message = "The finite development sample stream is exhausted. Save or start a new game."
                return
            }
        }
    }
}

struct Asteroids8BitGameView: View {
    let root: URL
    let onExit: () -> Void
    @StateObject private var session = Asteroids8BitSession()
    var body: some View {
        VStack(spacing: 16) {
            HStack { Text("ASTEROIDS · ATARI 8-BIT").font(.headline); Spacer(); Text("Development reconstruction").foregroundStyle(.secondary); Button("Library", action: onExit) }
            if session.presentation == nil {
                VStack(spacing: 16) {
                    if session.loading { ProgressView("Loading original graphics…") }
                    Text(session.message).foregroundStyle(.secondary)
                    Button("Load original media") { session.load(root: root) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.setup {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("ASTEROIDS").font(.largeTitle.monospaced())
                        Picker("Original mode", selection: $session.selection) {
                            ForEach(Asteroids8BitConfiguration.selectionValues, id: \.self) { value in Text(Self.modeName(value)).tag(value) }
                        }
                        ForEach(0..<session.configuration.players, id: \.self) { player in
                            Picker("Player \(player + 1) special control", selection: $session.difficulties[player]) {
                                Text("Shield").tag(UInt8(0)); Text("Hyperspace").tag(UInt8(1))
                                Text("Flip").tag(UInt8(2)); Text("No special control").tag(UInt8(3))
                            }
                        }
                        Toggle("Reflecting edges", isOn: $session.reflectingEdges)
                        Toggle("Fast asteroids", isOn: $session.fastAsteroids)
                        Text("Synthetic development startup").font(.headline)
                        Text("This local reconstruction uses a fixed finite sample sequence and zero startup fractions. Original POKEY randomness and OS startup have not been qualified.").font(.callout).foregroundStyle(.secondary)
                        Text("Player 1: arrows + Space\nPlayer 2: W A S D + F\nPlayer 3: I J K L + O\nPlayer 4: T G B H + V\nUp thrusts; down activates the selected special control.").font(.callout)
                        HStack { Button("Start development game") { session.start() }.buttonStyle(.borderedProminent); Button("Resume saved game") { session.resumeSave() }.disabled(!session.hasSave) }
                        Text(session.message).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: 600).padding()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let game = session.simulation, let media = session.presentation {
                HStack(alignment: .top, spacing: 24) {
                    RetroPixelCanvas(width: 160, height: 96) { context in
                        retroSprite(try? media.image(game: game), x: 0, y: 0, context: &context)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(0..<game.state.configuration.players, id: \.self) { player in
                                Text("P\(player + 1)  \(game.state.players[player].scoreUnits * 10)\nLIVES \(game.state.players[player].lives)").font(.title3.monospacedDigit())
                            }
                            Text("WAVE \(game.state.wave) · ROCKS \(game.state.asteroidCount)").monospacedDigit()
                            Text(session.paused ? "PAUSED" : game.state.phase == .gameOver ? "GAME OVER" : game.state.transitionFrames > 0 ? "PLAYER CHANGE" : "ARROWS + SPACE").foregroundStyle(Color(hex: "C2EF93"))
                            Text("Controller: stick / D-pad\nA / RB fires · X special\nB / Menu pauses\nAlternating mode follows the active player.").font(.callout)
                            Button(session.paused ? "Continue" : "Pause", action: session.togglePause)
                            Button("Save game", action: session.save)
                            Button("New game", action: session.newGame)
                            Text(session.message).font(.caption).foregroundStyle(.secondary)
                            Text("Original masks; monochrome development raster at 60 callbacks/s. Colors, alignment, audio, original comparisons and M1 acceptance remain unqualified.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(width: 270)
                }
            }
        }.padding(24).background(Color(hex: "101318"))
            .background(RetroKeys(handler: session.key).frame(width: 0, height: 0))
            .background(RetroWindow(attached: session.attach).frame(width: 0, height: 0))
            .onAppear { session.load(root: root) }.onDisappear { session.stop() }
    }
    static func modeName(_ selection: UInt8) -> String {
        let c = Asteroids8BitConfiguration(selection: selection, difficulties: [0, 0, 0, 0], reflectingEdges: false, fastAsteroids: false)
        let mode = ["Alternating", "Independent lives", "Shared ending", "Paired teams"][Int(c.mode)]
        return "\(c.players) player\(c.players == 1 ? "" : "s") · \(mode)\(c.opponentFire ? " · opponent fire" : "")"
    }
}
