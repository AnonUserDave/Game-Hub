import Foundation

// Native translation of the selected Crossfire 6502 program's game routines.
// Addresses in comments refer to the statically loaded $4000 game code.
// There is no CPU, Apple II machine, ROM execution or compatibility runtime.
struct CrossfirePoint: Codable, Equatable {
    var x: Int
    var y: Int
}

enum CrossfireDirection: String, Codable, CaseIterable {
    case up, left, down, right
    var vector: CrossfirePoint {
        switch self {
        case .up: return CrossfirePoint(x: 0, y: -2)
        case .left: return CrossfirePoint(x: -2, y: 0)
        case .down: return CrossfirePoint(x: 0, y: 2)
        case .right: return CrossfirePoint(x: 2, y: 0)
        }
    }
    var movementKey: UInt8 {
        switch self { case .up: return 0xC9; case .left: return 0xCA; case .down: return 0xCB; case .right: return 0xCC }
    }
    var shootingKey: UInt8 {
        switch self { case .up: return 0xC5; case .left: return 0xD3; case .down: return 0xC4; case .right: return 0xC6 }
    }
}

struct CrossfireEnemy: Codable, Equatable {
    var position: CrossfirePoint
    var velocity: CrossfirePoint
    var spawn: CrossfirePoint
    var spawnVelocity: CrossfirePoint
    // Source offsets +4: 0 waiting, 1 shifting, 2 ready, 3 roaming,
    // 4 eliminated, 5 dying, 6...10 explosion frames. +10 is kill stage.
    var state = 0
    var stage = 0
    var shiftRemaining = 0
    var explosionRemaining = 0
    var isEliminated: Bool { state == 4 }
    var isVisible: Bool { state != 4 && (state < 6 || explosionRemaining != 0) }
}

struct CrossfireProjectile: Codable, Equatable {
    var position = CrossfirePoint(x: 0, y: 0)
    var velocity = CrossfirePoint(x: 0, y: 0)
    var delay = 0
    // Source +7: zero free, one hostile, two player. Slots are 8 bytes.
    var kind = 0
}

struct CrossfireBonus: Codable, Equatable {
    var position: CrossfirePoint
    var originalY: Int
    var alternateY: Int
    var kind = 0
}

struct CrossfireSnapshot: Codable, Equatable {
    var version = 1
    var sourceIdentity = CrossfireSimulation.sourceIdentity
    var player: CrossfirePoint
    var velocity: CrossfirePoint
    var enemies: [CrossfireEnemy]
    var projectiles: [CrossfireProjectile]
    var freeProjectiles: [Int]
    var bonuses: [CrossfireBonus]
    var rng: [UInt8]
    var rngCarry: Bool
    var score: Int
    var highScore: Int
    var lives: Int
    var wave: Int
    var ammunition: Int
    var ammunitionCapacity: Int
    var resupply: CrossfirePoint?
    var resupplyVisible: Bool
    var movementKey: UInt8
    var lastKey: UInt8
    var pendingKey: UInt8?
    var fireDelay: Int
    var projectileIndex: Int
    var enemyIndex: Int
    var enemyDivider: Int
    var playerDivider: Int
    var blinkDivider: Int
    var shiftDivider: Int
    var roamDivider: Int
    var enemyFireDivider: Int
    var activeEnemies: Int
    var bonusIndex: Int
    var bonusShotDivider: Int
    var remainingBonuses: Int
    var bonusExpiry: Int
    var expiringBonus: Int?
    var deathFrame: Int
    var playerDead: Bool
    var transitionRemaining: Int
    var ended: Bool
    var audioEnabled: Bool
    var loops: UInt64
    var fractionalLoops: Double
}

struct CrossfireSimulation {
    static let sourceIdentity = "d1dca8251e6b3d3114e7eeac5aaa34c1d4ed9dc338fed02a8ef6aa6d48efe6c7"
    // Development clock conversion, NOT recovered original wall-clock timing.
    static let developmentLoopsPerSecond = 960.0
    static let enemyPoints = [10, 20, 40, 80]
    static let bonusPoints = [0, 100, 200, 400, 800]
    // $5999-$59EC: 7 x 6 blocks, logical origin at n*32-24.
    static let obstacles = (0..<6).flatMap { row in
        (0..<7).map { column in CrossfirePoint(x: column * 32 + 8, y: row * 32 + 8) }
    }
    private(set) var state: CrossfireSnapshot
    var player: CrossfirePoint { state.player }
    var enemies: [CrossfireEnemy] { state.enemies }
    var projectiles: [CrossfireProjectile] { state.projectiles }
    var score: Int { state.score }
    var highScore: Int { state.highScore }
    var lives: Int { state.lives }
    var wave: Int { state.wave }
    var ammunition: Int { state.ammunition }
    var ended: Bool { state.ended }
    var remainingEnemies: Int { state.enemies.filter { !$0.isEliminated }.count }
    var snapshot: CrossfireSnapshot { state }

    init(seed: UInt8 = 81, highScore: Int = 0) {
        // $5BB5: left (0,48/112/176), right (224,80/144),
        // top (48/80/112/144/176/208,0). All eleven carry spawn vectors.
        var actors: [CrossfireEnemy] = []
        let groups = [(0, 48, 0, 64, 0, 2, 3), (224, 80, 0, 64, 0, -2, 2), (48, 0, 32, 0, 2, 0, 6)]
        for (x, y, sx, sy, dx, dy, count) in groups {
            for i in 0..<count {
                let point = CrossfirePoint(x: x + sx * i, y: y + sy * i)
                let velocity = CrossfirePoint(x: dx, y: dy)
                actors.append(CrossfireEnemy(position: point, velocity: velocity, spawn: point, spawnVelocity: velocity))
            }
        }
        let bonuses = [(80, 112, 128), (80, 80, 64), (144, 80, 64), (144, 112, 128)].map {
            CrossfireBonus(position: CrossfirePoint(x: $0.0, y: $0.1), originalY: $0.1, alternateY: $0.2)
        }
        state = CrossfireSnapshot(player: CrossfirePoint(x: 128, y: 160), velocity: CrossfirePoint(x: 0, y: -2),
            enemies: actors, projectiles: Array(repeating: CrossfireProjectile(), count: 6), freeProjectiles: Array(0..<6),
            bonuses: bonuses, rng: [seed &+ 1, seed &+ 1, seed, seed, seed, seed], rngCarry: false,
            score: 0, highScore: max(0, min(999_999, highScore)), lives: 3, wave: 1,
            ammunition: 35, ammunitionCapacity: 35, resupply: nil, resupplyVisible: false,
            movementKey: 0xA0, lastKey: 0xA0, pendingKey: nil, fireDelay: 12, projectileIndex: 0, enemyIndex: 0,
            enemyDivider: 8, playerDivider: 32, blinkDivider: 128, shiftDivider: 32, roamDivider: 6,
            enemyFireDivider: 6, activeEnemies: 0, bonusIndex: 0, bonusShotDivider: 12, remainingBonuses: 4,
            bonusExpiry: 255, expiringBonus: nil, deathFrame: 0, playerDead: false, transitionRemaining: 0,
            ended: false, audioEnabled: true, loops: 0, fractionalLoops: 0)
    }

    init(snapshot: CrossfireSnapshot) throws {
        guard Self.valid(snapshot) else { throw CocoaError(.fileReadCorruptFile) }
        state = snapshot
    }

    private static func valid(_ s: CrossfireSnapshot) -> Bool {
        func coordinate(_ p: CrossfirePoint) -> Bool { (0...255).contains(p.x) && (0...255).contains(p.y) }
        func vector(_ p: CrossfirePoint) -> Bool { [-2, 0, 2].contains(p.x) && [-2, 0, 2].contains(p.y) && (p.x == 0 || p.y == 0) }
        guard s.version == 1, s.sourceIdentity == sourceIdentity, s.enemies.count == 11,
              s.projectiles.count == 6, s.bonuses.count == 4, s.rng.count == 6,
              coordinate(s.player), (32...192).contains(s.player.x), (32...160).contains(s.player.y), vector(s.velocity),
              s.player.x % 2 == 0, s.player.y % 2 == 0, s.player.x % 32 == 0 || s.player.y % 32 == 0,
              (0...999_999).contains(s.score), (s.score...999_999).contains(s.highScore), (0...99).contains(s.lives),
              (1...1_000_000).contains(s.wave), [15, 20, 25, 30, 35].contains(s.ammunitionCapacity),
              (0...s.ammunitionCapacity).contains(s.ammunition), (0...12).contains(s.fireDelay),
              (0..<6).contains(s.projectileIndex), (0..<11).contains(s.enemyIndex),
              (1...8).contains(s.enemyDivider), (1...128).contains(s.playerDivider), (1...128).contains(s.blinkDivider),
              (1...32).contains(s.shiftDivider), (1...6).contains(s.roamDivider), (1...6).contains(s.enemyFireDivider),
              (0...255).contains(s.activeEnemies), (0..<4).contains(s.bonusIndex), (1...12).contains(s.bonusShotDivider),
              (0...4).contains(s.remainingBonuses), (1...255).contains(s.bonusExpiry), (0...6).contains(s.deathFrame),
              (0...3327).contains(s.transitionRemaining), s.fractionalLoops.isFinite, (0..<1).contains(s.fractionalLoops),
              s.loops < UInt64.max - 100_000, Set(s.freeProjectiles).count == s.freeProjectiles.count,
              s.freeProjectiles.allSatisfy({ (0..<6).contains($0) && s.projectiles[$0].kind == 0 }),
              Set(s.freeProjectiles) == Set(s.projectiles.indices.filter { s.projectiles[$0].kind == 0 }),
              s.expiringBonus.map({ (0..<4).contains($0) }) ?? true,
              s.resupply.map({ coordinate($0) && (32...192).contains($0.x) && (32...160).contains($0.y) }) ?? true else { return false }
        let source = CrossfireSimulation().state
        for i in s.enemies.indices {
            let e = s.enemies[i]
            guard coordinate(e.position), vector(e.velocity), e.spawn == source.enemies[i].spawn,
                  e.spawnVelocity == source.enemies[i].spawnVelocity, (0...10).contains(e.state),
                  (0...4).contains(e.stage), (e.stage < 4 || e.state == 4),
                  (0...16).contains(e.shiftRemaining), (0...5).contains(e.explosionRemaining) else { return false }
        }
        for b in s.projectiles {
            guard coordinate(b.position), vector(b.velocity), (0...4).contains(b.delay), (0...2).contains(b.kind) else { return false }
        }
        for i in s.bonuses.indices {
            let b = s.bonuses[i], expected = source.bonuses[i]
            guard b.position.x == expected.position.x, [expected.originalY, expected.alternateY].contains(b.position.y),
                  b.originalY == expected.originalY, b.alternateY == expected.alternateY, (0...5).contains(b.kind) else { return false }
        }
        return true
    }

    mutating func press(_ key: String) {
        guard let code = key.uppercased().utf8.first else { return }
        // Source keyboard hardware keeps only the latest unconsumed character.
        state.pendingKey = code | 0x80
    }
    mutating func move(_ direction: CrossfireDirection?) { state.pendingKey = direction?.movementKey ?? 0xA0 }
    mutating func shoot(_ direction: CrossfireDirection) { state.pendingKey = direction.shootingKey }

    mutating func advance(seconds: Double) {
        guard seconds.isFinite, seconds > 0, seconds <= 0.25 else { return }
        let loops = seconds * Self.developmentLoopsPerSecond + state.fractionalLoops
        state.fractionalLoops = loops - floor(loops)
        advance(iterations: Int(loops))
    }

    mutating func advance(iterations: Int = 1) {
        guard !state.ended, (1...100_000).contains(iterations) else { return }
        for _ in 0..<iterations {
            guard !state.ended else { break }
            state.loops &+= 1
            // $4064-$40A5: independent round-robin actor and projectile clocks.
            state.enemyDivider -= 1
            if state.enemyDivider == 0 { updateEnemy(); state.enemyDivider = 8 }
            updateProjectile()
            state.playerDivider -= 1
            if state.playerDivider == 0 { updatePlayer(); state.playerDivider = state.playerDead ? 128 : 32 }
            state.blinkDivider -= 1
            if state.blinkDivider == 0 { state.resupplyVisible.toggle(); state.blinkDivider = 128 }
            if let index = state.expiringBonus {
                state.bonusExpiry -= 1
                if state.bonusExpiry == 0 {
                    state.bonuses[index].kind = 5
                    state.expiringBonus = nil
                    state.bonusExpiry = 255
                }
            }
            if state.playerDead || remainingEnemies == 0 {
                if state.transitionRemaining == 0 { state.transitionRemaining = 3327 }
                state.transitionRemaining -= 1
                if state.transitionRemaining == 0 {
                    if state.lives == 0 { state.ended = true }
                    else {
                        if remainingEnemies == 0 { nextWave() }
                        resetPositions()
                    }
                }
            }
        }
    }

    // $4D00: six-byte add/shift generator with carry from both additions.
    private mutating func randomByte() -> Int {
        let first = Int(state.rng[1]) + Int(state.rng[4]) + 1
        let second = (first & 255) + Int(state.rng[5]) + (first > 255 ? 1 : 0)
        state.rng[0] = UInt8(second & 255)
        state.rngCarry = second > 255
        for i in stride(from: 4, through: 0, by: -1) { state.rng[i + 1] = state.rng[i] }
        return second & 255
    }

    private mutating func addScore(_ points: Int) {
        let old = state.score
        let next = old + points
        // Source $4900 increments life on middle BCD carry and 4->5 thousands.
        if old / 10_000 != next / 10_000 || (old / 1_000 % 10 == 4 && next / 1_000 % 10 == 5) {
            state.lives = (state.lives + 1) % 100
        }
        state.score = next % 1_000_000
        state.highScore = max(state.highScore, state.score)
    }

    private mutating func killPlayer() {
        if !state.playerDead {
            state.playerDead = true
            state.lives = max(0, state.lives - 1)
        }
    }

    private mutating func resetPositions() {
        for i in state.enemies.indices where !state.enemies[i].isEliminated {
            state.enemies[i].position = state.enemies[i].spawn
            state.enemies[i].velocity = state.enemies[i].spawnVelocity
            state.enemies[i].state = 0
        }
        state.activeEnemies = 0
        state.player = CrossfirePoint(x: 128, y: 160)
        state.velocity = CrossfirePoint(x: 0, y: -2)
        state.movementKey = 0xA0; state.lastKey = 0xA0; state.pendingKey = nil
        state.playerDead = false; state.deathFrame = 0; state.playerDivider = 32
        state.resupply = nil; state.ammunition = state.ammunitionCapacity; state.fireDelay = 12
    }

    private mutating func nextWave() {
        state.wave = min(1_000_000, state.wave + 1)
        state.ammunitionCapacity = max(15, state.ammunitionCapacity - 5)
        for i in state.enemies.indices { state.enemies[i].state = 0; state.enemies[i].stage = 0 }
        for i in state.bonuses.indices { state.bonuses[i].position.y = state.bonuses[i].originalY; state.bonuses[i].kind = 0 }
        state.remainingBonuses = 4; state.bonusIndex = 0; state.bonusShotDivider = 12
        state.expiringBonus = nil; state.bonusExpiry = 255
    }

    private mutating func allocateProjectile(kind: Int, position: CrossfirePoint, velocity: CrossfirePoint) -> Bool {
        // $5100 reserves the final free slot for the player's projectile.
        guard !state.playerDead, !state.freeProjectiles.isEmpty, kind != 1 || state.freeProjectiles.count > 1 else { return false }
        let index = state.freeProjectiles.removeLast()
        state.projectiles[index] = CrossfireProjectile(position: position, velocity: velocity, delay: kind == 2 ? 1 : 4, kind: kind)
        return true
    }

    private mutating func freeProjectile(_ index: Int) {
        state.projectiles[index].kind = 0
        state.freeProjectiles.append(index)
    }

    private mutating func updateProjectile() {
        let i = state.projectileIndex
        state.projectileIndex = (i + 1) % 6
        guard state.projectiles[i].kind != 0 else { return }
        state.projectiles[i].delay -= 1
        guard state.projectiles[i].delay == 0 else { return }
        let kind = state.projectiles[i].kind
        state.projectiles[i].delay = kind == 2 ? 1 : 4
        var p = state.projectiles[i].position
        p.x = (p.x + state.projectiles[i].velocity.x) & 255
        p.y = (p.y + state.projectiles[i].velocity.y) & 255
        state.projectiles[i].position = p
        guard p.x <= 224, p.y <= 188 else { freeProjectile(i); return }
        if kind == 2 {
            for j in state.enemies.indices where state.enemies[j].state < 4 {
                let e = state.enemies[j]
                if abs(p.x - e.position.x) < 8 && abs(p.y - e.position.y) < 8 {
                    if e.state != 2 { state.activeEnemies = (state.activeEnemies - 1) & 255 }
                    state.enemies[j].state = 5
                    addScore(Self.enemyPoints[e.stage])
                    freeProjectile(i)
                    return
                }
            }
        }
        if abs(p.x - state.player.x) < 8 && abs(p.y - state.player.y) < 8 {
            killPlayer(); freeProjectile(i)
        }
    }

    private mutating func updatePlayer() {
        guard !state.playerDead else { state.deathFrame = min(6, state.deathFrame + 1); return }
        if let key = state.pendingKey {
            state.lastKey = key; state.pendingKey = nil
            state.rng[0] = 0x4E; state.rng[1] = 0x4F
            if key == 0x93 { state.audioEnabled.toggle() }
            if [0xC9, 0xCA, 0xCB, 0xCC, 0xA0].contains(key) { state.movementKey = key }
        }
        var velocity = CrossfirePoint(x: 0, y: 0)
        for direction in CrossfireDirection.allCases where direction.movementKey == state.movementKey { velocity = direction.vector }
        if state.player.x % 32 != 0 || state.player.y % 32 != 0 {
            if state.player.x % 32 == 0 {
                velocity.x = 0
                if velocity.y == 0 { velocity.y = state.velocity.y }
            } else {
                velocity.y = 0
                if velocity.x == 0 { velocity.x = state.velocity.x }
            }
        }
        let p = CrossfirePoint(x: state.player.x + velocity.x, y: state.player.y + velocity.y)
        if (32...192).contains(p.x), (32...160).contains(p.y), p != state.player {
            state.player = p
            let bonus = state.bonuses[state.bonusIndex]
            if state.remainingBonuses > 0, p == bonus.position, bonus.kind == 0 {
                state.remainingBonuses -= 1
                let kind = 4 - state.remainingBonuses
                state.bonuses[state.bonusIndex].kind = kind
                state.expiringBonus = state.bonusIndex
                addScore(Self.bonusPoints[kind])
                state.bonusShotDivider = 12
            }
        }
        state.velocity = velocity
        if let resupply = state.resupply, state.player == resupply {
            state.ammunition = state.ammunitionCapacity; state.resupply = nil
        }
        guard state.ammunition != 0 else { return }
        if state.fireDelay != 0 { state.fireDelay -= 1; return }
        guard let direction = CrossfireDirection.allCases.first(where: { $0.shootingKey == state.lastKey }) else { return }
        let v = direction.vector
        guard (v.x == 0 ? state.player.x : state.player.y) % 32 == 0 else { return }
        let origin = CrossfirePoint(x: state.player.x + v.x * 4, y: state.player.y + v.y * 4)
        guard allocateProjectile(kind: 2, position: origin, velocity: v) else { return }
        state.lastKey = 0xFF; state.fireDelay = 12
        advanceBonus()
        state.ammunition -= 1
        if state.ammunition == 10 {
            state.resupply = CrossfirePoint(x: 224 - state.player.x, y: 192 - state.player.y)
            state.resupplyVisible = true
        }
    }

    private mutating func advanceBonus() {
        state.bonusShotDivider -= 1
        guard state.bonusShotDivider == 0 else { return }
        defer { if state.bonusShotDivider == 0 { state.bonusShotDivider = 12 } }
        guard state.remainingBonuses > 0, state.remainingBonuses <= remainingEnemies else { return }
        // $5C0A compares bonus count with enemy count; equality or a negative
        // subtraction admits the update. Preserve that counterintuitive order.
        for _ in 0..<4 {
            if state.bonuses[state.bonusIndex].kind == 5 { state.bonusIndex = (state.bonusIndex + 3) % 4 }
            else { break }
        }
        guard state.bonuses[state.bonusIndex].kind == 0 else { return }
        if state.bonuses[state.bonusIndex].position.y == state.bonuses[state.bonusIndex].originalY {
            state.bonuses[state.bonusIndex].position.y = state.bonuses[state.bonusIndex].alternateY
            state.bonusShotDivider = 6
        } else {
            state.bonuses[state.bonusIndex].position.y = state.bonuses[state.bonusIndex].originalY
            state.bonusIndex = (state.bonusIndex + 3) % 4
        }
    }

    private mutating func shiftEnemy(_ i: Int) {
        let speed = state.enemies[i].state == 0 ? -2 : 2
        if state.enemies[i].velocity.x != 0 { state.enemies[i].velocity.x = speed }
        else { state.enemies[i].velocity.y = speed }
        state.enemies[i].shiftRemaining = 16
        state.enemies[i].state = 1
        state.activeEnemies = (state.activeEnemies + 1) & 255
    }

    private mutating func moveEnemy(_ i: Int) {
        state.enemies[i].position.x = (state.enemies[i].position.x + state.enemies[i].velocity.x) & 255
        state.enemies[i].position.y = (state.enemies[i].position.y + state.enemies[i].velocity.y) & 255
    }

    private mutating func startExplosion(_ i: Int) {
        state.enemies[i].state = 6; state.enemies[i].explosionRemaining = 5
    }

    private mutating func updateEnemy() {
        let i = state.enemyIndex
        defer { state.enemyIndex = (i + 1) % 11 }
        var e = state.enemies[i]
        if e.state == 4 { return }
        if e.state == 5 { startExplosion(i); return }
        if e.state >= 6 {
            if e.explosionRemaining != 0 {
                state.enemies[i].explosionRemaining -= 1
                if state.enemies[i].explosionRemaining != 0 { state.enemies[i].state += 1; return }
                state.enemies[i].stage += 1
                if state.enemies[i].stage == 4 { state.enemies[i].state = 4; return }
            }
            if !state.playerDead {
                state.enemies[i].position = e.spawn; state.enemies[i].velocity = e.spawnVelocity; state.enemies[i].state = 0
            }
            return
        }
        guard !state.playerDead else { return }
        let left = remainingEnemies
        var enteredRoaming = false
        if e.state == 0 {
            guard state.activeEnemies < 5 else { return }
            if left >= 6 {
                state.shiftDivider -= 1
                guard state.shiftDivider == 0 else { return }
                state.shiftDivider = 32
                let sum = randomByte() + [255, 255, 255, 255, 255, 255, 128, 96, 64, 32, 16, 0][left]
                guard sum > 255 || (sum & 255) < 128 else { return }
            }
            shiftEnemy(i)
        }
        if state.enemies[i].state == 1 {
            moveEnemy(i)
            let sum = state.enemies[i].velocity.x + state.enemies[i].velocity.y
            state.enemies[i].shiftRemaining -= abs(sum)
            guard state.enemies[i].shiftRemaining == 0 else { return }
            state.enemies[i].state = sum < 0 ? 2 : 0
            state.activeEnemies = (state.activeEnemies - 1) & 255
        }
        e = state.enemies[i]
        if e.state == 2 {
            if state.activeEnemies < 5 {
                var roam = left < 6
                if left >= 6 {
                    state.shiftDivider -= 1
                    if state.shiftDivider == 0 {
                        state.shiftDivider = 32
                        if randomByte() < 128 { shiftEnemy(i); moveEnemy(i); state.enemies[i].shiftRemaining -= 2; return }
                    }
                    state.roamDivider -= 1
                    if state.roamDivider == 0 {
                        state.roamDivider = 6
                        let one = randomByte() + [0, 48, 72, 96][e.stage]
                        let two = (one & 255) + [128, 96, 64, 32, 16, 0, 255, 255, 255, 255, 255, 255][left] + (one > 255 ? 1 : 0)
                        roam = one > 255 || two > 255 || (two & 255) < 32
                    }
                }
                if roam {
                    state.enemies[i].state = 3; state.activeEnemies = (state.activeEnemies + 1) & 255
                    state.enemies[i].velocity = e.position.y == 0 || e.position.y % 32 != 0
                        ? CrossfirePoint(x: 0, y: 2) : CrossfirePoint(x: e.position.x < 128 ? 2 : -2, y: 0)
                    enteredRoaming = true
                }
            }
            if state.enemies[i].state == 2 { fireEnemy(i); return }
        }
        guard state.enemies[i].state == 3 else { return }
        e = state.enemies[i]
        if !enteredRoaming, e.position.x % 32 == 0, e.position.y % 32 == 0 {
            let dx = state.player.x - e.position.x, dy = state.player.y - e.position.y
            var vertical = false
            if dy != 0 { vertical = dx == 0 || randomByte() < 128 }
            state.enemies[i].velocity = vertical ? CrossfirePoint(x: 0, y: dy < 0 ? -2 : 2) : CrossfirePoint(x: dx < 0 ? -2 : 2, y: 0)
        }
        for attempt in 0..<2 {
            let v = state.enemies[i].velocity
            let p = CrossfirePoint(x: (e.position.x + v.x) & 255, y: (e.position.y + v.y) & 255)
            if abs(p.x - state.player.x) < 13, abs(p.y - state.player.y) < 13 {
                moveEnemy(i); killPlayer(); state.activeEnemies = (state.activeEnemies - 1) & 255; startExplosion(i); return
            }
            let collision = state.enemies.indices.contains { j in
                j != i && state.enemies[j].state == 3 && abs(p.x - state.enemies[j].position.x) < 14 && abs(p.y - state.enemies[j].position.y) < 14
            }
            if !collision { moveEnemy(i); fireEnemy(i); return }
            if attempt != 0 || e.position.x < 33 || e.position.x >= 192 || e.position.y < 33 {
                state.activeEnemies = (state.activeEnemies - 1) & 255; startExplosion(i); return
            }
            state.enemies[i].velocity = CrossfirePoint(x: -v.x, y: -v.y)
        }
    }

    private mutating func fireEnemy(_ i: Int) {
        state.enemyFireDivider -= 1
        guard state.enemyFireDivider == 0 else { return }
        state.enemyFireDivider = 6
        let e = state.enemies[i]
        let random = randomByte()
        let value = random + [96, 64, 32, 0][e.stage] + (state.rngCarry ? 1 : 0)
        guard value < 120 else { return }
        let horizontal = e.position.y != 0 && e.position.y % 32 == 0
        let velocity = horizontal ? CrossfirePoint(x: e.position.x < state.player.x ? 2 : -2, y: 0)
            : CrossfirePoint(x: 0, y: e.position.y < state.player.y ? 2 : -2)
        let position = CrossfirePoint(x: (e.position.x + velocity.x * 2) & 255, y: (e.position.y + velocity.y * 2) & 255)
        _ = allocateProjectile(kind: 1, position: position, velocity: velocity)
    }
}
