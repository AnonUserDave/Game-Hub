import AppKit
import SwiftUI

/// Original PGA Tour 2005 HUD images converted by Tools/import_pga2005_hud.py.
/// Images are small (about 1.4 MB as PNG) and loaded once per session.
@MainActor
final class PGAHUDImages {
    private let directory: URL
    private var cache: [String: NSImage] = [:]
    let available: Bool

    init(root: URL = GameStore.workspaceRoot()) {
        directory = root.appendingPathComponent("Library/Imported/pga2005/hud", isDirectory: true)
        available = FileManager.default.fileExists(atPath: directory.appendingPathComponent("hud.json").path)
    }

    func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard available, let image = NSImage(contentsOf: directory.appendingPathComponent("\(name).png")) else { return nil }
        cache[name] = image
        return image
    }

    /// Bag graphic for a club, highlighted when selected.
    func club(_ club: PGAClub, selected: Bool) -> NSImage? {
        let name = ["D1", "W3", "I5", "I7", "I9", "PW", "SW", "Putter"][club.rawValue]
        return image("club-\(name)\(selected ? "-on" : "")")
    }
}

/// The original circular three-click meter: the lit ring (swingon) fills
/// clockwise from 6 o'clock to 12 o'clock for 0-100% power over the dimmed
/// ring (swingoff); during the accuracy phase a marker returns through 6
/// o'clock, where a straight strike lands. The marker timing comes from the
/// native simulation; the original meter speed is not decoded.
struct PGAOriginalSwingMeter: View {
    let simulation: PGASimulation
    let images: PGAHUDImages

    private var power: Double {
        switch simulation.phase {
        case .power: return simulation.meter
        case .aiming: return 0
        default: return simulation.shotPower
        }
    }
    private var accuracy: Double? {
        switch simulation.phase {
        case .accuracy: return simulation.meter
        case .airborne, .rolling: return simulation.shotAccuracy
        default: return nil
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            ZStack {
                if let off = images.image("swing-off") { Image(nsImage: off).resizable().interpolation(.high) }
                if let on = images.image("swing-on"), power > 0 {
                    Image(nsImage: on).resizable().interpolation(.high)
                        .mask(PGAMeterWedge(fraction: power).fill(.white))
                }
                Canvas { context, canvas in
                    let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2), radius = canvas.width / 2
                    func ray(_ degrees: Double, _ inner: Double, _ outer: Double) -> Path {
                        let a = degrees * .pi / 180
                        var path = Path()
                        path.move(to: CGPoint(x: center.x + cos(a) * radius * inner, y: center.y + sin(a) * radius * inner))
                        path.addLine(to: CGPoint(x: center.x + cos(a) * radius * outer, y: center.y + sin(a) * radius * outer))
                        return path
                    }
                    if simulation.phase == .power {
                        context.stroke(ray(90 + 180 * power, 0.66, 0.97), with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    }
                    if let accuracy {
                        // -1 (early, left of 6 o'clock) through 0 (straight) to +1 (late).
                        context.stroke(ray(90 - 45 * accuracy, 0.62, 0.99), with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    }
                }
            }.frame(width: size, height: size).position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

/// Wedge from 6 o'clock clockwise by `fraction` of a half turn (y points down).
struct PGAMeterWedge: Shape {
    var fraction: Double
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY), radius = rect.width / 2 * 1.02
        var path = Path()
        path.move(to: center)
        let end = 90 + 180 * max(0, min(1, fraction))
        for degrees in stride(from: 90.0, through: end, by: 1.5) {
            let a = degrees * .pi / 180
            path.addLine(to: CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius))
        }
        let a = end * .pi / 180
        path.addLine(to: CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius))
        path.closeSubpath()
        return path
    }
}
