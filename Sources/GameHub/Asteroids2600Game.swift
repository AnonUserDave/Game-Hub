import AppKit
import Combine
import Foundation
import SwiftUI

/// Prepared original masks, with mirrored ship pixels cached once. No generated
/// asteroid/ship art is substituted when the selected package is unavailable.
struct Asteroids2600Presentation {
    static let path = "Library/Prepared/asteroids2600/asteroids2600.json"
    let resources: Asteroids2600Resources
    let sprites: [String: CGImage]
    let reflectedShips: [String: CGImage]

    static func load(root: URL) throws -> Self {
        try Task.checkCancellation()
        let resources = try Asteroids2600Resources.load(from: root.appendingPathComponent(path))
        var sprites: [String: CGImage] = [:], reflected: [String: CGImage] = [:]
        for mask in resources.masks {
            try Task.checkCancellation()
            sprites[mask.name] = try RetroOriginalMedia.image(width: mask.width, height: mask.rows.count) { x, y in
                mask.rows[y] & (1 << (mask.width - 1 - x)) != 0
            }
            if mask.name.hasPrefix("ship-") {
                reflected[mask.name] = try RetroOriginalMedia.image(width: mask.width, height: mask.rows.count) { x, y in
                    mask.rows[y] & (1 << x) != 0
                }
            }
        }
        return Self(resources: resources, sprites: sprites, reflectedShips: reflected)
    }
}

struct Asteroids2600SessionSave: Codable, Equatable {
    var schema = 1
    var sourceSHA256 = Asteroids2600Resources.sourceIdentity
    var contentSHA256 = Asteroids2600Resources.contentIdentity
    var developmentFrameRate = 60.0
    var game: Asteroids2600Snapshot
    var frameFraction: Double
    var saucerSwitches: [Bool]

    func validate(resources: Asteroids2600Resources) throws {
        guard schema == 1, sourceSHA256 == Asteroids2600Resources.sourceIdentity,
              contentSHA256 == Asteroids2600Resources.contentIdentity, developmentFrameRate == 60,
              frameFraction.isFinite, frameFraction >= 0, frameFraction < 1,
              saucerSwitches.count == 2 else { throw Asteroids2600Error.invalidSnapshot }
        _ = try Asteroids2600Simulation(resources: resources, snapshot: game)
    }
}

enum Asteroids2600Action: Hashable { case left, right, thrust, down, fire }

@MainActor
final class Asteroids2600Session: ObservableObject {
    static let saveID = "asteroids-atari-2600"
    static let developmentFrameRate = 60.0
    static let variationValues: [UInt8] = Array(UInt8(0)...UInt8(31)) + [0x80]
        + Array(UInt8(32)...UInt8(63)) + [0xa0]
    @Published var presentation: Asteroids2600Presentation?
    @Published var simulation: Asteroids2600Simulation?
    @Published var selectedVariation: UInt8 = 0
    @Published var playerOneSaucers = true
    @Published var playerTwoSaucers = true
    @Published var setup = true
    @Published var paused = false
    @Published var loading = false
    @Published var message = ""
    let driver = RetroSessionDriver()
    private(set) var frameFraction = 0.0
    private(set) var pendingControllerActions: [Asteroids2600Action] = []
    private var previousControllerActions = Set<Asteroids2600Action>()
    private var previousControllerIdentity = ""
    private var previousControllerConnected = false
    private var latestSample = NativeGamepadSample()
    private var needsNeutralPass = false
    private var primeControllerAfterDetach = false
    private var loadGeneration = UUID()
    private var loadTask: Task<Void, Never>?
    private var mediaTask: Task<Asteroids2600Presentation, Error>?

    static func action(for code: UInt16) -> Asteroids2600Action? {
        switch code {
        case 123, 0: return .left
        case 124, 2: return .right
        case 126, 13: return .thrust
        case 125, 1: return .down
        case 49: return .fire
        default: return nil
        }
    }
    static func variationNumber(_ value: UInt8) -> Int {
        value & 0x80 != 0 ? (value & 0x20 != 0 ? 66 : 33)
            : Int(value) + 1 + (value & 0x20 != 0 ? 1 : 0)
    }
    static func variationDescription(_ value: UInt8) -> String {
        let players = value & 0x20 == 0 ? "One player" : "Two alternating players"
        if value & 0x80 != 0 { return "\(players) · Original special variation" }
        let bonus = value & 6 == 0 ? "5,000" : value & 6 == 2 ? "10,000" : "20,000"
        let lives = value & 6 == 6 ? "No bonus lives" : "Bonus ship every \(bonus) points"
        let special: String
        switch value & 0x18 { case 0: special = "Hyperspace"; case 8: special = "Shield"; case 16: special = "Flip"; default: special = "No special control" }
        return "\(players) · \(lives) · \(special)"
    }
    var snapshot: Asteroids2600SessionSave? {
        guard let simulation else { return nil }
        return Asteroids2600SessionSave(game: simulation.snapshot, frameFraction: frameFraction,
                                       saucerSwitches: [playerOneSaucers, playerTwoSaucers])
    }
    var hasSave: Bool {
        guard let media = presentation, let saved = RetroSaveStore.load(Asteroids2600SessionSave.self, id: Self.saveID),
              !saved.game.selectionReturn else { return false }
        return (try? saved.validate(resources: media.resources)) != nil
    }
    func load(root: URL) {
        cancelLoad(); setup = true; paused = false; simulation = nil; presentation = nil
        resetInput(); frameFraction = 0; loading = true; message = ""
        let generation = UUID(); loadGeneration = generation
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let media = try Asteroids2600Presentation.load(root: root)
            try Task.checkCancellation()
            return media
        }
        mediaTask = worker
        loadTask = Task { [weak self] in
            do {
                let media = try await worker.value
                guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
                self.presentation = media
                self.simulation = try Asteroids2600Simulation(resources: media.resources, variation: self.selectedVariation)
                self.loading = false; self.mediaTask = nil; self.loadTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
                self.loading = false; self.mediaTask = nil; self.loadTask = nil
                self.message = "Prepare the selected original media with Tools/prepare_asteroids2600.py. " + error.localizedDescription
            }
        }
    }
    private func cancelLoad() {
        loadGeneration = UUID(); mediaTask?.cancel(); loadTask?.cancel()
        mediaTask = nil; loadTask = nil; loading = false
    }
    func attach(_ window: NSWindow?) {
        guard let window else { driver.stop(); resetInput(); primeControllerAfterDetach = true; return }
        driver.attach(window) { [weak self] now in self?.frame(now: now) }
    }
    func start() {
        guard let media = presentation else { return }
        do {
            simulation = try Asteroids2600Simulation(resources: media.resources, variation: selectedVariation)
            frameFraction = 0; setup = false; paused = false; message = ""; resetInput()
        } catch { message = "This source variation is unavailable." }
    }
    func restore(_ saved: Asteroids2600SessionSave) throws {
        guard let media = presentation else { throw Asteroids2600Error.invalidResources }
        try saved.validate(resources: media.resources)
        simulation = try Asteroids2600Simulation(resources: media.resources, snapshot: saved.game)
        selectedVariation = saved.game.variation
        playerOneSaucers = saved.saucerSwitches[0]; playerTwoSaucers = saved.saucerSwitches[1]
        frameFraction = saved.frameFraction; setup = false; paused = true; resetInput()
        message = "Saved game restored paused."
    }
    func resumeSave() {
        guard let saved = RetroSaveStore.load(Asteroids2600SessionSave.self, id: Self.saveID) else { message = "Saved game is unavailable or incompatible."; return }
        do { try restore(saved) } catch { message = "Saved game is unavailable or incompatible." }
    }
    func save() {
        guard !setup, let snapshot else { return }
        message = RetroSaveStore.save(snapshot, id: Self.saveID) ? "Game saved." : "Could not save game."
    }
    func togglePause() { guard !setup else { return }; paused.toggle(); resetInput() }
    func newGame() { save(); setup = true; paused = false; resetInput() }
    func stop() {
        cancelLoad(); save(); driver.stop(); resetPendingInput(); frameFraction = 0
        simulation = nil; presentation = nil; setup = true; paused = false
    }
    private func resetPendingInput() {
        pendingControllerActions.removeAll(); previousControllerActions.removeAll()
        if let state = simulation?.state { needsNeutralPass = state.fireLatch || state.downLatch || state.flipLatch || state.shield }
        else { needsNeutralPass = false }
    }
    private func resetInput() {
        // Read the live pad at a UI boundary, including a button pressed since
        // the last display callback. Injected test identities retain their sample.
        let current = PGAControllerInput.current()
        let sample = current.identity == previousControllerIdentity && current.sample.connected == latestSample.connected
            ? current.sample : latestSample
        driver.block(sample); resetPendingInput()
    }
    func key(_ code: UInt16, down: Bool) -> Bool {
        if code == 53 { guard !setup else { return false }; if down { togglePause() }; return true }
        if setup && (code == 49 || code == 36) { if down { start() }; return true }
        guard !setup else { return false }
        guard Self.action(for: code) != nil else { return false }
        if !setup && !paused && simulation?.state.ended == false { driver.key(code, down: down, queue: true) }
        return true
    }

    /// Independent display adapter. Source odd/even passes remain in the core;
    /// short taps stay queued until an even input pass, including zero-delta UI callbacks.
    func frame(now: Double, focused: Bool? = nil, sample: NativeGamepadSample? = nil, identity: String? = nil) {
        let controller = sample.map { (identity: identity ?? "test", name: Optional<String>.none, sample: $0) } ?? PGAControllerInput.current()
        latestSample = controller.sample
        if primeControllerAfterDetach {
            driver.block(controller.sample); resetPendingInput(); primeControllerAfterDetach = false
        }
        let active = focused ?? driver.focused
        let input = driver.frame(now: now, focused: active, enabled: !paused, sample: controller.sample, identity: controller.identity)
        let controllerChanged = previousControllerIdentity != controller.identity || previousControllerConnected != controller.sample.connected
        previousControllerIdentity = controller.identity; previousControllerConnected = controller.sample.connected
        if controllerChanged { pendingControllerActions.removeAll(); previousControllerActions.removeAll() }
        if !active { resetPendingInput(); return }
        if input.pressed.contains("Menu") || input.pressed.contains("B") { togglePause(); return }
        if setup && input.pressed.contains("A") { start(); return }
        guard !setup, !paused, simulation != nil else { resetPendingInput(); return }
        let controllerActions = Self.controllerActions(input)
        for action in [Asteroids2600Action.left, .right, .thrust, .down, .fire]
            where controllerActions.contains(action) && !previousControllerActions.contains(action) && pendingControllerActions.count < 8 {
            pendingControllerActions.append(action)
        }
        previousControllerActions = controllerActions
        guard input.delta > 0 else { return }
        frameFraction += input.delta * Self.developmentFrameRate
        while frameFraction >= 1 - 1e-9 {
            guard var game = simulation else { break }
            var actions = Set<Asteroids2600Action>()
            let even = (game.state.frame &+ 1) & 1 == 0
            if even && !game.state.ended {
                if needsNeutralPass { needsNeutralPass = false }
                else {
                    actions = Set(driver.keys.compactMap(Self.action)); actions.formUnion(controllerActions)
                    // Two quick fire taps need a sampled release between them.
                    // Preserve the second queued press while the first latch clears.
                    if let key = driver.pendingKeys.first, let action = Self.action(for: key),
                       action != .fire || !game.state.fireLatch || actions.contains(.fire) {
                        _ = driver.takeKey(); actions.insert(action)
                    }
                    if let action = pendingControllerActions.first,
                       action != .fire || !game.state.fireLatch || actions.contains(.fire) {
                        pendingControllerActions.removeFirst(); actions.insert(action)
                    }
                }
            }
            game.frame(input: .init(left: actions.contains(.left), right: actions.contains(.right),
                thrust: actions.contains(.thrust), down: actions.contains(.down), fire: actions.contains(.fire),
                saucersEnabled: game.state.currentPlayer == 0 ? playerOneSaucers : playerTwoSaucers))
            _ = game.takeEvents() // Original audio sequencing is still unqualified.
            simulation = game; frameFraction = max(0, frameFraction - 1)
            if game.state.selectionReturn { save(); setup = true; resetInput(); frameFraction = 0; message = "Choose a new game."; break }
        }
    }
    private static func controllerActions(_ frame: RetroSessionDriver.Frame) -> Set<Asteroids2600Action> {
        var actions = Set<Asteroids2600Action>()
        if frame.held.contains("Left") || frame.axes[0] < -0.35 { actions.insert(.left) }
        if frame.held.contains("Right") || frame.axes[0] > 0.35 { actions.insert(.right) }
        if frame.held.contains("Up") || frame.held.contains("A") || frame.axes[1] > 0.35 { actions.insert(.thrust) }
        if frame.held.contains("Down") || frame.held.contains("Y") || frame.axes[1] < -0.35 { actions.insert(.down) }
        if frame.held.contains("X") { actions.insert(.fire) }
        return actions
    }
}

struct Asteroids2600SpritePlacement: Equatable {
    var name: String
    var x: Int
    var y: Int
    var horizontalScale = 1
    var reflected = false
}

/// Source coordinates/masks in an explicit development layout. TIA intraline
/// placement, RGB, complete crop and pixel repetition still need comparison.
enum Asteroids2600Screen {
    static let width = 160
    static let height = 200
    static let fieldTop = 16
    static let fieldHeight = 178
    static func sourceRow(_ y: UInt8) -> Int { y & 0x80 != 0 ? Int(Int8(bitPattern: y)) : Int(y) }
    static func placements(game: Asteroids2600Simulation) -> [Asteroids2600SpritePlacement] {
        var values = (game.state.upward + game.state.downward).map { object in
            Asteroids2600SpritePlacement(name: "asteroid-\(object.kind)", x: Int(game.resources.horizontalPixel(object.horizontal)),
                y: sourceRow(object.y), horizontalScale: object.kind < 2 ? 2 : 1)
        }
        if game.shipVisible {
            values.append(.init(name: game.shipMaskName, x: Int(game.resources.horizontalPixel(game.state.shipHorizontal)),
                                y: sourceRow(game.state.shipY), reflected: game.shipReflected))
        }
        if game.state.saucerY != 0xe0 {
            // The source chooses the graphic before advancing its explosion
            // counter. Retain the displayed phase rather than its next phase.
            let name = game.state.saucerExploding ? "explosion-\(max(0, Int(game.state.saucerExplosionFrame) - 1))"
                : (game.state.saucerFlags & 0x20 != 0 ? "saucer-small" : "saucer-large")
            values.append(.init(name: name, x: Int(game.resources.horizontalPixel(game.state.saucerHorizontal)), y: Int(game.state.saucerY)))
        }
        return values
    }
    static func draw(game: Asteroids2600Simulation, media: Asteroids2600Presentation, context: inout GraphicsContext) {
        // The source HUD digits are used directly. Their native placement is
        // provisional while the original score/selection kernel is reconciled.
        for (player, x) in [(0, 4), (1, 102)] where player == 0 || game.twoPlayers {
            let score = String(format: "%05d", game.state.players[player].points)
            for (offset, character) in score.enumerated() {
                retroSprite(media.sprites["digit-\(character)"], x: x + offset * 4, y: 4, context: &context)
            }
        }
        var field = context
        field.clip(to: Path(CGRect(x: 0, y: fieldTop, width: width, height: fieldHeight)))
        field.translateBy(x: 0, y: CGFloat(fieldTop)); field.scaleBy(x: 1, y: 2)
        for placement in placements(game: game) {
            var sprite = field
            sprite.translateBy(x: CGFloat(placement.x), y: CGFloat(placement.y))
            sprite.scaleBy(x: CGFloat(placement.horizontalScale), y: 1)
            let image = placement.reflected ? media.reflectedShips[placement.name] : media.sprites[placement.name]
            retroSprite(image, x: 0, y: 0, context: &sprite)
        }
        // Player missiles and the saucer shot are source TIA hardware pixels,
        // not missing bitmap sprites. Width/crop is explicitly provisional.
        for shot in game.state.projectiles where shot.active {
            field.fill(Path(CGRect(x: Int(game.resources.horizontalPixel(shot.horizontal)), y: Int(shot.y), width: 2, height: 1)), with: .color(.white))
        }
    }
}

struct Asteroids2600GameView: View {
    let root: URL
    let onExit: () -> Void
    @StateObject private var session = Asteroids2600Session()
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("ASTEROIDS · ATARI 2600").font(.headline)
                Spacer()
                Text("Development reconstruction").foregroundStyle(.secondary)
                Button("Library", action: onExit)
            }
            if session.presentation == nil {
                RetroLoadingPanel(message: session.message, loading: session.loading) { session.load(root: root) }
            } else if session.setup {
                VStack(spacing: 20) {
                    Text("ASTEROIDS").font(.largeTitle.monospaced())
                    Text("Break apart the asteroids, survive, and clear each field.")
                    Picker("Original game variation", selection: $session.selectedVariation) {
                        ForEach(Asteroids2600Session.variationValues, id: \.self) { value in
                            Text("Game \(Asteroids2600Session.variationNumber(value)) · \(value & 0x20 == 0 ? "1 player" : "2 players")").tag(value)
                        }
                    }.frame(maxWidth: 420)
                    Text(Asteroids2600Session.variationDescription(session.selectedVariation)).font(.callout).foregroundStyle(.secondary)
                    Toggle("Player 1 difficulty switch: include saucers", isOn: $session.playerOneSaucers).frame(maxWidth: 420)
                    if session.selectedVariation & 0x20 != 0 { Toggle("Player 2 difficulty switch: include saucers", isOn: $session.playerTwoSaucers).frame(maxWidth: 420) }
                    controls
                    Button("Start game") { session.start() }.buttonStyle(.borderedProminent)
                    Button("Resume saved game") { session.resumeSave() }.disabled(!session.hasSave)
                    limits
                    Text(session.message).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let game = session.simulation, let media = session.presentation {
                HStack(alignment: .top, spacing: 24) {
                    RetroPixelCanvas(width: Double(Asteroids2600Screen.width), height: Double(Asteroids2600Screen.height)) {
                        Asteroids2600Screen.draw(game: game, media: media, context: &$0)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        Text("PLAYER \(game.state.currentPlayer + 1)").font(.title2.monospacedDigit())
                        Text("SCORE \(game.player.points)\nSHIPS \(game.player.lives)\nGAME \(game.variationNumber)").monospacedDigit()
                        if game.twoPlayers { Text("P1 \(game.state.players[0].points) · P2 \(game.state.players[1].points)").monospacedDigit() }
                        Text(session.paused ? "PAUSED" : game.state.ended ? "GAME OVER" : Asteroids2600Session.variationDescription(game.state.variation)).font(.callout)
                        controls
                        Button(session.paused ? "Continue" : "Pause") { session.togglePause() }
                        Button("Save game") { session.save() }
                        Button("New game") { session.newGame() }
                        Text(session.message).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        limits
                    }.frame(width: 265)
                }
            }
        }.padding(24).background(Color(red: 0.063, green: 0.075, blue: 0.094))
            .background(RetroKeys(handler: session.key).frame(width: 0, height: 0))
            .background(RetroWindow(attached: session.attach).frame(width: 0, height: 0))
            .onAppear { session.load(root: root) }.onDisappear { session.stop() }
    }
    private var controls: some View {
        Text("← / → or A / D turn\n↑ / W thrust · ↓ / S special\nSpace fires · Escape pauses\n\nController: left stick / D-pad\nA thrust · X fire · Y special\nB / Menu pause").font(.callout).foregroundStyle(.secondary)
    }
    private var limits: some View {
        Text("Original monochrome masks. Development clock: 60 frames / second. TIA layout, RGB, audio and original cadence remain unqualified. Original comparison, physical input and M1 acceptance pending.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: 540)
    }
}
