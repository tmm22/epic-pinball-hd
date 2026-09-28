import AppKit
import MetalKit
import PinballCore
import PinballRender
import SwiftUI

/// How the window app starts: straight into a table (`--table N`, the smoke-test and
/// developer flags; the behaviour of earlier builds), or with the launcher / import screen.
enum StartMode {
    case direct(dataRoot: URL, assets: TableAssets, engine: ClassicEngine)
    case launcher
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let options: Options
    let startMode: StartMode
    let model: AppModel
    let gamepad = GamepadInput()
    var window: NSWindow?
    private(set) var game: GameScreen?
    private var launcherHost: NSHostingView<LauncherRoot>?
    private var launcherMonitor: Any?
    private var padTimer: Timer?
    private var settingsWindow: NSWindow?

    init(options: Options, startMode: StartMode, model: AppModel) {
        self.options = options
        self.startMode = startMode
        self.model = model
        super.init()
        model.onPlay = { [weak self] n in self?.startGame(table: n) }
        model.onQuit = { NSApp.terminate(nil) }
        model.onImportFinished = { [weak self] in self?.window?.title = "Epic Pinball HD" }
        model.settings.onChange = { [weak self] in self?.settingsChanged() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        switch startMode {
        case let .direct(dataRoot, assets, engine):
            // 3x the original screen (320x240 Mode X), in points (Retina doubles it in pixels).
            let w = makeWindow(content: NSRect(x: 0, y: 0, width: 960, height: options.legacyWindow ? 600 : 720))
            do {
                let screen = try GameScreen.make(options: options, dataRoot: dataRoot, preloaded: (assets, engine), app: self)
                show(game: screen, in: w)
                w.title = "Epic Pinball - Table \(assets.table)"
            } catch { fail("\(error)") }
            w.makeKeyAndOrderFront(nil)
        case .launcher:
            let w = makeWindow(content: NSRect(x: 0, y: 0, width: 1180, height: 800))
            w.title = "Epic Pinball HD"
            showLauncher()
            w.makeKeyAndOrderFront(nil)
            if model.settings.frontEnd.startFullscreen && options.exitAfter == nil { w.toggleFullScreen(nil) }
            if options.autostart, model.screen == .picker { model.play() }
            if let p = options.importFrom {
                let u = URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                model.runImport(from: isDir.boolValue ? .directory(u) : .isoImage(u))
            }
            if let s = options.exitAfter, game == nil { scheduleLauncherSmokeTest(after: s) }
        }
        NSApp.activate()
        startPadTimer()
    }

    /// `--launcher --exit-after S [--window-capture P]` without a game: capture the launcher window.
    private func scheduleLauncherSmokeTest(after s: Double) {
        Timer.scheduledTimer(withTimeInterval: s, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.game == nil, let v = self.window?.contentView else { return }
                if let p = self.options.windowCapture, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL
                    do {
                        try rep.representation(using: .png, properties: [:])?.write(to: url)
                        print("wrote \(url.path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
                    } catch { warn("capture failed: \(error)") }
                }
                print("launcher smoke test: screen \(self.model.screen), \(self.model.tables.filter(\.available).count) tables, "
                      + "controllers \(self.gamepad.connected.count), notice \(self.model.notice ?? "none")")
                NSApp.terminate(nil)
            }
        }
    }

    private func makeWindow(content: NSRect) -> NSWindow {
        let w = NSWindow(contentRect: content, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.contentMinSize = NSSize(width: 320, height: 200)
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.delegate = self
        w.center()
        window = w
        return w
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        game?.stop()
        gamepad.invalidate()
    }

    /// Key-up / flagsChanged events are not delivered while another window is key,
    /// so drop held keys and flipper buttons when focus leaves (avoids stuck input).
    func windowDidResignKey(_ notification: Notification) { game?.controller.releaseAllInput() }

    func windowDidChangeScreen(_ notification: Notification) { game?.controller.applyDisplayRate() }

    // MARK: screens

    func showLauncher() {
        guard let w = window else { return }
        game?.stop()
        game = nil
        model.screen = model.library == nil || model.screen == .importer ? .importer : .picker
        model.reloadTables()
        model.scoresVersion += 1
        let host = NSHostingView(rootView: LauncherRoot(model: model))
        launcherHost = host
        w.contentView = host
        w.title = "Epic Pinball HD"
        w.makeFirstResponder(host)
        installLauncherKeys()
        NSCursor.unhide()
    }

    func startGame(table: Int) {
        guard let w = window, let lib = model.library else { return }
        var o = options
        o.table = table
        o.tableGiven = true
        o.dataDir = lib.dataRoot.path
        if o.originalDir == nil { o.originalDir = lib.originalDir?.path }
        o.players = model.settings.frontEnd.players
        o.balls = model.settings.frontEnd.ballsPerGame
        do {
            let screen = try GameScreen.make(options: o, dataRoot: lib.dataRoot, preloaded: nil, app: self)
            removeLauncherKeys()
            launcherHost = nil
            model.screen = .game
            model.notice = nil
            show(game: screen, in: w)
            w.title = "Epic Pinball HD - \(model.tables.first { $0.number == table }?.name ?? "Table \(table)")"
        } catch {
            model.notice = "Table \(table) could not be started: \(error)"
            warn("table \(table): \(error)")
        }
    }

    private func show(game screen: GameScreen, in w: NSWindow) {
        game = screen
        w.contentView = screen.container
        w.makeFirstResponder(screen.view)
        screen.controller.applyDisplayRate()
    }

    func returnToPicker() {
        guard case .launcher = startMode else {
            // Started straight into a table: build the picker now.
            if model.library == nil {
                model.library = GameLibrary.locate(explicitData: options.dataDir, explicitOriginal: options.originalDir)
            }
            model.screen = .picker
            showLauncher()
            return
        }
        model.screen = .picker
        showLauncher()
    }

    // MARK: settings

    func openSettings() {
        if launcherHost != nil { model.showSettings = true; return }
        guard let w = window, settingsWindow == nil else { return }
        game?.controller.releaseAllInput()
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentView = NSHostingView(rootView: SettingsView(model: model) { [weak self] in self?.closeSettings() })
        settingsWindow = sheet
        w.beginSheet(sheet)
    }

    func closeSettings() {
        guard let s = settingsWindow, let w = window else { return }
        w.endSheet(s)
        settingsWindow = nil
        if let g = game { w.makeFirstResponder(g.view) }
    }

    private func settingsChanged() {
        game?.controller.apply(settings: model.settings)
        gamepad.enabled = model.settings.frontEnd.controllerEnabled
        gamepad.hapticsEnabled = model.settings.frontEnd.haptics
    }

    // MARK: launcher keyboard / controller

    private func installLauncherKeys() {
        removeLauncherKeys()
        launcherMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            nonisolated(unsafe) let e = ev
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.launcherHost != nil, self.model.screen == .picker, !self.model.showSettings,
                      e.window === self.window, self.window?.attachedSheet == nil else { return false }
                let cols = LauncherView.columns
                switch e.keyCode {
                case KeyCode.left: self.model.move(dx: -1, dy: 0, columns: cols)
                case KeyCode.right: self.model.move(dx: 1, dy: 0, columns: cols)
                case KeyCode.up: self.model.move(dx: 0, dy: -1, columns: cols)
                case KeyCode.down: self.model.move(dx: 0, dy: 1, columns: cols)
                case KeyCode.returnKey, KeyCode.keypadEnter, KeyCode.space: self.model.play()
                default: return false
                }
                return true
            }
            return handled ? nil : ev
        }
    }

    private func removeLauncherKeys() {
        if let m = launcherMonitor { NSEvent.removeMonitor(m) }
        launcherMonitor = nil
    }

    private func startPadTimer() {
        gamepad.enabled = model.settings.frontEnd.controllerEnabled
        gamepad.hapticsEnabled = model.settings.frontEnd.haptics
        padTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.model.controllers != self.gamepad.connected { self.model.controllers = self.gamepad.connected }
                guard self.launcherHost != nil, self.model.screen == .picker, !self.model.showSettings else { return }
                for b in self.gamepad.menuPresses() {
                    switch b {
                    case .left: self.model.move(dx: -1, dy: 0, columns: LauncherView.columns)
                    case .right: self.model.move(dx: 1, dy: 0, columns: LauncherView.columns)
                    case .up: self.model.move(dx: 0, dy: -1, columns: LauncherView.columns)
                    case .down: self.model.move(dx: 0, dy: 1, columns: LauncherView.columns)
                    case .accept: self.model.play()
                    case .menu: self.model.showSettings = true
                    case .back: break
                    }
                }
            }
        }
    }

    // MARK: menu bar

    private func installMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let it = NSMenuItem()
            let m = NSMenu(title: title)
            for i in items { m.addItem(i) }
            it.submenu = m
            main.addItem(it)
        }
        func item(_ t: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        sub("Epic Pinball", [
            item("About Epic Pinball HD", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Settings…", #selector(menuSettings), ",", target: self),
            .separator(),
            item("Hide Epic Pinball", #selector(NSApplication.hide(_:)), "h"),
            item("Quit Epic Pinball", #selector(NSApplication.terminate(_:)), "q"),
        ])
        sub("Game", [
            item("New Game", #selector(menuNewGame), "n", target: self),
            item("Pause Menu", #selector(menuPause), "p", [.command, .shift], target: self),
            item("Choose Table…", #selector(menuChooseTable), "l", target: self),
        ])
        sub("View", [
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        sub("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        NSApp.mainMenu = main
    }

    @objc private func menuSettings() { openSettings() }
    @objc private func menuNewGame() { game?.controller.newGame() }
    @objc private func menuPause() { game?.controller.openMenu() }
    @objc private func menuChooseTable() { returnToPicker() }
}

/// Picker or import screen, plus the settings sheet.
struct LauncherRoot: View {
    @Bindable var model: AppModel
    var body: some View {
        Group {
            switch model.screen {
            case .importer: ImportView(model: model)
            default: LauncherView(model: model)
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) { model.showSettings = false } }
    }
}

// MARK: - The running game

/// One table session: the Metal view, its overlay and the controller.
@MainActor
final class GameScreen {
    let container: NSView
    let view: GameView
    let controller: GameController

    init(container: NSView, view: GameView, controller: GameController) {
        self.container = container; self.view = view; self.controller = controller
    }

    func stop() {
        controller.stop()
        view.isPaused = true
        view.delegate = nil
    }

    static func make(options: Options, dataRoot: URL, preloaded: (TableAssets, ClassicEngine)?, app: AppDelegate?) throws -> GameScreen {
        let assets: TableAssets, engine: ClassicEngine
        if let p = preloaded { (assets, engine) = p } else {
            assets = try TableAssets.load(dataRoot: dataRoot, table: options.table)
            engine = try EngineAssets.makeEngine(dataRoot: dataRoot, table: options.table)
            if let gp = options.gravityPhase { engine.gravityPhase = gp }
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        let renderer = try PinballRenderer(device: device, assets: assets,
                                           flipperSprites: options.sprites ? loadFlipperSprites(assets: assets, engine: engine) : nil)
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

        let view = GameView(frame: NSRect(x: 0, y: 0, width: 960, height: 720), device: device)
        let sim = GameSimulation(engine: engine, mode: options.mode, options: options.rulesOptions)
        let controller = GameController(renderer: renderer, view: view, sim: sim, presentation: pres)
        controller.rulesOptions = options.rulesOptions
        controller.table = assets.table
        controller.cliPresentation = options.mode
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

        if let app {
            controller.gamepad = app.gamepad
            controller.highScores = app.model.scores
            controller.tableName = app.model.tables.first { $0.number == assets.table }?.name
                ?? (GameLibrary.findOriginal(near: dataRoot, explicit: options.originalDir)
                    .flatMap { try? Data(contentsOf: $0.appendingPathComponent("ID\(assets.table).DAT")) }
                    .flatMap(TableCatalog.tableName)) ?? "Table \(assets.table)"
            controller.onReturnToPicker = { [weak app] in app?.returnToPicker() }
            controller.onOpenSettings = { [weak app] in app?.openSettings() }
            controller.onScoresChanged = { [weak app] in app?.model.scoresVersion += 1 }
            controller.store = app.model.settings
            // The CLI flags of a direct start win over the stored settings for this session only.
            controller.apply(settings: app.model.settings, initial: true)
        }

        let container = NSView(frame: view.frame)
        container.autoresizesSubviews = true
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        let host = NSHostingView(rootView: GameOverlayView(model: controller.overlay))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        controller.overlayHost = host
        host.isHidden = true
        return GameScreen(container: container, view: view, controller: controller)
    }
}

/// MTKView subclass that owns keyboard input.
@MainActor
final class GameView: MTKView {
    weak var controller: GameController?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let c = controller else { return }
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }   // menu shortcuts
        if !c.keyDown(event.keyCode, isRepeat: event.isARepeat) { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        controller?.keyUp(event.keyCode)
    }

    override func flagsChanged(with event: NSEvent) {
        controller?.flagsChanged(raw: event.modifierFlags.rawValue, capsLock: event.modifierFlags.contains(.capsLock))
    }
}

/// Owns simulation + camera and drives rendering from MTKView's display link. The simulation
/// runs whole original frames (59.94 Hz) from wall-clock time whatever the display rate is.
@MainActor
final class GameController: NSObject, MTKViewDelegate {
    let renderer: PinballRenderer
    let sim: GameSimulation
    weak var view: MTKView?
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
    var table = 1
    var tableName = ""
    /// P: the game is frozen (no frames run), music paused, the pause banner shown.
    private(set) var paused = false
    /// The rules reported game over: frames stop until a new game starts.
    private(set) var gameOver = false
    private var manualY: Int?
    private var keyboard = KeyboardState()
    var bindings = KeyBindings.defaults
    var gamepad: GamepadInput?
    var highScores: HighScoreStore?
    /// Settings store the in-game keys write to (filter, aspect, volumes...); nil = keys act locally.
    weak var store: SettingsStore?
    var highRefresh = false
    /// `--mode` of a direct start (presentation only; enhanced physics implies enhanced presentation).
    var cliPresentation: SimulationMode = .classic
    let overlay = OverlayModel()
    weak var overlayHost: NSView?
    var onReturnToPicker: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onScoresChanged: (() -> Void)?
    private var lastState: PresentationState?
    private var pendingInitials: [(player: Int, score: UInt32)] = []
    private var lastInitials: String?
    private var lastTime: CFTimeInterval?
    private var stopped = false
    // Smoke-test support (--exit-after / --window-capture).
    var exitAfter: Double?
    var capturePath: String?
    private var startTime: CFTimeInterval?
    private var frames = 0

    init(renderer: PinballRenderer, view: MTKView, sim: GameSimulation, presentation: ClassicPresentation? = nil) {
        self.renderer = renderer
        self.sim = sim
        self.presentation = presentation
        self.view = view
        super.init()
        view.colorPixelFormat = .bgra8Unorm
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)  // palette values are sRGB
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 120
        view.autoResizeDrawable = true   // drawableSize tracks backing (Retina) pixels
        view.delegate = self
        overlay.onItem = { [weak self] in self?.menuItem($0) }
        camera.snap(toBallY: sim.renderBallTopLeft.y + 7)
        if let p = presentation {
            camera.windowHeight = Double(p.windowRows)
            p.camera.snap(maxBallY: ClassicPresentation.maxActiveBallY(sim.engine), cameraMax: p.cameraMax)
        }
    }

    func stop() {
        stopped = true
        audio?.stop()
        audio = nil
    }

    // MARK: settings

    /// Applies the settings to the running table. `initial`: the session's first call, where a
    /// direct start's CLI flags (already applied by `GameScreen.make`) take precedence.
    func apply(settings s: SettingsStore, initial: Bool = false) {
        let g = s.game, fe = s.frontEnd
        bindings = fe.keyBindings
        gamepad?.enabled = fe.controllerEnabled
        gamepad?.hapticsEnabled = fe.haptics
        rulesOptions.players = fe.players
        rulesOptions.ballsPerGame = fe.ballsPerGame
        highRefresh = g.highRefresh
        // Renderer: filter, HD pack, lighting and display-rate interpolation from the shared settings
        // (`EPIC_PINBALL_RENDER` still overrides them for developer runs).
        renderer.settings = RenderSettings.fromEnvironment() ?? RenderSettings(g)
        renderer.aspect = PixelAspect(rawValue: fe.pixelAspect) ?? .square
        camera.showFullTable = g.fullTableView
        // Physics: classic = the bit-exact integer engine, enhanced = the physics track's model.
        // The presentation mode follows it (enhanced draws the ball at sub-pixel positions).
        sim.physicsMode = g.physicsMode
        sim.mode = g.physicsMode == .enhanced || cliPresentation == .enhanced ? .enhanced : .classic
        if let p = presentation, p.stripShown != fe.showStrip { p.setStrip(shown: fe.showStrip, immediately: initial) }
        audio?.apply(master: fe.masterVolume, music: g.musicVolume, sfx: g.sfxVolume)
        if !renderer.hdPackWarnings.isEmpty { for w in renderer.hdPackWarnings { warn("HD pack: \(w)") } }
        applyDisplayRate()
    }

    /// Filters the F key cycles through.
    static var cyclableFilters: [GameSettings.UpscaleFilter] { GameSettings.UpscaleFilter.allCases }

    /// 60 Hz normally; the display's maximum (120 Hz on ProMotion) with high refresh on.
    func applyDisplayRate() {
        guard let v = view else { return }
        let maxFPS = v.window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
        v.preferredFramesPerSecond = highRefresh ? max(60, maxFPS) : 60
    }

    private func edit(_ f: (SettingsStore) -> Void) {
        if let s = store { f(s) }   // onChange applies it
    }

    // MARK: input

    /// Returns false for keys we do not handle.
    func keyDown(_ code: UInt16, isRepeat: Bool) -> Bool {
        if overlay.active { overlayKey(code, isRepeat: isRepeat); return true }
        let first = keyboard.press(code)
        let actions = bindings.actions(for: code)
        if actions.isEmpty { return false }
        for a in actions where !a.isHeld && (first || (isRepeat && a.repeats)) { command(a) }
        if actions.contains(where: \.isHeld) {
            sim.inputProvider = nil   // any game key takes over from --autopilot
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        return true
    }

    func keyUp(_ code: UInt16) { keyboard.release(code) }

    func flagsChanged(raw: UInt, capsLock: Bool) {
        let (pressed, _) = keyboard.modifiersChanged(rawFlags: raw, capsLock: capsLock)
        for code in pressed {
            if overlay.active { overlayKey(code, isRepeat: false); continue }
            let actions = bindings.actions(for: code)
            for a in actions where !a.isHeld { command(a) }
            if actions.contains(where: \.isHeld) { sim.inputProvider = nil }
        }
    }

    func releaseAllInput() { keyboard.releaseAll() }

    private func command(_ a: GameAction) {
        switch a {
        case .fullTable: edit { $0.game.fullTableView.toggle() }; if store == nil { camera.showFullTable.toggle() }
        case .restart: newGame()
        case .pause: setPaused(!paused)
        case .menu: openMenu()
        case .toggleMusic: audio?.toggleMusic()
        case .toggleSfx: audio?.toggleSfx()
        case .volumeDown: edit { $0.frontEnd.masterVolume = max(0, ($0.frontEnd.masterVolume - 0.1 + 1e-9).rounded(toPlaces: 1)) }
        case .volumeUp: edit { $0.frontEnd.masterVolume = min(1, ($0.frontEnd.masterVolume + 0.1).rounded(toPlaces: 1)) }
        case .musicDown: edit { $0.game.musicVolume = max(0, ($0.game.musicVolume - 0.1 + 1e-9).rounded(toPlaces: 1)) }
        case .musicUp: edit { $0.game.musicVolume = min(1, ($0.game.musicVolume + 0.1).rounded(toPlaces: 1)) }
        case .pixelAspect: edit { $0.frontEnd.pixelAspect = $0.frontEnd.pixelAspect == "vga" ? "square" : "vga" }
        case .toggleStrip:
            if let s = store { s.frontEnd.showStrip = !(presentation?.stripShown ?? s.frontEnd.showStrip) } else { presentation?.toggleStrip() }
        case .cycleFilter:
            edit { s in
                let all = Self.cyclableFilters
                s.game.upscaleFilter = all[((all.firstIndex(of: s.game.upscaleFilter) ?? -1) + 1) % all.count]
            }
        case .physicsMode: edit { $0.game.physicsMode = $0.game.physicsMode == .classic ? .enhanced : .classic }
        default: break
        }
    }

    /// Keys while an overlay is up (menu navigation, initials).
    private func overlayKey(_ code: UInt16, isRepeat: Bool) {
        let actions = bindings.actions(for: code)
        switch overlay.mode {
        case .none: return
        case .initials:
            if code == KeyCode.returnKey || code == KeyCode.keypadEnter || code == KeyCode.space
                || actions.contains(.plunger) || actions.contains(.launchOrNudge) {
                if !isRepeat { overlay.initials.accept() }
            } else if code == KeyCode.delete {
                overlay.initials.back()
            } else if code == KeyCode.escape {
                finishInitials(record: false); return
            } else if code == KeyCode.up || actions.contains(.rightFlipper) {
                overlay.initials.step(1)
            } else if code == KeyCode.down || actions.contains(.leftFlipper) {
                overlay.initials.step(-1)
            } else if let ch = KeyCode.character(code) {
                overlay.initials.type(ch)
            }
            if overlay.initials.done { finishInitials(record: true) }
        case .pauseMenu, .gameOver:
            if code == KeyCode.up || actions.contains(.scrollUp) { overlay.moveSelection(-1) }
            else if code == KeyCode.down || actions.contains(.scrollDown) { overlay.moveSelection(1) }
            else if code == KeyCode.returnKey || code == KeyCode.keypadEnter || code == KeyCode.space { if !isRepeat { overlay.activate() } }
            else if actions.contains(.menu) || code == KeyCode.escape { if overlay.mode == .pauseMenu { closeMenu() } }
            else if actions.contains(.restart), !isRepeat { newGame() }
        }
    }

    private func pad(_ b: PadButton) {
        switch overlay.mode {
        case .none: if b == .menu { openMenu() }
        case .initials:
            switch b {
            case .up, .right: overlay.initials.step(1)
            case .down, .left: overlay.initials.step(-1)
            case .accept: overlay.initials.accept()
            case .back: overlay.initials.back()
            case .menu: break
            }
            if overlay.initials.done { finishInitials(record: true) }
        case .pauseMenu, .gameOver:
            switch b {
            case .up: overlay.moveSelection(-1)
            case .down: overlay.moveSelection(1)
            case .accept: overlay.activate()
            case .back, .menu: if overlay.mode == .pauseMenu { closeMenu() }
            default: break
            }
        }
    }

    // MARK: menus

    func openMenu() {
        guard overlay.mode == .none else { return }
        if gameOver { showGameOverPanel(); return }
        setPaused(true)
        overlay.tableName = tableName
        overlay.index = 0
        setOverlay(.pauseMenu)
    }

    func closeMenu() {
        setOverlay(.none)
        setPaused(false)
    }

    private func setOverlay(_ m: OverlayModel.Mode) {
        overlay.mode = m
        overlayHost?.isHidden = m == .none
        if m != .none { NSCursor.unhide() }
        keyboard.releaseAll()
        gamepad?.resync()
        if let v = view { v.window?.makeFirstResponder(v) }
    }

    private func menuItem(_ it: OverlayModel.Item) {
        switch it {
        case .resume: closeMenu()
        case .newGame: newGame()
        case .settings: onOpenSettings?()
        case .chooseTable: setOverlay(.none); onReturnToPicker?()
        case .quit: NSApp.terminate(nil)
        }
    }

    /// R: a new game with the rules (the original's pause-menu restart), or a new ball without them.
    func newGame() {
        if sim.engine.rules != nil {
            sim.newGame(options: rulesOptions)
        } else {
            sim.resetBall()
        }
        gameOver = false
        pendingInitials = []
        setOverlay(.none)
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

    // MARK: high scores

    private func handleGameOver(_ st: PresentationState) {
        let n = max(1, min(st.playerCount, st.scores.count))
        overlay.finalScores = Array(st.scores.prefix(n))
        overlay.highlight = []
        guard let hs = highScores else { return }
        pendingInitials = (0..<n).map { (player: $0 + 1, score: st.scores[$0]) }.filter { hs.qualifies($0.score, table: table) }
        if pendingInitials.isEmpty { showGameOverPanel() } else { nextInitials() }
    }

    private func nextInitials() {
        guard let p = pendingInitials.first, let hs = highScores else { showGameOverPanel(); return }
        guard hs.qualifies(p.score, table: table) else { pendingInitials.removeFirst(); nextInitials(); return }
        overlay.initials = InitialsEntry(start: lastInitials)
        overlay.initialsScore = p.score
        overlay.initialsPrompt = overlay.finalScores.count > 1 ? "Player \(p.player), enter your initials" : "Enter your initials"
        setOverlay(.initials)
        // Smoke-test hook: type these key codes' letters through the normal key path.
        if let t = ProcessInfo.processInfo.environment["EPIC_PINBALL_TEST_INITIALS"] {
            let codes = t.uppercased().compactMap { ch in KeyCode.names.first { $0.value == String(ch) }?.key }
            DispatchQueue.main.async { [weak self] in for c in codes { _ = self?.keyDown(c, isRepeat: false) } }
        }
    }

    private func finishInitials(record: Bool) {
        guard !pendingInitials.isEmpty else { showGameOverPanel(); return }
        let p = pendingInitials.removeFirst()
        if record, let hs = highScores {
            let e = HighScoreEntry(initials: overlay.initials.text, score: p.score, date: Date(),
                                   players: overlay.finalScores.count, player: p.player, physics: sim.mode.rawValue)
            if let r = hs.add(e, table: table) {
                overlay.highlight = Set(overlay.highlight.map { $0 >= r ? $0 + 1 : $0 }.filter { $0 < HighScoreBook.capacity })
                overlay.highlight.insert(r)
                lastInitials = e.initials
                onScoresChanged?()
            }
        }
        nextInitials()
    }

    private func showGameOverPanel() {
        overlay.tableName = tableName
        overlay.entries = highScores?.entries(table: table) ?? []
        overlay.index = 0
        setOverlay(.gameOver)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard !stopped else { return }
        let now = CACurrentMediaTime()
        let dt = lastTime.map { now - $0 } ?? 0
        lastTime = now

        // Controller: menu buttons (edges), then the held game buttons.
        var padInput: FrameInput = []
        if let g = gamepad {
            for b in g.menuPresses() { pad(b) }
            padInput = g.frameInput()
        }
        if overlay.active {
            sim.input = []
        } else {
            if !padInput.isEmpty { sim.inputProvider = nil }
            sim.input = bindings.frameInput(held: keyboard.held).union(padInput)
        }

        let ran = paused || gameOver || overlay.active ? 0 : sim.advance(by: dt)
        // Rules output once per original frame (sounds of every frame in order); the renderer takes
        // the latest, the audio engine every frame's effects.
        var frameStates: [(PresentationState, DotMessage?)] = []
        if demo == nil, let src = presentationSource {
            for _ in 0..<ran { if let st = src() { frameStates.append(st) } }
        }
        for (st, _) in frameStates {
            audio?.present(st)
            lastState = st
            if st.gameOver && !gameOver {
                gameOver = true
                presentation?.paused = true   // the original enters its menu here (pause_menu)
                handleGameOver(st)
            }
        }
        let scroll = overlay.active ? 0 : max(-1, min(1, bindings.scroll(held: keyboard.held) + (gamepad?.scroll() ?? 0)))
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
        // Display-rate motion (high refresh): the renderer draws ball, flippers and camera between the
        // last two 59.94 Hz frames; the simulation itself only ever runs whole frames.
        renderer.interpolation = highRefresh ? MotionInterpolation(simulation: sim, interpolateCamera: sim.mode == .classic) : nil
        presentation?.apply(to: renderer, scene: scene, engine: sim.engine)
        do {
            try renderer.encode(scene: scene, into: cb, target: drawable.texture)
        } catch {
            fail("render failed: \(error)")
        }
        frames += 1
        if startTime == nil {
            startTime = now
            // Smoke-test hook: open the pause menu after the first frame.
            if ProcessInfo.processInfo.environment["EPIC_PINBALL_TEST_MENU"] != nil {
                DispatchQueue.main.async { [weak self] in self?.openMenu() }
            }
        }
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
        print("game: score \(sim.engine.rules?.score ?? 0), game over \(gameOver), overlay \(overlay.mode), "
              + "high scores on table \(table): \(highScores?.entries(table: table).count ?? 0)")
        print("smoke test: \(frames) frames in \(String(format: "%.2f", elapsed)) s, drawable \(tex.width)x\(tex.height) (\(tex.pixelFormat == .bgra8Unorm ? "bgra8Unorm" : "format \(tex.pixelFormat.rawValue)")), backing scale \(scale), engine frames \(sim.engine.frameCount), display \(view.preferredFramesPerSecond) fps requested (screen max \(view.window?.screen?.maximumFramesPerSecond ?? 0), high refresh \(highRefresh), interpolation \(renderer.interpolation != nil), physics \(sim.physicsMode.rawValue))")
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
        if overlay.active, let path = capturePath, let host = overlayHost,
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            // The SwiftUI overlay is not in the Metal drawable: capture it on its own.
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = URL(fileURLWithPath: ((path as NSString).expandingTildeInPath as NSString).deletingPathExtension + "-overlay.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("wrote \(url.path) (overlay \(overlay.mode), \(rep.pixelsWide)x\(rep.pixelsHigh))")
        }
        NSApp.terminate(nil)
    }
}

extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let m = pow(10, Double(p))
        return (self * m).rounded() / m
    }
}
