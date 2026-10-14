import AppKit
import GameController
import MetalKit
import SceneKit

/// A controlled native render target. macOS can expose a scaled 1440×900-point
/// desktop whose automatic Retina drawable is 2880×1800. The user's requested
/// fullscreen game image is explicitly 2560×1600, independent of that setting.
@MainActor
class PGAMetalView: MTKView, MTKViewDelegate {
    private let sceneRenderer: SCNRenderer
    private let commandQueue: MTLCommandQueue?
    var scene: SCNScene? {
        get { sceneRenderer.scene }
        set { sceneRenderer.scene = newValue }
    }
    var pointOfView: SCNNode? {
        get { sceneRenderer.pointOfView }
        set { sceneRenderer.pointOfView = newValue }
    }
    var sceneDelegate: SCNSceneRendererDelegate? {
        get { sceneRenderer.delegate }
        set { sceneRenderer.delegate = newValue }
    }

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        let selected = device ?? MTLCreateSystemDefaultDevice()
        sceneRenderer = SCNRenderer(device: selected, options: nil)
        commandQueue = selected?.makeCommandQueue()
        super.init(frame: frameRect, device: selected)
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float_stencil8
        sampleCount = selected?.supportsTextureSampleCount(4) == true ? 4 : 1
        preferredFramesPerSecond = 60
        autoResizeDrawable = false
        enableSetNeedsDisplay = false
        isPaused = false
        framebufferOnly = true
        sceneRenderer.isPlaying = true
        delegate = self
        configureDrawable()
    }
    required init(coder: NSCoder) { fatalError("PGAMetalView is created programmatically") }
    override func layout() { super.layout(); configureDrawable() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configureDrawable() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); configureDrawable() }
    func configureDrawable() {
        let size = window?.styleMask.contains(.fullScreen) == true ? CGSize(width: 2560, height: 1600) : convertToBacking(bounds.size)
        guard size.width > 0, size.height > 0 else { return }
        if drawableSize != size { drawableSize = size }
    }
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            // Check on each frame as well as layout: the fullscreen style mask
            // can change after AppKit's last resize callback during animation.
            configureDrawable()
            guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer() else { return }
            sceneRenderer.render(atTime: ProcessInfo.processInfo.systemUptime,
                                 viewport: CGRect(origin: .zero, size: drawableSize),
                                 commandBuffer: commandBuffer, passDescriptor: pass)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

@MainActor
enum PGAControllerInput {
    static func current() -> (identity: String, name: String?, sample: NativeGamepadSample) {
        if let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil }), let pad = controller.extendedGamepad {
            let buttons = ["A": pad.buttonA.isPressed, "B": pad.buttonB.isPressed, "X": pad.buttonX.isPressed,
                           "Y": pad.buttonY.isPressed, "LB": pad.leftShoulder.isPressed, "RB": pad.rightShoulder.isPressed,
                           "Menu": pad.buttonMenu.isPressed, "View": pad.buttonOptions?.isPressed ?? false,
                           "Up": pad.dpad.up.isPressed, "Down": pad.dpad.down.isPressed,
                           "Left": pad.dpad.left.isPressed, "Right": pad.dpad.right.isPressed]
            let sample = NativeGamepadSample(connected: true, buttons: buttons,
                                            axes: [pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value,
                                                   pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value],
                                            triggers: [pad.leftTrigger.value, pad.rightTrigger.value])
            return (String(describing: ObjectIdentifier(controller)), controller.vendorName ?? controller.productCategory, sample)
        }
        let fallback = FusionController.shared.sample
        return (fallback.connected ? "fusion-usb" : "none", fallback.connected ? "Xbox Fusion Pro · wired USB" : nil, fallback)
    }
}
