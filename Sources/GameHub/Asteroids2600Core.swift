import Foundation
import CryptoKit

/// Native reconstruction of the selected 8 KiB 2600 cartridge. It operates on
/// named game state and original data tables, without a CPU/TIA interpreter.
struct Asteroids2600Mask: Codable, Equatable {
    var name: String
    var width: Int
    var rows: [UInt8]
    var sourceAddress: String
}

struct Asteroids2600Resources: Codable {
    static let sourceIdentity = "d1a6e808412b4535c7e54fc25414943a9418b1095b4d4969dc33290f7eaa72a4"
    static let contentIdentity = "22d0866eecfa11c3d8d39e7638964ffa12fc44a8c32a65e8645c1708b2b11c5b"
    var schema: Int
    var sourceSHA256: String
    var contentSHA256: String
    var tables: [String: [UInt8]]
    var masks: [Asteroids2600Mask]

    static let tableCounts: [String: Int] = [
        "horizontalIncreasing": 256, "horizontalDecreasing": 256,
        "projectileLifetime": 16, "speedMasks": 16, "horizontalSubtract": 16,
        "horizontalAdd": 16, "randomHorizontalLow": 8, "horizontalHigh": 16,
        "horizontalLow": 16, "verticalExtent": 11, "horizontalExtent": 11,
        "scoreLowBCD": 7, "scoreHighBCD": 7, "topRemoval": 4,
        "bottomDuplicate": 4, "selectionEnd": 4, "selectionStart": 4,
        "thrust": 16, "projectileVertical": 16, "projectileHorizontal": 16,
        "asteroidColor": 8
    ]

    static func load(from url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, (1...64 * 1024).contains(size) else { throw Asteroids2600Error.invalidResources }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 64 * 1024 else { throw Asteroids2600Error.invalidResources }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    func validate() throws {
        guard schema == 1, sourceSHA256 == Self.sourceIdentity,
              tables.count == Self.tableCounts.count,
              Self.tableCounts.allSatisfy({ tables[$0.key]?.count == $0.value }),
              masks.count == 29, Set(masks.map(\.name)).count == 29,
              masks.allSatisfy({ mask in (1...8).contains(mask.width) && (1...15).contains(mask.rows.count)
                  && mask.rows.allSatisfy { Int($0) < (1 << mask.width) } }),
              tables["scoreLowBCD"]!.allSatisfy(Self.isBCD),
              tables["scoreHighBCD"]!.allSatisfy(Self.isBCD) else {
            throw Asteroids2600Error.invalidResources
        }
        let names = Set((0..<9).map { "ship-\($0)" } + (0..<3).map { "explosion-\($0)" }
            + (0..<4).map { "asteroid-\($0)" } + (0..<10).map { "digit-\($0)" }
            + ["shield", "saucer-small", "saucer-large"])
        guard Set(masks.map(\.name)) == names,
              masks.allSatisfy({ mask in
                  let height: Int
                  switch mask.name {
                  case "asteroid-0", "asteroid-1": height = 15
                  case "asteroid-2": height = 7
                  case "asteroid-3": height = 4
                  case "saucer-small": height = 3
                  default: height = 5
                  }
                  return mask.rows.count == height && mask.width == (mask.name.hasPrefix("digit-") ? 3 : 8)
              }),
              (tables["horizontalExtent"]! + tables["verticalExtent"]!).allSatisfy({ $0 <= 36 }) else {
            throw Asteroids2600Error.invalidResources
        }
        guard contentSHA256 == Self.contentIdentity,
              canonicalContentSHA256() == Self.contentIdentity else { throw Asteroids2600Error.invalidResources }
    }

    /// Matching first-party decoder order; JSON formatting cannot affect the hash.
    private func canonicalContentSHA256() -> String {
        var data = Data("GameHub.Asteroids2600.resources.v1\0".utf8)
        for name in tables.keys.sorted() {
            let values = tables[name]!
            data.append(contentsOf: name.utf8); data.append(0)
            var count = UInt32(values.count).littleEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(contentsOf: values)
        }
        for mask in masks.sorted(by: { $0.name < $1.name }) {
            data.append(contentsOf: mask.name.utf8); data.append(0)
            data.append(UInt8(mask.width)); data.append(UInt8(mask.rows.count))
            data.append(contentsOf: mask.rows)
            data.append(contentsOf: mask.sourceAddress.utf8); data.append(0)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func isBCD(_ x: UInt8) -> Bool { x & 15 < 10 && x >> 4 < 10 }
    fileprivate func byte(_ table: String, _ index: Int) -> UInt8 { tables[table]![index] }

    /// $FCCA: recover a pixel coordinate from the TIA-specific positioning byte.
    func horizontalPixel(_ packed: UInt8) -> UInt8 {
        byte("horizontalHigh", Int(packed >> 4)) &+ byte("horizontalLow", Int(packed & 15))
    }
    /// $D600: the source's authored transitions implement horizontal wrap.
    func horizontal(_ packed: UInt8, steps: UInt8, decreasing: Bool) -> UInt8 {
        guard steps != 0 else { return packed }
        let table = tables[decreasing ? "horizontalDecreasing" : "horizontalIncreasing"]!
        var result = packed
        for _ in 0..<steps { result = table[Int(result)] }
        return result
    }
}

enum Asteroids2600Error: Error { case invalidResources, invalidSnapshot, invalidVariation }

struct Asteroids2600Input: Equatable {
    var left = false
    var right = false
    var thrust = false
    var down = false
    var fire = false
    // Source difficulty switches gate saucers independently for each player.
    var saucersEnabled = true
}

struct Asteroids2600Player: Codable, Equatable {
    var livesAndHeading: UInt8 = 0x40
    /// Internal source score units. The original display appends a zero.
    var scoreUnits: Int = 0
    var lives: Int { Int(livesAndHeading >> 4) }
    var heading: UInt8 { livesAndHeading & 15 }
    var points: Int { scoreUnits * 10 }
}

struct Asteroids2600Asteroid: Codable, Equatable {
    var y: UInt8
    var horizontal: UInt8
    var flags: UInt8
    var kind: Int { Int((flags >> 4) & 3) }
    var markedForSplit: Bool { flags & 0x40 != 0 }
}

struct Asteroids2600Projectile: Codable, Equatable {
    var y: UInt8 = 0xe0
    var horizontal: UInt8 = 0
    /// High nibble lifetime; low nibble original heading. Zero is inactive.
    var lifetimeAndHeading: UInt8 = 0
    var active: Bool { lifetimeAndHeading != 0 }
}

struct Asteroids2600Snapshot: Codable, Equatable {
    var schema = 1
    var sourceSHA256 = Asteroids2600Resources.sourceIdentity
    var variation: UInt8
    var players = [Asteroids2600Player(), Asteroids2600Player()]
    var currentPlayer = 0
    var upward: [Asteroids2600Asteroid] = []
    var downward: [Asteroids2600Asteroid] = []
    var random = Asteroids2600Random()
    var frame: UInt16 = 0
    var totalFrames: UInt64 = 0
    var speedCycle: UInt8 = 0x73
    var collisionSchedule: UInt8 = 0
    var pendingSplits = true
    var shipHorizontal: UInt8 = 0x1d
    var shipY: UInt8 = 0x29
    var horizontalFraction: UInt8 = 0
    var verticalFraction: UInt8 = 0
    var velocityHorizontal: UInt16 = 0
    var velocityVertical: UInt16 = 0
    var returnY: UInt8 = 0x29
    /// Source $DE: negative values animate death; positive values delay re-entry.
    var shipDelay: UInt8 = 0
    var deathOrShieldFailure = false
    var shield = false
    var downLatch = false
    var flipLatch = false
    var fireLatch = false
    var projectiles = [Asteroids2600Projectile(), Asteroids2600Projectile(), Asteroids2600Projectile()]
    var saucerHorizontal: UInt8 = 0xc6
    var saucerY: UInt8 = 0xe0
    var saucerFlags: UInt8 = 0
    var saucerCountdown: UInt8 = 0
    var saucerExploding = true
    var saucerExplosionFrame: UInt8 = 0
    var ended = false
    var waves: UInt64 = 0
    var selectionReturn = false
}

enum Asteroids2600Event: Equatable {
    case shot(Int), thrust, hyperspace, shield, shipHit, lifeLost(Int), bonusLife(Int)
    case asteroidHit(Int), saucerHit, wave, playerChanged(Int), ended, selectionReturn
}

struct Asteroids2600Simulation {
    let resources: Asteroids2600Resources
    private(set) var state: Asteroids2600Snapshot
    private var events: [Asteroids2600Event] = []

    init(resources: Asteroids2600Resources, variation: UInt8 = 0,
         random: Asteroids2600Random = .init()) throws {
        try resources.validate()
        guard Self.validVariation(variation) else { throw Asteroids2600Error.invalidVariation }
        self.resources = resources
        state = Asteroids2600Snapshot(variation: variation)
        state.random = random
        spawnWave()
        events.removeAll()
    }

    init(resources: Asteroids2600Resources, snapshot: Asteroids2600Snapshot) throws {
        try resources.validate()
        guard snapshot.schema == 1, snapshot.sourceSHA256 == Asteroids2600Resources.sourceIdentity,
              Self.validVariation(snapshot.variation), snapshot.players.count == 2,
              (0...1).contains(snapshot.currentPlayer), snapshot.upward.count <= 8,
              snapshot.downward.count <= 8, snapshot.projectiles.count == 3,
              snapshot.players.allSatisfy({ $0.lives <= 9 && (0..<10_000).contains($0.scoreUnits) }),
              snapshot.saucerExplosionFrame < 3,
              snapshot.shipY == 0xe0 || snapshot.shipY < 84 || snapshot.shipY >= 251,
              snapshot.saucerY == 0xe0 || snapshot.saucerY < 89,
              (snapshot.upward + snapshot.downward).allSatisfy({ $0.y != 0xe0 }),
              snapshot.projectiles.allSatisfy({ ($0.y < 89 || $0.y == 0xe0)
                  && (!$0.active || ($0.y < 89 && $0.lifetimeAndHeading & 0xf0 != 0)) }),
              snapshot.variation & 0x20 != 0 || snapshot.currentPlayer == 0 else {
            throw Asteroids2600Error.invalidSnapshot
        }
        self.resources = resources
        state = snapshot
    }

    static func validVariation(_ value: UInt8) -> Bool { value < 64 || value == 0x80 || value == 0xa0 }
    var snapshot: Asteroids2600Snapshot { state }
    var player: Asteroids2600Player { state.players[state.currentPlayer] }
    var variationNumber: Int {
        state.variation & 0x80 != 0 ? (state.variation & 0x20 != 0 ? 66 : 33)
            : Int(state.variation) + 1 + (state.variation & 0x20 != 0 ? 1 : 0)
    }
    var twoPlayers: Bool { state.variation & 0x20 != 0 }
    var shipVisible: Bool { state.shipY != 0xe0 }
    var shipMaskName: String {
        if state.shield { return "shield" }
        if state.shipDelay & 0x80 != 0 { return "explosion-\(min(2, Int((state.shipDelay >> 1) & 7)))" }
        let h = Int(player.heading)
        return "ship-\(h > 8 ? 16 - h : h)"
    }
    var shipReflected: Bool { state.shipDelay & 0x80 == 0 && !state.shield && player.heading >= 8 }

    mutating func takeEvents() -> [Asteroids2600Event] {
        let result = events; events.removeAll(keepingCapacity: true); return result
    }

    /// One original frame dispatcher. The caller must qualify its display cadence;
    /// no host-time-derived invented physics or instruction execution is used.
    mutating func frame(input: Asteroids2600Input = .init()) {
        guard !state.selectionReturn else { return }
        resolvePreviousFrame()
        state.frame &+= 1
        state.totalFrames &+= 1
        if state.frame & 255 == 0, state.ended {
            if state.frame >> 8 & 0x80 != 0 {
                state.selectionReturn = true; emit(.selectionReturn)
            }
            if twoPlayers { exchangePlayers() }
        }
        _ = state.random.next()
        if state.frame & 1 != 0 {
            advanceAsteroids()
            advanceSaucer(enabled: input.saucersEnabled)
        } else {
            advanceShip(input)
            advanceProjectiles()
        }
        // The event buffer is an adapter convenience and is excluded from saves.
        // Bound it even if a caller neglects to consume audio/gameplay events.
        if events.count > 128 { events.removeFirst(events.count - 128) }
    }

    private mutating func emit(_ event: Asteroids2600Event) { events.append(event) }
    private mutating func exchangePlayers() {
        state.currentPlayer ^= 1
        emit(.playerChanged(state.currentPlayer))
    }

    // $FDF3/$FE16: wave density changes with the source score's high BCD byte,
    // rather than with an invented increasing wave number.
    private mutating func spawnWave() {
        let high = player.scoreUnits / 100
        let count = state.variation & 0x80 != 0 || high == 0 ? 2 : (high < 15 ? 3 : 4)
        func positions(_ down: Bool) -> [UInt8] {
            if count == 2 { return [1, 63] }
            if count == 3 { return [1, down ? 21 : 42, 63] }
            return [1, 21, 42, 63]
        }
        state.upward.removeAll(keepingCapacity: true)
        state.downward.removeAll(keepingCapacity: true)
        for down in [false, true] {
            var values: [Asteroids2600Asteroid] = []
            for (index, y) in positions(down).enumerated() {
                let x: UInt8
                if index == 0 || y == 63 { x = randomHorizontal() }
                else { x = state.random.next() & 0xe0 | 10 }
                values.append(.init(y: y, horizontal: x, flags: state.random.next() & 0x1f))
            }
            if down { state.downward = values } else { state.upward = values }
        }
        state.waves &+= 1
        emit(.wave)
    }

    private func randomHorizontal() -> UInt8 {
        var high = state.random.high & 0xf0
        if high == 0x70 { high = 0x80 }
        return high | resources.byte("randomHorizontalLow", Int(state.random.high & 7))
    }

    private mutating func resolvePreviousFrame() {
        if state.upward.isEmpty && state.downward.isEmpty { spawnWave(); return }
        if state.pendingSplits {
            processSplits(upward: true); processSplits(upward: false)
            state.pendingSplits = false
            return
        }
        if state.shipY == 0xe0 && state.shipDelay == 0 && !state.shield && !state.ended {
            if !state.deathOrShieldFailure || (state.saucerY == 0xe0
                && !state.projectiles[2].active && spawnClear()) {
                state.shipY = state.returnY
                state.verticalFraction = 0; state.horizontalFraction = 0
                state.velocityVertical = 0; state.velocityHorizontal = 0
                if !twoPlayers { state.players[1].livesAndHeading = 0 }
                else if state.deathOrShieldFailure && state.players[1 - state.currentPlayer].lives > 0 {
                    exchangePlayers()
                    state.upward.removeAll(); state.downward.removeAll()
                }
                return
            }
        }
        if state.shield || state.ended {
            if state.saucerY == 0xe0 && !state.projectiles.contains(where: \.active) { return }
        } else if state.shipY == 0xe0 && state.saucerY == 0xe0
            && !state.projectiles.contains(where: \.active) { return }
        // $F152 retries inactive slots within the same dispatcher; this is not
        // one collision check per frame with empty checks consuming a frame.
        for _ in 0..<8 {
        let schedule = state.collisionSchedule
        if schedule & 0x80 != 0 {
            state.collisionSchedule ^= 0xc0
            let slot = schedule & 0x40 != 0 ? 0 : 1
            if state.projectiles[slot].active {
                checkAsteroids(type: 7 + slot, y: state.projectiles[slot].y,
                               x: state.projectiles[slot].horizontal)
                if state.saucerY != 0xe0 {
                    collide(type: 7 + slot, y: state.projectiles[slot].y, x: state.projectiles[slot].horizontal,
                            otherType: saucerType, otherY: state.saucerY, otherX: state.saucerHorizontal)
                }
                return
            }
            continue
        }
        var next = schedule &+ 1
        if next & 3 == 3 { next &= 0xfc }
        state.collisionSchedule = next | 0x80
        switch schedule & 3 {
        case 0:
            if state.projectiles[2].active {
                checkAsteroids(type: 9, y: state.projectiles[2].y, x: state.projectiles[2].horizontal)
                if shipVisible && !state.shield && state.shipDelay & 0x80 == 0 {
                    collide(type: 9, y: state.projectiles[2].y, x: state.projectiles[2].horizontal,
                            otherType: 4, otherY: state.shipY, otherX: state.shipHorizontal)
                }
                return
            }
        case 1:
            if state.saucerY != 0xe0 {
                checkAsteroids(type: saucerType, y: state.saucerY, x: state.saucerHorizontal)
                return
            }
        default:
            if state.shield { continue }
            if state.shipDelay & 0x80 == 0 {
                checkAsteroids(type: 4, y: state.shipY, x: state.shipHorizontal)
                if state.saucerY != 0xe0 {
                    collide(type: 4, y: state.shipY, x: state.shipHorizontal,
                            otherType: saucerType, otherY: state.saucerY, otherX: state.saucerHorizontal)
                }
            }
            return
        }
        }
    }

    private var saucerType: Int { state.saucerFlags & 0x20 != 0 ? 5 : 6 }

    /// $FEA9: source re-entry obstruction check uses positioning-byte lanes.
    private func spawnClear() -> Bool {
        !(state.upward + state.downward).contains {
            let lane = $0.horizontal & 15
            if lane == 13 { return $0.y >= 8 && $0.y < 64 }
            if lane == 11 || lane == 2 { return $0.y >= 24 && $0.y < 56 }
            return false
        }
    }

    /// $FBA9. Both ADC carry-ins after CMP are retained. Extents are source
    /// tables, and all sums wrap as bytes before inclusive-edge comparison.
    func contact(type: Int, y: UInt8, x: UInt8,
                 otherType: Int, otherY: UInt8, otherX: UInt8) -> Bool {
        guard (0...10).contains(type), (0...10).contains(otherType) else { return false }
        let aY = y &+ 17, bY = otherY &+ 17
        let vertical = bY >= aY
            ? aY &+ resources.byte("verticalExtent", type) &+ 1 >= bY
            : bY &+ resources.byte("verticalExtent", otherType) >= aY
        guard vertical else { return false }
        let aX = resources.horizontalPixel(x), bX = resources.horizontalPixel(otherX)
        return bX >= aX
            ? aX &+ resources.byte("horizontalExtent", type) &+ 1 >= bX
            : bX &+ resources.byte("horizontalExtent", otherType) >= aX
    }

    private mutating func checkAsteroids(type: Int, y: UInt8, x: UInt8) {
        for up in [true, false] {
            let list = up ? state.upward : state.downward
            var found = false
            for (index, object) in list.enumerated() where !object.markedForSplit {
                let shifted = object.y &+ 17
                let first = y &+ 17
                let last = first &+ resources.byte("verticalExtent", type)
                if shifted & 0x80 == 0 && !(shifted < last && shifted &+ 15 >= first) { continue }
                if contact(type: type, y: y, x: x, otherType: object.kind,
                           otherY: object.y &+ 3, otherX: object.horizontal) {
                    found = true
                    if collisionEffects(type: type, otherType: object.kind) {
                        if up { state.upward[index].flags |= 0x44 }
                        else { state.downward[index].flags |= 0x44 }
                        state.pendingSplits = true
                        emit(.asteroidHit(object.kind))
                    }
                    break
                }
            }
            // $FB3C/$FB8C: the clipped pair represents the same asteroid.
            if up, (state.upward.first?.y ?? 0) < 0x80 { if found { return }; continue }
            if !up, (state.downward.first?.y ?? 0) < 0x80 { if found { return }; continue }
            // Only the pair at the two ends is linked by the source routine.
            let marked = up ? ((state.upward.first?.flags ?? 0) | (state.upward.last?.flags ?? 0)) & 0x40 != 0
                : ((state.downward.first?.flags ?? 0) | (state.downward.last?.flags ?? 0)) & 0x40 != 0
            if marked {
                if up, !state.upward.isEmpty {
                    state.upward[0].flags |= 0x44; state.upward[state.upward.count - 1].flags = state.upward[0].flags
                } else if !state.downward.isEmpty {
                    state.downward[0].flags |= 0x44; state.downward[state.downward.count - 1].flags = state.downward[0].flags
                }
            }
            if found { return }
        }
    }

    private mutating func collide(type: Int, y: UInt8, x: UInt8,
                                  otherType: Int, otherY: UInt8, otherX: UInt8) {
        if contact(type: type, y: y, x: x, otherType: otherType, otherY: otherY, otherX: otherX) {
            _ = collisionEffects(type: type, otherType: otherType)
        }
    }

    private mutating func collisionEffects(type: Int, otherType: Int) -> Bool {
        if type == 5 || type == 6 || otherType == 5 || otherType == 6 {
            if state.saucerExploding { return false }
            state.saucerExploding = true; state.saucerExplosionFrame = 0; emit(.saucerHit)
        }
        if type == 4 || (type == 9 && otherType == 4) {
            if state.shipDelay & 0x80 != 0 { return false }
            state.deathOrShieldFailure = true; state.shipDelay = 0x80; emit(.shipHit)
        }
        if type >= 7 || otherType == 9 {
            let slot = otherType == 9 && type < 7 ? 2 : type - 7
            if (0..<3).contains(slot) { state.projectiles[slot].lifetimeAndHeading = 0 }
        }
        if type != 9 && type != 5 && type != 6 && otherType < 7 { award(otherType) }
        return true
    }

    // $FC71–$FCC3: BCD carry, source bonus option and nine-life saturation.
    private mutating func award(_ kind: Int) {
        let lo = resources.byte("scoreLowBCD", kind), hi = resources.byte("scoreHighBCD", kind)
        let units = Int(lo >> 4) * 10 + Int(lo & 15) + Int(hi >> 4) * 1000 + Int(hi & 15) * 100
        let old = player.scoreUnits
        state.players[state.currentPlayer].scoreUnits = (old + units) % 10_000
        let oldHigh = old / 100, newHigh = player.scoreUnits / 100
        guard oldHigh != newHigh else { return }
        let highBCD = UInt8((newHigh / 10) * 16 + newHigh % 10)
        let option = state.variation & 6
        let bonus = option == 0 ? (highBCD & 15 == 0 || highBCD & 15 == 5)
            : option == 2 ? highBCD & 15 == 0
            : option == 4 ? highBCD & 31 == 0 : false
        if bonus, player.lives < 9 {
            state.players[state.currentPlayer].livesAndHeading &+= 0x10
            emit(.bonusLife(state.currentPlayer))
        }
    }

    private mutating func advanceAsteroids() {
        var cycle = state.speedCycle &- 0x11
        var speed = 0
        if cycle < 16 { cycle |= 0x70; speed += 2 }
        if cycle & 15 == 0 { cycle |= 3; speed += 1 }
        state.speedCycle = cycle
        let mask = UInt8(speed << 6)
        for index in state.downward.indices {
            state.downward[index].y &+= 1
            advanceHorizontal(&state.downward[index], mask: mask)
        }
        while let last = state.downward.last, last.y >= 89 { state.downward.removeLast() }
        if let last = state.downward.last,
           last.y == resources.byte("bottomDuplicate", last.kind), state.downward.count < 8 {
            var copy = last; copy.y &-= 89; state.downward.insert(copy, at: 0)
        }
        var index = 0
        while index < state.upward.count {
            if state.upward[index].y == 0 {
                var copy = state.upward[index]; copy.y = 89
                if state.upward.count < 8 { state.upward.append(copy) }
            } else if state.upward[index].y & 0x80 != 0 {
                state.upward[0].y &-= 1
                if state.upward[0].y == resources.byte("topRemoval", state.upward[0].kind) {
                    state.upward.removeFirst()
                }
                break
            }
            state.upward[index].y &-= 1
            advanceHorizontal(&state.upward[index], mask: mask)
            index += 1
        }
    }

    private func advanceHorizontal(_ object: inout Asteroids2600Asteroid, mask: UInt8) {
        let index = state.variation & 1 == 0 ? Int((object.flags >> 4) & 7) : Int(object.flags >> 4)
        let required = state.variation & 0x80 != 0 ? 0x80 : resources.byte("speedMasks", index)
        guard required == 0 || required & mask != 0 else { return }
        object.horizontal = asteroidHorizontal(object.horizontal, increasing: object.flags & 8 != 0)
    }

    private func asteroidHorizontal(_ packed: UInt8, increasing: Bool) -> UInt8 {
        if !increasing {
            let result = packed &- 16
            if result == 0x93 { return 0x65 }
            if result < 0x70 || result >= 0x80 { return result }
            let transformed = resources.byte("horizontalSubtract", Int(result & 15))
            if transformed != 0 { return transformed }
        }
        let result = packed &+ 16
        if result == 0x42 { return 0x8d }
        if result >= 0x70 && result < 0x80 { return resources.byte("horizontalAdd", Int(result & 15)) }
        return result
    }

    // $FCE7–$FDDE. Hit processing is deferred and preserves list capacity,
    // secondary-asteroid offset, type transitions and opposite travel flags.
    private mutating func processSplits(upward: Bool) {
        var list = upward ? state.upward : state.downward
        var index = 0
        while index < list.count {
            let original = list[index]
            guard original.markedForSplit else { index += 1; continue }
            if original.y & 0x80 != 0 || original.kind == 3 {
                list.remove(at: index); continue
            }
            let nextKind = original.kind == 2 ? 3 : 2
            list[index].flags = state.random.next() & 0x8f | UInt8(nextKind << 4)
            let wrapThreshold: UInt8 = nextKind == 3 ? 86 : 83
            if original.y >= wrapThreshold, list.count < 8 {
                var clipped = list[index]; clipped.y &-= 89
                list.insert(clipped, at: 0); index = 0
            }
            if nextKind == 2 && state.variation & 0x80 == 0 && list.count < 7 {
                var second = list[index]
                second.flags = (state.random.next() & 0x87 | 0x20 | (second.flags & 8)) ^ 8
                second.y &+= 10
                if list[index].y & 0x80 == 0 && list[index].y >= 79 {
                    second.y &-= 89; list.insert(second, at: 0); index = 0
                } else {
                    list.insert(second, at: index + 1)
                    index += 1
                    if second.y >= 83, list.count < 8 {
                        var clipped = second; clipped.y &-= 89
                        list.insert(clipped, at: 0); index = 0
                    }
                }
            }
            index += 1
        }
        if upward { state.upward = list } else { state.downward = list }
    }

    private mutating func advanceSaucer(enabled: Bool) {
        guard enabled else { state.saucerY = 0xe0; return }
        if state.saucerY == 0xe0 {
            guard shipVisible, state.frame >> 8 >= 4 else { return }
            state.saucerCountdown &-= 1
            guard state.saucerCountdown == 0 else { return }
            let sample = state.random.next()
            var y = sample >> 1
            state.saucerFlags = (state.saucerFlags & 0xf8) | (y & 6) | (sample & 1)
            if y > 79 { y &-= 79 }
            state.saucerY = y; state.saucerHorizontal = 0xba
            let high = player.scoreUnits / 100
            var small = high >= 15
            if high >= 7 && high < 15 { small = state.random.next() & 1 == 0 }
            if small { state.saucerFlags |= 0x20 } else { state.saucerFlags &= 0xdf }
            return
        }
        let vertical = state.saucerFlags & 6
        if vertical == 2 { state.saucerY &-= 1 }
        else if vertical == 4 { state.saucerY &+= 1 }
        if vertical == 2 || vertical == 4 {
            if state.saucerY == 0 || state.saucerY == 79 { state.saucerFlags ^= 6 }
            else if UInt8(truncatingIfNeeded: state.frame) & 0x7f == 0 {
                state.saucerFlags = (state.saucerFlags & 0xf9) | (state.random.next() & 6)
            }
        }
        state.saucerHorizontal = asteroidHorizontal(state.saucerHorizontal,
                                                     increasing: state.saucerFlags & 1 != 0)
        if state.saucerHorizontal == 0xba { state.saucerY = 0xe0; state.saucerCountdown = 0; return }
        guard !state.projectiles[2].active else { return }
        let sample = state.random.next()
        var heading = sample & 15
        if saucerType == 5 {
            let sx = resources.horizontalPixel(state.saucerHorizontal)
            let px = resources.horizontalPixel(state.shipHorizontal)
            var quadrant: UInt8 = px >= sx ? 8 : 0
            if state.shipY >= state.saucerY {
                if quadrant == 0 { quadrant &+= 4 }
            } else if quadrant != 0 { quadrant &+= 4 }
            heading = quadrant &+ (sample & 3)
        }
        state.projectiles[2] = .init(y: state.saucerY &+ 3, horizontal: state.saucerHorizontal,
                                    lifetimeAndHeading: heading | resources.byte("projectileLifetime", Int(heading)))
        emit(.shot(2))
    }

    private mutating func advanceShip(_ input: Asteroids2600Input) {
        if state.players.allSatisfy({ $0.lives == 0 }) {
            if !state.ended { state.ended = true; state.frame = 0x0100; emit(.ended) }
        } else if state.shield {
            if !input.down { state.shield = false; controlShip(input) }
            else {
                state.shipDelay &+= 1
                if state.shipDelay & 31 == 0 {
                    state.shield = false; state.deathOrShieldFailure = true
                    state.shipDelay = 0x80; emit(.shipHit)
                }
                dragAndMove()
            }
        } else if !shipVisible {
            if state.shipDelay != 0 { state.shipDelay &-= 1 }
        } else if state.shipDelay & 0x80 == 0 {
            if state.shipDelay != 0 { state.shipDelay &-= 1 }
            controlShip(input)
        }
        // $F834: the source explosion stream advances on even frames.
        if state.saucerExploding {
            state.saucerExplosionFrame &+= 1
            if state.saucerExplosionFrame == 3 {
                state.saucerExploding = false; state.saucerExplosionFrame = 0
                state.saucerY = 0xe0; state.saucerCountdown = 0
            }
        }
        if state.shipDelay & 0x80 != 0 {
            state.shipDelay &+= 1
            if (state.shipDelay >> 1) & 7 == 3 {
                state.shipY = 0xe0; state.shipDelay = 63
                state.shipHorizontal = 0x1d; state.returnY = 41
                let lives = player.lives
                if lives > 0 { state.players[state.currentPlayer].livesAndHeading = UInt8((lives - 1) << 4) }
                emit(.lifeLost(state.currentPlayer))
            }
        }
    }

    private mutating func controlShip(_ input: Asteroids2600Input) {
        // Only the exact down-only nibble ($D0) enables special controls.
        if input.down && !input.left && !input.right && !input.thrust {
            switch state.variation & 0x18 {
            case 0:
                if state.downLatch && shipVisible {
                    state.shipY = 0xe0; state.downLatch = false; state.deathOrShieldFailure = false
                    state.shipHorizontal = randomHorizontal()
                    state.returnY = state.random.low >> 1
                    if state.returnY >= 79 { state.returnY &-= 79 }
                    state.velocityHorizontal = 0; state.velocityVertical = 0
                    state.horizontalFraction = 0; state.verticalFraction = 0
                    state.shipDelay = 31; emit(.hyperspace); return
                }
                state.downLatch = true
            case 8: state.shield = true; state.shipDelay &+= 1; emit(.shield)
            case 16:
                if !state.flipLatch {
                    state.players[state.currentPlayer].livesAndHeading ^= 8; state.flipLatch = true
                }
            default: state.downLatch = false; state.flipLatch = false; state.deathOrShieldFailure = false
            }
        } else { state.shield = false; state.downLatch = false; state.flipLatch = false; state.deathOrShieldFailure = false }
        if state.frame & 2 != 0 {
            var heading = player.heading
            if input.right { heading &-= 1 }
            if input.left { heading &+= 1 }
            state.players[state.currentPlayer].livesAndHeading = UInt8(player.lives << 4) | (heading & 15)
        }
        if !input.fire { state.fireLatch = false }
        else if !state.fireLatch {
            state.fireLatch = true
            let slot = !state.projectiles[1].active ? 1 : (!state.projectiles[0].active ? 0 : -1)
            if slot >= 0 {
                let heading = player.heading
                state.projectiles[slot] = .init(y: state.shipY &+ 3, horizontal: state.shipHorizontal,
                    lifetimeAndHeading: heading | resources.byte("projectileLifetime", Int(heading & 7)))
                emit(.shot(slot))
            }
        }
        if input.thrust {
            state.velocityVertical &+= UInt16(bitPattern: Int16(Int8(bitPattern: resources.byte("thrust", Int(player.heading)))))
            state.velocityHorizontal &+= UInt16(bitPattern: Int16(Int8(bitPattern: resources.byte("thrust", Int((player.heading &+ 4) & 15)))))
            emit(.thrust); moveShip()
        } else { dragAndMove() }
    }

    /// $F7B9: sign-dependent byte drag, not a host floating-point coefficient.
    private func drag(_ value: UInt16) -> UInt16 {
        guard value != 0 else { return value }
        let high = UInt8(truncatingIfNeeded: value >> 8), low = UInt8(truncatingIfNeeded: value)
        let amount = ~(high &<< 1)
        let carry = amount & 0x80 == 0 ? 1 : 0
        let sum = Int(low) + Int(amount) + carry
        let nextHigh = high &+ (amount & 0x80 == 0 ? 0 : 0xff) &+ UInt8(sum >> 8)
        return UInt16(nextHigh) << 8 | UInt16(UInt8(truncatingIfNeeded: sum))
    }
    private mutating func dragAndMove() {
        state.velocityHorizontal = drag(state.velocityHorizontal)
        state.velocityVertical = drag(state.velocityVertical)
        moveShip()
    }

    /// $F7D7: preserve the limiter and pre-limiter displacement bytes.
    private func displacement(_ velocity: inout UInt16, fraction: inout UInt8) -> Int {
        let high = UInt8(truncatingIfNeeded: velocity >> 8), low = UInt8(truncatingIfNeeded: velocity)
        if ((high &<< 1) ^ high) & 0x80 != 0 {
            velocity = UInt16(high ^ 0x7f) << 8 | UInt16(low)
        }
        let sum = Int(fraction) + Int((high &<< 4) | (low >> 4))
        fraction = UInt8(truncatingIfNeeded: sum)
        return Int(Int8(bitPattern: (high >> 4) | (high & 0x80 != 0 ? 0xf0 : 0))) + (sum >> 8)
    }
    private mutating func moveShip() {
        let dy = displacement(&state.velocityVertical, fraction: &state.verticalFraction)
        state.shipY &+= UInt8(truncatingIfNeeded: dy)
        // $F8D5 preserves the five clipped rows above the display. Positive
        // row 84 wraps to -5, rather than waiting for row 89.
        if state.shipY != 0xe0 {
            if state.shipY & 0x80 != 0 {
                if state.shipY < 251 { state.shipY &+= 89 }
            } else if state.shipY >= 84 { state.shipY &-= 89 }
        }
        let dx = displacement(&state.velocityHorizontal, fraction: &state.horizontalFraction)
        let sourceStep = abs(dx)
        if sourceStep != 0 {
            state.shipHorizontal = resources.horizontal(state.shipHorizontal,
                steps: UInt8(truncatingIfNeeded: abs(sourceStep)), decreasing: dx >= 0)
        }
    }

    /// $F921: three independent slots, lifetime reduction every fourth frame,
    /// source inherited ship velocity (including the saucer projectile).
    private mutating func advanceProjectiles() {
        for slot in (0..<3).reversed() {
            if !state.projectiles[slot].active {
                state.projectiles[slot].y = 0xe0
                state.projectiles[slot].horizontal = slot == 2 ? state.saucerHorizontal : state.shipHorizontal
                state.projectiles[slot].horizontal = resources.horizontal(state.projectiles[slot].horizontal,
                                                                          steps: 2, decreasing: false)
                continue
            }
            if state.frame & 2 == 0 {
                state.projectiles[slot].lifetimeAndHeading &-= 16
                if state.projectiles[slot].lifetimeAndHeading & 0xf0 == 0 {
                    state.projectiles[slot].lifetimeAndHeading = 0
                    state.projectiles[slot].y = 0xe0
                    state.projectiles[slot].horizontal = slot == 2 ? state.saucerHorizontal : state.shipHorizontal
                    state.projectiles[slot].horizontal = resources.horizontal(state.projectiles[slot].horizontal,
                                                                              steps: 2, decreasing: false)
                    continue
                }
            }
            let heading = Int(state.projectiles[slot].lifetimeAndHeading & 15)
            func inherited(_ value: UInt16) -> Int {
                let high = UInt8(truncatingIfNeeded: value >> 8)
                return high & 0x80 != 0 ? Int(Int8(bitPattern: (high >> 4) | 0xf0)) + 1 : Int(high >> 4)
            }
            let dy = inherited(state.velocityVertical) + Int(Int8(bitPattern: resources.byte("projectileVertical", heading)))
            var y = state.projectiles[slot].y &+ UInt8(truncatingIfNeeded: dy)
            if y & 0x80 != 0 { y &+= 89 }
            else if y >= 89 { y &-= 89 }
            state.projectiles[slot].y = y
            let dx = inherited(state.velocityHorizontal) + Int(Int8(bitPattern: resources.byte("projectileHorizontal", heading)))
            // $F99D sets carry before EOR/ADC #1; a negative step becomes
            // one's complement plus two, preserving its unusual extra pixel.
            let step = dx < 0 ? -dx + 1 : dx
            if step != 0 {
                state.projectiles[slot].horizontal = resources.horizontal(state.projectiles[slot].horizontal,
                    steps: UInt8(truncatingIfNeeded: abs(step)), decreasing: dx >= 0)
            }
        }
    }
}
