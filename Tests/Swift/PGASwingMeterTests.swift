import XCTest
@testable import GameHub

/// The Swift tri-click meter must match the Python reference frame for frame
/// (Tests/Fixtures/pga2005-meter.json from Tools/make_pga2005_meter_fixture.py).
final class PGASwingMeterTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            var name: String; var level: Int; var putter: Bool; var two_click: Bool
            var power_click_ms: Int?; var accuracy_click_ms: Int?
            var jitter: Int; var dt: Int; var power: Double; var direction: Double
            var missed_power: Bool; var missed_direction: Bool; var finished_ms: Int
            var trace: [[Double]]
        }
        var cases: [Case]
    }

    func testMatchesReferenceMeter() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pga2005-meter.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.cases.count, 8)
        for test in fixture.cases {
            var meter = PGATriClickMeter(level: try XCTUnwrap(PGATriClickMeter.Level(rawValue: test.level)), putter: test.putter,
                                         twoClick: test.two_click, missJitter: test.jitter)
            var t = 0, frame = 0
            while !meter.finished && t < 10000 {
                if let ms = test.power_click_ms {
                    if ms >= 0 && t >= ms && meter.state == 2 { meter.click() }
                } else if meter.state == 2 && meter.angle <= 91 { meter.click() }
                if let ms = test.accuracy_click_ms {
                    if ms >= 0 && t >= ms && meter.state == 4 { meter.click() }
                } else if meter.state == 4 && meter.angle >= 269 { meter.click() }
                meter.step(milliseconds: test.dt)
                t += test.dt
                let expected = test.trace[frame]
                XCTAssertEqual(meter.angle, expected[1], accuracy: 0.001, "\(test.name) angle at \(t) ms")
                XCTAssertEqual(meter.state, Int(expected[2]), "\(test.name) state at \(t) ms")
                frame += 1
            }
            XCTAssertEqual(t, test.finished_ms, test.name)
            XCTAssertEqual(meter.power, test.power, accuracy: 1e-9, test.name)
            XCTAssertEqual(meter.directionPercent, test.direction, accuracy: 1e-9, test.name)
            XCTAssertEqual(meter.missedPower, test.missed_power, test.name)
            XCTAssertEqual(meter.missedDirection, test.missed_direction, test.name)
        }
    }

    func testOverswingIsCompressedAndExactClicksSnap() {
        var meter = PGATriClickMeter(level: .intermediate, putter: false)
        while !(meter.state == 2 && meter.angle <= 92) { meter.step(milliseconds: 1) }
        meter.click()
        XCTAssertEqual(meter.powerTick, .exact)
        XCTAssertEqual(meter.power, 1, accuracy: 1e-12)
        var over = PGATriClickMeter(level: .expert, putter: false)
        while !(over.state == 2 && over.angle <= 50) { over.step(milliseconds: 1) }
        over.click()
        XCTAssertEqual(over.powerTick, .over)
        XCTAssertLessThanOrEqual(over.power, 1.047 + 1e-9)
        XCTAssertGreaterThan(over.power, 1.04)
    }
}
