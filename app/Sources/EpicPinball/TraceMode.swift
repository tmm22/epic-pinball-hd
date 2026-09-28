import Foundation
import PinballCore

/// `--trace scenario.json [--out trace.jsonl]`: headless, integer-exact run of the
/// classic engine, one JSON line per physics step (shared trace contract).
enum TraceMode {
    static func run(options o: Options, scenarioPath: String, dataRoot: URL) throws {
        let scURL = URL(fileURLWithPath: (scenarioPath as NSString).expandingTildeInPath).standardizedFileURL
        var sc = try Scenario.load(contentsOf: scURL)
        if o.tableGiven && o.table != sc.table {
            warn("--table \(o.table) overrides the scenario's table \(sc.table)")
            sc.table = o.table
        }
        if let gp = o.gravityPhase { sc.gravityPhase = gp }
        let engine = try EngineAssets.makeEngine(dataRoot: dataRoot, table: sc.table, originalDir: o.originalURL)
        // A rules/full scenario without rules would silently test only the physics-only sensors.
        if let err = engine.rulesLoadError {
            warn("rules not loaded (\(sc.mode) mode runs the engine.json sensors only): \(err)")
            if sc.mode != "physics" && o.requireRules { throw ScenarioError.invalid("rules required: \(err)") }
        }

        // Field names: the harness track's schema if present, else the contract defaults.
        let schemaURL = o.traceSchema.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? dataRoot.deletingLastPathComponent().appendingPathComponent("tools/emu/trace_schema.json")
        var names = TraceFieldNames()
        if let d = try? Data(contentsOf: schemaURL) {
            let (n, warnings) = TraceFieldNames.fromSchema(d)
            names = n
            for w in warnings { warn(w) }
        } else if o.traceSchema != nil {
            throw ScenarioError.invalid("cannot read schema \(schemaURL.path)")
        }

        let text = TraceRunner.run(sc, engine: engine, names: names, extra: !o.noExtra, state: o.traceState)
        if let r = engine.rules {
            for w in r.warnings { warn("rules: \(w)") }
            for f in Set(r.machine.faults) { warn("rules fault: \(f)") }
        }
        if let out = o.traceOut {
            let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath).standardizedFileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            let b = engine.balls[0]
            FileHandle.standardError.write(Data(("wrote \(url.path): \(sc.frames) frames, \(sc.frames * engine.data.timing.stepsPerFrame) steps, "
                + "table \(sc.table), gravity phase \(engine.gravityPhase); final ball x=\(b.x) y=\(b.y) vx=\(b.vx) vy=\(b.vy) active=\(b.active)"
                + (engine.divideFaults > 0 ? ", \(engine.divideFaults) divide faults" : "")
                + (engine.loopGuardTrips > 0 ? ", \(engine.loopGuardTrips) loop-guard trips" : "") + "\n").utf8))
        } else {
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    }
}
