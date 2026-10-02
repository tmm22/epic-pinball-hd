import Foundation
import Metal
import PinballCore
import PinballRender

/// Loads the flipper sprite frames for a table, warning about anything missing.
func loadFlipperSprites(assets: TableAssets, engine: ClassicEngine) -> FlipperSpriteSet? {
    let dir = assets.directory.appendingPathComponent("sprites", isDirectory: true)
    let (set, warnings) = FlipperSpriteSet.load(engine: engine.data, spriteDirectory: dir)
    for w in warnings { warn("\(w) (procedural flipper used)") }
    return set.isEmpty ? nil : set
}

/// PresentationState from the snapshot/demo flags (no rules interpreter involved).
@MainActor
func flagPresentation(_ o: Options, _ p: ClassicPresentation) -> PresentationState {
    var s = PresentationState()
    let g = p.composer.graphics
    s.lamps = (o.lamps ?? .none).states(count: g.lampCount, restIsA: g.lampRestIsA)
    s.scores = [o.score ?? 0]
    s.ballNumber = o.ballNumber ?? 1
    s.currentPlayer = (o.player ?? 1) - 1
    return s
}

@MainActor
func directMessage(_ spec: MessageSpec?, _ p: ClassicPresentation, lines: [MessageLineSpec] = []) -> DotMessage? {
    guard let m = spec else { return nil }
    guard let exe = p.exe else { warn("--message needs the original EXE (--original DIR)"); return nil }
    let text = exe.cString(at: m.exeOffset, max: 64)
    if text.isEmpty { warn(String(format: "--message: no string at file offset 0x%x", m.exeOffset)) }
    let extra = lines.map { DotLine(text: exe.cString(at: $0.exeOffset, max: 64), font8: $0.font8, di: $0.di) }
    return DotMessage(text: text, ax: m.ax ?? 0x101, di: m.di ?? (p.spec.messagesInStrip ? 3 : 12) * 320, appended: extra, colour: m.colour)
}

/// `--snapshot`: run the classic engine headless, render one frame with Metal, write a PNG.
enum SnapshotMode {
    @MainActor
    static func run(options o: Options, assets: TableAssets, engine: ClassicEngine, dataRoot: URL) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        let renderer = try PinballRenderer(device: device, assets: assets,
                                           flipperSprites: o.sprites ? loadFlipperSprites(assets: assets, engine: engine) : nil)
        renderer.aspect = o.aspect
        // Render flags (--filter, --hd-pack, --lighting, --render) on top of EPIC_PINBALL_RENDER / classic.
        if let s = o.renderSettings(base: renderer.settings) { renderer.settings = s }
        if let r = o.rotation { renderer.settings.rotation = r }
        var pres: ClassicPresentation?
        if !o.legacyWindow, o.sprites, let p = ClassicPresentation.load(assets: assets, engine: engine.data, dataRoot: dataRoot, originalDir: o.originalDir) {
            p.setStrip(shown: o.stripShown && !o.attract, immediately: true)   // attract: no split line, as in the app
            p.state = flagPresentation(o, p)
            p.directMessage = directMessage(o.message, p, lines: o.messageLines)
            p.paused = o.paused
            p.camera.snap(maxBallY: ClassicPresentation.maxActiveBallY(engine), cameraMax: p.cameraMax)
            renderer.attach(composer: p.composer)
            pres = p
        }

        var ro = o.rulesOptions
        if o.attract {
            // --attract: the original's demo (players 'D'), with the app's plunge on EP2-EP13
            ro.demo = true
            engine.attractLaunch = true
        }
        let sim = GameSimulation(engine: engine, mode: o.mode, options: ro, physics: o.physics)
        if o.attract && engine.attractLayout == nil { warn("--attract: no demo-mode code found for table \(assets.table)") }
        pres?.camera.snap(maxBallY: ClassicPresentation.maxActiveBallY(engine), cameraMax: pres?.cameraMax ?? 0x12A)
        let useRules = engine.rules != nil && !o.hasPresentationFlags
        func frameDone() {
            guard let p = pres else { return }
            if useRules { p.ingest(sim.takePresentation()) }
            p.stepFrame(engine: engine, manualY: nil)
        }
        var held: FrameInput = []
        if o.holdLeft { held.insert(.leftFlipper) }
        if o.holdRight { held.insert(.rightFlipper) }
        var ran = 0
        if let n = o.autoplay {
            // A mid-game frame: the auto-player plays n frames (plunge, flip) with the real rules.
            var player = AutoPlayer(engine: engine)
            for _ in 0..<n {
                sim.input = player.input(for: engine).union(held)
                sim.stepFrame()
                frameDone()
                if pres?.state.gameOver == true { break }
                ran += 1
            }
        } else if let path = o.scenario {
            let sc = try Scenario.load(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            guard sc.table == assets.table else {
                throw ScenarioError.invalid("scenario is for table \(sc.table); pass --table \(sc.table)")
            }
            sc.apply(to: engine)
            if let gp = o.gravityPhase { engine.gravityPhase = gp }
            let frames = o.frames ?? sc.frames
            pres?.camera.snap(maxBallY: ClassicPresentation.maxActiveBallY(engine), cameraMax: pres?.cameraMax ?? 0x12A)
            for f in 0..<frames {
                sim.input = sc.input(frame: f).union(held)
                sim.stepFrame()
                frameDone()
            }
            ran = frames
        } else {
            if o.launch {
                // Hold the plunger until the charge has stopped growing for a few frames (full charge;
                // the serve delay pauses it for one frame), then let go.
                var stable = 0, last = engine.plungerCharge
                while ran < 600 && (engine.plungerCharge == 0 || stable < 3) {
                    sim.input = held.union(.plunger)
                    sim.stepFrame()
                    frameDone()
                    ran += 1
                    stable = engine.plungerCharge == last ? stable + 1 : 0
                    last = engine.plungerCharge
                }
            }
            for _ in 0..<(o.holdPlunger ?? 0) {
                sim.input = held.union(.plunger)
                sim.stepFrame()
                frameDone()
                ran += 1
            }
            if o.holdPlunger != nil { held.insert(.plunger) }
            let frames = o.frames ?? Int((o.simTime * engine.data.timing.frameHz).rounded())
            for _ in 0..<frames {
                sim.input = held
                sim.stepFrame()
                frameDone()
            }
            ran += frames
        }

        var camera = Camera()
        camera.showFullTable = o.full
        if let p = pres {
            camera.windowHeight = Double(p.windowRows)
            camera.setY(o.cameraY ?? Double(p.camera.y))
        } else if let y = o.cameraY { camera.setY(y) } else { camera.snap(toBallY: sim.renderBallTopLeft.y + 7) }

        let scene = SceneState(simulation: sim, camera: camera, showSprites: o.sprites)
        if let p = pres {
            if useRules && ran == 0 { p.ingest(sim.takePresentation()) }
            p.apply(to: renderer, scene: scene, engine: engine)
        }
        var width: Int, height: Int
        if let size = o.size {
            (width, height) = size
        } else {
            let rows = Int(scene.viewHeight.rounded()) + renderer.visibleStripRows(for: scene)
            let sy = o.aspect == .square ? o.scale : Int((Double(o.scale) * o.aspect.heightOverWidth).rounded())
            width = TableGeometry.width * o.scale
            height = rows * sy
        }
        // Rotated without --size: the output is the upright image turned (portrait <-> landscape).
        let turned = o.size == nil && DisplayTransform(rotation: renderer.settings.rotation, outputWidth: 1, outputHeight: 1).swapsAxes
        if turned { (width, height) = (height, width) }
        let pixels = try renderer.renderOffscreen(scene: scene, width: width, height: height)
        let url = URL(fileURLWithPath: (o.snapshot! as NSString).expandingTildeInPath).standardizedFileURL
        try PNGWriter.write(rgba: pixels, width: width, height: height, to: url)
        if let sp = o.scoreSnapshot, let p = pres {
            // The score window's picture: the strip alone, all of its rows, turned by its own rotation
            // (--score-rotate; without --score-size a 90 / 270 image is the upright one turned).
            let rows = p.maxStripRows
            let sy = o.aspect == .square ? o.scale : Int((Double(o.scale) * o.aspect.heightOverWidth).rounded())
            let rot = o.scoreRotation ?? .none
            var (sw, sh) = o.scoreSize ?? (TableGeometry.width * o.scale, rows * sy)
            if o.scoreSize == nil, DisplayTransform(rotation: rot, outputWidth: 1, outputHeight: 1).swapsAxes { (sw, sh) = (sh, sw) }
            let px = try renderer.renderStripOffscreen(rows: rows, width: sw, height: sh, rotation: rot)
            let su = URL(fileURLWithPath: (sp as NSString).expandingTildeInPath).standardizedFileURL
            try PNGWriter.write(rgba: px, width: sw, height: sh, to: su)
            let lt = DisplayTransform(rotation: rot, outputWidth: sw, outputHeight: sh)
            let f = renderer.stripFit(rows: rows, outputWidth: lt.logicalWidth, outputHeight: lt.logicalHeight)
            print("wrote \(su.path) (score window \(sw)x\(sh), \(rows) strip rows at \(Int(f.x)),\(Int(f.y)) \(Int(f.width))x\(Int(f.height))"
                  + (rot == .none ? ")" : " upright, rotated \(rot.rawValue))"))
        }
        let b = engine.balls[0]
        let flips = engine.groups.map { String($0.angle) }.joined(separator: ",")
        if let p = pres {
            let c = p.composer
            print("presentation: graphics from \(c.graphics.source), window \(p.windowRows) rows + strip \(renderer.visibleStripRows(for: scene)) rows, "
                  + "lamps drawn \(p.state.lamps.count), message \(p.currentMessage().map { "\($0.text.count) chars ax=0x\(String($0.ax, radix: 16)) di=\($0.di)" } ?? "none")"
                  + ", filter \(renderer.settings.filter.rawValue)"
                  + (renderer.settings.rotation == .none ? "" : ", rotated \(renderer.settings.rotation.rawValue)")
                  + (renderer.settings.isClassic ? "" : ", enhanced render (hd pack \(renderer.hdPackActive ? "on" : "off"), lighting \(renderer.settings.lighting.rawValue))"))
            for w in renderer.hdPackWarnings { warn("HD pack: \(w)") }
            if ProcessInfo.processInfo.environment["EPIC_PINBALL_DEBUG_SPEC"] != nil { print("strip spec: \(c.spec)") }
        }
        print("wrote \(url.path) (\(width)x\(height), table \(assets.table), \(o.full ? "full table" : "window top=\(camera.y)"), "
              + "\(ran) frames; ball x=\(b.x) y=\(b.y) vx=\(b.vx) vy=\(b.vy) active=\(b.active); flipper angles \(flips))")
    }
}
