import SwiftUI

/// The physical form a game came on, chosen from its original platform. The
/// shelf draws each game as that object, so the system reads at a glance.
enum MediaKind: Equatable {
    case cartridge2600, cartridge7800, cartridge8Bit, cartridgeC64, cartridgeIntellivision, floppy, disc, cabinet, app

    init(platform: String) {
        let name = platform.lowercased()
        if name.contains("2600") { self = .cartridge2600 }
        else if name.contains("7800") { self = .cartridge7800 }
        else if name.contains("atari") { self = .cartridge8Bit }
        else if name.contains("commodore") { self = .cartridgeC64 }
        else if name.contains("intellivision") { self = .cartridgeIntellivision }
        else if name.contains("apple ii") { self = .floppy }
        else if name.contains("windows") { self = .disc }
        else if name.contains("arcade") { self = .cabinet }
        else { self = .app }
    }

    /// Width divided by height of the drawn object.
    var aspect: CGFloat {
        switch self {
        case .cartridge2600: return 0.8
        case .cartridge7800: return 0.82
        case .cartridge8Bit: return 0.92
        case .cartridgeC64: return 1.32
        case .cartridgeIntellivision: return 0.58
        case .floppy, .app: return 1
        case .disc: return 1.28
        case .cabinet: return 0.56
        }
    }

    var noun: String {
        switch self {
        case .cartridge2600, .cartridge7800, .cartridge8Bit, .cartridgeC64, .cartridgeIntellivision: return "cartridge"
        case .floppy: return "floppy disk"
        case .disc: return "disc"
        case .cabinet: return "arcade cabinet"
        case .app: return "Mac app"
        }
    }

    /// The largest object rect that fits `size`, resting on its bottom edge.
    func fit(in size: CGSize) -> CGRect {
        let width = min(size.width, size.height * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: size.height - height, width: width, height: height)
    }
}

/// Code-drawn media object for a game. It is never presented as original box
/// art or a screenshot. Resolution independent, so it stays sharp at 2×.
struct MediaObject: View {
    let game: GameManifest
    var body: some View {
        let kind = MediaKind(platform: game.platform)
        Canvas { context, size in
            MediaPainter(context: context, r: kind.fit(in: size), game: game).draw(kind)
        }
        .accessibilityHidden(true)
    }
}

private struct MediaPainter {
    var context: GraphicsContext
    let r: CGRect
    let game: GameManifest
    private var tint: Color { game.tint }
    private var w: CGFloat { r.width }
    private var h: CGFloat { r.height }
    private static let paper = Color(hex: "EFE6D4")
    private static let ink = Color(hex: "1A1412")

    init(context: GraphicsContext, r: CGRect, game: GameManifest) {
        self.context = context; self.r = r; self.game = game
    }

    func draw(_ kind: MediaKind) {
        guard w > 4, h > 4 else { return }
        switch kind {
        case .cartridge2600: cartridge2600()
        case .cartridge7800: cartridge7800()
        case .cartridge8Bit: cartridge8Bit()
        case .cartridgeC64: cartridgeC64()
        case .cartridgeIntellivision: cartridgeIntellivision()
        case .floppy: floppy()
        case .disc: disc()
        case .cabinet: cabinet()
        case .app: appTile()
        }
    }

    // MARK: Objects

    private func cartridge2600() {
        let body = Path(roundedRect: r, cornerRadius: w * 0.06, style: .continuous)
        plastic(body, top: "2C292B", bottom: "121013")
        for i in 0..<6 {
            let y = r.minY + h * (0.04 + CGFloat(i) * 0.031)
            line(from: CGPoint(x: r.minX + w * 0.07, y: y), to: CGPoint(x: r.maxX - w * 0.07, y: y), color: .white.opacity(0.08), width: max(1, h * 0.007))
        }
        let label = rect(0.09, 0.26, 0.82, 0.67)
        context.fill(Path(roundedRect: label.insetBy(dx: -w * 0.018, dy: -w * 0.018), cornerRadius: 2), with: .color(Self.paper.opacity(0.9)))
        art(in: CGRect(x: label.minX, y: label.minY, width: label.width, height: label.height * 0.72))
        let band = CGRect(x: label.minX, y: label.minY + label.height * 0.72, width: label.width, height: label.height * 0.28)
        context.fill(Path(band), with: .color(Color(hex: "0E0C0D")))
        title(in: band.insetBy(dx: band.width * 0.07, dy: band.height * 0.16), color: tint)
        rim(body)
    }

    private func cartridge7800() {
        var body = Path()
        let shoulder = r.minY + h * 0.11, radius = w * 0.05
        body.move(to: CGPoint(x: r.minX, y: shoulder))
        body.addQuadCurve(to: CGPoint(x: r.maxX, y: shoulder), control: CGPoint(x: r.midX, y: r.minY - h * 0.08))
        body.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        body.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        body.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        body.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
        body.closeSubpath()
        plastic(body, top: "45444A", bottom: "1D1C20")
        for i in 0..<7 {
            let x = r.midX + (CGFloat(i) - 3) * w * 0.07
            line(from: CGPoint(x: x, y: r.minY + h * 0.06), to: CGPoint(x: x, y: r.minY + h * 0.17), color: .black.opacity(0.35), width: max(1, w * 0.014))
        }
        let label = rect(0.1, 0.24, 0.8, 0.7)
        context.fill(Path(roundedRect: label, cornerRadius: 2), with: .color(Self.paper))
        let window = CGRect(x: label.minX + label.width * 0.07, y: label.minY + label.width * 0.07, width: label.width * 0.86, height: label.height * 0.62)
        art(in: window)
        title(in: CGRect(x: window.minX, y: window.maxY + label.height * 0.05, width: window.width, height: label.maxY - window.maxY - label.height * 0.1), color: Self.ink)
        rim(body)
    }

    private func cartridge8Bit() {
        let body = Path(roundedRect: r, cornerRadius: w * 0.05, style: .continuous)
        plastic(body, top: "3E3631", bottom: "211C18")
        let connector = rect(0, 0.84, 1, 0.16)
        context.fill(Path(roundedRect: connector, cornerRadius: w * 0.05, style: .continuous), with: .color(.black.opacity(0.35)))
        line(from: CGPoint(x: r.minX + w * 0.04, y: connector.minY), to: CGPoint(x: r.maxX - w * 0.04, y: connector.minY), color: .white.opacity(0.08), width: 1)
        let label = rect(0.1, 0.08, 0.8, 0.66)
        art(in: label)
        title(in: CGRect(x: label.minX + label.width * 0.08, y: label.minY + label.height * 0.06, width: label.width * 0.84, height: label.height * 0.24), color: Self.paper, shadow: true)
        rim(body)
    }

    private func cartridgeC64() {
        let body = Path(roundedRect: r, cornerRadius: w * 0.035, style: .continuous)
        plastic(body, top: "34302D", bottom: "171514")
        for i in 0..<4 {
            for x in [0.04 + CGFloat(i) * 0.022, 0.894 + CGFloat(i) * 0.022] {
                line(from: CGPoint(x: r.minX + w * x, y: r.minY + h * 0.18), to: CGPoint(x: r.minX + w * x, y: r.maxY - h * 0.18), color: .black.opacity(0.4), width: max(1, w * 0.008))
            }
        }
        let label = rect(0.16, 0.13, 0.68, 0.74)
        art(in: CGRect(x: label.minX, y: label.minY, width: label.width, height: label.height * 0.66))
        let band = CGRect(x: label.minX, y: label.minY + label.height * 0.66, width: label.width, height: label.height * 0.34)
        context.fill(Path(band), with: .color(Self.paper))
        title(in: band.insetBy(dx: band.width * 0.06, dy: band.height * 0.14), color: Self.ink)
        rim(body)
    }

    private func cartridgeIntellivision() {
        let body = Path(roundedRect: r, cornerRadius: w * 0.06, style: .continuous)
        plastic(body, top: "232125", bottom: "0E0D0F")
        for i in 0..<4 {
            let y = r.minY + h * (0.035 + CGFloat(i) * 0.025)
            line(from: CGPoint(x: r.minX + w * 0.12, y: y), to: CGPoint(x: r.maxX - w * 0.12, y: y), color: .white.opacity(0.08), width: max(1, h * 0.005))
        }
        let label = rect(0.1, 0.16, 0.8, 0.78)
        let band = CGRect(x: label.minX, y: label.minY, width: label.width, height: label.height * 0.17)
        context.fill(Path(band), with: .color(Color(hex: "C9A453")))
        title(in: band.insetBy(dx: band.width * 0.08, dy: band.height * 0.16), color: Self.ink)
        art(in: CGRect(x: label.minX, y: band.maxY, width: label.width, height: label.height - band.height))
        rim(body)
    }

    private func floppy() {
        let sleeve = Path(roundedRect: r, cornerRadius: w * 0.025, style: .continuous)
        plastic(sleeve, top: "222024", bottom: "0E0D0F")
        let media = Color(hex: "4E3D30"), hole = Color(hex: "090708")
        let hub = CGPoint(x: r.midX, y: r.minY + h * 0.5)
        context.fill(circle(hub, w * 0.16), with: .color(media))
        context.fill(circle(hub, w * 0.085), with: .color(hole))
        context.stroke(circle(hub, w * 0.095), with: .color(Color(hex: "6D5846")), lineWidth: max(1, w * 0.012))
        context.fill(circle(CGPoint(x: r.midX + w * 0.23, y: hub.y - h * 0.02), w * 0.02), with: .color(hole))
        let slot = CGRect(x: r.midX - w * 0.055, y: r.minY + h * 0.7, width: w * 0.11, height: h * 0.25)
        context.fill(Path(roundedRect: slot, cornerRadius: w * 0.055), with: .color(media))
        context.fill(Path(rect(0.965, 0.15, 0.035, 0.07)), with: .color(hole))
        let label = rect(0.07, 0.06, 0.62, 0.24)
        context.fill(Path(roundedRect: label, cornerRadius: 1.5), with: .color(Self.paper))
        context.fill(Path(CGRect(x: label.minX, y: label.minY, width: label.width, height: label.height * 0.16)), with: .color(tint))
        for i in 1...2 {
            let y = label.minY + label.height * (0.28 + CGFloat(i) * 0.24)
            line(from: CGPoint(x: label.minX + label.width * 0.05, y: y), to: CGPoint(x: label.maxX - label.width * 0.05, y: y), color: Color(hex: "8EA6D6").opacity(0.7), width: max(0.5, h * 0.004))
        }
        // People wrote on their disks; the title is set in a handwriting face.
        title(in: CGRect(x: label.minX + label.width * 0.07, y: label.minY + label.height * 0.2, width: label.width * 0.86, height: label.height * 0.66),
              color: Color(hex: "2A3C8C"), font: "Noteworthy-Bold", uppercase: false, alignment: .leading)
        rim(sleeve)
    }

    private func disc() {
        let side = h
        let jewel = CGRect(x: r.minX, y: r.minY, width: side, height: side)
        let center = CGPoint(x: jewel.maxX - side * 0.16, y: jewel.midY)
        let radius = side * 0.44
        context.fill(circle(center, radius), with: .conicGradient(Gradient(colors: [
            Color(hex: "D9DEE5"), tint.opacity(0.85), Color(hex: "AEB6C2"), Color(hex: "F4F5F8"), Color(hex: "9DA7B5"), tint.opacity(0.7), Color(hex: "D9DEE5")
        ]), center: center))
        context.stroke(circle(center, radius * 0.38), with: .color(.white.opacity(0.35)), lineWidth: max(0.5, side * 0.006))
        context.fill(circle(center, radius * 0.17), with: .color(Color(hex: "8A919C")))
        context.fill(circle(center, radius * 0.07), with: .color(Hub.walnut))
        let cover = Path(roundedRect: jewel, cornerRadius: side * 0.015)
        art(in: jewel, corner: side * 0.015)
        let spine = CGRect(x: jewel.minX, y: jewel.minY, width: side * 0.075, height: side)
        context.fill(Path(spine), with: .color(.black.opacity(0.55)))
        for y in [0.12, 0.5, 0.88] {
            context.fill(Path(CGRect(x: spine.minX + spine.width * 0.25, y: jewel.minY + side * y - side * 0.03, width: spine.width * 0.5, height: side * 0.06)), with: .color(.white.opacity(0.12)))
        }
        title(in: CGRect(x: spine.maxX + side * 0.06, y: jewel.minY + side * 0.06, width: side * 0.78, height: side * 0.2), color: Self.paper, shadow: true, alignment: .leading)
        context.fill(cover, with: .linearGradient(Gradient(colors: [.white.opacity(0.16), .white.opacity(0)]), startPoint: CGPoint(x: jewel.minX, y: jewel.minY), endPoint: CGPoint(x: jewel.midX, y: jewel.midY)))
        context.stroke(cover, with: .color(.white.opacity(0.2)), lineWidth: 1)
    }

    private func cabinet() {
        let body = Path(roundedRect: rect(0.05, 0.12, 0.9, 0.88), cornerRadius: w * 0.03)
        plastic(body, top: "28201B", bottom: "120E0B")
        let marquee = rect(0.02, 0, 0.96, 0.135)
        context.fill(Path(roundedRect: marquee, cornerRadius: w * 0.03), with: .linearGradient(Gradient(colors: [tint, tint.opacity(0.75)]), startPoint: CGPoint(x: r.midX, y: marquee.minY), endPoint: CGPoint(x: r.midX, y: marquee.maxY)))
        title(in: marquee.insetBy(dx: marquee.width * 0.1, dy: marquee.height * 0.18), color: Self.ink)
        let bezel = rect(0.12, 0.18, 0.76, 0.36)
        context.fill(Path(roundedRect: bezel, cornerRadius: w * 0.02), with: .color(Color(hex: "050505")))
        art(in: bezel.insetBy(dx: w * 0.04, dy: w * 0.04), corner: w * 0.02)
        var panel = Path()
        panel.move(to: CGPoint(x: r.minX + w * 0.05, y: r.minY + h * 0.57))
        panel.addLine(to: CGPoint(x: r.maxX - w * 0.05, y: r.minY + h * 0.57))
        panel.addLine(to: CGPoint(x: r.maxX, y: r.minY + h * 0.66))
        panel.addLine(to: CGPoint(x: r.minX, y: r.minY + h * 0.66))
        panel.closeSubpath()
        context.fill(panel, with: .color(Color(hex: "3A2F28")))
        let stick = CGPoint(x: r.minX + w * 0.32, y: r.minY + h * 0.6)
        line(from: stick, to: CGPoint(x: stick.x, y: stick.y + h * 0.035), color: Color(hex: "BDBDBD"), width: max(1, w * 0.02))
        context.fill(circle(stick, w * 0.045), with: .color(Color(hex: "D9473B")))
        for x in [0.6, 0.73] { context.fill(circle(CGPoint(x: r.minX + w * x, y: r.minY + h * 0.615), w * 0.03), with: .color(tint)) }
        let door = rect(0.34, 0.74, 0.32, 0.15)
        context.fill(Path(roundedRect: door, cornerRadius: 1.5), with: .color(Color(hex: "2E2520")))
        for x in [0.42, 0.55] { context.fill(Path(rect(x, 0.78, 0.04, 0.05)), with: .color(Hub.amber.opacity(0.9))) }
        context.fill(Path(rect(0.05, 0.96, 0.9, 0.04)), with: .color(.black.opacity(0.4)))
        rim(body)
    }

    private func appTile() {
        let tile = Path(roundedRect: r, cornerRadius: w * 0.22, style: .continuous)
        art(in: r, corner: w * 0.22)
        title(in: CGRect(x: r.minX + w * 0.12, y: r.maxY - h * 0.28, width: w * 0.76, height: h * 0.18), color: Self.paper, shadow: true)
        context.fill(tile, with: .linearGradient(Gradient(colors: [.white.opacity(0.14), .white.opacity(0)]), startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.midY)))
        context.stroke(tile, with: .color(.white.opacity(0.16)), lineWidth: 1)
    }

    // MARK: Label art

    /// Fills `area` with the game's label artwork, drawn in its accent color.
    private func art(in area: CGRect, corner: CGFloat = 1.5) {
        var c = context
        let clip = Path(roundedRect: area, cornerRadius: corner, style: .continuous)
        c.clip(to: clip)
        c.fill(clip, with: .color(Color(hex: "15111A")))
        c.fill(clip, with: .linearGradient(Gradient(colors: [tint.opacity(0.42), tint.opacity(0.08)]), startPoint: CGPoint(x: area.minX, y: area.minY), endPoint: CGPoint(x: area.maxX, y: area.maxY)))
        let motif = game.artwork == "pixel" || game.artwork == "native" ? genreMotif : game.artwork
        switch motif {
        case "asteroids": asteroids(c, area)
        case "breakout": breakout(c, area)
        case "golf": golf(c, area)
        case "skate": skate(c, area)
        case "road": road(c, area)
        case "field": field(c, area)
        case "stars": starmap(c, area)
        default: sprite(c, area)
        }
    }

    private var genreMotif: String {
        switch game.genre.lowercased() {
        case "racing": return "road"
        case "sports": return "field"
        case "strategy": return "stars"
        default: return "sprite"
        }
    }

    private func asteroids(_ c: GraphicsContext, _ a: CGRect) {
        for i in 0..<14 {
            let x = a.minX + CGFloat((i * 73 + 19) % 97) / 97 * a.width, y = a.minY + CGFloat((i * 131 + 37) % 89) / 89 * a.height
            c.fill(circle(CGPoint(x: x, y: y), max(0.5, a.width * 0.006)), with: .color(.white.opacity(0.5)))
        }
        let rocks: [(CGFloat, CGFloat, CGFloat)] = [(0.2, 0.28, 0.17), (0.78, 0.24, 0.12), (0.8, 0.76, 0.2), (0.24, 0.8, 0.09)]
        for (x, y, size) in rocks {
            var rock = Path()
            for i in 0..<9 {
                let angle: CGFloat = CGFloat(i) / 9 * .pi * 2
                let radius = size * a.height * (i % 2 == 0 ? 1 : 0.72)
                let point = CGPoint(x: a.minX + x * a.width + cos(angle) * radius, y: a.minY + y * a.height + sin(angle) * radius)
                if i == 0 { rock.move(to: point) } else { rock.addLine(to: point) }
            }
            rock.closeSubpath()
            c.stroke(rock, with: .color(tint), lineWidth: max(1, a.width * 0.014))
        }
        var ship = Path()
        ship.move(to: CGPoint(x: a.minX + a.width * 0.5, y: a.minY + a.height * 0.36))
        ship.addLine(to: CGPoint(x: a.minX + a.width * 0.43, y: a.minY + a.height * 0.66))
        ship.addLine(to: CGPoint(x: a.minX + a.width * 0.5, y: a.minY + a.height * 0.58))
        ship.addLine(to: CGPoint(x: a.minX + a.width * 0.57, y: a.minY + a.height * 0.66))
        ship.closeSubpath()
        c.stroke(ship, with: .color(Self.paper), lineWidth: max(1, a.width * 0.016))
        c.fill(circle(CGPoint(x: a.minX + a.width * 0.5, y: a.minY + a.height * 0.2), max(1, a.width * 0.012)), with: .color(Self.paper))
    }

    private func breakout(_ c: GraphicsContext, _ a: CGRect) {
        let colors = [Color(hex: "EBA188"), tint, Color(hex: "D9CC73"), Color(hex: "8FC7E8")]
        for row in 0..<4 { for column in 0..<7 {
            let brick = CGRect(x: a.minX + a.width * (0.08 + CGFloat(column) * 0.122), y: a.minY + a.height * (0.14 + CGFloat(row) * 0.095), width: a.width * 0.11, height: a.height * 0.07)
            c.fill(Path(brick), with: .color(colors[row % colors.count]))
        } }
        c.fill(Path(CGRect(x: a.minX + a.width * 0.36, y: a.minY + a.height * 0.84, width: a.width * 0.28, height: max(2, a.height * 0.045))), with: .color(Self.paper))
        c.fill(Path(CGRect(x: a.minX + a.width * 0.62, y: a.minY + a.height * 0.62, width: a.width * 0.04, height: a.width * 0.04)), with: .color(Self.paper))
    }

    private func golf(_ c: GraphicsContext, _ a: CGRect) {
        c.fill(Path(CGRect(x: a.minX, y: a.minY, width: a.width, height: a.height * 0.5)), with: .linearGradient(Gradient(colors: [Color(hex: "2A3B55").opacity(0.6), .clear]), startPoint: CGPoint(x: a.midX, y: a.minY), endPoint: CGPoint(x: a.midX, y: a.minY + a.height * 0.5)))
        for i in 0..<5 {
            let band = CGRect(x: a.minX - a.width * 0.3 + CGFloat(i) * a.width * 0.08, y: a.minY + a.height * (0.52 + CGFloat(i) * 0.08), width: a.width * 1.6, height: a.height * 0.9)
            c.fill(Path(ellipseIn: band), with: .color(tint.opacity(0.16 + Double(i) * 0.05)))
        }
        let green = CGRect(x: a.minX + a.width * 0.48, y: a.minY + a.height * 0.6, width: a.width * 0.38, height: a.height * 0.12)
        c.fill(Path(ellipseIn: green), with: .color(tint.opacity(0.75)))
        let pole = CGPoint(x: green.midX, y: green.midY)
        line(c, from: pole, to: CGPoint(x: pole.x, y: a.minY + a.height * 0.18), color: Self.paper, width: max(1, a.width * 0.012))
        var flag = Path()
        flag.move(to: CGPoint(x: pole.x, y: a.minY + a.height * 0.18))
        flag.addLine(to: CGPoint(x: pole.x + a.width * 0.16, y: a.minY + a.height * 0.25))
        flag.addLine(to: CGPoint(x: pole.x, y: a.minY + a.height * 0.32))
        flag.closeSubpath()
        c.fill(flag, with: .color(Color(hex: "E8584A")))
        c.fill(circle(CGPoint(x: a.minX + a.width * 0.26, y: a.minY + a.height * 0.82), max(1, a.width * 0.022)), with: .color(.white))
    }

    private func skate(_ c: GraphicsContext, _ a: CGRect) {
        for i in 0..<5 {
            var stripe = Path()
            let x = a.minX + CGFloat(i) * a.width * 0.26 - a.width * 0.2
            stripe.move(to: CGPoint(x: x, y: a.maxY)); stripe.addLine(to: CGPoint(x: x + a.width * 0.45, y: a.minY))
            c.stroke(stripe, with: .color(tint.opacity(0.14)), lineWidth: a.width * 0.08)
        }
        var ramp = Path()
        ramp.move(to: CGPoint(x: a.minX, y: a.minY + a.height * 0.9))
        ramp.addQuadCurve(to: CGPoint(x: a.maxX, y: a.minY + a.height * 0.25), control: CGPoint(x: a.minX + a.width * 0.85, y: a.minY + a.height * 1.05))
        c.stroke(ramp, with: .color(tint), lineWidth: max(1, a.width * 0.018))
        var board = c
        board.translateBy(x: a.minX + a.width * 0.42, y: a.minY + a.height * 0.38)
        board.rotate(by: .degrees(-24))
        let deck = CGRect(x: -a.width * 0.2, y: -a.height * 0.035, width: a.width * 0.4, height: a.height * 0.07)
        board.fill(Path(roundedRect: deck, cornerRadius: a.height * 0.035), with: .color(Self.paper))
        for x in [-0.12, 0.12] { board.fill(circle(CGPoint(x: a.width * x, y: a.height * 0.06), a.width * 0.026), with: .color(tint)) }
    }

    private func road(_ c: GraphicsContext, _ a: CGRect) {
        let horizon = a.minY + a.height * 0.34, vanish = CGPoint(x: a.midX, y: horizon)
        line(c, from: CGPoint(x: a.minX, y: horizon), to: CGPoint(x: a.maxX, y: horizon), color: tint.opacity(0.4), width: 1)
        for side in [-1.0, 1.0] { for i in 0..<6 {
            let t = pow(CGFloat(i + 1) / 6, 1.7)
            let x = vanish.x + CGFloat(side) * t * a.width * 0.62, y = horizon + t * a.height * 0.66
            let post = CGSize(width: max(1, a.width * 0.05 * t), height: max(1.5, a.height * 0.14 * t))
            c.fill(Path(CGRect(x: x - post.width / 2, y: y - post.height, width: post.width, height: post.height)), with: .color(Self.paper.opacity(0.35 + 0.6 * Double(t))))
        } }
    }

    private func field(_ c: GraphicsContext, _ a: CGRect) {
        c.fill(Path(a), with: .color(Color(hex: "2F5A34").opacity(0.55)))
        for i in 0..<7 {
            let x = a.minX + a.width * (0.08 + CGFloat(i) * 0.14)
            line(c, from: CGPoint(x: x, y: a.minY), to: CGPoint(x: x, y: a.maxY), color: .white.opacity(i == 3 ? 0.55 : 0.28), width: max(1, a.width * 0.01))
        }
        let ball = CGRect(x: a.midX - a.width * 0.16, y: a.midY - a.height * 0.1, width: a.width * 0.32, height: a.height * 0.2)
        c.fill(Path(ellipseIn: ball), with: .color(Color(hex: "8C5A33")))
        line(c, from: CGPoint(x: ball.midX - ball.width * 0.22, y: ball.midY), to: CGPoint(x: ball.midX + ball.width * 0.22, y: ball.midY), color: Self.paper, width: max(1, a.width * 0.012))
        for i in 0..<4 {
            let x = ball.midX - ball.width * 0.15 + CGFloat(i) * ball.width * 0.1
            line(c, from: CGPoint(x: x, y: ball.midY - ball.height * 0.12), to: CGPoint(x: x, y: ball.midY + ball.height * 0.12), color: Self.paper, width: max(0.8, a.width * 0.008))
        }
    }

    private func starmap(_ c: GraphicsContext, _ a: CGRect) {
        for i in 0..<5 {
            let x = a.minX + a.width * CGFloat(i + 1) / 6, y = a.minY + a.height * CGFloat(i + 1) / 6
            line(c, from: CGPoint(x: x, y: a.minY), to: CGPoint(x: x, y: a.maxY), color: tint.opacity(0.12), width: 1)
            line(c, from: CGPoint(x: a.minX, y: y), to: CGPoint(x: a.maxX, y: y), color: tint.opacity(0.12), width: 1)
        }
        let worlds: [(CGFloat, CGFloat, CGFloat)] = [(0.26, 0.3, 0.07), (0.72, 0.42, 0.1), (0.4, 0.76, 0.055)]
        var route = Path()
        for (index, world) in worlds.enumerated() {
            let point = CGPoint(x: a.minX + a.width * world.0, y: a.minY + a.height * world.1)
            if index == 0 { route.move(to: point) } else { route.addLine(to: point) }
        }
        c.stroke(route, with: .color(Self.paper.opacity(0.5)), style: StrokeStyle(lineWidth: max(1, a.width * 0.008), dash: [3, 3]))
        for world in worlds {
            c.fill(circle(CGPoint(x: a.minX + a.width * world.0, y: a.minY + a.height * world.1), a.width * world.2), with: .color(tint))
        }
    }

    /// A symmetric 8-bit creature seeded by the game ID, so each title keeps
    /// its own sprite without implying it is the original character.
    private func sprite(_ c: GraphicsContext, _ a: CGRect) {
        var seed = game.id.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
        let columns = 11, rows = 8
        let pixel = min(a.width * 0.72 / CGFloat(columns), a.height * 0.62 / CGFloat(rows))
        let origin = CGPoint(x: a.midX - pixel * CGFloat(columns) / 2, y: a.midY - pixel * CGFloat(rows) / 2)
        for row in 0..<rows { for column in 0...(columns / 2) {
            let on = (row == 3 && column == 3) ? false : next() % 100 < (column == columns / 2 ? 70 : 52)
            guard on else { continue }
            for x in Set([column, columns - 1 - column]) {
                c.fill(Path(CGRect(x: origin.x + CGFloat(x) * pixel, y: origin.y + CGFloat(row) * pixel, width: pixel * 0.92, height: pixel * 0.92)), with: .color(row < 2 ? Self.paper : tint))
            }
        } }
    }

    // MARK: Primitives

    private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: r.minX + w * x, y: r.minY + h * y, width: w * width, height: h * height)
    }

    private func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func line(from a: CGPoint, to b: CGPoint, color: Color, width: CGFloat) { line(context, from: a, to: b, color: color, width: width) }

    private func line(_ c: GraphicsContext, from a: CGPoint, to b: CGPoint, color: Color, width: CGFloat) {
        var path = Path(); path.move(to: a); path.addLine(to: b)
        c.stroke(path, with: .color(color), lineWidth: width)
    }

    private func plastic(_ path: Path, top: String, bottom: String) {
        context.fill(path, with: .linearGradient(Gradient(colors: [Color(hex: top), Color(hex: bottom)]), startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY)))
    }

    /// Thin highlight along the upper edges, as if lit from above the shelf.
    private func rim(_ path: Path) {
        context.stroke(path, with: .linearGradient(Gradient(colors: [.white.opacity(0.3), .white.opacity(0.05), .clear]), startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.minY + h * 0.5)), lineWidth: 1)
    }

    /// Sets the game's name to fill `box` without overflowing it.
    private func title(in box: CGRect, color: Color, font: String = "Futura-CondensedExtraBold", uppercase: Bool = true, shadow: Bool = false, alignment: HorizontalAlignment = .center) {
        guard box.width > 6, box.height > 4 else { return }
        let name = uppercase ? game.title.uppercased() : game.title
        let probe = context.resolve(Text(name).font(.custom(font, size: 100)))
        let measured = probe.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        guard measured.width > 0, measured.height > 0 else { return }
        let size = min(100 * box.width / measured.width, 100 * box.height / measured.height * 0.95)
        guard size >= 3 else { return }
        var c = context
        if shadow { c.addFilter(.shadow(color: .black.opacity(0.7), radius: max(1, size * 0.08), x: 0, y: max(0.5, size * 0.04))) }
        let text = c.resolve(Text(name).font(.custom(font, size: size)).foregroundColor(color))
        let point = CGPoint(x: alignment == .leading ? box.minX : box.midX, y: box.midY)
        c.draw(text, at: point, anchor: alignment == .leading ? .leading : .center)
    }
}

/// Small outline of a media form for the sidebar's list of systems.
struct MediaGlyph: View {
    let kind: MediaKind
    var body: some View {
        Canvas { context, size in
            let width = min(size.width, size.height * kind.aspect) - 1.5, height = width / kind.aspect
            let r = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
            let line: CGFloat = 1.3
            func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: r.minX + r.width * x, y: r.minY + r.height * y, width: r.width * w, height: r.height * h)
            }
            switch kind {
            case .floppy:
                context.stroke(Path(roundedRect: r, cornerRadius: 1.5), with: .foreground, lineWidth: line)
                context.fill(Path(ellipseIn: box(0.36, 0.38, 0.28, 0.28)), with: .foreground)
            case .disc:
                let side = r.height
                context.stroke(Path(ellipseIn: CGRect(x: r.maxX - side * 0.9, y: r.minY + side * 0.05, width: side * 0.9, height: side * 0.9)), with: .foreground, lineWidth: line)
                context.stroke(Path(roundedRect: CGRect(x: r.minX, y: r.minY, width: side, height: side), cornerRadius: 1), with: .foreground, lineWidth: line)
            case .cabinet:
                context.stroke(Path(roundedRect: r, cornerRadius: 1.5), with: .foreground, lineWidth: line)
                context.fill(Path(box(0.22, 0.2, 0.56, 0.32)), with: .foreground)
            case .app:
                context.stroke(Path(roundedRect: r, cornerRadius: r.width * 0.25, style: .continuous), with: .foreground, lineWidth: line)
            default:
                context.stroke(Path(roundedRect: r, cornerRadius: 1.5), with: .foreground, lineWidth: line)
                context.fill(Path(kind == .cartridgeC64 ? box(0.2, 0.25, 0.6, 0.5) : box(0.22, 0.38, 0.56, 0.48)), with: .foreground)
            }
        }
        .accessibilityHidden(true)
    }
}
