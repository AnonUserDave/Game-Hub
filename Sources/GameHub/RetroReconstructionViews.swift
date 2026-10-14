import AppKit
import SwiftUI

private struct RetroGameHeader: View {
    let title: String
    let onExit: () -> Void
    var body: some View { HStack { Text(title).font(.headline); Spacer(); Text("Development reconstruction").foregroundStyle(.secondary); Button("Library", action: onExit) } }
}
private struct RetroSessionButtons: View {
    let paused: Bool
    let pause, save, newGame: () -> Void
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(paused ? "Continue" : "Pause", action: pause)
            Button("Save game", action: save)
            Button("New game", action: newGame)
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ApplePanicGameView: View {
    let root: URL
    let onExit: () -> Void
    @StateObject private var session = ApplePanicSession()
    var body: some View {
        VStack(spacing: 16) {
            RetroGameHeader(title: "APPLE PANIC · APPLE II", onExit: onExit)
            if session.presentation == nil {
                RetroLoadingPanel(message: session.message, loading: session.loading) { session.load(root: root) }
            } else if session.setup {
                VStack(spacing: 20) {
                    Text("APPLE PANIC").font(.largeTitle.monospaced())
                    Text("Climb, dig holes, trap the creatures, then fill the holes to drop them.")
                    Text("I / J / K / M move · A digs · S fills\nArrows also move · Escape pauses · Ctrl-R restarts").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Start game") { session.start() }.buttonStyle(.borderedProminent)
                    Button("Resume saved game") { session.resumeSave() }.disabled(!session.hasSave)
                    Text("Original sprite silhouettes; provisional floor, color and clock presentation.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let game = session.simulation, let media = session.presentation {
                HStack(alignment: .top, spacing: 24) {
                    RetroPixelCanvas(width: 280, height: 192) { draw(game: game, media: media, context: &$0) }
                    VStack(alignment: .leading, spacing: 16) {
                        Text("SCORE \(game.state.score)").font(.title2.monospacedDigit())
                        Text("HIGH \(game.state.highScore)\nLEVEL \(game.state.level)\nLIVES \(game.state.lives)\nBONUS \(game.state.bonus)").monospacedDigit()
                        ProgressView(value: Double(game.state.hourglass), total: 130) { Text("Time remaining") }.tint(.green)
                        Text(session.paused ? "PAUSED" : game.state.phase == .gameOver ? "GAME OVER" : game.state.phase == .completed ? "ALL 48 LEVELS CLEARED" : "I J K M · A dig · S fill").foregroundStyle(Color(hex: "C2EF93"))
                        Text("Controller: stick / D-pad move\nX dig · Y fill\nB / Menu pause").font(.callout)
                        RetroSessionButtons(paused: session.paused, pause: session.togglePause, save: session.save, newGame: session.newGame, message: session.message)
                        Spacer()
                        Text("Original comparison and M1 acceptance pending.").font(.caption).foregroundStyle(.secondary)
                    }.frame(width: 245)
                }
            }
        }.padding(24).background(Color(hex: "101318"))
            .background(RetroKeys(handler: session.key, modifiedHandler: session.modifiedKey).frame(width: 0, height: 0))
            .background(RetroWindow(attached: session.attach).frame(width: 0, height: 0))
            .onAppear { session.load(root: root) }.onDisappear { session.stop() }
    }
    private func draw(game: ApplePanicSimulation, media: ApplePanicPresentation, context: inout GraphicsContext) {
        // Logical source X is half an HGR pixel. Sprite masks retain21 pixels;
        // floor/ladder/hole art remains provisional until its tile decode lands.
        for row in stride(from: 16, through: 176, by: 32) {
            context.fill(Path(CGRect(x: 2, y: row, width: 266, height: 1)), with: .color(.white))
        }
        for ladder in game.ladders {
            let x = ladder.x * 2
            for side in [x, x + 8] { context.fill(Path(CGRect(x: side, y: ladder.top, width: 1, height: ladder.bottom - ladder.top)), with: .color(.white)) }
            for row in stride(from: ladder.top, to: ladder.bottom, by: 4) { context.fill(Path(CGRect(x: x, y: row, width: 9, height: 1)), with: .color(.white)) }
        }
        for hole in game.state.holes {
            context.fill(Path(CGRect(x: hole.x * 2 - 7, y: hole.row + 1, width: 14, height: hole.depth)), with: .color(.black))
        }
        for enemy in game.state.enemies where enemy.active {
            retroSprite(media.sprites["enemy\(enemy.kind)Frame\(enemy.alternateSprite ? 1 : 0)"], x: enemy.x * 2, y: enemy.y, context: &context)
        }
        retroSprite(media.sprites[game.playerSpriteName], x: game.state.player.x * 2, y: game.state.player.y, context: &context)
    }
}

struct CrossfireGameView: View {
    let root: URL
    let onExit: () -> Void
    @StateObject private var session = CrossfireSession()
    var body: some View {
        VStack(spacing: 16) {
            RetroGameHeader(title: "CROSSFIRE · APPLE II", onExit: onExit)
            if session.presentation == nil {
                RetroLoadingPanel(message: session.message, loading: session.loading) { session.load(root: root) }
            } else if session.setup {
                VStack(spacing: 20) {
                    Text("CROSSFIRE").font(.largeTitle.monospaced())
                    Text("Move through the corridors and fire in a separate direction. Collect ammunition when it appears.")
                    Text("I J K L move · E S D F fire · Space stops\nArrows also move · Escape pauses").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Start game") { session.start() }.buttonStyle(.borderedProminent)
                    Button("Resume saved game") { session.resumeSave() }.disabled(!session.hasSave)
                    Text("Original monochrome masks; source clock, colors, sound and startup remain unqualified.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let media = session.presentation {
                HStack(alignment: .top, spacing: 24) {
                    RetroPixelCanvas(width: 280, height: 192) { draw(game: session.simulation, media: media, context: &$0) }
                    VStack(alignment: .leading, spacing: 16) {
                        Text("SCORE \(session.simulation.score)").font(.title2.monospacedDigit())
                        Text("HIGH \(session.simulation.highScore)\nWAVE \(session.simulation.wave)\nLIVES \(session.simulation.lives)\nAMMO \(session.simulation.ammunition)").monospacedDigit()
                        Text(session.paused ? "PAUSED" : session.simulation.ended ? "GAME OVER" : "I J K L move\nE S D F fire\nSpace stops").foregroundStyle(Color(hex: "C2EF93"))
                        Text("Controller: left stick / D-pad move\nRight stick fires\nX left · Y up · A down · RB right\nB / Menu pause").font(.callout)
                        RetroSessionButtons(paused: session.paused, pause: session.togglePause, save: session.save, newGame: session.newGame, message: session.message)
                        Spacer()
                        Text("Development pacing: 960 source loop iterations / second. Audio pending. Original comparison and M1 acceptance pending.").font(.caption).foregroundStyle(.secondary)
                    }.frame(width: 255)
                }
            }
        }.padding(24).background(Color(hex: "101318"))
            .background(RetroKeys(handler: session.key, modifiedHandler: session.modifiedKey).frame(width: 0, height: 0))
            .background(RetroWindow(attached: session.attach).frame(width: 0, height: 0))
            .onAppear { session.load(root: root) }.onDisappear { session.stop() }
    }
    private func draw(game: CrossfireSimulation, media: CrossfirePresentation, context: inout GraphicsContext) {
        // Field coordinates use source offset (8,7). $6EAC XORs source
        // silhouettes against the field; opaque white overlays hide bonuses.
        for obstacle in CrossfireSimulation.obstacles {
            context.fill(Path(CGRect(x: obstacle.x + 8, y: obstacle.y + 7, width: 16, height: 16)), with: .color(.white))
        }
        if game.state.resupplyVisible, let point = game.state.resupply { retroSprite(media.sprites["ammo"], x: point.x + 2, y: point.y + 1, context: &context, xor: true) }
        for bonus in game.state.bonuses where bonus.kind < 5 {
            retroSprite(media.sprites[bonus.kind == 0 ? "bonus-idle" : "bonus-\(bonus.kind - 1)"], x: bonus.position.x + (bonus.kind == 0 ? 4 : 1), y: bonus.position.y + (bonus.kind == 0 ? 3 : 4), context: &context, xor: true)
        }
        for enemy in game.enemies where enemy.isVisible {
            let name = enemy.state >= 6 ? "explosion-\([0, 1, 2, 1, 0][enemy.state - 6])" : "enemy-\(enemy.stage)"
            retroSprite(media.sprites[name], x: enemy.position.x + 2, y: enemy.position.y + 1, context: &context, xor: true)
        }
        for projectile in game.projectiles where projectile.kind != 0 { retroSprite(media.sprites["projectile"], x: projectile.position.x + 8, y: projectile.position.y + 7, context: &context, xor: true) }
        if !game.state.playerDead { retroSprite(media.sprites["player"], x: game.player.x + 2, y: game.player.y + 3, context: &context, xor: true) }
        else if game.state.deathFrame < 6 { retroSprite(media.sprites["explosion-\(min(2, game.state.deathFrame / 2))"], x: game.player.x + 2, y: game.player.y + 1, context: &context, xor: true) }
    }
}

/// Original character cells and authored HUD placements from $E80E/$E8E7.
/// Palette RGB values and VIC border cropping await original visual comparison.
enum NightDriverScreen {
    static func cells(game: NightDriverSimulation, media: NightDriverMedia, instructions: Bool = false) -> [NightDriverCell] {
        if instructions { return media.graphics.instructions.enumerated().map { NightDriverCell(column: $0.offset % 40, row: $0.offset / 40, character: $0.element) } }
        var cells = (0..<1000).map { NightDriverCell(column: $0 % 40, row: $0 / 40, character: 32) }
        func write(_ offset: Int, _ values: [Int], color: Int) {
            for (i, value) in values.enumerated() where offset + i < cells.count { cells[offset + i].character = value; cells[offset + i].color = color }
        }
        write(0, Array(repeating: 0, count: 40), color: 6)
        for cell in game.roadCells where cell.row < 22 { cells[cell.row * 40 + cell.column] = cell }
        let hud = media.graphics.hud
        write(0x372, hud.gear, color: 5); write(0x37f, hud.speed, color: 4); write(0x3c8, hud.time, color: 5)
        write(0x35f, hud.highScore, color: 1)
        for i in 0..<17 { cells[0x35f + i].color = hud.colors[i] }
        write(0x387, hud.extendedPlay, color: game.state.extendedPlay ? 2 : 0); write(0x3d7, hud.timeLabel, color: 7)
        for (offset, glyph) in [(0x354, 0x12), (0x3cc, 0x13), (0x3a4, 0x14), (0x37c, 0x15), (0x3d4, 0x1d), (0x3d5, 0x1e), (0x3d0, 0x2e)] { write(offset, [glyph], color: 1) }
        // $E6FE/$E726: four existing gear indicator cells; selected one yellow.
        for gear in 0..<4 { cells[0x354 + gear * 40].color = gear == game.state.gear ? 7 : 6 }
        let digits = String(format: "%04d", game.state.highScore).utf8.map { Int($0) }
        for (offset, glyph) in zip([0x368, 0x369, 0x36b, 0x36c], digits) { write(offset, [glyph], color: 1) }
        for (row, values) in media.graphics.car.enumerated() {
            for (column, glyph) in values.enumerated() where row >= 3 || glyph != 0 { write((15 + row) * 40 + 11 + column, [glyph], color: 2) }
        }
        write(20 * 40 + 11, Array(repeating: 32, count: 18), color: 1)
        if game.state.phase == .crashed {
            for phase in 0...game.state.crashStage { for cell in media.graphics.crashPhases[phase] { write(cell[1] * 40 + cell[0], [cell[2]], color: 2) } }
        }
        return cells
    }
}

struct NightDriverGameView: View {
    let root: URL
    let onExit: () -> Void
    @StateObject private var session = NightDriverSession()
    var body: some View {
        VStack(spacing: 16) {
            RetroGameHeader(title: "NIGHT DRIVER · COMMODORE / HAL 1982", onExit: onExit)
            if session.presentation == nil {
                RetroLoadingPanel(message: session.message, loading: session.loading) { session.load(root: root) }
            } else if let media = session.presentation {
                HStack(alignment: .top, spacing: 24) {
                    RetroPixelCanvas(width: 320, height: 200) { draw(media: media, context: &$0) }
                        .overlay { GeometryReader { geometry in Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { session.pointer($0.location.x / geometry.size.width) }) } }
                    VStack(alignment: .leading, spacing: 16) {
                        if session.setup {
                            Text("NIGHT DRIVER").font(.title2)
                            Text("A accelerates · L / ; steer\nArrows also drive\nF1 keyboard / joystick\nF3 paddle / trackpad").font(.callout)
                            Button("Start keyboard / joystick") { session.start(paddle: false) }.buttonStyle(.borderedProminent)
                            Button("Start paddle / trackpad") { session.start(paddle: true) }
                            Button("Resume saved drive") { session.resumeSave() }.disabled(!session.hasSave)
                        } else {
                            Text("DISTANCE \(session.simulation.state.distance)").font(.title2.monospacedDigit())
                            Text("HIGH \(session.simulation.state.highScore)\nSPEED \(session.simulation.state.speed)\nTIME \(session.simulation.state.timeDisplay)").monospacedDigit()
                            Text(session.paused ? "PAUSED" : session.simulation.state.phase == .crashed ? "CRASH" : session.simulation.state.phase == .ended ? "DRIVE OVER" : "A accelerates · L / ; steer").foregroundStyle(Color(hex: "C2EF93"))
                            Text(session.paddleMode ? "Paddle: drag / left stick\nController A accelerates" : "Controller: left stick / D-pad steer\nA accelerates").font(.callout)
                            RetroSessionButtons(paused: session.paused, pause: session.togglePause, save: session.save, newGame: session.newGame, message: session.message)
                        }
                        Spacer()
                        Text("Development pacing: 120 control steps and 50 interrupts / second; crash stages 0.2s. Original clocks, audio, visual comparison and M1 acceptance pending.").font(.caption).foregroundStyle(.secondary)
                    }.frame(width: 270)
                }
            }
        }.padding(24).background(Color(hex: "101318"))
            .background(RetroKeys(handler: session.key).frame(width: 0, height: 0))
            .background(RetroWindow(attached: session.attach).frame(width: 0, height: 0))
            .onAppear { session.load(root: root) }.onDisappear { session.stop() }
    }
    private func draw(media: NightDriverPresentation, context: inout GraphicsContext) {
        let cells = NightDriverScreen.cells(game: session.simulation, media: media.media, instructions: session.setup)
        retroSprite(try? media.screenImage(cells: cells), x: 0, y: 0, context: &context)
        guard !session.setup else { return }
        let state = session.simulation.state
        let speed = String(format: "%03d", state.speed).utf8.map { Int($0 - 48) }
        for (i, digit) in speed.enumerated() { retroSprite(media.coloredDigits[3]?[digit], x: 6 + i * 16, y: 183, context: &context) }
        let time = String(format: "%02d", state.timeDisplay).utf8.map { Int($0 - 48) }
        for (i, digit) in time.enumerated() { retroSprite(media.coloredDigits[state.timeDisplay < 11 ? 2 : 7]?[digit], x: 256 + i * 16, y: 183, context: &context) }
        // $E749/$E77C: four 8-column rolling digits across two24-bit sprites,
        // with the lower pair inverted and the saved fractional road count.
        let distance = String(format: "%04d", state.distance).utf8.map { Int($0 - 48) }
        for (i, digit) in distance.enumerated() {
            let lower = i >= 2
            let shouldRoll = i == 3 || distance.dropFirst(i + 1).allSatisfy { $0 == 9 }
            let offset = shouldRoll ? state.distanceFraction : 0
            let rows = media.media.graphics.scoreDigitRows.flatMap { $0 }
            for y in 0..<8 {
                let byte = rows[digit * 8 + offset + y] ^ (lower ? 255 : 0)
                for x in 0..<8 where byte & (128 >> x) != 0 { context.fill(Path(CGRect(x: [112, 120, 136, 144][i] + x, y: 191 + y, width: 1, height: 1)), with: .color(.white)) }
            }
        }
    }
}
