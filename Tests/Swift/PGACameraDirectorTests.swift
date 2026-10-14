import Foundation
import XCTest
@testable import GameHub

final class PGACameraDirectorTests: XCTestCase {
    func testFixedScriptFramesTheGolferWithSourceOffsets() throws {
        // Tiny first-party fixture in the decoded schema; source .stn bytes
        // and prepared original media stay outside Git.
        let json = """
        {"scripts":[{"file":"f_camera.stn",
          "situations":[{"situation_type":11,"event":28,"conditions":[],"actions":[0],"single_random_action":false,"priority":100}],
          "actions":[{"probability_percent":100,"responses":[0,1]}],
          "responses":[
            {"response_type":13,"command":0,"object_type":7,"offset_ft":[0,8,-25],"start_mode":1,"flags":6,"duration_s":0,"amount":0},
            {"response_type":13,"command":1,"object_type":7,"offset_ft":[0,6,0],"start_mode":2,"flags":0,"duration_s":0,"amount":0}
          ]}]}
        """
        var director = try XCTUnwrap(PGACameraDirector(data: Data(json.utf8)))
        let game = PGASimulation()
        let pose = try XCTUnwrap(director.update(game, mode: 2, delta: 1 / 60))
        let expected = game.ball - game.direction * (25 * 0.3048) + PGAVector(x: 0, y: 8 * 0.3048, z: 0)
        XCTAssertEqual(pose.position.x, expected.x, accuracy: 0.00001)
        XCTAssertEqual(pose.position.y, expected.y, accuracy: 0.00001)
        XCTAssertEqual(pose.position.z, expected.z, accuracy: 0.00001)
        XCTAssertEqual(pose.target.y, game.ball.y + 6 * 0.3048, accuracy: 0.00001)
        XCTAssertEqual(pose.fieldOfView, 45, accuracy: 0.00001)
    }

    func testSourceOperatorSevenMeansLacksAnyBit() {
        let condition = PGACameraDirector.Condition(bit: 0, operator_code: 7, value: 0b11)
        XCTAssertTrue(condition.matches([0b01]))
        XCTAssertFalse(condition.matches([0b11]))
        XCTAssertEqual(PGACameraDirector.fieldOfView(zoom: 1.5), 30, accuracy: 0.00001)
    }

    func testPreparedOriginalScriptsDriveAllFourModesWhenAvailable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard var director = PGACameraDirector(root: root) else {
            throw XCTSkip("Prepared original camera scripts are not available on this machine")
        }
        let game = PGASimulation()
        for mode in 0..<4 {
            let pose = try XCTUnwrap(director.update(game, mode: mode, delta: 1 / 60))
            XCTAssertTrue([pose.position.x, pose.position.y, pose.position.z, pose.target.x,
                           pose.target.y, pose.target.z, pose.fieldOfView].allSatisfy(\.isFinite))
            XCTAssertGreaterThan((pose.target - pose.position).length, 0.1)
        }
    }

    func testTeeImpactRuleMatchesAndNewAttachmentResetsZoom() throws {
        let json = """
        {"scripts":[{"file":"d_camera.stn",
          "situations":[
            {"situation_type":11,"event":28,"conditions":[],"actions":[0],"single_random_action":false,"priority":100},
            {"situation_type":11,"event":3,"conditions":[{"bit":2,"operator_code":5,"value":32768}],"actions":[1],"single_random_action":false,"priority":100}],
          "actions":[{"probability_percent":100,"responses":[0,1]},{"probability_percent":100,"responses":[2]}],
          "responses":[
            {"response_type":13,"command":0,"object_type":7,"offset_ft":[0,3,-13],"start_mode":1,"flags":6,"duration_s":0,"amount":0},
            {"response_type":13,"command":6,"object_type":0,"offset_ft":[0,0,0],"start_mode":2,"flags":0,"duration_s":0,"amount":175},
            {"response_type":13,"command":0,"object_type":2,"offset_ft":[0,0,0],"start_mode":1,"flags":6,"duration_s":0,"amount":0}
          ]}]}
        """
        var director = try XCTUnwrap(PGACameraDirector(data: Data(json.utf8)))
        var game = PGASimulation()
        let address = try XCTUnwrap(director.update(game, mode: 0, delta: 1 / 60))
        XCTAssertEqual(address.fieldOfView, 45 / 1.75, accuracy: 0.00001)
        game.strike(power: 1, accuracy: 0)
        let impact = try XCTUnwrap(director.update(game, mode: 0, delta: 1 / 60))
        XCTAssertEqual(impact.position.x, game.hole.cup.x, accuracy: 0.00001)
        XCTAssertEqual(impact.position.z, game.hole.cup.z, accuracy: 0.00001)
        XCTAssertEqual(impact.fieldOfView, 45, accuracy: 0.00001)
    }

    func testCyclingModeInFlightKeepsShotOrigin() throws {
        let json = """
        {"scripts":[
          {"file":"f_camera.stn","situations":[{"situation_type":11,"event":28,"conditions":[],"actions":[0],"single_random_action":false,"priority":100}],
           "actions":[{"probability_percent":100,"responses":[0]}],
           "responses":[{"response_type":13,"command":0,"object_type":7,"offset_ft":[0,0,0],"start_mode":1,"flags":6,"duration_s":0,"amount":0}]},
          {"file":"b_camera.stn","situations":[{"situation_type":11,"event":3,"conditions":[],"actions":[0],"single_random_action":false,"priority":100}],
           "actions":[{"probability_percent":100,"responses":[0]}],
           "responses":[{"response_type":13,"command":0,"object_type":7,"offset_ft":[0,0,0],"start_mode":1,"flags":6,"duration_s":0,"amount":0}]}
        ]}
        """
        var director = try XCTUnwrap(PGACameraDirector(data: Data(json.utf8)))
        var game = PGASimulation()
        let origin = game.ball
        _ = director.update(game, mode: 2, delta: 1 / 60)
        game.strike(power: 1, accuracy: 0)
        _ = director.update(game, mode: 2, delta: 1 / 60)
        game.update(deltaTime: 0.05)
        XCTAssertGreaterThan(game.ball.distance(to: origin), 0.01)
        let pose = try XCTUnwrap(director.update(game, mode: 3, delta: 1 / 60))
        XCTAssertEqual(pose.position.x, origin.x, accuracy: 0.00001)
        XCTAssertEqual(pose.position.z, origin.z, accuracy: 0.00001)
    }
}
