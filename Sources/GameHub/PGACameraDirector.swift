import Foundation

/// Native playback of the camera situations decoded from the original .stn
/// files. The scripts are local prepared media, never bundled in Git.
struct PGACameraDirector {
    struct Condition: Decodable {
        let bit: Int
        let operator_code: Int
        let value: UInt32

        func matches(_ facts: [UInt32]) -> Bool {
            let actual = facts.indices.contains(bit) ? facts[bit] : 0
            switch operator_code {
            case 0: return true
            case 1: return actual == value
            case 2: return actual != value
            case 3: return actual > value
            case 4: return actual < value
            case 5: return actual & value != 0
            case 6: return actual != 0 || value != 0
            case 7: return ~actual & value != 0
            case 8: return actual & value == 0
            default: return false
            }
        }
    }

    struct Situation: Decodable {
        let situation_type: Int
        let event: Int
        let conditions: [Condition]
        let actions: [Int]
        let single_random_action: Bool
        let priority: Int
    }

    struct Action: Decodable {
        let probability_percent: Int
        let responses: [Int]
    }

    struct Response: Decodable {
        let response_type: Int
        let command: Int
        let object_type: Int
        let offset_ft: [Double]
        let start_mode: Int
        let flags: Int
        let duration_s: Double
        let amount: Int
    }

    struct Script: Decodable {
        let file: String
        let situations: [Situation]
        let actions: [Action]
        let responses: [Response]
    }

    struct Pose {
        var position: PGAVector
        var target: PGAVector
        var fieldOfView: Double
    }

    private struct Anchor {
        var object: Int
        var offset: PGAVector
    }

    private struct Group {
        var responses: [Response]
        var duration: Double
    }

    private let scripts: [String: Script]
    private var random = PGARandom(seed: "pga2005-camera")
    private var groups: [Group] = []
    private var elapsed = 0.0
    private var fromPose: Pose?
    private var positionAnchor: Anchor?
    private var targetAnchor: Anchor?
    private var zoom = 1.0
    private var currentPose: Pose?
    private var previousMode = -1
    private var previousHole = -1
    private var previousPlayer = -1
    private var previousPhase = PGAPhase.aiming
    private var shotOrigin: PGAVector?
    private var estimatedLanding: PGAVector?
    private var shotDistance = 0.0
    private var flightIndex = 2
    private var shortApproach = false
    private var shortApproachHold = 0.0

    init?(root: URL) {
        let url = root.appendingPathComponent("Library/Imported/pga2005/cameras.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = document["scripts"] as? [[String: Any]] else { return nil }
        var decoded: [String: Script] = [:]
        for record in records {
            guard let name = record["file"] as? String,
                  ["d_camera.stn", "s_camera.stn", "f_camera.stn", "b_camera.stn"].contains(name),
                  let bytes = try? JSONSerialization.data(withJSONObject: record),
                  let script = try? JSONDecoder().decode(Script.self, from: bytes) else { continue }
            decoded[name] = script
        }
        guard !decoded.isEmpty else { return nil }
        scripts = decoded
    }

    mutating func reset() {
        resetView()
        previousMode = -1; previousHole = -1; previousPlayer = -1
        previousPhase = .aiming; shotOrigin = nil; estimatedLanding = nil; flightIndex = 2
        shortApproach = false; shortApproachHold = 0
    }

    private mutating func resetView() {
        groups.removeAll(keepingCapacity: true)
        elapsed = 0; fromPose = nil; positionAnchor = nil; targetAnchor = nil
        currentPose = nil
        zoom = 1
    }

    /// The source game's script type enum is unresolved, so the UI exposes
    /// four named modes directly: Auto, Snap, Fixed, Ball.
    static func file(for mode: Int) -> String {
        ["d_camera.stn", "s_camera.stn", "f_camera.stn", "b_camera.stn"][max(0, min(3, mode))]
    }

    static func fieldOfView(zoom: Double) -> Double {
        let factor = max(0.0625, min(256, zoom <= 1 ? zoom * zoom : zoom))
        return max(10, min(120, 45 / factor))
    }

    mutating func update(_ simulation: PGASimulation, mode: Int, delta: Double) -> Pose? {
        let selected = Self.file(for: mode)
        guard let script = scripts[selected] else { return nil }
        let newHole = simulation.holeIndex != previousHole
        let newMode = mode != previousMode
        let turnChanged = !newHole && !newMode && previousPlayer >= 0 && simulation.currentPlayer != previousPlayer
        if newHole {
            reset()
            previousMode = mode; previousHole = simulation.holeIndex
            random = PGARandom(seed: simulation.course.identity + selected + String(simulation.holeIndex))
            fire(event: 28, script: script, simulation: simulation)
            fire(event: 19, script: script, simulation: simulation)
        } else if newMode {
            resetView()
            shortApproach = false; shortApproachHold = 0
            previousMode = mode
            if simulation.phase.inMotion { fire(event: 3, script: script, simulation: simulation) }
            else if simulation.phase == .holed { fire(event: 29, script: script, simulation: simulation) }
            else { fire(event: 19, script: script, simulation: simulation) }
        }

        if !previousPhase.inMotion && simulation.phase.inMotion {
            shotOrigin = simulation.ball
            shortApproach = mode == 0 && [.wedge, .sandWedge, .lobWedge].contains(simulation.club) &&
                (simulation.shotPower <= 0.65 || simulation.distanceToCup <= 50)
            shortApproachHold = 0
            // A partial wedge's full-club range puts source landing cameras far
            // beyond the actual chip and can produce a reverse view of empty turf.
            let power = shortApproach ? simulation.shotPower * simulation.shotPower : 1
            shotDistance = max(1, simulation.targetDistance * power)
            estimatedLanding = simulation.ball + simulation.direction * shotDistance
            flightIndex = 2
            fire(event: 3, script: script, simulation: simulation)
        }
        if simulation.phase.inMotion, let origin = shotOrigin {
            // Original flight progress uses its sampled predicted trajectory.
            // Travel toward the target is the available native approximation.
            let traveled = origin.distance(to: simulation.ball)
            let next = min(20, max(3, Int(traveled / shotDistance * 20)))
            if next > flightIndex {
                for index in (flightIndex + 1)...next {
                    flightIndex = index
                    fire(event: 1, script: script, simulation: simulation)
                }
            }
        }
        if previousPhase.inMotion && !simulation.phase.inMotion {
            if shortApproach { shortApproachHold = 1.25 }
            fire(event: 22, script: script, simulation: simulation)
            if simulation.phase == .aiming && !turnChanged {
                shotOrigin = nil; estimatedLanding = nil
                fire(event: 19, script: script, simulation: simulation)
            }
        }
        if previousPhase != .holed && simulation.phase == .holed {
            fire(event: 29, script: script, simulation: simulation)
        }
        if turnChanged {
            shotOrigin = nil; estimatedLanding = nil
            fire(event: 19, script: script, simulation: simulation)
        }
        previousPlayer = simulation.currentPlayer
        previousPhase = simulation.phase

        if currentPose == nil { currentPose = fallback(simulation) }
        advance(simulation, delta: max(0, min(0.1, delta)))
        if shortApproach && (simulation.phase.inMotion || shortApproachHold > 0) {
            if !simulation.phase.inMotion { shortApproachHold -= max(0, min(0.1, delta)) }
            let pose = shortApproachPose(simulation)
            currentPose = pose
            return pose
        }
        if shortApproach {
            shortApproach = false
            resetView()
            fire(event: 19, script: script, simulation: simulation)
            advance(simulation, delta: 0)
        }
        return currentPose
    }

    private mutating func fire(event: Int, script: Script, simulation: PGASimulation) {
        let facts = facts(for: simulation)
        let candidates = script.situations.filter {
            $0.situation_type == 11 && ($0.event == event || $0.event == 0) && !$0.actions.isEmpty &&
            $0.conditions.allSatisfy { $0.matches(facts) }
        }
        guard let priority = candidates.map(\.priority).min() else { return }
        let ranked = candidates.filter { $0.priority == priority }
        let count = ranked.map { $0.conditions.count }.max() ?? 0
        let tied = ranked.filter { $0.conditions.count == count }
        let situation = tied[random.int(tied.count)]
        let choices = situation.single_random_action ? [situation.actions[random.int(situation.actions.count)]] : situation.actions
        for index in choices where script.actions.indices.contains(index) {
            let action = script.actions[index]
            guard random.int(100) < action.probability_percent else { continue }
            let responses = action.responses.compactMap { script.responses.indices.contains($0) ? script.responses[$0] : nil }
                .filter { $0.response_type == 13 }
            enqueue(responses)
        }
    }

    private mutating func enqueue(_ responses: [Response]) {
        guard !responses.isEmpty else { return }
        let firstFlags = responses[0].flags
        if !groups.isEmpty && firstFlags & 4 == 0 && firstFlags & 8 == 0 { return }
        if firstFlags & 2 != 0 || firstFlags & 4 != 0 { groups.removeAll(keepingCapacity: true); elapsed = 0 }
        for response in responses {
            if groups.isEmpty || response.start_mode == 1 {
                groups.append(Group(responses: [response], duration: response.duration_s))
            } else {
                groups[groups.count - 1].responses.append(response)
                groups[groups.count - 1].duration = max(groups[groups.count - 1].duration, response.duration_s)
            }
        }
        if fromPose == nil { fromPose = currentPose }
    }

    private mutating func advance(_ simulation: PGASimulation, delta: Double) {
        guard !groups.isEmpty else {
            if currentPose != nil { currentPose = resolvedPose(simulation) }
            return
        }
        var remaining = delta
        while let group = groups.first {
            if elapsed == 0 {
                fromPose = currentPose ?? fallback(simulation)
                apply(group.responses)
            }
            let destination = resolvedPose(simulation)
            let duration = group.duration
            if duration <= 0 {
                currentPose = destination
                groups.removeFirst(); elapsed = 0
                continue
            }
            let step = min(remaining, duration - elapsed)
            elapsed += step; remaining -= step
            let t = min(1, elapsed / duration)
            let ease = 0.5 - 0.5 * cos(.pi * t)
            let start = fromPose ?? destination
            currentPose = Pose(position: start.position + (destination.position - start.position) * ease,
                               target: start.target + (destination.target - start.target) * ease,
                               fieldOfView: start.fieldOfView + (destination.fieldOfView - start.fieldOfView) * ease)
            if elapsed + 0.000001 < duration || remaining <= 0 { break }
            groups.removeFirst(); elapsed = 0
        }
    }

    private mutating func apply(_ responses: [Response]) {
        for response in responses {
            // CameraResponse adds reset-view to every Attach command even when
            // the raw response byte does not carry that bit.
            if response.flags & 1 != 0 || response.command == 0 { zoom = 1 }
            let offset = response.offset_ft.count == 3
                ? PGAVector(x: response.offset_ft[0] * 0.3048, y: response.offset_ft[1] * 0.3048, z: response.offset_ft[2] * 0.3048)
                : .zero
            switch response.command {
            case 0: positionAnchor = Anchor(object: response.object_type, offset: offset)
            case 1: targetAnchor = Anchor(object: response.object_type, offset: offset)
            case 6: zoom = max(0.1, Double(response.amount) / 100)
            default: break // Pan, fly-over, slow motion and replay filming need separate work.
            }
        }
    }

    private func resolvedPose(_ simulation: PGASimulation) -> Pose {
        let fallback = fallback(simulation)
        let position = positionAnchor.map { resolve($0, simulation: simulation) } ?? fallback.position
        let target = targetAnchor.map { resolve($0, simulation: simulation) } ?? fallback.target
        return Pose(position: position, target: target, fieldOfView: Self.fieldOfView(zoom: zoom))
    }

    private func fallback(_ simulation: PGASimulation) -> Pose {
        let ball = simulation.ball, direction = simulation.direction
        return Pose(position: ball - direction * 4 + PGAVector(x: 0, y: 2, z: 0),
                    target: ball + PGAVector(x: 0, y: 1, z: 0), fieldOfView: 45)
    }

    /// Keep a chip and its nearby landing area ahead of the camera. This
    /// follows the actual ball rather than a speculative full-wedge landing.
    private func shortApproachPose(_ simulation: PGASimulation) -> Pose {
        let ball = simulation.ball, direction = simulation.direction
        let ground = simulation.groundHeight(x: ball.x, z: ball.z, near: ball.y)
        let position = PGAVector(x: ball.x - direction.x * 7, y: ground + 3.5,
                                 z: ball.z - direction.z * 7)
        let target = PGAVector(x: ball.x + direction.x * 4, y: max(ball.y, ground + 0.5),
                               z: ball.z + direction.z * 4)
        return Pose(position: position, target: target, fieldOfView: 60)
    }

    private func resolve(_ anchor: Anchor, simulation: PGASimulation) -> PGAVector {
        let ball = simulation.ball, golfer = shotOrigin ?? ball, hole = simulation.hole
        let base: PGAVector
        let forward: PGAVector
        switch anchor.object {
        case 1: base = hole.tee; forward = (hole.cup - hole.tee).horizontalUnit
        case 2: base = hole.cup; forward = (hole.tee - hole.cup).horizontalUnit
        case 3, 4, 17: base = estimatedLanding ?? (ball + simulation.direction * simulation.targetDistance); forward = (ball - base).horizontalUnit
        case 5, 6: base = ball; forward = simulation.velocity.horizontalLength > 0.1 ? simulation.velocity.horizontalUnit : simulation.direction
        case 7, 8: base = golfer; forward = simulation.direction
        case 9, 10: base = golfer + PGAVector(x: 0, y: 1.7, z: 0); forward = simulation.direction
        case 11, 14: base = (ball + hole.cup) * 0.5; forward = (hole.cup - ball).horizontalUnit
        case 12, 15: base = (golfer + hole.cup) * 0.5; forward = (hole.cup - golfer).horizontalUnit
        case 13, 16: base = (golfer + ball) * 0.5; forward = simulation.direction
        case 18: base = ball + PGAVector(x: 0, y: max(0, ball.y - golfer.y), z: 0); forward = simulation.direction
        default: base = currentPose?.position ?? ball; forward = simulation.direction
        }
        let right = PGAVector(x: forward.z, y: 0, z: -forward.x)
        return base + right * anchor.offset.x + PGAVector(x: 0, y: anchor.offset.y, z: 0) + forward * anchor.offset.z
    }

    private func facts(for simulation: PGASimulation) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: 32)
        result[0] = UInt32(PGAAudioRules.clubMask(simulation.club))
        result[1] = simulation.club == .putter ? 2 : shortApproach ? (simulation.club == .wedge ? 0x4 : 0x800)
            : (simulation.strokes <= 1 ? 0x401 : 0x400)
        let origin = shotOrigin ?? simulation.ball
        let originSample = simulation.ground(x: origin.x, z: origin.z, ceiling: origin.y + 0.3)
        let originFlags = originSample?.properties?.flags ?? PGAAudioRules.flags(for: originSample?.surface ?? simulation.lie)
        result[2] = originFlags | (originSample?.surface == .tee ? 0x8000 : 0)
        let destination = simulation.phase.inMotion ? (estimatedLanding ?? simulation.ball) : simulation.ball
        let distance = UInt32(max(0, min(Double(UInt32.max), destination.distance(to: simulation.hole.cup) / 0.0254)))
        result[3] = distance; result[15] = distance
        let travel = UInt32(max(0, min(Double(UInt32.max), shotDistance / 0.0254)))
        result[4] = travel; result[22] = travel
        result[7] = UInt32(simulation.hole.par)
        result[8] = UInt32(simulation.strokes)
        result[9] = UInt32(bitPattern: Int32(clamping: simulation.strokes - simulation.hole.par))
        result[12] = UInt32(flightIndex)
        result[14] = 1 // Only the decoded male golfer is available.
        let destinationSample = simulation.ground(x: destination.x, z: destination.z)
        result[21] = (destinationSample?.properties?.flags ?? PGAAudioRules.flags(for: destinationSample?.surface ?? simulation.lie)) |
            (simulation.phase == .holed ? 0x4000 : 0)
        result[29] = simulation.course.isOriginal ? 0 : 0x40
        return result
    }
}
