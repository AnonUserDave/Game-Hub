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

    /// Course-folder image converted by the original importer (e.g. FLAG).
    func courseImage(_ name: String, course: String = "PBL") -> NSImage? {
        let key = "course-\(course)-\(name)"
        if let cached = cache[key] { return cached }
        let url = directory.deletingLastPathComponent().appendingPathComponent("\(course)/\(name).png")
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache[key] = image
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
                        context.stroke(ray(90 + 180 * power, 0.56, 0.86), with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    }
                    if let accuracy {
                        // -1 (early, left of 6 o'clock) through 0 (straight) to +1 (late).
                        context.stroke(ray(90 - 45 * accuracy, 0.54, 0.9), with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
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

/// Original loading art (4:3) with an indeterminate fill sliding inside the
/// chrome slot drawn in the image (slot measured at x 354-668, y 357-410).
struct PGAOriginalLoadingScreen: View {
    let images: PGAHUDImages
    let message: String
    var body: some View {
        ZStack {
            Color.black
            if let back = images.image("load-back") {
                Image(nsImage: back).resizable().interpolation(.high).aspectRatio(1024.0 / 768.0, contentMode: .fit)
                    .overlay {
                        GeometryReader { geometry in
                            let sx = geometry.size.width / 1024, sy = geometry.size.height / 768
                            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                                let t = context.date.timeIntervalSinceReferenceDate
                                let phase = (sin(t * 2.2) + 1) / 2
                                let inner = CGRect(x: 366 * sx, y: 368 * sy, width: 290 * sx, height: 31 * sy)
                                Capsule().fill(LinearGradient(colors: [Color(hex: "F6E6A2"), Color(hex: "D9A93A")], startPoint: .top, endPoint: .bottom))
                                    .frame(width: inner.width * 0.32, height: inner.height)
                                    .position(x: inner.minX + inner.width * (0.16 + 0.68 * phase), y: inner.midY)
                                    .opacity(0.9)
                            }
                        }
                    }
            }
            VStack { Spacer(); Text(message).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8)).padding(.bottom, 28) }
        }.ignoresSafeArea()
    }
}

/// Original scorecard art with values placed in its measured grid
/// (738 x 444 image; columns and rows measured from the drawn lines).
struct PGAOriginalScorecard: View {
    let images: PGAHUDImages
    let simulation: PGASimulation
    let playerName: String

    private static let columns: [CGFloat] = [19, 182, 262, 295, 327, 359, 391, 423, 454, 487, 519, 551, 600, 649, 681, 718]
    private static let rows: [CGFloat] = [147, 169, 191, 213, 235, 257, 279, 301, 323, 345, 367, 389]

    var body: some View {
        let holes = simulation.course.holes
        let start = simulation.holeIndex >= 9 && holes.count > 9 ? 9 : 0
        let nine = Array(start..<min(start + 9, holes.count))
        let score = { (index: Int) -> Int? in
            index < simulation.scores.count ? simulation.scores[index] : (index == simulation.holeIndex && simulation.phase == .holed ? simulation.strokes : nil)
        }
        let played = nine.compactMap(score)
        let total = holes.indices.compactMap(score).reduce(0, +)
        let toPar = zip(holes.indices.compactMap(score), holes.map(\.par)).reduce(0) { $0 + $1.0 - $1.1 }
        ZStack {
            if let card = images.image("scorecard") { Image(nsImage: card).resizable().interpolation(.high) }
            GeometryReader { geometry in
                let sx = geometry.size.width / 738, sy = geometry.size.height / 444
                let cell = { (column: Int, row: Int, text: String, bold: Bool) -> AnyView in
                    let x = (Self.columns[column] + Self.columns[column + 1]) / 2 * sx, y = (Self.rows[row] + Self.rows[row + 1]) / 2 * sy
                    return AnyView(Text(text).font(.system(size: 11 * sy, weight: bold ? .bold : .medium, design: .monospaced))
                        .foregroundStyle(.white).position(x: x, y: y))
                }
                Text(simulation.course.name.uppercased()).font(.system(size: 18 * sy, weight: .bold)).tracking(1.5)
                    .foregroundStyle(.white).position(x: 369 * sx, y: 78 * sy)
                Text(start == 0 ? "FRONT NINE" : "BACK NINE").font(.system(size: 11 * sy, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7)).position(x: 369 * sx, y: 112 * sy)
                cell(0, 0, "HOLE", true); cell(11, 0, start == 0 ? "OUT" : "IN", true); cell(12, 0, "TOT", true)
                cell(0, 1, "YARDS", false); cell(0, 2, "PAR", true); cell(0, 3, "HCP", false)
                cell(0, 4, playerName.uppercased(), true); cell(1, 4, toPar == 0 ? "E" : toPar > 0 ? "+\(toPar)" : "\(toPar)", true)
                ForEach(Array(nine.enumerated()), id: \.offset) { offset, index in
                    let hole = holes[index]
                    cell(2 + offset, 0, "\(index + 1)", true)
                    cell(2 + offset, 1, hole.source?.scorecardYards.map { "\($0)" } ?? "", false)
                    cell(2 + offset, 2, "\(hole.par)", true)
                    cell(2 + offset, 3, hole.source.map { "\($0.handicap)" } ?? "", false)
                    cell(2 + offset, 4, score(index).map { "\($0)" } ?? "", true)
                }
                cell(11, 1, "\(nine.compactMap { holes[$0].source?.scorecardYards }.reduce(0, +))", false)
                cell(11, 2, "\(nine.map { holes[$0].par }.reduce(0, +))", true)
                cell(11, 4, played.isEmpty ? "" : "\(played.reduce(0, +))", true)
                cell(12, 2, "\(holes.map(\.par).reduce(0, +))", true)
                cell(12, 4, total == 0 ? "" : "\(total)", true)
            }
        }.aspectRatio(738.0 / 444.0, contentMode: .fit)
    }
}
