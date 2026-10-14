import SwiftUI

/// Original, code-drawn library artwork. It is never presented as an original
/// game screenshot. Resolution independent artwork stays sharp on Retina Macs.
struct GameArtwork: View {
    let game: GameManifest
    var hero = false
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                LinearGradient(colors: [game.tint.opacity(0.24), Color(hex: "151B24"), Color(hex: "11151C")], startPoint: .topLeading, endPoint: .bottomTrailing)
                Canvas { context, canvas in
                    for i in 0..<45 {
                        let x = CGFloat((i * 73 + 19) % 997) / 997 * canvas.width
                        let y = CGFloat((i * 131 + 83) % 991) / 991 * canvas.height
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: i % 7 == 0 ? 2 : 1, height: i % 7 == 0 ? 2 : 1)), with: .color(.white.opacity(i % 3 == 0 ? 0.25 : 0.08)))
                    }
                    if game.artwork == "asteroids" {
                        let rocks: [(CGFloat, CGFloat, CGFloat)] = [(0.16,0.25,0.16),(0.72,0.23,0.12),(0.82,0.78,0.19),(0.25,0.83,0.08)]
                        for (x,y,r) in rocks {
                            var path = Path()
                            for i in 0..<9 {
                                let angle = Double(i) / 9 * Double.pi * 2
                                let radius = r * canvas.height * (i % 2 == 0 ? 1 : 0.73)
                                let point = CGPoint(x: x * canvas.width + cos(angle) * radius, y: y * canvas.height + sin(angle) * radius)
                                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                            }
                            path.closeSubpath(); context.stroke(path, with: .color(game.tint.opacity(0.6)), lineWidth: 1.5)
                        }
                        var ship = Path()
                        ship.move(to: CGPoint(x: canvas.width * 0.52, y: canvas.height * 0.29))
                        ship.addLine(to: CGPoint(x: canvas.width * 0.46, y: canvas.height * 0.66))
                        ship.addLine(to: CGPoint(x: canvas.width * 0.52, y: canvas.height * 0.57))
                        ship.addLine(to: CGPoint(x: canvas.width * 0.58, y: canvas.height * 0.66)); ship.closeSubpath()
                        context.stroke(ship, with: .color(game.tint), lineWidth: 2)
                        context.fill(Path(ellipseIn: CGRect(x: canvas.width * 0.515, y: canvas.height * 0.13, width: 3, height: 3)), with: .color(game.tint))
                    } else if game.artwork == "breakout" {
                        for row in 0..<5 { for column in 0..<9 {
                            let rect = CGRect(x: canvas.width * 0.09 + CGFloat(column) * canvas.width * 0.091, y: canvas.height * 0.18 + CGFloat(row) * canvas.height * 0.075, width: canvas.width * 0.08, height: canvas.height * 0.048)
                            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color([Color(hex:"EBA188"),game.tint,Color(hex:"D9CC73")][row % 3].opacity(0.85)))
                        } }
                        context.fill(Path(roundedRect: CGRect(x: canvas.width * 0.37, y: canvas.height * 0.83, width: canvas.width * 0.27, height: 4), cornerRadius: 2), with: .color(game.tint))
                        context.fill(Path(ellipseIn: CGRect(x: canvas.width * 0.62, y: canvas.height * 0.65, width: 6, height: 6)), with: .color(.white))
                    } else if game.artwork == "skate" {
                        for i in 0..<6 {
                            var line = Path(); let x = CGFloat(i) * canvas.width / 5
                            line.move(to: CGPoint(x: x, y: canvas.height)); line.addLine(to: CGPoint(x: x + canvas.width * 0.4, y: 0))
                            context.stroke(line, with: .color(game.tint.opacity(0.12)), lineWidth: 14)
                        }
                        var ramp = Path(); ramp.move(to: CGPoint(x: 0, y: canvas.height * 0.83)); ramp.addQuadCurve(to: CGPoint(x: canvas.width * 0.95, y: canvas.height * 0.3), control: CGPoint(x: canvas.width * 0.8, y: canvas.height * 1.1))
                        context.stroke(ramp, with: .color(game.tint.opacity(0.6)), lineWidth: 2)
                    } else if game.artwork == "golf" {
                        for i in 0..<7 {
                            let rect = CGRect(x: -canvas.width * 0.1 + CGFloat(i) * 20, y: canvas.height * 0.48 + CGFloat(i) * 9, width: canvas.width * 1.1, height: canvas.height * 0.7)
                            context.stroke(Path(ellipseIn: rect), with: .color(game.tint.opacity(0.1 + Double(i) * 0.025)), lineWidth: 1)
                        }
                        var flag = Path(); flag.move(to: CGPoint(x: canvas.width * 0.68, y: canvas.height * 0.74)); flag.addLine(to: CGPoint(x: canvas.width * 0.68, y: canvas.height * 0.2)); flag.addLine(to: CGPoint(x: canvas.width * 0.84, y: canvas.height * 0.3)); flag.addLine(to: CGPoint(x: canvas.width * 0.68, y: canvas.height * 0.36))
                        context.stroke(flag, with: .color(game.tint), lineWidth: 2)
                    } else {
                        let pixel = min(canvas.width / 21, canvas.height / 12)
                        let seed = game.id.utf8.reduce(0) { $0 + Int($1) }
                        for row in 0..<7 { for col in 0..<11 where (row * 17 + col * 11 + seed) % 7 < 3 {
                            let x = canvas.width / 2 + (CGFloat(col) - 5.5) * pixel * 1.4
                            let y = canvas.height / 2 + (CGFloat(row) - 3.5) * pixel * 1.4
                            context.fill(Path(CGRect(x: x, y: y, width: pixel, height: pixel)), with: .color(game.tint.opacity(0.35 + Double(row % 3) * 0.2)))
                        } }
                    }
                }
                if game.artwork == "skate" {
                    Image(systemName: "figure.skating").font(.system(size: size.height * 0.55, weight: .ultraLight)).foregroundStyle(game.tint).rotationEffect(.degrees(-18)).shadow(color: game.tint.opacity(0.2), radius: 25)
                }
                VStack { HStack { Text(game.platform.uppercased()).font(.system(size: hero ? 10 : 8, weight: .bold, design: .monospaced)).tracking(1.7); Spacer(); Text(String(game.year)).font(.system(size: 10, design: .monospaced)) }; Spacer() }
                    .foregroundStyle(.white.opacity(0.5)).padding(hero ? 22 : 14)
            }
        }
        .clipped()
    }
}
