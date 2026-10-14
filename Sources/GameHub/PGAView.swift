import AppKit
import SceneKit
import SwiftUI

private let pgaGold = Color(hex: "EDD297")
private let pgaInk = Color(hex: "102223")

struct PGAGameView: View {
    @StateObject private var session: PGAGameSession
    @State private var showHelp = true
    init(choice: PGACourseChoice = .practice, onExit: @escaping () -> Void) {
        _session = StateObject(wrappedValue: PGAGameSession(choice: choice, onExit: onExit))
    }
    private var game: PGASimulation { session.simulation }

    var body: some View {
        if session.showingLab {
            PGAOriginalCourseView(onExit: { [weak session] in session?.closeLab() }, onHub: { [weak session] in session?.exit() })
        } else { gameContent }
    }
    private var gameContent: some View {
        GeometryReader { geometry in
            ZStack {
                PGASceneView(session: session).ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar
                    // An original course shows no hole panels until its data
                    // is installed, so the placeholder state is never visible.
                    if session.loadState == .ready {
                        HStack(alignment: .top) { holeCard; Spacer(); performanceCard }.padding(22)
                        Spacer(minLength: 12)
                        HStack(alignment: .bottom, spacing: 20) {
                            if session.isOriginal && session.hud.available { originalSwingCard } else { swingCard }
                            Spacer(minLength: 0)
                            if geometry.size.width > 900 { mapCard }
                        }.padding(.horizontal, 22).padding(.bottom, 16)
                    } else { Spacer() }
                    bottomBar
                }
                if case let .loading(message) = session.loadState {
                    if session.isOriginal && session.hud.available { PGAOriginalLoadingScreen(images: session.hud, message: message) }
                    else { loadingOverlay(message) }
                }
                else if case let .failed(message) = session.loadState { failureOverlay(message) }
                else if session.paused { pauseOverlay }
                else if game.phase == .holed || game.phase == .roundComplete {
                    if session.isOriginal && session.hud.available { originalScoreOverlay } else { scoreOverlay }
                }
            }
        }.background(.black).onAppear {
            session.start()
        }.onDisappear { session.stop() }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.golf").font(.system(size: 19, weight: .medium)).foregroundStyle(pgaGold)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.isOriginal ? "PGA 2005 · ORIGINAL PEBBLE BEACH DATA · DEVELOPMENT" : "PGA 2005 · NATIVE DEVELOPMENT").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1.3)
                Text(session.isOriginal ? "Original TCR terrain, textures, tees and pins · approximate native physics, not the original engine" : "Generated practice course · original game reconstruction in progress").font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            Button { session.openLab() } label: { Label("Original course lab", systemImage: "mountain.2") }
            Button { session.fullscreen() } label: { Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right") }
            Button { session.togglePause() } label: { Label("Pause", systemImage: "pause.fill") }
            Button { session.exit() } label: { Label("Hub", systemImage: "square.grid.2x2") }
        }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 22).padding(.vertical, 12).background(pgaInk.opacity(0.95))
    }

    private var holeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(game.course.name.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundStyle(pgaGold)
            HStack(alignment: .firstTextBaseline, spacing: 13) {
                Text(String(format: "%02d", game.holeIndex + 1)).font(.system(size: 39, weight: .light, design: .rounded))
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.hole.name).font(.system(size: 14, weight: .semibold))
                    Text(game.hole.source?.scorecardYards.map { "PAR \(game.hole.par)    \($0) YARDS · CARD" } ?? "PAR \(game.hole.par)    \(Int((game.hole.length * 1.09361).rounded())) YARDS")
                        .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                }
            }
            Rectangle().fill(.white.opacity(0.16)).frame(height: 1)
            HStack(spacing: 25) {
                stat("STROKE", "\(game.strokes + (game.phase == .holed ? 0 : 1))")
                stat("TO PIN", game.distanceToCup < 20 ? String(format: "%.1f ft", game.distanceToCup * 3.28084) : "\(Int((game.distanceToCup * 1.09361).rounded())) yd")
                stat("LIE", game.lieLabel)
                if session.isOriginal { elevation }
            }
        }.padding(17).background(panel).frame(maxWidth: 350, alignment: .leading).foregroundStyle(.white)
    }

    /// Height of the pin relative to the ball, with the original up/downhill icon.
    private var elevation: some View {
        let feet = Int(((game.hole.cup.y - game.ball.y) * 3.28084).rounded())
        return VStack(alignment: .leading, spacing: 4) {
            Text("ELEV").font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(0.8).foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 4) {
                if let icon = session.hud.image(feet >= 0 ? "uphill" : "downhill") {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 26, height: 13)
                }
                Text(feet == 0 ? "LEVEL" : "\(feet > 0 ? "+" : "")\(feet) FT").font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(0.8).foregroundStyle(.white.opacity(0.5))
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
        }
    }

    private var performanceCard: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(session.drawableDescription).font(.system(size: 9, weight: .medium, design: .monospaced))
            Text("\(session.frameRate > 0 ? "\(session.frameRate) FPS · " : "")\(["Player camera", "Approach camera", "Course overview"][session.cameraMode])")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.65))
            Text(session.controllerName ?? "Keyboard + trackpad").font(.system(size: 9)).foregroundStyle(pgaGold)
        }.foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 9).background(panel)
    }

    private var swingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SELECTED CLUB").font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(1.2).foregroundStyle(.white.opacity(0.5))
                    Text(game.club.title).font(.system(size: 22, weight: .medium))
                }
                Spacer()
                Text(game.club == .putter ? "\(Int((game.targetDistance * 3.28084).rounded())) ft max" : "~\(Int((game.targetDistance * 1.09361).rounded())) yd carry")
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(pgaGold)
            }
            HStack(spacing: 6) {
                ForEach(PGAClub.allCases, id: \.rawValue) { club in
                    Button { session.changeClub(club.rawValue - game.club.rawValue) } label: {
                        Text(club.shortTitle).font(.system(size: 10, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 5).fill(club == game.club ? pgaGold : .white.opacity(0.08)))
                            .foregroundStyle(club == game.club ? pgaInk : .white.opacity(0.7))
                    }.buttonStyle(.plain).disabled(game.phase != .aiming)
                }
            }
            swingMeter
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: game.phase.inMotion ? "location.fill" : "info.circle").foregroundStyle(pgaGold).padding(.top, 1)
                Text(game.message).font(.system(size: 11)).foregroundStyle(.white.opacity(0.82)).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
            }.frame(minHeight: 29, alignment: .top)
            if showHelp {
                Text(session.controllerName == nil ? "← → / A D aim   ↑ ↓ / W S clubs   H aim at pin\nSpace or click: start → power → accuracy\nDrag to aim · scroll to zoom · C camera · Esc pause" : "Left stick / D-pad aim · LB RB clubs · Y aim at pin\nA: start → power → accuracy · X camera\nRight stick zoom · B / Menu pause")
                    .font(.system(size: 9, design: .monospaced)).lineSpacing(4).foregroundStyle(.white.opacity(0.55))
            }
        }.padding(18).frame(width: 385).background(panel).foregroundStyle(.white)
    }

    /// Pebble Beach module: original circular meter, bag graphics and panel art.
    private var originalSwingCard: some View {
        HStack(alignment: .bottom, spacing: 16) {
            PGAOriginalSwingMeter(simulation: game, images: session.hud)
                .frame(width: 196, height: 196)
                .contentShape(Circle())
                .onTapGesture { session.swing() }
                .help("Click: start swing, set power, strike at 6 o'clock")
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text(game.club.title).font(.system(size: 21, weight: .semibold))
                    Spacer()
                    Text(game.club == .putter ? "\(Int((game.targetDistance * 3.28084).rounded())) FT MAX" : "~\(Int((game.targetDistance * 1.09361).rounded())) YD")
                        .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(pgaGold)
                }
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(PGAClub.allCases, id: \.rawValue) { club in
                        Button { session.changeClub(club.rawValue - game.club.rawValue) } label: {
                            VStack(spacing: 3) {
                                if let image = session.hud.club(club, selected: club == game.club) {
                                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(height: 74)
                                }
                                Text(club.shortTitle).font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(club == game.club ? pgaGold : .white.opacity(0.55))
                            }.frame(width: 26)
                        }.buttonStyle(.plain).disabled(game.phase != .aiming)
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: game.phase.inMotion ? "location.fill" : "info.circle").foregroundStyle(pgaGold)
                    Text(game.message).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                }.frame(minHeight: 28, alignment: .top)
                Text(game.phase == .power ? "POWER \(Int((game.meter * 100).rounded()))% · CLICK TO SET" : game.phase == .accuracy ? "STRIKE AS THE MARKER CROSSES 6 O'CLOCK" : game.phase.inMotion ? "\(Int((game.shotPower * 100).rounded()))% · \(Int((game.lastShotDistance * 1.09361).rounded())) YD" : "SPACE / CLICK THE METER / A TO SWING")
                    .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(0.8).foregroundStyle(.white.opacity(0.7))
                if showHelp {
                    Text("← → aim · ↑ ↓ clubs · H aim at pin · C camera · Esc pause\nController: stick aim · LB/RB clubs · A swing · X camera · B pause")
                        .font(.system(size: 8.5, design: .monospaced)).lineSpacing(3).foregroundStyle(.white.opacity(0.5))
                }
            }.frame(width: 300)
        }
        .padding(16)
        .background {
            if let panel = session.hud.image("shot-panel") {
                Image(nsImage: panel).resizable().opacity(0.92).clipShape(RoundedRectangle(cornerRadius: 10))
            } else { panel }
        }
        .foregroundStyle(.white)
    }

    private var swingMeter: some View {
        VStack(spacing: 7) {
            HStack {
                Text(game.phase == .accuracy ? "ACCURACY" : "POWER").tracking(1.2)
                Spacer()
                Text(game.phase == .accuracy ? "CENTER = STRAIGHT" : game.phase == .power ? "\(Int((game.meter * 100).rounded()))%" : game.phase.inMotion ? "\(Int((game.shotPower * 100).rounded()))% · \(Int((game.lastShotDistance * 1.09361).rounded())) yd" : "THREE-CLICK SWING")
            }.font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.65))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.10))
                    if game.phase == .accuracy {
                        LinearGradient(colors: [Color.red.opacity(0.6), pgaGold.opacity(0.5), Color.green.opacity(0.7), pgaGold.opacity(0.5), Color.red.opacity(0.6)], startPoint: .leading, endPoint: .trailing).clipShape(RoundedRectangle(cornerRadius: 4))
                        Rectangle().fill(.white).frame(width: 2).offset(x: geometry.size.width / 2)
                        RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 5, height: 22).offset(x: (game.meter + 1) * 0.5 * (geometry.size.width - 5))
                    } else {
                        RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [Color(hex: "78B494"), pgaGold], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geometry.size.width * (game.phase == .power ? game.meter : game.shotPower))
                        ForEach(1..<4, id: \.self) { index in Rectangle().fill(.black.opacity(0.30)).frame(width: 1).offset(x: geometry.size.width * Double(index) / 4) }
                    }
                }
            }.frame(height: 16)
            Button { session.swing() } label: {
                HStack {
                    Text(game.phase == .power ? "LOCK POWER" : game.phase == .accuracy ? "STRIKE AT THE CENTER" : game.phase.inMotion ? "BALL IN PLAY" : "START SWING")
                    Spacer(); Text(session.controllerName == nil ? "SPACE / CLICK" : "A").opacity(0.6)
                }.font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(pgaInk).padding(11).background(pgaGold, in: RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain).disabled(game.phase.inMotion)
        }
    }

    private var mapCard: some View {
        VStack(spacing: 8) {
            HStack { Text("HOLE OVERVIEW").tracking(1); Spacer(); Text("\(game.holeIndex + 1) / \(game.course.holes.count)").foregroundStyle(pgaGold) }
                .font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.65))
            PGAMinimap(simulation: game, map: session.holeMap).frame(width: 175, height: 210).clipShape(RoundedRectangle(cornerRadius: 6))
            HStack { Text(session.isOriginal ? "ORIGINAL GEOMETRY" : "PRACTICE COURSE"); Spacer(); Text("● BALL").foregroundStyle(.white) }
                .font(.system(size: 7, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
        }.padding(12).frame(width: 200).background(panel)
    }

    private var bottomBar: some View {
        HStack {
            Text("NATIVE MAC RUNTIME").tracking(1.1); Text("·").padding(.horizontal, 3)
            Text(session.isOriginal ? "Original \(game.course.holes.count)-hole geometry, materials, tees and pins · approximate physics · no original vegetation, golfer or rules yet" : session.renderer.originalTexturesLoaded ? "Generated geometry · imported PGA grass textures · provisional physics" : "No emulation · generated geometry and provisional physics")
            Spacer()
            Button(showHelp ? "Hide controls" : "Show controls") { showHelp.toggle() }.buttonStyle(.plain)
        }.font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.65))
            .padding(.horizontal, 22).padding(.vertical, 10).background(pgaInk.opacity(0.92))
    }

    private var pauseOverlay: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 15) {
                Image(systemName: "pause.circle").font(.system(size: 33, weight: .light)).foregroundStyle(pgaGold)
                Text("Take your time").font(.system(size: 27, weight: .light))
                Text("Hole \(game.holeIndex + 1) · \(game.hole.name)").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                ForEach(Array(["Resume", "Restart hole", "Restart round", "Original course lab", "Return to hub"].enumerated()), id: \.offset) { index, label in
                    Button {
                        session.selectPauseItem(index - session.pauseSelection)
                        session.activatePauseSelection()
                    } label: {
                        HStack {
                            Text(label); Spacer()
                            if session.pauseSelection == index { Image(systemName: "arrow.right") }
                        }.font(.system(size: 12, weight: .medium)).padding(12)
                            .background(RoundedRectangle(cornerRadius: 6).fill(session.pauseSelection == index ? pgaGold : .white.opacity(0.04)))
                            .foregroundStyle(session.pauseSelection == index ? pgaInk : .white)
                    }.buttonStyle(.plain)
                }
                Text("↑ ↓ / Left stick to choose · Enter / A to select")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            }.padding(30).frame(width: 370).background(pgaInk, in: RoundedRectangle(cornerRadius: 15)).foregroundStyle(.white)
        }.ignoresSafeArea()
    }

    private var scoreOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 17) {
                Image(systemName: "flag.checkered").font(.system(size: 28)).foregroundStyle(pgaGold)
                Text(game.phase == .roundComplete ? (session.isOriginal ? "Round complete" : "Practice round complete") : game.message).font(.system(size: 25, weight: .light)).multilineTextAlignment(.center)
                VStack(spacing: 10) {
                    ForEach(Array(stride(from: 0, to: game.course.holes.count, by: 9)), id: \.self) { start in
                        HStack(spacing: 0) {
                            ForEach(start..<min(start + 9, game.course.holes.count), id: \.self) { index in
                                VStack(spacing: game.course.holes.count > 9 ? 6 : 9) {
                                    Text(game.course.holes.count > 9 ? "\(index + 1)" : "HOLE \(index + 1)").foregroundStyle(.white.opacity(0.5))
                                    Text(index < game.scores.count ? "\(game.scores[index])" : index == game.holeIndex && game.phase == .holed ? "\(game.strokes)" : "–")
                                        .font(.system(size: game.course.holes.count > 9 ? 17 : 25, weight: .light))
                                    Text(game.course.holes.count > 9 ? "\(game.course.holes[index].par)" : "PAR \(game.course.holes[index].par)").foregroundStyle(pgaGold)
                                }.font(.system(size: 9, weight: .semibold, design: .monospaced)).frame(maxWidth: .infinity)
                            }
                        }
                    }
                }.padding(18).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                if game.phase == .roundComplete {
                    Text("\(game.completedStrokes) strokes · \(game.scoreToPar == 0 ? "Even par" : game.scoreToPar > 0 ? "+\(game.scoreToPar)" : "\(game.scoreToPar)")")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
                    Button("Play again · Space / A") { session.restartRound() }.buttonStyle(.borderedProminent).tint(pgaGold).foregroundStyle(pgaInk)
                } else {
                    Button(game.holeIndex + 1 < game.course.holes.count ? "Next hole · Space / A" : "Finish round · Space / A") { session.nextHole() }
                        .buttonStyle(.borderedProminent).tint(pgaGold).foregroundStyle(pgaInk)
                }
                Button("Return to hub") { session.exit() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }.padding(28).frame(width: game.course.holes.count > 9 ? 470 : 400).background(pgaInk, in: RoundedRectangle(cornerRadius: 15)).foregroundStyle(.white)
        }.ignoresSafeArea()
    }

    private var originalScoreOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
            VStack(spacing: 14) {
                Text(game.phase == .roundComplete ? "Round complete · \(game.completedStrokes) strokes" : game.message)
                    .font(.system(size: 24, weight: .light)).foregroundStyle(.white)
                PGAOriginalScorecard(images: session.hud, simulation: game, playerName: "Player").frame(width: 760)
                HStack(spacing: 18) {
                    if game.phase == .roundComplete {
                        Button("Play again · Space / A") { session.restartRound() }.buttonStyle(.borderedProminent).tint(pgaGold).foregroundStyle(pgaInk)
                    } else {
                        Button(game.holeIndex + 1 < game.course.holes.count ? "Next hole · Space / A" : "Finish round · Space / A") { session.nextHole() }
                            .buttonStyle(.borderedProminent).tint(pgaGold).foregroundStyle(pgaInk)
                    }
                    Button("Return to hub") { session.exit() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }.ignoresSafeArea()
    }

    private func loadingOverlay(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(message).font(.system(size: 13)).multilineTextAlignment(.center)
                Text("Original course data is read from your local Library/Imported folder. Nothing is downloaded.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
            }.padding(28).frame(width: 420).background(pgaInk, in: RoundedRectangle(cornerRadius: 15)).foregroundStyle(.white)
        }.ignoresSafeArea()
    }

    private func failureOverlay(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 15) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 26)).foregroundStyle(pgaGold)
                Text("Original course unavailable").font(.system(size: 20, weight: .light))
                Text(message).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).textSelection(.enabled)
                Button("Return to hub") { session.exit() }.buttonStyle(.borderedProminent).tint(pgaGold).foregroundStyle(pgaInk)
            }.padding(28).frame(width: 460).background(pgaInk, in: RoundedRectangle(cornerRadius: 15)).foregroundStyle(.white)
        }.ignoresSafeArea()
    }

    private var panel: some View { RoundedRectangle(cornerRadius: 9).fill(pgaInk.opacity(0.91)).overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.12))) }
}

private struct PGASceneView: NSViewRepresentable {
    let session: PGAGameSession
    func makeNSView(context: Context) -> PGAInputView {
        let view = PGAInputView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.sceneDelegate = session.renderer
        session.attach(view)
        return view
    }
    func updateNSView(_ view: PGAInputView, context: Context) {}
    static func dismantleNSView(_ view: PGAInputView, coordinator: ()) { view.isPaused = true; view.sceneDelegate = nil; view.delegate = nil; view.session = nil }
}

private struct PGAMinimap: View {
    var simulation: PGASimulation
    var map: PGAHoleMap?
    var body: some View {
        if let map, simulation.course.isOriginal { original(map) } else { generated }
    }

    /// Rendered from the hole's own source triangles; the tee is at the bottom.
    private func original(_ map: PGAHoleMap) -> some View {
        Canvas { context, size in
            if let image = map.image { context.draw(Image(decorative: image, scale: 2), in: CGRect(origin: .zero, size: size)) }
            var path = Path(); path.addLines(simulation.hole.centerline.map { map.point($0, in: size) })
            context.stroke(path, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            let cup = map.point(simulation.hole.cup, in: size)
            context.fill(Path(ellipseIn: CGRect(x: cup.x - 2.5, y: cup.y - 2.5, width: 5, height: 5)), with: .color(pgaGold))
            let ball = map.point(simulation.ball, in: size)
            if !simulation.phase.inMotion {
                var aim = Path(); aim.move(to: ball)
                aim.addLine(to: map.point(simulation.ball + simulation.direction * min(simulation.targetDistance, simulation.distanceToCup + 30), in: size))
                context.stroke(aim, with: .color(pgaGold.opacity(0.85)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            let ballPath = Path(ellipseIn: CGRect(x: ball.x - 3.5, y: ball.y - 3.5, width: 7, height: 7))
            context.fill(ballPath, with: .color(.white)); context.stroke(ballPath, with: .color(pgaInk), lineWidth: 1)
        }
    }

    private var generated: some View {
        Canvas { context, size in
            let hole = simulation.hole
            let width = hole.maxX - hole.minX, depth = hole.maxZ - hole.minZ
            let scale = min(size.width / width, size.height / depth) * 0.93
            func point(_ v: PGAVector) -> CGPoint {
                CGPoint(x: (v.x - (hole.minX + hole.maxX) / 2) * scale + size.width / 2,
                        y: size.height / 2 - (v.z - (hole.minZ + hole.maxZ) / 2) * scale)
            }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: "344B30")))
            var fairway = Path(); fairway.addLines(hole.centerline.map(point))
            context.stroke(fairway, with: .color(Color(hex: "78995B")), style: StrokeStyle(lineWidth: hole.fairwayWidth * scale * 2, lineCap: .round, lineJoin: .round))
            for hazard in hole.hazards {
                let center = point(hazard.center)
                let rect = CGRect(x: center.x - hazard.radiusX * scale, y: center.y - hazard.radiusZ * scale, width: hazard.radiusX * scale * 2, height: hazard.radiusZ * scale * 2)
                context.fill(Path(ellipseIn: rect), with: .color(hazard.surface == .water ? Color(hex: "669FAC") : Color(hex: "D1C096")))
            }
            let cup = point(hole.cup)
            context.fill(Path(ellipseIn: CGRect(x: cup.x - hole.greenRadius * scale, y: cup.y - hole.greenRadius * scale, width: hole.greenRadius * scale * 2, height: hole.greenRadius * scale * 2)), with: .color(Color(hex: "A8BA7C")))
            context.fill(Path(ellipseIn: CGRect(x: cup.x - 2, y: cup.y - 2, width: 4, height: 4)), with: .color(pgaGold))
            let ball = point(simulation.ball)
            if !simulation.phase.inMotion {
                var aim = Path(); aim.move(to: ball); aim.addLine(to: point(simulation.ball + simulation.direction * min(simulation.targetDistance, simulation.distanceToCup + 30)))
                context.stroke(aim, with: .color(pgaGold.opacity(0.75)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            let ballPath = Path(ellipseIn: CGRect(x: ball.x - 3.5, y: ball.y - 3.5, width: 7, height: 7))
            context.fill(ballPath, with: .color(.white)); context.stroke(ballPath, with: .color(pgaInk), lineWidth: 1)
        }
    }
}
