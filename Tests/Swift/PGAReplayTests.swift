import XCTest
@testable import GameHub

final class PGAReplayTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    func testReplayChancesFollowReplayStn() throws {
        guard let rules = PGAReplayRules.load(root: root) else { throw XCTSkip("Camera scripts not prepared") }
        var random = PGARandom(seed: "replay-test")
        func chance(tee: Bool = false, putt: Bool = false, start: UInt32 = 0x1, result: UInt32, holed: Bool = false,
                    pin: Double, shot: Double, par: Int = 4, strokes: Int = 2) -> Int? {
            rules.chance(for: PGAReplayRules.facts(fromTee: tee, putt: putt, startFlags: start, resultFlags: result, holed: holed,
                                                   distanceToPin: pin, shotDistance: shot, par: par, strokes: strokes), random: &random)
        }
        XCTAssertEqual(chance(tee: true, start: 0x9000, result: 0x4, holed: true, pin: 0, shot: 150, par: 3, strokes: 1), 100, "hole in one")
        XCTAssertEqual(chance(putt: true, start: 0x4, result: 0x4, holed: true, pin: 0, shot: 12), 80, "30+ ft putt holed")
        XCTAssertEqual(chance(result: 0x4, pin: 2, shot: 90), 80, "75+ yd shot inside 3 yd")
        XCTAssertEqual(chance(tee: true, start: 0x9000, result: 0x4, pin: 6, shot: 280, par: 4, strokes: 1), 80, "drive on to a par-4 green")
        XCTAssertNil(chance(result: 0x1, pin: 120, shot: 150), "an ordinary approach gets no replay")
        XCTAssertNil(chance(putt: true, start: 0x4, result: 0x4, pin: 1, shot: 5), "a missed putt gets no replay")
    }

    func testClipPlaysThePathAndCutsToTheTower() throws {
        let path = (0...60).map { i in PGAVector(x: 0, y: Double(i) * Double(60 - i) * 0.02, z: Double(i) * 2.5) }
        var clip = try XCTUnwrap(PGAReplayClip(path: path))
        XCTAssertEqual(clip.ball, path[0])
        clip.advance(1.0 / 15 * 10.5)
        XCTAssertEqual(clip.ball.z, 26.25, accuracy: 1e-9, "interpolates between 15 Hz samples")
        let chase = clip.camera
        XCTAssertLessThan(chase.position.z, 0, "behind the start while the ball climbs")
        clip.advance(3)
        let tower = clip.camera
        XCTAssertGreaterThan(tower.position.z, 100, "beside the landing area later")
        clip.advance(20)
        XCTAssertTrue(clip.finished)
        XCTAssertNil(PGAReplayClip(path: [path[0], path[1]]))
    }
}
