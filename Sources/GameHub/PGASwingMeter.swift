import Foundation

/// The original tri-click swing meter (Engine.dll TriClickMeter 0x101a5fae;
/// docs/research/PGA2005-PRESENTATION.md §5), ported from the reference in
/// Tools/decode_pga2005_cameras.py. Angles are degrees, 0 = 3 o'clock,
/// counter-clockwise positive: 270 (6 o'clock) is rest and a straight strike,
/// 90 (12 o'clock) is 100 % power, 48 is the overswing stop. The original
/// steps once per rendered frame with that frame's whole milliseconds and
/// reads clicks before moving; callers do the same.
struct PGATriClickMeter: Equatable {
    enum Level: Int, Codable, CaseIterable {
        case novice, intermediate, advanced, expert
        var title: String { ["Novice", "Intermediate", "Advanced", "Expert"][rawValue] }
        /// Top speed in degrees per second (DifficultyDescription 0x10231ca9).
        var rate: Int { [200, 260, 325, 355][rawValue] }
        var putterRate: Int { [170, 170, 200, 200][rawValue] }
        var speedup: Float { [0.985, 0.98, 0.975, 0.97][rawValue] }
        var slowdown: Float { [1.015, 1.02, 1.025, 1.03][rawValue] }
    }
    /// Click tick colours: green exact, white under, red overswing.
    enum Tick: Equatable { case exact, under, over }

    static let rest = 270.0, fullPower = 90.0, powerSpan = 180.0
    static let minAngle = 48.0, maxAngle = 311.0, earlyAccuracy = 229.0, accuracySpan = 41.0
    static let slowdownStart = 63.0, snapDegrees = 3
    /// 16.16 fixed-point milliseconds per degree: 6.25 (160 °/s) and 50 (20 °/s).
    static let periodStart = 0x64000, periodSlow = 0x32_0000
    /// Lit art begins at 4:30 and runs clockwise to the marker (SwingMeterFrame::Draw).
    static let litStart = 315.0

    let level: Level
    let putter: Bool
    let twoClick: Bool
    /// 1 lift, 2 backswing (power click), 3 overshoot, 4 return (accuracy click), 5 run-out, 6 done.
    private(set) var state = 1
    private(set) var angle = PGATriClickMeter.rest
    private(set) var powerAngle = 0.0
    private(set) var accuracyAngle = 0.0
    private(set) var missedPower = false
    private(set) var missedDirection = false
    private(set) var powerTick: Tick?
    private(set) var accuracyTick: Tick?
    /// Angle where the power click landed, before overswing compression.
    private(set) var powerClickAngle: Double?
    private var direction = 1
    private var period = PGATriClickMeter.periodStart
    private let stepMin: Int
    private var floor: Int
    private let missJitter: Int

    /// `missJitter` (0…19) stands in for the original rand() % 20 on a missed
    /// power click, so the caller's seeded generator keeps rounds replayable.
    init(level: Level, putter: Bool, twoClick: Bool = false, missJitter: Int = 0) {
        self.level = level; self.putter = putter; self.twoClick = twoClick
        self.missJitter = max(0, min(19, missJitter))
        stepMin = 0x3E8_0000 / (putter ? level.putterRate : level.rate)
        floor = stepMin
    }

    var finished: Bool { state == 6 }
    /// The power click is accepted from the backswing at or past 6 o'clock.
    var acceptsPowerClick: Bool { state == 2 && angle <= Self.rest }
    /// GetPowerPercent 0x101a6fe2: 1.0 at 12 o'clock, at most 1.047 after overswing.
    var power: Double { (Self.rest - powerAngle) / Self.powerSpan }
    /// GetDirectionPercent 0x101a7002: −1 early … 0 straight … +1 late/missed; negated for the putter.
    var directionPercent: Double {
        if twoClick { return 0 }
        let value = (accuracyAngle - Self.rest) / Self.accuracySpan
        return putter ? -value : value
    }
    /// Live power reading of the marker (negative during the lift).
    var livePower: Double { (Self.rest - angle) / Self.powerSpan }

    /// SetStateAtMouseClick 0x101a654d.
    mutating func click() {
        if state == 2 && angle <= Self.rest {
            state = twoClick ? 6 : 3
            if abs(Int(angle - Self.fullPower)) < Self.snapDegrees { angle = Self.fullPower }
            powerClickAngle = angle
            powerAngle = angle
            powerTick = angle == Self.fullPower ? .exact : angle > Self.fullPower ? .under : .over
            if powerAngle < Self.fullPower {
                let over = Self.fullPower - powerAngle
                floor = Int(Double(floor) * (1 - over / 150))
                powerAngle = Self.fullPower - over * 0.2
            }
        } else if state == 4 {
            state = 5
            if abs(Int(angle - Self.rest)) < Self.snapDegrees { angle = Self.rest }
            if angle <= Self.earlyAccuracy { angle = Self.earlyAccuracy }
            accuracyAngle = angle
            accuracyTick = accuracyAngle == Self.rest ? .exact : .under
        }
    }

    /// ComputeNewAngle 0x101a699c with the NextFrame clamp 0x101a67dd.
    mutating func step(milliseconds: Int) {
        guard state != 0, state != 6, milliseconds > 0 else { return }
        let dt = min(milliseconds, 0xB4)
        let delta = min(Double(Float(Double((dt * 0xB6) << 16) / Double(period) / 182)), 16)
        let moving = direction
        func scaled(_ factor: Float) -> Int { Int(pow(Double(factor), Double(dt)) * Double(period)) }
        switch state {
        case 1:
            if period == Self.periodSlow { state = 2 }
            else if period < Self.periodSlow { period = min(scaled(1.005), Self.periodSlow) }
            direction = 1
        case 2:
            if angle > Self.slowdownStart {
                if stepMin < period { period = max(scaled(0.99), floor) }
            } else {
                period = min(scaled(level.slowdown), Self.periodSlow)
            }
            if angle <= Self.minAngle {
                state = twoClick ? 6 : 3
                let tick = 170 - Double(missJitter)
                powerAngle = tick; missedPower = true; powerTick = .under
                if twoClick { angle = tick; return }
                floor = Int(Double(floor) * (1 - 42.0 / 150))
            }
            direction = -1
        case 3:
            if period < Self.periodSlow { period = min(scaled(level.slowdown), Self.periodSlow) } else { state = 4 }
            direction = -1
        default:
            if angle < Self.maxAngle {
                if floor < period { period = max(scaled(level.speedup), floor) }
            } else {
                if state == 4 { accuracyAngle = Self.maxAngle; missedDirection = true; accuracyTick = .under }
                state = 6
            }
            direction = 1
        }
        angle = min(max(Double(moving) * delta + angle, Self.minAngle), Self.maxAngle)
    }
}
