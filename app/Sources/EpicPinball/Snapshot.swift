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

/// `--snapshot`: run the classic engine headless, render one frame with Metal, write a PNG.
enum SnapshotMode {
    static func run(options o: Options, assets: TableAssets, engine: ClassicEngine) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        let renderer = try PinballRenderer(device: device, assets: assets,
                                           flipperSprites: o.sprites ? loadFlipperSprites(assets: assets, engine: engine) : nil)
        renderer.aspect = o.aspect

        let sim = GameSimulation(engine: engine, mode: o.mode)
        var held: FrameInput = []
        if o.holdLeft { held.insert(.leftFlipper) }
        if o.holdRight { held.insert(.rightFlipper) }
        var ran = 0
        if let path = o.scenario {
            let sc = try Scenario.load(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            guard sc.table == assets.table else {
                throw ScenarioError.invalid("scenario is for table \(sc.table); pass --table \(sc.table)")
            }
            sc.apply(to: engine)
            if let gp = o.gravityPhase { engine.gravityPhase = gp }
            let frames = o.frames ?? sc.frames
            for f in 0..<frames {
                sim.input = sc.input(frame: f).union(held)
                sim.stepFrame()
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
                    ran += 1
                    stable = engine.plungerCharge == last ? stable + 1 : 0
                    last = engine.plungerCharge
                }
            }
            let frames = o.frames ?? Int((o.simTime * engine.data.timing.frameHz).rounded())
            for _ in 0..<frames {
                sim.input = held
                sim.stepFrame()
            }
            ran += frames
        }

        var camera = Camera()
        camera.showFullTable = o.full
        if let y = o.cameraY { camera.setY(y) } else { camera.snap(toBallY: sim.renderBallTopLeft.y + 7) }

        let scene = SceneState(simulation: sim, camera: camera, showSprites: o.sprites)
        let width: Int, height: Int
        if let size = o.size {
            (width, height) = size
        } else {
            let rows = Int(scene.viewHeight.rounded())
            let sy = o.aspect == .square ? o.scale : Int((Double(o.scale) * o.aspect.heightOverWidth).rounded())
            width = TableGeometry.width * o.scale
            height = rows * sy
        }
        let pixels = try renderer.renderOffscreen(scene: scene, width: width, height: height)
        let url = URL(fileURLWithPath: (o.snapshot! as NSString).expandingTildeInPath).standardizedFileURL
        try PNGWriter.write(rgba: pixels, width: width, height: height, to: url)
        let b = engine.balls[0]
        let flips = engine.groups.map { String($0.angle) }.joined(separator: ",")
        print("wrote \(url.path) (\(width)x\(height), table \(assets.table), \(o.full ? "full table" : "window top=\(camera.y)"), "
              + "\(ran) frames; ball x=\(b.x) y=\(b.y) vx=\(b.vx) vy=\(b.vy) active=\(b.active); flipper angles \(flips))")
    }
}
