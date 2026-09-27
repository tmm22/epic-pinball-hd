import Foundation
import PinballCore

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

    static let usage = """
    usage: EpicPinball [--table N] [--data DIR] [--aspect square|vga] [--mode classic|enhanced]
           EpicPinball --snapshot OUT.png [--table N] [--full] [--scale N | --size WxH]
                       [--camera-y Y] [--sim-time S] [--launch] [--flip left|right|both]
                       [--scenario FILE --frames N] [--no-sprites]
           EpicPinball --trace SCENARIO.json [--out TRACE.jsonl] [--no-extra] [--gravity-phase N]

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
      --flip SIDE      hold flipper button(s) during --sim-time (left, right, both)
      --no-sprites     hide the ball and flippers (pure playfield)
      --mode M         classic (bit-exact, integer ball position) or enhanced (same physics,
                       ball drawn at interpolated sub-pixel positions)
      --scenario FILE  snapshot: start from a trace scenario instead of a served ball
      --frames N       snapshot: run N original frames (overrides --sim-time)

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

    window smoke test:
      --exit-after S       quit the windowed app after S seconds, printing frame stats
      --window-capture P   with --exit-after: save the last presented drawable as PNG

    keys: Left/Right Shift (or Left/Right arrow) flippers, Space plunger in the lane /
          nudge elsewhere, Ctrl plunger, Z or , nudge (+x), / nudge (-x), Up/Down scroll,
          Tab full table, A pixel aspect, E classic/enhanced, R new ball, Esc or Cmd-Q quit
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
