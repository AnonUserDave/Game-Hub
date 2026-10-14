import Foundation

/// Source-bound pieces of three distinct games. This is not a completed gameplay simulation.
/// Addresses and source identities are recorded in docs/research/ASTEROIDS.md.
enum AsteroidsEdition: String, Codable, CaseIterable {
    case atari2600 = "asteroids-atari-2600"
    case atari7800 = "asteroids-atari-7800"
    case atari8Bit = "asteroids-atari-8-bit"

    var sourceSHA256: String {
        switch self {
        case .atari2600: return "d1a6e808412b4535c7e54fc25414943a9418b1095b4d4969dc33290f7eaa72a4"
        case .atari7800: return "ec6ef6179644041a9fb77fc6b7c917387219fc388dd5a0fbf8236677f279402e"
        case .atari8Bit: return "1cf45090b216c2363131bac2e4db9101a3c162e31686d7fe30474eaba5b7f97f"
        }
    }
}

/// Atari 2600 bank 1 $FAE2–$FAEF, reset state from $F9EA–$F9EE.
/// No CPU interpreter is present; this directly reconstructs one arithmetic algorithm.
struct Asteroids2600Random: Equatable, Codable {
    private(set) var low: UInt8
    private(set) var high: UInt8

    init(low: UInt8 = 0x34, high: UInt8 = 0x34) {
        self.low = low
        self.high = high
    }

    mutating func next() -> UInt8 {
        let feedback = ((low >> 5) ^ (low >> 6)) & 1
        let carry = high >> 7
        high = (high &<< 1) | feedback
        low = (low &<< 1) | carry
        return high
    }
}

/// Atari 7800 $D32C and $D389/$D391 use speed-dependent turning and 16 ship images.
enum Asteroids7800Rotation {
    static func turnStep(xVelocityHigh: UInt8, yVelocityHigh: UInt8) -> UInt8 {
        func magnitude(_ byte: UInt8) -> Int {
            byte & 0x80 == 0 ? Int(byte) : Int((~byte) &+ 1)
        }
        let sum = magnitude(xVelocityHigh) + magnitude(yVelocityHigh)
        // ADC's carry feeds SBC: preserve even the wrapped $80+$80 case.
        return UInt8(truncatingIfNeeded: 9 - (sum & 0xff) - (sum < 256 ? 1 : 0))
    }

    static func heading(_ current: UInt8, step: UInt8, increasing: Bool) -> UInt8 {
        increasing ? current &+ step : current &- step
    }

    static func imageCode(heading: UInt8) -> UInt8 {
        ((heading >> 3) & 0xfe) &+ 0xb5
    }
}

/// Atari 7800 $F827–$F85B; difficulty indexes are the original 0...3.
struct Asteroids7800Wave: Equatable, Codable {
    let number: UInt8
    let asteroidCount: UInt8
    let countLimit: UInt8
    let saucerTimer: UInt8

    enum Difficulty: Int, Codable, CaseIterable {
        case zero, one, two, three
    }

    static func after(previous: UInt8, difficulty: Difficulty) -> Self {
        let caps: [UInt8] = [8, 12, 14, 16] // ROM $F896
        let timers: [UInt8] = [0, 167, 149, 143] // ROM $F89A
        let number = previous &+ 1
        let sum = Int(number) + 2
        let count = UInt8(truncatingIfNeeded: (sum & 0xff) + difficulty.rawValue + (sum > 255 ? 1 : 0))
        var timer = timers[difficulty.rawValue]
        var borrow = 0
        // Three SBC instructions retain their borrow; subtracting 3*n in a host integer differs.
        for _ in 0..<3 {
            let difference = Int(timer) - Int(number) - borrow
            timer = UInt8(truncatingIfNeeded: difference)
            borrow = difference < 0 ? 1 : 0
        }
        return Self(number: number, asteroidCount: min(count, caps[difficulty.rawValue]),
                    countLimit: caps[difficulty.rawValue], saucerTimer: timer)
    }
}

/// Atari 7800 additive random generator at $F8B2–$F8D2.
/// The initial second index can exceed the copied 55-byte ROM table. The supplied program
/// does not initialize those extra bytes here, so callers must supply the existing RAM page.
struct Asteroids7800Random: Equatable {
    enum SeedError: Error { case pageSize, tableSize }
    private(set) var page: [UInt8]
    private(set) var firstIndex: UInt8
    private(set) var secondIndex: UInt8

    init(existingPage: [UInt8], romSeedTable: [UInt8], timerByte: UInt8) throws {
        guard existingPage.count == 256 else { throw SeedError.pageSize }
        guard romSeedTable.count == 55 else { throw SeedError.tableSize }
        page = existingPage
        page.replaceSubrange(0..<55, with: romSeedTable)
        firstIndex = timerByte & 0x1f
        secondIndex = firstIndex &+ 0x1f
    }

    mutating func next() -> UInt8 {
        let result = page[Int(firstIndex)] &+ page[Int(secondIndex)]
        page[Int(firstIndex)] = result
        firstIndex = firstIndex &- 1
        if firstIndex & 0x80 != 0 { firstIndex = 0x36 }
        secondIndex = secondIndex &- 1
        if secondIndex & 0x80 != 0 { secondIndex = 0x36 }
        return result
    }
}

/// Atari 8-bit object coordinates at pages $0400/$0500 and $0600/$0700,
/// velocities at $0800/$0900 and $0A00/$0B00. Low bytes are fractional.
struct Asteroids8BitMotion: Equatable, Codable {
    var x: UInt16
    var y: UInt16
    var xVelocity: UInt16
    var yVelocity: UInt16

    enum BoundaryMode { case wrap, reflect }

    /// $6186–$61C4 reports integer-coordinate changes before the boundary operation.
    @discardableResult
    mutating func advance(size: UInt8, boundary: BoundaryMode) -> Bool {
        let oldX = x >> 8
        let oldY = y >> 8
        x = x &+ xVelocity
        y = y &+ yVelocity
        let changed = x >> 8 != oldX || y >> 8 != oldY
        Self.boundary(&x, velocity: &xVelocity, limit: 0x9f, size: size, mode: boundary)
        Self.boundary(&y, velocity: &yVelocity, limit: 0x58, size: size, mode: boundary)
        return changed
    }

    private static func boundary(_ position: inout UInt16, velocity: inout UInt16,
                                 limit: UInt8, size: UInt8, mode: BoundaryMode) {
        let integer = UInt8(position >> 8)
        guard integer >= limit || integer &+ size >= limit else { return }
        // The source uses EOR $FF on both bytes, deliberately a one's-complement reflection.
        if mode == .reflect { velocity = ~velocity }
        let replacement: UInt8 = velocity & 0x8000 != 0 ? limit &- size &- 1 : 1
        position = (UInt16(replacement) << 8) | (position & 0xff)
    }

    /// $63C3–$63FF consumes four separate POKEY RANDOM reads. Explicit samples keep
    /// hardware randomness distinct from the 2600/7800 software generators.
    static func spawnVelocity(xMagnitude: UInt8, yMagnitude: UInt8,
                              xSign: UInt8, ySign: UInt8, fast: Bool) -> (x: UInt16, y: UInt16) {
        func component(magnitude: UInt8, sign: UInt8) -> UInt16 {
            let low = magnitude | (fast ? 0x90 : 0x10)
            return sign & 0x80 != 0 ? UInt16(0xff00 | UInt16(~low)) : UInt16(low)
        }
        return (component(magnitude: xMagnitude, sign: xSign),
                component(magnitude: yMagnitude, sign: ySign))
    }

    /// $6400–$6424 chooses original edge coordinates, independently of velocity.
    static func spawnIntegerPosition(xSample: UInt8, ySample: UInt8) -> (x: UInt8, y: UInt8) {
        // The source writes only integer bytes; fractional bytes retain their existing values.
        (xSample & 0x80 != 0 ? 2 : 0x8f, ySample & 0x80 != 0 ? 2 : 0x48)
    }
}

/// The Atari 8-bit bullet collision loop at $6A71–$6AD4 uses strict lower edges and
/// inclusive upper edges, with byte addition. It does not use circular collision.
enum Asteroids8BitCollision {
    static func projectileHits(objectCode: UInt8, objectX: UInt8, objectY: UInt8, extent: UInt8,
                               projectileCode: UInt8, projectileX: UInt8, projectileY: UInt8) -> Bool {
        guard objectCode & 0xf0 == 0, projectileCode & 0x80 == 0 else { return false }
        return objectX < projectileX && objectX &+ extent >= projectileX &&
               objectY < projectileY && objectY &+ extent >= projectileY
    }
}

/// Atari 8-bit $689A–$68B9 interprets an active-low joystick nibble.
enum Asteroids8BitControl {
    static func heading(_ current: UInt8, joystickNibble: UInt8) -> UInt8 {
        if joystickNibble & 8 == 0 { return current &+ 6 }
        if joystickNibble & 4 == 0 { return current &- 6 }
        return current
    }

    static func thrustRequested(joystickNibble: UInt8) -> Bool { joystickNibble & 1 == 0 }
}

/// Atari 8-bit $6C9A–$6CB5 and $7004–$702B. The source stores three BCD bytes.
/// `units` represents their decimal value; the score display appends a trailing zero.
struct Asteroids8BitScore: Equatable {
    enum Award: Int, CaseIterable { case one = 1, two = 2, five = 5, ten = 10, twentyFive = 25, fifty = 50 }
    enum StateError: Error { case scoreRange }
    private(set) var units: Int
    private(set) var lives: UInt8

    init(units: Int, lives: UInt8) throws {
        guard (0..<1_000_000).contains(units) else { throw StateError.scoreRange }
        self.units = units
        self.lives = lives
    }

    /// Returns how many bonus-life sound requests ($71DB with $95) the original issues.
    /// Each repeated award checks the original middle byte's high BCD nibble separately.
    @discardableResult
    mutating func add(_ award: Award, difficultyCode: UInt8) -> Int {
        var bonuses = 0
        for _ in 0...Int(difficultyCode >> 1) {
            let oldNibble = (units / 1_000) % 10
            units = (units + award.rawValue) % 1_000_000
            if (units / 1_000) % 10 != oldNibble {
                if lives != 255 { lives = lives &+ 1 }
                bonuses += 1
            }
        }
        return bonuses
    }
}
