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

    private static let columns: [CGFloat] = [19, 182, 262, 295, 327, 359, 391, 423, 454, 487, 519, 551, 600, 649, 681, 718]
    private static let rows: [CGFloat] = [147, 169, 191, 213, 235, 257, 279, 301, 323, 345, 367, 389]

    var body: some View {
        let holes = simulation.course.holes
        let start = simulation.holeIndex >= 9 && holes.count > 9 ? 9 : 0
        let nine = Array(start..<min(start + 9, holes.count))
        // A player's score on a hole: recorded, or just holed on the current one.
        let score = { (player: Int, index: Int) -> Int? in
            let p = simulation.players[player]
            return index < p.scores.count ? p.scores[index] : (index == simulation.holeIndex && p.holed ? p.strokes : nil)
        }
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
                ForEach(Array(nine.enumerated()), id: \.offset) { offset, index in
                    let hole = holes[index]
                    cell(2 + offset, 0, "\(index + 1)", true)
                    cell(2 + offset, 1, hole.source?.scorecardYards.map { "\($0)" } ?? "", false)
                    cell(2 + offset, 2, "\(hole.par)", true)
                    cell(2 + offset, 3, hole.source.map { "\($0.handicap)" } ?? "", false)
                }
                cell(11, 1, "\(nine.compactMap { holes[$0].source?.scorecardYards }.reduce(0, +))", false)
                cell(11, 2, "\(nine.map { holes[$0].par }.reduce(0, +))", true)
                cell(12, 2, "\(holes.map(\.par).reduce(0, +))", true)
                // Player rows: the first player sits in the original red row.
                ForEach(simulation.players.indices, id: \.self) { player in
                    let row = 4 + player
                    let scored = holes.indices.compactMap { score(player, $0) }
                    let toPar = zip(holes.indices.compactMap { score(player, $0) }, holes.map(\.par)).reduce(0) { $0 + $1.0 - $1.1 }
                    let ninePlayed = nine.compactMap { score(player, $0) }
                    let marker = simulation.isMultiplayer && player == simulation.currentPlayer ? "▸ " : ""
                    cell(0, row, marker + simulation.players[player].name.uppercased(), true)
                    cell(1, row, scored.isEmpty ? "" : toPar == 0 ? "E" : toPar > 0 ? "+\(toPar)" : "\(toPar)", true)
                    ForEach(Array(nine.enumerated()), id: \.offset) { offset, index in
                        cell(2 + offset, row, score(player, index).map { "\($0)" } ?? "", true)
                    }
                    cell(11, row, ninePlayed.isEmpty ? "" : "\(ninePlayed.reduce(0, +))", true)
                    cell(12, row, scored.isEmpty ? "" : "\(scored.reduce(0, +))", true)
                }
            }
        }.aspectRatio(738.0 / 444.0, contentMode: .fit)
    }
}

/// Round setup over the original loading art: players, tee set and pins.
/// Original tee/pin selection screens are not decoded; these choices map
/// onto the authored TCR tees (index 3 matches the championship card) and pins.
struct PGARoundSetupView: View {
    @ObservedObject var session: PGAGameSession
    private let gold = Color(hex: "EDD297"), ink = Color(hex: "102223")

    var body: some View {
        ZStack {
            Color.black
            if let back = session.hud.image("load-back") {
                Image(nsImage: back).resizable().aspectRatio(contentMode: .fill).opacity(0.45).blur(radius: 2).clipped()
            }
            VStack(spacing: 18) {
                HStack(spacing: 16) {
                    if let logo = session.hud.image("logo-pebble") { Image(nsImage: logo).resizable().frame(width: 72, height: 72) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PEBBLE BEACH GOLF LINKS").font(.system(size: 22, weight: .bold)).tracking(1.5)
                        Text("Original course data · 18 holes · approximate native physics")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                }
                section("PLAYERS") {
                    VStack(spacing: 8) {
                        ForEach(session.setup.players.indices, id: \.self) { index in
                            HStack {
                                Text("\(index + 1)").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(gold).frame(width: 18)
                                TextField("Player \(index + 1)", text: Binding(get: { session.setup.players[index] },
                                                                                 set: { session.setup.players[index] = String($0.prefix(24)) }))
                                    .textFieldStyle(.roundedBorder)
                                if session.setup.players.count > 1 {
                                    Button { session.setup.players.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                                }
                            }
                        }
                        if session.setup.players.count < 4 {
                            Button { session.setup.players.append("Player \(session.setup.players.count + 1)") } label: {
                                Label("Add player (hot-seat, up to 4)", systemImage: "plus.circle")
                            }.buttonStyle(.plain).foregroundStyle(gold).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                section("TEES") {
                    HStack(spacing: 6) {
                        ForEach(0..<5, id: \.self) { index in
                            Button { session.setup.teeIndex = index } label: {
                                VStack(spacing: 3) {
                                    Text(PGARoundSetup.teeNames[index]).font(.system(size: 11, weight: .semibold))
                                    Text(session.teeYards(index).map { "\($0) yd" } ?? "").font(.system(size: 9, design: .monospaced)).opacity(0.75)
                                }.frame(maxWidth: .infinity).padding(.vertical, 8)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(session.setup.teeIndex == index ? gold : .white.opacity(0.08)))
                                    .foregroundStyle(session.setup.teeIndex == index ? ink : .white)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                section("PIN POSITIONS") {
                    HStack(spacing: 6) {
                        ForEach(PGARoundSetup.Pins.allCases, id: \.self) { pins in
                            Button { session.setup.pins = pins; if pins == .varied { session.setup.seed = UInt32.random(in: 1...999_999) } } label: {
                                Text(pins == .standard ? "Standard" : "Varied (10 authored pins per hole)").font(.system(size: 11, weight: .semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(session.setup.pins == pins ? gold : .white.opacity(0.08)))
                                    .foregroundStyle(session.setup.pins == pins ? ink : .white)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                HStack(spacing: 12) {
                    Button("Start round") { session.startRound() }
                        .buttonStyle(.borderedProminent).tint(gold).foregroundStyle(ink).keyboardShortcut(.defaultAction)
                        .disabled(!session.setup.valid)
                    if let saved = session.savedRound {
                        Button("Resume hole \(saved.snapshot.holeIndex + 1) · \(saved.setup.players.joined(separator: ", "))") { session.startRound(resume: true) }
                            .buttonStyle(.bordered)
                    }
                    Spacer()
                    Button("Return to hub") { session.exit() }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                }
                Text("Return: start · Controller: A start · Y resume · LB/RB tees · X pins · B hub")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            }
            .padding(26).frame(width: 640)
            .background(ink.opacity(0.94), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12)))
            .foregroundStyle(.white)
        }.ignoresSafeArea()
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.4).foregroundStyle(gold)
            content()
        }
    }
}
