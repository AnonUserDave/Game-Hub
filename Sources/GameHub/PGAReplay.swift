import Foundation

/// Replay.stn (game event 2, decoded in Library/Imported/pga2005/cameras.json):
/// which finished shots get an automatic replay, and how likely. The rules are
/// the original's; how the original films a replay (ReplayShot, the replay
/// camera setting) is not decoded, so PGAReplayClip's camera is native.
struct PGAReplayRules {
    struct Situation {
        var priority: Int
        var conditions: [(bit: Int, op: Int, value: Int64)]
        var chances: [Int]
        var pickOne: Bool
    }
    let situations: [Situation]

    init(situations: [Situation]) { self.situations = situations }

    static func load(root: URL) -> PGAReplayRules? {
        struct File: Decodable {
            struct Script: Decodable {
                struct Condition: Decodable { var bit: Int; var operator_code: Int; var value: Int64 }
                struct Situation: Decodable {
                    var priority: Int; var conditions: [Condition]; var actions: [Int]; var single_random_action: Bool; var never_matches: Bool?
                }
                struct Action: Decodable { var probability_percent: Int }
                var file: String; var situations: [Situation]; var actions: [Action]
            }
            var scripts: [Script]
        }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Library/Imported/pga2005/cameras.json")), data.count < 20_000_000,
              let file = try? JSONDecoder().decode(File.self, from: data),
              let script = file.scripts.first(where: { $0.file.lowercased() == "replay.stn" }) else { return nil }
        return PGAReplayRules(situations: script.situations.filter { $0.never_matches != true }.map { situation in
            Situation(priority: situation.priority, conditions: situation.conditions.map { ($0.bit, $0.operator_code, $0.value) },
                      chances: situation.actions.compactMap { script.actions.indices.contains($0) ? script.actions[$0].probability_percent : nil },
                      pickOne: situation.single_random_action)
        })
    }

    /// Script operators (FUN_10215b87, unsigned compares).
    static func matches(_ op: Int, _ event: Int64, _ value: Int64) -> Bool {
        let e = UInt64(bitPattern: event), v = UInt64(bitPattern: value)
        switch op {
        case 0: return true
        case 1: return e == v
        case 2: return e != v
        case 3: return e > v
        case 4: return e < v
        case 5: return e & v != 0
        case 6: return e != 0 || v != 0
        case 7: return ~e & v != 0
        case 8: return e & v == 0
        default: return false
        }
    }

    /// Replay chance in percent for a finished shot, or nil: lowest priority
    /// wins, then the situation with more conditions (DoSituationsMatching).
    func chance(for facts: [Int64], random: inout PGARandom) -> Int? {
        let matching = situations.filter { situation in
            situation.conditions.allSatisfy { Self.matches($0.op, $0.bit < facts.count ? facts[$0.bit] : 0, $0.value) }
        }
        guard let best = matching.min(by: { ($0.priority, -$0.conditions.count) < ($1.priority, -$1.conditions.count) }),
              !best.chances.isEmpty else { return nil }
        return best.pickOne ? best.chances[random.int(best.chances.count)] : best.chances.max()
    }

    /// Event 2 values for a finished shot (bits as in the camera/replay scripts).
    static func facts(fromTee: Bool, putt: Bool, startFlags: UInt32, resultFlags: UInt32, holed: Bool,
                      distanceToPin: Double, shotDistance: Double, par: Int, strokes: Int) -> [Int64] {
        var facts = [Int64](repeating: 0, count: 32)
        facts[1] = (fromTee ? 0x1 : 0) | (putt ? 0x2 : 0)
        facts[2] = Int64(startFlags)
        facts[3] = Int64((distanceToPin / 0.0254).rounded())
        facts[4] = Int64((shotDistance / 0.0254).rounded())
        facts[7] = Int64(par)
        facts[8] = Int64(strokes)
        facts[21] = Int64(resultFlags | (holed ? 0x4000 : 0))
        return facts
    }
}

/// A replayed shot: the recorded ball path (15 samples per second) played
/// back in real time with a native TV-style camera: chasing from behind for
/// the first part of the flight, then cutting to a tower view beside the
/// landing area.
struct PGAReplayClip {
    static let sampleRate = 15.0
    let path: [PGAVector]
    private(set) var time = 0.0
    var duration: Double { min(14, Double(max(1, path.count - 1)) / Self.sampleRate + 1.2) }
    var finished: Bool { time >= duration }

    init?(path: [PGAVector]) {
        guard path.count >= 4 else { return nil }
        self.path = path
    }

    mutating func advance(_ delta: Double) { time += delta }

    var ball: PGAVector {
        let position = min(Double(path.count - 1), time * Self.sampleRate)
        let index = Int(position), t = position - Double(index)
        guard index + 1 < path.count else { return path[path.count - 1] }
        return path[index] + (path[index + 1] - path[index]) * t
    }

    /// Camera position and look-at for the current moment.
    var camera: (position: PGAVector, target: PGAVector) {
        let start = path[0], end = path[path.count - 1]
        let along = (end - start).horizontalUnit == .zero ? PGAVector(x: 0, y: 0, z: 1) : (end - start).horizontalUnit
        let side = PGAVector(x: -along.z, y: 0, z: along.x)
        let progress = time * Self.sampleRate / Double(max(1, path.count - 1))
        let ball = self.ball
        if progress < 0.45 {
            return (start - along * 9 + PGAVector(x: 0, y: 3.2, z: 0), ball + PGAVector(x: 0, y: 0.5, z: 0))
        }
        let tower = end + side * 22 - along * 12 + PGAVector(x: 0, y: 9, z: 0)
        return (tower, ball)
    }
}
