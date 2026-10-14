import AppKit
import Darwin
import SceneKit

/// Self-driving play-test and benchmark mode for the original courses.
///
/// Launch the app with `GAMEHUB_AUTOPLAY=PBL` (any prepared course code) and
/// it opens the Original Courses module, starts a round and plays it through
/// the real tri-click meter, cameras, physics, rules, sound and commentary.
/// Nothing reaches the network, and it only runs while the app is open in the
/// foreground of the person who started it. Options, all optional:
///
/// - `GAMEHUB_AUTOPLAY_HOLES` holes to play (default 3)
/// - `GAMEHUB_AUTOPLAY_MINUTES` stop after this long instead (benchmarks)
/// - `GAMEHUB_AUTOPLAY_WEATHER` 0–7, `_TIME` 0–4, `_WIND` 1–5, `_LEVEL` 0–3
/// - `GAMEHUB_AUTOPLAY_OUT` directory for `autoplay.log`, `summary.json` and
///   captures (default: the temporary directory); keep it outside Git
/// - `GAMEHUB_AUTOPLAY_CAPTURE` seconds between scene captures (0 = none; the
///   default 0 keeps benchmark frame times clean)
/// - `GAMEHUB_AUTOPLAY_FULLSCREEN=1` enters fullscreen first (native 2560 × 1600
///   on the M1 Air), for the sustained performance run
///
/// The app quits by itself when done. Frame times come from SceneKit's render
/// loop; footprint is the process's physical footprint.
@MainActor
final class PGAAutoplay {
    struct Options {
        var code = "PBL"
        var holes = 3
        var minutes: Double?
        var weather = 0
        var time = 2
        var wind = 2
        var level = 1
        var output: URL
        var captureEvery = 0.0
        var fullscreen = false

        static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Options? {
            guard let raw = environment["GAMEHUB_AUTOPLAY"] else { return nil }
            let code = raw.uppercased()
            var options = Options(output: URL(fileURLWithPath: environment["GAMEHUB_AUTOPLAY_OUT"]
                                              ?? NSTemporaryDirectory() + "gamehub-autoplay", isDirectory: true))
            if code.count == 3, code.allSatisfy({ $0.isLetter && $0.isASCII }) { options.code = code }
            func int(_ key: String, _ range: ClosedRange<Int>) -> Int? { environment[key].flatMap(Int.init).map { max(range.lowerBound, min(range.upperBound, $0)) } }
            options.holes = int("GAMEHUB_AUTOPLAY_HOLES", 1...18) ?? options.holes
            options.weather = int("GAMEHUB_AUTOPLAY_WEATHER", 0...7) ?? options.weather
            options.time = int("GAMEHUB_AUTOPLAY_TIME", 0...4) ?? options.time
            options.wind = int("GAMEHUB_AUTOPLAY_WIND", 1...5) ?? options.wind
            options.level = int("GAMEHUB_AUTOPLAY_LEVEL", 0...3) ?? options.level
            options.minutes = environment["GAMEHUB_AUTOPLAY_MINUTES"].flatMap(Double.init).map { max(0.5, min(240, $0)) }
            options.captureEvery = environment["GAMEHUB_AUTOPLAY_CAPTURE"].flatMap(Double.init).map { max(0, min(600, $0)) } ?? 0
            options.fullscreen = environment["GAMEHUB_AUTOPLAY_FULLSCREEN"] == "1"
            return options
        }
    }

    let options: Options
    private var log: FileHandle?
    private let started = ProcessInfo.processInfo.systemUptime
    private var waitClock = 0.0, captureClock = 0.0, statClock = 0.0
    private var targetPower = 1.0, targetAccuracy = 0.0
    private var lastPhase = PGAPhase.aiming
    private var lastHole = -1
    private var holesFinished = 0
    private var shots = 0
    private var captures = 0
    private var intervals: [Double] = []
    private var footprints: [UInt64] = []
    private var finished = false
    private var random = PGARandom(seed: "autoplay")

    init(options: Options) {
        self.options = options
        try? FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
        let url = options.output.appendingPathComponent("autoplay.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        log = try? FileHandle(forWritingTo: url)
        write("autoplay \(options.code) holes \(options.holes) minutes \(options.minutes.map { String($0) } ?? "-") weather \(options.weather) time \(options.time) wind \(options.wind) level \(options.level)")
    }

    /// Round setup for the scripted round.
    func configure(_ setup: inout PGARoundSetup, defaults: PGAConditions) {
        setup.players = ["Autoplay"]
        setup.weather = options.weather
        setup.timeOfDay = options.time
        setup.difficulty = PGATriClickMeter.Level(rawValue: options.level)
        var conditions = defaults
        conditions.windSpeed = options.wind
        setup.conditions = conditions
    }

    private var enteredFullscreen = false

    func tick(_ session: PGAGameSession, delta: Double) {
        guard !finished else { return }
        if options.fullscreen && !enteredFullscreen {
            enteredFullscreen = true
            session.fullscreen()
            write("entering fullscreen")
        }
        let game = session.simulation
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let fresh = session.renderer.drainFrameIntervals()
        if let worst = fresh.max(), worst > 0.1 {
            write(String(format: "hitch %.0f ms · hole %d · %@", worst * 1000, game.holeIndex + 1, game.phase.rawValue))
        }
        intervals += fresh
        statClock += delta
        if statClock >= 5 {
            statClock = 0
            let footprint = Self.footprint()
            footprints.append(footprint)
            write(String(format: "stats fps %d footprint %.0f MB %@", session.frameRate, Double(footprint) / 1_048_576, session.audioSummary))
        }
        if options.captureEvery > 0 {
            captureClock += delta
            if captureClock >= options.captureEvery {
                captureClock = 0
                capture(session, label: "t\(Int(elapsed))")
                _ = session.renderer.drainFrameIntervals()   // keep capture cost out of the frame statistics
            }
        }
        if game.holeIndex != lastHole {
            lastHole = game.holeIndex
            write("hole \(game.holeIndex + 1) par \(game.hole.par) wind \(Int(game.wind.mph)) mph")
        }
        if game.phase != lastPhase {
            if lastPhase.inMotion && !game.phase.inMotion { write("rest \(game.message) · lie \(game.lieLabel) · strokes \(game.strokes)") }
            if game.phase == .holed { holesFinished += 1; write("holed in \(game.strokes) · \(game.message)") }
            lastPhase = game.phase
            waitClock = 0
        }
        if let minutes = options.minutes, elapsed >= minutes * 60 { finish(session, reason: "time"); return }
        if game.phase == .roundComplete || (game.phase == .holed && holesFinished >= options.holes) {
            finish(session, reason: "holes"); return
        }
        // Let replays and commentary breathe, then play on.
        guard session.replay == nil else { return }
        waitClock += delta
        switch game.phase {
        case .aiming:
            guard waitClock > 1.4 else { return }
            // The caddie already aimed along the play line and chose a club.
            let target = game.playLineTargetDistance
            let reach = max(1, game.targetDistance)
            let fraction = min(1, target / reach)
            targetPower = game.club == .putter ? max(0.12, min(1, sqrt(fraction) * 1.05)) : max(0.35, fraction)
            targetAccuracy = (random.unit() - 0.5) * 0.2
            shots += 1
            write(String(format: "swing %@ to %.0f m (reach %.0f m) power %.2f", game.club.title, target, reach, targetPower))
            session.swing()
        case .power:
            if let meter = game.swingMeter, meter.acceptsPowerClick, meter.livePower >= targetPower { session.swing() }
        case .accuracy:
            if let meter = game.swingMeter, meter.state == 4,
               (meter.angle - PGATriClickMeter.rest) / PGATriClickMeter.accuracySpan >= targetAccuracy { session.swing() }
        case .holed:
            if waitClock > 3 { session.swing() }
        default:
            break
        }
        if options.captureEvery > 0, game.phase == .airborne, waitClock > 1.2, waitClock - delta <= 1.2 { capture(session, label: "flight\(shots)") }
    }

    private func finish(_ session: PGAGameSession, reason: String) {
        finished = true
        intervals += session.renderer.drainFrameIntervals()
        let sorted = intervals.filter { $0 > 0 && $0 < 2 }.sorted()
        func percentile(_ q: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] * 1000 }
        let average = sorted.isEmpty ? 0 : Double(sorted.count) / sorted.reduce(0, +)
        let summary: [String: Any] = [
            "course": options.code, "reason": reason, "seconds": ProcessInfo.processInfo.systemUptime - started,
            "holes_finished": holesFinished, "shots": shots, "frames": sorted.count,
            "average_fps": average, "p50_ms": percentile(0.5), "p95_ms": percentile(0.95), "p99_ms": percentile(0.99),
            "max_ms": (sorted.last ?? 0) * 1000, "frames_over_20ms": sorted.filter { $0 > 0.020 }.count,
            "peak_footprint_mb": Double(footprints.max() ?? Self.footprint()) / 1_048_576,
            "drawable": session.drawableDescription, "captures": captures,
            "machine": Self.machine(), "note": "Measured on this machine only; not M1 acceptance unless run on the M1."
        ]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: options.output.appendingPathComponent("summary.json"))
        }
        write("finished (\(reason)) · \(sorted.count) frames · " + String(format: "avg %.1f fps · p95 %.1f ms · p99 %.1f ms", average, percentile(0.95), percentile(0.99)))
        try? log?.close()
        session.exit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }

    /// Offscreen capture of the live scene at 1280 × 800 (no SwiftUI HUD).
    private func capture(_ session: PGAGameSession, label: String) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = session.renderer.scene
        renderer.pointOfView = session.renderer.camera
        let image = renderer.snapshot(atTime: ProcessInfo.processInfo.systemUptime, with: CGSize(width: 1280, height: 800), antialiasingMode: .multisampling4X)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        captures += 1
        try? png.write(to: options.output.appendingPathComponent(String(format: "capture-%03d-%@.png", captures, label)))
    }

    private func write(_ line: String) {
        let stamp = String(format: "%7.1f ", ProcessInfo.processInfo.systemUptime - started)
        log?.write(Data((stamp + line + "\n").utf8))
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func machine() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return "\(String(cString: model)) · \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB · \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}
