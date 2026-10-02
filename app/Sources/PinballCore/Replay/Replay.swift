import Foundation

// Replays: a game recorded as its per-frame inputs (`FrameInput` bits, one byte per original
// frame) plus what is needed to start the same simulation again. Playing a replay runs the real
// engine and rules from those inputs; nothing of the game's own data is stored in the file.
//
// Why inputs are enough (docs/enhanced/replays.md): the engine, the rules runtime and MiniX86 read
// nothing but the engine state, the table data and the frame input. The original's only "random"
// source the rules use is the frame counter (EP1 cs:09DC `skill_lane_rng` = counter mod 4, [H]);
// MiniX86 returns 0 for every port read except 3DAh, whose retrace bit toggles on each read (state
// in the snapshot, not a clock); there are no timer, BIOS tick or wall-clock reads, no threads, and
// the iteration orders that depend on Swift's per-process hash seed only build lookup tables whose
// result does not depend on the order (checked by the cross-process replays in replays.md). Enhanced
// physics is floating point: deterministic for the same binary on the same CPU architecture and
// libm; the header records the platform so a mismatch can be reported.
//
// File (`.epreplay`), little-endian:
//   "EPRP"  u8 format version (1)  u32 header length  header (UTF-8 JSON, `ReplayHeader`)
//   u32 run count, then per run: u8 input bits, LEB128 run length (frames)
// The runs must add up to `header.frames`.

public enum ReplayFormat {
    public static let magic: [UInt8] = Array("EPRP".utf8)
    public static let version: UInt8 = 1
    /// Bump when a change to the simulation (engine, rules runtime, MiniX86, enhanced physics, the
    /// start order) can change what the same inputs produce; replays of other versions are played
    /// but reported as possibly diverging.
    public static let engineVersion = 1
    public static let fileExtension = "epreplay"
    /// Upper bound on `ReplayHeader.frames` a file may claim (2^27 frames: over 24 days at 59.94 Hz).
    public static let maxFrames = 1 << 27
}

public enum ReplayError: Error, CustomStringConvertible {
    case badFile(String)
    case noRules(String)
    public var description: String {
        switch self {
        case let .badFile(s): return "not a replay file: \(s)"
        case let .noRules(s): return "the replay needs the table rules: \(s)"
        }
    }
}

/// A physics switch during the game (the E key or the settings), applied before frame `frame`.
public struct ReplayEvent: Codable, Sendable, Equatable {
    public var frame: Int
    public var physics: GameSettings.PhysicsMode
    public var enhancedConfig: EnhancedPhysicsConfig?
    /// A new model was installed since the previous frame even though `physics` may be the mode
    /// already running (enhanced -> classic -> enhanced between two frames: a fresh `EnhancedPhysics`).
    /// Absent (nil) in files without it: a mode change installs a model anyway.
    public var reinstall: Bool?
    public init(frame: Int, physics: GameSettings.PhysicsMode, enhancedConfig: EnhancedPhysicsConfig?, reinstall: Bool? = nil) {
        self.frame = frame; self.physics = physics; self.enhancedConfig = enhancedConfig; self.reinstall = reinstall
    }
}

/// Everything about a recorded game except its inputs.
public struct ReplayHeader: Codable, Sendable, Equatable {
    public var format = Int(ReplayFormat.version)
    public var engineVersion = ReplayFormat.engineVersion
    /// The app's version string (informational).
    public var appVersion = ""
    /// CPU architecture and OS of the recording (enhanced physics reproduces on the same platform).
    public var platform = ReplayHeader.currentPlatform
    public var table: Int
    public var date: Date
    /// Ball physics at frame 0 (later switches are `events`), and the enhanced tunables.
    public var physics: GameSettings.PhysicsMode
    public var enhancedConfig: EnhancedPhysicsConfig?
    /// "direct" or "lifted".
    public var rulesBackend: String
    /// The PINBALL.EXE command-line options (`RulesOptions`).
    public var players: Int
    public var ballsPerGame: Int
    public var sfx = true
    public var music = true
    public var soundPresent = true
    /// `ClassicEngine.gravityPhase` (0 in the app).
    public var gravityPhase = 0
    /// FNV-1a digests of the user's EPn.EXE and of engine.json + collision_idx.npy (+ rules.json for
    /// the lifted backend), to tell a replay recorded against other files apart (never the files).
    public var exeDigest: String?
    public var dataDigest: String?
    /// Filled when the recording ends.
    public var frames = 0
    public var finalScores: [UInt32] = []
    /// `StateHasher` digest of engine, rules and physics after the last frame.
    public var finalDigest = ""
    public var gameOver = false
    public var events: [ReplayEvent] = []
    /// Set by the front end for a game that entered the high-score list.
    public var initials: String?
    public var player: Int?

    public init(table: Int, date: Date = Date(), physics: GameSettings.PhysicsMode, enhancedConfig: EnhancedPhysicsConfig?,
                rulesBackend: String, options: RulesOptions) {
        // whole seconds: the file stores ISO 8601 dates
        self.table = table; self.date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        self.physics = physics; self.enhancedConfig = enhancedConfig
        self.rulesBackend = rulesBackend
        players = options.players; ballsPerGame = options.ballsPerGame
        sfx = options.sfx; music = options.music; soundPresent = options.soundPresent
    }

    public var rulesOptions: RulesOptions {
        var o = RulesOptions()
        o.players = players; o.ballsPerGame = ballsPerGame; o.sfx = sfx; o.music = music; o.soundPresent = soundPresent
        return o
    }

    public static var currentPlatform: String {
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "other"
        #endif
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(arch) macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The part of a `platform` string a mismatch is reported for: the architecture and the major OS
    /// release ("arm64 macOS 26.5.2" -> "arm64 macOS 26"). Minor updates are not reported (they would
    /// flag every enhanced replay after each update); the full string stays in the header.
    public static func platformFamily(_ p: String) -> String {
        var parts = p.split(separator: " ").map(String.init)
        if let last = parts.last, let major = last.split(separator: ".").first { parts[parts.count - 1] = String(major) }
        return parts.joined(separator: " ")
    }

    /// FNV-1a 64 of the files (hex), nil if one is missing.
    public static func fileDigest(_ urls: [URL]) -> String? {
        var h = StateHasher()
        for u in urls {
            guard let d = try? Data(contentsOf: u) else { return nil }
            h.add([UInt8](d))
        }
        return h.hex
    }

    /// Fills `exeDigest` / `dataDigest` from the table's files (`rulesBackend` must be set: the
    /// lifted rules also read rules.json).
    public mutating func setDigests(dataRoot: URL, originalDir: URL?) {
        exeDigest = RulesRuntime.locateEXE(dataRoot: dataRoot, table: table, originalDir: originalDir).flatMap { Self.fileDigest([$0]) }
        let dir = dataRoot.appendingPathComponent("tables/EP\(table)", isDirectory: true)
        var files = [dir.appendingPathComponent("engine.json"), dir.appendingPathComponent("collision_idx.npy")]
        if rulesBackend == RulesBackend.lifted.rawValue { files.append(dir.appendingPathComponent("rules.json")) }
        dataDigest = Self.fileDigest(files)
    }
}

public struct Replay: Sendable, Equatable {
    public var header: ReplayHeader
    /// One `FrameInput.rawValue` per original frame.
    public var inputs: [UInt8]

    public init(header: ReplayHeader, inputs: [UInt8]) { self.header = header; self.inputs = inputs }

    /// Run-length encoding of `inputs`: (bits, frames).
    public static func runs(_ inputs: [UInt8]) -> [(UInt8, Int)] {
        var out: [(UInt8, Int)] = []
        for b in inputs {
            if let last = out.last, last.0 == b { out[out.count - 1].1 += 1 } else { out.append((b, 1)) }
        }
        return out
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let json = try enc.encode(header)
        var out = Data(ReplayFormat.magic)
        out.append(ReplayFormat.version)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { out.append(contentsOf: $0) } }
        u32(json.count)
        out.append(json)
        let r = Self.runs(inputs)
        u32(r.count)
        for (bits, n) in r {
            out.append(bits)
            var v = n
            repeat {
                var b = UInt8(v & 0x7F)
                v >>= 7
                if v != 0 { b |= 0x80 }
                out.append(b)
            } while v != 0
        }
        return out
    }

    public static func decode(_ data: Data) throws -> Replay {
        let b = [UInt8](data)
        var p = 0
        func need(_ n: Int) throws { if p + n > b.count { throw ReplayError.badFile("truncated at byte \(p)") } }
        func u32() throws -> Int {
            try need(4)
            let v = Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24
            p += 4
            return v
        }
        try need(5)
        guard Array(b[0..<4]) == ReplayFormat.magic else { throw ReplayError.badFile("bad magic") }
        guard b[4] == ReplayFormat.version else { throw ReplayError.badFile("format version \(b[4]) (this build reads \(ReplayFormat.version))") }
        p = 5
        let hl = try u32()
        try need(hl)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let header: ReplayHeader
        do { header = try dec.decode(ReplayHeader.self, from: Data(b[p..<(p + hl)])) } catch {
            throw ReplayError.badFile("header: \(error)")
        }
        p += hl
        // A damaged or edited header must not trap or allocate without bound (the launcher lists the
        // saved replays by decoding them).
        guard (0...ReplayFormat.maxFrames).contains(header.frames) else { throw ReplayError.badFile("frame count \(header.frames)") }
        let n = try u32()
        guard n <= header.frames else { throw ReplayError.badFile("\(n) runs for \(header.frames) frames") }
        var inputs: [UInt8] = []
        inputs.reserveCapacity(header.frames)
        for _ in 0..<n {
            try need(1)
            let bits = b[p]; p += 1
            var len = 0, shift = 0
            while true {
                try need(1)
                let c = b[p]; p += 1
                len |= Int(c & 0x7F) << shift
                shift += 7
                if c & 0x80 == 0 { break }
                if shift > 35 { throw ReplayError.badFile("bad run length") }
            }
            guard len <= header.frames - inputs.count else { throw ReplayError.badFile("more frames than the header's \(header.frames)") }
            inputs.append(contentsOf: repeatElement(bits, count: len))
        }
        guard inputs.count == header.frames else { throw ReplayError.badFile("\(inputs.count) frames, header says \(header.frames)") }
        return Replay(header: header, inputs: inputs)
    }

    public static func load(contentsOf url: URL) throws -> Replay { try decode(Data(contentsOf: url)) }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }
}

/// Records the game running on a `GameSimulation` from its first frame (create it right after the
/// game started, before any frame ran).
public final class ReplayRecorder {
    public private(set) var header: ReplayHeader
    public private(set) var inputs: [UInt8] = []
    private var physics: GameSettings.PhysicsMode
    private var config: EnhancedPhysicsConfig
    private var installs: Int
    private weak var simulation: GameSimulation?

    /// `options`: the options the game started with (default: the ones the rules were booted with).
    public init(simulation sim: GameSimulation, options given: RulesOptions? = nil) {
        let options = given ?? sim.engine.rules?.options ?? RulesOptions()
        physics = sim.physicsMode
        config = sim.enhancedConfig
        installs = sim.physicsInstalls
        header = ReplayHeader(table: sim.engine.data.table, physics: sim.physicsMode,
                              enhancedConfig: sim.physicsMode == .enhanced ? sim.enhancedConfig : nil,
                              rulesBackend: sim.engine.rules?.backend.rawValue ?? "none", options: options)
        header.gravityPhase = sim.engine.gravityPhase
        inputs.reserveCapacity(1 << 14)
        simulation = sim
        sim.frameObserver = { [weak self] s, i in self?.record(s, i) }
    }

    /// Continues the recording `replay` (a game's first `replay.inputs.count` frames) on `sim`, which
    /// must be in the state those frames lead to (restored from a save state taken at that frame,
    /// or re-simulated from the power-on state with `ReplayPlayer`). Practice save states on disk
    /// are such prefixes; a state loaded from one keeps being recorded so it can be saved again.
    /// The physics tracking starts from what the prefix's last frame ran with, so a physics switch
    /// made after that frame is recorded as an event at the next frame, as it would have been.
    public init(resuming replay: Replay, simulation sim: GameSimulation) {
        var h = replay.header
        h.frames = 0
        h.finalScores = []
        h.finalDigest = ""
        h.gameOver = false
        header = h
        inputs = replay.inputs
        let last = replay.header.events.last { $0.frame <= replay.inputs.count }
        physics = last?.physics ?? replay.header.physics
        config = last?.enhancedConfig ?? replay.header.enhancedConfig ?? sim.enhancedConfig
        installs = sim.physicsInstalls
        simulation = sim
        sim.frameObserver = { [weak self] s, i in self?.record(s, i) }
    }

    /// The recording so far, without stopping it: frames, the current scores and the state digest
    /// at this frame boundary (`finalDigest`), `gameOver` false. Practice save states write this.
    public func snapshot(scores: [UInt32]) -> Replay {
        var h = header
        h.frames = inputs.count
        h.finalScores = scores
        h.finalDigest = simulation?.stateDigest().hex ?? ""
        h.gameOver = false
        return Replay(header: h, inputs: inputs)
    }

    /// The header fields the recorder cannot know (app version, file digests).
    public func describe(_ f: (inout ReplayHeader) -> Void) { f(&header) }

    func record(_ sim: GameSimulation, _ input: FrameInput) {
        // A model installed since the last frame counts even when the mode is the same again (a
        // fresh enhanced model has new bodies and substep counters); a classic -> enhanced -> classic
        // round trip leaves nothing behind and needs no event.
        let installed = sim.physicsInstalls != installs
        installs = sim.physicsInstalls
        let reinstalled = installed && sim.physicsMode == .enhanced && physics == .enhanced
        if sim.physicsMode != physics || (sim.physicsMode == .enhanced && sim.enhancedConfig != config) || reinstalled {
            physics = sim.physicsMode
            config = sim.enhancedConfig
            header.events.append(ReplayEvent(frame: inputs.count, physics: physics, enhancedConfig: physics == .enhanced ? config : nil,
                                             reinstall: reinstalled ? true : nil))
        }
        inputs.append(UInt8(truncatingIfNeeded: input.rawValue))
    }

    public var frames: Int { inputs.count }

    /// Stops recording (detaches from the simulation) and returns the replay. `scores` are the final
    /// per-player scores the front end showed (`PresentationState.scores` of the last frame).
    public func finish(scores: [UInt32], gameOver: Bool) -> Replay {
        if let s = simulation {
            header.finalDigest = s.stateDigest().hex
            if s.frameObserver != nil { s.frameObserver = nil }
        }
        simulation = nil
        header.frames = inputs.count
        header.finalScores = scores
        header.gameOver = gameOver
        return Replay(header: header, inputs: inputs)
    }

    /// Stops recording without a result (a new game, practice mode, leaving the table).
    public func cancel() {
        if let s = simulation { s.frameObserver = nil }
        simulation = nil
    }
}

/// The result of re-simulating a replay.
public struct ReplayCheck: Codable, Sendable, Equatable {
    public var table: Int
    public var frames: Int
    public var scores: [UInt32]
    public var gameOver: Bool
    public var digest: String
    public var expectedDigest: String
    public var expectedScores: [UInt32]
    /// Final state digest and scores identical to the recording.
    public var matches: Bool
    /// Why a mismatch may be expected (other engine version, files, platform), if any.
    public var notes: [String]
}

/// Plays a replay on a `GameSimulation` built by `makeSimulation` (or one in the same start state).
public final class ReplayPlayer {
    public let replay: Replay
    public private(set) var frame = 0
    private var nextEvent = 0
    /// Playback speed (1, 2, 4, ...) for `advance`.
    public var speed: Double = 1
    private var accumulator = 0.0

    public init(replay: Replay) { self.replay = replay }

    public var finished: Bool { frame >= replay.inputs.count }
    public var frameCount: Int { replay.inputs.count }

    /// Runs the next recorded frame on `sim` (physics switches of that frame first). False when the
    /// replay has ended.
    @discardableResult
    public func stepFrame(_ sim: GameSimulation) -> Bool {
        guard !finished else { return false }
        let ev = replay.header.events
        while nextEvent < ev.count && ev[nextEvent].frame <= frame {
            let e = ev[nextEvent]
            if let c = e.enhancedConfig { sim.enhancedConfig = c }
            if sim.physicsMode != e.physics {
                sim.physicsMode = e.physics   // installs the model
            } else if e.reinstall == true {
                sim.reinstallPhysics()        // the recording got a fresh model in the same mode
            }
            nextEvent += 1
        }
        sim.inputProvider = nil
        sim.input = FrameInput(rawValue: Int(replay.inputs[frame]))
        sim.stepFrame()
        frame += 1
        return true
    }

    /// Wall-clock time -> recorded frames at `speed` (at most 0.1 s of real time per call, as
    /// `GameSimulation.advance`). Returns the frames run.
    public func advance(_ sim: GameSimulation, by realTime: Double) -> Int {
        accumulator += min(max(realTime, 0), sim.maxFrameTime) * max(speed, 0)
        let h = sim.frameDuration
        var n = 0
        while accumulator + 1e-9 >= h, !finished {
            stepFrame(sim)
            accumulator -= h
            n += 1
        }
        if finished { accumulator = 0 }
        accumulator = max(accumulator, 0)
        return n
    }

    /// The simulation a replay starts from: a newly loaded engine for the recorded table and rules
    /// backend, the recorded options, gravity phase and starting physics, in `GameSimulation.init`'s
    /// order (the order the app starts every recorded game in).
    public static func makeSimulation(for h: ReplayHeader, dataRoot: URL, originalDir: URL? = nil,
                                      mode: SimulationMode = .classic) throws -> GameSimulation {
        makeSimulation(for: h, engine: try makeEngine(for: h, dataRoot: dataRoot, originalDir: originalDir), mode: mode)
    }

    /// The newly loaded engine of `makeSimulation` (rules attached, no game started yet).
    public static func makeEngine(for h: ReplayHeader, dataRoot: URL, originalDir: URL? = nil) throws -> ClassicEngine {
        let backend = RulesBackend(rawValue: h.rulesBackend) ?? .default
        let e = try EngineAssets.makeEngine(dataRoot: dataRoot, table: h.table, originalDir: originalDir, backend: backend)
        guard e.rules != nil else { throw ReplayError.noRules(e.rulesLoadError ?? "not loaded") }
        e.gravityPhase = h.gravityPhase
        return e
    }

    /// Starts the recorded game on `engine` (from `makeEngine`, or restored to its power-on state).
    public static func makeSimulation(for h: ReplayHeader, engine e: ClassicEngine, mode: SimulationMode = .classic) -> GameSimulation {
        GameSimulation(engine: e, mode: mode, options: h.rulesOptions, physics: h.physics, enhancedConfig: h.enhancedConfig ?? .classicFeel)
    }

    /// Reasons a replay may not reproduce here (empty when everything matches).
    public static func notes(for h: ReplayHeader, simulation sim: GameSimulation?, dataRoot: URL?, originalDir: URL?) -> [String] {
        var out: [String] = []
        if h.engineVersion != ReplayFormat.engineVersion {
            out.append("recorded with engine version \(h.engineVersion), this build has \(ReplayFormat.engineVersion)")
        }
        if let b = sim?.engine.rules?.backend.rawValue, b != h.rulesBackend { out.append("recorded with the \(h.rulesBackend) rules, playing with \(b)") }
        if let root = dataRoot {
            var cur = h
            cur.setDigests(dataRoot: root, originalDir: originalDir)
            if h.exeDigest != nil, cur.exeDigest != h.exeDigest { out.append("EP\(h.table).EXE differs from the one recorded with") }
            if h.dataDigest != nil, cur.dataDigest != h.dataDigest { out.append("the imported table data differs from the recording's") }
        }
        let usesEnhanced = h.physics == .enhanced || h.events.contains { $0.physics == .enhanced }
        if usesEnhanced, ReplayHeader.platformFamily(h.platform) != ReplayHeader.platformFamily(ReplayHeader.currentPlatform) {
            out.append("enhanced physics recorded on \(h.platform), playing on \(ReplayHeader.currentPlatform)")
        }
        return out
    }

    /// Re-simulates the whole replay headless and compares the final state with the recording.
    public static func verify(_ replay: Replay, dataRoot: URL, originalDir: URL? = nil) throws -> ReplayCheck {
        let sim = try makeSimulation(for: replay.header, dataRoot: dataRoot, originalDir: originalDir)
        let p = ReplayPlayer(replay: replay)
        var last = PresentationState()
        while p.stepFrame(sim) { last = sim.takePresentation() }
        let d = sim.stateDigest().hex
        let h = replay.header
        let n = max(1, min(last.playerCount, last.scores.count))
        let scores = Array(last.scores.prefix(n))
        return ReplayCheck(table: h.table, frames: p.frame, scores: scores, gameOver: last.gameOver, digest: d,
                           expectedDigest: h.finalDigest, expectedScores: h.finalScores,
                           matches: d == h.finalDigest && scores == h.finalScores,
                           notes: notes(for: h, simulation: sim, dataRoot: dataRoot, originalDir: originalDir))
    }
}
