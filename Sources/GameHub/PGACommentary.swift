import Foundation

// Original TV commentary (announcer.stn, analyst.stn) and the gallery's
// shot rules, driven by the class-2 shot event. Decoded statically; see
// docs/research/PGA2005-COMMENTARY.md for every address quoted here. The
// script tables come from Tools/import_pga2005_audio.py (commentary.json).

/// One situation event as the original script interpreter sees it: the event
/// class (SituationEvent+0x275), sub (+0x279), the constructor's "available
/// value" mask (+0x27d) and the values, here indexed by condition bit.
struct PGAScriptFacts: Equatable {
    var eventClass: Int
    var sub: Int
    var mask: UInt32
    var values: [Int64]

    init(eventClass: Int, sub: Int, mask: UInt32, values: [Int64] = Array(repeating: 0, count: 32)) {
        self.eventClass = eventClass; self.sub = sub; self.mask = mask
        self.values = values.count >= 32 ? values : values + Array(repeating: 0, count: 32 - values.count)
    }

    subscript(bit: Int) -> Int64 {
        get { values[bit] }
        set { values[bit] = newValue }
    }

    /// FUN_10215b87: the builder stores values compactly from +0x33f, and a
    /// condition on `bit` reads entry popcount(mask & (bit − 1)). For a bit the
    /// event provides that is its own value; for one it does not, it is the
    /// next provided bit's value (or 0 past the end of the 32-entry array).
    func compared(bit: Int) -> UInt32 {
        guard (0..<32).contains(bit) else { return 0 }
        var index = (mask & ((UInt32(1) << UInt32(bit)) &- 1)).nonzeroBitCount
        for candidate in 0..<32 where mask >> UInt32(candidate) & 1 == 1 {
            if index == 0 { return UInt32(truncatingIfNeeded: values[candidate]) }
            index -= 1
        }
        return 0
    }

    // Constructor masks (SituationEvent+0x27d).
    static let shotMask: UInt32 = 0x6FFF_FFDF      // ShotEvent 0x10214632 / CommentatorShotEvent 0x1021574f
    static let swingMask: UInt32 = 0x0830_512F     // SwingEvent 0x102141db / CommentatorSwingEvent 0x102157b3
    static let locationMask: UInt32 = 0x778A_62CA  // LocationEvent 0x102150e8 / CommentatorLocationEvent 0x10215781
    static let introMask: UInt32 = 0x7C82_2246     // CommentatorIntroEvent 0x102154a1
}

/// The decoded scripts (commentary.json).
struct PGAScriptBook: Decodable {
    struct Condition: Decodable, Equatable {
        var bit: Int
        var op: String
        var value: UInt32
        init(bit: Int, op: String, value: UInt32) { self.bit = bit; self.op = op; self.value = value }
        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            bit = try row.decode(Int.self); op = try row.decode(String.self)
            value = UInt32(clamping: Int64(try row.decode(Double.self)))
        }

        /// Operators of FUN_10215b87; 3 and 4 compare unsigned, an unknown
        /// operator (0xffff in the data) never matches.
        func matches(_ facts: PGAScriptFacts) -> Bool {
            let event = facts.compared(bit: bit)
            switch op {
            case "always": return true
            case "eq": return event == value
            case "ne": return event != value
            case "gt": return event > value
            case "lt": return event < value
            case "any_bits": return event & value != 0
            case "either_nonzero": return event != 0 || value != 0
            case "missing_bits": return ~event & value != 0
            case "no_bits": return event & value == 0
            default: return false
            }
        }
    }
    struct Situation: Decodable {
        var i: Int
        var c: Int
        var s: Int
        var p: Int
        var one: Bool
        var `if`: [Condition]
        var `do`: [Int]
        var d: String
        var conditionMask: UInt32 { `if`.reduce(0) { $0 | UInt32(1) << UInt32($1.bit) } }
    }
    struct Action: Decodable {
        var t: Int
        var p: Int
        var fl: UInt32
        var seq: Bool
        var r: [Int]
    }
    struct Response: Decodable {
        var t: Int
        /// Imported path relative to the audio directory; nil plays silence.
        var f: String?
    }
    struct Script: Decodable {
        var situations: [Situation]
        var actions: [Action]
        var responses: [Response]
    }
    var scripts: [String: Script]

    static func load(directory: URL) -> PGAScriptBook? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("commentary.json")) else { return nil }
        return try? JSONDecoder().decode(PGAScriptBook.self, from: data)
    }
}

/// The hard-coded part of the original situation-script engine, for the
/// commentary (action type 8) and gallery (type 12) scripts. Pure value type:
/// the audio queue owns one, tests drive it with a seeded generator.
struct PGAScriptInterpreter {
    /// One response the original would play now. Sequences list several.
    struct Play: Equatable {
        var script: String
        var situation: String
        var files: [String]
        var commentary: Bool
        /// Action flag 0x10: placed 750–3000 units from the event (gallery).
        var positional: Bool
    }

    /// SoundResponse::Invoke 0x102173e2: no identical commentary file within 20 s.
    static let repeatWindow = 20.0
    /// FUN_102160a5: drops while a commentary line plays before the handle is reset.
    static let dropLimit = 16

    private(set) var fired: [String: [Int: Int]] = [:]
    private(set) var plays: [String: [Int: Int]] = [:]
    /// Original shared state (globals 0x1038c838, 0x104503cc, 0x10450290/98).
    private(set) var drops = 0
    /// Set after 16 drops: the next line no longer waits for the old one.
    private(set) var handleForgotten = false
    private(set) var lastFile: String?
    private(set) var lastStart = -Double.infinity

    /// Script::FindSituationsMatching 0x1020bfe3 (no immediate actions or
    /// bit-31 rules occur in these scripts; the importer test checks that).
    static func matching(_ script: PGAScriptBook.Script, facts: PGAScriptFacts) -> [Int] {
        script.situations.indices.filter { index in
            let situation = script.situations[index]
            guard situation.c == facts.eventClass, situation.s == 0 || situation.s == facts.sub,
                  !situation.do.isEmpty else { return false }
            let mask = situation.conditionMask
            if facts.mask != 0 && mask != 0 && facts.mask & mask == 0 { return false }
            return situation.if.allSatisfy { $0.matches(facts) }
        }
    }

    /// Script::WillExecute 0x1020bc92: a situation matches (probabilities aside).
    static func willExecute(_ script: PGAScriptBook.Script, facts: PGAScriptFacts) -> Bool {
        !matching(script, facts: facts).isEmpty
    }

    /// The situations tied for first place before the random draw.
    func best(_ name: String, script: PGAScriptBook.Script, facts: PGAScriptFacts) -> [Int] {
        let candidates = Self.matching(script, facts: facts)
        let ranks = candidates.map { (script.situations[$0].p, -script.situations[$0].if.count, fired[name]?[$0] ?? 0) }
        guard let top = ranks.min(by: { $0 < $1 }) else { return [] }
        return zip(candidates, ranks).filter { $0.1 == top }.map(\.0)
    }

    /// Script::EventOccurrence for one script. `busyUntil` is when the current
    /// commentary line ends (shared by every script); `force` is
    /// ForceRandomActions (probabilities ignored).
    mutating func run<R: RandomNumberGenerator>(_ name: String, script: PGAScriptBook.Script, facts: PGAScriptFacts,
                                                 now: Double, busyUntil: Double, force: Bool = false,
                                                 using random: inout R) -> [Play] {
        // DoSituationsMatching 0x1020c1df: lowest priority byte, then most
        // conditions, then least fired, then uniform.
        let tied = best(name, script: script, facts: facts)
        guard !tied.isEmpty else { return [] }
        if busyUntil <= now { handleForgotten = false }
        let chosen = tied[Int.random(in: 0..<tied.count, using: &random)]
        fired[name, default: [:]][chosen, default: 0] += 1
        let situation = script.situations[chosen]
        let actions = situation.one ? [situation.do[Int.random(in: 0..<situation.do.count, using: &random)]] : situation.do
        var output: [Play] = []
        var busy = busyUntil
        for index in actions where script.actions.indices.contains(index) {
            let action = script.actions[index]
            // Script::IsIgnored: types 8 (commentary) and 9 (gallery) use the
            // default "on" frequency 3, so they are never ignored.
            guard action.t == 8 || action.t == 9 else { continue }
            if !force && Int.random(in: 1...100, using: &random) > action.p { continue }
            let commentary = action.t == 8
            if commentary && busy > now && !handleForgotten {
                // After 16 drops the original forgets the playing handle; the
                // next line then starts (natively it interrupts, never overlaps).
                drops += 1
                if drops >= Self.dropLimit { drops = 0; handleForgotten = true }
                continue
            }
            if commentary { drops = 0; handleForgotten = false }
            var files: [String] = []
            let picks = action.seq ? action.r : leastPlayed(name, action.r, using: &random).map { [$0] } ?? []
            if action.seq, let first = action.r.first { plays[name, default: [:]][first, default: 0] += 1 }
            for response in picks where script.responses.indices.contains(response) {
                guard let file = script.responses[response].f else { continue }
                if commentary {
                    if file == lastFile && now - lastStart < Self.repeatWindow { continue }
                    lastFile = file; lastStart = now
                }
                files.append(file)
            }
            guard !files.isEmpty else { continue }
            // The new sample is now the playing handle for later actions.
            if commentary { busy = .infinity }
            output.append(Play(script: name, situation: situation.d, files: files, commentary: commentary,
                               positional: action.fl & 0x10 != 0))
        }
        return output
    }

    /// FUN_10216d78: uniform among the entries with the fewest plays. Repeated
    /// ids share one counter, so a duplicate weights the choice.
    private mutating func leastPlayed<R: RandomNumberGenerator>(_ name: String, _ ids: [Int], using random: inout R) -> Int? {
        guard !ids.isEmpty else { return nil }
        let counts = plays[name] ?? [:]
        let fewest = ids.map { counts[$0] ?? 0 }.min()!
        let pool = ids.filter { (counts[$0] ?? 0) == fewest }
        let pick = pool[Int.random(in: 0..<pool.count, using: &random)]
        plays[name, default: [:]][pick, default: 0] += 1
        return pick
    }

}

// MARK: - Class-2 shot values (ShotEvent fill 0x102146cb)

/// Native inputs for one shot event, in meters and radians. Each field names
/// the original source it stands for.
struct PGAShotInputs {
    /// 1 in flight (CommentatorBallInFlight), 2 stopped (EndShot), 19 before the shot (BeginShot).
    var sub: Int
    /// CPlayer::GetLastClub: original club index (0 driver … 20 putter).
    var club: Int
    /// CPlayer+0x78dd shot style: 0–2 normal, 4 punch, 5 lob, 6 putt, 7 chip, 8 pick.
    var shotStyle = 0
    /// GetStrokesThisHole: before the shot for subs 1/19, after it for sub 2.
    var strokes: Int
    /// The ball position carries the on-tee attribute (0x8000).
    var ballOnTee = false
    /// TerrainTypeFlags at CPlayer::GetPosition (the address).
    var addressFlags: UInt32
    var golfer: PGAVector
    /// Ball rest (sub 2) or the precalculated end (CGolfBall::EndPosition) in flight.
    var ball: PGAVector
    /// TerrainTypeFlags at `ball` (0x4000 = in the hole).
    var ballFlags: UInt32
    /// Position sub-terrain (lie record) at `ball`.
    var ballSubTerrain = 0
    /// CPlayer ball position (+0x13e2): the lie the shot was played from until it rests.
    var playerBall: PGAVector
    var playerBallHoled = false
    var pin: PGAVector
    /// CPlayer::GetIdealPosition: the pin, or the caddy's target on long holes.
    var ideal: PGAVector
    /// CPlayer::AimAngle; direction (sin h, 0, cos h).
    var aimHeading: Double
    var hole: Int
    var par: Int
    /// 0x3f3: flight index for sub 1, else 0.
    var flightIndex = 0
    /// Course wind (course+0x581) and the direction the air moves toward.
    var windMph = 0.0
    var windDirection = 0.0
    var modelFlags: Int64 = 1
    var modelType: Int64 = 1
    /// CPlayer+0x15ff.
    var putts = 0
    /// FUN_1021088a and FUN_10210ae3 (see PGACommentaryContext).
    var score: Int64 = 0
    var standing: Int64 = 0
    /// FUN_10212e7b, for a point on the green.
    var greenSlope: UInt32 = 0
    /// Position::GetElevation of the ideal point and the player's ball (meters).
    var idealElevation = 0.0
    var ballElevation = 0.0
    var gameFormat: Int64 = 1
    var gameFlags: UInt32 = 0x200000
}

enum PGAShotFacts {
    static let inch = PGACourseTransform.metersPerInch
    /// ftol: truncation toward zero.
    static func ftol(_ value: Double) -> Int64 { value.isFinite ? Int64(max(-2e9, min(2e9, value)).rounded(.towardZero)) : 0 }

    /// FUN_1021038a, from the original club index.
    static func clubMask(_ club: Int) -> Int64 {
        var mask: Int64 = 0
        if club > 7 && club < 45 && club != 20 { mask |= 0x4 }
        if (0..<8).contains(club) { mask |= 0x2 }
        if club == 0 || club == 1 { mask |= 0x1 }
        if club > 20 && club < 33 { mask |= 0x8 }
        if club == 20 { mask |= 0x10 }
        if (8...11).contains(club) || (21...24).contains(club) || (33...36).contains(club) { mask |= 0x40 }
        if (12...15).contains(club) || (25...28).contains(club) || (37...40).contains(club) { mask |= 0x80 }
        if (16...19).contains(club) || (29...32).contains(club) || (41...44).contains(club) { mask |= 0x100 }
        if (17...19).contains(club) || (30...32).contains(club) { mask |= 0x20 }
        return mask
    }

    /// FUN_102104f9 outside impact (the toe/heel and launch-angle bands are
    /// only filled for subs 3 and 17).
    static func shotFlags(strokes: Int, ballOnTee: Bool, style: Int) -> Int64 {
        var flags: Int64 = strokes == 0 || ballOnTee ? 0x1 : 0
        switch style {
        case 0, 1, 2: flags |= 0x400
        case 3: flags |= 0x800
        case 4: flags |= 0x1000
        case 5: flags |= 0x2000
        case 6: flags |= 0x2
        case 7: flags |= 0x4
        case 8: flags |= 0x4000
        case 9: flags |= 0x8000
        default: break
        }
        return flags
    }

    /// Right of a horizontal heading in the native (right-handed, mirrored-z)
    /// frame; it is +x of the source's left-handed frame.
    static func right(of forward: PGAVector) -> PGAVector { PGAVector(x: -forward.z, y: 0, z: forward.x) }
    static func dot(_ a: PGAVector, _ b: PGAVector) -> Double { a.x * b.x + a.z * b.z }

    /// FUN_10212c19: miss of the shot's end against the ideal line from the
    /// golfer. Returns (flags 1 left / 2 right | 4 short / 8 long, lateral
    /// inches, depth inches).
    static func miss(golfer: PGAVector, end: PGAVector, ideal: PGAVector) -> (flags: Int64, lateral: Int64, depth: Int64) {
        let toIdeal = PGAVector(x: ideal.x - golfer.x, y: 0, z: ideal.z - golfer.z)
        let line = toIdeal.horizontalLength > 1e-9 ? toIdeal.horizontalUnit : PGAVector(x: 0, y: 0, z: 1)
        let shot = PGAVector(x: end.x - golfer.x, y: 0, z: end.z - golfer.z)
        let lateral = dot(shot, right(of: line)), forward = dot(shot, line)
        let target = toIdeal.horizontalLength, targetLateral = dot(toIdeal, right(of: line))
        let flags: Int64 = (lateral <= targetLateral ? 1 : 2) | (forward <= target ? 4 : 8)
        return (flags, ftol(abs(lateral) / inch), ftol(abs(forward - target) / inch))
    }

    /// Bit 16: wind against the aim (1 left→right, 2 right→left, 4 head,
    /// 0x10 tail) and against the ideal line (0x20 head, 8 tail); ±0.65 of
    /// the normalised wind direction (0x102d9a90/98).
    static func windFlags(mph: Double, direction: Double, aim: Double, ideal: PGAVector?) -> Int64 {
        guard mph > 0 else { return 0 }
        let wind = PGAVector(x: sin(direction), y: 0, z: cos(direction))
        let forward = PGAVector(x: sin(aim), y: 0, z: cos(aim))
        var flags: Int64 = 0
        let across = dot(wind, right(of: forward)), along = dot(wind, forward)
        if across > 0.65 { flags |= 1 } else if across < -0.65 { flags |= 2 }
        if along < -0.65 { flags |= 4 } else if along > 0.65 { flags |= 0x10 }
        if let ideal, ideal.horizontalLength > 1e-9 {
            let line = dot(wind, ideal.horizontalUnit)
            if line < -0.65 { flags |= 0x20 } else if line > 0.65 { flags |= 8 }
        }
        return flags
    }

    /// FUN_10212e7b: green slope between ball and pin. Elevation in inches
    /// (pin − ball): > 7 → 4, > 3 → 1, ≥ −3 → 0x100, ≥ −7 → 2, else 8.
    /// Break from 0.3·n(pin) + 0.4·n(mid) + 0.3·n(ball) across the putt line:
    /// left 0x80/0x400/0x20 and right 0x40/0x200/0x10 at 0.065/0.02/0.007.
    static func greenSlope(ball: PGAVector, pin: PGAVector, ballNormal: PGAVector, pinNormal: PGAVector, middleNormal: PGAVector) -> UInt32 {
        var flags: UInt32 = 0
        let rise = (pin.y - ball.y) / inch
        if rise <= 3 { flags |= rise >= -3 ? 0x100 : rise >= -7 ? 0x2 : 0x8 } else { flags |= rise <= 7 ? 0x1 : 0x4 }
        func unit(_ v: PGAVector) -> PGAVector { v.length > 1e-12 ? v * (1 / v.length) : v }
        let a = unit(pinNormal), b = unit(middleNormal), c = unit(ballNormal)
        let normal = PGAVector(x: 0.3 * a.x + 0.4 * b.x + 0.3 * c.x, y: 0, z: 0.3 * a.z + 0.4 * b.z + 0.3 * c.z)
        let line = PGAVector(x: pin.x - ball.x, y: 0, z: pin.z - ball.z)
        let across = line.horizontalLength > 1e-9 ? dot(normal, right(of: line.horizontalUnit)) : 0
        if across < -0.065 { flags |= 0x80 } else if across < -0.02 { flags |= 0x400 } else if across < -0.007 { flags |= 0x20 }
        else if across > 0.065 { flags |= 0x40 } else if across > 0.02 { flags |= 0x200 } else if across > 0.007 { flags |= 0x10 }
        return flags
    }

    /// ShotEvent value builder (0x102146cb) for class 2.
    static func build(_ s: PGAShotInputs) -> PGAScriptFacts {
        var facts = PGAScriptFacts(eventClass: 2, sub: s.sub, mask: PGAScriptFacts.shotMask)
        let onGreen = s.ballFlags & 0x4 != 0
        facts[0] = clubMask(s.club)
        facts[1] = shotFlags(strokes: s.strokes, ballOnTee: s.ballOnTee, style: s.shotStyle)
        facts[2] = Int64(s.addressFlags)
        // CPlayer::GetDistanceFromHole(false) is 0 once the player's ball is in the hole.
        let fromLie = s.playerBallHoled ? 0 : s.playerBall.distance(to: s.pin)
        let toPin = s.sub == 2 || onGreen ? s.ball.distance(to: s.pin) : fromLie
        facts[3] = ftol(toPin / inch)
        // Bit 4: GetDistanceFromHole(true) when the shot flags are exactly 3, else golfer → ball.
        facts[4] = facts[1] == 3 ? ftol(fromLie / inch) : ftol(s.ball.distance(to: s.golfer) / inch)
        facts[6] = Int64(s.hole)
        facts[7] = Int64(s.par)
        facts[8] = Int64(s.strokes)
        facts[9] = s.score
        let miss = miss(golfer: s.golfer, end: s.ball, ideal: s.ideal)
        facts[10] = miss.flags; facts[11] = miss.lateral
        facts[12] = Int64(s.flightIndex)
        facts[13] = ftol(s.windMph)
        facts[14] = s.modelFlags
        facts[15] = facts[3]
        facts[16] = windFlags(mph: s.windMph, direction: s.windDirection, aim: s.aimHeading,
                              ideal: PGAVector(x: s.ideal.x - s.golfer.x, y: 0, z: s.ideal.z - s.golfer.z))
        facts[17] = miss.depth
        facts[18] = Int64(s.putts)
        facts[19] = s.standing
        facts[20] = onGreen ? Int64(s.greenSlope) : Int64(s.ballSubTerrain)
        facts[21] = s.ballFlags == UInt32.max ? 0 : Int64(s.ballFlags)
        facts[22] = facts[4]
        // FUN_102135c1: ftol(ideal elevation − ball elevation); 1 if ≥ 0 else 2.
        let rise = ftol((s.idealElevation - s.ballElevation) / inch)
        facts[23] = abs(rise); facts[24] = rise >= 0 ? 1 : 2
        facts[25] = 18                     // FUN_10212b9f
        facts[26] = s.gameFormat
        facts[27] = s.modelType
        facts[29] = Int64(s.gameFlags); facts[30] = Int64(s.gameFlags)
        return facts
    }
}

// MARK: - Round context and the other commentary events

/// Game settings the value builders read (CGameSettings, FUN_102124e8).
struct PGACommentaryContext: Equatable {
    var gameType: PGAGameType = .stroke
    var courseCode = "PBL"
    var conditions = PGAConditions()

    /// settings+0x13: 1 stroke play, 2 match play, 7 skins (match-based).
    var gameFormat: Int64 { [.stroke: 1, .match: 2, .skins: 7][gameType]! }
    var matchBased: Bool { gameType != .stroke }
    /// FUN_102124e8 for a human, non-practice 18-hole round: 0x200000, plus
    /// 0x10 for match-based formats.
    var gameFlags: UInt32 { 0x20_0000 | (matchBased ? 0x10 : 0) }
    /// FUN_10211885: course GUID index, as the IntroCourse rules name them.
    var courseID: Int64 {
        ["PBL": 0x1, "SAW": 0x6, "STA": 0xD, "EDW": 0x15, "FAN": 0x16, "HAR": 0x17, "AUS": 0x18,
         "SHR": 0x19, "MON": 0x1A, "TUR": 0x1B, "JPN": 0x1C][courseCode] ?? 0
    }

    /// FUN_1021088a. Stroke: round score to par before this hole, plus this
    /// hole once holed (sub 2). Match: 1 up, 2 down, 4 dormie, 8/0x10 won/lost.
    func score(scores: [[Int]], pars: [Int], player: Int, holeIndex: Int, strokes: Int, holed: Bool, sub: Int,
               endOfHole: Bool) -> Int64 {
        let completed = zip(scores[player], pars).reduce(0) { $0 + $1.0 - $1.1 }
        if !matchBased { return Int64(completed + (holed && sub == 2 ? strokes - pars[holeIndex] : 0)) }
        let status = matchStatus(scores: scores, player: player)
        var flags: Int64 = status > 0 ? 1 : status < 0 ? 2 : 0
        let remaining = pars.count - (holeIndex + 1) + (endOfHole ? 0 : 1)
        if abs(status) == remaining { flags |= 4 } else if abs(status) > remaining { flags |= status > 0 ? 8 : 0x10 }
        return flags
    }

    /// FUN_10210ae3. Stroke: strokes behind the leader. Match: holes left when
    /// dormie, else the match margin.
    func standing(scores: [[Int]], pars: [Int], player: Int, holeIndex: Int, endOfHole: Bool) -> Int64 {
        if !matchBased {
            let totals = scores.map { $0.reduce(0, +) - zip($0, pars).reduce(0) { $0 + $1.1 } }
            return Int64(totals[player] - (totals.min() ?? 0))
        }
        let status = abs(matchStatus(scores: scores, player: player))
        let remaining = pars.count - (holeIndex + 1) + (endOfHole ? 0 : 1)
        return Int64(status == remaining ? remaining : status)
    }

    /// Holes won minus holes lost against the best other score (match play
    /// and skins in this native game are hole-by-hole contests).
    func matchStatus(scores: [[Int]], player: Int) -> Int {
        guard scores.count > 1 else { return 0 }
        var status = 0
        for hole in 0..<(scores.map(\.count).min() ?? 0) {
            let mine = scores[player][hole]
            let best = scores.indices.filter { $0 != player }.map { scores[$0][hole] }.min()!
            if mine < best { status += 1 } else if mine > best { status -= 1 }
        }
        return status
    }

    /// LocationEvent fill 0x10215126 (class 9): 28 hole start, 29 hole end.
    func location(sub: Int, hole: Int, par: Int, firstStroke: Bool, distanceToPin: Double, score: Int64, standing: Int64,
                  idealRise: Double = 0) -> PGAScriptFacts {
        var facts = PGAScriptFacts(eventClass: 9, sub: sub, mask: PGAScriptFacts.locationMask)
        facts[1] = PGAShotFacts.shotFlags(strokes: firstStroke ? 0 : 1, ballOnTee: firstStroke, style: 0)
        facts[3] = PGAShotFacts.ftol(distanceToPin / PGAShotFacts.inch)
        facts[6] = Int64(hole)           // FUN_102156a9; match-based hole end: holes played (same from hole 1)
        facts[7] = Int64(par)
        facts[9] = score
        facts[13] = Int64(conditions.windSpeed)
        facts[14] = 1                    // FUN_10213547 model flags (male)
        facts[17] = 0                    // FUN_10210e98: hole shape; composite bits are 0 on these courses
        facts[19] = standing
        let rise = PGAShotFacts.ftol(idealRise / PGAShotFacts.inch)
        facts[23] = abs(rise); facts[24] = rise >= 0 ? 1 : 2
        facts[25] = 18
        facts[26] = gameFormat
        facts[28] = courseID
        facts[29] = Int64(gameFlags); facts[30] = Int64(gameFlags)
        return facts
    }

    /// CommentatorIntroEvent fill 0x102154d5 (class 12): 6 course/tournament,
    /// 7 round format, 8 weather/course state.
    func intro(sub: Int, hole: Int) -> PGAScriptFacts {
        var facts = PGAScriptFacts(eventClass: 12, sub: sub, mask: PGAScriptFacts.introMask)
        facts[1] = Int64(conditions.greenSpeed)   // settings+0x10: 1 wet … 5 very dry
        facts[2] = Int64(conditions.roughLength)  // settings+0xe: 1 short … 3 long
        facts[6] = Int64(hole)                    // FUN_102134b4
        facts[9] = 0                              // settings+0x1b3 round of a tournament; 0 for one round
        facts[13] = Int64(conditions.windSpeed)   // settings+0xf: 1 still … 5 strong
        facts[17] = 0
        facts[23] = 2                             // settings+0x11 weather: no native choice; 2 = fair
        facts[26] = gameFormat
        facts[27] = sub == 6 ? 1 : 0              // FUN_102155f5: first golfer's model type (Tiger 1)
        facts[28] = courseID
        facts[29] = Int64(gameFlags); facts[30] = Int64(gameFlags)
        return facts
    }
}

// MARK: - Native orchestration

/// What the session asks the audio engine to evaluate.
struct PGAScriptRequest: Equatable {
    enum Timing: Equatable {
        /// Raised now; commentary lines are dropped if a line is playing.
        case now
        /// Waits until no commentary plays (the executable polls
        /// ScriptCommand::InProgress; its exact sequencing is encrypted).
        case whenIdle
        /// Drops waiting pre-shot comments (a swing started).
        case cancelWaiting
    }
    var facts: PGAScriptFacts
    /// Scripts in order. For `firstMatching`, only the first one whose
    /// situations match (Script::WillExecute) runs.
    var scripts: [String]
    var timing: Timing = .now
    var firstMatching = false
    var force = false

    static let cancel = PGAScriptRequest(facts: PGAScriptFacts(eventClass: 0, sub: 0, mask: 0), scripts: [], timing: .cancelWaiting)
}

/// The shot being played, captured at the strike.
struct PGACommentaryShot {
    var player: Int
    var hole: Int
    var club: Int
    var style: Int
    var strokesBefore: Int
    var puttsBefore: Int
    var origin: PGAVector
    var originFlags: UInt32
    var originOnTee: Bool
    var ideal: PGAVector
    var aim: Double
    var preview: PGAShotPreview?
    /// Precalculates the flight a slice per frame until `preview` is known.
    var previewer: PGAShotPreviewer?
    var flightIndex = 3
    var galleryIndex = 3
    var lastProgress = 1.0
}

/// Turns simulation state and events into script events, once per frame on
/// the main actor. Original-course play only.
struct PGACommentaryDirector {
    var context = PGACommentaryContext()
    private(set) var shot: PGACommentaryShot?
    private var turn: Turn?
    private var introduced = false
    private var endedHole = -1
    private var putts: [Int] = []
    private var preShotVoice = 0

    init(context: PGACommentaryContext = PGACommentaryContext()) { self.context = context }

    /// SetFlightIndex 0x100666f2: index = min(20, trunc(progress × 20)), only
    /// rising, from 3; nothing below 60 recorded ticks (30 within 72 in of the
    /// hole) and nothing for a putt before 10 % progress.
    static func flightIndex(elapsed: Int, total: Int, startDistance: Double, putt: Bool) -> Int? {
        let minimum = startDistance < 72 * PGAShotFacts.inch ? 30 : 60
        guard total >= minimum, total > 0 else { return nil }
        let progress = Double(elapsed) / Double(total)
        if putt && progress < 0.1 { return nil }
        return min(20, Int(progress * 20))
    }

    static func originalClub(_ club: PGAClub) -> Int { PGABallSwing.originalIndex(for: club) }
    static let previewTicksPerFrame = 150

    /// Shot style for the native game, which has no shot-type menu: putter
    /// putts (6); a partial wedge near the green is taken as a chip (7, the
    /// camera director's rule); everything else is a normal shot (0).
    static func style(club: PGAClub, power: Double, distanceToPin: Double) -> Int {
        if club == .putter { return 6 }
        if [.wedge, .sandWedge, .lobWedge].contains(club) && (power <= 0.65 || distanceToPin <= 50) { return 7 }
        return 0
    }

    private func flags(_ simulation: PGASimulation, at point: PGAVector, lie: Int = 0) -> UInt32 {
        let sample = simulation.ground(x: point.x, z: point.z, ceiling: point.y + 0.3)
        return sample?.properties?.lieRecord(lie)?.flags ?? sample?.properties?.flags ?? PGAAudioRules.flags(for: sample?.surface ?? .out)
    }

    private func height(_ simulation: PGASimulation, _ point: PGAVector) -> Double {
        simulation.ground(x: point.x, z: point.z, ceiling: point.y + 2)?.height ?? point.y
    }

    private func pars(_ simulation: PGASimulation) -> [Int] { simulation.course.holes.map(\.par) }

    private func greenSlope(_ simulation: PGASimulation, ball: PGAVector) -> UInt32 {
        let pin = simulation.hole.cup, middle = (ball + pin) * 0.5
        func normal(_ p: PGAVector) -> PGAVector { simulation.ground(x: p.x, z: p.z, ceiling: p.y + 2)?.normal ?? PGAVector(x: 0, y: 1, z: 0) }
        return PGAShotFacts.greenSlope(ball: PGAVector(x: ball.x, y: height(simulation, ball), z: ball.z),
                                       pin: PGAVector(x: pin.x, y: height(simulation, pin), z: pin.z),
                                       ballNormal: normal(ball), pinNormal: normal(pin), middleNormal: normal(middle))
    }

    /// Values for a shot event of the current player.
    func shotFacts(_ simulation: PGASimulation, sub: Int, shot: PGACommentaryShot?, end: PGAVector? = nil,
                   endFlags: UInt32? = nil, endLie: Int = 0, holed: Bool = false, flightIndex: Int = 0) -> PGAScriptFacts {
        let player = simulation.currentPlayer, ball = simulation.ball
        let golfer = shot?.origin ?? ball
        let point = end ?? ball
        var pointFlags = endFlags ?? flags(simulation, at: point, lie: simulation.lieIndex)
        if holed { pointFlags |= 0x4000 }
        let strokes = sub == 2 ? (shot.map { $0.strokesBefore + 1 } ?? simulation.strokes) : (shot?.strokesBefore ?? simulation.strokes)
        let puttsBefore = shot?.puttsBefore ?? (putts.indices.contains(player) ? putts[player] : 0)
        let putting = (shot?.club ?? Self.originalClub(simulation.club)) == PGAOriginalClub.putter.rawValue
        let scores = simulation.players.map(\.scores)
        var inputs = PGAShotInputs(sub: sub, club: shot?.club ?? Self.originalClub(simulation.club),
                                   shotStyle: shot?.style ?? Self.style(club: simulation.club, power: 1, distanceToPin: simulation.distanceToCup),
                                   strokes: strokes, ballOnTee: sub == 2 ? false : (shot?.originOnTee ?? (simulation.strokes == 0)),
                                   addressFlags: shot?.originFlags ?? (flags(simulation, at: ball, lie: simulation.lieIndex) | (simulation.strokes == 0 ? 0x8000 : 0)),
                                   golfer: golfer, ball: point, ballFlags: pointFlags, ballSubTerrain: endLie,
                                   playerBall: sub == 2 ? point : golfer, playerBallHoled: sub == 2 && holed,
                                   pin: simulation.hole.cup, ideal: shot?.ideal ?? simulation.playLineTarget,
                                   aimHeading: shot?.aim ?? simulation.heading, hole: simulation.holeIndex + 1,
                                   par: simulation.hole.par)
        inputs.flightIndex = flightIndex
        inputs.windMph = simulation.wind.mph; inputs.windDirection = simulation.wind.direction
        inputs.putts = puttsBefore + (sub == 2 && putting ? 1 : 0)
        inputs.score = context.score(scores: scores, pars: pars(simulation), player: player, holeIndex: simulation.holeIndex,
                                     strokes: strokes, holed: holed, sub: sub, endOfHole: false)
        inputs.standing = context.standing(scores: scores, pars: pars(simulation), player: player, holeIndex: simulation.holeIndex,
                                           endOfHole: false)
        if pointFlags & 0x4 != 0 { inputs.greenSlope = greenSlope(simulation, ball: point) }
        let idealPoint = inputs.ideal
        inputs.idealElevation = height(simulation, idealPoint)
        inputs.ballElevation = height(simulation, sub == 2 ? point : golfer)
        inputs.gameFormat = context.gameFormat
        inputs.gameFlags = context.gameFlags
        return PGAShotFacts.build(inputs)
    }

    /// Terrain flags at a precalculated end, with the penalty surface or the hole.
    private func endFlags(_ simulation: PGASimulation, _ preview: PGAShotPreview) -> UInt32 {
        var value = flags(simulation, at: preview.end, lie: preview.lieIndex)
        if preview.hazard == .water { value |= 0x40 } else if preview.hazard == .out { value |= 0x80 }
        if preview.holed { value |= 0x4000 }
        return value
    }

    /// Call once per frame after the simulation update with that frame's events.
    mutating func update(_ simulation: PGASimulation, events: [PGASimulationEvent]) -> [PGAScriptRequest] {
        guard simulation.course.isOriginal else { return [] }
        var requests: [PGAScriptRequest] = []
        if putts.count != simulation.players.count { putts = Array(repeating: 0, count: simulation.players.count) }
        // Pending pre-shot talk is stale once a swing starts.
        if simulation.phase.swinging && !wasSwinging { requests.append(.cancel) }
        wasSwinging = simulation.phase.swinging
        for event in events {
            switch event {
            case let .strike(club, _, lieFlags, power, accuracy, fromTee, position):
                let player = simulation.currentPlayer
                let address = (lieFlags != 0 ? lieFlags : flags(simulation, at: position)) | (fromTee ? 0x8000 : 0)
                let distance = position.distance(to: simulation.hole.cup)
                shot = PGACommentaryShot(player: player, hole: simulation.holeIndex, club: Self.originalClub(club),
                                         style: Self.style(club: club, power: power, distanceToPin: distance),
                                         strokesBefore: max(0, simulation.strokes - 1), puttsBefore: putts[player],
                                         origin: position, originFlags: address, originOnTee: fromTee,
                                         ideal: simulation.playLineTarget, aim: simulation.heading,
                                         preview: nil, previewer: simulation.shotPreviewer())
                if club == .putter { putts[player] += 1 }
                requests.append(.cancel)
                // CommentatorSwingEvent (class 1 sub 3) for the analyst. Its
                // tempo value (bit 12, 0x10214548) exists only for TrueSwing,
                // so with the click meter the "BallHit" rules cannot match.
                var swing = PGAScriptFacts(eventClass: 1, sub: 3, mask: PGAScriptFacts.swingMask,
                                           values: PGAAudioRules.swingFacts(club: club, lieFlags: lieFlags, teed: fromTee, power: power,
                                                                            accuracy: accuracy, strokes: max(0, simulation.strokes - 1),
                                                                            distanceToPin: distance))
                swing[12] = 0; swing[14] = 1; swing[27] = 1
                requests.append(PGAScriptRequest(facts: swing, scripts: ["analyst"]))
            case let .penalty(hazard):
                guard let current = shot else { break }
                var preview = current.preview ?? PGAShotPreview(end: simulation.ball, totalTicks: 0)
                preview.hazard = hazard
                requests.append(PGAScriptRequest(facts: shotFacts(simulation, sub: 2, shot: current, end: preview.end,
                                                                  endFlags: endFlags(simulation, preview)),
                                                 scripts: ["gallery", "analyst"]))
                shot = nil
            case .rest:
                guard let current = shot else { break }
                // The rest before any drop: the precalculated end.
                let preview = current.preview ?? PGAShotPreview(end: simulation.ball, totalTicks: 0, lieIndex: simulation.lieIndex)
                requests.append(PGAScriptRequest(facts: shotFacts(simulation, sub: 2, shot: current, end: preview.end,
                                                                  endFlags: endFlags(simulation, preview), endLie: preview.lieIndex),
                                                 scripts: ["gallery", "analyst"]))
                shot = nil
            case .holed:
                guard let current = shot else { break }
                let preview = PGAShotPreview(end: simulation.hole.cup, totalTicks: 0, holed: true)
                requests.append(PGAScriptRequest(facts: shotFacts(simulation, sub: 2, shot: current, end: preview.end,
                                                                  endFlags: endFlags(simulation, preview), holed: true),
                                                 scripts: ["gallery", "analyst"]))
                shot = nil
            case .impact, .cup:
                break
            }
        }
        // Precalculate the shot's end (CGolfBall::PreCalculateBall) in
        // slices: in-flight events start at 20 % of a flight of ≥ 1 s, well
        // after a ~1,000-tick flight is previewed at 150 ticks per frame.
        if var current = shot, current.preview == nil, var previewer = current.previewer {
            current.preview = previewer.advance(ticks: Self.previewTicksPerFrame)
            current.previewer = current.preview == nil ? previewer : nil
            shot = current
        }
        // In flight (SetFlightIndex 0x100666f2): the gallery steps through
        // every new index (BallInFlight 0x1006292e); the announcer hears only
        // the newest (CommentatorBallInFlight 0x10062dc5).
        if var current = shot, simulation.phase.inMotion, let preview = current.preview, let elapsed = simulation.flightTicks {
            if let index = Self.flightIndex(elapsed: elapsed, total: preview.totalTicks,
                                            startDistance: current.origin.distance(to: simulation.hole.cup),
                                            putt: current.club == PGAOriginalClub.putter.rawValue) {
                let progress = Double(elapsed) / Double(max(1, preview.totalTicks))
                if index <= current.flightIndex || progress - current.lastProgress < 0 {
                    current.lastProgress = progress
                } else {
                    let base = shotFacts(simulation, sub: 1, shot: current, end: preview.end, endFlags: endFlags(simulation, preview),
                                         endLie: preview.lieIndex, holed: preview.holed, flightIndex: index)
                    for stepped in (current.galleryIndex + 1)...index {
                        var facts = base
                        facts[12] = Int64(stepped)
                        requests.append(PGAScriptRequest(facts: facts, scripts: ["gallery"]))
                    }
                    requests.append(PGAScriptRequest(facts: base, scripts: ["announcer"]))
                    current.flightIndex = index; current.galleryIndex = index
                }
            } else {
                current.flightIndex = 3; current.galleryIndex = 3; current.lastProgress = 1  // ResetInflightInfo
            }
            shot = current
        }
        // Hole end (EndHole 0x1005fc54), once everyone is in.
        if simulation.phase == .holed && simulation.holeComplete && endedHole != simulation.holeIndex {
            endedHole = simulation.holeIndex
            var scores = simulation.players.map(\.scores)
            for index in scores.indices { scores[index].append(simulation.players[index].strokes) }
            let player = simulation.currentPlayer, pars = pars(simulation)
            let score = context.score(scores: scores, pars: pars, player: player, holeIndex: simulation.holeIndex,
                                      strokes: 0, holed: false, sub: 29, endOfHole: true)
            let standing = context.standing(scores: scores, pars: pars, player: player, holeIndex: simulation.holeIndex, endOfHole: true)
            requests.append(PGAScriptRequest(facts: context.location(sub: 29, hole: simulation.holeIndex + 1, par: simulation.hole.par,
                                                                     firstStroke: false, distanceToPin: 0, score: score, standing: standing),
                                             scripts: ["announcer"], timing: .whenIdle))
        }
        // A new turn: hole and round introductions, then the pre-shot comment.
        guard simulation.phase == .aiming else { return requests }
        let key = Turn(hole: simulation.holeIndex, player: simulation.currentPlayer, strokes: simulation.strokes)
        guard key != turn else { return requests }
        let newHole = turn?.hole != key.hole
        turn = key
        let pars = pars(simulation), scores = simulation.players.map(\.scores), player = simulation.currentPlayer
        if newHole {
            putts = Array(repeating: 0, count: simulation.players.count)
            let fresh = simulation.players.allSatisfy { $0.strokes == 0 && !$0.holed }
            if fresh && !introduced && simulation.holeIndex == 0 && scores.allSatisfy(\.isEmpty) {
                // BeginTournament, RoundFormatComment and WeatherComment.
                requests.append(PGAScriptRequest(facts: context.intro(sub: 6, hole: 1), scripts: ["announcer"], timing: .whenIdle))
                requests.append(PGAScriptRequest(facts: context.intro(sub: 7, hole: 1), scripts: ["announcer"], timing: .whenIdle))
                requests.append(PGAScriptRequest(facts: context.intro(sub: 8, hole: 1), scripts: ["analyst"], timing: .whenIdle))
            }
            introduced = true
            if fresh {
                let score = context.score(scores: scores, pars: pars, player: player, holeIndex: simulation.holeIndex,
                                          strokes: 0, holed: false, sub: 28, endOfHole: false)
                let standing = context.standing(scores: scores, pars: pars, player: player, holeIndex: simulation.holeIndex, endOfHole: false)
                requests.append(PGAScriptRequest(facts: context.location(sub: 28, hole: simulation.holeIndex + 1, par: simulation.hole.par,
                                                                         firstStroke: true, distanceToPin: simulation.distanceToCup,
                                                                         score: score, standing: standing),
                                                 scripts: ["announcer"], timing: .whenIdle))
            }
        }
        // BeginShot (skipped from an unplayable 0x20 lie): one commentator per
        // turn, alternating which is asked first. Native policy; the
        // executable's sequencing is encrypted.
        let facts = shotFacts(simulation, sub: 19, shot: nil)
        if facts[2] & 0x20 == 0 {
            let order = preShotVoice % 2 == 0 ? ["announcer", "analyst"] : ["analyst", "announcer"]
            preShotVoice += 1
            requests.append(PGAScriptRequest(facts: facts, scripts: order, timing: .whenIdle, firstMatching: true))
        }
        return requests
    }

    private struct Turn: Equatable { var hole: Int; var player: Int; var strokes: Int }
    private var wasSwinging = false
}
