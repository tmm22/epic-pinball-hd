import Foundation

/// Loads what the classic engine needs for one table: `engine.json` (tools/export_engine_data.py)
/// and the start-up collision buffer `collision_idx.npy` (tools/collision.py).
public enum EngineAssets {
    public static func load(dataRoot: URL, table: Int) throws -> (EngineData, [UInt8]) {
        guard (1...TableGeometry.tableCount).contains(table) else { throw AssetError.badTable(table) }
        let dir = dataRoot.appendingPathComponent("tables/EP\(table)", isDirectory: true)
        let engineURL = dir.appendingPathComponent("engine.json")
        let bufURL = dir.appendingPathComponent("collision_idx.npy")
        let fm = FileManager.default
        guard fm.fileExists(atPath: engineURL.path) else { throw EngineAssetError.missingEngineJSON(engineURL) }
        guard fm.fileExists(atPath: bufURL.path) else { throw AssetError.missingFile(bufURL, dataRoot: dataRoot) }
        let data: EngineData
        do { data = try EngineData.load(contentsOf: engineURL) } catch {
            throw AssetError.invalidFile(engineURL, String(describing: error))
        }
        guard data.table == table else {
            throw AssetError.invalidFile(engineURL, "belongs to table \(data.table), not \(table)")
        }
        let npy: NPYArray2D
        do { npy = try NPYReader.read(contentsOf: bufURL) } catch {
            throw AssetError.invalidFile(bufURL, String(describing: error))
        }
        guard npy.rows == TableGeometry.height, npy.columns == TableGeometry.width else {
            throw AssetError.invalidFile(bufURL, "shape is (\(npy.rows), \(npy.columns)), expected (400, 320)")
        }
        return (data, npy.data)
    }

    /// The classic engine for `table`. With `rules` (default) the table's lifted rules
    /// (rules.json + the user's EPn.EXE) are attached, inactive (`rulesMode = .off`) until a
    /// scenario or `ClassicEngine.startGame` enables them; if they cannot be loaded the engine runs
    /// physics only and `rulesLoadError` says why. `backend` (default `RulesBackend.default`) picks
    /// the rules implementation (a replay asks for the one it was recorded with).
    public static func makeEngine(dataRoot: URL, table: Int, rules: Bool = true, originalDir: URL? = nil,
                                  backend: RulesBackend = .default) throws -> ClassicEngine {
        let (d, buf) = try load(dataRoot: dataRoot, table: table)
        let e = try ClassicEngine(data: d, startBuffer: buf)
        if rules {
            do {
                let r = try RulesRuntime.load(dataRoot: dataRoot, table: table, originalDir: originalDir, backend: backend)
                r.attach(to: e, mode: .off)
            } catch {
                e.rulesLoadError = String(describing: error)
            }
        }
        return e
    }
}

public enum EngineAssetError: Error, CustomStringConvertible {
    case missingEngineJSON(URL)
    public var description: String {
        switch self {
        case let .missingEngineJSON(u):
            return "missing \(u.path)\nRun `.venv/bin/python tools/export_engine_data.py` (reads your own original/EPn.EXE) first."
        }
    }
}

// MARK: - Scenario (shared trace contract)

/// A trace scenario: `{"table":1,"frames":N,"ball":{x,y,xf,yf,vx,vy},"inputs":[bits],"params":...}`.
/// Ball fields are the original's raw words (x/y integer px of the box's top-left, xf/yf the
/// 1/128 px accumulators ds:6A18/6A24, vx/vy in 1/128 px per step).
public struct Scenario: Sendable {
    public struct Ball: Sendable, Equatable {
        public var x: Int, y: Int, xf: Int, yf: Int, vx: Int, vy: Int, layer: Int
        public var active: Int = 1   // "active" in ball / balls entries (harness default 1; EP3 captive ball, EP8 no ball)
    }
    public var table: Int
    public var frames: Int
    public var ball: Ball
    /// Optional extension: extra balls for slots 1...4 (`"balls": [{...}, ...]`, slot 0 = `ball`).
    public var extraBalls: [Ball] = []
    public var inputs: [Int]
    /// Full parameter block after overrides (nil = the table's own).
    public var paramOverrides: [Int: Int]
    public var gravityPhase: Int?
    /// Optional initial flipper angles by group (default: at rest).
    public var flipperAngles: [Int]?
    public var name: String?
    /// Raw state pokes by the harness's DS variable names (e.g. "kicker_cooldown").
    public var extras: [String: Int]
    /// "stop" (default): the trace ends before the first frame that starts with y >= 0x18F.
    public var onDrain: String
    /// "physics" (default, no sensor dispatch), "rules" or "full" (sensor dispatch on).
    public var mode: String
    /// Port extension for rules tests: raw data-segment writes applied after the rules boot,
    /// `"ds_pokes": [[offset, value, width], ...]` (width 1, 2 or 4; offsets as in rules.json).
    public var dsPokes: [(Int, Int, Int)] = []
    /// Port extension: game options for the rules boot (`"players"`, `"balls"`); the harness's
    /// defaults are 1 player and 3 balls.
    public var players: Int?
    public var ballsPerGame: Int?
    /// Port extension: `"start": "boot"` starts at the first main-loop arrival after the table's own
    /// boot (power-on flippers at their boot angle, the EXE's ball slots, the rules boot with the
    /// harness's options; `pokes.demo_mode` = players 'D'), as `EpEmu(players=...)` does, instead of
    /// the warmed-up scenario state; `ball` is then optional and ignored. Full mode only.
    public var startAtBoot = false
    /// Port extension for rules tests (`"watch": {"ds": [[offset, width], ...], "messages": true}`):
    /// the last record of every frame gets `extra.watch_ds` (those DS values after the frame) and
    /// `extra.messages` (that frame's dmd_message calls as [string DS offset, AX, DI]), as
    /// tools/emu/run_scenario.py records them for the original. Needs rules (rules or full mode).
    public var watchDS: [(Int, Int)] = []
    public var watchMessages = false

    /// engine.json / export names; the trace schema's names are accepted as aliases.
    public static let paramNames = ["rest_div_x", "rest_div_y", "kicker", "flip_top_x", "flip_top_y",
                                    "flip_side_x", "flip_side_y", "up_div_y", "up_div_x", "gravity"]
    public static let paramAliases = ["rest_x", "rest_y", "kicker", "flip_top_x", "flip_top_y",
                                      "flip_side_x", "flip_side_y", "up_y", "up_x", "gravity"]

    public static func parse(_ data: Data) throws -> Scenario {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScenarioError.invalid("top level is not an object")
        }
        func int(_ v: Any?) -> Int? {
            if let n = v as? NSNumber { return n.intValue }
            if let s = v as? String { return s.hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s) }
            return nil
        }
        guard let table = int(root["table"]), (1...TableGeometry.tableCount).contains(table) else {
            throw ScenarioError.invalid("'table' must be 1...13")
        }
        let boot = root["start"] as? String == "boot"
        guard root["start"] == nil || boot else { throw ScenarioError.invalid("start must be \"boot\"") }
        let b = root["ball"] as? [String: Any] ?? [:]
        guard let x = int(b["x"]) ?? (boot ? 0 : nil), let y = int(b["y"]) ?? (boot ? 0 : nil) else {
            throw ScenarioError.invalid("'ball' needs at least x and y")
        }
        let ball = Ball(x: x, y: y, xf: int(b["xf"]) ?? 0, yf: int(b["yf"]) ?? 0,
                        vx: int(b["vx"]) ?? 0, vy: int(b["vy"]) ?? 0, layer: int(b["layer"]) ?? 0, active: int(b["active"]) ?? 1)
        let inputs = (root["inputs"] as? [Any])?.map { int($0) ?? 0 } ?? []
        let frames = int(root["frames"]) ?? inputs.count
        guard frames >= 0 else { throw ScenarioError.invalid("'frames' must be >= 0") }
        var overrides: [Int: Int] = [:]
        if let arr = root["params"] as? [Any] {
            for (i, v) in arr.enumerated() where i < 10 { if let n = int(v) { overrides[i] = n } }  // null = keep
        } else if let dict = root["params"] as? [String: Any] {
            let src = (dict["values"] as? [Any]).map { Dictionary(uniqueKeysWithValues: $0.enumerated().map { (String($0.offset), $0.element) }) } ?? dict
            for (k, v) in src {
                guard let n = int(v) else { continue }
                if let i = paramNames.firstIndex(of: k) ?? paramAliases.firstIndex(of: k) { overrides[i] = n }
                else if let i = Int(k), (0..<10).contains(i) { overrides[i] = n }
                else if k.hasPrefix("p_"), let i = paramNames.firstIndex(of: String(k.dropFirst(2))) { overrides[i] = n }
                else { throw ScenarioError.invalid("unknown parameter '\(k)'") }
            }
        }
        var angles: [Int]?
        if let f = root["flippers"] as? [String: Any] {
            angles = [int(f["left"]) ?? 9, int(f["right"]) ?? 9]
        } else if let f = root["flippers"] as? [Any] {
            angles = f.map { int($0) ?? 9 }
        }
        var extras: [String: Int] = [:]
        for k in pokeNames {
            if let v = int(root[k]) { extras[k] = v }
        }
        if let pokes = root["pokes"] as? [String: Any] {
            for (k, v) in pokes {
                guard let n = int(v) else { continue }
                guard pokeNames.contains(k) else { throw ScenarioError.invalid("unsupported poke '\(k)'") }
                extras[k] = n
            }
        }
        let onDrain = root["on_drain"] as? String ?? "stop"
        guard ["stop", "continue"].contains(onDrain) else { throw ScenarioError.invalid("on_drain must be stop or continue") }
        let mode = root["mode"] as? String ?? "physics"
        guard ["physics", "rules", "full"].contains(mode) else { throw ScenarioError.invalid("mode must be physics, rules or full") }
        var sc = Scenario(table: table, frames: frames, ball: ball, inputs: inputs, paramOverrides: overrides,
                          gravityPhase: int(root["gravity_phase"]), flipperAngles: angles,
                          name: root["name"] as? String, extras: extras, onDrain: onDrain, mode: mode)
        for p in root["ds_pokes"] as? [[Any]] ?? [] {
            guard p.count >= 2, let a = int(p[0]), let v = int(p[1]) else { throw ScenarioError.invalid("bad ds_pokes entry") }
            let w = p.count > 2 ? (int(p[2]) ?? 1) : 1
            guard [1, 2, 4].contains(w), (0..<0x10000).contains(a) else { throw ScenarioError.invalid("bad ds_pokes entry") }
            sc.dsPokes.append((a, v, w))
        }
        sc.startAtBoot = boot
        if let w = root["watch"] as? [String: Any] {
            for p in w["ds"] as? [[Any]] ?? [] {
                guard let a = int(p.first), (0..<0x10000).contains(a) else { throw ScenarioError.invalid("bad watch.ds entry") }
                let wd = p.count > 1 ? (int(p[1]) ?? 1) : 1
                guard [1, 2, 4].contains(wd) else { throw ScenarioError.invalid("bad watch.ds entry") }
                sc.watchDS.append((a, wd))
            }
            sc.watchMessages = w["messages"] as? Bool ?? false
        }
        if boot && mode != "full" { throw ScenarioError.invalid("start \"boot\" needs mode full") }
        sc.players = int(root["players"])
        sc.ballsPerGame = int(root["balls_per_game"])
        if let bs = root["balls"] as? [[String: Any]] {
            sc.extraBalls = try bs.prefix(4).map { b in
                guard let x = int(b["x"]), let y = int(b["y"]) else { throw ScenarioError.invalid("'balls' entries need x and y") }
                return Ball(x: x, y: y, xf: int(b["xf"]) ?? 0, yf: int(b["yf"]) ?? 0,
                            vx: int(b["vx"]) ?? 0, vy: int(b["vy"]) ?? 0, layer: int(b["layer"]) ?? 0, active: int(b["active"]) ?? 1)
            }
        }
        return sc
    }

    public static func load(contentsOf url: URL) throws -> Scenario {
        do { return try parse(Data(contentsOf: url)) } catch let e as ScenarioError { throw e } catch {
            throw ScenarioError.invalid("\(url.path): \(error)")
        }
    }

    /// DS variables a scenario may poke (names as in tools/emu/ep_emu.py).
    public static let pokeNames = ["nudge_timer", "tilt_meter", "tilted", "kicker_cooldown", "plunger_charge",
                                   "extra_gravity", "extra_gravity_timer", "event_lockout", "event_cooldown", "serve_delay",
                                   "kick_strength", "flipper_contact", "collided", "demo_mode"]

    public func input(frame f: Int) -> FrameInput {
        FrameInput(rawValue: f < inputs.count ? inputs[f] : 0)
    }

    /// Engine state at frame 0: flippers at rest (or as given), ball 0 as given.
    public func apply(to e: ClassicEngine) {
        if startAtBoot { applyBoot(to: e); return }
        e.resetToRest()
        // The rules boot state (the original's init, with the harness's options) comes before the
        // scenario's own state, as in the harness (boot, then reset_play_state and pokes).
        if let r = e.rules {
            r.options = .harness
            if let p = players { r.options.players = p }
            if let b = ballsPerGame { r.options.ballsPerGame = b }
            r.boot()
        }
        if let a = flipperAngles {
            for (g, angle) in a.enumerated() where e.groups.indices.contains(g) { e.setFlipperAngle(group: g, angle: angle) }
            for g in e.groups.indices { e.groups[g].moving = false }
        }
        for (i, v) in paramOverrides { e.params[i] = Int16(truncatingIfNeeded: v) }
        if let gp = gravityPhase { e.gravityPhase = max(0, min(3, gp)) }
        for i in e.balls.indices { e.balls[i].active = 0 }   // like the harness's reset_play_state
        for (i, b) in ([ball] + extraBalls).enumerated() where i < 5 {
            e.balls[i] = BallState(x: Int16(truncatingIfNeeded: b.x), y: Int16(truncatingIfNeeded: b.y),
                                   vx: Int16(truncatingIfNeeded: b.vx), vy: Int16(truncatingIfNeeded: b.vy),
                                   accx: Int16(truncatingIfNeeded: b.xf), accy: Int16(truncatingIfNeeded: b.yf),
                                   layer: UInt8(truncatingIfNeeded: b.layer))
            e.balls[i].active = UInt16(truncatingIfNeeded: b.active)
        }
        if let v = extras["nudge_timer"] { e.nudgeTimer = UInt8(truncatingIfNeeded: v) }
        if let v = extras["tilt_meter"] { e.tiltMeter = UInt8(truncatingIfNeeded: v) }
        if let v = extras["tilted"] { e.tilted = v != 0 }
        if let v = extras["kicker_cooldown"] { e.kickerCooldown = UInt8(truncatingIfNeeded: v) }
        if let v = extras["plunger_charge"] { e.plungerCharge = UInt16(truncatingIfNeeded: v) }
        if let v = extras["extra_gravity"] ?? extras["extra_gravity_timer"] { e.extraGravity = Int16(truncatingIfNeeded: v) }
        if let v = extras["event_lockout"] { e.eventLockout = UInt8(truncatingIfNeeded: v) }
        if let v = extras["event_cooldown"] { e.eventCooldown = UInt8(truncatingIfNeeded: v) }
        if let v = extras["serve_delay"] { e.serveDelay = UInt8(truncatingIfNeeded: v) }
        if let v = extras["kick_strength"] { e.kickStrength = UInt8(truncatingIfNeeded: v) }
        if let v = extras["flipper_contact"] { e.flipperContact = UInt8(truncatingIfNeeded: v) }
        if let v = extras["collided"] { e.collidedThisStep = v != 0 }
        // The harness's "physics" mode runs no sensor dispatch and skips ball_lost_fade.
        e.sensorsEnabled = mode != "physics"
        e.ballLostResets = mode == "full"
        // Rules (if attached): the harness's mode; ds_pokes last, like the harness's pokes.
        if let r = e.rules {
            e.rulesMode = mode == "rules" ? .rules : (mode == "full" ? .full : .off)
            if let v = extras["demo_mode"] { e.setDemoMode(v == 1) }   // the harness pokes the DS byte
            for (a, v, w) in dsPokes { r.machine.write(a, w, Int64(v)) }
        }
    }
}

extension Scenario {
    /// `"start": "boot"`: the state at the first arrival at the main loop, as the harness boots it.
    func applyBoot(to e: ClassicEngine) {
        if e.rules?.introSettlesFlippers == true { e.resetToRest() } else { e.resetToPowerOn() }
        if let gp = gravityPhase { e.gravityPhase = max(0, min(3, gp)) }
        e.sensorsEnabled = true
        e.ballLostResets = true
        guard let r = e.rules else { return }
        r.options = .harness
        if let p = players { r.options.players = p }
        if let b = ballsPerGame { r.options.ballsPerGame = b }
        r.options.demo = extras["demo_mode"] == 1
        e.rulesMode = .full
        r.boot()
        for (a, v, w) in dsPokes { r.machine.write(a, w, Int64(v)) }
    }
}

public enum ScenarioError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self { case let .invalid(s): return "bad scenario: \(s)" }
    }
}

// MARK: - Trace (JSON Lines, one record per physics step)

/// Field names of a trace record. Defaults are the shared contract's names; if
/// `tools/emu/trace_schema.json` exists its property names are used instead.
public struct TraceFieldNames: Sendable, Equatable {
    public var frame = "frame", step = "step", ball = "ball", collided = "collided", k = "k"
    public var leftFlipper = "left_flipper_pos", rightFlipper = "right_flipper_pos"
    public var x = "x", y = "y", xf = "xf", yf = "yf", vx = "vx", vy = "vy"
    public var extraTop: [String] = []
    public init() {}

    /// Reads a JSON Schema describing one record. Recognises the default names and a few
    /// synonyms; returns the defaults (plus warnings) for anything it cannot map.
    public static func fromSchema(_ data: Data) -> (TraceFieldNames, [String]) {
        var n = TraceFieldNames()
        var warnings: [String] = []
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (n, ["trace_schema.json is not a JSON object; using default field names"])
        }
        // The record schema may be the root or nested under "items"/"record"/"$defs".
        var rec = root
        for key in ["record", "items", "step"] {
            if let r = root[key] as? [String: Any], r["properties"] != nil { rec = r }
        }
        if let defs = (root["$defs"] ?? root["definitions"]) as? [String: Any] {
            if let r = defs["record"] as? [String: Any], r["properties"] != nil {
                rec = r
            } else {
                for v in defs.values {
                    if let r = v as? [String: Any], let p = r["properties"] as? [String: Any], p["ball"] != nil, p["step"] != nil { rec = r }
                }
            }
            // resolve a "$ref" for the ball object
            if var props = rec["properties"] as? [String: Any], let ball = props["ball"] as? [String: Any],
               let ref = ball["$ref"] as? String, let name = ref.split(separator: "/").last,
               let target = defs[String(name)] as? [String: Any] {
                props["ball"] = target
                rec["properties"] = props
            }
        }
        guard let props = rec["properties"] as? [String: Any] else {
            return (n, ["trace_schema.json has no record 'properties'; using default field names"])
        }
        let top = Set(props.keys)
        func pick(_ cands: [String], _ current: String) -> String {
            if top.contains(current) { return current }
            return cands.first(where: top.contains) ?? current
        }
        n.frame = pick(["frame", "f"], n.frame)
        n.step = pick(["step", "s", "substep"], n.step)
        n.ball = pick(["ball"], n.ball)
        n.collided = pick(["collided", "collision", "hit"], n.collided)
        n.k = pick(["k", "dir", "contact_dir", "normal_index"], n.k)
        n.leftFlipper = pick(["left_flipper_pos", "left_flipper", "lflip"], n.leftFlipper)
        n.rightFlipper = pick(["right_flipper_pos", "right_flipper", "rflip"], n.rightFlipper)
        if let ball = props[n.ball] as? [String: Any], let bp = ball["properties"] as? [String: Any] {
            let bk = Set(bp.keys)
            func pb(_ cands: [String], _ cur: String) -> String { bk.contains(cur) ? cur : (cands.first(where: bk.contains) ?? cur) }
            n.x = pb(["x", "px"], n.x); n.y = pb(["y", "py"], n.y)
            n.xf = pb(["xf", "accx", "fx", "x_frac"], n.xf); n.yf = pb(["yf", "accy", "fy", "y_frac"], n.yf)
            n.vx = pb(["vx"], n.vx); n.vy = pb(["vy"], n.vy)
            for name in [n.x, n.y, n.xf, n.yf, n.vx, n.vy] where !bk.contains(name) {
                warnings.append("schema ball has no '\(name)'")
            }
        }
        for name in [n.frame, n.step, n.ball, n.collided, n.k, n.leftFlipper, n.rightFlipper] where !top.contains(name) {
            warnings.append("schema record has no '\(name)'")
        }
        if let req = rec["required"] as? [String] {
            let known = Set([n.frame, n.step, n.ball, n.collided, n.k, n.leftFlipper, n.rightFlipper])
            n.extraTop = req.filter { !known.contains($0) }
            for x in n.extraTop { warnings.append("schema requires '\(x)', which the port does not produce (written as null)") }
        }
        return (n, warnings)
    }
}

public enum TraceRunner {
    /// Runs a scenario and returns the JSONL text (one line per physics step), matching
    /// tools/emu/run_scenario.py: records after each physics step; `k` = contact direction
    /// of ball 0's first (velocity-changing) response in the step; `extra` = diagnostics.
    /// `state`: add `extra.balls` (all 5 slots: active,x,y,xf,yf,vx,vy,layer) and the nudge/tilt/
    /// kicker counters, for differential tests beyond the contract.
    public static func run(_ sc: Scenario, engine e: ClassicEngine, names: TraceFieldNames = TraceFieldNames(),
                           extra: Bool = true, state: Bool = false) -> String {
        sc.apply(to: e)
        let leftG = e.data.flipperGroups.firstIndex { $0.key == "left" } ?? 0
        let rightG = e.data.flipperGroups.firstIndex { $0.key == "right" } ?? min(1, e.groups.count - 1)
        var out = ""
        out.reserveCapacity(sc.frames * 3 * 200)
        var guardTrips = e.loopGuardTrips, faults = e.divideFaults
        var dsShadow = e.rules?.machine.initialDS ?? []
        if state { e.rules?.traceCalls = true; e.rules?.clearCallLog(); e.rules?.machine.coverage = [] }
        if sc.watchMessages { e.rules?.traceCalls = true; e.rules?.clearCallLog() }
        var covShadow = Set<Int>()
        e.onStep = { f, s, r in
            let b = e.balls[0]
            let mine = r.log.filter { $0.ball == 0 }
            let first = mine.first { $0.first }
            var line = "{\"\(names.frame)\":\(f),\"\(names.step)\":\(s),\"\(names.ball)\":{"
            line += "\"\(names.x)\":\(b.x),\"\(names.y)\":\(b.y),\"\(names.xf)\":\(b.accx),\"\(names.yf)\":\(b.accy),"
            line += "\"\(names.vx)\":\(b.vx),\"\(names.vy)\":\(b.vy)},"
            line += "\"\(names.collided)\":\(r.collided),\"\(names.k)\":\(first.map { String($0.k) } ?? "null"),"
            line += "\"\(names.leftFlipper)\":\(e.groups[leftG].angle),\"\(names.rightFlipper)\":\(e.groups[rightG].angle)"
            for x in names.extraTop { line += ",\"\(x)\":null" }
            if extra {
                line += ",\"extra\":{\"layer\":\(b.layer),\"active\":\(b.active),\"responses\":\(mine.count),"
                line += "\"k_all\":[\(mine.map { String($0.k) }.joined(separator: ","))],"
                line += "\"flipper_contact\":\(first?.flipperContact ?? 0),\"kick\":\(first?.kick ?? 0),"
                line += "\"lflip_moving\":\(e.groups[leftG].moving ? 1 : 0),\"rflip_moving\":\(e.groups[rightG].moving ? 1 : 0),"
                line += "\"plunger_charge\":\(e.plungerCharge)"
                // Port-only diagnostics, written only in steps where they happen: the original
                // hangs (push-out loop without a cap) or raises a divide error in such a step.
                if e.loopGuardTrips != guardTrips { line += ",\"loop_guard\":\(e.loopGuardTrips - guardTrips)" }
                if e.divideFaults != faults { line += ",\"divide_faults\":\(e.divideFaults - faults)" }
                if !sc.watchDS.isEmpty || sc.watchMessages, s == e.data.timing.stepsPerFrame - 1, let r = e.rules, e.rulesMode != .off {
                    if !sc.watchDS.isEmpty { line += ",\"watch_ds\":[\(sc.watchDS.map { String(r.machine.read($0.0, $0.1)) }.joined(separator: ","))]" }
                    if sc.watchMessages {
                        line += ",\"messages\":\(r.messageCalls)"
                        if !state { r.clearCallLog() }
                    }
                }
                if state, s == e.data.timing.stepsPerFrame - 1, let r = e.rules, e.rulesMode != .off {
                    // Rules data segment after the frame, as changes since the previous frame's dump
                    // (the first dump is relative to the EXE's data segment): [[offset, byte], ...].
                    var changes: [String] = []
                    let now = r.machine.snapshot()
                    if now != dsShadow {
                        // compare 8 bytes at a time, then the bytes of differing words
                        now.withUnsafeBytes { nb in
                            dsShadow.withUnsafeBytes { ob in
                                let n8 = nb.count / 8
                                for i in 0..<n8 where nb.loadUnaligned(fromByteOffset: 8 * i, as: UInt64.self)
                                    != ob.loadUnaligned(fromByteOffset: 8 * i, as: UInt64.self) {
                                    for a in (8 * i)..<(8 * i + 8) where nb[a] != ob[a] { changes.append("[\(a),\(nb[a])]") }
                                }
                                for a in (8 * n8)..<nb.count where nb[a] != ob[a] { changes.append("[\(a),\(nb[a])]") }
                            }
                        }
                        dsShadow = now
                    }
                    line += ",\"ds\":[\(changes.joined(separator: ","))]"
                    line += ",\"sfx\":\(r.sfxCalls),\"msg\":\(r.messageCalls)"
                    r.clearCallLog()
                    let cov = r.machine.coverage ?? []
                    let fresh = cov.subtracting(covShadow).map { "\"\(r.program.blocks[$0].label)\"" }
                    covShadow = cov
                    line += ",\"blk\":[\(fresh.sorted().joined(separator: ","))]"
                }
                if state {
                    let bs = e.balls.map { "[\($0.active),\($0.x),\($0.y),\($0.accx),\($0.accy),\($0.vx),\($0.vy),\($0.layer)]" }
                    line += ",\"balls\":[\(bs.joined(separator: ","))],\"tilted\":\(e.tilted ? 1 : 0),\"tilt_meter\":\(e.tiltMeter),"
                    line += "\"nudge_timer\":\(e.nudgeTimer),\"kicker_cooldown\":\(e.kickerCooldown),\"lockout\":\(e.eventLockout)"
                }
                line += "}"
            }
            line += "}\n"
            out += line
            guardTrips = e.loopGuardTrips; faults = e.divideFaults
        }
        defer { e.onStep = nil }
        let drainY = Int16(truncatingIfNeeded: e.data.drainY)
        for f in 0..<sc.frames {
            if sc.onDrain == "stop" && e.balls[0].y >= drainY { break }
            e.input = sc.input(frame: f)
            e.runFrame()
        }
        return out
    }
}
