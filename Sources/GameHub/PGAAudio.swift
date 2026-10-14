import AVFoundation
import CoreAudio
import Foundation

/// The original PGA Tour 2005 sound rules: basic.stn and gallery.stn situations
/// plus each course's SND.INI ambience, decoded statically by
/// Tools/import_pga2005_audio.py into Library/Imported/pga2005/audio/audio.json
/// (docs/research/PGA2005-AUDIO.md). Immutable after loading.
struct PGAAudioRules {
    struct Condition: Decodable, Equatable {
        var bit: Int
        var op: String
        var value: Double

        /// Script operators (0x10215b87) on the event's value for `bit`.
        func matches(_ facts: [Int64]) -> Bool {
            let event = bit >= 0 && bit < facts.count ? facts[bit] : 0, v = Int64(value)
            switch op {
            case "always": return true
            case "eq": return event == v
            case "ne": return event != v
            case "gt": return event > v
            case "lt": return event < v
            case "any_bits": return event & v != 0
            case "either_nonzero": return event != 0 || v != 0
            case "missing_bits": return ~event & v != 0
            case "no_bits": return event & v == 0
            default: return false
            }
        }
    }
    struct Conditions: Decodable, Equatable {
        var event_class: Int
        var event_sub: Int
        var all: [Condition]
        var priority: Int
    }
    struct Event: Decodable {
        var files: [String]
        var action_groups: [[String]]?
        var gain: Double
        var channel: String
        var loop: Bool
        var play_all_actions: Bool?
        var probability_percent: [Int]?
        var conditions: Conditions?
        var positional: Bool?
        /// Actions in order; interface sounds list only `files`.
        var groups: [[String]] { let groups = (action_groups ?? []).filter { !$0.isEmpty }; return groups.isEmpty ? [files] : groups }
    }
    struct Folder: Decodable {
        var frequency_percent: Int
        var loop: Bool
        var gain: Double
        var files: [String]
    }
    struct Emitter: Decodable {
        var hole: Int
        var folder: String
        var radius_inches: Double
        var center_world_inches: [Double]?
        var global_2d: Bool?
    }
    struct Course: Decodable {
        var ambient_folders: [String: Folder]
        var emitters: [Emitter]
    }
    private struct File: Decodable {
        var events: [String: Event]
        var courses: [String: Course]
    }

    let events: [String: Event]
    let courses: [String: Course]
    /// Situation names per (event class << 8 | sub), sorted for stable ties.
    private let situations: [Int: [String]]

    init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        events = file.events; courses = file.courses
        var situations: [Int: [String]] = [:]
        for (name, event) in file.events {
            guard let c = event.conditions else { continue }
            situations[c.event_class << 8 | c.event_sub, default: []].append(name)
        }
        self.situations = situations.mapValues { $0.sorted() }
    }

    static func load(directory: URL) -> PGAAudioRules? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("audio.json")) else { return nil }
        return try? PGAAudioRules(data: data)
    }

    /// Script::DoSituationsMatching (0x1020c1df): among matching situations the
    /// lowest priority byte wins, then the most conditions, then the least
    /// fired, then a random one.
    func select<R: RandomNumberGenerator>(eventClass: Int, sub: Int, facts: [Int64], fired: [String: Int], using random: inout R) -> String? {
        var best: [String] = [], key = (Int.max, Int.max, Int.max)
        for name in situations[eventClass << 8 | sub] ?? [] {
            guard let c = events[name]?.conditions, c.all.allSatisfy({ $0.matches(facts) }) else { continue }
            let rank = (c.priority, -c.all.count, fired[name] ?? 0)
            if rank < key { key = rank; best = [name] } else if rank == key { best.append(name) }
        }
        return best.isEmpty ? nil : best[Int.random(in: 0..<best.count, using: &random)]
    }

    // MARK: Event values (bit numbers from the situation-event builders)

    static let factCount = 32

    /// Club mask (0x1021038a): 1 driver, 2 wood, 4 iron/wedge, 0x10 putter,
    /// 0x20 wedge, 0x40/0x80/0x100 long/mid/short iron. The iron group
    /// boundaries (3–4 long, 5–7 mid, 8–9 short) are an assumption.
    static func clubMask(_ club: PGAClub) -> Int64 {
        switch club {
        case .driver: return 0x1
        case .wood3, .wood5: return 0x2
        case .iron3, .iron4: return 0x4 | 0x40
        case .iron5, .iron6, .iron7: return 0x4 | 0x80
        case .iron8, .iron9: return 0x4 | 0x100
        case .wedge, .sandWedge, .lobWedge: return 0x4 | 0x20
        case .putter: return 0x10
        }
    }

    /// Record flags for generated terrain, which has no original records.
    static func flags(for surface: PGASurface) -> UInt32 {
        switch surface {
        case .tee: return 0x1000
        case .fairway: return 0x1
        case .rough: return 0x2
        case .green: return 0x4
        case .sand: return 0x8
        case .fringe: return 0x10
        case .water: return 0x40
        case .out: return 0x80
        case .unplayable: return 0x20
        }
    }

    /// basic.stn collision ids (901 fairway … 905 rough) for generated terrain
    /// or original materials whose records carry no id.
    static func soundID(for surface: PGASurface) -> Int {
        switch surface {
        case .green, .fringe: return 902
        case .water: return 903
        case .sand: return 904
        case .rough, .unplayable, .out: return 905
        case .tee, .fairway: return 901
        }
    }

    /// Class 1 sub 3 (ClubSwing 0x1006e370). Power percent is swing power /
    /// 14 × 100 in the original; the native meter's 0…1 is scaled to the
    /// research's full-swing power 15.556 (putter 8), so ≥ 90 % reads as
    /// "perfect" (> 99). Toe/heel flags from a wide accuracy miss are a native
    /// approximation of the original strike-point flags.
    static func swingFacts(club: PGAClub, lieFlags: UInt32, teed: Bool, power: Double, accuracy: Double,
                           strokes: Int, distanceToPin: Double) -> [Int64] {
        var facts = [Int64](repeating: 0, count: factCount)
        facts[0] = clubMask(club)
        var swing: Int64 = teed ? 0x1 : 0
        if accuracy < -0.5 { swing |= 0x10 } else if accuracy > 0.5 { swing |= 0x20 }
        facts[1] = swing
        facts[2] = Int64(lieFlags) | (teed && club != .putter ? 0x8000 : 0)
        facts[3] = Int64((distanceToPin / PGACourseTransform.metersPerInch).rounded())
        facts[5] = Int64((power * (club == .putter ? 8 : 15.556) / 14 * 100).rounded())
        facts[8] = Int64(strokes)
        return facts
    }

    /// Class 3 sub 4 (CGolfBall::CheckForCollisionSound 0x10136ed0): impact
    /// percent = magnitude / 0.5 × 100, skipped below 0.1. The magnitude is
    /// taken as the normal speed in inches per 60 Hz tick (unit unconfirmed).
    static func impactFacts(soundID: Int, flags: UInt32, normalSpeed: Double) -> [Int64]? {
        let magnitude = normalSpeed / PGACourseTransform.metersPerInch / 60
        guard magnitude >= 0.1 else { return nil }
        var facts = [Int64](repeating: 0, count: factCount)
        facts[2] = Int64(soundID)
        facts[5] = Int64((magnitude / 0.5 * 100).rounded())
        facts[21] = Int64(flags)
        return facts
    }

    /// One finished shot, for the gallery reaction.
    struct Shot {
        var club: PGAClub
        var fromTee: Bool
        var par: Int
        var startFlags: UInt32
        var startDistance: Double
        var accuracy: Double
        var resultFlags: UInt32
        var resultDistance: Double
        var shotDistance: Double
        var holed: Bool
        var penalty: PGASurface?
    }

    /// gallery.stn reactions. The class 2 event builder was not decompiled, so
    /// this maps finished shots onto the situations by their editor
    /// descriptions and distance thresholds (inches converted to meters).
    static func crowdReaction(_ shot: Shot) -> String? {
        let inch = PGACourseTransform.metersPerInch, putt = shot.club == .putter
        let teeShot = shot.fromTee && shot.startFlags & 0x9000 != 0
        if let penalty = shot.penalty {
            if penalty == .water { return "crowd.water" }
            return teeShot && shot.par > 3 ? "crowd.drive_out_of_bounds" : nil
        }
        if shot.holed {
            if putt { return shot.startDistance > 348 * inch ? "crowd.putt_made_long" : "crowd.putt_made" }
            return shot.startDistance > 2304 * inch ? "crowd.hole_out" : "crowd.chip_in"
        }
        if putt {
            if shot.startDistance < 180 * inch && shot.resultDistance < 24 * inch { return "crowd.putt_near_miss" }
            if shot.startDistance > 72 * inch && shot.resultDistance > 36 * inch && shot.resultDistance < 348 * inch { return "crowd.putt_big_miss" }
            return nil
        }
        if teeShot && shot.par > 3 {
            if shot.resultFlags & 0x8 != 0 { return "crowd.drive_bunker" }
            if shot.resultFlags & 0x1 != 0 {
                if shot.shotDistance > 9864 * inch { return "crowd.drive_long_fairway" }
                if shot.shotDistance > 3600 * inch { return "crowd.drive_fairway" }
            }
            return nil
        }
        if shot.resultFlags & 0x4 != 0 && shot.shotDistance > 2304 * inch && shot.startFlags & 0x1 != 0 {
            if shot.resultDistance < 48 * inch { return "crowd.approach_close" }
            return shot.resultDistance < 240 * inch ? "crowd.approach_good" : "crowd.approach_green"
        }
        if !shot.fromTee && abs(shot.accuracy) > 0.5 && shot.resultFlags & 0x15A != 0 && shot.resultDistance > 2304 * inch {
            return "crowd.mishit"
        }
        return nil
    }
}

/// Native playback of the original sounds with AVAudioEngine. All engine state
/// lives on one serial queue; the game calls in from the main actor and never
/// waits. Buffers are converted once to 22.05 kHz mono float (every source is
/// ≤ 22.05 kHz except one) so the player pool never needs reconnecting, and
/// the cache is bounded. Positional sounds use an environment node with the
/// original Miles 3D distance model (inverse, 150 in reference, 10,800 in
/// maximum, rolloff 0.8).
final class PGAAudioEngine: @unchecked Sendable {
    static let sampleRate = 22_050.0
    private static let cacheLimit = 40 * 1024 * 1024
    private static let ambientOneShotLimit = 4

    let rules: PGAAudioRules
    private let directory: URL
    private let queue = DispatchQueue(label: "GameHub.PGAAudio", qos: .userInitiated)
    private let engine: AVAudioEngine
    private let environment: AVAudioEnvironmentNode
    private let format = AVAudioFormat(standardFormatWithSampleRate: PGAAudioEngine.sampleRate, channels: 1)!
    private var voices: [Voice] = []
    private var configured = false
    private var running = false
    private var paused = false
    private var configurationObserver: NSObjectProtocol?

    private var cache: [String: AVAudioPCMBuffer] = [:]
    private var cacheOrder: [String] = []
    private var cacheBytes = 0
    private var plays: [String: Int] = [:]
    private var fired: [String: Int] = [:]
    private var random = SystemRandomNumberGenerator()

    private struct Placed { var folder: String; var position: PGAVector?; var radius: Double }
    private var emitters: [Int: [Placed]] = [:]
    private var folders: [String: PGAAudioRules.Folder] = [:]
    private var hole = 0
    private var listener = PGAVector.zero
    private var ticks = 0

    private final class Voice {
        let node = AVAudioPlayerNode()
        let spatial: Bool
        var endsAt = 0.0
        var loopKey: String?
        var ambient = false
        var generation = 0
        init(spatial: Bool) { self.spatial = spatial }
    }

    init?(root: URL) {
        let directory = root.appendingPathComponent("Library/Imported/pga2005/audio", isDirectory: true)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard let rules = PGAAudioRules.load(directory: directory),
              AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        self.rules = rules
        self.directory = directory
        engine = AVAudioEngine()
        environment = AVAudioEnvironmentNode()
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        engine.stop()
    }

    // MARK: Game-facing API (main actor → audio queue)

    /// Diagnostics: whether the engine started, decoded buffers held, and
    /// voices currently sounding (loops included).
    var status: (running: Bool, buffers: Int, bytes: Int, sounding: Int) {
        queue.sync {
            let now = ProcessInfo.processInfo.systemUptime
            return (running, cache.count, cacheBytes, voices.filter { $0.endsAt > now }.count)
        }
    }

    func start() { queue.async { self.startEngine() } }
    func stop() {
        queue.sync {
            running = false
            for voice in voices { voice.node.stop(); voice.loopKey = nil }
            engine.stop()
            cache.removeAll(); cacheOrder.removeAll(); cacheBytes = 0
        }
    }
    func setPaused(_ value: Bool) {
        queue.async {
            guard self.running, value != self.paused else { return }
            self.paused = value
            if value { self.engine.pause() } else { try? self.engine.start() }
        }
    }

    /// Converts this course's SND.INI emitters to meters (y and centres in the
    /// raw TCR frame, like tees and pins).
    func useCourse(code: String, transform: PGACourseTransform?) {
        queue.async {
            self.stopLoops()
            self.emitters = [:]; self.folders = [:]
            guard let course = self.rules.courses[code], let transform else { return }
            self.folders = course.ambient_folders
            for emitter in course.emitters where course.ambient_folders[emitter.folder] != nil {
                var position: PGAVector?
                if emitter.global_2d != true, let c = emitter.center_world_inches, c.count == 3 {
                    position = transform.meters(raw: PGAVector(x: c[0], y: c[1], z: c[2]))
                }
                guard position != nil || emitter.global_2d == true, emitter.radius_inches > 0 else { continue }
                self.emitters[emitter.hole, default: []].append(Placed(folder: emitter.folder, position: position,
                                                                       radius: emitter.radius_inches * PGACourseTransform.metersPerInch))
            }
        }
    }

    func setHole(_ number: Int) {
        queue.async { if number != self.hole { self.stopLoops(); self.hole = number } }
    }

    func setListener(position: PGAVector, forward: PGAVector, up: PGAVector) {
        queue.async {
            self.listener = position
            guard self.configured else { return }
            self.environment.listenerPosition = Self.point(position)
            self.environment.listenerVectorOrientation = AVAudio3DVectorOrientation(forward: Self.vector(forward), up: Self.vector(up))
        }
    }

    /// Plays the situation the original script would pick for these values.
    func trigger(eventClass: Int, sub: Int, facts: [Int64], at position: PGAVector?) {
        queue.async {
            guard self.running, !self.paused,
                  let name = self.rules.select(eventClass: eventClass, sub: sub, facts: facts, fired: self.fired, using: &self.random) else { return }
            self.playEvent(name, at: position)
        }
    }

    func play(_ name: String, at position: PGAVector? = nil) {
        queue.async { if self.running && !self.paused { self.playEvent(name, at: position) } }
    }

    /// Background tick (BackgroundNoise; the original cadence lives in the
    /// SafeDisc-protected executable, so the research's 1 Hz is used). Loop
    /// folders keep one bed at the nearest in-range emitter; one-shot folders
    /// roll their frequency once per tick and play at a random in-range
    /// emitter. One roll per folder rather than per emitter is a native choice
    /// that keeps dense coastlines from stacking sounds.
    func backgroundTick() {
        queue.async {
            guard self.running, !self.paused else { return }
            self.ticks += 1
            var inRange: [String: [(position: PGAVector?, distance: Double)]] = [:]
            for emitter in self.emitters[self.hole] ?? [] {
                if let position = emitter.position {
                    let distance = (position - self.listener).length
                    if distance <= emitter.radius { inRange[emitter.folder, default: []].append((position, distance)) }
                } else {
                    inRange[emitter.folder, default: []].append((nil, 0))
                }
            }
            for voice in self.voices where voice.loopKey != nil && inRange[voice.loopKey!] == nil { self.fadeOut(voice) }
            let now = ProcessInfo.processInfo.systemUptime
            var oneShots = self.voices.filter { $0.ambient && $0.loopKey == nil && $0.endsAt > now }.count
            for (name, candidates) in inRange.sorted(by: { $0.key < $1.key }) {
                guard let folder = self.folders[name], !folder.files.isEmpty else { continue }
                if folder.loop {
                    let nearest = candidates.min { $0.distance < $1.distance }!.position
                    if let voice = self.voices.first(where: { $0.loopKey == name }) {
                        if let nearest, voice.spatial { voice.node.position = Self.point(nearest) }
                    } else if let file = self.leastPlayed(folder.files) {
                        self.playFile(file, gain: folder.gain, at: nearest, loop: true, key: name)
                    }
                } else if oneShots < Self.ambientOneShotLimit, Int.random(in: 1...100, using: &self.random) <= folder.frequency_percent,
                          let file = self.leastPlayed(folder.files) {
                    let spot = candidates[Int.random(in: 0..<candidates.count, using: &self.random)].position
                    if self.playFile(file, gain: folder.gain, at: spot, ambient: true) { oneShots += 1 }
                }
            }
            // Sub 7 fires when the counter is a multiple of 7: distant cheers.
            if self.ticks % 7 == 0, let name = self.rules.select(eventClass: 5, sub: 7, facts: [Int64](repeating: 0, count: PGAAudioRules.factCount),
                                                                  fired: self.fired, using: &self.random) {
                self.playEvent(name, at: nil)
            }
        }
    }

    // MARK: Audio queue

    private func startEngine() {
        if !configured { configure() }
        guard !running else { return }
        do { try engine.start(); running = true; paused = false } catch { running = false }
        guard running else { return }
        // Preload the short gameplay sounds the original marks static.
        for event in rules.events.values where event.channel != "crowd" && !event.loop && event.conditions?.event_class != 5 {
            for file in event.groups.joined() where file.hasPrefix("gameplay/") { _ = buffer(file) }
        }
    }

    private func configure() {
        configured = true
        engine.attach(environment)
        let output = engine.outputNode.outputFormat(forBus: 0)
        let stereo = AVAudioFormat(standardFormatWithSampleRate: output.sampleRate > 0 ? output.sampleRate : 48_000, channels: 2)
        engine.connect(environment, to: engine.mainMixerNode, format: stereo)
        let distance = environment.distanceAttenuationParameters
        distance.distanceAttenuationModel = .inverse
        distance.referenceDistance = Float(150 * PGACourseTransform.metersPerInch)
        distance.maximumDistance = Float(10_800 * PGACourseTransform.metersPerInch)
        distance.rolloffFactor = 0.8
        environment.reverbParameters.enable = false
        for spatial in Array(repeating: true, count: 14) + Array(repeating: false, count: 6) {
            let voice = Voice(spatial: spatial)
            engine.attach(voice.node)
            engine.connect(voice.node, to: spatial ? environment : engine.mainMixerNode, format: format)
            if spatial { voice.node.renderingAlgorithm = .equalPowerPanning; voice.node.reverbBlend = 0 }
            voices.append(voice)
        }
        engine.mainMixerNode.outputVolume = 0.9
        engine.prepare()
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { if self.running && !self.paused { try? self.engine.start() } }
        }
    }

    private func playEvent(_ name: String, at position: PGAVector?) {
        guard let event = rules.events[name] else { return }
        fired[name, default: 0] += 1
        let groups = event.groups, chances = event.probability_percent ?? []
        let chosen = event.play_all_actions == false ? [Int.random(in: 0..<groups.count, using: &random)] : Array(groups.indices)
        for index in chosen {
            let chance = index < chances.count ? chances[index] : 100
            guard Int.random(in: 1...100, using: &random) <= chance, let file = leastPlayed(groups[index]) else { continue }
            playFile(file, gain: event.gain, at: event.positional == true ? position : nil, loop: event.loop, key: event.loop ? name : nil)
        }
    }

    /// Uniform among the variants with the fewest plays (0x10216d78).
    private func leastPlayed(_ files: [String]) -> String? {
        guard let fewest = files.map({ plays[$0] ?? 0 }).min() else { return nil }
        let candidates = files.filter { (plays[$0] ?? 0) == fewest }
        let file = candidates[Int.random(in: 0..<candidates.count, using: &random)]
        plays[file, default: 0] += 1
        return file
    }

    @discardableResult
    private func playFile(_ file: String, gain: Double, at position: PGAVector?, loop: Bool = false, key: String? = nil, ambient: Bool = false) -> Bool {
        guard running, let buffer = buffer(file), let voice = takeVoice(spatial: position != nil) else { return false }
        voice.node.stop()
        voice.generation += 1
        voice.node.volume = Float(max(0, min(1, gain)))
        if let position { voice.node.position = Self.point(position) }
        voice.node.scheduleBuffer(buffer, at: nil, options: loop ? [.loops] : [], completionHandler: nil)
        voice.node.play()
        voice.endsAt = loop ? .infinity : ProcessInfo.processInfo.systemUptime + Double(buffer.frameLength) / Self.sampleRate
        voice.loopKey = loop ? key : nil
        voice.ambient = ambient || (loop && key != nil)
        return true
    }

    /// A finished voice of the right kind, else the one-shot ending soonest.
    private func takeVoice(spatial: Bool) -> Voice? {
        let now = ProcessInfo.processInfo.systemUptime
        let pool = voices.filter { $0.spatial == spatial && $0.loopKey == nil }
        return pool.first { $0.endsAt <= now } ?? pool.min { $0.endsAt < $1.endsAt }
    }

    private func fadeOut(_ voice: Voice) {
        voice.loopKey = nil; voice.endsAt = 0
        let generation = voice.generation
        for step in 1...4 {
            queue.asyncAfter(deadline: .now() + 0.08 * Double(step)) {
                guard voice.generation == generation else { return }
                if step == 4 { voice.node.stop() } else { voice.node.volume *= 0.5 }
            }
        }
    }

    private func stopLoops() {
        for voice in voices where voice.loopKey != nil { fadeOut(voice) }
    }

    private func buffer(_ file: String) -> AVAudioPCMBuffer? {
        if let cached = cache[file] {
            if let index = cacheOrder.firstIndex(of: file) { cacheOrder.remove(at: index) }
            cacheOrder.append(file)
            return cached
        }
        guard let source = try? AVAudioFile(forReading: directory.appendingPathComponent(file)),
              source.length > 0, source.length < 4_000_000,
              let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length)),
              (try? source.read(into: input)) != nil else { return nil }
        let converted: AVAudioPCMBuffer
        if input.format == format {
            converted = input
        } else {
            guard let converter = AVAudioConverter(from: input.format, to: format) else { return nil }
            converter.downmix = true
            let capacity = AVAudioFrameCount(Double(input.frameLength) * Self.sampleRate / input.format.sampleRate) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if consumed { outStatus.pointee = .endOfStream; return nil }
                consumed = true; outStatus.pointee = .haveData; return input
            }
            guard status != .error, output.frameLength > 0 else { return nil }
            converted = output
        }
        let bytes = Int(converted.frameLength) * 4
        while cacheBytes + bytes > Self.cacheLimit, !cacheOrder.isEmpty {
            let evicted = cacheOrder.removeFirst()
            cacheBytes -= cache.removeValue(forKey: evicted).map { Int($0.frameLength) * 4 } ?? 0
        }
        cache[file] = converted; cacheOrder.append(file); cacheBytes += bytes
        return converted
    }

    private static func point(_ v: PGAVector) -> AVAudio3DPoint { AVAudio3DPoint(x: Float(v.x), y: Float(v.y), z: Float(v.z)) }
    private static func vector(_ v: PGAVector) -> AVAudio3DVector { AVAudio3DVector(x: Float(v.x), y: Float(v.y), z: Float(v.z)) }
}
