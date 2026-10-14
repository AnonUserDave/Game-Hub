import Foundation

/// Native reconstruction of the selected CX2622 cartridge's game rules. This
/// contains no 6502 interpreter or TIA implementation. See BREAKOUT.md for the
/// exact ROM tables and the remaining collision/display/control approximations.
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
}

enum BreakoutPhase: String, Codable { case serve, playing, caught, ended }

enum BreakoutGeometry {
    static let width = 160.0, height = 210.0
    static let columns = 18, rows = 6
    static let brickX = 8.0, brickY = 50.0, brickWidth = 8.0, brickHeight = 6.0
    static let paddleY = 180.0, paddleHeight = 4.0
    static let ballWidth = 2.0, ballHeight = 4.0
    static let leftBoundary = 8.0, rightBoundary = 152.0, ceilingY = 26.0, drainY = 208.0
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
    var isFinished: Bool { ballsUsed >= 5 || wallsCleared >= 2 }
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

    var bricks: [Bool] { teams[activeTeam].bricks }
    var score: Int { teams[activeTeam].score }
    var ballsRemaining: Int { max(0, 5 - teams[activeTeam].ballsUsed) }
    var wallNumber: Int { min(2, teams[activeTeam].wallsCleared + 1) }
    var wallVisible: Bool { !configuration.variation.isInvisible || phase == .ended || invisibleFlashFrames > 0 }
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
}

struct BreakoutSnapshot: Codable, Equatable {
    var schemaVersion = 1
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
    }

    var snapshot: BreakoutSnapshot { BreakoutSnapshot(state: state) }

    init(snapshot: BreakoutSnapshot) throws {
        guard snapshot.schemaVersion == 1, snapshot.sourceSHA256 == Self.sourceSHA256 else { throw BreakoutRestoreError.incompatibleSource }
        let state = snapshot.state, configuration = state.configuration
        guard (1...4).contains(configuration.playerCount), configuration.teamDifficulties.count == 2,
              state.teams.count == (configuration.playerCount == 1 ? 1 : 2), state.teams.indices.contains(state.activeTeam),
              state.paddleLefts.count == 4, state.paddleLefts.allSatisfy({ (55...191).contains($0) }),
              (0...16).contains(state.speedCounter), [0, 2].contains(state.angleIndex),
              (0...6).contains(state.invisibleFlashFrames),
              state.caughtPlayer == nil || state.activePlayers.contains(state.caughtPlayer!),
              state.teams.allSatisfy({ $0.bricks.count == 108 && (0...864).contains($0.score) && (0...5).contains($0.ballsUsed)
                  && (0...2).contains($0.wallsCleared) && $0.timerTicks >= 0 && $0.timerTicks <= 9999 }),
              (state.phase == .playing || state.phase == .caught) == (state.ball != nil),
              state.phase != .caught || (state.caughtPlayer != nil && configuration.variation.canCatch)
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

    /// One cartridge frame. The caller owns its 60 Hz clock; render frequency
    /// never changes simulation speed. Bounded work: four knobs and 108 bricks.
    mutating func tick(input: BreakoutInput = BreakoutInput()) {
        guard state.phase != .ended else { return }
        events.removeAll(keepingCapacity: true)
        state.frame &+= 1
        updatePaddles(input.paddlePositions)
        state.invisibleFlashFrames = max(0, state.invisibleFlashFrames - 1)
        // $F3C8..$F3D4: BCD +1 on every 64th active frame, including waiting/catch.
        if state.configuration.variation.isTimed, state.frame & 63 == 0 {
            state.teams[state.activeTeam].timerTicks = (state.teams[state.activeTeam].timerTicks + 1) % 10000
        }
        if state.phase == .serve {
            if input.serve { serve() }
            return
        }
        if state.phase == .caught {
            if input.serve, let player = state.caughtPlayer {
                state.ball?.x256 = (state.paddleLefts[player] + 4) * 256
                state.ball?.y256 = 178 * 256 // $F5EC..$F5F4
                return
            }
            state.phase = .playing
            state.caughtPlayer = nil
        }
        guard var ball = state.ball else { return }
        let oldY = ball.y
        ball.x256 += ball.velocityX256
        ball.y256 += ball.velocityY256
        if state.configuration.variation.isSteerable, ball.velocityY256 < 0 {
            // $F708..$F72B: knob movement steers by two pixels only on ascent.
            let player = state.activePlayers[0]
            let previous = previousPaddleLefts[player]
            let current = state.paddleLefts[player]
            if current > previous { ball.x256 += 512 }
            if current < previous { ball.x256 -= 512 }
        }
        if ball.x < BreakoutGeometry.leftBoundary, ball.velocityX256 < 0 {
            ball.x256 = (49 + Int(BreakoutGeometry.leftBoundary)) * 256
            ball.velocityX256 = -ball.velocityX256
            events.append(.sideHit)
        } else if ball.x + BreakoutGeometry.ballWidth > BreakoutGeometry.rightBoundary, ball.velocityX256 > 0 {
            ball.x256 = (49 + Int(BreakoutGeometry.rightBoundary - BreakoutGeometry.ballWidth)) * 256
            ball.velocityX256 = -ball.velocityX256
            events.append(.sideHit)
        }
        if ball.y < BreakoutGeometry.ceilingY, ball.velocityY256 < 0 {
            ball.y256 = Int(BreakoutGeometry.ceilingY) * 256
            ball.velocityY256 = -ball.velocityY256
            state.ceilingWasHit = true
            state.paddleCollisionLatched = false
            state.brickCollisionLatched = false
            events.append(.ceilingHit)
        }
        if ball.velocityY256 > 0, !state.paddleCollisionLatched,
           oldY + BreakoutGeometry.ballHeight <= BreakoutGeometry.paddleY,
           ball.y + BreakoutGeometry.ballHeight >= BreakoutGeometry.paddleY,
           let paddle = state.paddles.first(where: { ball.x + BreakoutGeometry.ballWidth > $0.x && ball.x < $0.x + $0.width }) {
            hitPaddle(&ball, paddle: paddle, fireHeld: input.serve)
        }
        if !state.brickCollisionLatched { hitBrick(&ball) }
        if state.phase == .ended { state.ball = nil; return }
        if state.phase == .serve { return }
        if ball.y >= BreakoutGeometry.drainY { loseBall(); return }
        state.ball = ball
    }

    // These are input history, not saved gameplay state. Reset on restore; the
    // first restored frame cannot manufacture a steering movement.
    private var previousPaddleLefts = [123, 123, 123, 123]

    private mutating func updatePaddles(_ positions: [Double]) {
        previousPaddleLefts = state.paddleLefts
        let players = state.activePlayers
        for (index, player) in players.enumerated() {
            let value = player < positions.count && positions[player].isFinite ? positions[player] : 0.5
            let knob = min(1, max(0, value))
            let bounds = players.count == 1 ? (55, 191) : (index == 0 ? (55, 126) : (128, 191)) // $F782..$F787
            state.paddleLefts[player] = bounds.0 + Int((Double(bounds.1 - bounds.0) * knob).rounded())
        }
    }

    private mutating func serve() {
        let index = Int(state.frame & 3)
        state.ball = BreakoutBall(x256: [64, 128, 128, 192][index] * 256, y256: 112 * 256,
                                 velocityX256: [256, -256, 256, -256][index], velocityY256: 256) // $F401..$F418
        state.phase = .playing
        state.ceilingWasHit = false
        state.speedCounter = 0
        state.angleIndex = 0
        state.paddleCollisionLatched = false
        state.brickCollisionLatched = false
        events.append(.served)
    }

    /// ROM packed speed bytes: low two bits are integral, high six fractional.
    static func velocityMagnitudes(counter: Int, angle: Int) -> (x: Int, y: Int) {
        let packed = [0x81, 0x01, 0x01, 0x81, 0x81, 0x02, 0x80, 0x02, 0x02, 0x01,
                      0x02, 0x01, 0x02, 0x02, 0x02, 0x02, 0x02, 0x63, 0x02, 0x63] // $F7DC..$F7EF
        let index = (min(16, max(0, counter)) & 0x3c) + (angle == 2 ? 2 : 0)
        func decode(_ value: Int) -> Int { (value & 3) * 256 + (value & 0xfc) }
        return (decode(packed[index]), decode(packed[index + 1]))
    }

    private mutating func hitPaddle(_ ball: inout BreakoutBall, paddle: BreakoutPaddle, fireHeld: Bool) {
        var offset = (state.paddleLefts[paddle.player] + Int(paddle.width / 2)) - (ball.x256 / 256)
        if offset == 0 {
            ball.x256 += ball.velocityX256 < 0 ? 1024 : -1024 // $F43E..$F44E
            offset = 1
        }
        var magnitude = min(8, abs(offset))
        if paddle.width == 8 { magnitude *= 2 }
        state.angleIndex = ((magnitude + 3) & 4) >> 1 // $F45C..$F479
        if state.speedCounter < 12 { state.speedCounter += 1 }
        let speed = Self.velocityMagnitudes(counter: state.speedCounter, angle: state.angleIndex)
        ball.velocityX256 = offset > 0 ? -speed.x : speed.x
        ball.velocityY256 = -speed.y
        ball.y256 = 176 * 256
        state.paddleCollisionLatched = true
        state.brickCollisionLatched = false
        events.append(.paddleHit)
        if state.teams[state.activeTeam].awaitingSecondWall {
            state.teams[state.activeTeam].bricks = Array(repeating: true, count: 108)
            state.teams[state.activeTeam].awaitingSecondWall = false
            events.append(.wallRebuilt)
        }
        if state.configuration.variation.canCatch && fireHeld {
            state.phase = .caught
            state.caughtPlayer = paddle.player
            ball.x256 = (state.paddleLefts[paddle.player] + 4) * 256
            ball.y256 = 178 * 256
            events.append(.caught)
        }
    }

    private mutating func hitBrick(_ ball: inout BreakoutBall) {
        // Native rectangle contact replaces the TIA's prior-frame CXPFB latch.
        // Candidate order follows direction so a shared edge removes one brick.
        let rows = ball.velocityY256 < 0 ? Array((0..<6).reversed()) : Array(0..<6)
        let columns = ball.velocityX256 < 0 ? Array((0..<18).reversed()) : Array(0..<18)
        for row in rows {
            let y = BreakoutGeometry.brickY + Double(row) * BreakoutGeometry.brickHeight
            guard ball.y < y + BreakoutGeometry.brickHeight, ball.y + BreakoutGeometry.ballHeight > y else { continue }
            for column in columns {
                let index = row * 18 + column
                guard state.teams[state.activeTeam].bricks[index] else { continue }
                let x = BreakoutGeometry.brickX + Double(column) * BreakoutGeometry.brickWidth
                guard ball.x < x + 8, ball.x + 2 > x else { continue }
                state.teams[state.activeTeam].bricks[index] = false
                let points = BreakoutGeometry.rowPoints[row]
                state.teams[state.activeTeam].score += points
                state.invisibleFlashFrames = 6 // $F50B..$F50D; visual fade is a native approximation.
                if row < 3 { state.speedCounter = 16; state.angleIndex = 0 } // $F519..$F528
                let speed = Self.velocityMagnitudes(counter: state.speedCounter, angle: state.angleIndex)
                ball.velocityX256 = ball.velocityX256 < 0 ? -speed.x : speed.x
                ball.velocityY256 = ball.velocityY256 < 0 ? -speed.y : speed.y
                if !state.configuration.variation.isBreakthrough {
                    ball.velocityY256 = -ball.velocityY256
                    state.brickCollisionLatched = true
                    ball.y256 = Int((ball.velocityY256 > 0 ? y + 6 : y - 4) * 256)
                }
                events.append(.brickHit(row: row, column: column, points: points))
                if !state.teams[state.activeTeam].bricks.contains(true) {
                    state.teams[state.activeTeam].wallsCleared += 1
                    events.append(.wallCleared)
                    if state.teams[state.activeTeam].wallsCleared == 1 {
                        state.teams[state.activeTeam].awaitingSecondWall = true
                    } else { finishTurn() }
                }
                return
            }
        }
    }

    private mutating func loseBall() {
        state.teams[state.activeTeam].ballsUsed += 1
        events.append(.ballLost)
        finishTurn()
    }

    private mutating func finishTurn() {
        state.ball = nil
        state.caughtPlayer = nil
        state.ceilingWasHit = false
        state.phase = .serve
        if state.teams.allSatisfy(\.isFinished) {
            state.phase = .ended
            events.append(.ended)
        } else if state.teams.count == 2 && !state.teams[1 - state.activeTeam].isFinished {
            state.activeTeam = 1 - state.activeTeam
            events.append(.teamChanged)
        }
        // Team transitions restore their own source wall/score. Cartridge's
        // 36-frame bit rotation is intentionally represented as an atomic swap.
    }
}
