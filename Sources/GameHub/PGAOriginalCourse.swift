import AppKit
import Combine
import GameController
import SceneKit
import SwiftUI

/// Source-bound terrain inspection, separate from the provisional golf game.
/// GHPC v1 holds original points; v2 adds decoded, globally indexed triangles
/// and the original terrain IDs. It never manufactures replacement triangles.
struct PGAOriginalTerrain {
    struct Batch {
        var terrainID: UInt32
        var indices: Data
        var triangles: Int
    }
    var source: Data
    var sourceURL: URL
    var report: String
    var headerBytes: Int
    var sourceVertices: Int
    var displayedVertices: Int
    var triangleCount: Int
    var groupCount: Int
    var boundsMin: PGAVector
    var boundsMax: PGAVector
    var colors: Data
    var elevationColors: Data
    var normals: Data?
    var batches: [Batch]
    var sampled: Bool
    var formatVersion: Int
    var materialTextures: [UInt32: URL]
    var materialNames: [UInt32: String]
    var positionOffset: Int { headerBytes }
    var center: PGAVector { (boundsMin + boundsMax) * 0.5 }
    var extent: PGAVector { boundsMax - boundsMin }

    enum ImportError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(message) = self { return message }; return nil
        }
    }

    static func load(_ url: URL) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 300_000_000 else {
            throw ImportError.invalid("Terrain file exceeds the 300 MB development-viewer limit.")
        }
        let mapped = try Data(contentsOf: url, options: .mappedIfSafe)
        guard mapped.count >= 36, Array(mapped.prefix(4)) == [0x47, 0x48, 0x50, 0x43] else {
            throw ImportError.invalid("Expected an original-course GHPC terrain file.")
        }
        return try mapped.withUnsafeBytes { bytes in
            func uint(_ offset: Int) -> UInt32 { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            func float(_ offset: Int) -> Float { Float(bitPattern: uint(offset)) }
            let version = Int(uint(4))
            guard version == 1 || version == 2 else { throw ImportError.invalid("Unsupported terrain format version \(version).") }
            let header = version == 1 ? 36 : 44
            guard mapped.count >= header else { throw ImportError.invalid("Terrain header is incomplete.") }
            let vertices = Int(uint(8)), triangles = version == 2 ? Int(uint(12)) : 0
            let groups = version == 2 ? Int(uint(16)) : 0
            guard vertices > 0, vertices <= 2_000_000, triangles <= 4_000_000, groups <= 1_000_000 else {
                throw ImportError.invalid("Terrain counts exceed the viewer limits or contain no vertices.")
            }
            let expected = header + vertices * 24 + triangles * 16
            guard mapped.count == expected else { throw ImportError.invalid("Terrain byte count does not match its declared vertices and triangles.") }
            let boundsOffset = version == 1 ? 12 : 20
            let values = (0..<6).map { Double(float(boundsOffset + $0 * 4)) }
            guard values.allSatisfy(\.isFinite) else { throw ImportError.invalid("Terrain bounds contain a non-finite coordinate.") }
            let minimum = PGAVector(x: values[0], y: values[1], z: values[2])
            let maximum = PGAVector(x: values[3], y: values[4], z: values[5])
            let extent = maximum - minimum
            guard extent.x > 0, extent.z > 0, extent.y >= 0 else { throw ImportError.invalid("Terrain bounds have no usable horizontal extent.") }
            // A point-only file can be sampled without inventing positions. A
            // mesh retains every vertex because its original topology depends
            // on global indices. Current Pebble Beach fits within these limits.
            let step = triangles == 0 ? max(1, Int(ceil(Double(vertices) / 1_000_000))) : 1
            let rendered = (vertices + step - 1) / step
            var retained = mapped
            var headerOffset = header
            if step > 1 {
                var compact = Data(count: rendered * 24)
                compact.withUnsafeMutableBytes { target in
                    for index in 0..<rendered {
                        let origin = header + index * step * 24
                        target.baseAddress!.advanced(by: index * 24).copyMemory(from: bytes.baseAddress!.advanced(by: origin), byteCount: 24)
                    }
                }
                retained = compact; headerOffset = 0
            }
            var colors = Data(count: rendered * 16), elevation = Data(count: rendered * 16)
            try colors.withUnsafeMutableBytes { colorBytes in
                try elevation.withUnsafeMutableBytes { elevationBytes in
                    for index in 0..<rendered {
                        if index % 65_536 == 0 { try Task.checkCancellation() }
                        let offset = header + index * step * 24
                        let x = float(offset), y = float(offset + 4), z = float(offset + 8)
                        guard x.isFinite, y.isFinite, z.isFinite else { throw ImportError.invalid("A terrain vertex contains a non-finite coordinate.") }
                        for component in 0..<4 {
                            let value = Float(bytes[offset + 12 + component]) / 255
                            colorBytes.storeBytes(of: value, toByteOffset: index * 16 + component * 4, as: Float.self)
                        }
                        let h = Float(max(0, min(1, (Double(y) - minimum.y) / max(0.001, extent.y))))
                        let r: Float = 0.16 + 0.82 * h
                        let g: Float = 0.36 + 0.43 * (1 - abs(2 * h - 1))
                        let b: Float = 0.72 - 0.52 * h
                        for (component, value) in [r, g, b, 1].enumerated() {
                            elevationBytes.storeBytes(of: value, toByteOffset: index * 16 + component * 4, as: Float.self)
                        }
                    }
                }
            }
            var batches: [Batch] = []
            var normalData: Data?
            if triangles > 0 {
                var groupsByTerrain: [UInt32: [UInt32]] = [:]
                var normals = Array(repeating: Float(0), count: vertices * 3)
                let start = header + vertices * 24
                func position(_ index: Int) -> (Float, Float, Float) {
                    let offset = header + index * 24
                    return (float(offset), float(offset + 4), float(offset + 8))
                }
                for index in 0..<triangles {
                    if index % 65_536 == 0 { try Task.checkCancellation() }
                    let offset = start + index * 16
                    let a = uint(offset), b = uint(offset + 4), c = uint(offset + 8), terrain = uint(offset + 12)
                    guard a < vertices, b < vertices, c < vertices else { throw ImportError.invalid("Triangle index references a vertex outside the source file.") }
                    guard groupsByTerrain.count < 256 || groupsByTerrain[terrain] != nil else { throw ImportError.invalid("Terrain contains more than 256 material IDs.") }
                    groupsByTerrain[terrain, default: []].append(contentsOf: [a.littleEndian, b.littleEndian, c.littleEndian])
                    let p = position(Int(a)), q = position(Int(b)), r = position(Int(c))
                    let ux = q.0 - p.0, uy = q.1 - p.1, uz = q.2 - p.2
                    let vx = r.0 - p.0, vy = r.1 - p.1, vz = r.2 - p.2
                    var nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx
                    // Mesh winding remains under investigation. Keep exact
                    // source triangles and orient shading normals upward only.
                    if ny < 0 { nx = -nx; ny = -ny; nz = -nz }
                    for vertex in [Int(a), Int(b), Int(c)] {
                        normals[vertex * 3] += nx; normals[vertex * 3 + 1] += ny; normals[vertex * 3 + 2] += nz
                    }
                }
                for vertex in 0..<vertices {
                    let base = vertex * 3, x = normals[base], y = normals[base + 1], z = normals[base + 2]
                    let length = sqrt(x * x + y * y + z * z)
                    if length > 0.00001 { normals[base] /= length; normals[base + 1] /= length; normals[base + 2] /= length }
                    else { normals[base + 1] = 1 }
                }
                normalData = normals.withUnsafeBufferPointer { Data(buffer: $0) }
                batches = groupsByTerrain.keys.sorted().map { key in
                    let indices = groupsByTerrain[key]!
                    return Batch(terrainID: key, indices: indices.withUnsafeBufferPointer { Data(buffer: $0) }, triangles: indices.count / 3)
                }
            }
            let reportURL = url.deletingLastPathComponent().appendingPathComponent("terrain-report.json")
            let reportData = (try? Data(contentsOf: reportURL)) ?? Data()
            var report = reportData.count <= 200_000 ? String(data: reportData, encoding: .utf8) ?? "" : "Report exceeds preview size."
            let materials = loadMaterials(beside: url)
            if !materials.textures.isEmpty {
                report += "\n\nOriginal material textures: \(materials.textures.count) decoded DDS images, assigned by the retained original terrain IDs and UVs. Native lighting is provisional; UV orientation, seams, winding, vegetation, physics, and whole-game parity require validation."
            }
            return Self(source: retained, sourceURL: url, report: report, headerBytes: headerOffset,
                        sourceVertices: vertices, displayedVertices: rendered, triangleCount: triangles, groupCount: groups,
                        boundsMin: minimum, boundsMax: maximum, colors: colors, elevationColors: elevation,
                        normals: normalData, batches: batches, sampled: step > 1, formatVersion: version,
                        materialTextures: materials.textures, materialNames: materials.names)
        }
    }

    private struct MaterialManifest: Decodable {
        var schema_version: Int
        var materials: [Material]
        struct Material: Decodable { var id: UInt32; var name: String; var texture: String; var width: Int; var height: Int }
    }
    private static func loadMaterials(beside terrain: URL) -> (textures: [UInt32: URL], names: [UInt32: String]) {
        let directory = terrain.deletingLastPathComponent().standardizedFileURL
        let manifestURL = directory.appendingPathComponent("materials.json")
        guard let data = try? Data(contentsOf: manifestURL), data.count <= 3_000_000,
              let manifest = try? JSONDecoder().decode(MaterialManifest.self, from: data), manifest.schema_version == 1,
              manifest.materials.count <= 256 else { return ([:], [:]) }
        var textures: [UInt32: URL] = [:], names: [UInt32: String] = [:]
        for material in manifest.materials {
            guard material.width > 0, material.width <= 4096, material.height > 0, material.height <= 4096,
                  !material.texture.hasPrefix("/") else { continue }
            let url = directory.appendingPathComponent(material.texture).standardizedFileURL
            guard url.path.hasPrefix(directory.path + "/"), url.pathExtension.lowercased() == "png",
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            textures[material.id] = url; names[material.id] = material.name
        }
        return (textures, names)
    }
}

@MainActor
final class PGAOriginalCourseSession: ObservableObject {
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var terrain: PGAOriginalTerrain?
    @Published private(set) var elevationPalette = false
    @Published private(set) var telemetry = "Metal · loading original course"
    @Published private(set) var pointSize: CGFloat = 2.5
    @Published private(set) var courseCode = "PBL"
    let renderer = PGAOriginalRenderer()
    var onExit: () -> Void
    var onHub: () -> Void
    private weak var view: PGAOriginalInputView?
    private var loadTask: Task<PGAOriginalTerrain, Error>?
    private var loadID = UUID()
    private var timer: Timer?
    private var monitor: Any?
    private var heldKeys: Set<UInt16> = []
    private var previousButtons: [String: Bool] = [:]
    private var controllerID = "none"
    private var lastTick = 0.0
    private var telemetryTime = 0.0
    private var stopped = true
    private var azimuth = 0.8
    private var elevation = 0.75
    private var distance = 260.0
    private var target = PGAVector.zero

    init(onExit: @escaping () -> Void, onHub: @escaping () -> Void) { self.onExit = onExit; self.onHub = onHub }
    func attach(_ view: PGAOriginalInputView) {
        self.view = view; view.session = self
        view.scene = renderer.scene; view.pointOfView = renderer.camera; view.sceneDelegate = renderer
        updateCamera()
    }
    func start() {
        guard timer == nil else { return }
        stopped = false; previousButtons = [:]; lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated { guard let self, !self.stopped else { timer.invalidate(); return }; self.tick() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.view?.window?.isKeyWindow == true, NSApp.isActive,
                      event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
                return self.key(event)
            }
            return consumed ? nil : event
        }
        load()
    }
    func stop() {
        stopped = true; timer?.invalidate(); timer = nil; loadTask?.cancel(); loadTask = nil; loadID = UUID()
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        heldKeys.removeAll(); view?.session = nil
    }
    func exit() { stop(); onExit() }
    func hub() { stop(); onHub() }
    func load() {
        loadTask?.cancel(); let id = UUID(); loadID = id
        loading = true; error = nil
        let url = GameStore.workspaceRoot().appendingPathComponent("Library/Imported/pga2005/\(courseCode)/terrain.ghpc")
        let task = Task.detached(priority: .userInitiated) { try PGAOriginalTerrain.load(url) }
        loadTask = task
        Task { [weak self] in
            do {
                let terrain = try await task.value
                guard let self, self.loadID == id, !self.stopped else { return }
                self.terrain = terrain; self.renderer.install(terrain, elevationPalette: self.elevationPalette, pointSize: self.pointSize)
                self.loading = false; self.home()
            } catch {
                guard let self, self.loadID == id, !self.stopped else { return }
                self.loading = false
                self.error = "\(error.localizedDescription)\n\nImport original course terrain into Library/Imported/pga2005/\(self.courseCode)/terrain.ghpc, then reload."
            }
        }
    }
    func home() { azimuth = 0.8; elevation = 0.75; distance = 260; target = .zero; updateCamera() }
    func selectCourse(_ code: String) {
        guard ["PBL", "TUR"].contains(code), code != courseCode else { return }
        courseCode = code; terrain = nil; renderer.clear(); load()
    }
    func orbit(x: Double, y: Double) { azimuth += x; elevation = max(0.08, min(1.5, elevation + y)); updateCamera() }
    func zoom(_ amount: Double) { distance = max(8, min(850, distance * exp(amount))); updateCamera() }
    func pan(x: Double, y: Double) {
        let scale = distance * 0.0015
        target.x += (-cos(azimuth) * x + sin(azimuth) * y) * scale
        target.z += (sin(azimuth) * x + cos(azimuth) * y) * scale
        updateCamera()
    }
    func togglePalette() {
        elevationPalette.toggle()
        if let terrain { renderer.install(terrain, elevationPalette: elevationPalette, pointSize: pointSize) }
    }
    func cyclePointSize() {
        pointSize = pointSize >= 5 ? 1.5 : pointSize + 0.5
        renderer.updatePointSize(pointSize)
    }
    func fullscreen() { view?.window?.toggleFullScreen(nil) }
    private func updateCamera() {
        let position = target + PGAVector(x: sin(azimuth) * distance * cos(elevation), y: sin(elevation) * distance, z: cos(azimuth) * distance * cos(elevation))
        renderer.camera.position = SCNVector3(position.x, position.y, position.z)
        renderer.camera.look(at: SCNVector3(target.x, target.y, target.z))
    }
    private func key(_ event: NSEvent) -> Bool {
        let code = event.keyCode
        guard [0, 1, 2, 8, 3, 4, 13, 15, 24, 27, 53, 123, 124, 125, 126].contains(Int(code)) else { return false }
        if event.type == .keyUp { heldKeys.remove(code); return true }
        heldKeys.insert(code)
        guard !event.isARepeat else { return true }
        switch code {
        case 53: exit()
        case 4: home()
        case 8: togglePalette()
        case 3: fullscreen()
        case 15: load()
        default: break
        }
        return true
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = max(0.001, min(0.1, now - lastTick)); lastTick = now
        if NSApp.isActive {
            let x = (heldKeys.contains(124) || heldKeys.contains(2) ? 1.0 : 0) - (heldKeys.contains(123) || heldKeys.contains(0) ? 1.0 : 0)
            let y = (heldKeys.contains(126) ? 1.0 : 0) - (heldKeys.contains(125) ? 1.0 : 0)
            if x != 0 || y != 0 { orbit(x: x * delta, y: y * delta * 0.6) }
            if heldKeys.contains(13) || heldKeys.contains(24) { zoom(-delta) }
            if heldKeys.contains(1) || heldKeys.contains(27) { zoom(delta) }
            pollController(delta)
        } else { heldKeys.removeAll() }
        telemetryTime += delta
        if telemetryTime > 0.3 { telemetry = renderer.telemetry; telemetryTime = 0 }
    }
    private func pollController(_ delta: Double) {
        let input = PGAControllerInput.current(), sample = input.sample
        if input.identity != controllerID { controllerID = input.identity; previousButtons = [:] }
        guard sample.connected else { return }
        let state = sample.buttons
        if previousButtons.isEmpty { previousButtons = state; return }
        func pressed(_ key: String) -> Bool { state[key] == true && previousButtons[key] != true }
        defer { previousButtons = state }
        if pressed("B") { exit(); return }; if pressed("Menu") { hub(); return }
        if pressed("X") { togglePalette() }; if pressed("Y") { home() }; if pressed("A") { cyclePointSize() }
        if pressed("LB") || pressed("RB") { selectCourse(courseCode == "PBL" ? "TUR" : "PBL") }
        let x = sample.axes[0], y = sample.axes[1]
        let rx = sample.axes[2], ry = sample.axes[3]
        if abs(x) > 0.16 || abs(y) > 0.16 { orbit(x: Double(abs(x) > 0.16 ? x : 0) * delta, y: Double(abs(y) > 0.16 ? y : 0) * delta * 0.7) }
        if abs(rx) > 0.16 || abs(ry) > 0.16 { pan(x: Double(rx) * delta * 300, y: Double(ry) * delta * 300) }
        let z = sample.triggers[0] - sample.triggers[1]
        if abs(z) > 0.1 { zoom(Double(z) * delta) }
    }
}

final class PGAOriginalRenderer: NSObject, SCNSceneRendererDelegate {
    let scene = SCNScene()
    let camera = SCNNode()
    private var model = SCNNode()
    private var pointElements: [SCNGeometryElement] = []
    private let lock = NSLock()
    private var timestamps: [Double] = []
    private var report = "Metal · awaiting first frame"
    var telemetry: String { lock.lock(); defer { lock.unlock() }; return report }
    override init() {
        super.init()
        scene.background.contents = NSColor(calibratedRed: 0.055, green: 0.085, blue: 0.095, alpha: 1)
        camera.camera = SCNCamera(); camera.camera?.zNear = 0.1; camera.camera?.zFar = 1800; camera.camera?.fieldOfView = 50
        scene.rootNode.addChildNode(camera)
        let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional; sun.light?.intensity = 950
        sun.eulerAngles = SCNVector3(-0.8, -0.3, 0); scene.rootNode.addChildNode(sun)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 600
        scene.rootNode.addChildNode(ambient)
    }
    func install(_ terrain: PGAOriginalTerrain, elevationPalette: Bool, pointSize: CGFloat) {
        let position = SCNGeometrySource(data: terrain.source, semantic: .vertex, vectorCount: terrain.displayedVertices,
                                         usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                                         dataOffset: terrain.positionOffset, dataStride: 24)
        let color = SCNGeometrySource(data: elevationPalette ? terrain.elevationColors : terrain.colors, semantic: .color,
                                     vectorCount: terrain.displayedVertices, usesFloatComponents: true, componentsPerVector: 4,
                                     bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let uv = SCNGeometrySource(data: terrain.source, semantic: .texcoord, vectorCount: terrain.displayedVertices,
                                  usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: 4,
                                  dataOffset: terrain.positionOffset + 16, dataStride: 24)
        var sources = [position, color, uv]
        if let data = terrain.normals {
            sources.append(SCNGeometrySource(data: data, semantic: .normal, vectorCount: terrain.displayedVertices,
                                             usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12))
        }
        let elements: [SCNGeometryElement]
        if terrain.triangleCount > 0 {
            elements = terrain.batches.map { SCNGeometryElement(data: $0.indices, primitiveType: .triangles, primitiveCount: $0.triangles, bytesPerIndex: 4) }
            pointElements = []
        } else {
            var indices = [UInt32](repeating: 0, count: terrain.displayedVertices)
            for index in indices.indices { indices[index] = UInt32(index).littleEndian }
            let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
            let points = SCNGeometryElement(data: data, primitiveType: .point, primitiveCount: terrain.displayedVertices, bytesPerIndex: 4)
            points.pointSize = pointSize; points.minimumPointScreenSpaceRadius = pointSize / 2; points.maximumPointScreenSpaceRadius = pointSize
            elements = [points]; pointElements = [points]
        }
        let geometry = SCNGeometry(sources: sources, elements: elements)
        geometry.materials = elements.enumerated().map { index, _ in
            let material = SCNMaterial(); material.diffuse.contents = NSColor.white
            material.lightingModel = terrain.triangleCount > 0 && !elevationPalette ? .lambert : .constant
            material.isDoubleSided = true
            if terrain.triangleCount > 0 {
                let id = terrain.batches[index].terrainID
                material.name = "Original terrain ID \(id) · \(terrain.materialNames[id] ?? "unmapped")"
                if !elevationPalette, let texture = terrain.materialTextures[id] {
                    material.diffuse.contents = texture
                    material.diffuse.wrapS = .repeat; material.diffuse.wrapT = .repeat
                    material.diffuse.minificationFilter = .linear; material.diffuse.magnificationFilter = .linear
                    material.diffuse.mipFilter = .linear; material.diffuse.maxAnisotropy = 8
                }
            }
            return material
        }
        model.removeFromParentNode(); model = SCNNode(geometry: geometry)
        let scale = 200 / max(terrain.extent.x, terrain.extent.z)
        model.scale = SCNVector3(scale, scale, scale)
        model.position = SCNVector3(-terrain.center.x * scale, -terrain.center.y * scale, -terrain.center.z * scale)
        scene.rootNode.addChildNode(model)
    }
    func updatePointSize(_ value: CGFloat) {
        for element in pointElements { element.pointSize = value; element.minimumPointScreenSpaceRadius = value / 2; element.maximumPointScreenSpaceRadius = value }
    }
    func clear() { model.removeFromParentNode(); model = SCNNode(); pointElements = [] }
    func renderer(_ renderer: SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        timestamps.append(time); timestamps.removeAll { time - $0 > 1 }
        let fps = timestamps.count > 1 ? Int((Double(timestamps.count - 1) / max(0.001, time - timestamps[0])).rounded()) : 0
        let attachment = renderer.currentRenderPassDescriptor.colorAttachments[0]!
        if let color = attachment.texture {
            let target = attachment.resolveTexture ?? color
            report = "\(target.width) × \(target.height) Metal · \(color.sampleCount)× MSAA · \(fps) FPS"
        }
    }
}

@MainActor
final class PGAOriginalInputView: PGAMetalView {
    weak var session: PGAOriginalCourseSession?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseDragged(with event: NSEvent) { session?.orbit(x: Double(event.deltaX) * 0.007, y: -Double(event.deltaY) * 0.007) }
    override func rightMouseDragged(with event: NSEvent) { session?.pan(x: Double(event.deltaX), y: -Double(event.deltaY)) }
    override func scrollWheel(with event: NSEvent) { session?.zoom(Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.0025 : 0.04)) }
    override func magnify(with event: NSEvent) { session?.zoom(-Double(event.magnification) * 2) }
}

struct PGAOriginalCourseView: View {
    @StateObject private var session: PGAOriginalCourseSession
    @State private var showProvenance = false
    init(onExit: @escaping () -> Void, onHub: @escaping () -> Void) {
        _session = StateObject(wrappedValue: PGAOriginalCourseSession(onExit: onExit, onHub: onHub))
    }
    var body: some View {
        ZStack {
            PGAOriginalSceneView(session: session).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ORIGINAL COURSE LAB · \(session.courseCode == "PBL" ? "PEBBLE BEACH" : "TURNBERRY")").font(.system(size: 12, weight: .bold, design: .monospaced)).tracking(1)
                        Text("Original terrain extraction · native rendering · whole-game fidelity pending").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Button("Home · H") { session.home() }
                    Button("Full screen · F") { session.fullscreen() }
                    Button("Practice · Esc") { session.exit() }
                    Button("Hub") { session.hub() }
                }.buttonStyle(.plain).font(.system(size: 11)).padding(20).background(Color(hex: "102223").opacity(0.95))
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Button("Pebble Beach") { session.selectCourse("PBL") }
                            Text("·").foregroundStyle(.white.opacity(0.3))
                            Button("Turnberry") { session.selectCourse("TUR") }
                        }
                        if let terrain = session.terrain {
                            Text(terrain.triangleCount > 0 ? "ORIGINAL INDEXED MESH" : "ORIGINAL POINT CLOUD").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Color(hex: "EDD297"))
                            Text("\(terrain.displayedVertices.formatted()) vertices\(terrain.sampled ? " of \(terrain.sourceVertices.formatted())" : "")")
                            if terrain.triangleCount > 0 { Text("\(terrain.triangleCount.formatted()) original triangles · \(terrain.batches.count) terrain IDs") }
                            Text(session.elevationPalette ? "Analytical elevation palette" : !terrain.materialTextures.isEmpty ? "Original textures + UVs + diffuse · native lighting" : terrain.triangleCount > 0 ? "Original baked diffuse · native lighting" : "Original baked diffuse colors")
                                .foregroundStyle(.white.opacity(0.6))
                            Button(session.elevationPalette ? "Use original diffuse · C" : "Analyze elevation · C") { session.togglePalette() }
                            if terrain.triangleCount == 0 { Button("Point size \(session.pointSize, specifier: "%.1f") · A") { session.cyclePointSize() } }
                            Button("Extraction provenance") { showProvenance = true }
                        }
                        Text(session.telemetry).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
                    }.font(.system(size: 11)).buttonStyle(.plain).padding(15).background(Color(hex: "102223").opacity(0.92), in: RoundedRectangle(cornerRadius: 9))
                    Spacer()
                }.padding(20)
                Spacer()
                HStack {
                    Text("Drag / arrows orbit · right-drag pan · scroll / pinch / W S zoom · H home · C palette · R reload")
                    Spacer()
                    Text("Controller: sticks orbit/pan · triggers zoom · LB/RB course · X palette · Y home · B practice · Menu hub")
                }.font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.65)).padding(14).background(Color(hex: "102223").opacity(0.95))
            }
            if session.loading { ProgressView("Loading original terrain off the main thread…").padding(25).background(Color(hex: "102223"), in: RoundedRectangle(cornerRadius: 10)) }
            if let error = session.error {
                VStack(spacing: 17) {
                    Text("Original terrain unavailable").font(.title2)
                    Text(error).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).textSelection(.enabled)
                    HStack(spacing: 20) { Button("Reload") { session.load() }; Button("Return to practice") { session.exit() } }
                }.padding(25).frame(width: 460).background(Color(hex: "102223"), in: RoundedRectangle(cornerRadius: 12))
            }
        }.foregroundStyle(.white).onAppear { session.start() }.onDisappear { session.stop() }
            .sheet(isPresented: $showProvenance) {
                VStack(alignment: .leading, spacing: 15) {
                    Text("Original terrain provenance").font(.title2)
                    Text("Original source positions, UVs, baked diffuse colors, and—when present—decoded triangle indices and terrain IDs. SceneKit provides the native camera and provisional shading. Texture assignment, winding, seams, and original physics still require validation.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    ScrollView { Text(session.terrain?.report.isEmpty == false ? session.terrain!.report : "No extraction report found beside terrain.ghpc.")
                            .font(.system(size: 10, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    Button("Done") { showProvenance = false }
                }.padding(24).frame(width: 700, height: 560)
            }
    }
}

private struct PGAOriginalSceneView: NSViewRepresentable {
    let session: PGAOriginalCourseSession
    func makeNSView(context: Context) -> PGAOriginalInputView {
        let view = PGAOriginalInputView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        session.attach(view)
        return view
    }
    func updateNSView(_ view: PGAOriginalInputView, context: Context) {}
    static func dismantleNSView(_ view: PGAOriginalInputView, coordinator: ()) { view.isPaused = true; view.session = nil; view.sceneDelegate = nil; view.delegate = nil }
}
