import Foundation

// Native translation of the selected Conflict 2500 disk's recovered CONFLICT
// Applesoft program (SHA-256 08382687...b16a). Line numbers below refer to that
// local listing. This is game logic, not a BASIC interpreter or CPU emulator.
// RNG, floating point, presentation and timing still need original comparison.
struct ConflictScenario: Codable, Equatable {
    var ships = 3
    var enemies = 6
    var planets = 2
    var bases = 3
    var isValid: Bool {
        (1...10).contains(ships) && (1...20).contains(enemies)
            && (1...10).contains(planets) && (1...10).contains(bases)
    }
}

struct ConflictUnit: Codable, Equatable {
    var x: Int
    var y: Int
    var energy: Int
    var dx = 0
    var dy = 0
    var kills = 0
    var fired = false
    // The BASIC deliberately distinguishes <0 from >0 at several sites.
    var destroyed: Bool { energy < 0 }
    var sector: String { String(UnicodeScalar(64 + max(1, min(13, x / 1000)))!) + String(max(1, min(9, y / 1000))) }
    var displayedHeading: Int {
        // Literal status calculation, BASIC3020-3100. Preserve its behavior
        // for an exactly horizontal vector rather than replacing with atan2.
        if dx == 0 { return dy > 0 ? 180 : 0 }
        var angle = abs(Int(floor(57.2957795 * atan(Double(dy) / Double(dx)))))
        if dx > 0 && dy < 0 { angle = 90 - angle }
        if dx > 0 && dy > 0 { angle = 90 + angle }
        if dx < 0 && dy < 0 { angle = 270 + angle }
        if dx < 0 && dy > 0 { angle = 270 - angle }
        return angle
    }
}

struct ConflictObject: Codable, Equatable {
    var x: Int
    var y: Int
    var energy: Int
    var destroyed: Bool { energy < 0 }
}

enum ConflictDisplay: String, Codable, CaseIterable {
    case map = "Map", tactical = "Tactical", status = "Status"
}

enum ConflictDock: String, CaseIterable {
    case base = "Base", planet = "Planet", ship = "Ship"
}

struct ConflictSnapshot: Codable, Equatable {
    var version = 1
    var sourceIdentity = ConflictSimulation.sourceIdentity
    var scenario: ConflictScenario
    var ships: [ConflictUnit]
    var enemies: [ConflictUnit]
    var bases: [ConflictObject]
    var planets: [ConflictObject]
    var mines: [ConflictObject]
    var turn: Int
    var selected: Int
    var display: ConflictDisplay
    var placedMine: Int
    var placementUsed: Bool
    var shipPriority: Double
    var basePriority: Double
    var planetPriority: Double
    var mineDetection: Double
    var rng: UInt64
    var ended: Bool
}

struct ConflictSimulation {
    static let sourceIdentity = "083826876c216b210d2ad779160711c03d7d29be0fa178a3a243066993fcb16a"
    private(set) var scenario: ConflictScenario
    var ships: [ConflictUnit]
    var enemies: [ConflictUnit]
    var bases: [ConflictObject]
    var planets: [ConflictObject]
    var mines: [ConflictObject]
    private(set) var turn = 0
    private(set) var selected = 0
    var display: ConflictDisplay = .map
    private(set) var placedMine = 0
    private(set) var placementUsed = false
    private(set) var shipPriority = 2.0
    private(set) var basePriority = 1.0
    private(set) var planetPriority = 5.0
    private(set) var mineDetection = 0.0
    private(set) var ended = false
    private(set) var messages: [String] = []
    private var rng: UInt64

    init(scenario: ConflictScenario = ConflictScenario(), seed: UInt64 = 2500) {
        precondition(scenario.isValid)
        self.scenario = scenario
        rng = seed
        ships = []; enemies = []; bases = []; planets = []
        // Original DIM MI%(N4,2) includes index zero. SET starts with index 1.
        mines = Array(repeating: ConflictObject(x: 0, y: 0, energy: 0), count: scenario.ships * 2 + 1)
        // Preserve source RNG call order (1050-1080), including 8999 for enemy Y.
        for _ in 0..<scenario.enemies {
            let x = Int(1000 + random() * 13000), y = Int(1000 + random() * 8999)
            enemies.append(ConflictUnit(x: x, y: y, energy: Int(10000 + random() * 20000)))
        }
        for _ in 0..<scenario.ships {
            let x = Int(1000 + random() * 13000), y = Int(1000 + random() * 9000)
            ships.append(ConflictUnit(x: x, y: y, energy: Int(10000 + random() * 20000)))
        }
        for _ in 0..<scenario.bases {
            bases.append(ConflictObject(x: Int(1000 + random() * 13000), y: Int(1000 + random() * 9000), energy: 30000))
        }
        for _ in 0..<scenario.planets {
            planets.append(ConflictObject(x: Int(1000 + random() * 13000), y: Int(1000 + random() * 9000), energy: 30000))
        }
        // Line 60 resolves enemy orders and attacks once before the first command.
        resolveEnemyOrders()
        selectFirstSurvivor()
    }

    private mutating func random() -> Double {
        // Reproducible native generator. Does not claim Applesoft RND parity.
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return Double(rng >> 11) / 9007199254740992.0
    }

    private mutating func log(_ message: String) {
        messages.append(message)
        if messages.count > 40 { messages.removeFirst(messages.count - 40) }
    }

    static func attenuation(_ distance: Double) -> Int {
        // DEF FN A(X), line 910. Distances are original megameters.
        Int(floor(20000 / (10 + pow(distance / 10, 2))))
    }

    var currentShip: ConflictUnit { ships[selected] }
    var remainingEnemies: Int { enemies.filter { $0.energy > 0 }.count }
    var victory: Bool {
        let friendlyPercent = ships.filter { $0.energy > 0 }.count * 100 / ships.count
        let enemyPercent = enemies.filter { $0.energy > 0 }.count * 100 / enemies.count
        return ended && friendlyPercent > enemyPercent && (bases.contains { $0.energy > 0 } || planets.contains { $0.energy > 0 })
    }

    mutating func selectShip(_ index: Int) {
        guard !ended, ships.indices.contains(index), !ships[index].destroyed else { return }
        selected = index
        placementUsed = false // 3226; do not reset the per-turn FIRE flag.
    }

    mutating func nextShip() {
        guard !ended else { return }
        placementUsed = false
        if let next = ships.indices.dropFirst(selected + 1).first(where: { !ships[$0].destroyed }) {
            selected = next
        } else { advanceTurn() }
    }

    private mutating func selectFirstSurvivor() {
        if let first = ships.indices.first(where: { !ships[$0].destroyed }) { selected = first }
        else { ended = true }
    }

    @discardableResult
    mutating func changeCourse(speed: Int, heading: Int) -> Bool {
        guard !ended, !currentShip.destroyed, (0...5000).contains(speed),
              (0...359).contains(heading), speed <= currentShip.energy else {
            log("Course rejected: speed 0–5000, heading 0–359, sufficient energy required.")
            return false
        }
        // 2570 uses 57, not the more precise firing constant 57.2957795.
        ships[selected].dx = Int(floor(Double(speed) * sin(Double(heading) / 57)))
        ships[selected].dy = Int(floor(-Double(speed) * cos(Double(heading) / 57)))
        log("Ship #\(selected): course \(heading)°, speed \(speed).")
        return true
    }

    @discardableResult
    mutating func fire(angle: Int, power: Int) -> Bool {
        guard !ended, !currentShip.destroyed, !currentShip.fired,
              (0...360).contains(angle), (0...200).contains(power), power * 50 <= currentShip.energy else {
            log("Fire rejected: one shot per turn, angle 0–360, power 0–200, sufficient energy required.")
            return false
        }
        let origin = currentShip
        ships[selected].energy -= power * 50
        ships[selected].fired = true
        let a = Int(floor(10 * sin(Double(angle) / 57.2957795)))
        let b = Int(floor(-10 * cos(Double(angle) / 57.2957795)))
        // 2351-2410: prefilter by Manhattan distance, then sample every 10.
        let candidates = enemies.indices.filter { !enemies[$0].destroyed && manhattan(origin.x, origin.y, enemies[$0].x, enemies[$0].y) < 1290 }
        for step in stride(from: 0, through: 200, by: 10) {
            for index in candidates {
                let enemy = enemies[index]
                if manhattan(origin.x + a * step, origin.y + b * step, enemy.x, enemy.y) < 150 {
                    let distance = max(155, manhattan(origin.x, origin.y, enemy.x, enemy.y))
                    enemies[index].energy -= power * Self.attenuation(Double(distance))
                    shipPriority *= 1.5
                    log("Planet pulverizer #\(index) hit by ship #\(selected).")
                    if enemies[index].destroyed {
                        ships[selected].kills += 1
                        shipPriority *= 2
                        log("Planet pulverizer #\(index) destroyed.")
                    }
                    return true
                }
            }
        }
        log("Ship #\(selected) fired; no target hit.")
        return true
    }

    @discardableResult
    mutating func dock(_ kind: ConflictDock, transfer: Int = 0) -> Bool {
        guard !ended, !currentShip.destroyed else { return false }
        if kind != .ship && currentShip.energy > 24999 {
            log("Too much energy on board to refuel.")
            return false
        }
        let before = currentShip.energy
        switch kind {
        case .base:
            guard before <= 10000 else { log("Base can only refuel to 10000."); return false }
            for base in bases where !base.destroyed && nearby(base.x, base.y) {
                ships[selected].energy = 10000; basePriority *= 1.5
                log("Ship docked with base.")
            }
        case .planet:
            for planet in planets where !planet.destroyed && nearby(planet.x, planet.y) {
                ships[selected].energy = 30000; planetPriority *= 1.5
                log("Ship in orbit.")
            }
        case .ship:
            // Every adjacent ship is prompted in the source. Native UI chooses
            // one transfer amount, applied to the first eligible adjacent ship.
            guard let other = ships.indices.first(where: { $0 != selected && !ships[$0].destroyed && nearby(ships[$0].x, ships[$0].y) }) else {
                log("No ship close enough to dock."); return false
            }
            let source = before.subtractingReportingOverflow(transfer)
            let target = ships[other].energy.addingReportingOverflow(transfer)
            guard !source.overflow, !target.overflow, (0...30000).contains(source.partialValue), (0...30000).contains(target.partialValue) else {
                log("Both ships must retain 0–30000 energy."); return false
            }
            ships[selected].energy = source.partialValue; ships[other].energy = target.partialValue
            log("Transferred \(transfer) energy to ship #\(other).")
        }
        if currentShip.energy == before { log("Refueling not possible."); return false }
        return true
    }

    private func nearby(_ x: Int, _ y: Int) -> Bool {
        abs(x - currentShip.x) < 300 && abs(y - currentShip.y) < 300
    }

    @discardableResult
    mutating func setMine() -> Bool {
        guard !ended, !currentShip.destroyed, !placementUsed, placedMine + 1 < mines.count else {
            log("No mine can be placed for this selection."); return false
        }
        placedMine += 1
        mines[placedMine] = ConflictObject(x: currentShip.x, y: currentShip.y, energy: 0)
        placementUsed = true
        log("Mine #\(placedMine) placed. Move more than 500 MM away before ending the turn.")
        return true
    }

    @discardableResult
    mutating func armMine() -> Bool {
        guard !ended, placementUsed, placedMine > 0, mines.indices.contains(placedMine) else { return false }
        mines[placedMine].energy = 10000
        log("Mine #\(placedMine) armed.")
        return true
    }

    mutating func advanceTurn() {
        guard !ended else { return }
        selectFirstSurvivor()
        guard !ended else { return }
        resolveEnemyOrders() // 200: computer fires before either fleet moves.
        moveFleets()
        resolveMines()
        turn += 1
        for index in ships.indices { ships[index].fired = false }
        ended = !enemies.contains { $0.energy > 0 } || !ships.contains { $0.energy > 0 }
        if !ended { selectFirstSurvivor() }
        log(ended ? (victory ? "You saved the universe." : "You lose.") : "Turn \(turn). \(remainingEnemies) planet pulverizers remaining.")
    }

    mutating func finish() { ended = true; log(victory ? "You saved the universe." : "You lose.") }

    private func manhattan(_ x: Int, _ y: Int, _ x2: Int, _ y2: Int) -> Int { abs(x - x2) + abs(y - y2) }

    private mutating func resolveEnemyOrders() {
        for index in enemies.indices where !enemies[index].destroyed {
            let enemy = enemies[index]
            var best = 0.0
            var target: (kind: Int, index: Int, x: Int, y: Int)?
            func consider(_ kind: Int, _ i: Int, _ x: Int, _ y: Int, _ priority: Double) {
                let distance = manhattan(enemy.x, enemy.y, x, y)
                let score = distance == 0 ? Double.infinity : priority / Double(distance)
                if score > best { best = score; target = (kind, i, x, y) }
            }
            // 1130-1210: exact tie order: ship, planet, base, first index.
            for i in ships.indices where !ships[i].destroyed { consider(3, i, ships[i].x, ships[i].y, shipPriority) }
            for i in planets.indices where !planets[i].destroyed { consider(5, i, planets[i].x, planets[i].y, planetPriority) }
            for i in bases.indices where !bases[i].destroyed { consider(1, i, bases[i].x, bases[i].y, basePriority) }
            guard let target else { continue }
            let distance = hypot(Double(enemy.x - target.x), Double(enemy.y - target.y))
            let attack = distance < 500 + 1500 * random()
            // 1300 clamps RD before returning; movement thus uses the clamp.
            let rd = attack ? max(200, distance) : distance
            if attack {
                // 1350-1440 resolves by coordinates, independent of the target
                // chosen by priority. First coincident ship intercepts; otherwise
                // every coincident planet/base takes a separately sampled hit.
                if let ship = ships.indices.first(where: { ships[$0].x == target.x && ships[$0].y == target.y }) {
                    ships[ship].energy = Int(Double(ships[ship].energy) - 500 * random() * Double(Self.attenuation(rd)))
                    log("Planet pulverizer #\(index) attacked ship #\(ship).")
                } else {
                    for planet in planets.indices where planets[planet].x == target.x && planets[planet].y == target.y {
                        planets[planet].energy = Int(Double(planets[planet].energy) - 500 * random() * Double(Self.attenuation(rd)))
                        log("Planet pulverizer #\(index) attacked planet #\(planet).")
                    }
                    for base in bases.indices where bases[base].x == target.x && bases[base].y == target.y {
                        bases[base].energy = Int(Double(bases[base].energy) - 500 * random() * Double(Self.attenuation(rd)))
                        log("Planet pulverizer #\(index) attacked base #\(base).")
                    }
                }
            }
            let divisor = sqrt(max(rd, 1))
            // 1250-1270 assign to integer arrays before multiplying by five.
            enemies[index].dx = Int(Double(target.x - enemy.x) / divisor) * 5
            enemies[index].dy = Int(Double(target.y - enemy.y) / divisor) * 5
        }
    }

    private mutating func moveFleets() {
        for index in enemies.indices where !enemies[index].destroyed {
            enemies[index].x = max(1000, min(13999, enemies[index].x + enemies[index].dx))
            enemies[index].y = max(1000, min(8999, enemies[index].y + enemies[index].dy))
            if enemies[index].energy < 15000 { enemies[index].energy = Int(Double(enemies[index].energy) * 1.3) }
        }
        for index in ships.indices where !ships[index].destroyed {
            ships[index].x += ships[index].dx; ships[index].y += ships[index].dy
            if ships[index].x > 13700 { ships[index].x = 13700; ships[index].dx = 0 }
            if ships[index].x < 1100 { ships[index].x = 1100; ships[index].dx = 0 }
            if ships[index].y > 9700 { ships[index].y = 9700; ships[index].dy = 0 }
            if ships[index].y < 1100 { ships[index].y = 1100; ships[index].dy = 0 }
            // Source charges the post-clamp velocity, even on a boundary turn.
            ships[index].energy -= abs(ships[index].dx) + abs(ships[index].dy)
        }
    }

    private mutating func resolveMines() {
        for index in mines.indices where mines[index].energy > 0 {
            for ship in ships.indices where !ships[ship].destroyed {
                let distance = hypot(Double(mines[index].x - ships[ship].x), Double(mines[index].y - ships[ship].y))
                if distance <= 500 {
                    mines[index].energy = 0
                    ships[ship].energy = Int(Double(ships[ship].energy) - 500 * random() * Double(Self.attenuation(max(175, distance))))
                    log("Ship #\(ship) exploded mine #\(index).")
                }
            }
            // The original continues both loops after a detonation; all ships
            // in range can be hit by one mine in the same resolution.
            for enemy in enemies.indices where !enemies[enemy].destroyed {
                let distance = hypot(Double(mines[index].x - enemies[enemy].x), Double(mines[index].y - enemies[enemy].y))
                if distance <= 500 {
                    mineDetection += 0.05
                    if random() < mineDetection {
                        mines[index] = ConflictObject(x: 0, y: 0, energy: 0)
                        log("Mine detected by planet pulverizer #\(enemy).")
                    } else {
                        enemies[enemy].energy = Int(Double(enemies[enemy].energy) - 500 * random() * Double(Self.attenuation(max(175, distance))))
                        mines[index].energy = 0
                        log("Planet pulverizer #\(enemy) exploded mine #\(index).")
                    }
                }
            }
        }
    }

    func mapCell(column: Int, row: Int) -> String {
        var symbols = ""
        for unit in bases where !unit.destroyed && unit.x / 1000 == column && unit.y / 1000 == row { symbols += "B" }
        for i in ships.indices where !ships[i].destroyed && ships[i].x / 1000 == column && ships[i].y / 1000 == row { symbols += String(i) }
        for unit in mines where unit.energy > 0 && unit.x / 1000 == column && unit.y / 1000 == row { symbols += "M" }
        for unit in planets where !unit.destroyed && unit.x / 1000 == column && unit.y / 1000 == row { symbols += "P" }
        // Enemy ships intentionally remain absent from the galactic map.
        return symbols.isEmpty ? "." : symbols
    }

    var snapshot: ConflictSnapshot {
        ConflictSnapshot(scenario: scenario, ships: ships, enemies: enemies, bases: bases, planets: planets, mines: mines, turn: turn, selected: selected, display: display, placedMine: placedMine, placementUsed: placementUsed, shipPriority: shipPriority, basePriority: basePriority, planetPriority: planetPriority, mineDetection: mineDetection, rng: rng, ended: ended)
    }

    init?(snapshot: ConflictSnapshot) {
        guard snapshot.version == 1, snapshot.sourceIdentity == Self.sourceIdentity, snapshot.scenario.isValid,
              snapshot.ships.count == snapshot.scenario.ships, snapshot.enemies.count == snapshot.scenario.enemies,
              snapshot.planets.count == snapshot.scenario.planets, snapshot.bases.count == snapshot.scenario.bases,
              snapshot.mines.count == snapshot.scenario.ships * 2 + 1,
              snapshot.ships.indices.contains(snapshot.selected), snapshot.mines.indices.contains(snapshot.placedMine),
              snapshot.turn >= 0, snapshot.turn < 1_000_000,
              [snapshot.shipPriority, snapshot.basePriority, snapshot.planetPriority, snapshot.mineDetection].allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 1e100 }),
              (snapshot.ships + snapshot.enemies).allSatisfy({ (0...15000).contains($0.x) && (0...15000).contains($0.y) && (-10000...10000).contains($0.dx) && (-10000...10000).contains($0.dy) && (-100000...30000).contains($0.energy) && $0.kills >= 0 && $0.kills < 100000 }),
              (snapshot.bases + snapshot.planets + snapshot.mines).allSatisfy({ (0...15000).contains($0.x) && (0...15000).contains($0.y) && (-100000...30000).contains($0.energy) }) else { return nil }
        scenario = snapshot.scenario; ships = snapshot.ships; enemies = snapshot.enemies
        bases = snapshot.bases; planets = snapshot.planets; mines = snapshot.mines
        turn = snapshot.turn; selected = snapshot.selected; display = snapshot.display
        placedMine = snapshot.placedMine; placementUsed = snapshot.placementUsed
        shipPriority = snapshot.shipPriority; basePriority = snapshot.basePriority; planetPriority = snapshot.planetPriority
        mineDetection = snapshot.mineDetection; rng = snapshot.rng; ended = snapshot.ended
    }
}
