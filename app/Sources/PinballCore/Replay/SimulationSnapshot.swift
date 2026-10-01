import Foundation

// Save states of a running table: the classic engine, the attached rules (the machine's data
// segment, MiniX86's registers, stack and retrace toggle, the message / lamp / sound bookkeeping)
// and the enhanced ball physics, taken and restored between frames. Used by practice mode (save /
// restore at a key press) and by replays (every recorded game starts from the engine's power-on
// state, `GameSimulation.newGame(options:powerOn:)`).
//
// Nothing here runs unless a caller asks for it: the engine, rules and physics code paths are
// unchanged, so the classic engine stays bit-exact with the original (parity suite 830/830).
//
// What a snapshot does not contain: the table data and everything derived from it (engine.json
// tables, the EXE's code segment, discovered rule program, distance-field kernels), and diagnostics
// that callers clear themselves (`onStep`). The audio engine's playing voices are not simulation
// state; the app stops them on restore. The sounds and texts queued since the last
// `takePresentation` are kept, so the next presentation after a restore is the one the saved frame
// would have produced.

/// FNV-1a (64 bit) over the simulation state in a fixed order: the identity of a game state for
/// replay verification and the save-state tests. Independent of Swift's per-process hash seed.
public struct StateHasher {
    public private(set) var value: UInt64 = 0xCBF2_9CE4_8422_2325

    public init() {}

    @inline(__always) mutating func byte(_ b: UInt8) {
        value ^= UInt64(b)
        value = value &* 0x0000_0100_0000_01B3
    }

    public mutating func add<T: FixedWidthInteger>(_ v: T) {
        var x = UInt64(truncatingIfNeeded: v)
        for _ in 0..<8 { byte(UInt8(truncatingIfNeeded: x)); x >>= 8 }
    }

    public mutating func add(_ b: Bool) { byte(b ? 1 : 0) }

    public mutating func add(_ bytes: [UInt8]) {
        add(bytes.count)
        for b in bytes { byte(b) }
    }

    public mutating func add<T: FixedWidthInteger>(_ list: [T]) {
        add(list.count)
        for v in list { add(v) }
    }

    /// 16 hex digits.
    public var hex: String { String(format: "%016llx", value) }
}

/// The engine with its rules and ball physics model at a frame boundary.
public struct EngineSnapshot {
    let engine: ClassicEngine.State
    let rules: RulesRuntime.State?
    let physics: EnhancedPhysics.State?

    /// The engine frame the snapshot was taken at.
    public var frame: Int { engine.frameCount }
    /// Whether the enhanced model was installed.
    public var enhanced: Bool { physics != nil }
}

extension ClassicEngine {
    public func snapshot() -> EngineSnapshot {
        EngineSnapshot(engine: saveState(), rules: rules?.saveState(), physics: (ballPhysics as? EnhancedPhysics)?.saveState())
    }

    /// Back to `s`. An `EnhancedPhysics` model is installed (or reused) when the snapshot had one and
    /// removed when it had none; its whole state comes from the snapshot.
    public func restore(_ s: EngineSnapshot) {
        if let ps = s.physics {
            let m = (ballPhysics as? EnhancedPhysics) ?? EnhancedPhysics.install(on: self, config: ps.config)
            m.restoreState(ps)
        } else if ballPhysics is EnhancedPhysics {
            EnhancedPhysics.uninstall(from: self)
        }
        restoreState(s.engine)   // after the install, which resets `bufferWriteLog`
        if let r = rules, let rs = s.rules { r.restoreState(rs) }
    }

    /// FNV-1a digest of the engine, rules and model state (see `StateHasher`).
    public func stateDigest() -> StateHasher {
        var h = StateHasher()
        digest(into: &h)
        if let r = rules { h.add(true); r.digest(into: &h) } else { h.add(false) }
        if let m = ballPhysics as? EnhancedPhysics { h.add(true); m.digest(into: &h) } else { h.add(false) }
        return h
    }
}

/// A practice save state: the engine snapshot plus the driver's fields (`GameSimulation`).
public struct SimulationSnapshot {
    public let engine: EngineSnapshot
    let sim: GameSimulation.State
    public var frame: Int { engine.frame }
}

extension GameSimulation {
    public func snapshot() -> SimulationSnapshot {
        SimulationSnapshot(engine: engine.snapshot(), sim: saveState())
    }

    /// Back to `s`: continuing from here gives exactly the frames that followed the save
    /// (ReplayTests.testSaveRestoreContinuesIdentically).
    public func restore(_ s: SimulationSnapshot) {
        restoreState(s.sim)
        engine.restore(s.engine)
    }

    public func stateDigest() -> StateHasher { engine.stateDigest() }
}
