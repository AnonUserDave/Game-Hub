import CoreAudio
import XCTest
@testable import GameHub

final class PGAAudioTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func rules() throws -> PGAAudioRules {
        guard let rules = PGAAudioRules.load(directory: root.appendingPathComponent("Library/Imported/pga2005/audio")) else {
            throw XCTSkip("Prepare original audio with python3 Tools/prepare_pga2005.py")
        }
        return rules
    }

    func testOperatorsFollowTheScriptEvaluator() {
        let facts: [Int64] = [0b0110, 5]
        func check(_ op: String, _ bit: Int, _ value: Double) -> Bool { PGAAudioRules.Condition(bit: bit, op: op, value: value).matches(facts) }
        XCTAssertTrue(check("eq", 1, 5)); XCTAssertFalse(check("ne", 1, 5))
        XCTAssertTrue(check("gt", 1, 4)); XCTAssertFalse(check("lt", 1, 5))
        XCTAssertTrue(check("any_bits", 0, 0b0010)); XCTAssertFalse(check("any_bits", 0, 0b1001))
        XCTAssertTrue(check("missing_bits", 0, 0b0011)); XCTAssertFalse(check("missing_bits", 0, 0b0110))
        XCTAssertTrue(check("no_bits", 0, 0b1001)); XCTAssertFalse(check("no_bits", 0, 0b0100))
        XCTAssertTrue(check("eq", 30, 0), "absent bits read as zero")
    }

    func testSwingSoundsFollowOriginalPriorities() throws {
        let rules = try rules()
        var random = SystemRandomNumberGenerator()
        func swing(_ club: PGAClub, flags: UInt32, teed: Bool, power: Double, accuracy: Double = 0) -> String? {
            rules.select(eventClass: 1, sub: 3, facts: PGAAudioRules.swingFacts(club: club, lieFlags: flags, teed: teed, power: power,
                                                                                 accuracy: accuracy, strokes: teed ? 0 : 1, distanceToPin: 300),
                         fired: [:], using: &random)
        }
        XCTAssertEqual(swing(.driver, flags: 0x1000, teed: true, power: 0.95), "swing.driver.tee_perfect")
        XCTAssertEqual(swing(.driver, flags: 0x1000, teed: true, power: 0.85), "swing.driver.tee")
        XCTAssertEqual(swing(.driver, flags: 0x1000, teed: true, power: 0.5), "swing.driver.tee_25")
        XCTAssertEqual(swing(.driver, flags: 0x1, teed: false, power: 0.8), "swing.driver.generic")
        XCTAssertEqual(swing(.iron7, flags: 0x2, teed: false, power: 0.4), "swing.iron.rough")
        XCTAssertEqual(swing(.iron7, flags: 0x2, teed: false, power: 0.8), "swing.iron.rough_hard")
        XCTAssertEqual(swing(.sandWedge, flags: 0x8, teed: false, power: 0.5), "swing.iron.sand")
        XCTAssertEqual(swing(.putter, flags: 0x4, teed: false, power: 0.3), "swing.putt.hard")
        XCTAssertEqual(swing(.putter, flags: 0x4, teed: false, power: 0.04), "swing.putt.soft")
    }

    func testCollisionSoundsUseSurfaceIdsAndImpactStrength() throws {
        let rules = try rules()
        var random = SystemRandomNumberGenerator()
        func hit(_ id: Int, _ flags: UInt32, _ speed: Double) -> String? {
            guard let facts = PGAAudioRules.impactFacts(soundID: id, flags: flags, normalSpeed: speed) else { return nil }
            return rules.select(eventClass: 3, sub: 4, facts: facts, fired: [:], using: &random)
        }
        XCTAssertNil(hit(902, 0x4, 0.1), "impacts below magnitude 0.1 are silent")
        XCTAssertEqual(hit(902, 0x4, 0.25), "ball.hit.green_soft")
        XCTAssertEqual(hit(902, 0x4, 3), "ball.hit.green_hard")
        XCTAssertEqual(hit(901, 0x1, 3), "ball.hit.fairway")
        XCTAssertEqual(hit(905, 0x2, 3), "ball.hit.rough")
        XCTAssertEqual(hit(904, 0x8, 3), "ball.hit.sand")
        XCTAssertEqual(hit(903, 0x40, 3), "ball.hit.water")
        XCTAssertEqual(hit(908, 0x400, 3), "ball.hit.cartpath")
    }

    func testEveryReferencedSoundIsPrepared() throws {
        let rules = try rules()
        let directory = root.appendingPathComponent("Library/Imported/pga2005/audio")
        var missing: [String] = []
        for event in rules.events.values { for file in event.groups.joined() where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) { missing.append(file) } }
        for course in rules.courses.values {
            for folder in course.ambient_folders.values { for file in folder.files where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) { missing.append(file) } }
        }
        XCTAssertEqual(missing, [])
        XCTAssertGreaterThan(rules.courses["PBL"]?.emitters.count ?? 0, 500)
    }

    func testEnginePlaysSwingImpactAndAmbience() throws {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else {
            XCTAssertNil(PGAAudioEngine(root: root), "A missing output device should leave the golf session playable without audio")
            throw XCTSkip("CoreAudio has no default output device in this test environment")
        }
        _ = try rules()
        let course = try PGAOriginalPlayableCourse.load(code: "PBL", root: root)
        let audio = try XCTUnwrap(PGAAudioEngine(root: root))
        audio.start()
        audio.useCourse(code: "PBL", transform: course.transform)
        audio.setHole(7)
        let tee = course.course.holes[6].tee
        audio.setListener(position: tee + PGAVector(x: 0, y: 2, z: 4), forward: PGAVector(x: 0, y: 0, z: -1), up: PGAVector(x: 0, y: 1, z: 0))
        audio.trigger(eventClass: 1, sub: 3, facts: PGAAudioRules.swingFacts(club: .wedge, lieFlags: 0x1000, teed: true, power: 0.6,
                                                                            accuracy: 0, strokes: 0, distanceToPin: 100), at: tee)
        for _ in 0..<3 { audio.backgroundTick() }
        let status = audio.status
        guard status.running else { throw XCTSkip("No audio output device available") }
        XCTAssertGreaterThan(status.buffers, 10, "gameplay sounds preload")
        XCTAssertGreaterThanOrEqual(status.sounding, 2, "swing plus the hole's ambient beds")
        XCTAssertLessThan(status.bytes, 40 * 1024 * 1024)
        audio.stop()
        XCTAssertEqual(audio.status.buffers, 0)
    }

    func testGalleryReactions() {
        let inch = PGACourseTransform.metersPerInch
        func shot(_ club: PGAClub, tee: Bool = false, start: UInt32 = 0x1, from: Double, to: Double, result: UInt32,
                  carried: Double, holed: Bool = false, penalty: PGASurface? = nil) -> String? {
            PGAAudioRules.crowdReaction(.init(club: club, fromTee: tee, par: 4, startFlags: tee ? 0x9000 : start, startDistance: from,
                                              accuracy: 0, resultFlags: result, resultDistance: to, shotDistance: carried, holed: holed, penalty: penalty))
        }
        XCTAssertEqual(shot(.driver, tee: true, from: 360, to: 90, result: 0x1, carried: 270), "crowd.drive_long_fairway")
        XCTAssertEqual(shot(.driver, tee: true, from: 360, to: 130, result: 0x1, carried: 230), "crowd.drive_fairway")
        XCTAssertEqual(shot(.driver, tee: true, from: 360, to: 130, result: 0x8, carried: 230), "crowd.drive_bunker")
        XCTAssertEqual(shot(.driver, tee: true, from: 360, to: 0, result: 0, carried: 0, penalty: .out), "crowd.drive_out_of_bounds")
        XCTAssertEqual(shot(.iron7, from: 150, to: 4, result: 0x4, carried: 146), "crowd.approach_good")
        XCTAssertEqual(shot(.iron7, from: 150, to: 1, result: 0x4, carried: 149), "crowd.approach_close")
        XCTAssertEqual(shot(.iron7, from: 150, to: 12, result: 0x4, carried: 140), "crowd.approach_green")
        XCTAssertEqual(shot(.putter, start: 0x4, from: 400 * inch, to: 0, result: 0x4000, carried: 400 * inch, holed: true), "crowd.putt_made_long")
        XCTAssertEqual(shot(.putter, start: 0x4, from: 3, to: 0.3, result: 0x4, carried: 2.7), "crowd.putt_near_miss")
        XCTAssertEqual(shot(.wedge, from: 20, to: 0, result: 0x4000, carried: 20, holed: true), "crowd.chip_in")
        XCTAssertNil(shot(.putter, start: 0x4, from: 1.5, to: 0.9, result: 0x4, carried: 0.6))
    }
}

/// Deterministic generator for script tests (SplitMix64).
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Class-2 shot values (ShotEvent 0x102146cb), the script interpreter rules
/// and the original commentary/gallery line choice for representative shots.
final class PGACommentaryTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let audioDirectory = root.appendingPathComponent("Library/Imported/pga2005/audio")
    private static let book = PGAScriptBook.load(directory: audioDirectory)
    private static let pebble: Result<PGAOriginalPlayableCourse, Error>? = {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/Imported/pga2005/PBL/terrain.ghpc").path) else { return nil }
        return Result { try PGAOriginalPlayableCourse.load(code: "PBL", root: root) }
    }()
    private let inch = PGACourseTransform.metersPerInch
    private var yard: Double { 36 * inch }

    private func scripts() throws -> PGAScriptBook {
        guard let book = Self.book, book.scripts["announcer"] != nil else {
            throw XCTSkip("Import commentary with python3 Tools/import_pga2005_audio.py")
        }
        return book
    }

    // MARK: Representative shots (par 4, pin 420 yd down +z from the tee)

    private var pin: PGAVector { PGAVector(x: 0, y: 0, z: 420 * yard) }

    private func drive(end: PGAVector, flags: UInt32, index: Int) -> PGAShotInputs {
        var inputs = PGAShotInputs(sub: 1, club: 0, strokes: 0, ballOnTee: true, addressFlags: 0x9000, golfer: .zero, ball: end,
                                   ballFlags: flags, playerBall: .zero, pin: pin, ideal: PGAVector(x: 0, y: 0, z: 280 * yard),
                                   aimHeading: 0, hole: 1, par: 4)
        inputs.flightIndex = index
        return inputs
    }

    private var greatDrive: PGAShotInputs { drive(end: PGAVector(x: 0.4, y: 0, z: 290 * yard), flags: 0x1, index: 4) }

    private var closeApproach: PGAShotInputs {
        let golfer = PGAVector(x: 2, y: 0, z: 270 * yard)
        var inputs = PGAShotInputs(sub: 1, club: PGAOriginalClub.iron7.rawValue, strokes: 1, addressFlags: 0x1, golfer: golfer,
                                   ball: pin + PGAVector(x: 0.6, y: 0, z: -0.7), ballFlags: 0x4, playerBall: golfer, pin: pin,
                                   ideal: pin, aimHeading: 0, hole: 1, par: 4)
        inputs.flightIndex = 12
        return inputs
    }

    private func longPutt(sub: Int) -> PGAShotInputs {
        let golfer = pin + PGAVector(x: 0, y: 0, z: -50 * 12 * inch)
        var inputs = PGAShotInputs(sub: sub, club: PGAOriginalClub.putter.rawValue, shotStyle: 6, strokes: sub == 2 ? 3 : 2,
                                   addressFlags: 0x4, golfer: golfer, ball: pin, ballFlags: 0x4004, playerBall: sub == 2 ? pin : golfer,
                                   playerBallHoled: sub == 2, pin: pin, ideal: pin, aimHeading: 0, hole: 1, par: 4)
        inputs.flightIndex = sub == 1 ? 8 : 0
        inputs.putts = sub == 2 ? 1 : 0
        inputs.score = sub == 2 ? -1 : 0
        return inputs
    }

    private func threePutt(strokes: Int) -> PGAShotInputs {
        let golfer = pin + PGAVector(x: 0.3, y: 0, z: -0.8)
        var inputs = PGAShotInputs(sub: 2, club: PGAOriginalClub.putter.rawValue, shotStyle: 6, strokes: strokes, addressFlags: 0x4,
                                   golfer: golfer, ball: pin, ballFlags: 0x4004, playerBall: pin, playerBallHoled: true, pin: pin,
                                   ideal: pin, aimHeading: 0, hole: 1, par: 4)
        inputs.putts = 3
        inputs.score = Int64(strokes - 4)
        return inputs
    }

    // MARK: Value builder

    func testCompactValuesReadTheNextProvidedBit() {
        var facts = PGAScriptFacts(eventClass: 2, sub: 1, mask: PGAScriptFacts.shotMask)
        facts[4] = 44; facts[6] = 6; facts[27] = 27; facts[29] = 29
        XCTAssertEqual(facts.compared(bit: 4), 44)
        XCTAssertEqual(facts.compared(bit: 5), 6, "bit 5 is not provided, so a condition on it reads bit 6")
        XCTAssertEqual(facts.compared(bit: 28), 29, "bit 28 is not provided either")
        var location = PGAScriptFacts(eventClass: 9, sub: 29, mask: PGAScriptFacts.locationMask)
        location[23] = 180
        XCTAssertEqual(location.compared(bit: 21), 180, "class 9 rules on bit 21 read the elevation value")
        let negative = PGAScriptBook.Condition(bit: 9, op: "eq", value: 0xFFFF_FFFE)
        var score = PGAScriptFacts(eventClass: 2, sub: 2, mask: PGAScriptFacts.shotMask)
        score[9] = -2
        XCTAssertTrue(negative.matches(score), "score values compare as the original's 32-bit words")
        XCTAssertFalse(PGAScriptBook.Condition(bit: 9, op: "lt", value: 3).matches(score), "operators 3/4 are unsigned")
        XCTAssertFalse(PGAScriptBook.Condition(bit: 9, op: "op65535", value: 0).matches(score))
    }

    func testGreatDriveValues() {
        let facts = PGAShotFacts.build(greatDrive)
        XCTAssertEqual(facts.mask, 0x6FFF_FFDF)
        XCTAssertEqual(facts[0], 0x3, "driver: club mask 1 | 2")
        XCTAssertEqual(facts[1], 0x401, "first stroke, normal style")
        XCTAssertEqual(facts[2], 0x9000)
        XCTAssertEqual(facts[3], 420 * 36, "off the green the distance is from the lie, not the predicted end")
        XCTAssertEqual(facts[15], facts[3])
        XCTAssertEqual(facts[4], 290 * 36, "golfer to predicted end, truncated")
        XCTAssertEqual(facts[22], facts[4])
        XCTAssertEqual(facts[10], 1 | 8, "left of the line (+x is left facing +z), past the 280 yd target")
        XCTAssertEqual(facts[11], 15)
        XCTAssertEqual(facts[17], 10 * 36)
        XCTAssertEqual(facts[12], 4)
        XCTAssertEqual(facts[21], 0x1)
        XCTAssertEqual([facts[25], facts[26], facts[27], facts[29], facts[30]], [18, 1, 1, 0x200000, 0x200000])
    }

    func testApproachPuttAndHazardValues() {
        let approach = PGAShotFacts.build(closeApproach)
        XCTAssertEqual(approach[0], 0x4 | 0x80, "7-iron: iron, mid iron")
        XCTAssertEqual(approach[1], 0x400)
        XCTAssertEqual(approach[3], 36, "a green finish measures from the predicted end")
        XCTAssertEqual(approach[8], 1)
        let made = PGAShotFacts.build(longPutt(sub: 2))
        XCTAssertEqual([made[0], made[1], made[3], made[8], made[18]], [0x10, 0x2, 0, 3, 1])
        XCTAssertEqual(made[4], 600)
        XCTAssertEqual(made[9], Int64(-1))
        XCTAssertEqual(made[21], 0x4004)
        let water = PGAShotFacts.build(drive(end: PGAVector(x: -20 * 36 * inch, y: 0, z: 250 * yard), flags: 0x40, index: 11))
        XCTAssertEqual(water[10], 2 | 4, "right of the line and short of the target")
        XCTAssertEqual(water[11], 720)
        XCTAssertEqual(water[21], 0x40)
    }

    func testWindAndGreenSlopeFlags() {
        // Aim +z; right of +z is −x in the mirrored native frame.
        XCTAssertEqual(PGAShotFacts.windFlags(mph: 10, direction: .pi, aim: 0, ideal: PGAVector(x: 0, y: 0, z: 1)), 0x4 | 0x20, "headwind")
        XCTAssertEqual(PGAShotFacts.windFlags(mph: 10, direction: 0, aim: 0, ideal: nil), 0x10, "tailwind")
        XCTAssertEqual(PGAShotFacts.windFlags(mph: 10, direction: -.pi / 2, aim: 0, ideal: nil), 0x1, "blowing to the right: left to right")
        XCTAssertEqual(PGAShotFacts.windFlags(mph: 0, direction: 0, aim: 0, ideal: nil), 0)
        let up = PGAVector(x: 0, y: 1, z: 0)
        let ball = PGAVector(x: 0, y: 0, z: 0), hole = PGAVector(x: 0, y: 8 * inch, z: 6)
        XCTAssertEqual(PGAShotFacts.greenSlope(ball: ball, pin: hole, ballNormal: up, pinNormal: up, middleNormal: up), 0x4, "steep uphill")
        let tilted = PGAVector(x: 0.1, y: 1, z: 0)  // falls toward +x, the golfer's left
        XCTAssertEqual(PGAShotFacts.greenSlope(ball: ball, pin: PGAVector(x: 0, y: 0, z: 6), ballNormal: tilted, pinNormal: tilted,
                                               middleNormal: tilted), 0x100 | 0x80, "level, severe break left")
        XCTAssertEqual(PGAShotFacts.miss(golfer: .zero, end: PGAVector(x: -1, y: 0, z: 5), ideal: PGAVector(x: 0, y: 0, z: 10)).flags, 2 | 4)
    }

    func testClubMaskAndShotFlags() {
        XCTAssertEqual(PGAShotFacts.clubMask(PGAOriginalClub.wood3.rawValue), 0x2)
        XCTAssertEqual(PGAShotFacts.clubMask(PGAOriginalClub.iron3.rawValue), 0x44)
        XCTAssertEqual(PGAShotFacts.clubMask(PGAOriginalClub.iron9.rawValue), 0x104)
        XCTAssertEqual(PGAShotFacts.clubMask(PGAOriginalClub.sandWedge.rawValue), 0x124)
        XCTAssertEqual(PGAShotFacts.clubMask(PGAOriginalClub.putter.rawValue), 0x10)
        XCTAssertEqual(PGAShotFacts.shotFlags(strokes: 2, ballOnTee: false, style: 7), 0x4)
        XCTAssertEqual(PGACommentaryDirector.style(club: .sandWedge, power: 0.4, distanceToPin: 30), 7)
        XCTAssertEqual(PGACommentaryDirector.flightIndex(elapsed: 50, total: 59, startDistance: 100, putt: false), nil, "under 60 samples")
        XCTAssertEqual(PGACommentaryDirector.flightIndex(elapsed: 50, total: 59, startDistance: 1, putt: true), 16)
        XCTAssertEqual(PGACommentaryDirector.flightIndex(elapsed: 5, total: 100, startDistance: 1, putt: true), nil, "putts wait for 10 %")
        XCTAssertEqual(PGACommentaryDirector.flightIndex(elapsed: 100, total: 100, startDistance: 100, putt: false), 20)
    }

    // MARK: Original line choice (probabilities forced, as QueueBeginShot does)

    private func choose(_ script: String, _ facts: PGAScriptFacts, book: PGAScriptBook) -> String? {
        var interpreter = PGAScriptInterpreter()
        var random = SeededGenerator(state: 7)
        return interpreter.run(script, script: book.scripts[script]!, facts: facts, now: 100, busyUntil: 0, force: true,
                               using: &random).first?.situation.trimmingCharacters(in: .whitespaces)
    }

    func testRepresentativeShotsPickOriginalLines() throws {
        let book = try scripts()
        // Great drive: the announcer at 20 % of the flight, the gallery at 50 %.
        XCTAssertEqual(choose("announcer", PGAShotFacts.build(greatDrive), book: book)?.hasPrefix("InFlight: Male/Tee/Long/"), true)
        var halfway = greatDrive; halfway.flightIndex = 10
        XCTAssertEqual(choose("gallery", PGAShotFacts.build(halfway), book: book), "In Flight - Drive - 275+y in fairway")
        XCTAssertNil(choose("gallery", PGAShotFacts.build(greatDrive), book: book))
        // Approach to 3 ft.
        let approach = PGAShotFacts.build(closeApproach)
        XCTAssertEqual(choose("gallery", approach, book: book), "In Flight - Approach - Fairway to Green <20ft")
        XCTAssertEqual(choose("announcer", approach, book: book)?.contains("Green/AtFlag/ApchPar4V"), true)
        // 50 ft putt holed for birdie.
        XCTAssertEqual(choose("announcer", PGAShotFacts.build(longPutt(sub: 1)), book: book), "ToHole: LongPuttInV")
        XCTAssertEqual(choose("analyst", PGAShotFacts.build(longPutt(sub: 2)), book: book)?.hasPrefix("PuttResult: Birdie/"), true)
        // Water and out of bounds off the tee.
        let wet = drive(end: PGAVector(x: 0, y: 0, z: 250 * yard), flags: 0x40, index: 11)
        XCTAssertEqual(choose("announcer", PGAShotFacts.build(wet), book: book)?.hasPrefix("InFlight: Male/Tee/Avg/WaterV"), true)
        var wetLate = wet; wetLate.flightIndex = 16
        XCTAssertEqual(choose("gallery", PGAShotFacts.build(wetLate), book: book), "In Flight - Drive - Average/Water")
        var out = wet; out.ballFlags = 0x80
        XCTAssertEqual(choose("announcer", PGAShotFacts.build(out), book: book), "InFlight: Male/Tee/Average/OBV")
        out.flightIndex = 16
        XCTAssertEqual(choose("gallery", PGAShotFacts.build(out), book: book), "In Flight - Drive - Average/OB")
        // Three putts: par and bogey.
        let parSave = PGAShotFacts.build(threePutt(strokes: 4)), analyst = book.scripts["analyst"]!
        let tied = PGAScriptInterpreter().best("analyst", script: analyst, facts: parSave).map { analyst.situations[$0].d.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(tied.contains("PuttResult: 3PuttPar/Par4V"), "\(tied)")
        XCTAssertEqual(choose("analyst", PGAShotFacts.build(threePutt(strokes: 5)), book: book), "PuttResult: Bogey/Par4V")
        // First tee: Tiger Woods is model type 1.
        var tee = greatDrive
        tee.sub = 19; tee.flightIndex = 0; tee.ball = .zero; tee.ballFlags = 0x9001
        XCTAssertEqual(choose("announcer", PGAShotFacts.build(tee), book: book), "IntroPlayer: 1stTee/Woods1V")
        // Pebble Beach course intro and the analyst's course state.
        let context = PGACommentaryContext(gameType: .stroke, courseCode: "PBL", conditions: PGAConditions())
        XCTAssertEqual(choose("announcer", context.intro(sub: 6, hole: 1), book: book), "IntroCourse: Pebble Beach1V")
        XCTAssertEqual(choose("analyst", context.intro(sub: 8, hole: 1), book: book)?.hasPrefix("CourseState:"), true)
        // A dead rule: bits 3 and 15 hold the same distance.
        let dead = book.scripts["gallery"]!.situations.first { $0.d == "In Flight - Approach <4ft to pin" }!
        XCTAssertTrue(dead.if.contains(PGAScriptBook.Condition(bit: 3, op: "gt", value: 0x1680)))
        XCTAssertTrue(dead.if.contains(PGAScriptBook.Condition(bit: 15, op: "lt", value: 0x30)))
    }

    // MARK: Shared commentary channel

    private func syntheticBook() throws -> PGAScriptBook {
        let json = """
        {"scripts": {"announcer": {
          "situations": [{"i":0,"c":2,"s":1,"p":100,"one":false,"if":[[12,"eq",4]],"do":[0,1],"d":"two actions"},
                         {"i":1,"c":2,"s":2,"p":100,"one":false,"if":[],"do":[2],"d":"sequence"},
                         {"i":2,"c":2,"s":19,"p":100,"one":false,"if":[],"do":[3],"d":"rotation"}],
          "actions": [{"t":8,"p":100,"fl":0,"seq":false,"r":[0]}, {"t":8,"p":100,"fl":0,"seq":false,"r":[1]},
                      {"t":8,"p":100,"fl":1,"seq":true,"r":[0,1]}, {"t":8,"p":100,"fl":0,"seq":false,"r":[0,1,2]}],
          "responses": [{"t":10,"f":"commentary/a.mp3"}, {"t":10,"f":"commentary/b.mp3"}, {"t":10,"f":null}]}}}
        """
        return try JSONDecoder().decode(PGAScriptBook.self, from: Data(json.utf8))
    }

    func testOneCommentaryLineAtATimeAndNoQuickRepeats() throws {
        let book = try syntheticBook(), script = book.scripts["announcer"]!
        var interpreter = PGAScriptInterpreter()
        var random = SeededGenerator(state: 1)
        var flight = PGAScriptFacts(eventClass: 2, sub: 1, mask: PGAScriptFacts.shotMask)
        flight[12] = 4
        let first = interpreter.run("announcer", script: script, facts: flight, now: 0, busyUntil: 0, using: &random)
        XCTAssertEqual(first.map(\.files), [["commentary/a.mp3"]], "the second action is dropped while the first speaks")
        let busy = interpreter.run("announcer", script: script, facts: flight, now: 1, busyUntil: 5, using: &random)
        XCTAssertEqual(busy, [], "dropped, not queued, while a line plays")
        // Sequence (file flag 1 → 0x4000): every response in order, but not
        // the file that started under 20 s ago.
        let stopped = PGAScriptFacts(eventClass: 2, sub: 2, mask: PGAScriptFacts.shotMask)
        let sequence = interpreter.run("announcer", script: script, facts: stopped, now: 10, busyUntil: 0, using: &random)
        XCTAssertEqual(sequence.map(\.files), [["commentary/b.mp3"]])
        let later = interpreter.run("announcer", script: script, facts: stopped, now: 40, busyUntil: 0, using: &random)
        XCTAssertEqual(later.map(\.files), [["commentary/a.mp3", "commentary/b.mp3"]])
        // Least-played rotation; the silent placeholder takes its turn too.
        let before = PGAScriptFacts(eventClass: 2, sub: 19, mask: PGAScriptFacts.shotMask)
        var heard: [String] = []
        interpreter = PGAScriptInterpreter()
        for step in 0..<3 {
            heard += interpreter.run("announcer", script: script, facts: before, now: 100 + Double(step) * 30, busyUntil: 0,
                                     using: &random).flatMap(\.files)
        }
        XCTAssertEqual(Set(heard), ["commentary/a.mp3", "commentary/b.mp3"])
        XCTAssertEqual(heard.count, 2, "one of three turns plays the silent response")
    }

    func testDropWatchdogInterruptsInsteadOfOverlapping() throws {
        let book = try syntheticBook(), script = book.scripts["announcer"]!
        var interpreter = PGAScriptInterpreter()
        var random = SeededGenerator(state: 3)
        var flight = PGAScriptFacts(eventClass: 2, sub: 1, mask: PGAScriptFacts.shotMask)
        flight[12] = 4
        var played = 0
        for step in 0..<40 {
            played += interpreter.run("announcer", script: script, facts: flight, now: Double(step) * 60, busyUntil: .infinity,
                                      using: &random).count
        }
        XCTAssertGreaterThan(played, 0, "after 16 drops the original forgets the playing handle")
        XCTAssertLessThan(played, 10)
    }

    func testEngineSpeaksOneLineAndQueuesTheNext() throws {
        let book = try scripts()
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown, let audio = PGAAudioEngine(root: Self.root) else {
            throw XCTSkip("CoreAudio has no default output device in this test environment")
        }
        XCTAssertTrue(audio.scripted)
        audio.start()
        var tee = greatDrive
        tee.sub = 19; tee.flightIndex = 0; tee.ball = .zero; tee.ballFlags = 0x9001
        let intro = PGAScriptRequest(facts: PGAShotFacts.build(tee), scripts: ["announcer"], force: true)
        let context = PGACommentaryContext()
        audio.perform([intro, PGAScriptRequest(facts: context.intro(sub: 8, hole: 1), scripts: ["analyst"], timing: .whenIdle, force: true)])
        let status = audio.status
        guard status.running else { throw XCTSkip("No audio output device available") }
        XCTAssertNotNil(book.scripts["announcer"])
        XCTAssertTrue(status.speaking, "Woods' first-tee introduction plays")
        XCTAssertEqual(status.waiting, 1, "the analyst waits for silence")
        XCTAssertEqual(status.buffers, audio.status.buffers, "speech is not cached")
        audio.perform([.cancel])
        XCTAssertEqual(audio.status.waiting, 0)
        audio.stop()
        XCTAssertFalse(audio.status.speaking)
    }

    // MARK: Director on Pebble Beach

    func testDirectorRaisesOriginalEventsOnPebbleBeach() throws {
        guard let pebble = Self.pebble else { throw XCTSkip("Original PBL data not prepared; run Tools/prepare_pga2005.py") }
        let course = try pebble.get()
        var game = PGASimulation(course: course.course, terrains: course.terrains)
        var director = PGACommentaryDirector(context: PGACommentaryContext(gameType: .stroke, courseCode: "PBL", conditions: game.conditions))
        var requests = director.update(game, events: [])
        XCTAssertEqual(requests.map { "\($0.facts.eventClass)/\($0.facts.sub)" }, ["12/6", "12/7", "12/8", "9/28", "2/19"])
        XCTAssertTrue(requests.allSatisfy { $0.timing == .whenIdle })
        XCTAssertEqual((requests.last?.facts[2] ?? 0) & 0x9000, 0x9000, "the tee shot starts on the tee box, on the tee")
        XCTAssertEqual(director.update(game, events: []), [], "nothing new on the same turn")

        game.strike(power: 0.9, accuracy: 0)
        let whole = try XCTUnwrap(game.previewShot())
        requests = director.update(game, events: game.takeEvents())
        XCTAssertTrue(requests.contains(.cancel))
        XCTAssertTrue(requests.contains { $0.facts.eventClass == 1 && $0.facts.sub == 3 })
        XCTAssertLessThanOrEqual(whole.totalTicks, 0x800)
        let framesToPreview = (whole.totalTicks + PGACommentaryDirector.previewTicksPerFrame - 1) / PGACommentaryDirector.previewTicksPerFrame
        XCTAssertLessThan(framesToPreview, 60, "the preview is ready before the first in-flight event (≥ 60 ticks)")

        var indexes: [Int64] = [], gallery: [Int64] = [], stopped: [PGAScriptFacts] = []
        var steps = 0, sliced: PGAShotPreview?
        while (game.phase.inMotion || stopped.isEmpty) && steps < 4000 {
            if sliced == nil { sliced = director.shot?.preview }
            game.update(deltaTime: 1.0 / 60)
            for request in director.update(game, events: game.takeEvents()) where request.facts.eventClass == 2 {
                if request.facts.sub == 1 {
                    if request.scripts == ["gallery"] { gallery.append(request.facts[12]) } else { indexes.append(request.facts[12]) }
                }
                if request.facts.sub == 2 { stopped.append(request.facts) }
            }
            steps += 1
        }
        XCTAssertEqual(indexes, indexes.sorted())
        XCTAssertEqual(indexes.first ?? 0, 4, "the first in-flight event is index 4")
        XCTAssertEqual(gallery, Array(4...Int64(gallery.last ?? 3)), "the gallery hears every index")
        let preview = try XCTUnwrap(sliced)
        XCTAssertEqual(preview, whole, "slice-by-slice and whole previews agree")
        XCTAssertEqual(stopped.count, 1)
        let rest = try XCTUnwrap(stopped.first)
        XCTAssertEqual(rest[8], 1, "one stroke taken")
        XCTAssertEqual(rest[1] & 0x1, 0, "no longer the first stroke")
        XCTAssertGreaterThan(rest[4], 150 * 36, "a 90 % drive travels well over 150 yd")
        if game.lie.playable {
            XCTAssertEqual(game.ball.distance(to: preview.end), 0, accuracy: 0.05, "the precalculated end is where the ball stopped")
        }
    }
}
