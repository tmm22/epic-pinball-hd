import Foundation

/// Which implementation runs a table's rule code.
public enum RulesBackend: String, Sendable, CaseIterable {
    /// rules.json (lifted by tools/rules.py) interpreted by `RulesMachine`.
    case lifted
    /// The handlers and hooks executed from the user's EXE by `MiniX86`, located at run time by
    /// `RulesDiscovery` / `HookDiscovery` (no rules.json).
    case direct

    /// The backend the app uses unless told otherwise: `$EPIC_PINBALL_RULES` (`lifted` or
    /// `direct`), else direct.
    public static var `default`: RulesBackend {
        if let e = ProcessInfo.processInfo.environment["EPIC_PINBALL_RULES"], let b = RulesBackend(rawValue: e.lowercased()) { return b }
        return .direct
    }
}

extension RulesProgram {
    /// The program the direct backend runs: no blocks, but every address rules.json would give
    /// (engine roles, lamps, player block, jump table, hooks with stops/kinds/continues, stub
    /// routines), found in the user's EXE. `layout`/`discovery` are kept for the runtime.
    public static func discover(exe: [UInt8], table: Int, exeName: String? = nil) throws -> (RulesProgram, RulesDiscovery, HookDiscovery) {
        let image = try ExeImage(exe: exe)
        let d = try RulesDiscovery(image: image)
        let h = HookDiscovery.run(d, table: table)
        var engineVars: [String: EngineVar] = [:]
        for (a, r) in d.roles { engineVars[r.name] = EngineVar(addr: a, size: r.width, count: 1, stride: 2) }
        for (f, base) in d.ballArrays { engineVars["ball_slots.\(f)"] = EngineVar(addr: base, size: 2, count: 5, stride: 2) }
        engineVars["ball_slots.layer"] = EngineVar(addr: d.ballLayerArray, size: 1, count: 5, stride: 2)
        var hooks: [String: Hook] = [:]
        for (n, x) in h.hooks {
            var hk = Hook(name: n, entry: -1, entryIP: x.entry)
            hk.kind = x.kind; hk.when = x.when; hk.stops = x.stops; hk.continues = x.continues; hk.via = x.via
            hooks[n] = hk
        }
        var nativeHooks: [String: Hook] = [:]
        for (n, x) in h.nativeHooks {
            var hk = Hook(name: n, entry: -1, entryIP: x.entry)
            hk.kind = x.kind; hk.when = x.when; hk.stops = x.stops; hk.continues = x.continues; hk.via = x.via
            nativeHooks[n] = hk
        }
        var handlers: [String: Handler] = [:]
        var colourHandler: [Int: String] = [:]
        for (k, ip) in d.jumpTable.enumerated() {
            let name = String(format: "h%04x", ip)
            let v = d.firstValue + k
            handlers[name, default: Handler(name: name, entry: -1, entryIP: ip, colours: [])].colours.append(v)
            colourHandler[v] = name
        }
        var stubs: [Int: Stub] = [:]
        for (t, s) in h.stubs { stubs[t] = Stub(kind: s.kind, far: s.far) }
        let lt = d.lampTable
        var p = RulesProgram(
            table: table, exe: exeName ?? "EP\(table).EXE", annotated: false,
            codeSegment: image.entryCS, dataSegment: image.dataSegment, dispatcherIP: d.dispatchIP, sensorTable: d.tableIP,
            dsFileOffset: image.dsFileOffset, dsSize: image.dsSize, playerBlock: d.playerBlock,
            lampFirst: lt?.first ?? 0, lampCount: lt?.count ?? 0, lampPhase: lt?.phase, lampSlotCount: lt?.count ?? 0,
            vars: [:], engineVars: engineVars, blocks: [], labels: [:], hooks: hooks, handlers: handlers,
            colourHandler: colourHandler, level1Colours: [], tiltColours: [], lockoutFreeColours: [], gates: [],
            sweeps: [], messages: [:], messageTables: [:], stubs: stubs, registerNames: [], maskedRegisters: [])
        p.direct = true
        p.nativeHooks = nativeHooks
        p.hookStops = h.stops
        p.subs = h.subs
        p.ballEndCode = (h.hooks.values.filter { $0.when == "ball_end" } + h.nativeHooks.values).reduce(into: Set<Int>()) { $0.formUnion($1.code) }
        p.segmentVars = [d.segTop: 0, d.segBottom: 1]
        p.gateRoutines = Set(d.gates.map(\.routine))
        if let l = d.layout.csVars["key_lflip"] { p.inputKeys[l] = 0 }
        if let r = d.layout.csVars["key_rflip"] { p.inputKeys[r] = 1 }
        return (p, d, h)
    }
}
