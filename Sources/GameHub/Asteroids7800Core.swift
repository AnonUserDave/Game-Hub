import Foundation
import CryptoKit

/// The selected 7800 edition, reconstructed as game rules rather than a console/CPU.
/// Data provenance, remaining source ambiguities and hardware gates: ASTEROIDS-7800.md.
struct Asteroids7800Resources: Codable, Sendable {
    static let sourceIdentity = "ec6ef6179644041a9fb77fc6b7c917387219fc388dd5a0fbf8236677f279402e"
    static let contentIdentity = "12917c9cac4f193f1a2dab07a8a2955b44ada245aba4ac648392d319ec87798d"
    static let codeIdentity = "a1e293ed0e1af9ea6a7df257440a50e40a4ae9088d6bcf4800a5a6f51780183d"
    struct Frame: Codable, Sendable { var width: Int; var height: Int; var pixels: [UInt8] }
    var schema: Int
    var sourceSHA256: String
    var codeSHA256: String
    var tables: [String: [UInt8]]
    var frames: [String: Frame]
    var graphicsQualification: String
    var rngQualification: String
    enum Invalid: Error { case identity, bound, table(String), frame }
    static let sizes = ["seed":55, "menuModes":6, "demoControls":8, "shipStartX":2,
        "collisionScan":9, "collisionX":8, "collisionY":8, "collisionDiagonal":8,
        "shipOutlineX1":16, "shipOutlineY1":16, "shipOutlineX2":16, "shipOutlineY2":16,
        "spinStyles":24, "spinMasks":24, "spinRanges":12, "explosionStarts":8,
        "explosionEnds":8, "initialImages":3, "centerX":7, "centerY":7,
        "speedCaps":4, "aimMasks":5, "ufoVelocityXHigh":32, "ufoVelocityXLow":32,
        "ufoVelocityYHigh":32, "ufoVelocityYLow":32, "waveCaps":4, "waveTimers":4,
        "safeRadius":2, "explosionSteps":7, "paletteRegisters":32, "objectPalettes":33,
        "menuImages":29, "menuPalettes":29, "menuX":29, "menuY":29,
        "scoreBCDLow":8, "scoreBCDHigh":8, "shotOffsetX":16, "shotOffsetY":16,
        "thrustLow":32, "thrustHigh":32, "speedLimits":32, "displayZones":51]
    func validate() throws {
        guard schema == 1, sourceSHA256 == Self.sourceIdentity, codeSHA256 == Self.codeIdentity
        else { throw Invalid.identity }
        guard tables.count == Self.sizes.count else { throw Invalid.bound }
        for (name, size) in Self.sizes {
            guard tables[name]?.count == size else { throw Invalid.table(name) }
        }
        guard frames.count == 813 else { throw Invalid.bound }
        var pixels = 0
        for frame in frames.values {
            guard (1...124).contains(frame.width), [8,16].contains(frame.height),
                  frame.pixels.count == frame.width * frame.height,
                  frame.pixels.allSatisfy({$0 <= 3}) else { throw Invalid.frame }
            pixels += frame.pixels.count
        }
        guard pixels < 150_000 else { throw Invalid.bound }
        var canonical = Data()
        func word(_ value: Int) { canonical.append(UInt8(value & 255)); canonical.append(UInt8(value >> 8)) }
        for name in tables.keys.sorted() {
            canonical.append(contentsOf: name.utf8); canonical.append(0)
            word(tables[name]!.count); canonical.append(contentsOf: tables[name]!)
        }
        for name in frames.keys.sorted() {
            let frame = frames[name]!
            canonical.append(contentsOf: name.utf8); canonical.append(0)
            word(frame.width); word(frame.height); canonical.append(contentsOf: frame.pixels)
        }
        guard SHA256.hash(data: canonical).map({String(format: "%02x", $0)}).joined() == Self.contentIdentity
        else { throw Invalid.identity }
    }
    static func load(url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 512 * 1024 else { throw Invalid.bound }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 512 * 1024 else { throw Invalid.bound }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
    fileprivate func table(_ name: String, _ index: Int) -> UInt8 { tables[name]![index] }
}

/// A source startup dependency, explicitly supplied by the caller. The first 55 bytes
/// are replaced by the verified ROM seed; bytes 55...62 retain their actual prior RAM.
/// A synthetic test page is valid for tests, but is never evidence of original startup.
struct Asteroids7800Startup: Codable, Sendable {
    var existingRandomPage: [UInt8]
    var timerByte: UInt8
    var provenance: String
}

enum Asteroids7800Mode: Int, Codable, CaseIterable, Sendable {
    case single = 255, alternating = 0, team = 1, competition = 2
    var simultaneous: Bool { self == .team || self == .competition }
}
enum Asteroids7800Screen: Int, Codable, Sendable {
    case title = 1, selection = 2, attract = 3, highScoreService = 4, playing = 5, paused = 6
}
struct Asteroids7800Input: Equatable, Codable, Sendable {
    var left = false
    var right = false
    var thrust = false
    var hyperspace = false
    var fire = false
    var secondButton = false
}
struct Asteroids7800Console: Sendable {
    var reset = false
    var select = false
    var pause = false
}
struct Asteroids7800Object: Equatable, Codable, Sendable {
    /// Source bit 7 selects an explosion/inactive object; $FF means free.
    var code: UInt8 = 255
    var x: UInt16 = 0
    var y: UInt16 = 0
    var velocityX: UInt16 = 0
    var velocityY: UInt16 = 0
    var centerX: UInt8 = 0
    var centerY: UInt8 = 0
    var image: UInt8 = 0
    var palette: UInt8 = 0
    var lifetime: UInt8 = 0
    var active: Bool { code < 128 }
    var kind: Int { Int(code & 15) }
}
struct Asteroids7800Player: Equatable, Codable, Sendable {
    /// $00 live, $01 entry/respawn, $02 hyperspace, $03 death/end, $04 winner, $FF absent.
    var phase: UInt8 = 1
    var timer: UInt8 = 122
    var heading: UInt8 = 0
    var lives: UInt8 = 3
    var wave: UInt8 = 255
    var asteroidCount: UInt8 = 0
    var countLimit: UInt8 = 0
    var speed: UInt8 = 32
    var xDragFraction: UInt8 = 0
    var yDragFraction: UInt8 = 0
    var fireLatch = true
    var score = 0
}
struct Asteroids7800RandomState: Equatable, Codable, Sendable {
    var page: [UInt8]
    var first: UInt8
    var second: UInt8
    fileprivate mutating func next() -> (byte: UInt8, carry: Bool) {
        let sum = Int(page[Int(first)]) + Int(page[Int(second)])
        let value = UInt8(truncatingIfNeeded: sum)
        page[Int(first)] = value
        first = first &- 1; if first & 128 != 0 { first = 54 }
        second = second &- 1; if second & 128 != 0 { second = 54 }
        return (value, sum > 255)
    }
}
struct Asteroids7800Snapshot: Equatable, Codable, Sendable {
    var schema = 1
    var sourceSHA256 = Asteroids7800Resources.sourceIdentity
    var screen: Asteroids7800Screen = .title
    var pausedScreen: Asteroids7800Screen = .playing
    var mode: Asteroids7800Mode = .single
    var difficulty: Int = 1
    var players = [Asteroids7800Player(), Asteroids7800Player()]
    var objects = Array(repeating: Asteroids7800Object(), count: 33)
    /// Alternating players keep complete private asteroid fields, as the source swaps 24 slots.
    var alternatingField = Array(repeating: Asteroids7800Object(), count: 24)
    var random: Asteroids7800RandomState
    var randomStartupProvenance: String
    var sourceFault: String? = nil
    var activePlayer = 0
    var sharedLives: UInt8 = 6
    var sharedScore = 0
    var highScore = 0
    var dliCounter: UInt8 = 0
    var mainPasses: UInt64 = 0
    var screenPasses: UInt16 = 0
    var waveDelay: UInt8 = 0
    var ufoDelay: UInt8 = 146
    var ufoInterval: UInt8 = 146
    var ufoGrace: UInt8 = 80
    var ufoShotTimer: UInt8 = 40
    var ufoAim: UInt8 = 9
    var shipBounceCooldown: UInt8 = 255
    var spawnSpeed: UInt8 = 32
    var menuRepeat: UInt8 = 16
    var winFlag: UInt8 = 0
    var winnerBrightness: UInt8 = 13
    var opponentWasShot = false
    var dragStopped = false
    var previousSelect = false
    var previousReset = false
    var previousPause = false
    var events: [Asteroids7800Event] = []
}
enum Asteroids7800Event: Equatable, Codable, Sendable {
    case sound(Int)
    case wave(player: Int, number: Int)
    case destroyed(slot: Int, kind: Int)
    case gameEnded
    case firmwareHighScoreService
}

/// Each `advanceMainPass` is the ordered $F7F7 gameplay pass. `displayInterrupt`
/// is separate because $D063 waits for two DLIs. No processor-speed-dependent updates.
struct Asteroids7800Simulation: Sendable {
    let resources: Asteroids7800Resources
    private(set) var state: Asteroids7800Snapshot
    enum Invalid: Error { case startup, snapshot }
    var snapshot: Asteroids7800Snapshot { state }
    var objects: [Asteroids7800Object] { state.objects }
    var players: [Asteroids7800Player] { state.players }
    var ended: Bool { state.screen != .playing && state.screen != .paused }
    init(resources: Asteroids7800Resources, startup: Asteroids7800Startup) throws {
        try resources.validate()
        guard startup.existingRandomPage.count == 256, !startup.provenance.isEmpty,
              startup.provenance.utf8.count <= 1024 else { throw Invalid.startup }
        self.resources = resources
        var page = startup.existingRandomPage
        page.replaceSubrange(0..<55, with: resources.tables["seed"]!)
        let first = startup.timerByte & 31
        state = .init(random: .init(page: page, first: first, second: first &+ 31),
                      randomStartupProvenance: startup.provenance)
        setObjectPalettes()
        for _ in 0..<24 { _ = state.random.next() }
    }
    init(resources: Asteroids7800Resources, snapshot: Asteroids7800Snapshot) throws {
        try resources.validate()
        guard snapshot.schema == 1, snapshot.sourceSHA256 == Asteroids7800Resources.sourceIdentity,
              snapshot.players.count == 2, snapshot.objects.count == 33,
              snapshot.alternatingField.count == 24, snapshot.random.page.count == 256,
              snapshot.random.first <= 54, snapshot.random.second <= 62,
              (0...3).contains(snapshot.difficulty), (0...1).contains(snapshot.activePlayer),
              snapshot.highScore >= 0, snapshot.highScore < 100_000_000,
              snapshot.sharedScore >= 0, snapshot.sharedScore < 100_000_000,
              snapshot.players.allSatisfy({ $0.score >= 0 && $0.score < 100_000_000 &&
                  [0,1,2,3,4,255].contains(Int($0.phase)) && $0.asteroidCount <= 24 }),
              snapshot.objects.allSatisfy({ $0.code == 255 || $0.kind <= 6 }),
              snapshot.alternatingField.allSatisfy({ $0.code == 255 || $0.kind <= 2 }),
              (3...9).contains(snapshot.ufoAim), snapshot.events.count <= 128,
              (snapshot.sourceFault?.utf8.count ?? 0) <= 256, !snapshot.randomStartupProvenance.isEmpty,
              snapshot.randomStartupProvenance.utf8.count <= 1024
        else { throw Invalid.snapshot }
        self.resources = resources; state = snapshot
    }
    mutating func configure(mode: Asteroids7800Mode, difficulty: Int) throws {
        guard (0...3).contains(difficulty) else { throw Invalid.snapshot }
        if state.mode != mode || state.difficulty != difficulty { state.highScore = 0 }
        state.mode = mode; state.difficulty = difficulty
        state.screen = .selection; state.screenPasses = 0
    }
    mutating func start() {
        state.screen = .playing; state.screenPasses = 0; state.sourceFault = nil
        initializeRound()
    }
    mutating func takeEvents() -> [Asteroids7800Event] {
        let result = state.events; state.events.removeAll(keepingCapacity: true); return result
    }
    mutating func displayInterrupt() { state.dliCounter &+= 1 }
    mutating func advanceMainPass(inputs: [Asteroids7800Input], console: Asteroids7800Console = .init()) {
        guard inputs.count == 2, state.sourceFault == nil else { return }
        let reset = console.reset && !state.previousReset
        let select = console.select && !state.previousSelect
        let pause = console.pause && !state.previousPause
        state.previousReset = console.reset; state.previousSelect = console.select; state.previousPause = console.pause
        if pause && (state.screen == .playing || state.screen == .paused) {
            if state.screen == .paused { state.screen = state.pausedScreen }
            else { state.pausedScreen = state.screen; state.screen = .paused }
        }
        if reset { start() }
        if select { state.screen = .selection; state.screenPasses = 0; state.menuRepeat = 16 }
        guard state.screen != .paused else { return }
        state.mainPasses &+= 1; state.screenPasses &+= 1
        // $FA0B consumes an RNG byte every foreground pass, including non-game screens.
        _ = state.random.next()
        switch state.screen {
        case .title:
            if inputs[0].fire || inputs[0].secondButton { start() }
            else if state.screenPasses >= 256 { initializeRound(); state.screen = .attract; state.screenPasses = 0 }
        case .selection:
            updateSelection(inputs[0], selectHeld: console.select)
            if inputs[0].fire || inputs[0].secondButton { start() }
            else if state.screenPasses >= 1792 { state.screen = .title; state.screenPasses = 0 }
        case .attract:
            var demo = [Asteroids7800Input(), Asteroids7800Input()]
            if state.dliCounter & 12 == 0 {
                let mask = resources.table("demoControls", Int(state.random.next().byte & 7))
                let index = Int((state.dliCounter >> 1) & 1)
                demo[index] = .init(left: mask & 0x40 == 0, right: mask & 0x80 == 0,
                                    thrust: mask & 0x10 == 0, hyperspace: mask & 0x20 == 0, fire: true)
            }
            gameplay(demo)
            if inputs[0].fire || inputs[0].secondButton { start() }
            else if state.screenPasses >= 1024 { state.screen = .title; state.screenPasses = 0 }
        case .playing: gameplay(inputs)
        case .highScoreService, .paused: break
        }
    }
    /// Helper for a native scheduler: two authored DLIs, then one foreground pass.
    /// Nominal NTSC refresh/actual source cadence still require original comparison.
    mutating func tick(inputs: [Asteroids7800Input], console: Asteroids7800Console = .init()) {
        if state.screen == .paused { advanceMainPass(inputs: inputs, console: console); return }
        displayInterrupt(); displayInterrupt(); advanceMainPass(inputs: inputs, console: console)
    }
    private mutating func emit(_ event: Asteroids7800Event) {
        if state.events.count < 128 { state.events.append(event) }
    }
    private func t(_ name: String, _ index: Int) -> UInt8 { resources.table(name, index) }
    private var shipSlot: Int { 24 + state.activePlayer * 8 }
    private mutating func setObjectPalettes() {
        for i in 0..<33 { state.objects[i].palette = t("objectPalettes", i) }
    }
    private mutating func initializeRound() {
        state.players = [Asteroids7800Player(), Asteroids7800Player()]
        if state.mode == .single { state.players[1].phase = 255; state.players[0].timer = 57 }
        state.objects = Array(repeating: .init(), count: 33)
        state.alternatingField = Array(repeating: .init(), count: 24)
        setObjectPalettes(); state.activePlayer = 0; state.sharedLives = 6; state.sharedScore = 0
        state.waveDelay = 0; state.ufoGrace = 80; state.ufoInterval = 146; state.ufoDelay = 146
        state.ufoAim = 9; state.ufoShotTimer = 40; state.shipBounceCooldown = 255
        state.winFlag = 0; state.opponentWasShot = false
    }
    private mutating func updateSelection(_ input: Asteroids7800Input, selectHeld: Bool) {
        let direction = input.left || input.right || input.thrust || input.hyperspace
        guard direction || selectHeld else { state.menuRepeat = 0; return }
        state.menuRepeat &-= 1
        guard Int8(bitPattern: state.menuRepeat) < 0 else { return }
        state.menuRepeat = 16
        if !direction {
            if state.difficulty < 3 { state.difficulty += 1 }
            else {
                state.difficulty = 0
                let next: [Asteroids7800Mode:Asteroids7800Mode] = [.single:.alternating, .alternating:.competition, .competition:.team, .team:.single]
                state.mode = next[state.mode]!
            }
        } else if input.right { state.difficulty = min(3, state.difficulty + 1) }
        else if input.left { state.difficulty = max(0, state.difficulty - 1) }
        else {
            let ordered: [Asteroids7800Mode] = [.single, .alternating, .competition, .team]
            let index = ordered.firstIndex(of: state.mode)!
            if input.hyperspace { state.mode = ordered[min(3, index + 1)] }
            else { state.mode = ordered[max(0, index - 1)] }
        }
        state.screenPasses = 0
    }
    private mutating func gameplay(_ inputs: [Asteroids7800Input]) {
        let p = state.activePlayer
        state.spawnSpeed = state.players[p].speed
        if state.players[p].asteroidCount == 0 && state.objects[25].code == 255 &&
            (state.players[0].phase & state.players[1].phase) < 2 &&
            (state.mode != .alternating || state.objects[shipSlot].active) {
            state.waveDelay &-= 1
            if Int8(bitPattern: state.waveDelay) < 0 { beginWave() }
        }
        updateShipPhase(inputs[state.activePlayer]); controlShip(inputs[state.activePlayer])
        if state.mode.simultaneous {
            state.activePlayer ^= 1
            updateShipPhase(inputs[state.activePlayer]); controlShip(inputs[state.activePlayer])
            state.activePlayer ^= 1
        }
        moveObjects(); expireProjectiles(); collide(); advanceExplosions(); updateSaucer();
    }
    private mutating func beginWave() {
        let p = state.activePlayer
        let wave = Asteroids7800Wave.after(previous: state.players[p].wave,
            difficulty: Asteroids7800Wave.Difficulty(rawValue: state.difficulty)!)
        state.players[p].wave = wave.number; state.players[p].asteroidCount = wave.asteroidCount
        state.players[p].countLimit = wave.countLimit; state.waveDelay = 37
        increaseSpeed(1, player: p)
        // $FD9D's authored decorative-stars refresh consumes 24 generator calls.
        for _ in 0..<24 { _ = state.random.next() }
        state.ufoGrace = 80; state.ufoInterval = wave.saucerTimer; state.ufoDelay = wave.saucerTimer
        state.ufoAim = 9; state.ufoShotTimer = 40
        for i in 0..<24 { state.objects[i].code = 255 }
        for i in stride(from: Int(wave.asteroidCount) - 1, through: 0, by: -1) {
            state.objects[i].code = 0x32
            let style = Int(t("spinStyles", i) & 127)
            state.objects[i].image = t("spinRanges", style)
            spawnEdge(i); spawnVelocity(i)
        }
        setObjectPalettes(); emit(.wave(player: p, number: Int(wave.number)))
    }
    private mutating func increaseSpeed(_ factor: Int, player: Int) {
        // $F44F sets factors (difficulty+1)*[8,4,2,1]; $F89E caps the carried byte sum.
        let factorByte = UInt8(truncatingIfNeeded: (state.difficulty + 1) << (3 - factor))
        state.players[player].speed = min(t("speedCaps", state.difficulty), state.players[player].speed &+ factorByte)
    }
    private mutating func spawnEdge(_ i: Int) {
        if state.random.next().byte & 1 != 0 {
            state.objects[i].y = (state.objects[i].y & 255) | 0xbf00
            guard let sample = randomBelow(153) else { return }
            state.objects[i].x = (state.objects[i].x & 255) | UInt16(sample) << 8
        } else {
            state.objects[i].x = (state.objects[i].x & 255) | 0x9f00
            guard let sample = randomBelow(191) else { return }
            state.objects[i].y = (state.objects[i].y & 255) | UInt16(sample) << 8
        }
    }
    private mutating func spawnVelocity(_ i: Int) {
        // $F8F9: ROL carries the random addition's carry into the sampled magnitude.
        let speed = state.spawnSpeed
        func component(_ sample: (byte: UInt8, carry: Bool), amount: UInt8) -> UInt16 {
            let rotated = sample.byte &<< 1 | (sample.carry ? 1 : 0)
            if sample.byte & 128 != 0 {
                let low = Int(rotated) - Int(amount)
                return UInt16(low >= 0 ? 255 : 254) << 8 | UInt16(UInt8(truncatingIfNeeded: low))
            }
            let sum = Int(rotated) + Int(amount)
            return UInt16(sum & 255) | UInt16(sum > 255 ? 1 : 0) << 8
        }
        state.objects[i].velocityX = component(state.random.next(), amount: speed >> 1)
        state.objects[i].velocityY = component(state.random.next(), amount: speed)
    }
    private mutating func moveObjects() {
        for i in stride(from: 32, through: 0, by: -1) where state.objects[i].active {
            var o = state.objects[i]
            o.x &+= o.velocityX
            var highX = UInt8(o.x >> 8)
            if highX >= 159 && i != 25 { highX = o.velocityX & 0x8000 == 0 ? 0 : 159 }
            o.x = UInt16(highX) << 8 | (o.x & 255)
            o.centerX = highX &+ t("centerX", o.kind)
            o.y &+= o.velocityY
            var highY = UInt8(o.y >> 8)
            if highY >= 191 { highY = o.velocityY & 0x8000 == 0 ? 0 : 191 }
            o.y = UInt16(highY) << 8 | (o.y & 255)
            o.centerY = highY &+ t("centerY", o.kind)
            if o.kind < 3 && i < 24 {
                let pulse = ((UInt8(truncatingIfNeeded: i * 2) &+ state.dliCounter) >> 1) & t("spinMasks", i)
                if pulse == 0 {
                    let style = t("spinStyles", i)
                    let table = o.kind == 2 ? 0 : o.kind == 1 ? 4 : 8
                    let offset = Int(style & 127)
                    let low = t("spinRanges", table + offset)
                    let high = t("spinRanges", table + offset + 1)
                    let step: UInt8 = o.kind == 2 ? 2 : 1
                    if style & 128 == 0 { o.image = o.image &+ step; if Int8(bitPattern: o.image &- high) >= 0 { o.image = low } }
                    else { o.image = o.image &- step; if Int8(bitPattern: o.image &- low) < 0 { o.image = high &- step } }
                }
            }
            state.objects[i] = o
        }
    }
    private mutating func expireProjectiles() {
        for i in 26...31 where state.objects[i].active {
            state.objects[i].lifetime &+= 1
            if state.objects[i].lifetime == 0 { state.objects[i].code = 255 }
        }
    }
    private mutating func controlShip(_ input: Asteroids7800Input) {
        let p = state.activePlayer, slot = shipSlot
        guard state.players[p].phase == 0 else { return }
        let turn = Asteroids7800Rotation.turnStep(xVelocityHigh: UInt8(state.objects[slot].velocityX >> 8),
                                                 yVelocityHigh: UInt8(state.objects[slot].velocityY >> 8))
        if input.secondButton { enterHyperspace() }
        if input.right { state.players[p].heading &+= turn }
        if input.left { state.players[p].heading &-= turn }
        state.objects[slot].image = Asteroids7800Rotation.imageCode(heading: state.players[p].heading)
        if input.hyperspace { enterHyperspace(); dragShip() }
        else if input.thrust {
            emit(.sound(17)); accelerateShip()
        } else { dragShip() }
        if !input.fire { state.players[p].fireLatch = false }
        else if !state.players[p].fireLatch { fireShip() }
    }
    private mutating func enterHyperspace() {
        let p = state.activePlayer
        if state.players[p].phase == 0 { state.players[p].phase = 2; state.players[p].timer = 44 }
    }
    /// $D54F/$D5B9's byte/carry fractional damping. The negative-high increment is
    /// retained exactly; replacing it with a host floating-point drag changes the rule.
    static func damp(_ velocity: UInt16, fraction: UInt8) -> (velocity: UInt16, fraction: UInt8, stopped: Bool) {
        let low = UInt8(velocity & 255), high = UInt8(velocity >> 8)
        let doubledLow = low &<< 1
        let doubledHigh = high &<< 1 | (low >> 7)
        let lowSum = Int(low) + Int(doubledLow)
        let adjustedHigh = high & 128 != 0 ? high &+ 1 : high
        let productHigh = UInt8(truncatingIfNeeded: Int(adjustedHigh) + Int(doubledHigh) + (lowSum > 255 ? 1 : 0))
        let first = Int(fraction) - (lowSum & 255)
        let second = Int(low) - Int(productHigh) - (first < 0 ? 1 : 0)
        let third = Int(adjustedHigh) - (second < 0 ? 1 : 0)
        let result = UInt16(UInt8(truncatingIfNeeded: third)) << 8 | UInt16(UInt8(truncatingIfNeeded: second))
        let resultHigh = UInt8(result >> 8), resultLow = UInt8(result & 255)
        let stopped = (resultHigh == 0 && resultLow < 32) || (resultHigh == 255 && resultLow >= 224)
        return (result, UInt8(truncatingIfNeeded: first), stopped)
    }
    private mutating func dragShip() {
        let p = state.activePlayer, slot = shipSlot
        let oldX = state.objects[slot].velocityX, oldY = state.objects[slot].velocityY
        let x = Self.damp(oldX, fraction: state.players[p].xDragFraction)
        let y = Self.damp(oldY, fraction: state.players[p].yDragFraction)
        if oldX != 0 { state.objects[slot].velocityX = x.velocity; state.players[p].xDragFraction = x.fraction }
        if oldY != 0 { state.objects[slot].velocityY = y.velocity; state.players[p].yDragFraction = y.fraction }
        // Source leaves $F8 unchanged when X is already zero, so this needs state.
        if oldX != 0 { state.dragStopped = x.stopped }
        if oldY != 0 && y.stopped && state.dragStopped {
            state.objects[slot].velocityX = 0; state.objects[slot].velocityY = 0
        }
    }
    // $F8 is shared transient state, not a processor flag; retained for native save fidelity.
    private mutating func accelerateShip() {
        let p = state.activePlayer, slot = shipSlot, heading = Int(state.players[p].heading >> 4)
        for axis in 0...1 {
            let index = heading + axis * 16
            let velocity = axis == 0 ? state.objects[slot].velocityX : state.objects[slot].velocityY
            let sample = UInt8(truncatingIfNeeded: velocity >> 4)
            let limit = t("speedLimits", index)
            let over: Bool
            if limit & 128 != 0 { over = sample & 128 != 0 && limit >= sample }
            else { over = sample & 128 == 0 && limit <= sample }
            if over {
                let drag = Self.damp(velocity, fraction: axis == 0 ? state.players[p].xDragFraction : state.players[p].yDragFraction)
                if axis == 0 { state.objects[slot].velocityX = drag.velocity; state.players[p].xDragFraction = drag.fraction }
                else { state.objects[slot].velocityY = drag.velocity; state.players[p].yDragFraction = drag.fraction }
            } else {
                let low = t("thrustLow", index) &<< 3
                let delta = UInt16(t("thrustHigh", index)) << 8 | UInt16(low)
                if axis == 0 { state.objects[slot].velocityX &+= delta }
                else { state.objects[slot].velocityY &+= delta }
            }
        }
    }
    private mutating func fireShip() {
        let p = state.activePlayer, ship = state.objects[shipSlot]
        let slots = state.mode.simultaneous ? (p == 0 ? [28,29] : [30,31]) : [31,30,29,28]
        guard let slot = slots.first(where: { state.objects[$0].code & 128 != 0 }) else { return }
        let heading = Int(state.players[p].heading >> 4)
        var o = state.objects[slot]
        o.code = 6; o.lifetime = 236
        let x = ship.x >> 8
        let y = ship.y >> 8
        var bx = UInt8(truncatingIfNeeded: x) &+ t("shotOffsetX", heading)
        var by = UInt8(truncatingIfNeeded: y) &+ t("shotOffsetY", heading)
        if bx >= 159 { bx &-= 159 }; if by >= 191 { by &-= 191 }
        o.x = UInt16(bx) << 8 | (ship.x & 255); o.y = UInt16(by) << 8 | (ship.y & 255)
        // Source adds the heading component to the HIGH velocity byte, keeping the low byte.
        o.velocityX = UInt16(UInt8(ship.velocityX >> 8) &+ t("thrustLow", heading)) << 8 | (ship.velocityX & 255)
        o.velocityY = UInt16(UInt8(ship.velocityY >> 8) &+ t("thrustLow", heading + 16)) << 8 | (ship.velocityY & 255)
        state.objects[slot] = o; state.players[p].fireLatch = true; emit(.sound(14))
    }
    private mutating func updateShipPhase(_ input: Asteroids7800Input) {
        let p = state.activePlayer, slot = shipSlot
        if state.players[p].phase == 0 && state.winFlag != 0 {
            let winner = state.players[0].score == state.players[1].score ? -1 : (state.players[0].score > state.players[1].score ? 0 : 1)
            if winner == p {
                state.players[p].phase = 4; state.players[p].lives = 0
                state.winFlag = 255; state.winnerBrightness = 13; emit(.sound(0))
            }
        }
        guard state.players[p].phase != 0 && state.players[p].phase != 255 else { return }
        state.players[p].timer &-= 1
        let timer = state.players[p].timer
        switch state.players[p].phase {
        case 1:
            if timer == 81 { return } // Authored start-player message disappears.
            if timer == 41 {
                if state.objects[25].code < 128 { state.players[p].timer &+= 1; return }
                if state.screen != .attract {
                    if state.mode == .team {
                        guard state.sharedLives > 0 else { state.players[p].timer &+= 1; return }
                        state.sharedLives &-= 1
                    } else { state.players[p].lives &-= 1 }
                }
                state.objects[slot].velocityX = 0; state.objects[slot].velocityY = 0
                let x: UInt8 = state.mode.simultaneous ? t("shipStartX", p) : 80
                state.objects[slot].x = UInt16(x) << 8 | (state.objects[slot].x & 255)
                state.objects[slot].y = 0x5000 | (state.objects[slot].y & 255)
                state.objects[slot].image = Asteroids7800Rotation.imageCode(heading: state.players[p].heading)
                state.objects[slot].code = 0x23
            } else if timer < 41 {
                let forced = state.screen == .playing && (input.fire || input.secondButton || input.left || input.right || input.thrust || input.hyperspace)
                if !forced {
                    if timer >= 1 { return }
                    if unsafeToEnter(slot, initialCarry: false) { state.players[p].timer &+= 1; return }
                }
                state.players[p].fireLatch = true; state.players[p].phase = 0; emit(.sound(3))
            }
        case 2:
            if timer == 41 {
                state.objects[slot].code = 255
                state.objects[slot].velocityX = 0; state.objects[slot].velocityY = 0; emit(.sound(1))
            } else if timer == 1 {
                let rx = state.random.next().byte
                let ry = state.random.next().byte
                state.objects[slot].x = UInt16((rx >> 1) &+ (rx & 1) &+ 13) << 8 | (state.objects[slot].x & 255)
                state.objects[slot].y = UInt16((ry >> 1) &+ (ry & 1) &+ 16) << 8 | (state.objects[slot].y & 255)
                if unsafeToEnter(slot, initialCarry: false) { state.players[p].timer &+= 1; return }
                if state.random.next().byte < 50 {
                    state.objects[slot].code = 0xa3
                    state.objects[slot].image = t("explosionStarts", 3)
                    state.players[p].phase = 3; state.players[p].timer = 222; emit(.sound(5))
                } else { state.objects[slot].code = 0x23; state.players[p].phase = 0; emit(.sound(3)) }
            }
        case 3:
            if timer == 182 {
                let available = state.mode == .team ? state.sharedLives : state.players[p].lives
                if available > 0 {
                    if state.mode == .alternating && state.players[p ^ 1].lives > 0 { return }
                    state.players[p].phase = 1; state.players[p].timer = 44
                } else if state.mode == .single || (state.mode == .team && state.players[p ^ 1].phase != 1) {
                    state.players[p].timer = 100
                } else { state.players[p].timer = 164 }
            } else if timer == 161 {
                if state.mode == .alternating && state.players[p ^ 1].lives > 0 { swapAlternatingPlayer() }
                else {
                    state.highScore = max(state.highScore, state.players[0].score, state.players[1].score, state.sharedScore)
                    if state.mode == .competition && state.winFlag == 0 { state.winFlag = 2 }
                }
            } else if timer == 113 {
                if state.players[p ^ 1].phase != 255 {
                    state.players[p].phase = 255
                    if state.mode == .alternating { swapAlternatingPlayer() }
                }
            } else if timer == 1 { endRound() }
        case 4:
            state.winnerBrightness &+= 1
            if state.winnerBrightness == 33 { state.objects[slot].code = 255 }
            else if state.winnerBrightness == 47 { state.players[p].phase = 3; state.players[p].timer = 222 }
        default: break
        }
    }
    private mutating func endRound() {
        state.highScore = max(state.highScore, state.players[0].score, state.players[1].score, state.sharedScore)
        state.screen = .title; state.screenPasses = 0
        for i in 0..<33 { state.objects[i].code = 255 }
        emit(.gameEnded)
        // Optional $3900 high-score cartridge service is not supplied/executed.
        emit(.firmwareHighScoreService)
    }
    private mutating func swapAlternatingPlayer() {
        state.activePlayer ^= 1
        for i in 0..<24 { swap(&state.objects[i], &state.alternatingField[i]) }
        for i in 24..<32 { state.objects[i].code = 255 }
        state.waveDelay = 0; state.ufoGrace = 80; state.ufoInterval = 146; state.ufoDelay = 146
        state.players[state.activePlayer].phase = 1; state.players[state.activePlayer].timer = 153
    }
    /// $F93C constructs a wrapping, source-sized safety rectangle with carried ADC/SBC.
    private mutating func unsafeToEnter(_ slot: Int, initialCarry: Bool) -> Bool {
        // The source's Y branch uses $BF; explicitly preserve that independent bound.
        func sourceEdges(_ c: UInt8, radius: UInt8, limit: Int, carry: inout Bool) -> (UInt8, UInt8, UInt8) {
            let a = Int(c) + Int(radius) + (carry ? 1 : 0); carry = a > 255
            var upper = a & 255
            let b = upper - limit - (carry ? 0 : 1); carry = b >= 0
            var wraps = 0
            if carry { wraps += 1; upper = b & 255 }
            let d = Int(c) - Int(radius) - (carry ? 0 : 1); carry = d >= 0
            var lower = d & 255
            if !carry { wraps += 1; let e = lower + limit; lower = e & 255; carry = e > 255 }
            return (UInt8(upper), UInt8(lower), UInt8(wraps))
        }
        var carry = initialCarry
        let x = sourceEdges(UInt8(state.objects[slot].x >> 8), radius: t("safeRadius", 0), limit: 159, carry: &carry)
        let y = sourceEdges(UInt8(state.objects[slot].y >> 8), radius: t("safeRadius", 1), limit: 191, carry: &carry)
        func contains(_ value: UInt8, _ e: (UInt8, UInt8, UInt8)) -> Bool {
            (((value >= e.0 ? 1 : 0) + (value >= e.1 ? 1 : 0)) ^ Int(e.2)) & 1 != 0
        }
        return state.objects.enumerated().contains { i, o in
            i != slot && o.active && contains(UInt8(o.x >> 8), x) && contains(UInt8(o.y >> 8), y)
        }
    }
    /// Authored octagonal extents, not a circular-distance test. The width/height
    /// prechecks and toroidal seam exclusions are those of $DABA.
    func overlaps(_ a: Asteroids7800Object, _ b: Asteroids7800Object, aSlot: Int, bSlot: Int) -> Bool {
        func seam(_ difference: Int, limit: Int) -> Int {
            let result = difference - limit
            return Int((~UInt8(truncatingIfNeeded: result)) &+ 1 &+ (result >= 0 ? 1 : 0))
        }
        var dx = abs(Int(a.centerX) - Int(b.centerX))
        if dx >= 146 && aSlot != 25 && bSlot != 25 { dx = seam(dx, limit: 160) }
        guard dx < 10 else { return false }
        var dy = abs(Int(a.centerY) - Int(b.centerY))
        if dy >= 174 { dy = seam(dy, limit: 192) }
        guard dy < 14 else { return false }
        let k = a.kind, l = b.kind
        return Int(t("collisionDiagonal", k)) + Int(t("collisionDiagonal", l)) >= dx + dy &&
            Int(t("collisionX", k)) + Int(t("collisionX", l)) >= dx &&
            Int(t("collisionY", k)) + Int(t("collisionY", l)) >= dy
    }
    private func outline(_ slot: Int) -> [Asteroids7800Object] {
        let p = slot == 24 ? 0 : 1, ship = state.objects[slot], heading = Int(state.players[p].heading >> 4)
        let x = UInt8(ship.x >> 8), y = UInt8(ship.y >> 8)
        var points = [Asteroids7800Object](repeating: .init(code: 7), count: 4)
        points[0].centerX = x &+ t("shotOffsetX", heading); points[0].centerY = y &+ t("shotOffsetY", heading)
        points[1].centerX = x &+ t("shipOutlineX2", heading); points[1].centerY = y &+ t("shipOutlineY2", heading)
        points[2].centerX = x &+ t("shipOutlineX1", heading); points[2].centerY = y &+ t("shipOutlineY1", heading)
        points[3].centerX = ship.centerX; points[3].centerY = ship.centerY
        return points
    }
    private mutating func collide() {
        if state.shipBounceCooldown & 128 == 0 { state.shipBounceCooldown &-= 1 }
        for x in stride(from: 32, through: 24, by: -1) where state.objects[x].active {
            let last = Int(t("collisionScan", x - 24))
            for y in stride(from: last, through: 0, by: -1) where state.objects[y].active {
                guard state.objects[x].active else { break }
                let a = state.objects[x], b = state.objects[y]
                guard overlaps(a, b, aSlot: x, bSlot: y) else { continue }
                if x == 32 || y == 24 || x == 24 {
                    let ship = x == 32 ? 32 : 24, p = ship == 24 ? 0 : 1
                    guard state.players[p].phase == 0 else { continue }
                    let other = ship == x ? y : x
                    if other >= 28 && other <= 31 {
                        if state.mode == .team { continue }
                        if ship == 24 && other < (state.mode.simultaneous ? 30 : 32) { continue }
                    }
                    if x == 32 && y == 24 && state.mode != .competition {
                        if state.players[0].phase == 0 { bounceShips() }
                        continue
                    }
                    guard outline(ship).contains(where: { overlaps($0, state.objects[other], aSlot: ship, bSlot: other) }) else { continue }
                    if x == 32 && y == 24 {
                        guard outline(24).contains(where: { point in outline(32).contains(where: { overlaps(point, $0, aSlot: 24, bSlot: 32) }) }) else { continue }
                    }
                }
                let kindX = a.kind, kindY = b.kind
                destroy(x); destroy(y)
                award(kindX, ownerSlot: y); award(kindY, ownerSlot: x)
                if y < 24 { splitAsteroid(y) }
            }
        }
    }
    private mutating func bounceShips() {
        if state.shipBounceCooldown & 128 != 0 {
            func half(_ value: UInt16) -> UInt16 {
                UInt16(bitPattern: Int16(bitPattern: value) >> 1)
            }
            let x = state.objects[24].velocityX, y = state.objects[24].velocityY
            state.objects[24].velocityX = half(state.objects[32].velocityX)
            state.objects[24].velocityY = half(state.objects[32].velocityY)
            state.objects[32].velocityX = half(x); state.objects[32].velocityY = half(y)
        }
        state.shipBounceCooldown = 1
    }
    private mutating func destroy(_ slot: Int) {
        let kind = state.objects[slot].kind
        state.objects[slot].code |= 128
        if kind < 3 { emit(.sound(kind + 10)) }
        if kind == 3 {
            let p = slot == 32 ? 1 : 0
            state.players[p].phase = 3; state.players[p].timer = 222; emit(.sound(5))
        }
        if kind == 4 || kind == 5 {
            increaseSpeed(kind - 2, player: state.activePlayer)
            if kind == 4 && state.ufoAim >= 4 { state.ufoAim &-= 1 }
            emit(.sound(kind + 2))
        }
        state.objects[slot].image = t("explosionStarts", kind)
        emit(.destroyed(slot: slot, kind: kind))
    }
    private mutating func award(_ kind: Int, ownerSlot: Int) {
        guard state.screen == .playing, ownerSlot >= 24 else { return }
        let player: Int
        if ownerSlot == 24 { player = 0 }
        else if ownerSlot == 32 { player = 1 }
        else if ownerSlot >= 28 && ownerSlot <= 31 {
            player = state.mode.simultaneous ? (ownerSlot >= 30 ? 1 : 0) : state.activePlayer
        } else { return }
        func bcd(_ byte: UInt8) -> Int { Int(byte >> 4) * 10 + Int(byte & 15) }
        let amount = bcd(t("scoreBCDHigh", kind)) * 100 + bcd(t("scoreBCDLow", kind))
        let old = state.players[player].score
        state.players[player].score = (old + amount) % 100_000_000
        if state.mode == .team {
            let prior = state.sharedScore; state.sharedScore = (prior + amount) % 100_000_000
            if state.sharedScore / 10_000 != prior / 10_000 { state.sharedLives &+= 1; increaseSpeed(0, player: state.activePlayer); emit(.sound(4)) }
        } else if state.players[player].score / 10_000 != old / 10_000 {
            state.players[player].lives &+= 1; increaseSpeed(0, player: state.activePlayer); emit(.sound(4))
        }
    }
    private mutating func splitAsteroid(_ slot: Int) {
        let original = state.objects[slot]
        let code = original.code &- 0x91
        guard Int8(bitPattern: code) >= 0 else { return }
        state.ufoGrace = 80
        var children = state.difficulty == 0 ? 1 : 2
        if state.difficulty == 3 && state.random.first & 3 == 0 { children += 1 }
        for _ in 0..<children {
            guard let free = (0..<24).reversed().first(where: { state.objects[$0].code == 255 }) else { return }
            state.objects[free] = original; state.objects[free].code = code
            state.objects[free].palette = original.palette &+ 1
            state.objects[free].image = t("initialImages", Int(code & 15))
            spawnVelocity(free); state.players[state.activePlayer].asteroidCount &+= 1
        }
    }
    private mutating func advanceExplosions() {
        for i in stride(from: 32, through: 0, by: -1) {
            let o = state.objects[i]
            guard o.code & 128 != 0 && o.code != 255 else { continue }
            if ((UInt8(truncatingIfNeeded: i * 2) &+ state.dliCounter) >> 1) & 3 != 0 { continue }
            if o.image == t("explosionEnds", o.kind) {
                if o.kind < 3 { state.players[state.activePlayer].asteroidCount &-= 1 }
                state.objects[i].code = 255
            } else { state.objects[i].image &+= t("explosionSteps", o.kind) }
        }
    }
    private mutating func updateSaucer() {
        if !state.objects[25].active {
            guard state.objects[25].code == 255, state.difficulty != 0,
                  (state.mode.simultaneous ? state.players[0].phase & state.players[1].phase == 0 : state.players[state.activePlayer].phase == 0),
                  state.dliCounter & 2 == 0, state.players[state.activePlayer].asteroidCount > 0 else { return }
            let grace = state.ufoGrace
            if grace > 0 { state.ufoGrace &-= 1 }
            state.ufoDelay &-= 1
            guard state.ufoDelay == 0 else { return }
            state.ufoDelay = 1
            if grace != 0 && state.players[state.activePlayer].asteroidCount >= state.players[state.activePlayer].countLimit { return }
            if state.ufoInterval &- 6 >= 20 { state.ufoInterval &-= 6 }
            state.ufoDelay = state.ufoInterval; state.ufoShotTimer = 21
            let y = state.random.next().byte
            state.objects[25].y = UInt16((y >> 1) &+ (y & 1) &+ 16) << 8 | (state.objects[25].y & 255)
            let score = state.mode == .team ? state.sharedScore : state.players[state.activePlayer].score
            let small: Bool
            if score >= 20_000 { small = true }
            else if state.ufoInterval & 128 == 0 { small = state.ufoInterval >> 1 < state.random.next().byte }
            else { small = false }
            state.objects[25].code = small ? 0x14 : 0x25
            if state.random.next().byte & 1 != 0 { state.objects[25].x = 0xa300; state.objects[25].velocityX = 0xff00 }
            else { state.objects[25].x = 0xfc00; state.objects[25].velocityX = 0x0100 }
        } else if state.dliCounter >= 254 {
            if state.difficulty == 1 { state.objects[25].velocityY = 0 }
            else {
                let sample = state.random.next().byte
                if sample >= 170 { state.objects[25].velocityY = 0xff00 }
                else if sample >= 85 { state.objects[25].velocityY = 0x0100 }
                else if UInt8(state.objects[25].y >> 8) >= 10 && UInt8(state.objects[25].y >> 8) < 171 { state.objects[25].velocityY = 0 }
            }
        }
        let o = state.objects[25]
        let nextX = UInt8(o.x >> 8) &+ UInt8(o.velocityX >> 8)
        if nextX >= 163 && nextX < 253 { state.objects[25].code = 255; return }
        if let shot = [27,26].first(where: { state.objects[$0].code & 128 != 0 }) {
            state.ufoShotTimer &-= 1
            if state.ufoShotTimer == 0 {
                state.ufoShotTimer = 32
                guard let heading = o.kind == 4 ? saucerAim() : Int(state.random.next().byte & 31) else { return }
                state.objects[shot].code = 6; state.objects[shot].lifetime = 236
                var x = o.centerX, y = o.centerY
                if x >= 159 { x &-= 159 }; if y >= 191 { y &-= 191 }
                state.objects[shot].x = UInt16(x) << 8; state.objects[shot].y = UInt16(y) << 8
                state.objects[shot].velocityX = UInt16(t("ufoVelocityXHigh", heading)) << 8 | UInt16(t("ufoVelocityXLow", heading))
                state.objects[shot].velocityY = UInt16(t("ufoVelocityYHigh", heading)) << 8 | UInt16(t("ufoVelocityYLow", heading))
                emit(.sound(13))
            }
        }
        let frame = (state.dliCounter >> 2) & 3
        state.objects[25].image = o.kind == 4 ? frame &+ 233 : frame &* 2 &+ 225
    }
    private mutating func saucerAim() -> Int? {
        var player = state.activePlayer
        if state.mode.simultaneous {
            if state.players[0].phase & state.players[1].phase == 0 { player = state.random.next().byte & 128 == 0 ? 0 : 1 }
            else { player = state.players[0].phase == 0 ? 0 : 1 }
        }
        let a = state.objects[24 + player * 8], b = state.objects[25]
        let negX = a.centerX < b.centerX, negY = a.centerY < b.centerY
        var x = abs(Int(a.centerX) - Int(b.centerX))
        let y = abs(Int(a.centerY) - Int(b.centerY))
        let transformedY = (y >> 3) + (y >> 1)
        let exchanged = transformedY < x
        let major = exchanged ? x : transformedY
        if exchanged { x = transformedY }
        var threshold = major >> 2
        let quarter = x >> 2
        let limit = quarter + (quarter >> 1)
        let fiveEighths = (x >> 3) + (x >> 1)
        var heading: Int
        let sourceA: Int
        if fiveEighths >= threshold { heading = 2; sourceA = 0 }
        else { heading = 0; sourceA = x }
        if sourceA + limit >= threshold { heading += 1 }
        if exchanged { heading = 7 - heading }
        if negY { heading = 15 - heading }
        if negX { heading = 31 - heading }
        let half = Int(state.ufoAim >> 1)
        guard let random = randomBelow(state.ufoAim, mask: t("aimMasks", half)) else { return nil }
        threshold = heading + Int(random) - half
        return threshold & 31
    }
    /// A damaged snapshot may create a pathological rejection cycle. Stop with an
    /// explicit fault instead of supplying a guessed random byte or hanging the hub.
    private mutating func randomBelow(_ limit: UInt8, mask: UInt8 = 255) -> UInt8? {
        for _ in 0..<4096 {
            let value = state.random.next().byte & mask
            if value < limit { return value }
        }
        state.sourceFault = "RNG rejection exceeded its native bound; an original RAM/timer sample is required."
        return nil
    }

}
