import XCTest
@testable import GameHub

final class PGARenderPresetsTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    func testSelectorFollowsAdjustTimeOfDay() {
        // PGA2005-WEATHER-TIME.md examples.
        XCTAssertTrue(PGARenderPresets.selection(weather: 0, time: 0, hole: 1) == (1, 2, 0))
        let hole5 = PGARenderPresets.selection(weather: 0, time: 0, hole: 5)
        XCTAssertEqual(hole5.lower, 1); XCTAssertEqual(hole5.upper, 2); XCTAssertEqual(hole5.blend, 0.4444, accuracy: 1e-4)
        XCTAssertTrue(PGARenderPresets.selection(weather: 0, time: 2, hole: 1) == (3, 4, 0))
        let late = PGARenderPresets.selection(weather: 7, time: 2, hole: 18)
        XCTAssertEqual(late.lower, 39); XCTAssertEqual(late.upper, 40); XCTAssertEqual(late.blend, 0.8889, accuracy: 1e-4)
        let clamped = PGARenderPresets.selection(weather: 0, time: 4, hole: 18)
        XCTAssertEqual(clamped.lower, 5); XCTAssertEqual(clamped.upper, 5, "the last slot clamps")
    }

    func testTerrainLightingFormula() {
        let contrast = SIMD3<Float>(1, 0.5, 1)  // Mid 1, Scale 0.5, Shift 1: lifts dark baked light.
        let lit = PGARenderState.terrainLight(SIMD3(0.4, 0.4, 0.4), diffuse: SIMD3(0.7, 0.7, 0.9), contrast: contrast)
        XCTAssertEqual(lit.x, Float(Int(0.7 * 0.7 * 255)) / 255, accuracy: 1e-6)
        XCTAssertEqual(lit.z, Float(Int(0.7 * 0.9 * 255)) / 255, accuracy: 1e-6)
        XCTAssertEqual(PGARenderState.terrainLight(SIMD3(0.4, 0.5, 0.6), diffuse: SIMD3(1, 1, 1), contrast: SIMD3(1, 1, 1)),
                       SIMD3(Float(Int(0.4 * 255)) / 255, Float(Int(0.5 * 255)) / 255, Float(Int(0.6 * 255)) / 255), "neutral at Scale 1")
    }

    func testPreparedPresetsBlend() throws {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/Imported/pga2005/render/presets.json").path) else {
            throw XCTSkip("Render presets not prepared")
        }
        let presets = try PGARenderPresets(data: Data(contentsOf: root.appendingPathComponent("Library/Imported/pga2005/render/presets.json")))
        let noon = presets.state(weather: 0, time: 2, hole: 1)
        XCTAssertEqual(noon.skyType, 1); XCTAssertEqual(noon.fogStart, 5000); XCTAssertEqual(noon.fogEnd, 150_000)
        XCTAssertFalse(noon.terrainContrastEnabled); XCTAssertNotNil(noon.flare); XCTAssertNil(noon.rain)
        let fog = presets.state(weather: 4, time: 2, hole: 1)
        XCTAssertEqual(fog.skyType, 5); XCTAssertNil(fog.flare); XCTAssertLessThan(fog.fogEnd, 110_000)
        let rain = presets.state(weather: 7, time: 3, hole: 1)
        XCTAssertEqual(rain.skyType, 6); XCTAssertNotNil(rain.rain)
        // Hole 10 at noon is halfway to afternoon: fog colour blends toward render4's.
        let later = presets.state(weather: 0, time: 2, hole: 10)
        XCTAssertEqual(later.lower, 4); XCTAssertEqual(later.upper, 5)
    }
}
