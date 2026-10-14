import Foundation

/// Native reconstruction of the selected CX2622 cartridge's game rules. This
/// contains no processor interpreter or platform compatibility runtime. Pixel
/// contacts are title-specific geometry derived from its authored display kernel.
enum BreakoutVariation: Int, CaseIterable, Codable {
    case breakout = 1, steerable, catchBall, invisible
    case timed, timedSteerable, timedCatch, timedInvisible
    case breakthrough, breakthroughSteerable, breakthroughCatch, breakthroughInvisible

    // ROM $F7F0..$F7FB; player count occupies separate low selection bits.
    var flags: Int { [0x00, 0x10, 0x08, 0x40, 0x80, 0x90, 0x88, 0xc0, 0x20, 0x30, 0x28, 0x60][rawValue - 1] }
    var isTimed: Bool { flags & 0x80 != 0 }
    var isSteerable: Bool { flags & 0x10 != 0 }
    var canCatch: Bool { flags & 0x08 != 0 }
    var isInvisible: Bool { flags & 0x40 != 0 }
    var isBreakthrough: Bool { flags & 0x20 != 0 }
    var title: String {
        ["Breakout", "Steerable", "Catch", "Invisible", "Timed", "Timed steerable", "Timed catch", "Timed invisible",
         "Breakthru", "Breakthru steerable", "Breakthru catch", "Breakthru invisible"][rawValue - 1]
    }
}

enum BreakoutDifficulty: String, Codable, CaseIterable { case beginner, advanced }

struct BreakoutConfiguration: Codable, Equatable {
    var variation: BreakoutVariation = .breakout
    var playerCount: Int = 1
    /// The two original console difficulty switches apply to the two teams.
    var teamDifficulties: [BreakoutDifficulty] = [.beginner, .beginner]
    var monochrome = false
}

enum BreakoutPhase: String, Codable { case serve, playing, caught, ended, selection }

enum BreakoutGeometry {
    static let width = 160.0, height = 210.0
    static let columns = 18, rows = 6
    static let brickX = 8.0, brickY = 50.0, brickWidth = 8.0, brickHeight = 6.0
    static let paddleY = 180.0, paddleHeight = 4.0
    static let ballWidth = 2.0, ballHeight = 4.0
    static let leftBoundary = 8.0, rightBoundary = 152.0, ceilingY = 26.0, drainY = 208.0
    static let ceilingTop = 12, rasterBottom = 188
    static let rowPoints = [7, 7, 4, 4, 1, 1] // $F78C..$F791
}

struct BreakoutBall: Codable, Equatable {
    /// 8 fractional bits, as in $E3:$E4 / $E5:$E6. Horizontal display origin $31.
    var x256: Int
    var y256: Int
    /// Native coordinate derivatives; the ROM stores the negation of velocityX.
    var velocityX256: Int
    var velocityY256: Int
    var x: Double { Double(x256) / 256 - 49 }
    var y: Double { Double(y256) / 256 }
    var velocityX: Double { Double(velocityX256) / 256 }
    var velocityY: Double { Double(velocityY256) / 256 }
    /// $F040..F046 and $F0B3..F0B9 enable the ball for four lines. The
    /// display loop's Y takes only even values; fractional Y never enters it.
    var rasterX: Int { (x256 >> 8) - 49 }
    var rasterY: Int { ((y256 >> 8) + 1) & 0xfe }
}

struct BreakoutPaddle: Equatable {
    var player: Int
    var x: Double
    var width: Double
    var y: Double { BreakoutGeometry.paddleY }
    var height: Double { BreakoutGeometry.paddleHeight }
}

struct BreakoutTeam: Codable, Equatable {
    var score = 0
    var timerTicks = 0
    var ballsUsed = 0
    var wallsCleared = 0
    var bricks = Array(repeating: true, count: 108)
    var awaitingSecondWall = false
    var isFinished: Bool { ballsUsed >= 5 }
}

struct BreakoutContacts: Codable, Equatable {
    var paddlePlayers: [Int] = []
    var playfield = false
    var side = false
}

/// Authored sound parameters, not an audio-device or TIA implementation.
struct BreakoutAudioRegisters: Codable, Equatable {
    var control = 12
    var frequency = 0
    var volume = 0
}

struct BreakoutState: Codable, Equatable {
    var configuration: BreakoutConfiguration
    var phase: BreakoutPhase = .serve
    var frame: UInt64 = 0
    var activeTeam = 0
    var teams: [BreakoutTeam]
    var ball: BreakoutBall?
    /// Player knob positions in cartridge coordinates, independent of game turn.
    var paddleLefts = [123, 123, 123, 123]
    var ceilingWasHit = false
    var speedCounter = 0
    var angleIndex = 0
    var paddleCollisionLatched = false
    var brickCollisionLatched = false
    var invisibleFlashFrames = 0
    var caughtPlayer: Int?
    /// Collision flags from the previous displayed frame, consumed before
    /// the next motion update ($F428..F55D; clear at $F616).
    var contacts = BreakoutContacts()
    var roundsRemaining = 5
    /// $F132 rotates 36 packed wall entries, then $F1A1 clears the request.
    /// Native teams swap atomically; this preserves collision suspension only.
    var transitionFrames = 37
    var transitionRebuildsWall = true
    var endDisplayFrame = 0
    var audioCounter = 0
    var brickAudioFrequency = 0
    var audioRegisters = BreakoutAudioRegisters()
    var renderWallVisible = true
    /// Source F5/F6 update only on ascent with steering enabled and no side
    /// contact; descent and team changes retain these two logical channels.
    var steeringLefts = [0, 0]
    /// ResetMotion at $F1E1 retains E4/E6. New serves inherit the lost ball's
    /// fractional coordinates even when the next turn belongs to another team.
    var serveFractionX256 = 0
    var serveFractionY256 = 0

    var bricks: [Bool] { teams[activeTeam].bricks }
    var score: Int { teams[activeTeam].score }
    var ballsRemaining: Int { roundsRemaining }
    var wallNumber: Int { min(2, teams[activeTeam].wallsCleared + 1) }
    var wallVisible: Bool { renderWallVisible }
    var activePlayers: [Int] {
        switch configuration.playerCount {
        case 1: return [0]
        case 2: return [activeTeam]
        case 3: return activeTeam == 0 ? [0] : [1, 2]
        default: return activeTeam == 0 ? [0, 1] : [2, 3]
        }
    }
    var paddleWidth: Double {
        let index = (configuration.teamDifficulties[activeTeam] == .advanced ? 1 : 0) + (ceilingWasHit ? 1 : 0)
        return Double([16, 12, 8][index]) // $F7D6..$F7DB, fourfold TIA player pixels.
    }
    var paddles: [BreakoutPaddle] {
        activePlayers.map { BreakoutPaddle(player: $0, x: Double(paddleLefts[$0] - 49), width: paddleWidth) }
    }
    /// Original COLU values, top row first. RGB/NTSC display calibration is
    /// separate; these values are read directly from $F7AA..F7BD.
    var rowColorCodes: [Int] {
        configuration.monochrome ? [4, 6, 8, 4, 6, 8] : [0x46, 0x36, 0x26, 0x16, 0xc6, 0x86]
    }
    var paddleColorCodes: [Int] {
        let codes = configuration.monochrome ? [12, 10] : [0x46, 0xb6]
        return activeTeam == 0 || configuration.monochrome ? codes : codes.map { $0 ^ 0x90 }
    }
}

struct BreakoutInput {
    /// Absolute 0...1 paddle knobs for all players. Native device-to-knob mapping
    /// is an adapter and is not a claim about original RC discharge timing.
    var paddlePositions: [Double] = [0.5, 0.5, 0.5, 0.5]
    /// Original fire is level-sensitive: hold to catch, release to launch a catch.
    var serve = false
}

enum BreakoutEvent: Equatable {
    case served, paddleHit, ceilingHit, sideHit, caught, ballLost, teamChanged
    case brickHit(row: Int, column: Int, points: Int)
    case wallCleared, wallRebuilt, ended
    case selectionReturned
}

struct BreakoutSnapshot: Codable, Equatable {
    var schemaVersion = 2
    var sourceSHA256 = BreakoutSimulation.sourceSHA256
    var state: BreakoutState
}

enum BreakoutRestoreError: Error { case incompatibleSource, invalidState }

struct BreakoutSimulation {
    static let sourceSHA256 = "376323f051c3c373c887fd83abead39d87d844ff283d435f4addbfc1710c6fd5"
    private(set) var state: BreakoutState
    private(set) var events: [BreakoutEvent] = []

    init(configuration: BreakoutConfiguration = BreakoutConfiguration()) {
        var configuration = configuration
        configuration.playerCount = min(4, max(1, configuration.playerCount))
        configuration.teamDifficulties = Array((configuration.teamDifficulties + [.beginner, .beginner]).prefix(2))
        state = BreakoutState(configuration: configuration, teams: Array(repeating: BreakoutTeam(), count: configuration.playerCount == 1 ? 1 : 2))
        state.renderWallVisible = !configuration.variation.isInvisible
    }

    var snapshot: BreakoutSnapshot { BreakoutSnapshot(state: state) }

    init(snapshot: BreakoutSnapshot) throws {
        guard snapshot.schemaVersion == 2, snapshot.sourceSHA256 == Self.sourceSHA256 else { throw BreakoutRestoreError.incompatibleSource }
        let state = snapshot.state, configuration = state.configuration
        guard state.frame <= 65535, (1...4).contains(configuration.playerCount), configuration.teamDifficulties.count == 2,
              state.teams.count == (configuration.playerCount == 1 ? 1 : 2), state.teams.indices.contains(state.activeTeam),
              state.paddleLefts.count == 4, state.paddleLefts.allSatisfy({ (55...191).contains($0) }),
              (0...16).contains(state.speedCounter), [0, 2].contains(state.angleIndex),
              (0...6).contains(state.invisibleFlashFrames), (0...5).contains(state.roundsRemaining),
              (0...37).contains(state.transitionFrames), (0...255).contains(state.endDisplayFrame),
              (0...255).contains(state.audioCounter), (0...31).contains(state.brickAudioFrequency),
              state.steeringLefts.count == 2, state.steeringLefts.allSatisfy({ (0...255).contains($0) }),
              (0...255).contains(state.serveFractionX256), (0...255).contains(state.serveFractionY256),
              state.audioRegisters.control == 12, (0...31).contains(state.audioRegisters.frequency),
              [0, 15].contains(state.audioRegisters.volume),
              state.contacts.paddlePlayers.count <= 2,
              Set(state.contacts.paddlePlayers).count == state.contacts.paddlePlayers.count,
              state.contacts.paddlePlayers.allSatisfy({ state.activePlayers.contains($0) }),
              state.caughtPlayer == nil || state.activePlayers.contains(state.caughtPlayer!),
              state.teams.allSatisfy({ $0.bricks.count == 108 && (0...864).contains($0.score) && (0...5).contains($0.ballsUsed)
                  && (0...2).contains($0.wallsCleared) && (0...9999).contains($0.timerTicks) }),
              (state.phase == .playing || state.phase == .caught) == (state.ball != nil),
              state.phase != .caught || (state.caughtPlayer != nil && configuration.variation.canCatch),
              state.phase != .ended || state.roundsRemaining == 0,
              [.ended, .selection].contains(state.phase) || state.roundsRemaining > 0
        else { throw BreakoutRestoreError.invalidState }
        if let ball = state.ball {
            guard (0...65535).contains(ball.x256), (0...65535).contains(ball.y256),
                  (-1024...1024).contains(ball.velocityX256), (-1024...1024).contains(ball.velocityY256) else { throw BreakoutRestoreError.invalidState }
        }
        self.state = state
    }

    mutating func reset(configuration: BreakoutConfiguration? = nil) {
        self = Self(configuration: configuration ?? state.configuration)
    }

    mutating func takeEvents() -> [BreakoutEvent] {
        let result = events
        events.removeAll(keepingCapacity: true)
        return result
    }

    /// One authored frame, independent of render frequency. A qualified original
    /// frame duration is still required; the UI's nominal 60 Hz is development.
    mutating func tick(input: BreakoutInput = BreakoutInput()) {
        events.removeAll(keepingCapacity: true)
        state.frame &+= 1
        prepareSoundAndVisibility() // $F2AF..F326 precedes the game update.
        // $F352..F358 -> F3B4: overflowing DA/DB returns to console selection,
        // even from the ended scoreboard. This is not five-round completion.
        if state.frame & 65535 == 0 {
            returnToSelection()
            updatePaddles(input.paddlePositions, ball: nil)
            return
        }
        if state.phase == .selection {
            advanceTransition()
            updatePaddles(input.paddlePositions, ball: nil)
            state.contacts = BreakoutContacts()
            return
        }
        if state.phase == .ended {
            state.endDisplayFrame = (state.endDisplayFrame + 1) & 255
            if state.endDisplayFrame == 0, state.teams.count == 2 {
                changeTeam(rebuild: false) // $F352..F368: compare teams every 256 frames.
            }
            advanceTransition()
            updatePaddles(input.paddlePositions, ball: nil)
            state.contacts = BreakoutContacts()
            return
        }
        if state.configuration.variation.isTimed, state.frame & 63 == 0 {
            state.teams[state.activeTeam].timerTicks = (state.teams[state.activeTeam].timerTicks + 1) % 10000
        }
        // $F3D7..F3F3 tests the prior frame's integer Y before collisions/motion.
        let drained = state.ball.map { $0.y256 >> 8 >= 208 } ?? false
        if drained { loseBall() }
        if !drained, state.phase == .serve, input.serve { serve() }

        var ball = state.ball
        if state.transitionFrames > 0 {
            advanceTransition()
        } else if var moving = ball {
            consumeContacts(&moving)
            ball = moving
        }
        // $F55F..F5A5 updates the knobs after collision response. Steering uses
        // the resulting vertical sign, and is suppressed by a side contact.
        updatePaddles(input.paddlePositions, ball: &ball)
        if var moving = ball {
            if state.configuration.variation.canCatch, input.serve,
               let player = state.contacts.paddlePlayers.first {
                state.phase = .caught
                if state.caughtPlayer != player { events.append(.caught) }
                state.caughtPlayer = player
                // Source catch changes only integer position; the Q8 fractional
                // bytes survive capture and release ($F5EC..F5F4).
                moving.x256 = (state.paddleLefts[player] + 4) * 256 + (moving.x256 & 255)
                moving.y256 = 178 * 256 + (moving.y256 & 255)
            } else {
                state.phase = .playing
                state.caughtPlayer = nil
                moving.x256 = (moving.x256 + moving.velocityX256) & 65535
                moving.y256 = (moving.y256 + moving.velocityY256) & 65535
            }
            state.ball = moving
        } else { state.ball = nil }
        // $F616 clears collision bits immediately before drawing the new frame.
        state.contacts = Self.contacts(ball: state.ball, paddles: state.paddles, bricks: state.bricks)
    }

    /// Static integer pixel overlap, not a hardware graphics/CPU interpreter.
    /// It reconstructs this title's fixed strips, PF brick bits and player masks.
    /// Intra-scanline register-write edges still require original comparison.
    static func contacts(ball: BreakoutBall?, paddles: [BreakoutPaddle], bricks: [Bool]) -> BreakoutContacts {
        guard let ball else { return BreakoutContacts() }
        let x = ball.rasterX, y = ball.rasterY
        func overlap(_ left: Int, _ top: Int, _ width: Int, _ height: Int) -> Bool {
            x < left + width && x + 2 > left && y < top + height && y + 4 > top
        }
        let players = paddles.filter { overlap(Int($0.x), 180, Int($0.width), 4) }.map(\.player)
        let side = overlap(0, 12, 8, 176) || overlap(152, 12, 8, 176)
        var playfield = overlap(0, 12, 160, 14)
        if !playfield, bricks.count == 108 {
            for row in 0..<6 where y < 56 + row * 6 && y + 4 > 50 + row * 6 {
                for column in 0..<18 where bricks[row * 18 + column] {
                    if overlap(8 + column * 8, 50 + row * 6, 8, 6) { playfield = true; break }
                }
                if playfield { break }
            }
        }
        return BreakoutContacts(paddlePlayers: players, playfield: playfield, side: side)
    }

    private mutating func prepareSoundAndVisibility() {
        let counter = state.audioCounter
        var frequency = 0
        if counter & 63 != 0 {
            frequency = counter & 128 != 0 ? (counter & 64 != 0 ? 2 : 8) :
                (counter & 64 != 0 ? 4 : state.brickAudioFrequency)
            state.audioCounter = (counter - 1) & 255
        }
        state.audioRegisters = BreakoutAudioRegisters(frequency: frequency, volume: counter & 63 == 0 ? 0 : 15)
        state.invisibleFlashFrames = state.audioCounter & 192 == 0 ? min(6, state.audioCounter & 63) : 0
        state.renderWallVisible = !state.configuration.variation.isInvisible || [.ended, .selection].contains(state.phase) || state.invisibleFlashFrames > 0
    }

    private mutating func updatePaddles(_ positions: [Double], ball: inout BreakoutBall?) {
        let players = state.activePlayers
        for (index, player) in players.enumerated() {
            // $F5FA..F606 and $F6DB..F6E7 select one split knob for two frames.
            if players.count == 2, index != Int((state.frame & 2) >> 1) { continue }
            let value = player < positions.count && positions[player].isFinite ? positions[player] : 0.5
            let knob = min(1, max(0, value))
            let bounds = players.count == 1 ? (55, 191) : (index == 0 ? (55, 126) : (128, 191))
            state.paddleLefts[player] = bounds.0 + Int((Double(bounds.1 - bounds.0) * knob).rounded())
            if state.configuration.variation.isSteerable, !state.contacts.side,
               let moving = ball, moving.velocityY256 < 0 {
                let previous = state.steeringLefts[index]
                let current = state.paddleLefts[player]
                state.steeringLefts[index] = current
                if current != previous { ball?.x256 = (moving.x256 + (current > previous ? 512 : -512)) & 65535 }
            }
        }
    }

    private mutating func updatePaddles(_ positions: [Double], ball: BreakoutBall?) {
        var ball = ball
        updatePaddles(positions, ball: &ball)
    }

    private mutating func serve() {
        let index = Int(state.frame & 3)
        state.ball = BreakoutBall(x256: [64, 128, 128, 192][index] * 256 + state.serveFractionX256,
                                 y256: 112 * 256 + state.serveFractionY256,
                                 velocityX256: [256, -256, 256, -256][index], velocityY256: 256)
        state.phase = .playing
        state.ceilingWasHit = false
        state.speedCounter = 0
        state.angleIndex = 0
        state.paddleCollisionLatched = false
        state.brickCollisionLatched = false
        state.audioCounter = 0x48
        events.append(.served)
    }

    /// ROM packed speed bytes: low two bits are integral, high six fractional.
    static func velocityMagnitudes(counter: Int, angle: Int) -> (x: Int, y: Int) {
        let packed = [0x81, 0x01, 0x01, 0x81, 0x81, 0x02, 0x80, 0x02, 0x02, 0x01,
                      0x02, 0x01, 0x02, 0x02, 0x02, 0x02, 0x02, 0x63, 0x02, 0x63]
        let index = (min(16, max(0, counter)) & 0x3c) + (angle == 2 ? 2 : 0)
        func decode(_ value: Int) -> Int { (value & 3) * 256 + (value & 0xfc) }
        return (decode(packed[index]), decode(packed[index + 1]))
    }

    private mutating func consumeContacts(_ ball: inout BreakoutBall) {
        if !state.paddleCollisionLatched, let player = state.contacts.paddlePlayers.first {
            hitPaddle(&ball, player: player)
        }
        if state.contacts.playfield {
            if ball.y256 >> 8 < 40 {
                state.ceilingWasHit = true
                ball.velocityY256 = -ball.velocityY256
                state.paddleCollisionLatched = false
                state.brickCollisionLatched = false
                state.audioCounter = 0x88
                events.append(.ceilingHit)
            } else if !state.brickCollisionLatched { hitBrick(&ball) }
        }
        // $F54C..F552 reflects only while moving toward that half's side.
        // Original motion is not clamped or pushed out after any collision.
        if state.contacts.side, ((ball.x256 >> 8 < 128) == (ball.velocityX256 <= 0)) {
            ball.velocityX256 = -ball.velocityX256
            if state.audioCounter & 63 == 0 { state.audioCounter = 0x46 }
            events.append(.sideHit)
        }
    }

    private mutating func hitPaddle(_ ball: inout BreakoutBall, player: Int) {
        let halfWidth = Int(state.paddleWidth / 2)
        var offset = state.paddleLefts[player] + halfWidth - (ball.x256 >> 8)
        if offset == 0 {
            ball.x256 = (ball.x256 + (ball.velocityX256 < 0 ? 1024 : -1024)) & 65535
            offset = 1
        }
        var magnitude = min(8, abs(offset))
        if halfWidth == 4 { magnitude *= 2 }
        state.angleIndex = ((magnitude + 3) & 4) >> 1
        if state.speedCounter < 12 { state.speedCounter += 1 }
        let speed = Self.velocityMagnitudes(counter: state.speedCounter, angle: state.angleIndex)
        ball.velocityX256 = offset > 0 ? -speed.x : speed.x
        ball.velocityY256 = ball.velocityY256 >= 0 ? -speed.y : speed.y
        state.paddleCollisionLatched = true
        // $F485 retains only the low speed bits: paddle clears the brick latch.
        state.brickCollisionLatched = false
        state.audioCounter = 0x88
        events.append(.paddleHit)
        // $F490..F4A2 explicitly bypasses this path in all four timer modes.
        // Clearing a wall is not itself a rebuild trigger in this revision.
        if !state.configuration.variation.isTimed, state.score == 432 {
            state.transitionFrames = 1
            state.transitionRebuildsWall = true
        }
    }

    private mutating func hitBrick(_ ball: inout BreakoutBall) {
        // $F4C8..F4F1 selects from the integer ball origin, not from which
        // rectangle actually produced the collision. SBC $39 runs with carry
        // clear after row negation/+5, so its effective X subtraction is 58.
        let row = max(0, (ball.y256 >> 8) - 50) / 6
        let column = min(17, max(0, (ball.x256 >> 8) - 58) / 8)
        guard row < 6, state.teams[state.activeTeam].bricks[row * 18 + column] else { return }
        state.teams[state.activeTeam].bricks[row * 18 + column] = false
        let points = BreakoutGeometry.rowPoints[row]
        // Timed source uses these same score bytes exclusively as its BCD timer.
        if !state.configuration.variation.isTimed { state.teams[state.activeTeam].score += points }
        state.brickAudioFrequency = [10, 12, 16, 18, 22, 28][row]
        state.audioCounter = 6
        if row < 3 { state.speedCounter = 16; state.angleIndex = 0 }
        let speed = Self.velocityMagnitudes(counter: state.speedCounter, angle: state.angleIndex)
        ball.velocityX256 = ball.velocityX256 <= 0 ? -speed.x : speed.x
        if state.configuration.variation.isBreakthrough {
            ball.velocityY256 = ball.velocityY256 < 0 ? -speed.y : speed.y
        } else {
            ball.velocityY256 = ball.velocityY256 < 0 ? speed.y : -speed.y
            state.brickCollisionLatched = true
        }
        events.append(.brickHit(row: row, column: column, points: points))
        if !state.teams[state.activeTeam].bricks.contains(true) {
            state.teams[state.activeTeam].wallsCleared = min(2, state.teams[state.activeTeam].wallsCleared + 1)
            state.teams[state.activeTeam].awaitingSecondWall = !state.configuration.variation.isTimed && state.score == 432
            events.append(.wallCleared)
            // No 864/wall-empty terminal branch exists in the selected fully
            // covered cartridge. Ball and shared five-round schedule continue.
        }
    }

    private mutating func advanceTransition() {
        guard state.transitionFrames > 0 else { return }
        state.transitionFrames -= 1
        if state.transitionFrames == 0, state.transitionRebuildsWall {
            state.teams[state.activeTeam].bricks = Array(repeating: true, count: 108)
            state.teams[state.activeTeam].awaitingSecondWall = false
            state.transitionRebuildsWall = false
            events.append(.wallRebuilt)
        }
    }

    private mutating func changeTeam(rebuild: Bool) {
        state.activeTeam = 1 - state.activeTeam
        state.transitionFrames = 37
        state.transitionRebuildsWall = rebuild
        state.contacts = BreakoutContacts()
        events.append(.teamChanged)
    }

    private mutating func loseBall() {
        let lostTeam = state.activeTeam
        state.serveFractionX256 = (state.ball?.x256 ?? 0) & 255
        state.serveFractionY256 = (state.ball?.y256 ?? 0) & 255
        state.teams[lostTeam].ballsUsed += 1
        state.ball = nil
        state.caughtPlayer = nil
        state.ceilingWasHit = false
        state.speedCounter = 0
        state.angleIndex = 0
        state.paddleCollisionLatched = false
        state.brickCollisionLatched = false
        state.phase = .serve
        state.contacts = BreakoutContacts()
        events.append(.ballLost)
        if state.teams.count == 2 { changeTeam(rebuild: false) }
        // $F3EB..F3F3 decrements B9 only on return to team zero, after both turns.
        if state.teams.count == 1 || state.activeTeam == 0 { state.roundsRemaining -= 1 }
        if state.roundsRemaining == 0 {
            state.phase = .ended
            state.frame = 0 // $F385..F387 reset DA/DB when B4 becomes zero.
            state.endDisplayFrame = 0
            state.renderWallVisible = true
            events.append(.ended)
        }
    }

    private mutating func returnToSelection() {
        if let ball = state.ball {
            state.serveFractionX256 = ball.x256 & 255
            state.serveFractionY256 = ball.y256 & 255
        }
        state.phase = .selection
        state.frame = 0
        state.ball = nil
        state.caughtPlayer = nil
        state.ceilingWasHit = false
        state.speedCounter = 0
        state.angleIndex = 0
        state.paddleCollisionLatched = false
        state.brickCollisionLatched = false
        state.contacts = BreakoutContacts()
        events.append(.selectionReturned)
    }
}

/// Original bitmap HUD data is prepared locally and never embedded in Git.
struct BreakoutMedia: Codable {
    var schemaVersion: Int
    var sourceSHA256: String
    /// Ten digits, top-to-bottom five scanline pairs, three logical pixels wide.
    var digitRows: [[Int]]

    static func load(from url: URL) throws -> BreakoutMedia {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 16385), (1...16384).contains(data.count)
        else { throw BreakoutRestoreError.invalidState }
        let media = try JSONDecoder().decode(Self.self, from: data)
        guard media.schemaVersion == 1, media.sourceSHA256 == BreakoutSimulation.sourceSHA256,
              media.digitRows.count == 10,
              media.digitRows.allSatisfy({ $0.count == 5 && $0.allSatisfy({ (0...7).contains($0) }) })
        else { throw BreakoutRestoreError.incompatibleSource }
        return media
    }
}
