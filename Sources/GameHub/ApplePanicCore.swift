import Foundation

/// Native, source-grounded development reconstruction. No original CPU executes.
/// Source instruction windows and every remaining approximation are recorded in
/// docs/research/APPLE-PANIC.md. Prepared source-owned media remain outside Git.
enum ApplePanicInput: Int, Codable, CaseIterable {
    case none = 0, right, left, up, down, dig, fill
}
enum ApplePanicPhase: String, Codable { case playing, gameOver, completed }
struct ApplePanicLadder: Codable, Equatable { var x: Int; var top: Int; var bottom: Int }
struct ApplePanicPosition: Codable, Equatable { var x: Int; var y: Int }
struct ApplePanicSprite: Codable { var width: Int; var height: Int; var rows: [UInt32]; var address: String }
struct ApplePanicResources: Codable {
    static let sourceIdentity = "ce05dc96aa47b5da90e55d49124bdd7f2fc3ec135f43b06d7f96ad95dba53abb"
    var schema: Int
    var sourceSHA256: String
    var layouts: [[ApplePanicLadder]]
    var spawns: [[ApplePanicPosition]]
    var enemyCounts: [Int]
    var enemyTypes: [[Int]]
    var initialBackgroundIndex: Int
    var sprites: [String: ApplePanicSprite]

    static func load(url: URL) throws -> ApplePanicResources {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 256 * 1024 else { throw ApplePanicError.invalidResources }
        let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try result.validate()
        return result
    }
    func validate() throws {
        guard schema == 1, sourceSHA256 == Self.sourceIdentity,
              layouts.count == 4, layouts.allSatisfy({ !$0.isEmpty && $0.count <= 15 }),
              spawns.count == 4, spawns.allSatisfy({ $0.count == 8 }),
              enemyCounts == [3, 5, 8], enemyTypes.count == 16,
              enemyTypes.allSatisfy({ $0.count == 8 && $0.allSatisfy { (0...2).contains($0) } }),
              (0...255).contains(initialBackgroundIndex), sprites.count <= 32 else { throw ApplePanicError.invalidResources }
        for layout in layouts {
            guard layout.allSatisfy({ (1...130).contains($0.x) && (15...175).contains($0.top) &&
                (15...175).contains($0.bottom) && $0.top < $0.bottom && ($0.top & 31) == 15 && ($0.bottom & 31) == 15 }) else { throw ApplePanicError.invalidResources }
        }
        for spawn in spawns {
            guard spawn.allSatisfy({ (0...132).contains($0.x) && (6...166).contains($0.y) && (($0.y - 6) & 31) == 0 }) else { throw ApplePanicError.invalidResources }
        }
        guard sprites.values.allSatisfy({ $0.width == 21 && [10, 16].contains($0.height) &&
            $0.rows.count == $0.height && $0.rows.allSatisfy { $0 < (1 << 21) } }) else { throw ApplePanicError.invalidResources }
    }
}
enum ApplePanicError: Error { case invalidResources, invalidSnapshot }
struct ApplePanicPlayer: Codable, Equatable {
    var x = 68, y = 160
    var action = ApplePanicInput.right
    var facingRight = true
    var onGround = true
    var actionFrame = 0
    var alternateSprite = false
}
struct ApplePanicHole: Codable, Equatable {
    var x: Int
    /// Original table base index: player top + 15. Pixel cut begins at row + 1.
    var row: Int
    var depth: Int
    var occupied = false
}
struct ApplePanicEnemy: Codable, Equatable {
    var kind: Int
    var x: Int
    var y: Int
    var active = true
    var direction = ApplePanicInput.none
    var trapped = false
    var trappedTicks = 0
    var holeRow: Int? = nil
    var alternateSprite = false
}
struct ApplePanicState: Codable, Equatable {
    var level = 1, score = 0, highScore = 0, lives = 3
    var hourglass = 130, hourglassCounter = 0, bonus = 2000, bonusCounter = 0
    var backgroundIndex = 0, layoutIndex = 0, spawnIndex = 0
    var player = ApplePanicPlayer()
    var enemies: [ApplePanicEnemy] = []
    var holes: [ApplePanicHole] = []
    var enemyCursor = 0
    var lifeSerial = 0
    var dispatcherHalf = 0
    var extraLifeAwarded = false
    var phase = ApplePanicPhase.playing
    var randomState: UInt64 = 1
    var steps: UInt64 = 0
}
struct ApplePanicSnapshot: Codable {
    var schema = 1
    var sourceSHA256 = ApplePanicResources.sourceIdentity
    var state: ApplePanicState
}

struct ApplePanicSimulation {
    let resources: ApplePanicResources
    private(set) var state: ApplePanicState
    var ladders: [ApplePanicLadder] { resources.layouts[state.layoutIndex] }
    var snapshot: ApplePanicSnapshot { ApplePanicSnapshot(state: state) }

    init(resources: ApplePanicResources, seed: UInt64 = 1) throws {
        try resources.validate()
        self.resources = resources
        state = ApplePanicState()
        state.backgroundIndex = resources.initialBackgroundIndex
        state.randomState = seed == 0 ? 1 : seed
        beginLife()
    }
    init(resources: ApplePanicResources, snapshot: ApplePanicSnapshot) throws {
        try resources.validate()
        let s = snapshot.state
        guard snapshot.schema == 1, snapshot.sourceSHA256 == resources.sourceSHA256,
              (1...48).contains(s.level), (0...4).contains(s.lives), (0...999999).contains(s.score),
              (0...999999).contains(s.highScore), (0...130).contains(s.hourglass),
              (0..<32).contains(s.hourglassCounter), (0..<33).contains(s.bonusCounter),
              (0...9000).contains(s.bonus), s.bonus % 10 == 0,
              (0...255).contains(s.backgroundIndex), (0..<4).contains(s.layoutIndex), (0..<4).contains(s.spawnIndex),
              (0..<8).contains(s.enemyCursor), (1...1_000_000).contains(s.lifeSerial), (0...1).contains(s.dispatcherHalf), s.randomState != 0,
              (1...130).contains(s.player.x), (0...160).contains(s.player.y), s.player.y % 2 == 0,
              (0..<10).contains(s.player.actionFrame), s.enemies.count == 8, s.holes.count <= 70,
              (s.extraLifeAwarded || s.lives <= 3),
              s.phase != .playing || (s.lives > 0 && s.hourglass > 0) else { throw ApplePanicError.invalidSnapshot }
        for enemy in s.enemies {
            guard (0...2).contains(enemy.kind), (0...132).contains(enemy.x), (0...175).contains(enemy.y),
                  (0...128).contains(enemy.trappedTicks), (!enemy.trapped || enemy.y > 6), [.none, .right, .left, .up, .down].contains(enemy.direction),
                  enemy.holeRow == nil || [15, 47, 79, 111, 143].contains(enemy.holeRow!) else { throw ApplePanicError.invalidSnapshot }
        }
        var coordinates = Set<String>()
        for hole in s.holes {
            guard (1...130).contains(hole.x), [15, 47, 79, 111, 143].contains(hole.row), (1...5).contains(hole.depth),
                  coordinates.insert("\(hole.x):\(hole.row)").inserted,
                  s.holes.filter({ $0.row == hole.row }).count <= 14 else { throw ApplePanicError.invalidSnapshot }
        }
        self.resources = resources
        state = s
    }

    /// One player-update half of the actual dispatcher. Four enemy slots are
    /// updated before each player step; the second half adds the source timer
    /// and speed calls. 60 Hz wall-clock pacing is a native approximation.
    mutating func tick(input: ApplePanicInput = .none) {
        guard state.phase == .playing else { return }
        let half = state.dispatcherHalf
        let level = state.level
        let life = state.lifeSerial
        for _ in 0..<4 {
            updateNextEnemy()
            if state.lifeSerial != life || state.phase != .playing { return }
        }
        movePlayer(input)
        tickHourglass()
        guard state.phase == .playing, state.lifeSerial == life else { return }
        if half == 0 {
            tickBonus()
            checkExtraLife()
        } else {
            if !state.enemies.contains(where: { $0.active }) {
                addScore(state.bonus)
                if state.level == 48 { state.phase = .completed; return }
                state.level += 1
                beginLife()
                return
            }
            tickHourglass()
            guard state.phase == .playing, state.lifeSerial == life else { return }
            let extra = state.hourglass >= 30 ? 0 : state.hourglass >= 20 ? 1 : state.hourglass >= 10 ? 2 : 3
            for _ in 0..<extra {
                updateNextEnemy()
                if state.lifeSerial != life || state.phase != .playing { return }
            }
        }
        if state.level == level { state.dispatcherHalf = 1 - half }
        state.steps &+= 1
    }

    private mutating func beginLife() {
        state.lifeSerial += 1
        state.player = ApplePanicPlayer()
        state.backgroundIndex = (state.backgroundIndex + 1) & 255
        state.layoutIndex = (state.lives + state.backgroundIndex) & 3
        state.backgroundIndex = (state.backgroundIndex + 1) & 255
        state.spawnIndex = (state.level + state.backgroundIndex) & 3
        let count = resources.enemyCounts[(state.level - 1) % 3]
        let types = resources.enemyTypes[(state.level - 1) / 3]
        state.enemies = resources.spawns[state.spawnIndex].enumerated().map { index, point in
            ApplePanicEnemy(kind: types[index], x: point.x, y: point.y, active: index < count)
        }
        state.holes.removeAll(keepingCapacity: true)
        state.hourglass = 130
        state.bonus = (2 + min(state.level >> 2, 7)) * 1000
        state.enemyCursor = 0
        state.dispatcherHalf = 0
    }
    private func platform(x: Int, row: Int) -> Int {
        for ladder in ladders where ladder.x == x {
            if row == ladder.top { return 1 }
            if row == ladder.bottom { return 2 }
            if row > ladder.top && row < ladder.bottom { return 3 }
        }
        return 0
    }
    private func holeIndex(x: Int, row: Int) -> Int? {
        state.holes.firstIndex { $0.x == x && $0.row == row }
    }
    private mutating func movePlayer(_ input: ApplePanicInput) {
        if !state.player.onGround {
            if state.player.y & 31 != 0 { state.player.y = min(160, state.player.y + 2); return }
            if let i = holeIndex(x: state.player.x, row: state.player.y + 15), state.holes[i].depth == 5, !state.holes[i].occupied {
                state.player.y = min(160, state.player.y + 2)
                return
            }
            state.player.onGround = true
        }
        switch input {
        case .none: break
        case .right, .left:
            // Mid-ladder horizontal input continues the previous climb.
            if state.player.y & 31 != 0 {
                if state.player.action == .up || state.player.action == .down { climb(state.player.action) }
                return
            }
            let delta = input == .right ? 1 : -1
            let target = state.player.x + delta
            guard (1...130).contains(target) else { return }
            if let i = holeIndex(x: target, row: state.player.y + 15) {
                if state.holes[i].depth < 5 || state.holes[i].occupied { return }
                state.player.onGround = false
                state.player.y = min(160, state.player.y + 2)
            }
            state.player.x = target
            state.player.facingRight = input == .right
            state.player.action = input
        case .up, .down: climb(input)
        case .dig, .fill:
            guard state.player.x & 1 == 1, state.player.y & 31 == 0 else { return }
            let target = state.player.x + (state.player.facingRight ? 7 : -7)
            guard target > 0, target < 131 else { return }
            let row = state.player.y + 15
            var index = holeIndex(x: target, row: row)
            if input == .dig {
                guard state.player.y < 160 else { return }
                if let i = index {
                    guard state.holes[i].depth < 5 else { return }
                } else {
                    guard !ladders.contains(where: { abs($0.x - target) < 9 && row >= $0.top && row <= $0.bottom }),
                          !state.holes.contains(where: { $0.row == row && abs($0.x - target) < 9 }),
                          state.holes.filter({ $0.row == row }).count < 14 else { return }
                }
            } else if index == nil { return }
            state.player.action = input
            state.player.actionFrame += 1
            if state.player.actionFrame == 2 {
                if input == .dig {
                    if let i = index { state.holes[i].depth += 1 }
                    else {
                        state.holes.append(ApplePanicHole(x: target, row: row, depth: 1))
                        index = state.holes.count - 1
                    }
                } else if let i = index {
                    state.holes[i].depth -= 1
                    if state.holes[i].depth == 0 { state.holes.remove(at: i) }
                }
            }
            if state.player.actionFrame == 8 { state.player.alternateSprite = true }
            if state.player.actionFrame == 10 { state.player.actionFrame = 0; state.player.alternateSprite = false }
        }
    }
    private mutating func climb(_ input: ApplePanicInput) {
        let p = platform(x: state.player.x, row: state.player.y + 15)
        guard input == .up ? p & 2 != 0 : p & 1 != 0 else { return }
        state.player.y = max(0, min(160, state.player.y + (input == .up ? -2 : 2)))
        state.player.action = input
    }
    private mutating func tickHourglass() {
        state.hourglassCounter += 1
        if state.hourglassCounter == 32 {
            state.hourglassCounter = 0
            state.hourglass -= 1
            if state.hourglass == 0 { loseLife() }
        }
    }
    private mutating func tickBonus() {
        state.bonusCounter += 1
        if state.bonusCounter == 33 { state.bonusCounter = 0; state.bonus = max(0, state.bonus - 20) }
    }
    private mutating func addScore(_ value: Int) {
        state.score = (state.score + value) % 1_000_000
        state.highScore = max(state.highScore, state.score)
    }
    private mutating func checkExtraLife() {
        // The actual code tests the thousands digit, not a >= whole-score test.
        if !state.extraLifeAwarded && (state.score / 1000) % 10 > 3 {
            state.extraLifeAwarded = true
            state.lives += 1
        }
    }
    private mutating func loseLife() {
        state.lives -= 1
        if state.lives == 0 { state.phase = .gameOver }
        else { beginLife() }
    }
    private mutating func randomByte() -> Int {
        // Source samples the absent Apple II ROM at $F800+cursor. This seeded
        // substitute keeps saves reproducible; it does not reproduce that ROM.
        state.randomState ^= state.randomState << 13
        state.randomState ^= state.randomState >> 7
        state.randomState ^= state.randomState << 17
        return Int(state.randomState & 255)
    }
    private func overlapsPlayer(_ enemy: ApplePanicEnemy) -> Bool {
        enemy.x + 4 >= state.player.x && state.player.x + 4 >= enemy.x &&
            enemy.y + 7 >= state.player.y && state.player.y + 14 >= enemy.y
    }
    private func overlapsEnemy(_ first: ApplePanicEnemy, _ second: ApplePanicEnemy) -> Bool {
        abs(first.x - second.x) <= 6 && abs(first.y - second.y) <= 9
    }
    private mutating func updateNextEnemy() {
        let slot = state.enemyCursor
        let life = state.lifeSerial
        defer { if state.lifeSerial == life { state.enemyCursor = (slot + 1) % 8 } }
        guard state.enemies[slot].active else { return }
        if overlapsPlayer(state.enemies[slot]) { loseLife(); return }
        var enemy = state.enemies[slot]
        if !enemy.trapped, ((enemy.y - 6) & 31) == 0,
           let index = holeIndex(x: enemy.x, row: enemy.y + 9) {
            let depth = state.holes[index].depth
            state.holes[index].occupied = true
            enemy.trapped = true
            enemy.holeRow = enemy.y + 9
            enemy.y += depth == 5 ? 9 : depth + 1
            enemy.trappedTicks = depth == 5 ? 128 : 0
            state.enemies[slot] = enemy
            chooseDirections()
            return
        }
        if enemy.trapped {
            if enemy.trappedTicks > 0 {
                if holeIndex(x: enemy.x, row: enemy.holeRow ?? -1) == nil {
                    dropEnemy(slot)
                    chooseDirections()
                    return
                }
                enemy.trappedTicks -= 1
                enemy.alternateSprite.toggle()
            } else {
                enemy.y -= 1
                enemy.alternateSprite.toggle()
                if ((enemy.y - 6) & 31) == 0 {
                    enemy.trapped = false
                    if let i = holeIndex(x: enemy.x, row: enemy.y + 9) { state.holes.remove(at: i) }
                    enemy.holeRow = nil
                }
            }
            state.enemies[slot] = enemy
            chooseDirections()
            return
        }
        var next = enemy
        switch enemy.direction {
        case .right: if enemy.x < 132 { next.x = min(132, enemy.x + 2) } else { next.direction = .none }
        case .left: if enemy.x > 0 { next.x = max(0, enemy.x - 2) } else { next.direction = .none }
        case .up:
            let p = platform(x: enemy.x, row: enemy.y + 9)
            if p & 2 != 0, enemy.y > 6 { next.y -= 4 } else { next.direction = .none }
        case .down:
            let p = platform(x: enemy.x, row: enemy.y + 9)
            if p & 1 != 0, enemy.y < 166 { next.y += 4 } else { next.direction = .none }
        default: break
        }
        if state.enemies.enumerated().contains(where: { $0.offset != slot && $0.element.active && overlapsEnemy(next, $0.element) }) { next = enemy; next.direction = .none }
        if let i = holeIndex(x: next.x + (enemy.direction == .left ? -6 : 6), row: next.y + 9), state.holes[i].occupied { next = enemy; next.direction = .none }
        if overlapsPlayer(next) { loseLife(); return }
        next.alternateSprite.toggle()
        state.enemies[slot] = next
        chooseDirections()
    }
    private mutating func chooseDirections() {
        for slot in state.enemies.indices where state.enemies[slot].active && !state.enemies[slot].trapped {
            let enemy = state.enemies[slot]
            let floor = ((enemy.y - 6) & 31) == 0
            let p = platform(x: enemy.x, row: enemy.y + 9)
            if enemy.direction != .none {
                if (enemy.direction == .up || enemy.direction == .down) && !floor { continue }
                if (enemy.direction == .left || enemy.direction == .right) && p == 0 { continue }
            }
            let random = randomByte()
            let direction: ApplePanicInput
            if p == 3 && !floor { direction = random < 128 ? .up : .down }
            else if p == 3 { direction = random < 24 ? .right : random < 144 ? .left : random < 240 ? .up : .down }
            else if p == 2 { direction = random < 80 ? .right : random < 160 ? .left : .up }
            else if p == 1 { direction = random < 80 ? .right : random < 160 ? .left : .down }
            else { direction = floor ? (random < 80 ? .right : .left) : .none }
            state.enemies[slot].direction = direction
        }
    }
    private mutating func dropEnemy(_ slot: Int) {
        // The original performs this descent synchronously. Native state resolves
        // the same aligned-floor chain without its speaker/delay rendering loop.
        var enemy = state.enemies[slot]
        var multiplier = 1
        var nextFloor = ((enemy.y - 6) / 32 + 1) * 32 + 6
        while nextFloor <= 166 {
            for other in state.enemies.indices where other != slot && state.enemies[other].active {
                let victim = state.enemies[other]
                if abs(victim.x - enemy.x) <= 6 && victim.y >= enemy.y && victim.y < nextFloor {
                    state.enemies[other].active = false
                    addScore((victim.kind + 1) * 100)
                }
            }
            enemy.y = nextFloor
            if let index = holeIndex(x: enemy.x, row: nextFloor + 9), state.holes[index].depth == 5 {
                let occupied = state.holes[index].occupied
                state.holes.remove(at: index)
                multiplier += 1
                if occupied, let other = state.enemies.indices.first(where: { $0 != slot && state.enemies[$0].active && state.enemies[$0].x == enemy.x && state.enemies[$0].y == nextFloor + 9 }) {
                    state.enemies[other].active = false
                    // Full source chain scoring uses six per-enemy accumulators;
                    // this contribution is an explicitly approximate native sum.
                    addScore((state.enemies[other].kind + 1) * multiplier * 100)
                }
                nextFloor += 32
                continue
            }
            if multiplier >= enemy.kind + 1 {
                enemy.active = false
                addScore((enemy.kind + 1) * multiplier * 100)
                checkExtraLife()
            } else if let i = state.holes.firstIndex(where: { $0.row == nextFloor + 9 && abs($0.x - enemy.x) < 6 && $0.depth < 5 }) {
                enemy.x = max(0, min(132, state.holes[i].x + (state.holes[i].x < enemy.x ? 8 : -8)))
            }
            break
        }
        enemy.trapped = false
        enemy.trappedTicks = 0
        enemy.holeRow = nil
        enemy.direction = .none
        state.enemies[slot] = enemy
    }

    var playerSpriteName: String {
        let p = state.player
        let left = !p.facingRight
        switch p.action {
        case .dig, .fill: return "dig\(left ? "Left" : "Right")\(p.alternateSprite ? 1 : 0)"
        case .up, .down: return "climb\(((p.y >> 2) & 1) == 0 ? 0 : 1)"
        default: return "walk\(left ? "Left" : "Right")\(p.x & 1)"
        }
    }
}
