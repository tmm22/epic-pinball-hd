import Foundation
import PinballCore
import PinballRender

struct Options {
    var dataDir: String?
    var table = 1
    var snapshot: String?
    var full = false
    var scale = 3
    var size: (Int, Int)?
    var aspect: PixelAspect = .square
    var cameraY: Double?
    var simTime: Double = 0
    var launch = false
    var sprites = true
    var exitAfter: Double?
    var windowCapture: String?
    var holdLeft = false
    var holdRight = false
    var tableGiven = false
    var mode: SimulationMode = .classic
    var trace: String?
    var traceOut: String?
    var noExtra = false
    var traceState = false
    var traceSchema: String?
    var gravityPhase: Int?
    var scenario: String?
    var frames: Int?
    // Classic presentation (display strip, lamp overlays, messages)
    var originalDir: String?
    var filter: UpscaleFilter = .nearest
    var stripShown = true
    var legacyWindow = false
    var lamps: LampSpec?
    var score: UInt32?
    var ballNumber: Int?
    var player: Int?
    var message: MessageSpec?
    var messageLines: [MessageLineSpec] = []
    var demo = false
    var paused = false
    var holdPlunger: Int?
    // Game and audio
    var autoplay: Int?
    var autoplayJSON: String?
    var mute = false
    var noMusic = false
    var noSfx = false
    var volume: Double?
    var players = 1
    var balls = 3
    var requireRules = false
    var autopilot = false
    /// `--attract`: start in attract mode (the original's demo); `--attract-delay S`: idle time before it.
    var attract = false
    var attractDelay: Double?
    // Front end
    var launcher = false
    var forceImport = false
    var supportDir: String?
    var uiSnapshot: String?
    var uiScreen = "launcher"
    var autostart = false
    var importFrom: String?
    /// `--import-hd-packs S|skip`: the import-done screen's HD pack offer answered (scale, 0 = skip).
    var importHDPacks: Int?
    /// Ball physics (`--physics`): classic = the bit-exact integer engine, enhanced = EnhancedPhysics.
    var physics: GameSettings.PhysicsMode = .classic
    /// `--library DIR`: the imported library (instead of <support dir>/Library).
    var libraryDir: String?
    /// `--headless-import SRC`: import SRC (.iso or folder) into the library without a window, then exit.
    var headlessImport: String?
    /// `--rules lifted|direct`: the table-rules backend (sets $EPIC_PINBALL_RULES for this process).
    var rulesBackend: RulesBackend?
    /// Enhanced rendering from the command line (window direct starts and --snapshot).
    var filterGiven = false
    var renderSpec: String?
    var hdPack = false
    var lighting: RenderSettings.Lighting?
    var highRefreshFlag = false
    /// `--make-hd-pack N|all`: generate HD packs (Swift port of tools/hdpack/make_pack.py) and exit.
    var makeHDPack: [Int]?
    var scaleGiven = false
    /// `--hd-pack-out DIR`: packs root for --make-hd-pack (default <support dir>/HDPacks).
    var hdPackOut: String?
    var hdPackMethod = "xbrz"
    var verifyHDPack = false
    // Replays and practice (docs/enhanced/replays.md)
    /// `--record-replay FILE`: with --autoplay, write the game as a replay.
    var recordReplay: String?
    /// `--play-replay FILE`: re-simulate a replay headless and print the check (JSON).
    var playReplay: String?
    /// `--watch FILE`: window: watch a replay.
    var watchReplay: String?
    /// `--practice`: window direct start in practice mode (save states, no scores).
    var practice = false
    /// Cabinet display: `--rotate` (picture turned clockwise), `--score-window` (strip in its own
    /// window, direct starts), `--score-snapshot PATH` (snapshot: the strip as the score window draws it).
    var rotation: GameSettings.DisplayRotation?
    var scoreWindow = false
    /// `--score-rotate`: the score window's own picture rotation (window and --score-snapshot).
    var scoreRotation: GameSettings.DisplayRotation?
    var scoreSnapshot: String?
    var scoreSize: (Int, Int)?
    /// `--list-dylibs`: print the images loaded into the process and exit (packaging check).
    var listDylibs = false

    /// Start straight into a table (the behaviour of earlier builds, used by the smoke tests and
    /// developer flags); otherwise the launcher (or the import screen on first launch) opens.
    var directPlay: Bool {
        !launcher && !forceImport && (tableGiven || exitAfter != nil || windowCapture != nil || demo || autopilot || attract
            || hasPresentationFlags || message != nil || legacyWindow || watchReplay != nil || practice)
    }

    /// `--original DIR` as a URL (nil when not given: the loaders then use their own search order).
    var originalURL: URL? {
        originalDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL }
    }

    /// The game options PINBALL.EXE would pass (players, balls; sounds on, card present).
    var rulesOptions: RulesOptions {
        var r = RulesOptions()
        r.players = players
        r.ballsPerGame = balls
        return r
    }

    /// The render settings the command line asks for, on top of `base` (the renderer's current
    /// settings, i.e. `EPIC_PINBALL_RENDER` or classic); nil when no render flag was given.
    func renderSettings(base: RenderSettings) -> RenderSettings? {
        if let spec = renderSpec { return RenderSettings.fromEnvironment(["EPIC_PINBALL_RENDER": spec]) ?? base }
        guard filterGiven || hdPack || lighting != nil else { return nil }
        var s = base
        if filterGiven { s.filter = filter }
        if hdPack { s.useHDPack = true }
        if let l = lighting { s.lighting = l }
        return s
    }

    /// Any of the demo presentation flags given (they replace the rules' state).
    var hasPresentationFlags: Bool { lamps != nil || score != nil || ballNumber != nil || player != nil }

    static let usage = """
    usage: EpicPinball [--table N] [--data DIR | --library DIR] [--original DIR] [--aspect square|vga]
                       [--physics classic|enhanced] [--filter nearest|smooth|xbrz|crt] [--hd-pack]
                       [--lighting off|subtle|vivid] [--high-refresh] [--full] [--demo]
                       [--rotate 0|90|180|270] [--score-window] [--score-rotate 0|90|180|270]
           EpicPinball --headless-import CD.iso|FOLDER [--library DIR | --support-dir DIR]
           EpicPinball --snapshot OUT.png [--table N] [--full] [--scale N | --size WxH]
                       [--camera-y Y] [--sim-time S] [--launch] [--flip left|right|both]
                       [--scenario FILE --frames N] [--no-sprites]
                       [--strip on|off] [--lamps SPEC] [--score N] [--ball N] [--player N]
                       [--message OFFSET[:AX[:DI]]] [--pause] [--legacy-window]
                       [--rotate 0|90|180|270] [--score-snapshot OUT.png [--score-size WxH]]
                       [--score-rotate 0|90|180|270]
           EpicPinball --trace SCENARIO.json [--out TRACE.jsonl] [--no-extra] [--gravity-phase N] [--require-rules]
           EpicPinball --autoplay N [--table N] [--json OUT.json]      (headless game, no window)
                       [--record-replay OUT.epreplay]
           EpicPinball --make-hd-pack N|all [--scale 2...8] [--hd-method xbrz|nearest] [--verify-hd-pack]
                       [--hd-pack-out DIR] [--data DIR | --library DIR]
           EpicPinball --play-replay FILE.epreplay [--json OUT.json]    (re-simulate and check, no window)
           EpicPinball --watch FILE.epreplay | --practice [--table N]  (window)

      --data DIR       runtime data root (contains tables/EPn/): an imported library or a developer
                       extracted/ directory. Default: $EPIC_PINBALL_DATA, then (not inside a .app)
                       ../extracted relative to the Swift package, then the imported library.
      --library DIR    the imported library to use and import into (default: <support dir>/Library,
                       i.e. ~/Library/Application Support/EpicPinballHD/Library)
      --headless-import SRC  import SRC (the CD image .iso, or a folder with EP1.EXE ...) into the
                       library with the Swift importer, print progress and exit (no window)
      --make-hd-pack T generate the HD pack of table T (or all) from the data root without a window
                       and exit: --scale S (default 4), --hd-method xbrz (default) or nearest,
                       --verify-hd-pack runs the alignment check, --hd-pack-out DIR the packs root
                       (default <support dir>/HDPacks, where the app looks; EPn/ is appended)
      --rules B        table rules backend: direct (run from your EPn.EXE, default) or lifted
                       (rules.json); the same as EPIC_PINBALL_RULES=B
      --table N        table 1...13 (default 1)
      --aspect A       square (1:1 pixels, default) or vga (1.2 tall pixels, 4:3 CRT look)
      --snapshot PATH  render one frame offscreen to a PNG and exit (no window)
      --full           snapshot (or window direct start): the whole 320x400 table instead of the window
      --scale N        snapshot integer scale (default 3)
      --size WxH       snapshot output size in pixels (overrides --scale; letterboxed)
      --camera-y Y     snapshot window top row (default: follow the ball)
      --sim-time S     run the engine for S seconds (59.94 frames/s) before the snapshot
      --launch         hold the plunger to full charge, then release (before --sim-time)
      --hold-plunger N hold the plunger for N frames and keep holding (after --launch)
      --flip SIDE      hold flipper button(s) during --sim-time (left, right, both)
      --no-sprites     pure playfield: no ball, flippers, overlays or strip (legacy window)
      --mode M         classic (integer ball position) or enhanced (ball drawn at interpolated
                       sub-pixel positions); presentation only
      --physics P      classic (the bit-exact integer engine, default) or enhanced (EnhancedPhysics);
                       window, --snapshot and --autoplay
      --scenario FILE  snapshot: start from a trace scenario instead of a served ball
      --frames N       snapshot: run N original frames (overrides --sim-time)

    classic presentation (the original's 320x240 screen: playfield window + display strip):
      --original DIR   directory with your EPn.EXE (default: $EPIC_PINBALL_ORIGINAL, then
                       ../original next to the data root). Sprites, fonts, strip layout and
                       message text are read from it at runtime.
      --filter F       upscaler: nearest (default, the classic look), smooth (Catmull-Rom), xbrz, crt
      --hd-pack        use the table's HD pack if one is installed (--make-hd-pack, Settings > Library)
      --lighting L     off (default), subtle or vivid lamp glow, ball highlight and shadow
      --high-refresh   window: display-rate interpolation of ball, flippers and camera
      --render SPEC    developer override, e.g. filter=xbrz,hd=1,lighting=subtle,interp=1,scaling=fill
                       (the same as EPIC_PINBALL_RENDER=SPEC; wins over the flags above)
      --strip on|off   snapshot: strip shown (default) or hidden (as after Enter)
      --rotate D       cabinet / portrait monitor: turn the picture D degrees clockwise (0, 90,
                       180, 270; input unchanged). Snapshot without --size: the image is turned too
      --score-window   window: the score strip in its own window (e.g. on a backglass display),
                       the main window shows the playfield only
      --score-snapshot P  snapshot: also write the strip alone as the score window draws it
      --score-size WxH score snapshot size in pixels (default: 320x(strip rows) times --scale)
      --score-rotate D the score window's picture turned D degrees clockwise (its screen may be
                       mounted differently); score snapshot without --score-size: turned too
      --legacy-window  old 320x200 window without strip/overlays
      --lamps SPEC     demo lamp states: none (no overlays), a, b, rest (records matching the
                       playfield), alt, or a slot list like 3,5,40-47 (those slots drawn with
                       the record that differs from the playfield, the others at rest), or
                       explicit records like 38-42a,43-47b
      --score N, --ball N, --player N   strip contents (player 1-based)
      --message OFF[:AX[:DI[:COL]]]  dot message from the EXE string at file offset OFF, with the
                       original's dmd_message AX (AH font/centring, AL effect; default 0x101)
                       and DI (y*320+x; default row 12); COL = EP9-13 dot colour index
      --message-line OFF:font5|font8:DI  append a line (draw_text / draw_text_hi), repeatable
      --pause          draw the pause banner in the strip
      --demo           window: cycle lamps, score and messages without rules

    trace mode (headless, no window, no Metal):
      --trace FILE     run a scenario (tools/emu/scenarios/*.json) and write one JSON line
                       per physics step (3 per frame) to --out FILE or stdout
      --no-extra       omit the per-record "extra" diagnostics object
      --state          add all 5 ball slots and the nudge/tilt/kicker counters to "extra"
                       (scenarios may also give "balls": [...] for slots 1-4; input bits
                       8 = nudge Z, 16 = nudge /, 32 = Space)
      --gravity-phase N  physics steps per frame before the main-loop logic (0...3; default 0,
                       the contract's order: main-loop work, then 3 steps)
      --schema FILE    trace schema to take field names from (default tools/emu/trace_schema.json)

    game and audio (window):
      --players N      1...4 players (default 1), --balls N balls per game (default 3)
      --mute           no audio at all; --no-music / --no-sfx start with music paused / effects off
      --volume V       master volume 0...1 (default 0.9)
      --autoplay N     without --snapshot: play N frames headless with a simple auto-player and
                       print a JSON report (score, drains, sounds, rule warnings); with --snapshot:
                       auto-play N frames, then render the frame (a mid-game snapshot)
      --json FILE      write the --autoplay report to FILE
      --autopilot      window: the auto-player plays (plunge and flip) until you press a game key
      --record-replay F  with --autoplay: write the game as a replay file (physics installed after the
                       start, as in the app)
      --play-replay F  re-simulate replay F headless and print whether it reaches the recorded final
                       state (frames, scores, state digest); exit 4 if it does not
      --watch F        window: watch replay F (P / Space pause, 1 / 2 / 4 speed, Esc back)
      --practice       window: start the table in practice mode (K saves the state, L restores it,
                       1-4 choose the slot; states are kept in <support dir>/SaveStates; no high
                       scores, statistics or replay)
      --attract        window: start in attract mode (the original's demo plays the table; any key
                       leaves it); with --snapshot: run the demo for --frames / --sim-time
      --attract-delay S  idle seconds before attract mode starts (default 15, the original's 900
                       frames; also enables it in --exit-after smoke tests)
      --require-rules  trace mode: fail if the table rules do not load (from the EXE, or from rules.json
                       with --rules lifted) instead of a warning

    front end (window):
      without --table (and the smoke-test / demo flags) the launcher opens: table picker, settings,
      high scores; on first launch (no library and no --data) the import screen.
      --launcher       open the launcher even with --table (that table preselected)
      --import         open the import screen
      --support-dir D  use D instead of ~/Library/Application Support/EpicPinballHD (settings,
                       high scores, imported library)
      --ui-snapshot P  render a front-end screen offscreen to PNG P and exit
      --ui-screen S    launcher (default), launcher-hdpacks, import, import-done,
                       settings[-game|-display|-audio|-controls|-library], pause, initials or gameover
                       (with --size WxH)
      --import-from P  open the import screen and import P (.iso file or folder) without the file panel
      --import-hd-packs S|skip  answer the import-done screen's HD pack offer (S = 2, 3 or 4: make the
                       packs at that scale in the background; skip: none) instead of waiting for a click
      --autostart      with --launcher: press Play on the selected table at once (smoke test of the
                       picker -> game path; --exit-after/--window-capture then apply to the game, or
                       to the launcher window when no game starts)

    window smoke test:
      --exit-after S       quit the windowed app after S seconds, printing frame stats (games in
                           such runs, like --autopilot games, are not counted in the statistics)
      --window-capture P   with --exit-after: save the last presented drawable as PNG
      --list-dylibs        print every image loaded into the process and exit (packaging check)

    keys: Left/Right Shift (or Left/Right arrow) flippers, Space plunger in the lane /
          nudge elsewhere, Ctrl plunger, Z or , nudge (+x), / nudge (-x), Up/Down scroll,
          Enter show/hide the display strip, P pause, M music on/off, S effects on/off,
          - / = master volume, [ / ] music volume, R new game (new ball without rules),
          Tab full table, A pixel aspect, E classic/enhanced physics, F cycle upscale filter,
          Esc menu (resume, new game, practice, settings, choose table, quit), Cmd-Q quit.
          Practice: K save state, L restore state, 1-4 choose the slot (kept on disk per table).
          Cmd-, Settings (a running game pauses; it stays paused when Settings closes).
          All game keys can be changed in Settings > Controls; game controllers work too.
    """

    enum ParseError: Error, CustomStringConvertible {
        case message(String)
        case help
        var description: String {
            switch self {
            case let .message(m): return m
            case .help: return Options.usage
            }
        }
    }

    static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw ParseError.message("\(flag) needs a value") }
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--data": o.dataDir = try value(a)
            case "--table":
                let v = try value(a)
                guard let n = Int(v), (1...TableGeometry.tableCount).contains(n) else {
                    throw ParseError.message("--table must be 1...\(TableGeometry.tableCount), got '\(v)'")
                }
                o.table = n
                o.tableGiven = true
            case "--mode":
                let v = try value(a)
                guard let m = SimulationMode(rawValue: v) else { throw ParseError.message("--mode must be classic or enhanced") }
                o.mode = m
            case "--trace": o.trace = try value(a)
            case "--out": o.traceOut = try value(a)
            case "--no-extra": o.noExtra = true
            case "--state": o.traceState = true
            case "--schema": o.traceSchema = try value(a)
            case "--scenario": o.scenario = try value(a)
            case "--frames":
                let v = try value(a)
                guard let n = Int(v), n >= 0, n <= 1_000_000 else { throw ParseError.message("--frames needs 0...1000000") }
                o.frames = n
            case "--gravity-phase":
                let v = try value(a)
                guard let n = Int(v), (0...3).contains(n) else { throw ParseError.message("--gravity-phase must be 0...3") }
                o.gravityPhase = n
            case "--snapshot": o.snapshot = try value(a)
            case "--full": o.full = true
            case "--scale":
                let v = try value(a)
                guard let n = Int(v), (1...32).contains(n) else { throw ParseError.message("--scale must be 1...32") }
                o.scale = n
                o.scaleGiven = true
            case "--size":
                let v = try value(a)
                let parts = v.lowercased().split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, parts.allSatisfy({ (1...16384).contains($0) }) else {
                    throw ParseError.message("--size must look like 1280x800")
                }
                o.size = (parts[0], parts[1])
            case "--aspect":
                let v = try value(a)
                guard let asp = PixelAspect(rawValue: v) else { throw ParseError.message("--aspect must be square or vga") }
                o.aspect = asp
            case "--camera-y":
                let v = try value(a)
                guard let y = Double(v) else { throw ParseError.message("--camera-y needs a number") }
                o.cameraY = y
            case "--sim-time":
                let v = try value(a)
                guard let t = Double(v), t >= 0, t <= 600 else { throw ParseError.message("--sim-time needs 0...600 seconds") }
                o.simTime = t
            case "--launch": o.launch = true
            case "--exit-after":
                let v = try value(a)
                guard let t = Double(v), t > 0 else { throw ParseError.message("--exit-after needs seconds > 0") }
                o.exitAfter = t
            case "--window-capture": o.windowCapture = try value(a)
            case "--no-sprites": o.sprites = false
            case "--flip":
                switch try value(a) {
                case "left": o.holdLeft = true
                case "right": o.holdRight = true
                case "both": o.holdLeft = true; o.holdRight = true
                default: throw ParseError.message("--flip must be left, right or both")
                }
            case "--original": o.originalDir = try value(a)
            case "--filter":
                let v = try value(a)
                guard let f = UpscaleFilter(rawValue: v) else {
                    throw ParseError.message("--filter must be one of \(UpscaleFilter.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                o.filter = f
                o.filterGiven = true
            case "--render": o.renderSpec = try value(a)
            case "--hd-pack": o.hdPack = true
            case "--lighting":
                let v = try value(a)
                guard let l = RenderSettings.Lighting(rawValue: v) else { throw ParseError.message("--lighting must be off, subtle or vivid") }
                o.lighting = l
            case "--high-refresh": o.highRefreshFlag = true
            case "--make-hd-pack":
                let v = try value(a)
                if v == "all" { o.makeHDPack = Array(1...TableGeometry.tableCount) } else {
                    guard let n = Int(v), (1...TableGeometry.tableCount).contains(n) else {
                        throw ParseError.message("--make-hd-pack needs a table 1...\(TableGeometry.tableCount) or all")
                    }
                    o.makeHDPack = [n]
                }
            case "--hd-pack-out": o.hdPackOut = try value(a)
            case "--hd-method":
                let v = try value(a)
                guard ["xbrz", "nearest"].contains(v) else { throw ParseError.message("--hd-method must be xbrz or nearest") }
                o.hdPackMethod = v
            case "--verify-hd-pack": o.verifyHDPack = true
            case "--rotate":
                let v = try value(a)
                guard let r = Int(v).flatMap(GameSettings.DisplayRotation.init(rawValue:)) else {
                    throw ParseError.message("--rotate must be 0, 90, 180 or 270")
                }
                o.rotation = r
            case "--score-window": o.scoreWindow = true
            case "--score-rotate":
                let v = try value(a)
                guard let r = Int(v).flatMap(GameSettings.DisplayRotation.init(rawValue:)) else {
                    throw ParseError.message("--score-rotate must be 0, 90, 180 or 270")
                }
                o.scoreRotation = r
            case "--score-snapshot": o.scoreSnapshot = try value(a)
            case "--score-size":
                let v = try value(a)
                let parts = v.lowercased().split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, parts.allSatisfy({ (1...16384).contains($0) }) else {
                    throw ParseError.message("--score-size must look like 1280x160")
                }
                o.scoreSize = (parts[0], parts[1])
            case "--list-dylibs": o.listDylibs = true
            case "--library": o.libraryDir = try value(a)
            case "--headless-import": o.headlessImport = try value(a)
            case "--rules":
                let v = try value(a)
                guard let b = RulesBackend(rawValue: v.lowercased()) else { throw ParseError.message("--rules must be direct or lifted") }
                o.rulesBackend = b
            case "--strip":
                switch try value(a) {
                case "on": o.stripShown = true
                case "off": o.stripShown = false
                default: throw ParseError.message("--strip must be on or off")
                }
            case "--legacy-window": o.legacyWindow = true
            case "--lamps": o.lamps = try LampSpec.parse(try value(a))
            case "--score":
                let v = try value(a)
                guard let n = UInt32(v) else { throw ParseError.message("--score needs 0...4294967295") }
                o.score = n
            case "--ball":
                let v = try value(a)
                guard let n = Int(v), (0...9).contains(n) else { throw ParseError.message("--ball needs 0...9") }
                o.ballNumber = n
            case "--player":
                let v = try value(a)
                guard let n = Int(v), (1...4).contains(n) else { throw ParseError.message("--player needs 1...4") }
                o.player = n
            case "--message": o.message = try MessageSpec.parse(try value(a))
            case "--message-line": o.messageLines.append(try MessageLineSpec.parse(try value(a)))
            case "--demo": o.demo = true
            case "--pause": o.paused = true
            case "--hold-plunger":
                let v = try value(a)
                guard let n = Int(v), (0...600).contains(n) else { throw ParseError.message("--hold-plunger needs 0...600 frames") }
                o.holdPlunger = n
            case "--autoplay":
                let v = try value(a)
                guard let n = Int(v), (0...10_000_000).contains(n) else { throw ParseError.message("--autoplay needs 0...10000000 frames") }
                o.autoplay = n
            case "--json": o.autoplayJSON = try value(a)
            case "--mute": o.mute = true
            case "--no-music": o.noMusic = true
            case "--no-sfx": o.noSfx = true
            case "--volume":
                let v = try value(a)
                guard let x = Double(v), (0...1).contains(x) else { throw ParseError.message("--volume needs 0...1") }
                o.volume = x
            case "--players":
                let v = try value(a)
                guard let n = Int(v), (1...4).contains(n) else { throw ParseError.message("--players needs 1...4") }
                o.players = n
            case "--balls":
                let v = try value(a)
                guard let n = Int(v), (1...9).contains(n) else { throw ParseError.message("--balls needs 1...9") }
                o.balls = n
            case "--require-rules": o.requireRules = true
            case "--record-replay": o.recordReplay = try value(a)
            case "--play-replay": o.playReplay = try value(a)
            case "--watch": o.watchReplay = try value(a)
            case "--practice": o.practice = true
            case "--autopilot": o.autopilot = true
            case "--attract": o.attract = true
            case "--attract-delay":
                let v = try value(a)
                guard let t = Double(v), t >= 0 else { throw ParseError.message("--attract-delay needs seconds >= 0") }
                o.attractDelay = t
            case "--launcher": o.launcher = true
            case "--import": o.forceImport = true
            case "--autostart": o.autostart = true
            case "--import-from": o.importFrom = try value(a); o.forceImport = true
            case "--import-hd-packs":
                let v = try value(a)
                if v == "skip" || v == "0" { o.importHDPacks = 0 } else if let n = Int(v), HDPackGeneration.appScales.contains(n) { o.importHDPacks = n }
                else { throw ParseError.message("--import-hd-packs: expected 2, 3, 4 or skip, got \(v)") }
            case "--physics":
                let v = try value(a)
                guard let p = GameSettings.PhysicsMode(rawValue: v) else { throw ParseError.message("--physics must be classic or enhanced") }
                o.physics = p
            case "--support-dir": o.supportDir = try value(a)
            case "--ui-snapshot": o.uiSnapshot = try value(a)
            case "--ui-screen":
                let v = try value(a)
                guard ["launcher", "import", "import-done", "launcher-hdpacks", "settings", "pause", "initials", "gameover"].contains(v)
                        || ["settings-game", "settings-display", "settings-audio", "settings-controls", "settings-library"].contains(v) else {
                    throw ParseError.message("--ui-screen must be launcher, launcher-hdpacks, import, import-done, settings[-TAB], pause, initials or gameover")
                }
                o.uiScreen = v
            case "-h", "--help": throw ParseError.help
            default:
                // Ignore flags macOS may inject when launched from Finder/Xcode (-NSDocumentRevisionsDebugMode, -psn_...).
                if a.hasPrefix("-NS") || a.hasPrefix("-psn_") || a.hasPrefix("-Apple") { if a.hasPrefix("-NS") || a.hasPrefix("-Apple") { i += 1 }; break }
                throw ParseError.message("unknown argument '\(a)'\n\n\(usage)")
            }
            i += 1
        }
        return o
    }
}
