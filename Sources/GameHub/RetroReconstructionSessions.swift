import AppKit
import Combine
import Foundation

@MainActor
final class ApplePanicSession: ObservableObject {
    @Published var simulation: ApplePanicSimulation?
    @Published var presentation: ApplePanicPresentation?
    @Published var setup = true
    @Published var paused = false
    @Published var loading = false
    @Published var message = ""
    let driver = RetroSessionDriver()
    private var loadTask: Task<Void, Never>?
    private var accumulator = 0.0
    static let saveID = "apple-panic-apple-ii"
    static func input(for key: UInt16) -> ApplePanicInput? {
        switch key { case 40, 124: return .right; case 38, 123: return .left; case 34, 126: return .up
        case 46, 125: return .down; case 0: return .dig; case 1: return .fill; default: return nil }
    }
    var hasSave: Bool {
        guard let presentation, let snapshot = RetroSaveStore.load(ApplePanicSnapshot.self, id: Self.saveID) else { return false }
        return (try? ApplePanicSimulation(resources: presentation.resources, snapshot: snapshot)) != nil
    }
    func load(root: URL) {
        loadTask?.cancel(); loading = true; message = ""
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try ApplePanicPresentation.load(root: root) } }.value
            guard !Task.isCancelled, let self else { return }
            self.loading = false
            switch result {
            case let .success(media): self.presentation = media; self.simulation = try? ApplePanicSimulation(resources: media.resources)
            case let .failure(error): self.message = error.localizedDescription + " Prepare Apple Panic media with Tools/decode_apple_panic.py."
            }
        }
    }
    func attach(_ window: NSWindow?) { driver.attach(window) { [weak self] now in self?.frame(now: now) } }
    func start() {
        guard let presentation else { return }
        let high = simulation?.state.highScore ?? 0
        simulation = try? ApplePanicSimulation(resources: presentation.resources)
        if var snapshot = simulation?.snapshot { snapshot.state.highScore = high; simulation = try? ApplePanicSimulation(resources: presentation.resources, snapshot: snapshot) }
        setup = false; paused = false; message = ""; accumulator = 0; driver.block(PGAControllerInput.current().sample)
    }
    func resumeSave() {
        guard let presentation, let snapshot = RetroSaveStore.load(ApplePanicSnapshot.self, id: Self.saveID),
              let restored = try? ApplePanicSimulation(resources: presentation.resources, snapshot: snapshot) else { message = "Saved game is unavailable or incompatible."; return }
        simulation = restored; setup = false; paused = true; accumulator = 0; driver.block(PGAControllerInput.current().sample); message = "Saved game restored."
    }
    func togglePause() { guard !setup else { return }; paused.toggle(); accumulator = 0; driver.block(PGAControllerInput.current().sample) }
    func save() { guard !setup, let snapshot = simulation?.snapshot else { return }; message = RetroSaveStore.save(snapshot, id: Self.saveID) ? "Game saved." : "Could not save game." }
    func stop() { loadTask?.cancel(); loadTask = nil; driver.stop(); accumulator = 0; save() }
    func newGame() { save(); setup = true; paused = false; accumulator = 0; driver.block(PGAControllerInput.current().sample) }
    func key(_ code: UInt16, down: Bool) -> Bool {
        if code == 53 { if down { togglePause() }; return true }
        if code == 49 { if down && setup { start() }; return true }
        guard Self.input(for: code) != nil else { return false }
        guard !setup, !paused else { return true }
        driver.key(code, down: down, queue: true); return true
    }
    func modifiedKey(_ code: UInt16, down: Bool, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.contains(.control), code == 15 else { return false }
        if down { start() }; return true
    }
    func frame(now: Double, focused: Bool? = nil, sample: NativeGamepadSample? = nil, identity: String? = nil) {
        let controller = sample.map { (identity: identity ?? "test", name: Optional<String>.none, sample: $0) } ?? PGAControllerInput.current()
        let active = focused ?? driver.focused
        let input = driver.frame(now: now, focused: active, enabled: !paused, sample: controller.sample, identity: controller.identity)
        if active && (input.pressed.contains("Menu") || input.pressed.contains("B")) { togglePause() }
        if active && setup && input.pressed.contains("A") { start(); return }
        guard active, !setup, !paused, simulation?.state.phase == .playing else { accumulator = 0; return }
        accumulator += input.delta
        while accumulator >= 1.0 / 60 {
            let queued = driver.takeKey().flatMap(Self.input)
            let held = [UInt16(0), 1, 34, 46, 38, 40, 126, 125, 123, 124].first(where: driver.keys.contains).flatMap(Self.input)
            let command: ApplePanicInput = queued ?? held ?? (input.held.contains("X") ? .dig : input.held.contains("Y") ? .fill :
                input.held.contains("Right") || input.axes[0] > 0.35 ? .right : input.held.contains("Left") || input.axes[0] < -0.35 ? .left :
                input.held.contains("Up") || input.axes[1] > 0.35 ? .up : input.held.contains("Down") || input.axes[1] < -0.35 ? .down : .none)
            simulation?.tick(input: command); accumulator -= 1.0 / 60
        }
    }
}

@MainActor
final class CrossfireSession: ObservableObject {
    @Published var simulation = CrossfireSimulation()
    @Published var presentation: CrossfirePresentation?
    @Published var setup = true
    @Published var paused = false
    @Published var loading = false
    @Published var message = ""
    let driver = RetroSessionDriver()
    private var loadTask: Task<Void, Never>?
    private var controllerMove: CrossfireDirection?
    private var controllerFire: CrossfireDirection?
    private var commands: [String] = []
    static let saveID = "crossfire-apple-ii"
    static func originalKey(for code: UInt16) -> String? {
        switch code { case 34, 126: return "I"; case 38, 123: return "J"; case 40, 125: return "K"; case 37, 124: return "L"
        case 14: return "E"; case 1: return "S"; case 2: return "D"; case 3: return "F"; case 49: return " "; default: return nil }
    }
    var hasSave: Bool {
        guard let snapshot = RetroSaveStore.load(CrossfireSnapshot.self, id: Self.saveID) else { return false }
        return (try? CrossfireSimulation(snapshot: snapshot)) != nil
    }
    func load(root: URL) {
        loadTask?.cancel(); loading = true; message = ""
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try CrossfirePresentation.load(root: root) } }.value
            guard !Task.isCancelled, let self else { return }
            self.loading = false
            switch result {
            case let .success(media): self.presentation = media
            case let .failure(error): self.message = error.localizedDescription + " Prepare Crossfire media with Tools/decode_crossfire.py."
            }
        }
    }
    func attach(_ window: NSWindow?) { driver.attach(window) { [weak self] now in self?.frame(now: now) } }
    func resetInput() {
        commands.removeAll(); driver.block(PGAControllerInput.current().sample)
        if controllerFire != nil || controllerMove != nil { simulation.move(nil) }
        controllerMove = nil; controllerFire = nil
    }
    func start() { guard presentation != nil else { return }; simulation = CrossfireSimulation(highScore: simulation.highScore); setup = false; paused = false; message = ""; resetInput() }
    func resumeSave() {
        guard let snapshot = RetroSaveStore.load(CrossfireSnapshot.self, id: Self.saveID), let restored = try? CrossfireSimulation(snapshot: snapshot) else { message = "Saved game is unavailable or incompatible."; return }
        resetInput(); simulation = restored; setup = false; paused = true; message = "Saved game restored."
    }
    func togglePause() { guard !setup else { return }; paused.toggle(); resetInput() }
    func save() { guard !setup else { return }; message = RetroSaveStore.save(simulation.snapshot, id: Self.saveID) ? "Game saved." : "Could not save game." }
    func stop() { loadTask?.cancel(); loadTask = nil; driver.stop(); resetInput(); save() }
    func newGame() { save(); setup = true; paused = false; resetInput() }
    func key(_ code: UInt16, down: Bool) -> Bool {
        if code == 53 { if down { togglePause() }; return true }
        guard Self.originalKey(for: code) != nil else { return false }
        if setup { if code == 49 && down { start() }; return true }
        if !paused { driver.key(code, down: down, queue: true) }; return true
    }
    func modifiedKey(_ code: UInt16, down: Bool, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.contains(.control), code == 1 else { return false }
        if down && !setup && !paused { enqueue("\u{13}") }; return true
    }
    private func enqueue(_ command: String) { if commands.count < 8 { commands.append(command) } }
    static func direction(x: Float, y: Float, held: Set<String> = []) -> CrossfireDirection? {
        if held.contains("Up") { return .up }; if held.contains("Down") { return .down }
        if held.contains("Left") { return .left }; if held.contains("Right") { return .right }
        guard max(abs(x), abs(y)) > 0.35 else { return nil }
        return abs(x) >= abs(y) ? (x > 0 ? .right : .left) : (y > 0 ? .up : .down)
    }
    func frame(now: Double, focused: Bool? = nil, sample: NativeGamepadSample? = nil, identity: String? = nil) {
        let controller = sample.map { (identity: identity ?? "test", name: Optional<String>.none, sample: $0) } ?? PGAControllerInput.current()
        let active = focused ?? driver.focused
        let input = driver.frame(now: now, focused: active, enabled: !paused, sample: controller.sample, identity: controller.identity)
        if active && (input.pressed.contains("Menu") || input.pressed.contains("B")) { togglePause() }
        if active && setup && input.pressed.contains("A") { start(); return }
        guard active, !setup, !paused, !simulation.ended else {
            commands.removeAll()
            if !active && (controllerFire != nil || controllerMove != nil) { simulation.move(nil); controllerMove = nil; controllerFire = nil }
            return
        }
        while let key = driver.takeKey() { if let command = Self.originalKey(for: key) { enqueue(command) } }
        let movement = Self.direction(x: input.axes[0], y: input.axes[1], held: input.held)
        let fire = Self.direction(x: input.axes[2], y: input.axes[3]) ?? (input.held.contains("X") ? .left : input.held.contains("Y") ? .up : input.held.contains("A") ? .down : input.held.contains("RB") ? .right : nil)
        if movement != controllerMove { enqueue(movement.map { String(UnicodeScalar(Int($0.movementKey & 127))!) } ?? " "); controllerMove = movement }
        if fire != controllerFire {
            enqueue(fire.map { String(UnicodeScalar(Int($0.shootingKey & 127))!) } ?? movement.map { String(UnicodeScalar(Int($0.movementKey & 127))!) } ?? " ")
            controllerFire = fire
        }
        // Successful source shots clear the latch to $FF. Native held fire
        // rearms only after the source cooldown; focus/pause blocks the held
        // device until release. A brief keyboard tap remains a single shot.
        if commands.isEmpty, simulation.state.pendingKey == nil, simulation.state.lastKey == 0xFF, simulation.state.fireDelay == 0 {
            let keyboardFire = [UInt16(14), 1, 2, 3].first(where: driver.keys.contains).flatMap(Self.originalKey)
            if let command = keyboardFire ?? fire.map({ String(UnicodeScalar(Int($0.shootingKey & 127))!) }) { enqueue(command) }
        }
        // The original latch consumes one command every32 loops. Preserve a
        // short tap until consumed; never replace an already pending key.
        if simulation.state.pendingKey == nil && !commands.isEmpty { simulation.press(commands.removeFirst()) }
        simulation.advance(seconds: input.delta)
    }
}

struct NightDriverSessionSave: Codable {
    var version = 1
    var game: NightDriverSnapshot
    var paddleMode: Bool
    var controlFraction: Double
    var interruptFraction: Double
    var crashFraction: Double
    func validate() throws {
        guard version == 1, controlFraction.isFinite, (0..<1).contains(controlFraction), interruptFraction.isFinite,
              (0..<1).contains(interruptFraction), crashFraction.isFinite, (0..<0.2).contains(crashFraction) else { throw NightDriverRestoreError.invalidState }
        _ = try NightDriverSimulation(snapshot: game)
    }
}

@MainActor
final class NightDriverSession: ObservableObject {
    @Published var simulation = NightDriverSimulation()
    @Published var presentation: NightDriverPresentation?
    @Published var setup = true
    @Published var paused = false
    @Published var paddleMode = false
    @Published var loading = false
    @Published var message = ""
    let driver = RetroSessionDriver()
    private var loadTask: Task<Void, Never>?
    private(set) var controlFraction = 0.0
    private(set) var interruptFraction = 0.0
    private(set) var crashFraction = 0.0
    private var pointerPaddle = 128
    static let saveID = "night-driver-c64"
    // Explicit development pacing; these are not qualified original clocks.
    static let developmentControlRate = 120.0
    static let developmentInterruptRate = 50.0
    static let developmentCrashStageSeconds = 0.2
    var snapshot: NightDriverSessionSave { NightDriverSessionSave(game: simulation.snapshot, paddleMode: paddleMode, controlFraction: controlFraction, interruptFraction: interruptFraction, crashFraction: crashFraction) }
    var hasSave: Bool { guard let save = RetroSaveStore.load(NightDriverSessionSave.self, id: Self.saveID) else { return false }; return (try? save.validate()) != nil }
    func load(root: URL) {
        loadTask?.cancel(); loading = true; message = ""
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try NightDriverPresentation.load(root: root) } }.value
            guard !Task.isCancelled, let self else { return }
            self.loading = false
            switch result {
            case let .success(media): self.presentation = media
            case let .failure(error): self.message = error.localizedDescription + " Prepare Night Driver media with Tools/decode_night_driver.py."
            }
        }
    }
    func attach(_ window: NSWindow?) { driver.attach(window) { [weak self] now in self?.frame(now: now) } }
    func start(paddle: Bool? = nil) {
        guard presentation != nil else { return }; if let paddle { paddleMode = paddle }
        simulation.start(); setup = false; paused = false; message = ""; resetInput(); controlFraction = 0; interruptFraction = 0; crashFraction = 0
    }
    func resumeSave() {
        guard let save = RetroSaveStore.load(NightDriverSessionSave.self, id: Self.saveID), (try? save.validate()) != nil,
              let restored = try? NightDriverSimulation(snapshot: save.game) else { message = "Saved drive is unavailable or incompatible."; return }
        simulation = restored; paddleMode = save.paddleMode; controlFraction = save.controlFraction; interruptFraction = save.interruptFraction; crashFraction = save.crashFraction
        setup = false; paused = true; message = "Saved drive restored."; resetInput()
    }
    func resetInput() { driver.block(PGAControllerInput.current().sample); pointerPaddle = 128 }
    func togglePause() { guard !setup else { return }; paused.toggle(); resetInput() }
    func save() { guard !setup else { return }; message = RetroSaveStore.save(snapshot, id: Self.saveID) ? "Drive saved." : "Could not save drive." }
    func stop() { loadTask?.cancel(); loadTask = nil; driver.stop(); save() }
    func newGame() { save(); setup = true; paused = false; resetInput() }
    static func paddle(for rightwardInput: Double) -> Int {
        guard rightwardInput.isFinite else { return 128 }
        return Int((127.5 * (1 - min(1, max(-1, rightwardInput)))).rounded())
    }
    func pointer(_ fraction: Double) { guard paddleMode, !setup, !paused, driver.focused, fraction.isFinite else { return }; pointerPaddle = Self.paddle(for: fraction * 2 - 1) }
    func key(_ code: UInt16, down: Bool) -> Bool {
        if code == 53 { if down { togglePause() }; return true }
        if code == 122 || code == 99 || code == 49 {
            if down && setup { start(paddle: code == 99) }; return true
        }
        guard [UInt16(0), 37, 41, 123, 124, 126].contains(code) else { return false }
        if !setup && !paused { driver.key(code, down: down, queue: true) }; return true
    }
    func frame(now: Double, focused: Bool? = nil, sample: NativeGamepadSample? = nil, identity: String? = nil) {
        let controller = sample.map { (identity: identity ?? "test", name: Optional<String>.none, sample: $0) } ?? PGAControllerInput.current()
        let active = focused ?? driver.focused
        let input = driver.frame(now: now, focused: active, enabled: !paused, sample: controller.sample, identity: controller.identity)
        if active && (input.pressed.contains("Menu") || input.pressed.contains("B")) { togglePause() }
        if active && setup && input.pressed.contains("A") { start(); return }
        if !active { pointerPaddle = 128 }
        guard active, !setup, !paused, simulation.state.phase != .ended else { return }
        guard input.delta > 0 else { return }
        // A tap must survive display callbacks before its next source control
        // update. Steering is read at the independent interrupt schedule.
        let controlDue = controlFraction + input.delta * Self.developmentControlRate >= 1 - 1e-9
        let interruptDue = interruptFraction + input.delta * Self.developmentInterruptRate >= 1 - 1e-9
        let pending = driver.pendingKeys.first
        let acceleratorTap = pending == 0 || pending == 126
        let tap = (acceleratorTap ? controlDue : interruptDue) ? driver.takeKey() : nil
        let accelerate = driver.keys.contains(0) || driver.keys.contains(126) || tap == 0 || tap == 126 || input.held.contains("A")
        let left = driver.keys.contains(37) || driver.keys.contains(123) || tap == 37 || tap == 123 || input.held.contains("Left") || input.axes[0] < -0.35
        let right = driver.keys.contains(41) || driver.keys.contains(124) || tap == 41 || tap == 124 || input.held.contains("Right") || input.axes[0] > 0.35
        let paddle = paddleMode ? (abs(input.axes[0]) > 0.2 ? Self.paddle(for: Double(input.axes[0])) : pointerPaddle) : nil
        let command = NightDriverInput(accelerate: accelerate, left: left, right: right, paddle: paddle)
        // Merge independent fixed schedules in timestamp order. Neither rate
        // follows display refresh or the development machine's CPU throughput.
        let controlPeriod = 1 / Self.developmentControlRate, interruptPeriod = 1 / Self.developmentInterruptRate
        var remaining = input.delta
        while remaining > 0 {
            let toControl = (1 - controlFraction) * controlPeriod, toInterrupt = (1 - interruptFraction) * interruptPeriod
            let step = min(remaining, min(toControl, toInterrupt))
            controlFraction += step / controlPeriod; interruptFraction += step / interruptPeriod; remaining -= step
            if simulation.state.phase == .crashed {
                crashFraction += step
                if crashFraction >= Self.developmentCrashStageSeconds { simulation.advanceCrashStage(); crashFraction -= Self.developmentCrashStageSeconds }
            } else { crashFraction = 0 }
            if interruptFraction >= 1 - 1e-9 { simulation.timerInterrupt(command); interruptFraction = 0 }
            if controlFraction >= 1 - 1e-9 { simulation.controlStep(command); controlFraction = 0 }
        }
        _ = simulation.takeEvents()
    }
}
