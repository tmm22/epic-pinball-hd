import AppKit
import MetalKit
import PinballCore
import PinballRender

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let options: Options
    let assets: TableAssets
    let engine: ClassicEngine
    let dataRoot: URL
    var window: NSWindow?
    var controller: GameController?

    init(options: Options, assets: TableAssets, engine: ClassicEngine, dataRoot: URL) {
        self.options = options
        self.assets = assets
        self.engine = engine
        self.dataRoot = dataRoot
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device available") }
        let renderer: PinballRenderer
        do {
            renderer = try PinballRenderer(device: device, assets: assets,
                                           flipperSprites: options.sprites ? loadFlipperSprites(assets: assets, engine: engine) : nil)
        } catch { fail("\(error)") }
        renderer.aspect = options.aspect
        renderer.filter = options.filter
        var pres: ClassicPresentation?
        if !options.legacyWindow,
           let p = ClassicPresentation.load(assets: assets, engine: engine.data, dataRoot: dataRoot, originalDir: options.originalDir) {
            p.setStrip(shown: options.stripShown, immediately: true)
            p.state = flagPresentation(options, p)
            p.directMessage = directMessage(options.message, p, lines: options.messageLines)
            p.paused = options.paused
            renderer.attach(composer: p.composer)
            pres = p
        }

        // 3x the original screen (320x240 Mode X, or the legacy 320x200 window), in points
        // (Retina doubles it in pixels).
        let content = NSRect(x: 0, y: 0, width: 960, height: pres == nil ? 600 : 720)
        let view = GameView(frame: content, device: device)
        let sim = GameSimulation(engine: engine, mode: options.mode, options: options.rulesOptions)
        let controller = GameController(renderer: renderer, view: view, sim: sim, presentation: pres)
        controller.rulesOptions = options.rulesOptions
        if options.autopilot {
            var player = AutoPlayer(engine: engine)
            sim.inputProvider = { player.input(for: $0) }
        }
        controller.audio = options.mute ? nil : AudioController(table: assets.table, originalDir: options.originalDir, options: options)
        if let err = engine.rulesLoadError { warn("table rules not loaded, physics only: \(err)") }
        for w in engine.rules?.warnings ?? [] { warn("rules: \(w)") }
        if !options.demo, engine.rules != nil, !options.hasPresentationFlags {
            // The table's rules run the game: one PresentationState per original frame goes to the
            // renderer (lamps, score, messages) and to the audio engine (effects, music).
            controller.presentationSource = { (sim.takePresentation(), nil) }
        }
        if options.demo, let p = pres {
            let g = p.composer.graphics
            controller.demo = DemoDriver(lampCount: g.lampCount, restIsA: g.lampRestIsA,
                                         messages: DemoDriver.findMessages(tableDirectory: assets.directory, exe: p.exe,
                                                                           dataSegment: g.dataSegment))
        }
        controller.exitAfter = options.exitAfter
        controller.capturePath = options.windowCapture
        if options.windowCapture != nil { view.framebufferOnly = false }
        view.controller = controller

        let window = NSWindow(contentRect: content, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Epic Pinball - Table \(assets.table)"
        window.contentView = view
        window.contentMinSize = NSSize(width: 320, height: 200)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        self.window = window
        self.controller = controller
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { controller?.audio?.stop() }

    /// Key-up / flagsChanged events are not delivered while another window is key,
    /// so drop held keys and flipper buttons when focus leaves (avoids stuck input).
    func windowDidResignKey(_ notification: Notification) { controller?.releaseAllInput() }

    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Epic Pinball", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }
}

/// MTKView subclass that owns keyboard input.
@MainActor
final class GameView: MTKView {
    weak var controller: GameController?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let c = controller else { return }
        if !c.keyDown(event.keyCode, isRepeat: event.isARepeat) { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        controller?.keyUp(event.keyCode)
    }

    override func flagsChanged(with event: NSEvent) {
        // Device-dependent modifier bits distinguish left/right Shift
        // (NX_DEVICELSHIFTKEYMASK = 0x02, NX_DEVICERSHIFTKEYMASK = 0x04).
        let raw = event.modifierFlags.rawValue
        controller?.setModifiers(leftShift: raw & 0x02 != 0, rightShift: raw & 0x04 != 0,
                                 control: event.modifierFlags.contains(.control))
    }
}

/// Owns simulation + camera and drives rendering from MTKView's display link.
@MainActor
final class GameController: NSObject, MTKViewDelegate {
    enum Key {
        static let up: UInt16 = 126, down: UInt16 = 125, left: UInt16 = 123, right: UInt16 = 124
        static let tab: UInt16 = 48, space: UInt16 = 49, r: UInt16 = 15, a: UInt16 = 0, e: UInt16 = 14
        static let z: UInt16 = 6, comma: UInt16 = 43, slash: UInt16 = 44, escape: UInt16 = 53
        static let returnKey: UInt16 = 36, keypadEnter: UInt16 = 76, f: UInt16 = 3
        static let m: UInt16 = 46, s: UInt16 = 1, p: UInt16 = 35, minus: UInt16 = 27, equal: UInt16 = 24
        static let leftBracket: UInt16 = 33, rightBracket: UInt16 = 30
    }

    let renderer: PinballRenderer
    let sim: GameSimulation
    var camera = Camera()
    /// Classic presentation (strip, overlays, messages, original camera); nil = legacy view.
    let presentation: ClassicPresentation?
    /// `--demo`: drives lamps/score/messages without rules.
    var demo: DemoDriver?
    /// Hook for the rules integration: called once per original frame; return the frame's
    /// PresentationState and, when the producer knows the original's placement (AX, DI,
    /// appended text lines, live DS text), the full DotMessage; nil keeps the current state.
    var presentationSource: (() -> (PresentationState, DotMessage?)?)?
    /// Table audio (nil with --mute or without the original files).
    var audio: AudioController?
    /// Options for a new game (R key / after game over).
    var rulesOptions = RulesOptions()
    /// P: the game is frozen (no frames run), music paused, the pause banner shown.
    private(set) var paused = false
    /// The rules reported game over: frames stop until R starts a new game.
    private(set) var gameOver = false
    private var manualY: Int?
    private var heldKeys = Set<UInt16>()
    private var modifiers = (leftShift: false, rightShift: false, control: false)
    private var lastTime: CFTimeInterval?
    // Smoke-test support (--exit-after / --window-capture).
    var exitAfter: Double?
    var capturePath: String?
    private var startTime: CFTimeInterval?
    private var frames = 0

    init(renderer: PinballRenderer, view: MTKView, sim: GameSimulation, presentation: ClassicPresentation? = nil) {
        self.renderer = renderer
        self.sim = sim
        self.presentation = presentation
        super.init()
        view.colorPixelFormat = .bgra8Unorm
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)  // palette values are sRGB
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 120
        view.autoResizeDrawable = true   // drawableSize tracks backing (Retina) pixels
        view.delegate = self
        camera.snap(toBallY: sim.renderBallTopLeft.y + 7)
        if let p = presentation {
            camera.windowHeight = Double(p.windowRows)
            p.camera.snap(maxBallY: ClassicPresentation.maxActiveBallY(sim.engine), cameraMax: p.cameraMax)
        }
    }

    // MARK: input

    /// Returns false for keys we do not handle.
    func keyDown(_ code: UInt16, isRepeat: Bool) -> Bool {
        switch code {
        case Key.up, Key.down, Key.left, Key.right, Key.space, Key.z, Key.comma, Key.slash: heldKeys.insert(code)
        case Key.tab: if !isRepeat { camera.showFullTable.toggle() }
        case Key.r:
            if !isRepeat { newGame() }
        case Key.p: if !isRepeat { setPaused(!paused) }
        case Key.m: if !isRepeat { audio?.toggleMusic() }
        case Key.s: if !isRepeat { audio?.toggleSfx() }
        case Key.minus: audio?.adjust(master: -0.1)
        case Key.equal: audio?.adjust(master: 0.1)
        case Key.leftBracket: audio?.adjust(music: -0.1)
        case Key.rightBracket: audio?.adjust(music: 0.1)
        case Key.a: if !isRepeat { renderer.aspect = renderer.aspect == .square ? .vga : .square }
        case Key.returnKey, Key.keypadEnter: if !isRepeat { presentation?.toggleStrip() }
        case Key.f:
            if !isRepeat {
                let all = UpscaleFilter.allCases
                renderer.filter = all[((all.firstIndex(of: renderer.filter) ?? 0) + 1) % all.count]
            }
        case Key.e: if !isRepeat { sim.mode = sim.mode == .classic ? .enhanced : .classic }
        case Key.escape: NSApp.terminate(nil)
        default: return false
        }
        updateInput()
        return true
    }

    /// R: a new game with the rules (the original's pause-menu restart), or a new ball without them.
    func newGame() {
        if sim.engine.rules != nil {
            sim.newGame(options: rulesOptions)
        } else {
            sim.resetBall()
        }
        gameOver = false
        setPaused(false)
        camera.snap(toBallY: sim.renderBallTopLeft.y + 7)
        if let p = presentation { p.camera.snap(maxBallY: ClassicPresentation.maxActiveBallY(sim.engine), cameraMax: p.cameraMax) }
    }

    func setPaused(_ on: Bool) {
        paused = on
        presentation?.paused = on || gameOver
        audio?.setPaused(on)
        lastTime = nil
    }

    func keyUp(_ code: UInt16) {
        heldKeys.remove(code)
        updateInput()
    }

    func releaseAllInput() {
        heldKeys.removeAll()
        modifiers = (false, false, false)
        updateInput()
    }

    func setModifiers(leftShift: Bool, rightShift: Bool, control: Bool) {
        modifiers = (leftShift, rightShift, control)
        updateInput()
    }

    /// Maps keys to the original's input flags (keyboard_isr cs:314B).
    private func updateInput() {
        sim.inputProvider = nil   // any game key takes over from --autopilot
        var i: FrameInput = []
        if modifiers.leftShift || heldKeys.contains(Key.left) { i.insert(.leftFlipper) }
        if modifiers.rightShift || heldKeys.contains(Key.right) { i.insert(.rightFlipper) }
        if modifiers.control { i.insert(.plunger) }
        if heldKeys.contains(Key.space) { i.insert(.space) }
        if heldKeys.contains(Key.z) || heldKeys.contains(Key.comma) { i.insert(.nudgeA) }
        if heldKeys.contains(Key.slash) { i.insert(.nudgeB) }
        sim.input = i
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = lastTime.map { now - $0 } ?? 0
        lastTime = now

        let ran = paused || gameOver ? 0 : sim.advance(by: dt)
        // Rules output once per original frame (sounds of every frame in order); the renderer takes
        // the latest, the audio engine every frame's effects.
        var frameStates: [(PresentationState, DotMessage?)] = []
        if demo == nil, let src = presentationSource {
            for _ in 0..<ran { if let st = src() { frameStates.append(st) } }
        }
        for (st, _) in frameStates {
            audio?.present(st)
            if st.gameOver && !gameOver {
                gameOver = true
                presentation?.paused = true   // the original enters its menu here (pause_menu)
            }
        }
        let scroll = (heldKeys.contains(Key.down) ? 1 : 0) - (heldKeys.contains(Key.up) ? 1 : 0)
        if let p = presentation {
            // Original camera in classic mode (integer rows, eased per frame); arrows scroll
            // manually like manual_scroll (cs:0B03) until released.
            if scroll != 0 {
                manualY = max(0, (manualY ?? p.camera.y) + scroll * 4)
            } else { manualY = nil }
            for _ in 0..<ran {
                if var d = demo {
                    var st = p.state
                    _ = d.step(into: &st, messagesInStrip: p.spec.messagesInStrip)
                    p.ingest(st)
                    p.directMessage = directMessage(d.messageSpec(at: d.frame, inStrip: p.spec.messagesInStrip), p)
                    demo = d
                } else if !frameStates.isEmpty {
                    let (s, msg) = frameStates.removeFirst()
                    p.ingest(s)
                    if let msg { p.directMessage = msg }
                }
                p.stepFrame(engine: sim.engine, manualY: manualY)
            }
            camera.windowHeight = Double(p.windowRows)
            if sim.mode == .classic {
                camera.setY(Double(p.camera.y))
            } else {
                camera.update(dt: min(dt, 0.1), ballY: sim.renderBallTopLeft.y + 7, scroll: scroll)
            }
        } else {
            camera.update(dt: min(dt, 0.1), ballY: sim.renderBallTopLeft.y + 7, scroll: scroll)
        }

        guard let drawable = view.currentDrawable,
              let cb = renderer.commandQueue.makeCommandBuffer() else { return }
        let scene = SceneState(simulation: sim, camera: camera)
        presentation?.apply(to: renderer, scene: scene, engine: sim.engine)
        do {
            try renderer.encode(scene: scene, into: cb, target: drawable.texture)
        } catch {
            fail("render failed: \(error)")
        }
        frames += 1
        if startTime == nil { startTime = now }
        if let limit = exitAfter, now - startTime! >= limit {
            finishSmokeTest(view: view, drawable: drawable, commandBuffer: cb, elapsed: now - startTime!)
            return
        }
        cb.present(drawable)
        cb.commit()
    }

    private func finishSmokeTest(view: MTKView, drawable: CAMetalDrawable, commandBuffer cb: MTLCommandBuffer, elapsed: Double) {
        let tex = drawable.texture
        var readback: MTLBuffer?
        if capturePath != nil, !view.framebufferOnly,
           let buf = renderer.device.makeBuffer(length: tex.width * tex.height * 4, options: .storageModeShared),
           let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: tex.width, height: tex.height, depth: 1), to: buf,
                      destinationOffset: 0, destinationBytesPerRow: tex.width * 4, destinationBytesPerImage: tex.width * tex.height * 4)
            blit.endEncoding()
            readback = buf
        }
        cb.present(drawable)
        cb.commit()
        cb.waitUntilCompleted()
        let scale = view.window?.backingScaleFactor ?? 1
        if let a = audio {
            print("audio: \(a.effectsSubmitted) effects submitted, music \(a.musicPaused ? "paused" : "playing"), dropped commands \(a.engine.droppedCommands)")
        } else {
            print("audio: off")
        }
        print("game: score \(sim.engine.rules?.score ?? 0), game over \(gameOver)")
        print("smoke test: \(frames) frames in \(String(format: "%.2f", elapsed)) s, drawable \(tex.width)x\(tex.height) (\(tex.pixelFormat == .bgra8Unorm ? "bgra8Unorm" : "format \(tex.pixelFormat.rawValue)")), backing scale \(scale), engine frames \(sim.engine.frameCount)")
        if let buf = readback, let path = capturePath {
            let n = tex.width * tex.height
            let src = buf.contents().bindMemory(to: UInt8.self, capacity: n * 4)
            var rgba = [UInt8](repeating: 255, count: n * 4)
            for i in 0..<n {  // BGRA -> RGBA
                rgba[i * 4] = src[i * 4 + 2]; rgba[i * 4 + 1] = src[i * 4 + 1]; rgba[i * 4 + 2] = src[i * 4]
            }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            do {
                try PNGWriter.write(rgba: rgba, width: tex.width, height: tex.height, to: url)
                print("wrote \(url.path)")
            } catch {
                FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
            }
        }
        NSApp.terminate(nil)
    }
}
