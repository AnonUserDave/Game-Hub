import AppKit
import Combine
import GameController
import Metal
import SceneKit

/// Which course a golf session plays.
enum PGACourseChoice: Equatable {
    case practice
    /// Original course data prepared locally by Tools/prepare_pga2005.py.
    case original(code: String)
}

enum PGALoadState: Equatable {
    case ready
    case loading(String)
    case failed(String)
}

@MainActor
final class PGAGameSession: ObservableObject {
    @Published private(set) var simulation = PGASimulation()
    @Published private(set) var loadState = PGALoadState.ready
    @Published private(set) var holeMap: PGAHoleMap?
    @Published private(set) var loadReport = ""
    @Published var paused = false
    @Published private(set) var pauseSelection = 0
    @Published private(set) var cameraMode = 0
    @Published private(set) var controllerName: String?
    @Published private(set) var drawableDescription = "Retina drawable"
    @Published private(set) var frameRate = 0
    let renderer: PGARenderer
    var onExit: () -> Void
    private weak var view: PGAInputView?
    private var timer: Timer?
    private var eventMonitor: Any?
    private var focusObserver: NSObjectProtocol?
    private var heldKeys: Set<UInt16> = []
    private var previousButtons: [String: Bool] = [:]
    private var controllerID = "none"
    private var lastTick = 0.0
    private var hudTick = 0.0
    private var cameraZoom = 1.0
    private var lastHoleIndex = -1
    private var previousPhase = PGAPhase.aiming
    private var stopped = false
    private var pauseStickDirection = 0
    private var pauseStickRepeat = 0.0
    let choice: PGACourseChoice
    private var original: PGAOriginalPlayableCourse?
    private let textures = PGAOriginalTextureCache()
    private var loadTask: Task<Void, Never>?
    private var loadWork: Task<(PGAOriginalPlayableCourse, PGAOriginalHoleMesh, Double), Error>?
    private var prefetch: (index: Int, task: Task<PGAOriginalHoleMesh, Never>)?
    var onOriginalCourse: (() -> Void)?
    var isOriginal: Bool { if case .original = choice { return true }; return false }

    init(choice: PGACourseChoice = .practice, onExit: @escaping () -> Void) {
        renderer = PGARenderer(assetRoot: GameStore.workspaceRoot().appendingPathComponent("Library/Imported/pga2005/PBL"))
        self.choice = choice
        self.onExit = onExit
        if case .original = choice {
            loadState = .loading("Loading original course data off the main thread…")
        } else {
            renderer.build(hole: simulation.hole)
            lastHoleIndex = 0
        }
    }

    /// Loads the mapped course, builds 18 bounded floor indexes and the first
    /// hole's render buffers on a worker; the hub and UI stay responsive.
    private func loadOriginal() {
        guard case let .original(code) = choice, original == nil, loadTask == nil else { return }
        let root = GameStore.workspaceRoot()
        let started = ProcessInfo.processInfo.systemUptime
        loadState = .loading("Loading original \(code) terrain, materials, tees and pins…")
        let work = Task.detached(priority: .userInitiated) { () throws -> (PGAOriginalPlayableCourse, PGAOriginalHoleMesh, Double) in
            let course = try PGAOriginalPlayableCourse.load(code: code, root: root)
            let indexed = ProcessInfo.processInfo.systemUptime
            let saved = PGARoundStore.load(identity: course.course.identity)
            let mesh = PGAOriginalHoleMesh.build(course: course, holeIndex: saved?.holeIndex ?? 0)
            return (course, mesh, indexed - started)
        }
        loadWork = work
        loadTask = Task { [weak self] in
            defer { self?.loadTask = nil; self?.loadWork = nil }
            do {
                let (course, mesh, indexSeconds) = try await work.value
                guard let self, !self.stopped else { return }
                self.install(course, mesh: mesh, indexSeconds: indexSeconds, total: ProcessInfo.processInfo.systemUptime - started)
            } catch is CancellationError {
            } catch {
                self?.loadState = .failed("\(error.localizedDescription)\n\nPrepare original assets with `python3 Tools/prepare_pga2005.py`, then reopen.")
            }
        }
    }

    private func install(_ course: PGAOriginalPlayableCourse, mesh: PGAOriginalHoleMesh, indexSeconds: Double, total: Double) {
        original = course
        var game = PGASimulation(course: course.course, terrains: course.terrains)
        var restored = false
        if let saved = PGARoundStore.load(identity: course.course.identity) { restored = (try? game.restore(saved)) != nil }
        simulation = game
        showHole(mesh.holeIndex == game.holeIndex ? mesh : PGAOriginalHoleMesh.build(course: course, holeIndex: game.holeIndex))
        let checks = course.validation
        let tees = checks.filter { $0.teeSurface == .tee }.count, pins = checks.filter { $0.pinSurface == .green }.count
        loadReport = String(format: "Loaded in %.2f s (indexes %.2f s) · %d/%d tees on tee boxes · %d/%d pins on greens · %@%@",
                            total, indexSeconds, tees, checks.count, pins, checks.count, course.conditions.summary,
                            restored ? " · saved round restored" : "")
        loadState = .ready
    }

    private func showHole(_ mesh: PGAOriginalHoleMesh) {
        guard let original else { return }
        renderer.build(original: PGAOriginalSceneBuilder.node(for: mesh, course: original, textures: textures), hole: original.course.holes[mesh.holeIndex])
        holeMap = mesh.map
        lastHoleIndex = mesh.holeIndex
        view?.pointOfView = renderer.camera
        // Build the next hole's buffers in the background so the transition
        // after the scorecard does not stall a frame.
        let next = mesh.holeIndex + 1
        prefetch?.task.cancel(); prefetch = nil
        if next < original.course.holes.count {
            prefetch = (next, Task.detached(priority: .utility) { PGAOriginalHoleMesh.build(course: original, holeIndex: next) })
        }
    }

    private func saveRound() {
        guard isOriginal, original != nil else { return }
        if simulation.phase == .roundComplete { PGARoundStore.clear(identity: simulation.course.identity); return }
        if let snapshot = simulation.snapshot { PGARoundStore.save(snapshot) }
    }

    func attach(_ view: PGAInputView) {
        self.view = view
        view.scene = renderer.scene
        view.pointOfView = renderer.camera
        view.session = self
        view.drawableChanged = { [weak self] width, height in
            guard let self, width > 0, height > 0 else { return }
            guard self.renderer.renderTarget == nil else { return }
            let description = "\(width) × \(height) backing pixels · awaiting Metal frame"
            if self.drawableDescription != description { self.drawableDescription = description }
        }
        view.reportDrawable()
        renderer.update(simulation, cameraMode: cameraMode, zoom: cameraZoom, delta: 1)
    }

    func start() {
        guard timer == nil else { return }
        stopped = false
        previousButtons = [:]
        lastTick = ProcessInfo.processInfo.systemUptime
        loadOriginal()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { timer.invalidate(); return }
                self.tick()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, NSApp.isActive, self.view?.window?.isKeyWindow == true,
                      event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
                return self.handleKey(event)
            }
            return consumed ? nil : event
        }
        focusObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(true) }
        }
    }

    func stop() {
        saveRound()
        stopped = true
        loadTask?.cancel(); loadWork?.cancel(); prefetch?.task.cancel(); prefetch = nil
        timer?.invalidate(); timer = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }; eventMonitor = nil
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }; focusObserver = nil
        heldKeys.removeAll()
        view?.session = nil
    }

    func exit() { stop(); onExit() }
    func togglePause() { setPaused(!paused) }
    func setPaused(_ value: Bool) {
        if value && !paused { saveRound() }
        paused = value
        pauseSelection = 0
        pauseStickDirection = 0
        heldKeys.removeAll()
        lastTick = ProcessInfo.processInfo.systemUptime
    }

    func swing() {
        guard !paused, loadState == .ready else { return }
        if simulation.phase == .holed { nextHole(); return }
        if simulation.phase == .roundComplete { restartRound(); return }
        simulation.swing()
    }

    func changeClub(_ delta: Int) { guard !paused else { return }; simulation.changeClub(delta) }
    func aim(_ delta: Double) { guard !paused else { return }; simulation.aim(delta) }
    func autoAim() { guard !paused else { return }; simulation.alignToCup() }
    func cancelSwing() { simulation.cancelSwing() }
    func cycleCamera() { cameraMode = (cameraMode + 1) % 3 }
    func zoom(_ delta: Double) { cameraZoom = max(0.55, min(2.2, cameraZoom + delta)) }
    func fullscreen() { view?.window?.toggleFullScreen(nil) }
    func resetHole() { simulation.resetHole(); setPaused(false); renderer.resetCamera() }
    func restartRound() { simulation.restartRound(); setPaused(false); syncHole(); renderer.resetCamera(); saveRound() }
    func nextHole() { simulation.continueRound(); syncHole(); renderer.resetCamera(); saveRound() }
    func selectPauseItem(_ offset: Int) { pauseSelection = (pauseSelection + offset + 5) % 5 }
    func activatePauseSelection() {
        switch pauseSelection {
        case 1: resetHole()
        case 2: restartRound()
        case 3: onOriginalCourse?()
        case 4: exit()
        default: setPaused(false)
        }
    }

    private func syncHole() {
        guard lastHoleIndex != simulation.holeIndex else { return }
        if let original {
            let index = simulation.holeIndex
            if let prefetch, prefetch.index == index {
                let task = prefetch.task
                Task { [weak self] in
                    let mesh = await task.value
                    guard let self, self.simulation.holeIndex == index else { return }
                    self.showHole(mesh)
                }
            } else {
                showHole(PGAOriginalHoleMesh.build(course: original, holeIndex: index))
            }
            lastHoleIndex = index
            return
        }
        renderer.build(hole: simulation.hole)
        view?.pointOfView = renderer.camera
        lastHoleIndex = simulation.holeIndex
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let key = event.keyCode
        let used: Set<UInt16> = [0, 1, 2, 6, 8, 13, 15, 17, 3, 4, 36, 49, 53, 123, 124, 125, 126]
        guard used.contains(key) else { return false }
        if event.type == .keyUp { heldKeys.remove(key); return true }
        heldKeys.insert(key)
        guard !event.isARepeat else { return true }
        if paused {
            switch key {
            case 49, 36: activatePauseSelection()
            case 126, 13: selectPauseItem(-1)
            case 125, 1: selectPauseItem(1)
            case 53: setPaused(false)
            case 15: resetHole()
            case 3: fullscreen()
            default: break
            }
            return true
        }
        switch key {
        case 49, 36: if paused { setPaused(false) } else { swing() }
        case 53: if simulation.phase.swinging && !paused { cancelSwing() } else { togglePause() }
        case 13, 126: changeClub(-1)
        case 1, 125: changeClub(1)
        case 15: if paused || !simulation.phase.inMotion { resetHole() }
        case 8: cycleCamera()
        case 3: fullscreen()
        case 4: autoAim()
        default: break
        }
        return true
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = max(0.001, min(0.1, now - lastTick))
        lastTick = now
        pollController(delta: delta)
        guard !stopped else { return }
        if !paused && NSApp.isActive && loadState == .ready {
            let left = heldKeys.contains(123) || heldKeys.contains(0)
            let right = heldKeys.contains(124) || heldKeys.contains(2)
            if left != right { simulation.aim((right ? 1 : -1) * delta * 0.42) }
            simulation.update(deltaTime: delta)
        }
        if previousPhase != simulation.phase {
            if simulation.phase == .airborne || simulation.phase == .rolling { renderer.animateSwing() }
            previousPhase = simulation.phase
        }
        renderer.update(simulation, cameraMode: cameraMode, zoom: cameraZoom, delta: delta)
        hudTick += delta
        if hudTick > 0.25 {
            frameRate = renderer.measuredFramesPerSecond
            if let target = renderer.renderTarget {
                drawableDescription = "\(target.width) × \(target.height) Metal target · \(target.samples)× MSAA"
            }
            hudTick = 0
        }
    }

    private func pollController(delta: Double) {
        let input = PGAControllerInput.current()
        let sample = input.sample
        if controllerID != input.identity {
            controllerID = input.identity
            controllerName = input.name
            previousButtons = [:]
        }
        guard sample.connected, loadState == .ready else { return }
        let buttons = sample.buttons
        // Prime on connection: holding A to launch from the hub must not also
        // begin a swing when the native game takes over.
        if previousButtons.isEmpty { previousButtons = buttons; return }
        func pressed(_ name: String) -> Bool { buttons[name] == true && previousButtons[name] != true }
        defer { previousButtons = buttons }
        guard NSApp.isActive else { return }
        if pressed("Menu") { togglePause(); return }
        if pressed("B") { if simulation.phase.swinging && !paused { cancelSwing() } else { togglePause() } }
        if paused {
            if pressed("A") { activatePauseSelection(); return }
            if pressed("Y") { resetHole(); return }
            if pressed("Up") { selectPauseItem(-1) }
            if pressed("Down") { selectPauseItem(1) }
            let y = sample.axes[1]
            let direction = y > 0.6 ? -1 : y < -0.6 ? 1 : 0
            let now = ProcessInfo.processInfo.systemUptime
            if direction != pauseStickDirection {
                pauseStickDirection = direction; pauseStickRepeat = now + 0.4
                if direction != 0 { selectPauseItem(direction) }
            } else if direction != 0 && now >= pauseStickRepeat {
                pauseStickRepeat = now + 0.16; selectPauseItem(direction)
            }
            return
        }
        if pressed("A") { swing() }
        if pressed("X") { cycleCamera() }
        if pressed("Y") { if paused { resetHole() } else { autoAim() } }
        if pressed("LB") || pressed("Up") { changeClub(-1) }
        if pressed("RB") || pressed("Down") { changeClub(1) }
        guard !paused else { return }
        let x = sample.axes[0]
        let dpad: Float = (buttons["Right"] == true ? 1 : 0) - (buttons["Left"] == true ? 1 : 0)
        if abs(x) > 0.18 { simulation.aim(Double(x) * delta * 0.52) }
        else if abs(dpad) > 0.5 { simulation.aim(Double(dpad) * delta * 0.3) }
        let zoomInput = sample.axes[3]
        if abs(zoomInput) > 0.2 { zoom(-Double(zoomInput) * delta * 0.7) }
    }
}

@MainActor
final class PGAInputView: PGAMetalView {
    weak var session: PGAGameSession?
    var drawableChanged: ((Int, Int) -> Void)?
    private var lastDrag: NSPoint?
    private var didDrag = false
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        reportDrawable()
    }
    override func layout() { super.layout(); reportDrawable() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); reportDrawable() }
    func reportDrawable() {
        let pixels = convertToBacking(bounds.size)
        drawableChanged?(Int(pixels.width.rounded()), Int(pixels.height.rounded()))
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastDrag = event.locationInWindow; didDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let lastDrag else { return }
        let dx = event.locationInWindow.x - lastDrag.x
        if abs(dx) > 0.5 {
            didDrag = true
            session?.aim(Double(dx) * 0.003)
        }
        self.lastDrag = event.locationInWindow
    }
    override func mouseUp(with event: NSEvent) {
        if !didDrag { session?.swing() }
        lastDrag = nil
    }
    override func rightMouseDown(with event: NSEvent) { session?.togglePause() }
    override func scrollWheel(with event: NSEvent) {
        session?.zoom(Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.002 : 0.025))
    }
}

/// SceneKit's native Metal renderer draws directly at the NSView backing size.
/// There is no 1280×800 render target or post-render upscale in this module.
final class PGARenderer: NSObject, SCNSceneRendererDelegate {
    struct RenderTarget: Equatable {
        var width: Int
        var height: Int
        var samples: Int
    }
    let scene = SCNScene()
    let camera = SCNNode()
    private let ball = SCNNode()
    private let ballShadow = SCNNode()
    private let aimMarker = SCNNode()
    private let golfer = SCNNode()
    private let clubPivot = SCNNode()
    private var content = SCNNode()
    private var flag = SCNNode()
    private var cameraPosition = PGAVector.zero
    private var cameraTarget = PGAVector.zero
    private var freshCamera = true
    private var frameSamples: [Double] = []
    private let frameLock = NSLock()
    private var storedFPS = 0
    private var storedTarget: RenderTarget?
    private let originalGrass: NSImage?
    private let originalRough: NSImage?
    var originalTexturesLoaded: Bool { originalGrass != nil }
    var measuredFramesPerSecond: Int { frameLock.lock(); defer { frameLock.unlock() }; return storedFPS }
    var renderTarget: RenderTarget? { frameLock.lock(); defer { frameLock.unlock() }; return storedTarget }

    init(assetRoot: URL? = nil) {
        let rough = assetRoot.flatMap { NSImage(contentsOf: $0.appendingPathComponent("PBLROUGH.png")) }
        originalGrass = rough.map { Self.opaqueTexture($0, background: NSColor(calibratedRed: 0.43, green: 0.55, blue: 0.24, alpha: 1)) }
        originalRough = rough.map { Self.opaqueTexture($0, background: NSColor(calibratedRed: 0.30, green: 0.42, blue: 0.18, alpha: 1)) }
        super.init()
        scene.background.contents = Self.skyImage()
        scene.fogStartDistance = 360
        scene.fogEndDistance = 1200
        scene.fogColor = NSColor(calibratedRed: 0.69, green: 0.82, blue: 0.88, alpha: 1)
        let cameraSettings = SCNCamera()
        cameraSettings.fieldOfView = 56
        cameraSettings.zNear = 0.12; cameraSettings.zFar = 1600
        cameraSettings.wantsHDR = false; cameraSettings.wantsExposureAdaptation = false
        cameraSettings.bloomIntensity = 0
        camera.camera = cameraSettings
        scene.rootNode.addChildNode(camera)
        let sunlight = SCNLight()
        sunlight.type = .directional
        sunlight.intensity = 1200
        sunlight.color = NSColor(calibratedRed: 1, green: 0.94, blue: 0.80, alpha: 1)
        sunlight.castsShadow = true
        sunlight.shadowMode = .deferred
        sunlight.shadowMapSize = CGSize(width: 2048, height: 2048)
        sunlight.shadowSampleCount = 8
        sunlight.shadowRadius = 2
        sunlight.maximumShadowDistance = 180
        sunlight.shadowColor = NSColor.black.withAlphaComponent(0.25)
        let sun = SCNNode(); sun.light = sunlight
        sun.eulerAngles = SCNVector3(-Float.pi * 0.36, -0.65, 0)
        scene.rootNode.addChildNode(sun)
        let ambient = SCNNode(); ambient.light = SCNLight()
        ambient.light?.type = .ambient; ambient.light?.intensity = 700
        ambient.light?.color = NSColor(calibratedRed: 0.71, green: 0.82, blue: 0.93, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let ballGeometry = SCNSphere(radius: 0.13)
        ballGeometry.segmentCount = 20
        ballGeometry.firstMaterial = Self.material(NSColor.white, roughness: 0.48)
        ball.geometry = ballGeometry; ball.castsShadow = true
        scene.rootNode.addChildNode(ball)
        let shadow = SCNCylinder(radius: 0.20, height: 0.008)
        shadow.radialSegmentCount = 24
        shadow.firstMaterial = Self.material(NSColor.black.withAlphaComponent(0.23))
        ballShadow.geometry = shadow
        scene.rootNode.addChildNode(ballShadow)
        let ring = SCNTorus(ringRadius: 1.8, pipeRadius: 0.10)
        ring.ringSegmentCount = 40; ring.pipeSegmentCount = 6
        ring.firstMaterial = Self.material(NSColor(calibratedRed: 0.98, green: 0.82, blue: 0.33, alpha: 1))
        aimMarker.geometry = ring
        scene.rootNode.addChildNode(aimMarker)
        makeGolfer()
        scene.rootNode.addChildNode(golfer)
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        frameLock.lock()
        frameSamples.append(time)
        frameSamples.removeAll { time - $0 > 1 }
        if let first = frameSamples.first, time - first > 0.4 {
            storedFPS = Int((Double(frameSamples.count - 1) / (time - first)).rounded())
        }
        frameLock.unlock()
    }

    func renderer(_ renderer: SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        guard let attachment = renderer.currentRenderPassDescriptor.colorAttachments[0],
              let color = attachment.texture else { return }
        let drawable = attachment.resolveTexture ?? color
        let target = RenderTarget(width: drawable.width, height: drawable.height, samples: color.sampleCount)
        frameLock.lock(); storedTarget = target; frameLock.unlock()
    }

    /// Original course hole: decoded source triangles and textures only. No
    /// generated trees or sea are added; original vegetation is not decoded yet.
    func build(original terrain: SCNNode, hole: PGAHole) {
        content.removeFromParentNode(); content = SCNNode(); scene.rootNode.addChildNode(content)
        content.addChildNode(terrain)
        makeFlag(pin: hole.cup)
        freshCamera = true
    }

    func build(hole: PGAHole) {
        content.removeFromParentNode(); content = SCNNode(); scene.rootNode.addChildNode(content)
        content.addChildNode(makeTerrain(hole: hole))
        makeTrees(hole: hole)
        makeFlag(pin: hole.position(x: hole.cup.x, z: hole.cup.z))
        // A distant sea and ridge provide depth while preserving a quiet,
        // naturalistic golf-course palette; they are generated development art.
        let sea = SCNPlane(width: 2500, height: 2500)
        sea.firstMaterial = Self.material(NSColor(calibratedRed: 0.30, green: 0.57, blue: 0.65, alpha: 1))
        let seaNode = SCNNode(geometry: sea)
        seaNode.eulerAngles.x = -.pi / 2; seaNode.position = SCNVector3(-950, -2.7, 250)
        content.addChildNode(seaNode)
        freshCamera = true
    }

    func resetCamera() { freshCamera = true }

    func update(_ simulation: PGASimulation, cameraMode: Int, zoom: Double, delta: Double) {
        let position = simulation.ball
        let hole = simulation.hole
        let direction = simulation.direction
        let ground = simulation.groundHeight(x: position.x, z: position.z, near: position.y)
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0; SCNTransaction.disableActions = true
        ball.position = Self.vector(position + PGAVector(x: 0, y: 0.10, z: 0))
        ball.isHidden = simulation.phase == .holed || simulation.phase == .roundComplete
        let visualScale = simulation.phase.inMotion ? max(1, min(2.5, (position.y - ground) / 14)) : 1
        ball.scale = SCNVector3(visualScale, visualScale, visualScale)
        ballShadow.position = SCNVector3(position.x, ground + 0.025, position.z)
        ballShadow.isHidden = ball.isHidden
        let targetDistance = min(simulation.targetDistance, simulation.distanceToCup + 45)
        let target = position + direction * targetDistance
        aimMarker.position = SCNVector3(target.x, simulation.groundHeight(x: target.x, z: target.z, near: position.y + 30) + 0.12, target.z)
        aimMarker.isHidden = simulation.phase.inMotion || simulation.phase == .holed || simulation.phase == .roundComplete
        aimMarker.scale = simulation.club == .putter ? SCNVector3(0.4, 1, 0.4) : SCNVector3(1, 1, 1)
        golfer.isHidden = simulation.phase.inMotion || simulation.phase == .holed || cameraMode == 2
        let side = PGAVector(x: -direction.z, y: 0, z: direction.x)
        let golferPosition = position + side * 1.1 + direction * -0.15
        golfer.position = SCNVector3(golferPosition.x, simulation.groundHeight(x: golferPosition.x, z: golferPosition.z, near: position.y), golferPosition.z)
        golfer.eulerAngles.y = CGFloat(simulation.heading)
        if simulation.phase == .power { clubPivot.eulerAngles.z = CGFloat(-simulation.meter * 1.6) }
        else if simulation.phase == .aiming { clubPivot.eulerAngles.z = 0 }

        let desiredPosition: PGAVector
        let desiredTarget: PGAVector
        if cameraMode == 2 {
            // Overview from behind the tee along this hole's own direction.
            let middle = (hole.tee + hole.cup) * 0.5
            let along = (hole.cup - hole.tee).horizontalUnit, right = PGAVector(x: -along.z, y: 0, z: along.x)
            desiredPosition = middle + right * 45 - along * (hole.length * 0.24 * zoom) + PGAVector(x: 0, y: hole.length * 0.68 * zoom, z: 0)
            desiredTarget = middle
        } else if simulation.phase.inMotion {
            let flightDirection = simulation.velocity.horizontalLength > 0.5 ? simulation.velocity.horizontalUnit : direction
            desiredPosition = position - flightDirection * (18 * zoom) + PGAVector(x: 0, y: 8 * zoom, z: 0)
            desiredTarget = position + flightDirection * 14 + PGAVector(x: 0, y: 1, z: 0)
        } else if simulation.club == .putter && cameraMode == 0 {
            desiredPosition = position - direction * (8 * zoom) + PGAVector(x: 0, y: 3.2 * zoom, z: 0)
            desiredTarget = position + direction * min(10, simulation.distanceToCup) + PGAVector(x: 0, y: 0.2, z: 0)
        } else {
            desiredPosition = position - direction * ((cameraMode == 0 ? 13 : 35) * zoom)
                + PGAVector(x: 0, y: (cameraMode == 0 ? 5.5 : 19) * zoom, z: 0)
            desiredTarget = position + direction * 75 + PGAVector(x: 0, y: 2, z: 0)
        }
        let alpha = freshCamera ? 1 : 1 - exp(-delta * (simulation.phase.inMotion ? 3.5 : 5))
        cameraPosition = cameraPosition + (desiredPosition - cameraPosition) * alpha
        cameraTarget = cameraTarget + (desiredTarget - cameraTarget) * alpha
        cameraPosition.y = max(cameraPosition.y, simulation.groundHeight(x: cameraPosition.x, z: cameraPosition.z, near: cameraPosition.y) + 1.4)
        camera.position = Self.vector(cameraPosition)
        camera.look(at: Self.vector(cameraTarget))
        freshCamera = false
        SCNTransaction.commit()
    }

    func animateSwing() {
        clubPivot.removeAllActions()
        clubPivot.runAction(.sequence([.rotateTo(x: 0, y: 0, z: 1.7, duration: 0.18), .wait(duration: 0.2), .rotateTo(x: 0, y: 0, z: 0, duration: 0.4)]))
    }

    private func makeTerrain(hole: PGAHole) -> SCNNode {
        let spacing = 2.8
        let columns = Int(ceil((hole.maxX - hole.minX) / spacing)) + 1
        let rows = Int(ceil((hole.maxZ - hole.minZ) / spacing)) + 1
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var colors: [Float] = []
        var textureCoordinates: [CGPoint] = []
        vertices.reserveCapacity(columns * rows); normals.reserveCapacity(columns * rows)
        let surfaces: [PGASurface] = [.rough, .fairway, .green, .tee, .sand, .water, .out]
        var batches = Array(repeating: [Int32](), count: surfaces.count * 2)
        for row in 0..<rows {
            for column in 0..<columns {
                let x = hole.minX + Double(column) * spacing, z = hole.minZ + Double(row) * spacing
                let h = hole.height(x: x, z: z)
                vertices.append(SCNVector3(x, h, z))
                textureCoordinates.append(CGPoint(x: x / 2.5, y: z / 2.5))
                let gradient = hole.gradient(x: x, z: z)
                let n = PGAVector(x: -gradient.x, y: 1, z: -gradient.z)
                normals.append(Self.vector(n * (1 / n.length)))
                let grain = Float(0.94 + 0.06 * sin(x * 2.13 + z * 5.8) * sin(z * 3.1 - x * 0.4))
                colors.append(contentsOf: [grain, grain, grain, 1])
            }
        }
        for row in 0..<(rows - 1) {
            for column in 0..<(columns - 1) {
                let x = hole.minX + (Double(column) + 0.5) * spacing, z = hole.minZ + (Double(row) + 0.5) * spacing
                let surface = hole.surface(x: x, z: z)
                let material = (surfaces.firstIndex(of: surface) ?? 0) * 2 + (Int(floor(z / 11)) % 2 == 0 ? 0 : 1)
                let i = Int32(row * columns + column), c = Int32(columns)
                batches[material].append(contentsOf: [i, i + c, i + 1, i + 1, i + c, i + c + 1])
            }
        }
        let colorSource = colors.withUnsafeBufferPointer { buffer -> SCNGeometrySource in
            SCNGeometrySource(data: Data(buffer: buffer), semantic: .color, vectorCount: vertices.count,
                              usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        }
        let elements = batches.map { SCNGeometryElement(indices: $0, primitiveType: .triangles) }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals),
                                             SCNGeometrySource(textureCoordinates: textureCoordinates), colorSource], elements: elements)
        let palette: [(Double, Double, Double)] = [(0.24, 0.38, 0.14), (0.32, 0.49, 0.18), (0.42, 0.58, 0.25), (0.36, 0.52, 0.20), (0.80, 0.73, 0.52), (0.25, 0.48, 0.55), (0.25, 0.37, 0.16)]
        geometry.materials = palette.flatMap { r, g, b in
            [Self.material(NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)),
             Self.material(NSColor(calibratedRed: r * 0.94, green: g * 0.94, blue: b * 0.94, alpha: 1))]
        }
        // Use the user's decoded original grass bitmaps when available. This
        // preserves those source colors/details without claiming original mesh,
        // terrain placement, UV layout, or engine shading has been reconstructed.
        for (index, material) in geometry.materials.enumerated() {
            let surface = surfaces[index / 2]
            let texture = surface == .rough || surface == .out ? originalRough :
                [.fairway, .green, .tee].contains(surface) ? originalGrass : nil
            guard let texture else { continue }
            material.diffuse.contents = texture
            material.diffuse.wrapS = .repeat; material.diffuse.wrapT = .repeat
            material.diffuse.magnificationFilter = .linear
            material.diffuse.minificationFilter = .linear; material.diffuse.mipFilter = .linear
            material.diffuse.maxAnisotropy = 8
            let stripe = index % 2 == 0 ? 1.0 : 0.92
            let tint = surface == .green ? (0.79, 0.88, 0.68) : surface == .fairway || surface == .tee ? (0.71, 0.83, 0.60) : (0.55, 0.65, 0.48)
            material.multiply.contents = NSColor(calibratedRed: tint.0 * stripe, green: tint.1 * stripe, blue: tint.2 * stripe, alpha: 1)
        }
        let node = SCNNode(geometry: geometry)
        node.castsShadow = false
        return node
    }

    private func makeTrees(hole: PGAHole) {
        let forest = SCNNode()
        forest.name = "Development forest"
        let trunkMaterial = Self.material(NSColor(calibratedRed: 0.25, green: 0.22, blue: 0.15, alpha: 1))
        let leafMaterial = Self.material(NSColor(calibratedRed: 0.14, green: 0.27, blue: 0.14, alpha: 1))
        let trunkGeometry = SCNCylinder(radius: 0.23, height: 1)
        trunkGeometry.radialSegmentCount = 6; trunkGeometry.firstMaterial = trunkMaterial
        let canopyGeometry = SCNSphere(radius: 1)
        canopyGeometry.segmentCount = 10; canopyGeometry.firstMaterial = leafMaterial
        var seed = UInt64((hole.terrainSeed * 1000).rounded())
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 32) & 0xffffff) / Double(0xffffff)
        }
        for _ in 0..<240 {
            let x = hole.minX + random() * (hole.maxX - hole.minX)
            let z = hole.minZ + random() * (hole.maxZ - hole.minZ)
            guard hole.surface(x: x, z: z) == .rough,
                  hypot(x - hole.tee.x, z - hole.tee.z) > 65,
                  hypot(x - hole.cup.x, z - hole.cup.z) > hole.greenRadius + 25 else { continue }
            // Leave a buffer along the fairway rather than placing trees in the
            // hitting corridor. Original course vegetation will replace this.
            let neighboring = [-20.0, 0, 20].flatMap { dx in [-20.0, 0, 20].map { dz in hole.surface(x: x + dx, z: z + dz) } }
            guard neighboring.allSatisfy({ $0 == .rough || $0 == .out }) else { continue }
            let tree = SCNNode()
            tree.name = "Development tree \(forest.childNodes.count + 1)"
            let height = 7 + random() * 6, radius = 2.8 + random() * 1.7
            let trunkNode = SCNNode(geometry: trunkGeometry)
            trunkNode.scale.y = CGFloat(height * 0.7)
            trunkNode.position.y = CGFloat(height * 0.35)
            tree.addChildNode(trunkNode)
            for level in 0..<3 {
                let canopyNode = SCNNode(geometry: canopyGeometry)
                let size = radius * (1 - Double(level) * 0.12)
                canopyNode.scale = SCNVector3(size * 1.2, size * 0.72, size * 0.95)
                canopyNode.position = SCNVector3(Double(level - 1) * 0.7, height * 0.60 + Double(level) * 1.0, 0)
                tree.addChildNode(canopyNode)
            }
            tree.position = SCNVector3(x, hole.height(x: x, z: z), z)
            forest.addChildNode(tree)
        }
        // SceneKit's flattening collapsed the freshly constructed primitive
        // nodes to the origin on the observed Mac. Keep authored transforms and
        // share the primitive geometry objects instead of baking that hierarchy.
        content.addChildNode(forest)
    }

    private func makeFlag(pin: PGAVector) {
        let cup = SCNCylinder(radius: 0.24, height: 0.013)
        cup.firstMaterial = Self.material(NSColor(calibratedWhite: 0.1, alpha: 1))
        let cupNode = SCNNode(geometry: cup); cupNode.position = Self.vector(pin + PGAVector(x: 0, y: 0.018, z: 0))
        content.addChildNode(cupNode)
        let pole = SCNCylinder(radius: 0.035, height: 3.8); pole.radialSegmentCount = 8
        pole.firstMaterial = Self.material(.white)
        let poleNode = SCNNode(geometry: pole); poleNode.position = Self.vector(pin + PGAVector(x: 0, y: 1.9, z: 0))
        content.addChildNode(poleNode)
        let flagGeometry = SCNGeometry(sources: [SCNGeometrySource(vertices: [SCNVector3(0, 0, 0), SCNVector3(1.1, -0.24, 0.08), SCNVector3(0, -0.6, 0)])],
                                       elements: [SCNGeometryElement(indices: [Int32(0), 1, 2], primitiveType: .triangles)])
        let flagMaterial = Self.material(NSColor(calibratedRed: 0.86, green: 0.20, blue: 0.13, alpha: 1)); flagMaterial.isDoubleSided = true
        flagGeometry.firstMaterial = flagMaterial
        flag = SCNNode(geometry: flagGeometry); flag.position = Self.vector(pin + PGAVector(x: 0, y: 3.75, z: 0))
        content.addChildNode(flag)
        flag.runAction(.repeatForever(.sequence([.rotateTo(x: 0, y: 0.12, z: 0.02, duration: 1.2), .rotateTo(x: 0, y: -0.08, z: -0.02, duration: 1.4)])))
    }

    private func makeGolfer() {
        let blue = Self.material(NSColor(calibratedRed: 0.16, green: 0.32, blue: 0.54, alpha: 1))
        let cream = Self.material(NSColor(calibratedRed: 0.89, green: 0.88, blue: 0.79, alpha: 1))
        let skin = Self.material(NSColor(calibratedRed: 0.72, green: 0.51, blue: 0.34, alpha: 1))
        func capsule(radius: CGFloat, height: CGFloat, material: SCNMaterial, x: Float, y: Float, z: Float) -> SCNNode {
            let geometry = SCNCapsule(capRadius: radius, height: height); geometry.radialSegmentCount = 10
            geometry.firstMaterial = material
            let node = SCNNode(geometry: geometry); node.position = SCNVector3(x, y, z); return node
        }
        let body = capsule(radius: 0.23, height: 0.65, material: blue, x: 0, y: 1.2, z: 0)
        body.eulerAngles.z = -0.15; golfer.addChildNode(body)
        golfer.addChildNode(capsule(radius: 0.10, height: 0.87, material: cream, x: -0.14, y: 0.48, z: -0.22))
        golfer.addChildNode(capsule(radius: 0.10, height: 0.87, material: cream, x: -0.14, y: 0.48, z: 0.22))
        let head = SCNSphere(radius: 0.145); head.segmentCount = 12; head.firstMaterial = skin
        let headNode = SCNNode(geometry: head); headNode.position = SCNVector3(0.12, 1.64, 0); golfer.addChildNode(headNode)
        let cap = SCNSphere(radius: 0.153); cap.segmentCount = 12; cap.firstMaterial = cream
        let capNode = SCNNode(geometry: cap); capNode.position = SCNVector3(0.12, 1.72, 0); capNode.scale.y = 0.50; golfer.addChildNode(capNode)
        for z: Float in [-0.22, 0.22] {
            let arm = capsule(radius: 0.07, height: 0.60, material: skin, x: 0.26, y: 1.1, z: z)
            arm.eulerAngles.z = 0.60; golfer.addChildNode(arm)
        }
        clubPivot.position = SCNVector3(0.45, 0.94, 0)
        let shaft = SCNCylinder(radius: 0.013, height: 1.15); shaft.radialSegmentCount = 6
        shaft.firstMaterial = Self.material(NSColor.lightGray, roughness: 0.2)
        let shaftNode = SCNNode(geometry: shaft); shaftNode.position = SCNVector3(0.28, -0.49, 0); shaftNode.eulerAngles.z = 0.52
        clubPivot.addChildNode(shaftNode)
        let clubHead = SCNBox(width: 0.15, height: 0.09, length: 0.13, chamferRadius: 0.025)
        clubHead.firstMaterial = Self.material(.darkGray, roughness: 0.25)
        let clubHeadNode = SCNNode(geometry: clubHead); clubHeadNode.position = SCNVector3(0.57, -0.99, 0)
        clubPivot.addChildNode(clubHeadNode); golfer.addChildNode(clubPivot)
    }

    private static func material(_ color: NSColor, roughness: CGFloat = 1) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .blinn
        material.shininess = roughness < 0.5 ? 0.3 : 0
        material.specular.contents = NSColor(white: roughness < 0.5 ? 0.35 : 0.025, alpha: 1)
        material.roughness.contents = roughness
        return material
    }
    private static func vector(_ v: PGAVector) -> SCNVector3 { SCNVector3(v.x, v.y, v.z) }
    private static func skyImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 1024, height: 512))
        image.lockFocus()
        let colors = [NSColor(calibratedRed: 0.76, green: 0.85, blue: 0.89, alpha: 1),
                      NSColor(calibratedRed: 0.37, green: 0.65, blue: 0.83, alpha: 1)]
        NSGradient(colors: colors)?.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 512), angle: 90)
        image.unlockFocus()
        return image
    }
    private static func opaqueTexture(_ source: NSImage, background: NSColor) -> NSImage {
        let result = NSImage(size: source.size)
        result.lockFocus()
        background.setFill(); NSRect(origin: .zero, size: source.size).fill()
        source.draw(in: NSRect(origin: .zero, size: source.size))
        result.unlockFocus()
        return result
    }
}
