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
