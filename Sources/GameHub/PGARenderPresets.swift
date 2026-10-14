import Foundation
import simd

/// The original weather × time-of-day render presets (Executable/render1–40.ini),
/// decoded to numbers by Tools/decode_pga2005_render.py. Selection and blending
/// follow docs/research/PGA2005-WEATHER-TIME.md and PGA2005-RENDER-PRESETS.md:
/// eight weather rows of five time slots, time advancing 20 units per hole
/// with 180 units between neighbouring slots, and CGlobalRenderSettings::Lerp
/// interpolating colours, fog, contrast and flare values while the sky type,
/// flare switch and rain come from the lower preset.
struct PGARenderState: Equatable {
    struct Flare: Equatable {
        /// Sun position in source units before the skydome transform.
        var position: SIMD3<Double>
        var sunSize: Double
        var sunOpacity: Double
        var coronaOpacity: Double
        var flareOpacity: Double
        /// (size, position along the sun–centre line, texture index).
        var flares: [(size: Double, position: Double, texture: Int)]
        var coronas: [(size: Double, texture: Int)]
        static func == (a: Flare, b: Flare) -> Bool {
            a.position == b.position && a.sunSize == b.sunSize && a.sunOpacity == b.sunOpacity && a.coronaOpacity == b.coronaOpacity
                && a.flareOpacity == b.flareOpacity && a.flares.count == b.flares.count && a.coronas.count == b.coronas.count
        }
    }
    struct Rain: Equatable {
        var density: Double
        var distance: Double
        var dropLength: Double
        var dropVelocity: Double
        var color: SIMD3<Float>
    }

    var lower: Int
    var upper: Int
    var blend: Double
    var skyType: Int
    var diffuse: SIMD3<Float>
    var skydomeDiffuse: SIMD3<Float>
    /// (MidValue, Scale, Shift).
    var terrainContrast: SIMD3<Float>
    var treeContrast: SIMD3<Float>
    var treeAmbient: Int
    /// Linear fog in source inches and its colour.
    var fogStart: Double
    var fogEnd: Double
    var fogColor: SIMD3<Float>
    var flare: Flare?
    var rain: Rain?

    /// The engine's contrast switch lives outside Lerp; following the research's
    /// recommendation it is on whenever the blended Scale differs from 1.
    var terrainContrastEnabled: Bool { abs(terrainContrast.y - 1) > 1e-4 }

    /// Terrain vertex lighting (0x101e710a): per channel of the baked byte x/255,
    /// clamp((x − Mid)·Scale + Shift, 0, 1) when contrast is on, times Diffuse.
    func terrainLight(_ value: SIMD3<Float>) -> SIMD3<Float> { Self.terrainLight(value, diffuse: diffuse, contrast: terrainContrast) }

    static func terrainLight(_ value: SIMD3<Float>, diffuse: SIMD3<Float>, contrast: SIMD3<Float>) -> SIMD3<Float> {
        var x = value
        if abs(contrast.y - 1) > 1e-4 {
            x = simd_clamp((x - SIMD3(repeating: contrast.x)) * contrast.y + SIMD3(repeating: contrast.z), SIMD3(repeating: 0), SIMD3(repeating: 1))
        }
        return (x * diffuse * 255).rounded(.towardZero) / 255
    }
}

final class PGARenderPresets: @unchecked Sendable {
    static let weatherNames = ["Clear", "Fair", "Partly cloudy", "Cloudy", "Foggy", "Overcast", "Light rain", "Heavy rain"]
    static let timeNames = ["Sunrise", "Morning", "Noon", "Afternoon", "Sunset"]

    private struct File: Decodable {
        struct Preset: Decodable {
            struct Settings: Decodable {
                struct Lighting: Decodable { var diffuse: [Double]; var skydome_diffuse: [Double] }
                struct Contrast: Decodable { var mid: Double; var shift: Double; var scale: Double }
                struct Fog: Decodable { var start: Double; var end: Double; var color: [Double] }
                struct Flare: Decodable {
                    struct Item: Decodable { var size: Double; var position: Double; var texture: Int }
                    struct Corona: Decodable { var size: Double; var texture: Int }
                    var enabled: Int; var position: [Double]?
                    var flare_opacity: Double; var sun_opacity: Double; var corona_opacity: Double; var sun_size: Double
                    var flares: [Item]?; var coronas: [Corona]?
                }
                struct Rain: Decodable { var on: Int; var density: Double?; var distance: Double?; var drop_length: Double?; var drop_velocity: Double?; var color: [Double]? }
                var sky_type: Int
                var tree_ambient: Double
                var global_lighting: Lighting
                var terrain_contrast: Contrast
                var tree_contrast: Contrast
                var fog: Fog
                var lens_flare: Flare
                var rain: Rain
            }
            var number: Int
            var settings: Settings
        }
        var schema_version: Int
        var default_sun_position: [Double]?
        var presets: [Preset]
    }

    private let presets: [Int: File.Preset.Settings]
    private let defaultSun: SIMD3<Double>

    init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.schema_version == 1, file.presets.count == 40 else { throw PGAOriginalCourseData.LoadError.invalid("Unexpected render presets.") }
        presets = Dictionary(uniqueKeysWithValues: file.presets.map { ($0.number, $0.settings) })
        let sun = file.default_sun_position ?? [74831.2265625, 18868.849609375, 156948.265625]
        defaultSun = SIMD3(sun[0], sun[1], sun[2])
    }

    static func load(root: URL) -> PGARenderPresets? {
        let url = root.appendingPathComponent("Library/Imported/pga2005/render/presets.json")
        guard let data = try? Data(contentsOf: url), data.count < 4_000_000 else { return nil }
        return try? PGARenderPresets(data: data)
    }

    /// RenderCommand::AdjustTimeOfDay for setting bytes weather 0–7 and time 0–4.
    static func selection(weather: Int, time: Int, hole: Int) -> (lower: Int, upper: Int, blend: Double) {
        let row = min(7, Int(Double(max(0, min(7, weather))) / 7 * 8))
        let position = (Double(max(0, min(4, time))) / 4 * 720 + 20 * Double(max(1, hole) - 1)) / 180
        let slot = Int(position)
        return (row * 5 + min(slot, 4) + 1, row * 5 + min(slot + 1, 4) + 1, position - Double(slot))
    }

    func state(weather: Int, time: Int, hole: Int) -> PGARenderState {
        let pick = Self.selection(weather: weather, time: time, hole: hole)
        let a = presets[pick.lower]!, b = presets[pick.upper]!, t = pick.blend
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        func rgb(_ x: [Double], _ y: [Double]) -> SIMD3<Float> { SIMD3(Float(mix(x[0], y[0])), Float(mix(x[1], y[1])), Float(mix(x[2], y[2]))) }
        func contrast(_ x: File.Preset.Settings.Contrast, _ y: File.Preset.Settings.Contrast) -> SIMD3<Float> {
            SIMD3(Float(mix(x.mid, y.mid)), Float(mix(x.scale, y.scale)), Float(mix(x.shift, y.shift)))
        }
        var flare: PGARenderState.Flare?
        if a.lens_flare.enabled != 0 {
            let pa = a.lens_flare.position.map { SIMD3($0[0], $0[1], $0[2]) } ?? defaultSun
            let pb = b.lens_flare.position.map { SIMD3($0[0], $0[1], $0[2]) } ?? pa
            let items = a.lens_flare.flares ?? [], upperItems = b.lens_flare.flares ?? []
            flare = .init(position: pa + (pb - pa) * t,
                          sunSize: mix(a.lens_flare.sun_size, b.lens_flare.sun_size),
                          sunOpacity: mix(a.lens_flare.sun_opacity, b.lens_flare.sun_opacity),
                          coronaOpacity: mix(a.lens_flare.corona_opacity, b.lens_flare.corona_opacity),
                          flareOpacity: mix(a.lens_flare.flare_opacity, b.lens_flare.flare_opacity),
                          // Counts, sizes and textures from the lower preset; positions blend
                          // (slots past the upper count are held instead of the original's drift).
                          flares: items.enumerated().map { index, item in
                              (item.size, index < upperItems.count ? mix(item.position, upperItems[index].position) : item.position, item.texture)
                          },
                          coronas: (a.lens_flare.coronas ?? []).map { ($0.size, $0.texture) })
        }
        var rain: PGARenderState.Rain?
        if a.rain.on != 0 {
            let color = a.rain.color ?? [0.75, 0.75, 0.75]
            rain = .init(density: a.rain.density ?? 0.35, distance: a.rain.distance ?? 500, dropLength: a.rain.drop_length ?? 15,
                         dropVelocity: a.rain.drop_velocity ?? 170, color: SIMD3(Float(color[0]), Float(color[1]), Float(color[2])))
        }
        return PGARenderState(lower: pick.lower, upper: pick.upper, blend: t, skyType: a.sky_type,
                              diffuse: rgb(a.global_lighting.diffuse, b.global_lighting.diffuse),
                              skydomeDiffuse: rgb(a.global_lighting.skydome_diffuse, b.global_lighting.skydome_diffuse),
                              terrainContrast: contrast(a.terrain_contrast, b.terrain_contrast),
                              treeContrast: contrast(a.tree_contrast, b.tree_contrast),
                              treeAmbient: Int(mix(a.tree_ambient, b.tree_ambient)),
                              fogStart: mix(a.fog.start, b.fog.start), fogEnd: mix(a.fog.end, b.fog.end),
                              fogColor: rgb(a.fog.color, b.fog.color), flare: flare, rain: rain)
    }
}
