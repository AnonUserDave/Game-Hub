import Foundation

/// First-party integer rules reconstructed from the selected Commodore/HAL
/// Night Driver V.01. No CPU, VIC or SID interpreter is used. Scheduling the
/// original foreground loop still requires a running-original timing check.
enum NightDriverPhase: String, Codable { case ready, driving, crashed, ended }

struct NightDriverInput {
    var accelerate = false
    var left = false
    var right = false
    /// The original paddle reading, 0...255. Nil selects keys/joystick rules.
    var paddle: Int?
}

struct NightDriverCell: Equatable {
    var column: Int
    var row: Int
    var character: Int
    var color: Int = 1
}

struct NightDriverState: Codable, Equatable {
    var phase: NightDriverPhase = .ready
    var speed256 = 0
    var gear = 0
    var distance = 0
    var distanceFraction = 0
    var highScore = 0
    /// The original BCD $31:$32, represented as a decimal integer. The HUD
    /// displays the hundreds; these are not established wall-clock seconds.
    var timerTicks = 0
    var extendedPlay = false
    var roadOrigin256 = 0x1414
    var bend256 = 0x8000
    var targetBend256 = 0x8100
    var bendStep = 4
    var roadCenters = Array(repeating: 20, count: 19)
    var roadPhase = 0
    var motionFraction = 0
    var randomState: UInt16 = 0xffff
    var crashStage = 0
    var interruptCount: UInt64 = 0
    var controlCount: UInt64 = 0

    var speed: Int { speed256 >> 8 }
    var timeDisplay: Int { timerTicks / 100 }
}

enum NightDriverEvent: Equatable { case roadAdvanced, crash, recovered, extendedPlay, ended }

struct NightDriverSnapshot: Codable, Equatable {
    var schemaVersion = 1
    var sourceSHA256 = NightDriverSimulation.sourceSHA256
    var state: NightDriverState
}

enum NightDriverRestoreError: Error { case incompatibleSource, invalidState }

struct NightDriverSimulation {
    static let sourceSHA256 = "2238c3c9f844d4456edc49d4af00531b34f1caeba92d0a5f6fb83c2317c89b16"
    /// CIA Timer A reload $4E20 at $E074..$E080. The native scheduler must
    /// establish the source machine clock separately; no CPU is emulated.
    static let timerPeriodSourceCycles = 20_000
    static let depthSchedules = [
        [0, 1, 2, 3, 5, 7, 9, 13], [0, 1, 2, 3, 5, 7, 10, 14],
        [0, 1, 2, 4, 6, 8, 11, 15], [0, 2, 3, 4, 7, 9, 13, 17]
    ]
    private(set) var state = NightDriverState()
    private(set) var events: [NightDriverEvent] = []

    init(highScore: Int = 0) {
        state.highScore = min(9999, max(0, highScore))
        rebuildRoad()
    }

    init(snapshot: NightDriverSnapshot) throws {
        guard snapshot.schemaVersion == 1, snapshot.sourceSHA256 == Self.sourceSHA256 else {
            throw NightDriverRestoreError.incompatibleSource
        }
        let value = snapshot.state
        guard (0...64255).contains(value.speed256), (0...3).contains(value.gear),
              (0...9999).contains(value.distance), (0...7).contains(value.distanceFraction),
              (0...9999).contains(value.highScore), (0...9999).contains(value.timerTicks),
              (0...65535).contains(value.roadOrigin256), (0...65535).contains(value.bend256),
              (0x4000...0xbfff).contains(value.targetBend256), (-1024...1023).contains(value.bendStep),
              value.roadCenters.count == 19, value.roadCenters.allSatisfy({ (0...255).contains($0) }),
              (0...3).contains(value.roadPhase), (0...255).contains(value.motionFraction),
              (0...3).contains(value.crashStage), value.phase != .ended || value.timerTicks < 100
        else { throw NightDriverRestoreError.invalidState }
        state = value
        var rebuilt = self
        rebuilt.rebuildRoad()
        guard rebuilt.state.roadCenters == value.roadCenters else { throw NightDriverRestoreError.invalidState }
    }

    var snapshot: NightDriverSnapshot { NightDriverSnapshot(state: state) }

    mutating func takeEvents() -> [NightDriverEvent] {
        let value = events
        events.removeAll(keepingCapacity: true)
        return value
    }

    mutating func start() {
        // $E0BF clears round distance but deliberately retains the RNG and high score.
        let highScore = state.highScore, random = state.randomState
        state = NightDriverState()
        state.highScore = highScore
        state.randomState = random
        state.timerTicks = 9999
        state.phase = .driving
        rebuildRoad()
        events.removeAll(keepingCapacity: true)
    }

    /// One $E120 foreground iteration. This API keeps the source's foreground
    /// acceleration cadence separate from its independent CIA road/timer cadence.
    mutating func controlStep(_ input: NightDriverInput = NightDriverInput()) {
        state.controlCount &+= 1
        guard state.phase == .driving else { return }
        // $E120 calls $E48E before testing collision and expiry. Even the final
        // foreground iteration updates the source speed's wrapped low byte.
        state.gear = Self.gear(for: state.speed)
        let low = state.speed256 & 255, high = state.speed
        if input.accelerate {
            let result = low + [255, 25, 35, 15][state.gear]
            state.speed256 = min(250, high + (result >> 8)) * 256 + (result & 255)
        } else {
            let result = low - [255, 30, 40, 45][state.gear]
            // Source $E4BF clamps only the high byte; the wrapped low byte remains.
            state.speed256 = max(0, high - (result < 0 ? 1 : 0)) * 256 + (result & 255)
        }
        if collisionAtCar {
            state.phase = .crashed
            state.crashStage = 0
            events.append(.crash)
            return
        }
        if state.timerTicks < 100 {
            if !state.extendedPlay && state.distance >= 600 {
                // $E220 sets only the high BCD byte, retaining fractional time.
                state.extendedPlay = true
                state.timerTicks = 5000 + state.timerTicks % 100
                events.append(.extendedPlay)
            } else {
                state.phase = .ended
                state.highScore = max(state.highScore, state.distance)
                events.append(.ended)
                return
            }
        }
    }

    /// One $EBB1 CIA interrupt: decrement BCD time, then add integer speed to
    /// $22 and advance the road only on the byte carry. No delta-time physics.
    mutating func timerInterrupt(_ input: NightDriverInput = NightDriverInput()) {
        state.interruptCount &+= 1
        guard state.phase == .driving || state.phase == .crashed else { return }
        if state.timerTicks >= 100 { state.timerTicks -= 1 }
        guard state.phase == .driving else { return }
        let motion = state.motionFraction + state.speed
        state.motionFraction = motion & 255
        guard motion >= 256 else { return }
        advanceBend()
        if let paddle = input.paddle {
            state.roadOrigin256 = (state.roadOrigin256 + 2 * (min(255, max(0, paddle)) - 128)) & 65535
        } else {
            // Both original input paths give right priority when both are held.
            let steering = input.right ? -200 : input.left ? 200 : 0
            state.roadOrigin256 = (state.roadOrigin256 + steering) & 65535
        }
        rebuildRoad()
        state.distanceFraction = (state.distanceFraction + 1) & 7
        if state.distanceFraction == 0 { state.distance = (state.distance + 1) % 10_000 }
        state.roadPhase = (state.roadPhase + 1) & 3
        events.append(.roadAdvanced)
    }

    /// Source crash has four authored drawing stages and a blocking sound/filter
    /// sequence. A presentation adapter controls their wall-clock duration.
    mutating func advanceCrashStage() {
        guard state.phase == .crashed else { return }
        if state.crashStage < 3 {
            state.crashStage += 1
        } else {
            state.phase = .driving
            state.speed256 = 0
            state.gear = 0
            state.roadOrigin256 = 0x1414
            state.bend256 = 0x8000
            state.targetBend256 = 0x8100
            state.bendStep = 4
            rebuildRoad()
            events.append(.recovered)
        }
    }

    var collisionAtCar: Bool { state.roadCenters[15] < 10 || state.roadCenters[15] >= 30 }

    /// Character-cell geometry from $E321/$E36B, including the two special
    /// half-height post characters. Native rendering can use decoded tile rows.
    var roadCells: [NightDriverCell] {
        let depths = Self.depthSchedules[state.roadPhase]
        var cells: [NightDriverCell] = []
        for side in [-1, 1] {
            for (index, depth) in depths.enumerated() {
                let column = (state.roadCenters[depth] + side * (depth + 1)) & 255
                guard column < 40 else { continue }
                if index == 3 || index == 4 {
                    cells.append(NightDriverCell(column: column, row: depth + 1, character: 12 + index))
                } else {
                    let height = index < 3 ? 1 : index < 6 ? 2 : index == 6 ? 3 : 4
                    for row in depth..<(depth + height) {
                        cells.append(NightDriverCell(column: column, row: row, character: 8 + index))
                    }
                }
            }
        }
        return cells
    }

    static func gear(for speed: Int) -> Int {
        speed == 0 ? 0 : speed >= 151 ? 1 : speed >= 61 ? 2 : 3
    }

    /// $EAA0, algebraically reduced from eleven rounds. The shifted-in bit is
    /// XNOR(old bit 15, old bit 1, old bit 0); it does not depend on incoming A.
    static func nextRandom(_ seed: inout UInt16) -> Int {
        for _ in 0..<11 {
            let bit = ((seed >> 15) ^ (seed >> 1) ^ seed ^ 1) & 1
            seed = (seed &<< 1) | bit
        }
        return Int(seed & 255)
    }

    private mutating func advanceBend() {
        let currentHigh = state.bend256 >> 8, targetHigh = state.targetBend256 >> 8
        let continuing = state.bendStep < 0 ? currentHigh >= targetHigh : currentHigh < targetHigh
        if continuing {
            state.bend256 = (state.bend256 + state.bendStep) & 65535
            state.roadOrigin256 = (state.roadOrigin256 + 2 - (state.bend256 >> 10)) & 65535
        } else {
            let targetLow = Self.nextRandom(&state.randomState)
            let targetHigh = (Self.nextRandom(&state.randomState) & 127) + 64
            state.targetBend256 = targetHigh * 256 + targetLow
            var stepLow = Self.nextRandom(&state.randomState) | 63
            let stepHigh = (Self.nextRandom(&state.randomState) & 7) - 4
            if stepHigh < 0 { stepLow ^= 255 }
            state.bendStep = stepHigh * 256 + stepLow
        }
    }

    private mutating func rebuildRoad() {
        // $E3FC: a signed 16-bit recurrence; each stored center is its high byte.
        let slope = ((state.bend256 >> 8) >> 1) - 64
        var delta = -15 * slope, position = state.roadOrigin256
        for row in 0..<19 {
            delta += slope
            position = (position + delta) & 65535
            state.roadCenters[row] = position >> 8
        }
    }
}

/// Original media stays local. Only the bounded first-party format reader ships.
struct NightDriverMedia: Decodable {
    struct Graphics: Decodable {
        struct HUD: Decodable {
            var gear, speed, time, highScore, extendedPlay, timeLabel, colors: [Int]
        }
        var characterRows: [[Int]]
        var digitSprites: [[Int]]
        var scoreDigitRows: [[Int]]
        var instructions: [Int]
        var hud: HUD
        var car: [[Int]]
        var crashPhases: [[[Int]]]
    }
    var schemaVersion: Int
    var sourceProgramSHA256: String
    var gameSHA256: String
    var graphics: Graphics

    static func load(from url: URL) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) < 150_000 else {
            throw NightDriverRestoreError.invalidState
        }
        let media = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        let graphics = media.graphics
        guard media.schemaVersion == 1, media.gameSHA256 == NightDriverSimulation.sourceSHA256,
              media.sourceProgramSHA256 == "c8be3efca0b9cb49418e3e1fd3659a40b651aa864c53743a4a4a232c33394ad8",
              graphics.characterRows.count == 256, graphics.characterRows.allSatisfy({ validBytes($0, count: 8) }),
              graphics.digitSprites.count == 10, graphics.digitSprites.allSatisfy({ validBytes($0, count: 63) }),
              graphics.scoreDigitRows.count == 11, graphics.scoreDigitRows.allSatisfy({ validBytes($0, count: 8) }),
              validBytes(graphics.instructions, count: 880), graphics.car.count == 5,
              graphics.car.allSatisfy({ validBytes($0, count: 18) }), graphics.crashPhases.count == 4,
              graphics.crashPhases.allSatisfy({ $0.count <= 100 && $0.allSatisfy({ $0.count == 3 && (0..<40).contains($0[0]) && (0..<22).contains($0[1]) && (0...255).contains($0[2]) }) }),
              validBytes(graphics.hud.gear, count: 5), validBytes(graphics.hud.speed, count: 5),
              validBytes(graphics.hud.time, count: 4), validBytes(graphics.hud.highScore, count: 17),
              validBytes(graphics.hud.extendedPlay, count: 17), validBytes(graphics.hud.timeLabel, count: 17),
              graphics.hud.colors.count == 17, graphics.hud.colors.allSatisfy({ (0...15).contains($0) })
        else { throw NightDriverRestoreError.invalidState }
        return media
    }

    private static func validBytes(_ bytes: [Int], count: Int) -> Bool {
        bytes.count == count && bytes.allSatisfy { (0...255).contains($0) }
    }
}
