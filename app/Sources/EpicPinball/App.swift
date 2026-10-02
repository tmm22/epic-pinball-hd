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
    /// Launcher attract mode: last input in the picker, and the event monitor that records it.
    private var launcherIdleSince = CACurrentMediaTime()
    private var launcherActivityMonitor: Any?
    /// Cabinet: the score strip's own window (Cabinet.swift), while a game runs with the option on.
    var scoreWindow: ScoreWindowController?

    init(options: Options, startMode: StartMode, model: AppModel) {
        self.options = options
        self.startMode = startMode
        self.model = model
        if let d = options.attractDelay { AttractTracker.delayOverride = d }
        super.init()
        model.onPlay = { [weak self] n in self?.startGame(table: n) }
        model.onPractice = { [weak self] n in self?.startGame(table: n, practice: true) }
        model.onWatch = { [weak self] url in self?.watchReplay(url) }
        model.onQuit = { NSApp.terminate(nil) }
        model.onImportFinished = { [weak self] in self?.window?.title = "Epic Pinball HD" }
        model.settings.onChange = { [weak self] in self?.settingsChanged() }
        gamepad.onDisconnect = { [weak self] in self?.game?.controller.pauseForInactivity() }
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
                if options.attract { screen.controller.enterAttract(fromLauncher: false) }
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
            model.importHDPacksAnswer = options.importHDPacks
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
        launcherActivityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown,
                                                                             .rightMouseDown, .scrollWheel]) { [weak self] ev in
            MainActor.assumeIsolated { self?.launcherIdleSince = CACurrentMediaTime() }
            return ev
        }
    }

    /// The picker sitting idle for `AttractTracker.idleSeconds` opens the selected table in attract
    /// mode, as PINBALL.EXE's menu starts its demo (file 0x843..0x85C); leaving it returns here.
    /// Only while the app is frontmost (no demo music from a background app), unless `--attract-delay`
    /// is given (smoke tests on a locked session).
    private func launcherAttractTick() {
        guard launcherHost != nil, model.screen == .picker, !model.showSettings, let w = window, w.attachedSheet == nil,
              !w.isMiniaturized, NSApp.isActive || options.attractDelay != nil, model.settings.frontEnd.attractMode, model.selectedTable?.available == true,
              options.exitAfter == nil || options.attractDelay != nil else {
            launcherIdleSince = CACurrentMediaTime()
            return
        }
        guard CACurrentMediaTime() - launcherIdleSince >= AttractTracker.idleSeconds else { return }
        launcherIdleSince = CACurrentMediaTime()
        startGame(table: model.selected, attract: true)
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
                      + "controllers \(self.gamepad.connected.count), notice \(self.model.notice ?? "none"), hd packs \(self.model.hdPackState), "
                      + "installed \(HDPackGeneration.installedSummary()), use hd pack \(self.model.settings.game.useHDPack)")
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
    /// so drop held keys and flipper buttons when focus leaves (avoids stuck input), and open the
    /// pause menu ("Pause when inactive", on by default).
    func windowDidResignKey(_ notification: Notification) { game?.controller.pauseForInactivity() }

    func applicationDidResignActive(_ notification: Notification) { game?.controller.pauseForInactivity() }

    func windowDidChangeScreen(_ notification: Notification) { game?.controller.applyDisplayRate() }

    // MARK: screens

    func showLauncher() {
        guard let w = window else { return }
        game?.stop()
        game = nil
        updateScoreWindow()
        model.hdPackStatus = nil
        model.screen = model.library == nil || model.screen == .importer ? .importer : .picker
        model.reloadTables()
        model.scoresVersion += 1
        launcherIdleSince = CACurrentMediaTime()
        let host = NSHostingView(rootView: LauncherRoot(model: model))
        launcherHost = host
        w.contentView = host
        w.title = "Epic Pinball HD"
        w.makeFirstResponder(host)
        installLauncherKeys()
        NSCursor.unhide()
    }

    /// Starts `table` (a normal game, a practice game, or watching the replay at `replay`, already
    /// decoded as `decoded` when the caller read it).
    func startGame(table: Int, practice: Bool = false, replay: URL? = nil, decoded: Replay? = nil, attract: Bool = false) {
        guard let w = window, let lib = model.library else { return }
        var o = options
        o.table = table
        o.tableGiven = true
        o.practice = practice
        o.watchReplay = replay?.path
        o.dataDir = lib.dataRoot.path
        if o.originalDir == nil { o.originalDir = lib.originalDir?.path }
        o.players = model.settings.frontEnd.players
        o.balls = model.settings.frontEnd.ballsPerGame
        do {
            // Watching from the game-over panel replaces the running table: its sound stops before the
            // new table's audio engine starts (the table itself is stopped once the new one shows).
            let previous = game
            previous?.controller.stopAudio()
            let screen = try GameScreen.make(options: o, dataRoot: lib.dataRoot, preloaded: nil, app: self, replay: decoded)
            removeLauncherKeys()
            launcherHost = nil
            model.screen = .game
            model.notice = nil
            show(game: screen, in: w)
            previous?.stop()   // watching from the game-over panel replaces the running table
            w.title = "Epic Pinball HD - \(model.tables.first { $0.number == table }?.name ?? "Table \(table)")"
                + (practice ? " (Practice)" : replay != nil ? " (Replay)" : "")
            if attract { screen.controller.enterAttract(fromLauncher: true) }
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
        updateScoreWindow()
        // Smoke tests (--exit-after) on a Mac whose display is asleep or locked: MTKView's display
        // link does not fire there, so drive the same draw(in:) from a 60 Hz timer instead.
        if screen.controller.exitAfter != nil, CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            print("smoke test: the main display is asleep; frames are driven by a 60 Hz timer")
            screen.driveWithTimer()
        }
        // Smoke-test hook: EPIC_PINBALL_TEST_SETTINGS=OPEN,CLOSE opens Settings after OPEN seconds
        // through the Cmd-, menu action and closes it after CLOSE seconds.
        if let v = ProcessInfo.processInfo.environment["EPIC_PINBALL_TEST_SETTINGS"]?.split(separator: ",").compactMap({ Double($0) }),
           v.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + v[0]) { [weak self] in
                self?.menuSettings()
                if let c = self?.game?.controller {
                    print("test settings: opened, paused \(c.paused), overlay \(c.overlay.mode), sheet \(self?.window?.attachedSheet != nil)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + v[1]) { [weak self] in
                if let c = self?.game?.controller {
                    print("test settings: before close, paused \(c.paused), overlay \(c.overlay.mode)")
                }
                self?.closeSettings()
                if let c = self?.game?.controller {
                    print("test settings: closed, paused \(c.paused), overlay \(c.overlay.mode), hud \(c.hud.flash ?? "-")")
                }
            }
        }
    }

    /// Watch the replay at `url` (launcher, game-over panel).
    func watchReplay(_ url: URL) {
        do {
            let r = try Replay.load(contentsOf: url)
            startGame(table: r.header.table, replay: url, decoded: r)
        } catch {
            model.notice = "Replay \(url.lastPathComponent) could not be read: \(error)"
            warn("replay \(url.path): \(error)")
        }
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
        // Before the sheet takes the key window: the game pauses for Settings (not the pause menu).
        game?.controller.settingsWillOpen()
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentView = NSHostingView(rootView: SettingsView(model: model) { [weak self] in self?.closeSettings() })
        settingsWindow = sheet
        w.beginSheet(sheet)
    }

    func closeSettings() {
        guard let s = settingsWindow, let w = window else { return }
        w.endSheet(s)
        settingsWindow = nil
        if let g = game {
            w.makeFirstResponder(g.view)
            g.controller.settingsDidClose()
        }
    }

    private func settingsChanged() {
        game?.controller.apply(settings: model.settings)
        updateScoreWindow()
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
                self.launcherAttractTick()
                guard self.launcherHost != nil, self.model.screen == .picker, !self.model.showSettings else { return }
                for b in self.gamepad.menuPresses() {
                    self.launcherIdleSince = CACurrentMediaTime()
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
            item("Save Screenshot", #selector(menuScreenshot), "s", [.command, .shift], target: self),
            item("Choose Table…", #selector(menuChooseTable), "l", target: self),
        ])
        sub("View", [
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
            item("Performance Overlay", #selector(menuPerfOverlay), "", target: self),
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
    @objc private func menuScreenshot() { game?.controller.requestScreenshot() }
    @objc private func menuPerfOverlay() {
        if game != nil { game?.controller.togglePerfOverlay() } else { model.settings.frontEnd.showPerfOverlay.toggle() }
    }
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

    private var drawTimer: Timer?

    func stop() {
        drawTimer?.invalidate()
        drawTimer = nil
        controller.stop()
        view.isPaused = true
        view.delegate = nil
    }

    /// Draws from a timer instead of the display link (used when no display is awake).
    func driveWithTimer(hz: Double = 60) {
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        drawTimer = Timer.scheduledTimer(withTimeInterval: 1 / hz, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.view.draw() }
        }
    }

    static func make(options: Options, dataRoot: URL, preloaded: (TableAssets, ClassicEngine)?, app: AppDelegate?,
                     replay given: Replay? = nil) throws -> GameScreen {
        let assets: TableAssets, engine: ClassicEngine
        // Watching a replay: a newly loaded engine with the recorded rules backend and gravity phase.
        let replay = try given ?? options.watchReplay.map { try Replay.load(contentsOf: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) }
        if let r = replay {
            assets = try preloaded.flatMap { $0.0.table == r.header.table ? $0.0 : nil } ?? TableAssets.load(dataRoot: dataRoot, table: r.header.table)
            engine = try ReplayPlayer.makeEngine(for: r.header, dataRoot: dataRoot, originalDir: options.originalURL)
        } else if let p = preloaded { (assets, engine) = p } else {
            assets = try TableAssets.load(dataRoot: dataRoot, table: options.table)
            engine = try EngineAssets.makeEngine(dataRoot: dataRoot, table: options.table, originalDir: options.originalURL)
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
        // Every new game starts from this power-on state (replays start from a newly loaded engine).
        let powerOn = engine.rules != nil ? engine.snapshot() : nil
        let sim = replay.map { ReplayPlayer.makeSimulation(for: $0.header, engine: engine, mode: options.mode) }
            ?? GameSimulation(engine: engine, mode: options.mode, options: options.rulesOptions)
        let controller = GameController(renderer: renderer, view: view, sim: sim, presentation: pres)
        controller.powerOn = powerOn
        controller.dataRoot = dataRoot
        controller.originalDir = options.originalURL
        controller.session = replay != nil ? .watching : (options.practice ? .practice : .normal)
        controller.replayPlayer = replay.map { ReplayPlayer(replay: $0) }
        controller.rulesOptions = options.rulesOptions
        controller.table = assets.table
        controller.cliPresentation = options.mode
        controller.cliLighting = options.directPlay ? options.lighting : nil
        if pres != nil, let r = engine.rules, let sf = r.screenFade, ProcessInfo.processInfo.environment["EPIC_PINBALL_NO_SCREEN_FADE"] == nil {
            controller.screenFade = ScreenFadePlayer(fade: sf, ds: r.machine.initialDS)
        }
        if options.autopilot, replay == nil {
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
        controller.automatedRun = options.exitAfter != nil || GameController.testHooksActive()
        // Smoke tests (--exit-after) keep running when focus moves, unless asked to check auto-pause.
        controller.autoPauseAllowed = options.exitAfter == nil || ProcessInfo.processInfo.environment["EPIC_PINBALL_TEST_AUTOPAUSE"] != nil
        controller.capturePath = options.windowCapture
        if options.windowCapture != nil { view.framebufferOnly = false }
        view.controller = controller

        if let app {
            controller.gamepad = app.gamepad
            controller.highScores = app.model.scores
            controller.stats = app.model.stats
            controller.tableName = app.model.tables.first { $0.number == assets.table }?.name
                ?? (GameLibrary.findOriginal(near: dataRoot, explicit: options.originalDir)
                    .flatMap { try? Data(contentsOf: $0.appendingPathComponent("ID\(assets.table).DAT")) }
                    .flatMap(TableCatalog.tableName)) ?? "Table \(assets.table)"
            controller.onReturnToPicker = { [weak app] in app?.returnToPicker() }
            controller.onOpenSettings = { [weak app] in app?.openSettings() }
            controller.onScoresChanged = { [weak app] in app?.model.scoresVersion += 1 }
            controller.onRenderStatus = { [weak app] in app?.model.hdPackStatus = $0 }
            controller.onWatchReplay = { [weak app] in app?.watchReplay($0) }
            controller.keepsReplays = true
            controller.practiceStore = PracticeStateStore()
            controller.store = app.model.settings
            // The CLI flags of a direct start win over the stored settings for this session only.
            controller.apply(settings: app.model.settings, initial: true)
        }

        let container = NSView(frame: view.frame)
        container.autoresizesSubviews = true
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        let hud = NSHostingView(rootView: GameHUDView(model: controller.hud, orientation: controller.overlayOrientation))
        hud.frame = container.bounds
        hud.autoresizingMask = [.width, .height]
        container.addSubview(hud)
        controller.beginSession()
        let host = NSHostingView(rootView: GameOverlayView(model: controller.overlay, orientation: controller.overlayOrientation))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        controller.overlayHost = host
        host.isHidden = true
        let statusHost = PassthroughHostingView(rootView: StatusHUDView(model: controller.statusHUD, orientation: controller.overlayOrientation))
        statusHost.frame = container.bounds
        statusHost.autoresizingMask = [.width, .height]
        container.addSubview(statusHost)
        controller.hudHost = statusHost
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
        if !c.keyDown(event.keyCode, isRepeat: event.isARepeat, at: event.timestamp) { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        controller?.keyUp(event.keyCode)
    }

    override func flagsChanged(with event: NSEvent) {
        controller?.flagsChanged(raw: event.modifierFlags.rawValue, capsLock: event.modifierFlags.contains(.capsLock), at: event.timestamp)
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
    /// The original's visible fades (boot fade-in at every game start, end-of-game fade-out); nil without the
    /// rules or the classic presentation. The game waits while it plays (`blocksPlay`).
    var screenFade: ScreenFadePlayer?
    private var fadeClock = 0.0
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
    /// `--lighting` of a direct start: the level used while lighting is on (GameSettings only stores on/off).
    var cliLighting: RenderSettings.Lighting?
    let overlay = OverlayModel()
    weak var overlayHost: NSView?
    /// Screenshot confirmation and the performance overlay (always visible, never takes input).
    let statusHUD = StatusHUDModel()
    weak var hudHost: NSView?
    /// Per-table statistics (stats.json); nil = not recorded (no front end).
    var stats: StatsStore?
    private var statsTracker = GameStatsTracker()
    /// Settings > Game > Pause when inactive.
    var pauseWhenInactive = true
    /// False for `--exit-after` runs (without `EPIC_PINBALL_TEST_AUTOPAUSE`).
    var autoPauseAllowed = true
    /// Settings > Display > Screenshots.
    var screenshotDirectory = AppPaths.defaultScreenshotFolder
    private var screenshotRequested = false
    /// Non-nil while the performance overlay is on.
    private var perf: PerfMeter?
    /// Attract mode: idle tracking and the demo session (AttractMode.swift).
    let attract = AttractTracker()
    var onReturnToPicker: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onScoresChanged: (() -> Void)?
    /// Receives the HD pack status (Settings > Display) when it changes: after a settings change
    /// and after the frame in which the renderer looked for, loaded or dropped a pack.
    var onRenderStatus: ((String) -> Void)?
    private var lastRenderStatus: String?
    /// Cabinet: the score window drawing this table's strip (set by the app delegate).
    weak var scoreWindow: ScoreWindowController?
    /// The score window's own picture rotation (`GameSettings.scoreWindowRotation`).
    var scoreRotation: GameSettings.DisplayRotation = .none
    /// The picture rotation the SwiftUI overlays follow (`CabinetRotated`, OverlayRotation.swift).
    let overlayOrientation = OverlayOrientation()
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
    // Replays and practice (extension at the end of this file, Replays.swift)
    var session: SessionKind = .normal
    /// The engine before its first game: every new game starts from it (replayable).
    var powerOn: EngineSnapshot?
    /// Recording the running normal game (nil in practice / watching, or without rules).
    private var recorder: ReplayRecorder?
    private var lastReplay: Replay?
    /// File the last game's replay was kept under (high score or Save Replay).
    private var lastReplayKept: String?
    /// Write replays to the support directory (the app; not unit tests).
    var keepsReplays = false
    let replays = ReplayLibrary()
    var replayPlayer: ReplayPlayer?
    private var replayDone = false
    /// Practice save states of this session by slot (1...PracticeStateFile.slotCount): restored at
    /// once; `replay` is the game up to the state (what the slot's file holds), nil when the game was
    /// not recorded (no rules, or a practice game entered from an unrecorded one).
    private var practiceSlots: [Int: PracticeSlot] = [:]
    struct PracticeSlot {
        var sim: SimulationSnapshot
        var presentation: ClassicPresentation.Saved?
        var camera: Camera
        var gameOver: Bool
        var replay: Replay?
    }
    /// The slot K saves to and L restores from (digit keys 1-4 in a practice game).
    private(set) var stateSlot = 1
    /// Where practice states are written (`<support>/SaveStates`); nil = this session only.
    var practiceStore: PracticeStateStore?
    /// Records the practice game (never written as a replay): the input prefix a save state stores.
    private var practiceRecorder: ReplayRecorder?
    let hud = HUDModel()
    var onWatchReplay: ((URL) -> Void)?
    /// Where the table's files are (replay headers record their digests).
    var dataRoot: URL?
    var originalDir: URL?
    private var fileDigests: (exe: String?, data: String?)?
    /// Smoke-test hook `EPIC_PINBALL_TEST_STATES=SAVE,LOAD` (engine frames): what happened.
    private var testStatesLog: [String] = []
    /// `EPIC_PINBALL_TEST_LOAD_STATE` ran.
    private var testLoadDone = false
    /// High scores and statistics are recorded only for normal games (not practice, not replays).
    /// Attract (demo) games count for nothing either.
    var recordsResults: Bool { session == .normal && !attract.active }
    /// Statistics are for human play: `recordsResults`, and the game not driven by automation
    /// (`countsForStatistics`). A game started directly with `--table N` and played by hand counts.
    var recordsStatistics: Bool {
        Self.countsForStatistics(recordsResults: recordsResults, autopilotPlayed: gameAutopiloted, automatedRun: automatedRun)
    }
    /// The rule behind `recordsStatistics`: a normal, non-attract game (`recordsResults`) that the
    /// auto-player (`--autopilot`) played no frame of, in a run that is not a smoke test
    /// (`--exit-after`, `EPIC_PINBALL_TEST_*` hooks: `automatedRun`). Headless runs (`--autoplay`,
    /// `--trace`, `--snapshot`, `--play-replay`) have no statistics store at all.
    nonisolated static func countsForStatistics(recordsResults: Bool, autopilotPlayed: Bool, automatedRun: Bool) -> Bool {
        recordsResults && !autopilotPlayed && !automatedRun
    }
    /// The auto-player ran at least one frame of the current game (a game key takes over from it,
    /// but that game stays automated; the next one counts).
    private(set) var gameAutopiloted = false
    /// Smoke-test run (`--exit-after`) or a test hook in the environment (set by `GameScreen.make`).
    var automatedRun = false
    /// Whether this process runs under a test hook (`EPIC_PINBALL_TEST_*` in the environment).
    nonisolated static func testHooksActive(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        env.keys.contains { $0.hasPrefix("EPIC_PINBALL_TEST_") }
    }
    /// A replay of the running game is being recorded.
    var isRecording: Bool { recorder != nil }

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
        recordAbandonedGame()
        stopped = true
        recorder?.cancel()
        recorder = nil
        practiceRecorder?.cancel()
        practiceRecorder = nil
        stopAudio()
    }

    /// Silences the table (its audio engine stops for good).
    func stopAudio() {
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
        if !statsTracker.active { statsTracker.ballsPerGame = fe.ballsPerGame }   // the running game keeps its own
        pauseWhenInactive = fe.pauseWhenInactive
        screenshotDirectory = fe.screenshotDirectory
        setPerfOverlay(fe.showPerfOverlay)
        attract.enabled = fe.attractMode && (exitAfter == nil || AttractTracker.delayOverride != nil)
        highRefresh = g.highRefresh
        // Renderer: filter, HD pack, lighting and display-rate interpolation from the shared settings
        // (`EPIC_PINBALL_RENDER` still overrides them for developer runs).
        var rs = RenderSettings.fromEnvironment() ?? RenderSettings(g)
        if let l = cliLighting, rs.lighting != .off, RenderSettings.fromEnvironment() == nil { rs.lighting = l }
        renderer.settings = rs
        renderer.aspect = PixelAspect(rawValue: fe.pixelAspect) ?? .square
        scoreRotation = g.scoreWindowRotation
        overlayOrientation.rotation = rs.rotation
        camera.showFullTable = g.fullTableView
        // Physics: classic = the bit-exact integer engine, enhanced = the physics track's model.
        // The presentation mode follows it (enhanced draws the ball at sub-pixel positions).
        if session != .watching {   // a replay keeps its recorded physics
            sim.enhancedConfig = .preset(g.enhancedPreset)
            sim.physicsMode = g.physicsMode
        }
        followPhysics()
        let stripHere = mainWindowShowsStrip(s)
        if let p = presentation, p.stripShown != stripHere { p.setStrip(shown: stripHere, immediately: initial) }
        audio?.apply(master: fe.masterVolume, music: g.musicVolume, sfx: g.sfxVolume)
        audio?.setInterpolation(g.audioInterpolation)
        if !renderer.hdPackWarnings.isEmpty { for w in renderer.hdPackWarnings { warn("HD pack: \(w)") } }
        reportRenderStatus()
        applyDisplayRate()
    }

    /// The HD pack lookup happens in the renderer's next frame, so the status is read back from the
    /// renderer rather than predicted from the settings.
    private func reportRenderStatus() {
        let rs = renderer.settings
        let text: String
        if renderer.hdPackActive { text = "active for table \(table)" }
        else if !rs.useHDPack { text = "off" }
        else if let w = renderer.hdPackWarnings.first { text = "none for table \(table) (\(w))" }
        else { text = "looking for table \(table)'s pack…" }
        guard text != lastRenderStatus else { return }
        lastRenderStatus = text
        onRenderStatus?(text)
    }

    /// Whether the strip is drawn under the playfield: the setting, unless the score window draws it
    /// (cabinet: the playfield then takes the whole screen, the original's strip-hidden layout) or
    /// the demo runs (the original shows no score panel in demo mode).
    func mainWindowShowsStrip(_ s: SettingsStore?) -> Bool {
        guard let s else { return presentation?.stripShown ?? true }
        return s.frontEnd.showStrip && !(s.game.scoreWindow && presentation != nil) && !attract.active
    }

    /// The presentation mode follows the running physics (enhanced draws the ball at sub-pixel
    /// positions); also after a practice restore or a replay's physics switch.
    func followPhysics() {
        sim.mode = sim.physicsMode == .enhanced || cliPresentation == .enhanced ? .enhanced : .classic
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
    func keyDown(_ code: UInt16, isRepeat: Bool, at time: TimeInterval? = nil) -> Bool {
        if attractInput() { return true }   // any key ends the demo (cs:0CFF)
        if overlay.active { overlayKey(code, isRepeat: isRepeat); return true }
        if session == .watching, watchingKey(code, isRepeat: isRepeat) { return true }
        if session == .practice, let slot = Self.stateSlotKeys[code], bindings.actions(for: code).isEmpty {
            if !isRepeat { selectStateSlot(slot) }   // digits 1-4 (and keypad 1-4) choose the save slot
            return true
        }
        let first = keyboard.press(code)
        let actions = bindings.actions(for: code)
        if actions.isEmpty { return false }
        if first, actions.contains(where: Self.isFlipper) { perf?.flipperPressed(at: time ?? CACurrentMediaTime()) }
        for a in actions where !a.isHeld && (first || (isRepeat && a.repeats)) { command(a) }
        if actions.contains(where: \.isHeld), session != .watching {
            sim.inputProvider = nil   // any game key takes over from --autopilot
            attract.touched = true
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        return true
    }

    func keyUp(_ code: UInt16) { keyboard.release(code) }

    /// Practice games: key code -> save slot (1-4 on the main row and the keypad), unless the key is
    /// bound to an action in Settings > Controls.
    static let stateSlotKeys: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 83: 1, 84: 2, 85: 3, 86: 4]

    func flagsChanged(raw: UInt, capsLock: Bool, at time: TimeInterval? = nil) {
        let (pressed, _) = keyboard.modifiersChanged(rawFlags: raw, capsLock: capsLock)
        if !pressed.isEmpty, attractInput() {
            // A held modifier (Ctrl plunger, Shift flippers) that ended the demo stays held in the
            // fresh game: that game has started, so idle attract must not take it over again.
            if !attract.active, pressed.contains(where: { bindings.actions(for: $0).contains(where: \.isHeld) }) { attract.touched = true }
            return
        }
        for code in pressed {
            if overlay.active { overlayKey(code, isRepeat: false); continue }
            let actions = bindings.actions(for: code)
            if actions.contains(where: Self.isFlipper) { perf?.flipperPressed(at: time ?? CACurrentMediaTime()) }
            for a in actions where !a.isHeld { command(a) }
            if actions.contains(where: \.isHeld), session != .watching { sim.inputProvider = nil; attract.touched = true }
        }
    }

    func releaseAllInput() { keyboard.releaseAll() }

    private static func isFlipper(_ a: GameAction) -> Bool { a == .leftFlipper || a == .rightFlipper }

    /// Focus lost (window or app) or a game controller disconnected: drop held input and, with
    /// "Pause when inactive", open the pause menu. Nothing happens over a menu, during initials
    /// entry, after game over or while the P pause already holds the game.
    func pauseForInactivity() {
        releaseAllInput()
        guard pauseWhenInactive, autoPauseAllowed, !stopped, !settingsOpen, !paused, !gameOver, overlay.mode == .none else { return }
        openMenu()
    }

    /// The Settings sheet is up (Cmd-, or the pause menu's Settings…).
    private(set) var settingsOpen = false
    /// Settings paused the game itself (it was running when Cmd-, was pressed).
    private(set) var pausedForSettings = false

    /// Settings opens over the running table: held input is dropped and a running game pauses
    /// (the P pause: frozen, music paused, the pause sign in the strip) instead of opening the pause
    /// menu, whatever "Pause when inactive" says. Over the pause menu, the initials entry or the
    /// game-over panel nothing else changes (the game is not running there).
    func settingsWillOpen() {
        releaseAllInput()
        settingsOpen = true
        pausedForSettings = false
        if !paused, !gameOver, overlay.mode == .none, !stopped {
            setPaused(true)
            pausedForSettings = true
        }
    }

    /// Settings closed: back to the game as it was left. A game Settings paused stays paused (P or
    /// the menu continues it); opened from the pause menu, the pause menu is shown again.
    func settingsDidClose() {
        settingsOpen = false
        releaseAllInput()
        if pausedForSettings, paused {
            hud.show("Paused: press \(bindings.label(.pause)) to continue", seconds: 3)
        }
        pausedForSettings = false
    }

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
        case .screenshot: requestScreenshot()
        case .perfOverlay: togglePerfOverlay()
        case .saveState: saveState()
        case .loadState: loadState()
        default: break
        }
    }

    /// Keys while an overlay is up (menu navigation, initials).
    private func overlayKey(_ code: UInt16, isRepeat: Bool) {
        let actions = bindings.actions(for: code)
        if overlay.mode != .initials, !isRepeat {
            if actions.contains(.screenshot) { requestScreenshot(); return }
            if actions.contains(.perfOverlay) { togglePerfOverlay(); return }
        }
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
        updateOverlaySession()
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
        case .practice: enterPractice()
        case .endPractice: session = .normal; newGame(); updateWindowTitle()
        case .saveState: saveState(); closeMenu()
        case .loadState: loadState()
        case .saveReplay: saveLastReplay()
        case .watchReplay: if let u = lastReplayURL { setOverlay(.none); onWatchReplay?(u) }
        case .watchAgain: newGame()
        }
    }

    /// R: a new game with the rules (the original's pause-menu restart), or a new ball without them.
    func newGame() {
        if attract.active { attract.session = nil; sim.engine.attractLaunch = false }
        startFreshGame(options: rulesOptions)
    }

    /// A new game with `options` (a demo game when `options.demo`): no overlay, not paused. The
    /// engine starts from its power-on snapshot (replays), and a game left early goes into the
    /// statistics first; while watching, the replay's recorded start is used instead (Watch again).
    func startFreshGame(options: RulesOptions) {
        recordAbandonedGame()
        gameAutopiloted = false
        statsTracker.ballsPerGame = options.ballsPerGame
        recorder?.cancel()
        recorder = nil
        practiceRecorder?.cancel()
        practiceRecorder = nil
        if let rp = replayPlayer {
            // Watch again: the recorded start (physics, options) on the power-on engine.
            let h = rp.replay.header
            if let c = h.enhancedConfig { sim.enhancedConfig = c }
            sim.physicsMode = h.physics
            sim.newGame(options: h.rulesOptions, powerOn: powerOn)
            replayPlayer = ReplayPlayer(replay: rp.replay)
            replayPlayer?.speed = rp.speed
            replayDone = false
        } else if sim.engine.rules != nil {
            sim.newGame(options: options, powerOn: powerOn)
        } else {
            sim.resetBall()
        }
        gameOver = false
        lastReplay = nil
        lastReplayKept = nil
        pendingInitials = []
        attract.touched = false
        attract.idle = 0
        setOverlay(.none)
        setPaused(false)
        camera.snap(toBallY: sim.renderBallTopLeft.y + 7)
        if let p = presentation { p.camera.snap(maxBallY: ClassicPresentation.maxActiveBallY(sim.engine), cameraMax: p.cameraMax) }
        beginGame()
    }

    func setPaused(_ on: Bool) {
        paused = on
        hud.paused = on
        presentation?.paused = on || gameOver
        audio?.setPaused(on)
        lastTime = nil
    }

    // MARK: high scores

    /// The rules reported game over (the original calls pause_menu here, EP1 cs:3529).
    func rulesGameOver(_ st: PresentationState) {
        gameOver = true
        presentation?.paused = true   // the original enters its menu here (pause_menu)
        // pause_menu's quit path fades out (EP1 cs:14FA -> cs:136F, entries 0..254): EP1-EP8 the passes before
        // the final-score screen now, the rest when the next game starts
        if let m = sim.engine.rules?.screenMachine() {
            screenFade?.gameOver(from: m)
            presentation?.screenOverrides = screenFade?.current
        }
        handleGameOver(st)
    }

    func handleGameOver(_ st: PresentationState) {
        let n = max(1, min(st.playerCount, st.scores.count))
        overlay.finalScores = Array(st.scores.prefix(n))
        overlay.highlight = []
        if session == .watching { return }   // the end of the replay shows its own panel
        finishRecording(scores: overlay.finalScores)
        guard recordsResults else { showGameOverPanel(); return }   // practice: no high scores
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
            var e = HighScoreEntry(initials: overlay.initials.text, score: p.score, date: Date(),
                                   players: overlay.finalScores.count, player: p.player, physics: sim.physicsMode.rawValue)
            e.replay = keepHighScoreReplay(initials: e.initials, player: p.player)
            defer { pruneReplays() }
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
        updateOverlaySession()
        overlay.tableName = tableName
        overlay.entries = highScores?.entries(table: table) ?? []
        overlay.index = 0
        setOverlay(.gameOver)
    }

    // MARK: statistics

    /// A game left before game over (new game, table change, quit) goes into the statistics.
    /// Only normal games count (`recordsResults`): practice and watched replays are not fed to the
    /// tracker, and a normal game turned into practice is closed as abandoned first (`enterPractice`).
    private func recordAbandonedGame() {
        guard let g = statsTracker.abandon(physics: sim.physicsMode.rawValue), recordsStatistics, let st = stats else { return }
        st.record(g, table: table)
        onScoresChanged?()
    }

    /// One original frame's rules output for the statistics (only while `recordsStatistics`).
    func trackStatistics(_ st: PresentationState) {
        guard let book = stats, recordsStatistics,
              let g = statsTracker.frame(st, physics: sim.physicsMode.rawValue, frameSeconds: sim.frameDuration) else { return }
        book.record(g, table: table)
        onScoresChanged?()
    }

    /// Before frames run: a game the auto-player drives is automated for the statistics.
    func noteInputSource() {
        if sim.inputProvider != nil, session != .watching { gameAutopiloted = true }
    }

    // MARK: screenshot and performance overlay

    /// Screenshot key / Game > Save Screenshot: the next output frame is written as a PNG to
    /// `screenshotDirectory`. The drawable must be readable for that, so the view leaves
    /// framebuffer-only mode for the frames until the capture (and goes back after it).
    func requestScreenshot() {
        guard let v = view else { return }
        screenshotRequested = true
        if v.framebufferOnly { v.framebufferOnly = false }
    }

    private func captureScreenshot(_ tex: MTLTexture, commandBuffer cb: MTLCommandBuffer) {
        guard !tex.isFramebufferOnly else { return }   // a drawable from before the switch: wait
        screenshotRequested = false
        if capturePath == nil { view?.framebufferOnly = true }
        guard let buf = encodeReadback(tex, cb) else { statusHUD.flash("Screenshot failed"); return }
        let url = Self.screenshotURL(in: screenshotDirectory, table: tableName.isEmpty ? "Table \(table)" : tableName, date: Date())
        let w = tex.width, h = tex.height
        nonisolated(unsafe) let pixels = buf
        cb.addCompletedHandler { [weak self] _ in
            // Off the main thread: the GPU has finished the frame and its copy.
            let result: String
            do {
                try Self.writePNG(bgra: pixels, width: w, height: h, to: url)
                result = "Screenshot saved: \(url.lastPathComponent)"
                print("screenshot: wrote \(url.path) (\(w)x\(h))")
            } catch {
                result = "Screenshot failed: \(error.localizedDescription)"
                warn("screenshot to \(url.path) failed: \(error)")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.statusHUD.flash(result) } }
        }
    }

    /// `<folder>/<table name> 2026-10-01 at 14.03.27.png` (a numbered suffix if that exists).
    nonisolated static func screenshotURL(in dir: URL, table: String, date: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let safe = table.map { "/:\\".contains($0) ? "-" : $0 }.reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespaces)
        let base = "\(safe.isEmpty ? "Epic Pinball" : safe) \(f.string(from: date))"
        var url = dir.appendingPathComponent(base + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).png")
            n += 1
        }
        return url
    }

    /// Blits `tex` (BGRA8) into a shared buffer at the end of `cb`; nil if Metal refuses.
    private func encodeReadback(_ tex: MTLTexture, _ cb: MTLCommandBuffer) -> MTLBuffer? {
        guard let buf = renderer.device.makeBuffer(length: tex.width * tex.height * 4, options: .storageModeShared),
              let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: tex.width, height: tex.height, depth: 1), to: buf,
                  destinationOffset: 0, destinationBytesPerRow: tex.width * 4, destinationBytesPerImage: tex.width * tex.height * 4)
        blit.endEncoding()
        return buf
    }

    /// The read-back drawable (BGRA) as an sRGB PNG (`PNGWriter`, as `--snapshot` writes them).
    nonisolated static func writePNG(bgra buf: MTLBuffer, width: Int, height: Int, to url: URL) throws {
        let n = width * height
        let src = buf.contents().bindMemory(to: UInt8.self, capacity: n * 4)
        var rgba = [UInt8](repeating: 255, count: n * 4)
        for i in 0..<n {  // BGRA -> RGBA
            rgba[i * 4] = src[i * 4 + 2]; rgba[i * 4 + 1] = src[i * 4 + 1]; rgba[i * 4 + 2] = src[i * 4]
        }
        try PNGWriter.write(rgba: rgba, width: width, height: height, to: url)
    }

    /// Debug key / View > Performance Overlay: flips the setting (or the session's overlay
    /// without a settings store).
    func togglePerfOverlay() {
        if let s = store { s.frontEnd.showPerfOverlay.toggle() } else { setPerfOverlay(perf == nil) }
    }

    /// `EPIC_PINBALL_TEST_FLIPPER`: synthetic key down / up of the left flipper's first ordinary
    /// (non-modifier) key, sent to the window like a real press, every 0.5 s.
    private func startTestFlipperTaps() {
        let mods = Set(KeyCode.modifierMasks.map(\.code))
        guard let code = bindings.keys(.leftFlipper).first(where: { !mods.contains($0) }) else { return }
        func send(_ type: NSEvent.EventType) {
            guard let w = view?.window,
                  let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                           isARepeat: false, keyCode: code) else { return }
            w.sendEvent(e)
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                send(.keyDown)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { send(.keyUp) } }
            }
        }
    }

    private func setPerfOverlay(_ on: Bool) {
        guard on != (perf != nil) else { return }
        perf = on ? PerfMeter() : nil
        statusHUD.perf = on ? ["measuring…"] : nil
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
            var presses = g.menuPresses()
            padInput = g.frameInput()
            if !presses.isEmpty || !padInput.isEmpty, attractInput() { presses = []; padInput = [] }
            for b in presses { pad(b) }
        }
        if session == .watching {
            // the replay sets the input of every frame
        } else if overlay.active {
            sim.input = []
        } else {
            if !padInput.isEmpty { sim.inputProvider = nil; attract.touched = true }
            sim.input = bindings.frameInput(held: keyboard.held).union(padInput)
        }

        noteInputSource()

        // The visible fades run one DAC frame per original frame; play waits for them (the original's main
        // loop starts after its boot fade-in), the Esc menu and the P pause do not.
        var fading = false
        if var f = screenFade {
            if f.blocksPlay {
                fading = true
                fadeClock += min(dt, 0.1)
                while f.blocksPlay, fadeClock >= sim.frameDuration { fadeClock -= sim.frameDuration; f.step() }
            } else {
                fadeClock = 0
                f.step()   // back to the rules' palette, unless a game-over fade-out holds
            }
            screenFade = f
            presentation?.screenOverrides = f.current
        }
        let simStart = CACurrentMediaTime()
        let ran: Int
        if let rp = replayPlayer {
            ran = paused || overlay.active || replayDone || fading ? 0 : rp.advance(sim, by: dt)
        } else {
            ran = paused || gameOver || overlay.active || fading ? 0 : sim.advance(by: dt)
        }
        let simEnd = CACurrentMediaTime()
        let perfKey = perf?.frame(now: simEnd, ran: ran, simSeconds: simEnd - simStart,
                                  flipperHeld: !sim.input.isDisjoint(with: [.leftFlipper, .rightFlipper]))
        // Rules output once per original frame (sounds of every frame in order); the renderer takes
        // the latest, the audio engine every frame's effects.
        var frameStates: [(PresentationState, DotMessage?)] = []
        if demo == nil, let src = presentationSource {
            for _ in 0..<ran { if let st = src() { frameStates.append(st) } }
        }
        var demoOver = false
        for (st, _) in frameStates {
            audio?.present(st)
            lastState = st
            trackStatistics(st)
            if st.gameOver && attract.active { demoOver = true; break }   // the demo quits: no high scores
            if st.gameOver && !gameOver { rulesGameOver(st) }
        }
        if let rp = replayPlayer {
            if ran > 0 { followPhysics() }   // the replay's physics switches
            watchingFrames(rp, ran: ran)
        }
        if ran > 0, session == .practice { practiceTestHook() }
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
                    // Per-frame events of the previous state must not be fed again.
                    st.texts = []; st.spriteSets = []; st.soundEvents = []; st.music = nil
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
        if demoOver { attractGameOver() } else { attractTick(dt: dt) }

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
        reportRenderStatus()
        if let p = perf, !p.summary.isEmpty, statusHUD.perf != p.summary { statusHUD.perf = p.summary }
        if let k = perfKey {
            drawable.addPresentedHandler { [weak self] d in
                let t = d.presentedTime
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.perf?.presented(keyTime: k, at: t) } }
            }
        }
        if screenshotRequested { captureScreenshot(drawable.texture, commandBuffer: cb) }
        if startTime == nil {
            startTime = now
            // Smoke-test hook: open the pause menu after the first frame.
            if ProcessInfo.processInfo.environment["EPIC_PINBALL_TEST_MENU"] != nil {
                DispatchQueue.main.async { [weak self] in self?.openMenu() }
            }
            // Smoke-test hook: press the screenshot key after the first frame.
            if ProcessInfo.processInfo.environment["EPIC_PINBALL_TEST_SCREENSHOT"] != nil { requestScreenshot() }
            // Smoke-test hook: tap the left flipper key twice a second through the window's key path.
            if ProcessInfo.processInfo.environment["EPIC_PINBALL_TEST_FLIPPER"] != nil { startTestFlipperTaps() }
            // Smoke-test hook: EPIC_PINBALL_TEST_KEY=S:CODE presses key CODE (a macOS key code) after S seconds.
            if let k = ProcessInfo.processInfo.environment["EPIC_PINBALL_TEST_KEY"]?.split(separator: ":"), k.count == 2,
               let t = Double(k[0]), let c = UInt16(k[1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                    print("test key \(c) at \(t) s (attract \(self?.attract.active ?? false))")
                    _ = self?.keyDown(c, isRepeat: false)
                    self?.keyUp(c)
                }
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
        let readback = capturePath != nil && !view.framebufferOnly ? encodeReadback(tex, cb) : nil
        cb.present(drawable)
        cb.commit()
        cb.waitUntilCompleted()
        let scale = view.window?.backingScaleFactor ?? 1
        if let a = audio {
            print("audio: \(a.effectsSubmitted) effects submitted, music \(a.musicPaused ? "paused" : "playing"), dropped commands \(a.engine.droppedCommands), resampling \(a.engine.interpolation.rawValue)")
        } else {
            print("audio: off")
        }
        print("rules: " + (sim.engine.rules.map { "\($0.backend.rawValue)" } ?? "none (\(sim.engine.rulesLoadError ?? "not requested"))"))
        let rs = renderer.settings
        print("render: filter \(rs.filter.rawValue), hd pack \(renderer.hdPackActive ? "active" : (rs.useHDPack ? "requested, none found" : "off")), "
              + "lighting \(rs.lighting.rawValue), interpolate \(rs.interpolate), scaling \(rs.scaling.rawValue), full table \(camera.showFullTable)"
              + ", settings status \"\(lastRenderStatus ?? "none")\""
              + (rs.rotation == .none ? "" : ", rotation \(rs.rotation.rawValue)")
              + (rs.filter == .crt ? String(format: ", crt scanlines %.2f curvature %.3f mask %.2f", rs.crtScanlines, rs.crtCurvature, rs.crtMask) : "")
              + ", round dots \(rs.roundDots), strip in full table \(rs.stripInFullTable), rotate flippers \(rs.rotateFlippers)"
              + (renderer.hdPackWarnings.isEmpty ? "" : ", hd warnings: \(renderer.hdPackWarnings.joined(separator: "; "))"))
        print("game: score \(sim.engine.rules?.score ?? 0), game over \(gameOver), paused \(paused), overlay \(overlay.mode), attract \(attract.active), "
              + "high scores on table \(table): \(highScores?.entries(table: table).count ?? 0)")
        if let st = stats {
            let byMode = st.stats(table: table).sorted { $0.key < $1.key }
                .map { "\($0.key) games \($0.value.games) balls \($0.value.balls) best \($0.value.bestScore) time \(String(format: "%.1f", $0.value.playSeconds)) s" }
            print("stats: table \(table): " + (byMode.isEmpty ? "none" : byMode.joined(separator: "; ")) + ", current game " + (statsTracker.active ? "running" : "none"))
        }
        if let lines = statusHUD.perf { print("perf overlay: " + lines.joined(separator: " | ")) }
        print("focus: app active \(NSApp.isActive), window key \(view.window?.isKeyWindow ?? false), pause when inactive \(pauseWhenInactive && autoPauseAllowed)")
        if let t = statusHUD.toast { print("hud: \(t)") }
        print("session: \(session), recording \(recorder != nil), last replay \(lastReplay.map { "\($0.header.frames) frames" } ?? "none")"
              + (replayPlayer.map { ", replay frame \($0.frame)/\($0.frameCount) at \(Int($0.speed))x, finished \($0.finished)" } ?? "")
              + (overlay.note.map { ", note: \($0)" } ?? "") + (testStatesLog.isEmpty ? "" : ", states: \(testStatesLog.joined(separator: "; "))"))
        print("smoke test: \(frames) frames in \(String(format: "%.2f", elapsed)) s, drawable \(tex.width)x\(tex.height) (\(tex.pixelFormat == .bgra8Unorm ? "bgra8Unorm" : "format \(tex.pixelFormat.rawValue)")), backing scale \(scale), engine frames \(sim.engine.frameCount), display \(view.preferredFramesPerSecond) fps requested (screen max \(view.window?.screen?.maximumFramesPerSecond ?? 0), high refresh \(highRefresh), interpolation \(renderer.interpolation != nil), physics \(sim.physicsMode.rawValue)" + (sim.physicsMode == .enhanced ? " preset \(sim.enhanced?.config.preset.rawValue ?? "-")" : "") + ")")
        if let buf = readback, let path = capturePath {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            do {
                try Self.writePNG(bgra: buf, width: tex.width, height: tex.height, to: url)
                print("wrote \(url.path)")
            } catch {
                FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
            }
        }
        if statusHUD.perf != nil || statusHUD.toast != nil, let path = capturePath, let host = hudHost,
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            // The HUD (performance overlay, screenshot confirmation) is not in the drawable either.
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = URL(fileURLWithPath: ((path as NSString).expandingTildeInPath as NSString).deletingPathExtension + "-status.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("wrote \(url.path) (status hud)")
        }
        if let sw = scoreWindow {
            print(sw.summary)
            if let path = capturePath, let shot = try? sw.renderOffscreen() {
                let url = URL(fileURLWithPath: ((path as NSString).expandingTildeInPath as NSString).deletingPathExtension + "-score.png")
                try? PNGWriter.write(rgba: shot.pixels, width: shot.width, height: shot.height, to: url)
                print("wrote \(url.path) (score window strip, \(shot.width)x\(shot.height))")
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
        if session != .normal, let path = capturePath,
           let hudHost = overlayHost?.superview?.subviews.first(where: { $0 is NSHostingView<GameHUDView> }),
           let rep = hudHost.bitmapImageRepForCachingDisplay(in: hudHost.bounds) {
            // The practice / replay banner, captured like the overlay.
            hudHost.cacheDisplay(in: hudHost.bounds, to: rep)
            let url = URL(fileURLWithPath: ((path as NSString).expandingTildeInPath as NSString).deletingPathExtension + "-hud.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("wrote \(url.path) (hud \(session))")
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

// MARK: - Replays and practice

extension GameController {
    /// After the screen is built: banner, menus and the first game's recording.
    func beginSession() {
        hud.onPauseToggle = { [weak self] in self?.toggleReplayPause() }
        hud.onSpeed = { [weak self] in self?.setReplaySpeed($0) }
        hud.onExit = { [weak self] in self?.onReturnToPicker?() }
        if let rp = replayPlayer {
            hud.speed = Int(rp.speed)
            let notes = ReplayPlayer.notes(for: rp.replay.header, simulation: sim, dataRoot: dataRoot, originalDir: originalDir)
            if !notes.isEmpty { hud.show("This replay may not play back exactly: " + notes.joined(separator: "; "), seconds: 6) }
            // the 1 / 2 / 4 keys (key codes 18 / 19 / 21) through the key path
            if let v = ProcessInfo.processInfo.environment["EPIC_PINBALL_TEST_REPLAY_SPEED"], let c = ["1": 18, "2": 19, "4": 21][v] {
                _ = keyDown(UInt16(c), isRepeat: false)
            }
        }
        beginGame()
    }

    /// A game starts (first one or `newGame`): a normal game with rules is recorded from frame 0,
    /// and so is a practice game (`practiceRecorder`: never written as a replay, it is what the save
    /// states store on disk).
    func beginGame() {
        // the table boots: its fade-in from black (after the rest of a game-over fade-out)
        if screenFade != nil {
            screenFade?.boot()
            presentation?.screenOverrides = screenFade?.current
            fadeClock = 0
        }
        hud.session = session
        overlay.session = session
        replayDone = false
        hud.finished = false
        hud.progress = 0
        overlay.note = nil
        let practice = session == .practice
        guard (recordsResults && keepsReplays) || practice, sim.engine.rules != nil, sim.engine.frameCount == 0 else { recorder = nil; return }
        if fileDigests == nil, let root = dataRoot {
            var h = ReplayHeader(table: table, physics: .classic, enhancedConfig: nil,
                                 rulesBackend: sim.engine.rules?.backend.rawValue ?? "", options: RulesOptions())
            h.setDigests(dataRoot: root, originalDir: originalDir)
            fileDigests = (h.exeDigest, h.dataDigest)
        }
        let r = ReplayRecorder(simulation: sim)
        let d = fileDigests
        r.describe { h in
            h.appVersion = ReplayLibrary.appVersion
            h.exeDigest = d?.exe
            h.dataDigest = d?.data
        }
        if practice { practiceRecorder = r } else { recorder = r }
    }

    /// Game over of a recorded game: the replay becomes the table's last game.
    fileprivate func finishRecording(scores: [UInt32]) {
        guard let r = recorder else { return }
        recorder = nil
        let replay = r.finish(scores: scores, gameOver: true)
        lastReplay = replay
        lastReplayKept = nil
        overlay.replaySaved = false
        do { try replays.saveLast(replay) } catch { warn("cannot save the replay: \(error)") }
        onScoresChanged?()   // the launcher's replay lists
    }

    /// The replay file a new high-score entry links to (one file for all players of the game).
    fileprivate func keepHighScoreReplay(initials: String, player: Int) -> String? {
        guard keepsReplays, var r = lastReplay else { return nil }
        if let k = lastReplayKept { return k }
        r.header.initials = initials
        r.header.player = player
        do {
            let name = try replays.keep(r, kind: .highScore)
            lastReplayKept = name
            return name
        } catch {
            warn("cannot keep the high-score replay: \(error)")
            return nil
        }
    }

    /// Deletes high-score replays of this table that no entry links to any more.
    fileprivate func pruneReplays() {
        guard keepsReplays, let hs = highScores else { return }
        replays.prune(table: table, referenced: Set(hs.entries(table: table).compactMap(\.replay)))
    }

    /// Game-over panel: Save Replay keeps the last game for good.
    fileprivate func saveLastReplay() {
        guard let r = lastReplay, !overlay.replaySaved else { return }
        do {
            _ = try replays.keep(r, kind: .saved)
            overlay.replaySaved = true
            onScoresChanged?()
            hud.show("Replay saved")
        } catch {
            hud.show("The replay could not be saved: \(error)")
        }
    }

    /// "(Practice)" / "(Replay)" after the table name, following the session.
    fileprivate func updateWindowTitle() {
        guard let w = view?.window else { return }
        var t = w.title
        for suffix in [" (Practice)", " (Replay)"] where t.hasSuffix(suffix) { t.removeLast(suffix.count) }
        w.title = t + (session == .practice ? " (Practice)" : session == .watching ? " (Replay)" : "")
    }

    fileprivate var lastReplayURL: URL? { lastReplay.flatMap { replays.lastURL(table: $0.header.table) } }

    fileprivate func updateOverlaySession() {
        overlay.session = session
        overlay.replayAvailable = keepsReplays && lastReplay != nil
        overlay.stateSlot = stateSlot
        overlay.stateSaved = slotHasState(stateSlot)
        switch session {
        case .normal: overlay.note = nil
        case .practice: overlay.note = "Practice games are not scored."
        case .watching: break   // set when the replay ends
        }
    }

    /// Pause menu > Practice Mode: the running game continues as a practice game (it can never enter
    /// the high scores or statistics). Its recording goes on as the practice recording, so states
    /// saved from it can be written to disk; it is no longer written as a replay.
    fileprivate func enterPractice() {
        recordAbandonedGame()   // the normal part of the game goes into the statistics
        session = .practice
        practiceRecorder?.cancel()
        practiceRecorder = recorder
        recorder = nil
        hud.session = .practice
        updateWindowTitle()
        closeMenu()
        hud.show("Practice mode: K saves the state, L restores it, 1-\(PracticeStateFile.slotCount) choose the slot", seconds: 3)
    }

    /// The current slot has a state this session or a file on disk.
    func slotHasState(_ slot: Int) -> Bool {
        practiceSlots[slot] != nil || (practiceStore?.exists(table: table, slot: slot) ?? false)
    }

    /// The final scores the game shows now (for the state file).
    private var currentScores: [UInt32] {
        let st = lastState ?? PresentationState()
        return Array(st.scores.prefix(max(1, min(st.playerCount, st.scores.count))))
    }

    /// Digit keys 1-4 in a practice game: the slot K saves to and L restores from.
    func selectStateSlot(_ slot: Int) {
        guard session == .practice, (1...PracticeStateFile.slotCount).contains(slot) else { return }
        stateSlot = slot
        overlay.stateSlot = slot
        overlay.stateSaved = slotHasState(slot)
        hud.slot = slot
        let what: String
        if let s = practiceSlots[slot] {
            what = "frame \(s.sim.frame)"
        } else if practiceStore?.exists(table: table, slot: slot) == true {
            what = "saved state on disk"
        } else {
            what = "empty"
        }
        hud.show("Slot \(slot): \(what)")
    }

    /// K: the whole simulation (engine, rules data segment and MiniX86, physics model, presentation)
    /// into the current slot, and the game up to here into the slot's file
    /// (`<support>/SaveStates/EPn-slotK.epstate`).
    func saveState() {
        guard session == .practice else {
            if session == .normal { hud.show("Save states work in practice games (Esc > Practice Mode)") }
            return
        }
        let replay = practiceRecorder?.snapshot(scores: currentScores)
        let slot = stateSlot
        practiceSlots[slot] = PracticeSlot(sim: sim.snapshot(), presentation: presentation?.save(), camera: camera,
                                           gameOver: gameOver, replay: replay)
        overlay.stateSaved = true
        var note = ""
        if let store = practiceStore {
            if let r = replay {
                do {
                    let f = PracticeStateFile(table: table, slot: slot, frame: r.header.frames, scores: r.header.finalScores,
                                              gameOver: gameOver, physics: sim.physicsMode,
                                              enhancedConfig: sim.physicsMode == .enhanced ? sim.enhancedConfig : nil,
                                              digest: r.header.finalDigest, replay: try r.encoded())
                    try store.write(f)
                } catch {
                    note = " (not written to disk: \(error.localizedDescription))"
                    warn("practice state slot \(slot): \(error)")
                }
            } else {
                note = " (this session only: the game was not recorded from its start)"
            }
        }
        hud.show("Slot \(slot): state saved (frame \(sim.engine.frameCount))" + note)
    }

    /// L: back to the current slot's state; the game continues exactly as it did from there. A
    /// state of this session is restored at once; otherwise the slot's file is read and its game
    /// re-simulated up to the saved frame (`restoreFromDisk`).
    func loadState() {
        guard session == .practice else { return }
        let slot = stateSlot
        if let s = practiceSlots[slot] {
            restore(s)
            hud.show("Slot \(slot): state restored (frame \(sim.engine.frameCount))")
            return
        }
        guard let store = practiceStore else { hud.show("Slot \(slot) is empty (K saves one)"); return }
        switch store.load(table: table, slot: slot) {
        case .missing:
            hud.show("Slot \(slot) is empty (K saves one)")
        case let .damaged(_, moved):
            hud.show("Slot \(slot)'s file could not be read" + (moved.map { "; kept aside as \($0.lastPathComponent)" } ?? ""), seconds: 4)
            overlay.stateSaved = slotHasState(slot)
        case let .unsupported(why):
            hud.show("Slot \(slot) cannot be loaded: \(why)", seconds: 4)
        case let .ok(file, replay):
            restoreFromDisk(file, replay)
        }
    }

    /// A slot of this session back on the table.
    private func restore(_ s: PracticeSlot) {
        practiceRecorder?.cancel()
        practiceRecorder = nil
        sim.restore(s.sim)
        // The practice recording continues from the slot's game (after the restore, which may
        // install a physics model).
        practiceRecorder = s.replay.map { ReplayRecorder(resuming: $0, simulation: sim) }
        syncPhysicsSettings()
        if let p = presentation, let ps = s.presentation { p.restore(ps) }
        camera = s.camera
        afterRestore(gameOver: s.gameOver)
    }

    /// A state from disk: a new game from the power-on state with the stored game's start (physics,
    /// options), its frames re-simulated (rules output into the presentation, no drawing or sound),
    /// then the digest compared with the saved one. Fails without changing the game when the rules
    /// backend differs (the frames would mean something else).
    private func restoreFromDisk(_ file: PracticeStateFile, _ replay: Replay) {
        let slot = file.slot
        let h = replay.header
        guard let rules = sim.engine.rules, let powerOn else {
            hud.show("Slot \(slot) needs the table rules, which are not loaded", seconds: 4); return
        }
        guard rules.backend.rawValue == h.rulesBackend else {
            hud.show("Slot \(slot) was saved with the \(h.rulesBackend) rules; this table runs the \(rules.backend.rawValue) rules", seconds: 4)
            return
        }
        let started = CACurrentMediaTime()
        practiceRecorder?.cancel()
        practiceRecorder = nil
        let provider = sim.inputProvider
        if let c = h.enhancedConfig { sim.enhancedConfig = c }
        sim.physicsMode = h.physics
        sim.newGame(options: h.rulesOptions, powerOn: powerOn)
        let player = ReplayPlayer(replay: replay)
        var last: PresentationState?
        while player.stepFrame(sim) {
            let st = sim.takePresentation()
            last = st
            if let p = presentation {
                p.ingest(st)
                p.stepFrame(engine: sim.engine, manualY: nil)
            }
        }
        sim.inputProvider = provider   // ReplayPlayer drives the input itself; --autopilot continues
        if let l = last { lastState = l }
        practiceRecorder = ReplayRecorder(resuming: replay, simulation: sim)
        // A physics switch made after the last recorded frame (E, then K): as the key did it.
        if file.physics != sim.physicsMode || (file.physics == .enhanced && file.enhancedConfig.map { $0 != sim.enhancedConfig } == true) {
            if let c = file.enhancedConfig { sim.enhancedConfig = c }
            sim.physicsMode = file.physics
        }
        syncPhysicsSettings()
        camera.snap(toBallY: sim.renderBallTopLeft.y + 7)
        afterRestore(gameOver: file.gameOver)
        let digest = sim.stateDigest().hex
        let exact = digest == file.digest && sim.engine.frameCount == file.frame
        practiceSlots[slot] = PracticeSlot(sim: sim.snapshot(), presentation: presentation?.save(), camera: camera,
                                           gameOver: gameOver, replay: replay)
        let secs = String(format: "%.1f s", CACurrentMediaTime() - started)
        let notes = ReplayPlayer.notes(for: h, simulation: sim, dataRoot: dataRoot, originalDir: originalDir)
        hud.show("Slot \(slot): state loaded (frame \(sim.engine.frameCount), \(secs))"
                 + (exact ? "" : "; not exactly the saved state" + (notes.first.map { " (\($0))" } ?? "")), seconds: exact ? 2 : 5)
        testStatesLog.append("loaded slot \(slot) from disk -> frame \(sim.engine.frameCount) digest \(digest) "
                             + (exact ? "(equals the saved digest)" : "(saved \(file.digest))"))
        if !exact { warn("practice state slot \(slot): re-simulated to digest \(digest), saved \(file.digest); \(notes.joined(separator: "; "))") }
    }

    /// The stored physics setting (and preset) follow a restored state, so the next settings
    /// change does not switch back; so does the presentation mode.
    private func syncPhysicsSettings() {
        if let st = store {
            if st.game.physicsMode != sim.physicsMode { edit { $0.game.physicsMode = sim.physicsMode } }
            if sim.physicsMode == .enhanced, st.game.enhancedPreset != sim.enhancedConfig.preset,
               sim.enhancedConfig == .preset(sim.enhancedConfig.preset) {
                edit { $0.game.enhancedPreset = sim.enhancedConfig.preset }
            }
        }
        followPhysics()
    }

    private func afterRestore(gameOver over: Bool) {
        gameOver = over
        if let p = presentation { p.paused = over }
        screenFade?.cancel()   // the restored game goes on with its own palette
        presentation?.screenOverrides = nil
        pendingInitials = []
        manualY = nil
        audio?.stopEffects()
        if overlay.active { setOverlay(.none) }
        setPaused(false)
    }

    /// `EPIC_PINBALL_TEST_STATES=SAVE,LOAD`: save at engine frame SAVE, restore once at LOAD.
    /// `EPIC_PINBALL_TEST_LOAD_STATE=SLOT`: at the first frame select SLOT and restore it (a state
    /// saved by an earlier run: loaded from disk). Both go through the key path (bindings -> command).
    fileprivate func practiceTestHook() {
        let env = ProcessInfo.processInfo.environment
        if let v = env["EPIC_PINBALL_TEST_LOAD_STATE"], let slot = Int(v), !testLoadDone {
            testLoadDone = true
            let digit: [Int: UInt16] = [1: 18, 2: 19, 3: 20, 4: 21]
            if let c = digit[slot] { _ = keyDown(c, isRepeat: false); keyUp(c) }
            _ = keyDown(KeyCode.l, isRepeat: false); keyUp(KeyCode.l)
        }
        guard let v = env["EPIC_PINBALL_TEST_STATES"] else { return }
        let f = v.split(separator: ",").compactMap { Int($0) }
        guard f.count == 2 else { return }
        let n = sim.engine.frameCount
        let saved = practiceSlots[stateSlot] != nil
        if !saved, n >= f[0] {
            _ = keyDown(KeyCode.k, isRepeat: false); keyUp(KeyCode.k)
            testStatesLog.append("saved at \(n) digest \(sim.stateDigest().hex)")
        } else if saved, testStatesLog.count == 1, n >= f[1] {
            _ = keyDown(KeyCode.l, isRepeat: false); keyUp(KeyCode.l)
            testStatesLog.append("restored at \(n) -> frame \(sim.engine.frameCount) digest \(sim.stateDigest().hex)")
        }
    }

    // MARK: watching

    /// Keys while a replay plays: Space / P pause, 1 / 2 / 4 speed; the game keys do nothing. The
    /// view keys (strip, filter, full table, volume, scrolling) and Esc work as in a game.
    fileprivate func watchingKey(_ code: UInt16, isRepeat: Bool) -> Bool {
        let actions = bindings.actions(for: code)
        if code == KeyCode.space || actions.contains(.pause) {
            if !isRepeat { toggleReplayPause() }
            return true
        }
        switch code {
        case 18: setReplaySpeed(1); return true   // 1
        case 19: setReplaySpeed(2); return true   // 2
        case 21: setReplaySpeed(4); return true   // 4
        default: break
        }
        if actions.contains(where: { $0.isHeld && $0 != .scrollUp && $0 != .scrollDown }) || actions.contains(.saveState)
            || actions.contains(.loadState) {
            return true
        }
        return false
    }

    fileprivate func toggleReplayPause() {
        guard !replayDone else { return }
        setPaused(!paused)
    }

    fileprivate func setReplaySpeed(_ s: Int) {
        replayPlayer?.speed = Double(max(1, s))
        hud.speed = max(1, s)
    }

    fileprivate func watchingFrames(_ rp: ReplayPlayer, ran: Int) {
        if ran > 0, rp.frame % 15 < ran || rp.finished { hud.progress = Double(rp.frame) / Double(max(1, rp.frameCount)) }
        guard rp.finished, !replayDone else { return }
        replayDone = true
        hud.finished = true
        hud.progress = 1
        let h = rp.replay.header
        let st = lastState ?? sim.takePresentation()
        let n = max(1, min(st.playerCount, st.scores.count))
        let scores = Array(st.scores.prefix(n))
        let same = sim.stateDigest().hex == h.finalDigest && scores == h.finalScores
        overlay.finalScores = scores
        overlay.highlight = []
        overlay.note = same ? "The replay reached the recorded final state exactly (\(h.frames) frames)."
            : "The replay ended in a different state than recorded"
                + (ReplayPlayer.notes(for: h, simulation: sim, dataRoot: dataRoot, originalDir: originalDir).first.map { " (\($0))." } ?? ".")
        presentation?.paused = true
        showGameOverPanel()
    }
}
