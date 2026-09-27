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

    /// The game options PINBALL.EXE would pass (players, balls; sounds on, card present).
    var rulesOptions: RulesOptions {
        var r = RulesOptions()
        r.players = players
        r.ballsPerGame = balls
        return r
    }

    /// Any of the demo presentation flags given (they replace the rules' state).
    var hasPresentationFlags: Bool { lamps != nil || score != nil || ballNumber != nil || player != nil }

    static let usage = """
    usage: EpicPinball [--table N] [--data DIR] [--original DIR] [--aspect square|vga] [--mode classic|enhanced]
                       [--filter nearest|xbrz-like|crt] [--demo]
           EpicPinball --snapshot OUT.png [--table N] [--full] [--scale N | --size WxH]
                       [--camera-y Y] [--sim-time S] [--launch] [--flip left|right|both]
                       [--scenario FILE --frames N] [--no-sprites]
                       [--strip on|off] [--lamps SPEC] [--score N] [--ball N] [--player N]
                       [--message OFFSET[:AX[:DI]]] [--pause] [--legacy-window]
           EpicPinball --trace SCENARIO.json [--out TRACE.jsonl] [--no-extra] [--gravity-phase N] [--require-rules]
           EpicPinball --autoplay N [--table N] [--json OUT.json]      (headless game, no window)

      --data DIR       extracted data root (contains tables/EPn/). Default: ../extracted
                       relative to the Swift package, or $EPIC_PINBALL_DATA.
      --table N        table 1...13 (default 1)
      --aspect A       square (1:1 pixels, default) or vga (1.2 tall pixels, 4:3 CRT look)
      --snapshot PATH  render one frame offscreen to a PNG and exit (no window)
      --full           snapshot the whole 320x400 table instead of the 320x200 window
      --scale N        snapshot integer scale (default 3)
      --size WxH       snapshot output size in pixels (overrides --scale; letterboxed)
      --camera-y Y     snapshot window top row (default: follow the ball)
      --sim-time S     run the engine for S seconds (59.94 frames/s) before the snapshot
      --launch         hold the plunger to full charge, then release (before --sim-time)
      --hold-plunger N hold the plunger for N frames and keep holding (after --launch)
      --flip SIDE      hold flipper button(s) during --sim-time (left, right, both)
      --no-sprites     pure playfield: no ball, flippers, overlays or strip (legacy window)
      --mode M         classic (bit-exact, integer ball position) or enhanced (same physics,
                       ball drawn at interpolated sub-pixel positions)
      --scenario FILE  snapshot: start from a trace scenario instead of a served ball
      --frames N       snapshot: run N original frames (overrides --sim-time)

    classic presentation (the original's 320x240 screen: playfield window + display strip):
      --original DIR   directory with your EPn.EXE (default: $EPIC_PINBALL_ORIGINAL, then
                       ../original next to the data root). Sprites, fonts, strip layout and
                       message text are read from it at runtime.
      --filter F       upscaler: nearest (default), xbrz-like (edge-directed placeholder), crt
      --strip on|off   snapshot: strip shown (default) or hidden (as after Enter)
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
      --require-rules  trace mode: fail if rules.json does not load (instead of a warning)

    window smoke test:
      --exit-after S       quit the windowed app after S seconds, printing frame stats
      --window-capture P   with --exit-after: save the last presented drawable as PNG

    keys: Left/Right Shift (or Left/Right arrow) flippers, Space plunger in the lane /
          nudge elsewhere, Ctrl plunger, Z or , nudge (+x), / nudge (-x), Up/Down scroll,
          Enter show/hide the display strip, P pause, M music on/off, S effects on/off,
          - / = master volume, [ / ] music volume, R new game (new ball without rules),
          Tab full table, A pixel aspect, E classic/enhanced, F cycle upscale filter,
          Esc or Cmd-Q quit
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
            case "--autopilot": o.autopilot = true
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
