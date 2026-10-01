import AppKit
import MetalKit
import PinballCore
import PinballRender

/// Cabinet support (docs/enhanced/frontend.md "Cabinet"): the score strip / DMD in a window of
/// its own, which the user can put on a second display (a backglass screen), while the main
/// window shows the playfield only. The picture rotation for turned monitors is the renderer's
/// (`RenderSettings.rotation`, DisplayRotation.swift); this file only owns the extra window.
///
/// Both windows remember their frame (and with it their screen) through AppKit's frame
/// autosave in the user defaults; the score window also remembers whether it was in full screen.
@MainActor
final class ScoreWindowController: NSObject, MTKViewDelegate, NSWindowDelegate {
    static let frameName = "EpicPinballHD.ScoreWindow"
    static let mainFrameName = "EpicPinballHD.MainWindow"
    static let fullScreenKey = "EpicPinballHD.ScoreWindow.fullScreen"

    let window: NSWindow
    let view: GameView
    private weak var controller: GameController?
    /// The user closed the window (its close button): the front end turns the option off.
    var onUserClose: (() -> Void)?
    private var closing = false
    private var reportedError = false

    init(controller: GameController, device: MTLDevice) {
        self.controller = controller
        // 3x the 320-wide strip; EP1-8 have 19 strip rows, EP9-13 29 (letterboxed either way).
        let rows = CGFloat(controller.presentation?.maxStripRows ?? 19)
        // Turned by 90 / 270 (its own rotation): a tall window to start with.
        let tall = controller.scoreRotation == .clockwise90 || controller.scoreRotation == .clockwise270
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: tall ? rows * 3 : 960, height: tall ? 960 : rows * 3),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Epic Pinball HD - Score"
        window.contentMinSize = NSSize(width: 160, height: 24)
        window.collectionBehavior.insert(.fullScreenPrimary)   // its own full screen on a second display
        window.isReleasedWhenClosed = false
        view = GameView(frame: NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size), device: device)
        super.init()
        view.controller = controller   // keys typed while this window is key still play
        view.colorPixelFormat = .bgra8Unorm
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.autoResizeDrawable = true   // backing (Retina) pixels; the renderer letterboxes
        view.preferredFramesPerSecond = 60
        view.delegate = self
        window.contentView = view
        window.delegate = self
        if !AppPaths.remembersWindows || !window.setFrameUsingName(Self.frameName) { window.center() }
        if AppPaths.remembersWindows { window.setFrameAutosaveName(Self.frameName) }
    }

    func show() {
        window.orderFront(nil)
        if AppPaths.remembersWindows, UserDefaults.standard.bool(forKey: Self.fullScreenKey), !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    /// Closes the window without touching the setting (the game ended or the option was turned off).
    func close() {
        closing = true
        view.isPaused = true
        view.delegate = nil
        window.close()
    }

    /// The strip alone at the window's backing size (what the window shows; smoke-test capture).
    func renderOffscreen() throws -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let c = controller, let p = c.presentation else { return nil }
        let w = max(1, Int(view.drawableSize.width)), h = max(1, Int(view.drawableSize.height))
        return (try c.renderer.renderStripOffscreen(rows: p.maxStripRows, width: w, height: h, rotation: c.scoreRotation), w, h)
    }

    var summary: String {
        let f = window.frame
        return "score window \(Int(f.width))x\(Int(f.height)) at \(Int(f.minX)),\(Int(f.minY)) on \(window.screen?.localizedName ?? "no screen"), "
            + "drawable \(Int(view.drawableSize.width))x\(Int(view.drawableSize.height)), full screen \(window.styleMask.contains(.fullScreen))"
            + ((controller?.scoreRotation ?? .none) == .none ? "" : ", rotated \(controller!.scoreRotation.rawValue)")
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let c = controller, let p = c.presentation, let d = view.currentDrawable,
              let cb = c.renderer.commandQueue.makeCommandBuffer() else { return }
        do {
            try c.renderer.encodeStrip(rows: p.maxStripRows, into: cb, target: d.texture, rotation: c.scoreRotation)
        } catch {
            if !reportedError { warn("score window: \(error)"); reportedError = true }
        }
        cb.present(d)
        cb.commit()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if !closing { onUserClose?() }
    }

    func windowDidResignKey(_ notification: Notification) { controller?.releaseAllInput() }

    func windowDidEnterFullScreen(_ notification: Notification) {
        if !closing, AppPaths.remembersWindows { UserDefaults.standard.set(true, forKey: Self.fullScreenKey) }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if !closing, AppPaths.remembersWindows { UserDefaults.standard.set(false, forKey: Self.fullScreenKey) }
    }
}

extension AppDelegate {
    /// Opens or closes the score window to match the setting (only while a table with the classic
    /// presentation runs). The main window starts remembering its frame once cabinet mode is used.
    func updateScoreWindow() {
        let want = model.settings.game.scoreWindow && game?.controller.presentation != nil
        if want, scoreWindow == nil, let g = game, let w = window {
            if AppPaths.remembersWindows, w.frameAutosaveName != ScoreWindowController.mainFrameName {
                if !w.styleMask.contains(.fullScreen) { w.setFrameUsingName(ScoreWindowController.mainFrameName) }
                w.setFrameAutosaveName(ScoreWindowController.mainFrameName)
            }
            let s = ScoreWindowController(controller: g.controller, device: g.view.device ?? g.controller.renderer.device)
            s.onUserClose = { [weak self] in
                self?.scoreWindow = nil
                self?.model.settings.game.scoreWindow = false
            }
            scoreWindow = s
            g.controller.scoreWindow = s
            s.show()
            w.makeKeyAndOrderFront(nil)   // the playfield keeps the keyboard
        } else if !want, let s = scoreWindow {
            scoreWindow = nil
            game?.controller.scoreWindow = nil
            s.close()
        }
    }
}

extension GameSettings.DisplayRotation {
    var label: String {
        switch self {
        case .none: return "None"
        case .clockwise90: return "90° clockwise"
        case .upsideDown: return "180°"
        case .clockwise270: return "90° anticlockwise (270°)"
        }
    }
}
