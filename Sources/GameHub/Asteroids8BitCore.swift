import Foundation
import CryptoKit

/// Selected US Atari 8-bit edition. Source resources stay outside Git.
/// This core contains game rules, not a 6502, ANTIC, GTIA or POKEY interpreter.
struct Asteroids8BitResources: Codable, Equatable {
    static let sourceIdentity = "1cf45090b216c2363131bac2e4db9101a3c162e31686d7fe30474eaba5b7f97f"
    static let codeIdentity = "e24b9792d19d4a8fdeb443bb7201b64b27ab283ec308dc067affea86e12dbf5f"
    static let tableIdentity = "de5c7d6d9e0933f2f6b06a9d8854de47e4e57fbb5ccdaea46d712edab9c41c7a"
    var schema: Int
    var sourceSHA256: String
    var codeSHA256: String
    var tableSHA256: String
    var waveCounts, initialX, initialY, projectileOffsetX, projectileOffsetY: [UInt8]
    var extents, explosionOffsets, sine, colors, shipRows: [UInt8]
    var smallRows, mediumRows, largeRows, explosionRows, explosionBits: [UInt8]
    var soundRequests, soundSequences: [UInt8]

    enum Invalid: Error { case size, identity, layout }
    static func load(from url: URL) throws -> Self {
        let count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard count > 0, count <= 32 * 1024 else { throw Invalid.size }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty, data.count <= 32 * 1024 else { throw Invalid.size }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }
    func validate() throws {
        guard schema == 1, sourceSHA256 == Self.sourceIdentity, codeSHA256 == Self.codeIdentity,
              tableSHA256 == Self.tableIdentity else {
            throw Invalid.identity
        }
        let lengths: [(Int, Int)] = [(waveCounts.count, 7), (initialX.count, 4), (initialY.count, 4),
                       (projectileOffsetX.count, 18), (projectileOffsetY.count, 18),
                       (extents.count, 4), (explosionOffsets.count, 4), (sine.count, 65),
                       (colors.count, 11), (shipRows.count, 95), (smallRows.count, 4),
                       (mediumRows.count, 7), (largeRows.count, 24),
                       (explosionRows.count, 42), (explosionBits.count, 42),
                       (soundRequests.count, 27), (soundSequences.count, 137)]
        guard lengths.allSatisfy({ $0.0 == $0.1 }), sine.allSatisfy({ $0 <= 127 }),
              waveCounts.allSatisfy({ (1...29).contains($0) }),
              extents.allSatisfy({ $0 <= 16 }), initialX.allSatisfy({ $0 < 159 }),
              initialY.allSatisfy({ $0 < 88 }) else { throw Invalid.layout }
        let tables: [[UInt8]] = [waveCounts, initialX, initialY, projectileOffsetX, projectileOffsetY,
                               extents, explosionOffsets, sine, colors, shipRows, smallRows, mediumRows,
                               largeRows, explosionRows, explosionBits, soundRequests, soundSequences]
        let digest = SHA256.hash(data: Data(tables.flatMap { $0 })).map { String(format: "%02x", $0) }.joined()
        guard digest == Self.tableIdentity else { throw Invalid.identity }
    }
    /// Authored $7178/$717B/$7185 table fold, including its byte-edge asymmetry.
    func sineByte(_ angle: UInt8) -> UInt8 {
        let negative = angle & 128 != 0
        var folded = angle & 127
        if folded > 64 { folded = (folded ^ 127) &+ 1 }
        let value = sine[Int(folded)]
        return negative ? (~value) &+ 1 : value
    }
    func shipMask(image: Int) -> [UInt16] {
        guard (0..<19).contains(image) else { return [] }
        return shipRows[(image * 5)..<(image * 5 + 5)].map { UInt16($0) << 8 }
    }
    func asteroidMask(kind: UInt8) -> [UInt16] {
        switch kind {
        case 1: return smallRows.map { UInt16($0) << 8 }
        case 2: return mediumRows.map { UInt16($0) << 8 }
        case 3: return stride(from: 0, to: largeRows.count, by: 2).map {
            UInt16(largeRows[$0]) << 8 | UInt16(largeRows[$0 + 1])
        }
        default: return []
        }
    }
}

/// No replacement RNG is hidden inside the simulation. These are the original
/// RANDOM-read values supplied by a caller, recording or an explicitly provisional driver.
struct Asteroids8BitRandomStream: Codable, Equatable {
    var samples: [UInt8]
    private(set) var consumed: Int = 0
    enum Invalid: Error { case exhausted, size }
    init(samples: [UInt8]) throws {
        guard samples.count <= 65_536 else { throw Invalid.size }
        self.samples = samples
    }
    mutating func next() throws -> UInt8 {
        guard consumed >= 0, consumed < samples.count else { throw Invalid.exhausted }
        defer { consumed += 1 }
        return samples[consumed]
    }
}

struct Asteroids8BitConfiguration: Codable, Equatable {
    // Reachable SELECT values at $74DA: unsupported gaps are deliberately rejected.
    static let selectionValues: [UInt8] = [0, 2] + Array(10...15) + Array(18...23) + Array(28...31)
    var selection: UInt8
    var difficulties: [UInt8] // four independently selected original codes 0...3
    var reflectingEdges: Bool
    var fastAsteroids: Bool
    var players: Int { Int((selection >> 1) & 3) + 1 }
    var mode: UInt8 { selection >> 3 }
    var opponentFire: Bool { selection & 1 != 0 }
    func validate() throws {
        guard Self.selectionValues.contains(selection), difficulties.count == 4,
              difficulties.allSatisfy({ $0 < 4 }) else { throw Asteroids8BitSimulation.Invalid.configuration }
    }
}

struct Asteroids8BitInput: Equatable {
    var joystickNibble: UInt8 = 15
    var fire = false
}

struct Asteroids8BitEntity: Codable, Equatable {
    var motion: Asteroids8BitMotion
    var code: UInt8 = 255
    var x: UInt8 { UInt8(motion.x >> 8) }
    var y: UInt8 { UInt8(motion.y >> 8) }
    var active: Bool { code & 128 == 0 }
    static let empty = Self(motion: Asteroids8BitMotion(x: 0, y: 0, xVelocity: 0, yVelocity: 0))
}

struct Asteroids8BitPlayer: Codable, Equatable {
    var entity: Asteroids8BitEntity
    var heading: UInt8 = 0
    var lives: UInt8 = 4
    var scoreUnits = 0
    var freeShots: UInt8 = 4
    var triggerLatch = false
    var downCounter: UInt8 = 0
    var respawnCounter: UInt8 = 0
    var image = 0
}

struct Asteroids8BitExplosion: Codable, Equatable {
    var x: UInt8, y: UInt8, bitOffset: UInt8
    var remaining: UInt8
    static let empty = Self(x: 0, y: 0, bitOffset: 0, remaining: 0)
}

struct Asteroids8BitSoundChannel: Codable, Equatable {
    var pointer: UInt8 = 0
    var value: UInt8 = 0
    var delay: UInt8 = 0
    var repeats: UInt8 = 0
}

/// Full lifecycle snapshot, bound to one source revision and resource schema.
struct Asteroids8BitSnapshot: Codable, Equatable {
    var schema = 1
    var sourceSHA256 = Asteroids8BitResources.sourceIdentity
    var configuration: Asteroids8BitConfiguration
    var phase: Asteroids8BitSimulation.Phase = .ready
    var paused = false
    var players: [Asteroids8BitPlayer]
    var asteroids: [Asteroids8BitEntity] // source slots 0...29, zero is scratch and never active
    var shots: [Asteroids8BitEntity] // source slots $85...$99 inclusive
    var shotTimers: [UInt8]
    var explosions: [Asteroids8BitExplosion]
    var savedFields: [[Asteroids8BitEntity]] // alternating mode's two original asteroid fields
    var savedWaves: [UInt8] = [0, 0]
    var wave: UInt8 = 0
    var objectLimit = 0
    var asteroidCount = 0
    var currentPlayer = 0
    var switchRequested: UInt8 = 0
    var waveWait: UInt8 = 0
    var transitionFrames: UInt16 = 0
    var pendingPlayer: Int? = nil
    var videoCounter: UInt8 = 0
    var framesIntoPass: UInt8 = 0
    var collisionCursor = 0
    var idleLow: UInt8 = 0
    var idleHigh: UInt8 = 0
    var inactive: UInt8 = 0
    var ufoSmall = false
    var ufoDelay: UInt8 = 0
    var ufoFireCounter: UInt8 = 0
    var ufoMotionDelay: UInt8 = 0
    var ufoMotionPhase: UInt8 = 0
    var ufoVerticalSign: UInt8 = 0
    var beatDelay: UInt8 = 64
    var beatPeriod: UInt8 = 64
    var beatSound: UInt8 = 0
    var ufoSoundDelay: UInt8 = 0
    var sounds: [Asteroids8BitSoundChannel]
    var soundRequests: [UInt8] = []
    var frames: UInt64 = 0
    var randomReads: UInt64 = 0
}

/// Native reconstruction of the source's rules and independent update schedules.
/// The clock is one source VBI per call; region/cadence is the caller's qualification task.
/// Raster contacts use the original masks. Their display-latch timing still needs an
/// original-game comparison; no claim of GTIA behavior is made.
struct Asteroids8BitSimulation {
    enum Phase: String, Codable { case ready, playing, gameOver }
    enum Invalid: Error { case configuration, startup, snapshot, input }
    let resources: Asteroids8BitResources
    private(set) var state: Asteroids8BitSnapshot
    var snapshot: Asteroids8BitSnapshot { state }

    /// $0400/$0600 fractional coordinates are not initialized by the recovered reset.
    /// The caller must make this startup dependency explicit: 30 asteroid + 5 ship pairs.
    init(resources: Asteroids8BitResources, configuration: Asteroids8BitConfiguration,
         startupFractions: [(UInt8, UInt8)]) throws {
        try resources.validate()
        try configuration.validate()
        guard startupFractions.count == 35 else { throw Invalid.startup }
        self.resources = resources
        let entities = startupFractions.map {
            Asteroids8BitEntity(motion: Asteroids8BitMotion(x: UInt16($0.0), y: UInt16($0.1),
                                                         xVelocity: 0, yVelocity: 0))
        }
        state = Asteroids8BitSnapshot(configuration: configuration,
            players: entities.suffix(5).map { Asteroids8BitPlayer(entity: $0) },
            asteroids: Array(entities.prefix(30)), shots: Array(repeating: .empty, count: 21),
            shotTimers: Array(repeating: 0, count: 21), explosions: Array(repeating: .empty, count: 23),
            savedFields: Array(repeating: Array(repeating: .empty, count: 30), count: 2),
            sounds: Array(repeating: Asteroids8BitSoundChannel(), count: 8))
    }

    init(resources: Asteroids8BitResources, snapshot: Asteroids8BitSnapshot) throws {
        try resources.validate()
        try snapshot.configuration.validate()
        let s = snapshot
        guard s.schema == 1, s.sourceSHA256 == Asteroids8BitResources.sourceIdentity,
              s.players.count == 5, s.asteroids.count == 30, s.shots.count == 21,
              s.shotTimers.count == 21, s.savedFields.count == 2,
              s.savedFields.allSatisfy({ $0.count == 30 }), s.savedWaves.count == 2,
              s.savedFields.allSatisfy({ field in
                  field[0].code == 255 && field.dropFirst().allSatisfy {
                      $0.code == 255 || (1...3).contains($0.code & 15) && $0.code & 0xe0 == 0
                  }
              }),
              s.savedWaves.allSatisfy({ $0 <= 7 }), s.wave <= 7,
              s.sounds.count == 8, s.sounds.allSatisfy({ $0.pointer == 0 || Int($0.pointer) + 3 < resources.soundSequences.count || $0.pointer == 253 }),
              s.explosions.count == 23, s.explosions.allSatisfy({ $0.remaining <= 42 && $0.bitOffset < 8 }),
              s.soundRequests.count <= 64, (0...29).contains(s.objectLimit),
              (0...29).contains(s.asteroidCount), (0..<s.configuration.players).contains(s.currentPlayer),
              s.framesIntoPass < 5, (0...29).contains(s.collisionCursor),
              s.players.allSatisfy({ (0..<1_000_000).contains($0.scoreUnits) && (0..<19).contains($0.image) }),
              s.transitionFrames <= 480, s.pendingPlayer == nil || (0...1).contains(s.pendingPlayer!),
              (s.transitionFrames > 0) == (s.pendingPlayer != nil),
              s.asteroids[0].code == 255,
              s.asteroids.dropFirst().allSatisfy({ $0.code == 255 || (1...3).contains($0.code & 15) && $0.code & 0xe0 == 0 }),
              s.shots.allSatisfy({ $0.code == 255 || $0.code <= 4 }),
              s.players.allSatisfy({ [0, 0xb0, 0xe0, 0xf0, 0xff].contains($0.entity.code) }),
              s.asteroids.dropFirst().filter(\.active).count == s.asteroidCount else { throw Invalid.snapshot }
        self.resources = resources
        state = s
    }

    /// Transactional external-sample consumption: exhaustion changes neither game nor stream.
    mutating func start(random: inout Asteroids8BitRandomStream) throws {
        var next = self, supply = random
        try next.startUnchecked(random: &supply)
        self = next
        random = supply
    }
    private mutating func startUnchecked(random: inout Asteroids8BitRandomStream) throws {
        state.phase = .playing
        state.paused = false
        state.inactive = 0
        state.currentPlayer = 0
        state.wave = 0
        state.waveWait = 0
        state.transitionFrames = 0
        state.pendingPlayer = nil
        state.switchRequested = 0
        state.idleLow = 0
        state.idleHigh = 0
        state.shots = Array(repeating: .empty, count: 21)
        state.shotTimers = Array(repeating: 0, count: 21)
        state.explosions = Array(repeating: .empty, count: 23)
        state.savedFields = Array(repeating: Array(repeating: .empty, count: 30), count: 2)
        state.savedWaves = [0, 0]
        state.sounds = Array(repeating: Asteroids8BitSoundChannel(), count: 8)
        state.soundRequests = []
        state.framesIntoPass = 0
        for i in 0..<5 {
            state.players[i].freeShots = 4
            state.players[i].scoreUnits = 0
            state.players[i].lives = i < state.configuration.players ? 4 : 0
            state.players[i].triggerLatch = false
            state.players[i].downCounter = 0
            state.players[i].respawnCounter = 0
            state.players[i].heading = 0
            state.players[i].image = 0
            state.players[i].entity.code = i < state.configuration.players ? 0 : 255
            state.players[i].entity.motion.xVelocity = 0
            state.players[i].entity.motion.yVelocity = 0
            if i < 4 {
                setInteger(&state.players[i].entity.motion.x, resources.initialX[i])
                setInteger(&state.players[i].entity.motion.y, resources.initialY[i])
            }
        }
        if state.configuration.mode == 0 {
            for i in 1..<4 { state.players[i].entity.code = 255 }
        }
        try resetUFO(random: &random)
        try newWave(random: &random)
        // The foreground starts its first asteroid pass immediately after setup.
        try objectPass(random: &random)
    }

    mutating func setPaused(_ value: Bool) { state.paused = value }

    /// One recovered $6F2F callback plus its once-per-frame foreground service.
    mutating func verticalBlank(inputs: [Asteroids8BitInput], random: inout Asteroids8BitRandomStream) throws {
        guard inputs.count == 4, inputs.allSatisfy({ $0.joystickNibble < 16 }) else { throw Invalid.input }
        guard state.phase == .playing else { return }
        var next = self, supply = random
        try next.frame(inputs: inputs, random: &supply)
        self = next
        random = supply
    }
    private mutating func frame(inputs: [Asteroids8BitInput], random: inout Asteroids8BitRandomStream) throws {
        _ = try sample(&random) // $6F30, passed to color routine; that routine does not use it.
        state.frames &+= 1
        state.videoCounter &+= 1
        if state.videoCounter == 0 {
            if state.inactive != 0 { state.inactive = state.inactive == 255 ? 1 : state.inactive &+ 1 }
            state.idleLow &+= 1
            if state.idleLow == 0 {
                state.idleHigh &+= 1
                if state.idleHigh >= 2 { state.inactive &+= 1 }
            }
        }
        guard !state.paused else { return }
        state.soundRequests = []
        if state.waveWait > 0 {
            state.waveWait &-= 1
            if state.waveWait == 0 { try newWave(random: &random) }
        }
        if state.transitionFrames > 0 {
            state.transitionFrames -= 1
            if state.transitionFrames == 240, let next = state.pendingPlayer {
                state.currentPlayer = next
            }
            if state.transitionFrames == 0 { try finishPlayerSwitch(random: &random) }
        }
        let even = state.videoCounter & 1 == 0
        for player in even ? [0, 2] : [1, 3] {
            try updateShip(player, input: inputs[player], random: &random)
        }
        for slot in even ? 10..<20 : 0..<10 { advanceShot(slot) }
        if even { try updateUFO(random: &random) }
        updateBeat()
        // Foreground's asteroid pass uses $50 elapsed>=5. Cooperative original
        // raster work can alter within-frame order; retained here as an explicit limitation.
        state.framesIntoPass &+= 1
        if state.framesIntoPass == 5 {
            state.framesIntoPass = 0
            try objectPass(random: &random)
        } else if state.objectLimit > 0, state.transitionFrames == 0 {
            // The original spins collision checks during its wait; a bounded full
            // scan is equivalent until one contact mutates an object.
            for slot in stride(from: state.objectLimit, through: 1, by: -1) { projectileHit(slot) }
        }
        // Source explosion erasure runs eight bit steps per foreground pass.
        if state.framesIntoPass == 0 || state.waveWait > 0 || state.transitionFrames > 0 {
            // $6E4C visits slots 22...1. Slot zero can be allocated but is never
            // serviced by this loop; preserve that selected-byte behavior.
            for i in 1..<23 {
                state.explosions[i].remaining = state.explosions[i].remaining > 8 ? state.explosions[i].remaining - 8 : 0
            }
        }
        // Sound DLI frequency is not inferred from VBI. advanceSoundCallback()
        // is independent and must be driven from a qualified source schedule.
        if state.players.prefix(state.configuration.players).allSatisfy({ $0.lives == 0 }) {
            state.phase = .gameOver
            state.inactive = 1
        }
    }

    private mutating func objectPass(random: inout Asteroids8BitRandomStream) throws {
        if state.waveWait > 0 || state.transitionFrames > 0 { return }
        if state.objectLimit > 0 {
            for slot in stride(from: state.objectLimit, through: 1, by: -1) {
                guard state.asteroids[slot].active else { continue }
                projectileHit(slot)
                if state.asteroids[slot].code & 16 != 0 {
                    state.asteroids[slot].code &= 0xef
                    try split(slot, random: &random)
                } else {
                    let size = resources.extents[Int(state.asteroids[slot].code & 15)]
                    state.asteroids[slot].motion.advance(size: size, boundary: boundary)
                }
            }
        }
        for i in 0..<5 where state.players[i].entity.code == 0xb0 {
            state.players[i].entity.code = safeToSpawn(state.players[i].entity) ? 0 : 0xf0
        }
        if state.configuration.mode == 0, state.configuration.players > 1, state.switchRequested != 0,
           state.players[state.currentPlayer].lives == 0 || state.players[0].lives > 0 && state.players[1].lives > 0 {
            try switchPlayer(random: &random)
        }
    }

    private var boundary: Asteroids8BitMotion.BoundaryMode { state.configuration.reflectingEdges ? .reflect : .wrap }
    private func setInteger(_ position: inout UInt16, _ value: UInt8) { position = UInt16(value) << 8 | position & 255 }
    private mutating func sample(_ random: inout Asteroids8BitRandomStream) throws -> UInt8 {
        let value = try random.next()
        state.randomReads &+= 1
        return value
    }
    private mutating func spawn(_ entity: inout Asteroids8BitEntity, random: inout Asteroids8BitRandomStream) throws {
        let x = try sample(&random), y = try sample(&random)
        let position = Asteroids8BitMotion.spawnIntegerPosition(xSample: x, ySample: y)
        setInteger(&entity.motion.x, position.x)
        setInteger(&entity.motion.y, position.y)
        try randomVelocity(&entity, random: &random)
    }
    private mutating func randomVelocity(_ entity: inout Asteroids8BitEntity, random: inout Asteroids8BitRandomStream) throws {
        let xm = try sample(&random), ym = try sample(&random), xs = try sample(&random), ys = try sample(&random)
        let velocity = Asteroids8BitMotion.spawnVelocity(xMagnitude: xm, yMagnitude: ym, xSign: xs, ySign: ys,
                                                        fast: state.configuration.fastAsteroids)
        entity.motion.xVelocity = velocity.x
        entity.motion.yVelocity = velocity.y
    }
    private mutating func newWave(random: inout Asteroids8BitRandomStream) throws {
        state.beatPeriod = 64
        state.wave = min(state.wave &+ 1, 7)
        let count = Int(resources.waveCounts[Int(state.wave) - 1])
        state.objectLimit = count
        state.asteroidCount = count
        state.collisionCursor = count
        for i in 1..<30 { state.asteroids[i].code = 255 }
        for i in stride(from: count, through: 1, by: -1) {
            var entity = state.asteroids[i]
            try spawn(&entity, random: &random)
            entity.code = 3
            state.asteroids[i] = entity
        }
    }
    private mutating func split(_ slot: Int, random: inout Asteroids8BitRandomStream) throws {
        explosion(state.asteroids[slot], type: state.asteroids[slot].code)
        state.asteroids[slot].code &-= 1
        if state.asteroids[slot].code == 0 {
            state.asteroids[slot].code = 255
            state.asteroidCount -= 1
            if state.asteroidCount == 0 {
                state.beatPeriod = 240
                state.waveWait = 240 // $6CBC waits 240 VBI callbacks before constructing next wave.
            }
            return
        }
        var first = state.asteroids[slot]
        try randomVelocity(&first, random: &random)
        state.asteroids[slot] = first
        if let available = (1...state.objectLimit).reversed().first(where: { !state.asteroids[$0].active }) {
            var second = first
            try randomVelocity(&second, random: &random)
            state.asteroids[available] = second
            state.asteroidCount += 1
        } else if state.objectLimit < 29 {
            state.objectLimit += 1
            var second = first
            try randomVelocity(&second, random: &random)
            state.asteroids[state.objectLimit] = second
            state.asteroidCount += 1
        }
    }

    private mutating func projectileHit(_ slot: Int) {
        guard state.asteroids[slot].active else { return }
        let object = state.asteroids[slot]
        let extent = resources.extents[Int(object.code & 15)]
        for i in state.shots.indices {
            let shot = state.shots[i]
            if Asteroids8BitCollision.projectileHits(objectCode: object.code, objectX: object.x, objectY: object.y,
                extent: extent, projectileCode: shot.code, projectileX: shot.x, projectileY: shot.y) {
                let owner = Int(shot.code)
                releaseShot(i)
                if owner < 4 {
                    // $6C96 indexed by asteroid type gives small=5, medium=2, large=1.
                    addScore(owner, award: object.code & 15 == 1 ? .five : object.code & 15 == 2 ? .two : .one)
                }
                state.asteroids[slot].code |= 16
                return
            }
        }
    }

    private mutating func releaseShot(_ slot: Int) {
        let owner = Int(state.shots[slot].code)
        guard owner < 5 else { return }
        state.shots[slot].code = 255
        state.players[owner].freeShots &+= 1
    }
    private mutating func advanceShot(_ slot: Int) {
        guard state.shots[slot].active else { return }
        state.shotTimers[slot] &-= 1
        if state.shotTimers[slot] == 0 { releaseShot(slot); return }
        state.shots[slot].motion.advance(size: 0, boundary: boundary)
    }
    private func clampedVelocityHigh(_ value: UInt8) -> UInt8 {
        let negative = value & 128 != 0
        let magnitude = negative ? ~value : value
        let clamped = magnitude & 0xfc != 0 ? UInt8(3) : magnitude
        return negative ? ~clamped : clamped
    }
    private func drag(_ velocity: UInt16) -> UInt16 {
        guard velocity != 0 else { return 0 }
        var low = UInt8(velocity & 255), high = UInt8(velocity >> 8)
        let increment: UInt8 = high & 128 != 0 ? 1 : 255
        low &+= increment
        if low == 0 && high != 0 { high &+= increment }
        return UInt16(high) << 8 | UInt16(low)
    }
    private func accelerated(_ velocity: UInt16, lowAcceleration: UInt8) -> UInt16 {
        let sum = Int(velocity & 255) + Int(lowAcceleration)
        let sign: UInt8 = lowAcceleration & 128 != 0 ? 255 : 0
        let high = UInt8(velocity >> 8) &+ sign &+ (sum > 255 ? 1 : 0)
        return UInt16(clampedVelocityHigh(high)) << 8 | UInt16(sum & 255)
    }
    private func signedNibble(_ value: UInt8) -> UInt8 {
        let nibble = value >> 4
        return nibble & 8 != 0 ? nibble | 0xf0 : nibble
    }
    private func projectileVelocity(_ value: UInt8) -> UInt16 {
        let signed = Int(Int8(bitPattern: value))
        return UInt16(truncatingIfNeeded: signed * 4 + (signed < 0 ? 3 : 0))
    }

    private mutating func updateShip(_ index: Int, input: Asteroids8BitInput,
                                     random: inout Asteroids8BitRandomStream) throws {
        guard index < state.configuration.players,
              state.configuration.mode != 0 || index == state.currentPlayer else { return }
        var player = state.players[index]
        if player.lives == 0 { player.entity.code = 255; state.players[index] = player; return }
        if player.entity.code == 0xf0 {
            if player.respawnCounter != 0 { player.respawnCounter &-= 1 }
            else { player.entity.code = 0xb0; player.respawnCounter = 15; try resetUFO(random: &random) }
            state.players[index] = player
            return
        }
        if player.entity.code == 0xb0 || player.entity.code == 255 { return }
        if player.entity.code == 0xe0 {
            player.image = 18
            player.entity.motion.advance(size: 8, boundary: boundary)
            player.entity.motion.xVelocity = drag(player.entity.motion.xVelocity)
            player.entity.motion.yVelocity = drag(player.entity.motion.yVelocity)
            player.entity.code = 0
            player.downCounter = 1
            try downAction(&player, index: index, input: input, random: &random)
            state.players[index] = player
            return // $677F jumps directly to down-input handling, bypassing fire/collision.
        } else {
            // Image is sampled before the heading update, matching $6782.
            player.image = Int(player.heading &+ 7) >> 4
            player.heading = Asteroids8BitControl.heading(player.heading, joystickNibble: input.joystickNibble)
            try downAction(&player, index: index, input: input, random: &random)
            if Asteroids8BitControl.thrustRequested(joystickNibble: input.joystickNibble) {
                let x = signedNibble(resources.sineByte(player.heading))
                let yNibble = signedNibble(resources.sineByte(player.heading &+ 64))
                let negativeY = (~yNibble) &+ 1
                let y = negativeY &<< 1 | (yNibble == 0 ? 1 : 0) // retained ADC carry into ROL
                player.entity.motion.xVelocity = accelerated(player.entity.motion.xVelocity, lowAcceleration: x)
                player.entity.motion.yVelocity = accelerated(player.entity.motion.yVelocity, lowAcceleration: y)
                requestSound(15)
            }
            player.entity.motion.xVelocity = drag(player.entity.motion.xVelocity)
            player.entity.motion.yVelocity = drag(player.entity.motion.yVelocity)
        }
        state.players[index] = player
        if state.players[index].entity.active {
            if !input.fire { state.players[index].triggerLatch = false }
            else if !state.players[index].triggerLatch {
                state.players[index].triggerLatch = true
                state.idleLow = 0
                fire(index)
            }
            try shipContact(index, random: &random)
            if state.players[index].entity.active {
                state.players[index].entity.motion.advance(size: 8, boundary: boundary)
            }
        }
    }

    private mutating func downAction(_ player: inout Asteroids8BitPlayer, index: Int,
                                      input: Asteroids8BitInput,
                                      random: inout Asteroids8BitRandomStream) throws {
        if input.joystickNibble & 2 == 0 {
            if player.downCounter == 0 { player.downCounter = 10 }
            player.downCounter &-= 1
            if player.downCounter == 0 {
                switch state.configuration.difficulties[index] {
                case 0: player.entity.code = 0xe0
                case 1:
                    let x = try sample(&random), y = try sample(&random)
                    setInteger(&player.entity.motion.x, (x & 63) &+ 41)
                    setInteger(&player.entity.motion.y, (y & 31) &+ 21)
                    player.entity.code = 0xf0
                    player.entity.motion.xVelocity = 0
                    player.entity.motion.yVelocity = 0
                    player.downCounter = 0
                    player.respawnCounter = 100
                case 2: player.heading &+= 127
                default: break
                }
            }
        } else { player.downCounter = 0; player.respawnCounter = 100 }
    }

    private mutating func fire(_ owner: Int) {
        let remaining = state.players[owner].freeShots &- 1
        guard remaining & 128 == 0,
              let slot = state.shots.firstIndex(where: { !$0.active }) else { return }
        state.players[owner].freeShots = remaining
        var shot = state.players[owner].entity
        shot.code = UInt8(owner)
        let image = min(state.players[owner].image, 17)
        setInteger(&shot.motion.x, shot.x &+ resources.projectileOffsetX[image])
        setInteger(&shot.motion.y, shot.y &+ resources.projectileOffsetY[image])
        shot.motion.xVelocity = projectileVelocity(resources.sineByte(state.players[owner].heading))
        shot.motion.yVelocity = projectileVelocity((~resources.sineByte(state.players[owner].heading &+ 64)) &+ 1)
        state.shots[slot] = shot
        state.shotTimers[slot] = owner == 4 ? 27 : 38
        requestSound(owner == 4 ? 0x92 : 0x8c)
        if owner == 4 {
            advanceShot(slot)
            advanceShot(slot)
        }
    }

    private func boxContains(_ object: Asteroids8BitEntity, x: UInt8, y: UInt8, margin: UInt8) -> Bool {
        // $6AD5/$6B39: lower inclusive and upper exclusive; byte arithmetic.
        let upperX = object.x &+ 8 &+ margin
        let lowerX = object.x &+ 3 &- margin
        let upperY = object.y &+ 5 &+ margin
        let lowerY = object.y &- margin
        return x >= lowerX && x < upperX && y >= lowerY && y < upperY
    }
    private func overlappingAsteroid(_ entity: Asteroids8BitEntity, margin: UInt8) -> Int? {
        let upperX = entity.x &+ 8 &+ margin, upperY = entity.y &+ 5 &+ margin
        let sourceX = entity.x &+ 3 &- margin, sourceY = entity.y &- margin
        guard state.objectLimit > 0 else { return nil }
        for slot in stride(from: state.objectLimit, through: 1, by: -1) {
            let asteroid = state.asteroids[slot]
            guard asteroid.active else { continue }
            let extent = resources.extents[Int(asteroid.code & 15)]
            let lowerX = max(0, Int(sourceX) - Int(extent) - 1)
            let lowerY = max(0, Int(sourceY) - Int(extent) - 1)
            if Int(asteroid.x) >= lowerX && asteroid.x < upperX &&
                Int(asteroid.y) >= lowerY && asteroid.y < upperY { return slot }
        }
        return nil
    }
    private func safeToSpawn(_ entity: Asteroids8BitEntity) -> Bool { overlappingAsteroid(entity, margin: 10) == nil }
    private func pixelsOverlap(_ lhs: Asteroids8BitEntity, rows: [UInt16],
                               _ rhs: Asteroids8BitEntity, otherRows: [UInt16]) -> Bool {
        for (r, row) in rows.enumerated() {
            let otherY = Int(lhs.y) + r - Int(rhs.y)
            guard otherY >= 0 && otherY < otherRows.count else { continue }
            for bit in 0..<16 where row & (0x8000 >> bit) != 0 {
                let otherX = Int(lhs.x) + bit - Int(rhs.x)
                if (0..<16).contains(otherX), otherRows[otherY] & (0x8000 >> otherX) != 0 { return true }
            }
        }
        return false
    }
    private mutating func shipContact(_ index: Int, random: inout Asteroids8BitRandomStream) throws {
        let ship = state.players[index].entity
        for slot in state.shots.indices where state.shots[slot].active {
            let owner = Int(state.shots[slot].code)
            guard owner != index, boxContains(ship, x: state.shots[slot].x, y: state.shots[slot].y, margin: 0) else { continue }
            if index != 4 && owner != 4 {
                guard state.configuration.opponentFire else { continue }
                if state.configuration.mode == 3 && owner / 2 == index / 2 { continue }
                addScore(owner, award: .fifty)
            }
            releaseShot(slot)
            if index == 4 { addScore(owner, award: state.ufoSmall ? .twentyFive : .ten) }
            try killShip(index, random: &random)
            return
        }
        guard state.players[index].downCounter == 0 else { return }
        let mask = resources.shipMask(image: state.players[index].image)
        let bitmapContact = state.asteroids.dropFirst().contains { asteroid in
            asteroid.active && pixelsOverlap(ship, rows: mask, asteroid,
                                              otherRows: resources.asteroidMask(kind: asteroid.code & 15))
        }
        if bitmapContact, let slot = overlappingAsteroid(ship, margin: 0) {
            state.asteroids[slot].code |= 16
            if index == 4 { try resetUFO(random: &random) }
            else { try killShip(index, random: &random) }
            return
        }
        // Fifth saucer is authored from hardware missiles; native masks retain
        // the overlapping contact result while original latch timing remains open.
        if index < 4, state.players[4].entity.active,
           pixelsOverlap(ship, rows: mask, state.players[4].entity,
                         otherRows: resources.shipMask(image: state.players[4].image)) {
            try killShip(index, random: &random)
            try resetUFO(random: &random)
        }
    }
    private mutating func killShip(_ index: Int, random: inout Asteroids8BitRandomStream) throws {
        var entity = state.players[index].entity
        entity.code = 2
        explosion(entity, type: 2)
        if index == 4 { try resetUFO(random: &random); return }
        setInteger(&state.players[index].entity.motion.x, resources.initialX[index])
        setInteger(&state.players[index].entity.motion.y, resources.initialY[index])
        if state.configuration.opponentFire {
            let x = try sample(&random), y = try sample(&random)
            // Carry into the death relocation is unresolved across hardware-latch branches.
            setInteger(&state.players[index].entity.motion.x, (x & 63) &+ 40)
            setInteger(&state.players[index].entity.motion.y, (y & 31) &+ 21)
        }
        requestSound(0x98)
        state.players[index].lives &-= 1
        if state.players[index].lives == 0 {
            if state.configuration.mode == 2 {
                for i in 0..<4 { state.players[i].lives = 0 }
            } else if state.configuration.mode == 3 {
                for i in (index / 2 * 2)..<(index / 2 * 2 + 2) { state.players[i].lives = 0 }
            }
        }
        state.switchRequested &+= 1
        state.players[index].entity.code = 0xf0
        state.players[index].entity.motion.xVelocity = 0
        state.players[index].entity.motion.yVelocity = 0
        state.players[index].downCounter = 0
        state.players[index].respawnCounter = 100
    }
    private mutating func addScore(_ index: Int, award: Asteroids8BitScore.Award) {
        guard index < 4 else { return }
        var score = try! Asteroids8BitScore(units: state.players[index].scoreUnits, lives: state.players[index].lives)
        let bonus = score.add(award, difficultyCode: state.configuration.difficulties[index])
        state.players[index].scoreUnits = score.units
        state.players[index].lives = score.lives
        for _ in 0..<bonus { requestSound(0x95) }
    }
    private mutating func explosion(_ entity: Asteroids8BitEntity, type: UInt8) {
        guard let slot = (0..<23).reversed().first(where: { state.explosions[$0].remaining == 0 }) else { return }
        requestSound(0x98)
        if state.beatPeriod > 10 { state.beatPeriod &-= 1 }
        let offset = resources.explosionOffsets[min(Int(type), 3)]
        var x = entity.x &+ offset, y = entity.y &+ offset
        if y & 128 != 0 { y = 0 }
        if x >= 159 { x = 158 }
        if y >= 88 { y = 87 }
        state.explosions[slot] = Asteroids8BitExplosion(x: x & 0xf8, y: y, bitOffset: x & 7, remaining: 42)
    }

    /// XOR pixels from the authored scatter/erase tables. This is a native
    /// bitmap composition operation, not an Atari display-list implementation.
    var explosionPixels: [Int] {
        var pixels = Set<Int>()
        for explosion in state.explosions where explosion.remaining < 42 && explosion.remaining > 0 {
            let base = Int(explosion.y) * 20 + Int(explosion.x) / 8
            for step in Int(explosion.remaining)..<42 {
                let bit = Int(explosion.bitOffset) + Int(resources.explosionBits[step])
                let address = base + Int(resources.explosionRows[step]) + (bit & 0xf8 == 0 ? 0 : 1)
                let index = address * 8 + (bit & 7)
                guard (0..<(160 * 96)).contains(index) else { continue }
                if pixels.contains(index) { pixels.remove(index) } else { pixels.insert(index) }
            }
        }
        return pixels.sorted()
    }

    private mutating func switchPlayer(random: inout Asteroids8BitRandomStream) throws {
        let old = state.currentPlayer
        state.players[old].entity.code = 255
        state.savedFields[old] = state.asteroids
        state.savedWaves[old] = state.wave
        let new = old == 0 ? 1 : 0
        for slot in state.asteroids.indices { state.asteroids[slot].code = 255 }
        state.asteroidCount = 0
        state.pendingPlayer = new
        state.transitionFrames = 480 // two consecutive $6CBC F0 waits around the player announcement
        state.switchRequested = 0
    }

    private mutating func finishPlayerSwitch(random: inout Asteroids8BitRandomStream) throws {
        guard let new = state.pendingPlayer else { return }
        state.pendingPlayer = nil
        state.currentPlayer = new
        state.asteroids = state.savedFields[new]
        state.wave = state.savedWaves[new]
        state.asteroidCount = state.asteroids.dropFirst().filter(\.active).count
        state.objectLimit = state.asteroids.indices.last(where: { state.asteroids[$0].active }) ?? 0
        state.players[new].entity.code = 0xf0
        if state.objectLimit == 0 || state.wave == 0 { try newWave(random: &random) }
    }

    private mutating func resetUFO(random: inout Asteroids8BitRandomStream) throws {
        var ufo = state.players[4].entity
        try spawn(&ufo, random: &random)
        ufo.code = 255
        state.players[4].entity = ufo
        state.players[4].freeShots = 4
        state.ufoSmall = try sample(&random) & state.wave != 0
        state.ufoFireCounter = UInt8(truncatingIfNeeded: (state.configuration.players - 1) << 4) | 0x90
        state.ufoDelay = 0
        state.ufoVerticalSign = 0
    }
    private mutating func updateUFO(random: inout Asteroids8BitRandomStream) throws {
        if !state.players[4].entity.active {
            state.ufoDelay &-= 1
            if state.ufoDelay == 0 { state.players[4].entity.code = 0xb0 }
        }
        guard state.players[4].entity.active else { return }
        state.players[4].image = state.ufoSmall ? 16 : 17
        try shipContact(4, random: &random)
        guard state.players[4].entity.active else { return }
        state.players[4].entity.motion.advance(size: 8, boundary: boundary)
        let add = Int(state.ufoFireCounter) + state.configuration.players // SEC ADC $B0
        var next = add
        if add < 256 && state.ufoSmall { next += state.configuration.players - 1 }
        state.ufoFireCounter = UInt8(truncatingIfNeeded: next)
        if next > 255 {
            state.ufoFireCounter = (try sample(&random) | 0xc0) & 0xdf
            state.players[4].heading = try sample(&random)
            fire(4)
        }
        state.ufoMotionDelay &-= 1
        if state.ufoMotionDelay == 0 {
            state.ufoMotionDelay = try sample(&random) & 63 | 16
            if state.ufoMotionPhase == 0 {
                state.players[4].entity.motion.yVelocity = 0
                state.ufoMotionPhase = 1
            } else {
                state.ufoVerticalSign ^= 255
                let low = (try sample(&random) | 128) ^ state.ufoVerticalSign
                state.players[4].entity.motion.yVelocity = UInt16(state.ufoVerticalSign) << 8 | UInt16(low)
                state.ufoMotionPhase = 0
            }
        }
    }

    private mutating func updateBeat() {
        state.beatDelay &-= 1
        if state.beatDelay == 0 {
            state.beatDelay = state.beatPeriod
            state.beatSound ^= 3
            requestSound(state.beatSound)
        }
        state.ufoSoundDelay &-= 1
        if state.ufoSoundDelay == 0 {
            state.ufoSoundDelay = 10
            if state.players[4].entity.active { requestSound(state.ufoSmall ? 0x86 : 0x89) }
        }
    }
    private mutating func requestSound(_ request: UInt8) {
        if state.inactive != 0 { return }
        if state.soundRequests.count < 64 { state.soundRequests.append(request) }
        let offset = Int(request & 127)
        guard offset + 2 < resources.soundRequests.count else { return }
        let channel = Int(resources.soundRequests[offset])
        guard channel < 7 else { return }
        if state.sounds[channel].pointer != 0 && request & 128 == 0 { return }
        state.sounds[channel].pointer = resources.soundRequests[offset + 1]
        state.sounds[channel + 1].pointer = resources.soundRequests[offset + 2]
        state.sounds[channel].delay = 1
        state.sounds[channel + 1].delay = 1
        state.sounds[channel].repeats = 1
        state.sounds[channel + 1].repeats = 1
    }
    /// One non-color $72D7 source DLI: yields the eight POKEY parameter bytes,
    /// not synthesized audio. The DLI schedule and analog output remain unqualified.
    @discardableResult
    mutating func advanceSoundCallback() -> [UInt8] {
        for i in stride(from: 7, through: 0, by: -1) {
            var channel = state.sounds[i]
            if channel.pointer == 0 { channel.value = 0; state.sounds[i] = channel; continue }
            channel.delay &-= 1
            if channel.delay == 0 {
                channel.repeats &-= 1
                if channel.repeats == 0 {
                    channel.pointer &+= 4
                    let p = Int(channel.pointer)
                    guard p + 3 < resources.soundSequences.count else {
                        state.sounds[i] = Asteroids8BitSoundChannel(); continue
                    }
                    channel.repeats = resources.soundSequences[p + 3]
                    channel.value = resources.soundSequences[p + 1]
                } else {
                    let p = Int(channel.pointer)
                    guard p + 2 < resources.soundSequences.count else {
                        state.sounds[i] = Asteroids8BitSoundChannel(); continue
                    }
                    channel.value &+= resources.soundSequences[p + 2]
                }
                channel.delay = resources.soundSequences[Int(channel.pointer)]
                if channel.delay == 0 { channel.pointer = 0; channel.value = 0 }
            }
            state.sounds[i] = channel
        }
        return state.sounds.map(\.value)
    }
}
