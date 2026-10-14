import AppKit
import Combine
import CryptoKit
import ImageIO
import SwiftUI

/// Bounded original-media readers, shared pixel presentation and focused input.
/// These adapters never interpret the original CPU or machine registers.
enum RetroMediaError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

enum RetroOriginalMedia {
    static let applePath = "Library/Prepared/apple-panic/apple-panic.json"
    static let crossfirePath = "Library/Imported/crossfire/crossfire.json"
    static let nightPath = "Library/SourceMedia/retro/night-driver-c64/native-media.json"
    static let requiredIDs: Set<String> = ["apple-panic-native-development", "crossfire-native-development", "night-driver-native-development"]

    static func readiness(id: String, root: URL) -> String {
        do {
            switch id {
            case "apple-panic-native-development": _ = try ApplePanicPresentation.load(root: root)
            case "crossfire-native-development": _ = try CrossfirePresentation.load(root: root)
            case "night-driver-native-development": _ = try NightDriverPresentation.load(root: root)
            default: return ""
            }
            return ""
        } catch { return "Original media needs preparation" }
    }
    static func image(width: Int, height: Int, pixels: (Int, Int) -> Bool) throws -> CGImage {
        guard width > 0, height > 0, width <= 320, height <= 200 else { throw RetroMediaError.invalid("Invalid original image bounds") }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width where pixels(x, y) {
            let offset = (y * width + x) * 4
            data[offset] = 255; data[offset + 1] = 255; data[offset + 2] = 255; data[offset + 3] = 255
        } }
        return try rgbaImage(width: width, height: height, data: Data(data))
    }
    static func rgbaImage(width: Int, height: Int, data: Data) throws -> CGImage {
        guard width > 0, height > 0, width <= 320, height <= 200, data.count == width * height * 4,
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw RetroMediaError.invalid("Cannot prepare original pixels") }
        return image
    }
}

struct ApplePanicPresentation {
    let resources: ApplePanicResources
    let sprites: [String: CGImage]
    static func load(root: URL) throws -> Self {
        let resources = try ApplePanicResources.load(url: root.appendingPathComponent(RetroOriginalMedia.applePath))
        let names = ["digLeft0", "digRight0", "digLeft1", "digRight1", "walkRight0", "walkLeft0", "climb0", "walkRight1", "walkLeft1", "climb1"] +
            (0..<3).flatMap { kind in (0..<2).map { "enemy\(kind)Frame\($0)" } }
        guard Set(resources.sprites.keys) == Set(names) else { throw RetroMediaError.invalid("The selected Apple Panic sprite set is incomplete") }
        var sprites: [String: CGImage] = [:]
        for (name, sprite) in resources.sprites {
            sprites[name] = try RetroOriginalMedia.image(width: sprite.width, height: sprite.height) { x, y in sprite.rows[y] & (1 << x) != 0 }
        }
        return Self(resources: resources, sprites: sprites)
    }
}

struct CrossfirePresentation {
    struct Manifest: Decodable {
        struct Sprite: Decodable { let name, path, sha256: String; let width, height: Int }
        let schemaVersion: Int
        let sourceIdentity: String
        let sprites: [Sprite]
    }
    let sprites: [String: CGImage]
    static func load(root: URL) throws -> Self {
        let url = root.appendingPathComponent(RetroOriginalMedia.crossfirePath)
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 32 * 1024 else { throw RetroMediaError.invalid("Invalid Crossfire media index") }
        let metadata = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        let names = ["player", "ammo", "projectile", "bonus-idle"] + (0..<4).map { "enemy-\($0)" } + (0..<3).map { "explosion-\($0)" } + (0..<4).map { "bonus-\($0)" }
        guard metadata.schemaVersion == 1, metadata.sourceIdentity == CrossfireSimulation.sourceIdentity,
              metadata.sprites.count == names.count, Set(metadata.sprites.map(\.name)) == Set(names) else { throw RetroMediaError.invalid("The selected Crossfire sprite set is incomplete") }
        var sprites: [String: CGImage] = [:]
        for record in metadata.sprites {
            guard record.path == record.name + ".png", (1...28).contains(record.width), (1...16).contains(record.height) else { throw RetroMediaError.invalid("Invalid Crossfire sprite record") }
            let file = url.deletingLastPathComponent().appendingPathComponent(record.path)
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 16 * 1024 else { throw RetroMediaError.invalid("Missing Crossfire sprite") }
            let data = try Data(contentsOf: file)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == record.sha256,
                  let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  (props[kCGImagePropertyPixelWidth] as? Int) == record.width, (props[kCGImagePropertyPixelHeight] as? Int) == record.height,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { throw RetroMediaError.invalid("Crossfire sprite integrity check failed") }
            sprites[record.name] = image
        }
        return Self(sprites: sprites)
    }
}

struct NightDriverPresentation {
    let media: NightDriverMedia
    let coloredDigits: [Int: [CGImage]]
    /// Provisional display palette; source color indices are retained separately.
    static let palette: [UInt32] = [0x000000, 0xFFFFFF, 0x883932, 0x67B6BD, 0x8B3F96, 0x55A049, 0x40318D, 0xBFCE72,
                                    0x8B5429, 0x574200, 0xB86962, 0x505050, 0x787878, 0x94E089, 0x7869C4, 0x9F9F9F]
    static func load(root: URL) throws -> Self {
        let media = try NightDriverMedia.load(from: root.appendingPathComponent(RetroOriginalMedia.nightPath))
        var digits: [Int: [CGImage]] = [:]
        for color in [2, 3, 7] {
            digits[color] = try media.graphics.digitSprites.map { bytes in
                var pixels = [UInt8](repeating: 0, count: 24 * 21 * 4)
                for y in 0..<21 { for x in 0..<24 where bytes[y * 3 + x / 8] & (128 >> (x % 8)) != 0 {
                    putPixel(&pixels, offset: (y * 24 + x) * 4, color: palette[color])
                } }
                return try RetroOriginalMedia.rgbaImage(width: 24, height: 21, data: Data(pixels))
            }
        }
        return Self(media: media, coloredDigits: digits)
    }
    /// A single320x200 raster avoids per-character clipping/interpolation seams.
    /// Temporary storage is256KB, independent of Retina window dimensions.
    func screenImage(cells: [NightDriverCell]) throws -> CGImage {
        guard cells.count <= 1000 else { throw RetroMediaError.invalid("Invalid Night Driver screen") }
        var pixels = [UInt8](repeating: 0, count: 320 * 200 * 4)
        for cell in cells {
            guard (0..<40).contains(cell.column), (0..<25).contains(cell.row), (0..<256).contains(cell.character), (0..<16).contains(cell.color) else { throw RetroMediaError.invalid("Invalid Night Driver cell") }
            let rows = media.graphics.characterRows[cell.character]
            for y in 0..<8 { for x in 0..<8 where rows[y] & (128 >> x) != 0 {
                let offset = ((cell.row * 8 + y) * 320 + cell.column * 8 + x) * 4
                Self.putPixel(&pixels, offset: offset, color: Self.palette[cell.color])
            } }
        }
        return try RetroOriginalMedia.rgbaImage(width: 320, height: 200, data: Data(pixels))
    }
    private static func putPixel(_ pixels: inout [UInt8], offset: Int, color: UInt32) {
        pixels[offset] = UInt8((color >> 16) & 255); pixels[offset + 1] = UInt8((color >> 8) & 255)
        pixels[offset + 2] = UInt8(color & 255); pixels[offset + 3] = 255
    }
}

/// A finite main-thread display timer. Source schedules live in each session;
/// elapsed time is discarded at focus/pause/setup boundaries, never caught up.
@MainActor
final class RetroSessionDriver {
    struct Frame {
        var delta: Double
        var pressed: Set<String>
        var held: Set<String>
        var axes: [Float]
    }
    var keys = Set<UInt16>()
    private(set) var pendingKeys: [UInt16] = []
    private var latch = RetroControllerLatch()
    private var blockedAxes = Set<Int>()
    private var previousIdentity = ""
    private var previousConnected = false
    private var previousFocused = false
    private var lastTime: Double?
    private var timer: Timer?
    private weak var window: NSWindow?
    var focused: Bool { NSApp.isActive && window?.isKeyWindow == true }
    var running: Bool { timer != nil }
    deinit { timer?.invalidate() }
    func attach(_ window: NSWindow?, frame: @escaping (Double) -> Void) {
        self.window = window
        guard window != nil, timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            MainActor.assumeIsolated { frame(ProcessInfo.processInfo.systemUptime) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil; window = nil; reset() }
    func reset() { keys.removeAll(); pendingKeys.removeAll(); lastTime = nil }
    func block(_ sample: NativeGamepadSample) {
        reset(); latch.blockActions(sample)
        for i in 0..<min(4, sample.axes.count) where abs(sample.axes[i]) > 0.2 { blockedAxes.insert(i) }
    }
    func key(_ code: UInt16, down: Bool, queue: Bool = false) {
        if down {
            keys.insert(code)
            if queue && pendingKeys.count < 8 { pendingKeys.append(code) }
        } else { keys.remove(code) }
    }
    func takeKey() -> UInt16? { pendingKeys.isEmpty ? nil : pendingKeys.removeFirst() }
    func frame(now: Double, focused: Bool, enabled: Bool, sample: NativeGamepadSample, identity: String) -> Frame {
        let input = latch.sample(sample, identity: identity, focused: focused, actionsEnabled: enabled)
        let delta = focused && previousFocused && enabled ? max(0, min(0.1, now - (lastTime ?? now))) : 0
        lastTime = now
        let changed = identity != previousIdentity || sample.connected != previousConnected
        var axes = Array(sample.axes.prefix(4)); axes += Array(repeating: 0, count: 4 - axes.count)
        for i in 0..<4 {
            if changed || !focused || !enabled { if abs(axes[i]) > 0.2 { blockedAxes.insert(i) } }
            if abs(axes[i]) <= 0.2 { blockedAxes.remove(i) }
            if blockedAxes.contains(i) || !enabled || !focused { axes[i] = 0 }
        }
        previousIdentity = identity; previousConnected = sample.connected; previousFocused = focused
        if !focused || !enabled { keys.removeAll(); pendingKeys.removeAll() }
        return Frame(delta: delta, pressed: input.pressed, held: input.held, axes: axes)
    }
}

struct RetroPixelCanvas: View {
    let width: Double
    let height: Double
    let draw: (inout GraphicsContext) -> Void
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / width, geometry.size.height / height)
            Canvas { context, _ in context.scaleBy(x: scale, y: scale); draw(&context) }
                .frame(width: width * scale, height: height * scale).background(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

func retroSprite(_ image: CGImage?, x: Int, y: Int, context: inout GraphicsContext, xor: Bool = false) {
    guard let image else { return }
    let previousBlend = context.blendMode
    if xor { context.blendMode = .difference }
    defer { context.blendMode = previousBlend }
    context.withCGContext { cg in
        cg.saveGState(); defer { cg.restoreGState() }
        cg.interpolationQuality = .none
        cg.translateBy(x: CGFloat(x), y: CGFloat(y + image.height)); cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
}

struct RetroLoadingPanel: View {
    let message: String
    let loading: Bool
    let reload: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            if loading { ProgressView() }
            Text(loading ? "Loading original media…" : "Original media unavailable").font(.title2)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 540)
            if !loading { Button("Reload media", action: reload) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
