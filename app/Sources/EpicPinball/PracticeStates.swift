import Foundation
import PinballCore

// Practice save states on disk (docs/enhanced/replays.md "Save states on disk"). A state is stored
// as the game that led to it: the input-only replay from the table's power-on state up to the
// saved frame (PinballCore's Replay format, deterministic like every replay), plus the frame,
// scores and state digest it reached. Loading re-simulates those frames on the running table
// (engine, rules, physics and the classic presentation, without drawing or sound) and checks the
// digest, so a state loaded in a new run continues exactly as it would have in the run that saved
// it. Nothing here is game data: the files hold key presses and numbers about the user's own game,
// in the user's support directory. Practice games never reach the high scores or statistics.

extension AppPaths {
    /// `<support>/SaveStates/EPn-slotK.epstate`.
    static var saveStatesDirectory: URL { supportRoot.appendingPathComponent("SaveStates", isDirectory: true) }
}

/// One saved practice state (JSON).
struct PracticeStateFile: Codable, Equatable, Sendable {
    static let formatName = "epic-pinball-practice-state"
    static let currentVersion = 1
    static let fileExtension = "epstate"
    /// Slots per table (digit keys 1...slotCount select one in a practice game).
    static let slotCount = 4

    var format = PracticeStateFile.formatName
    var version = PracticeStateFile.currentVersion
    var table: Int
    var slot: Int
    var date: Date
    /// Engine frame of the state (frames since the game started).
    var frame: Int
    var scores: [UInt32]
    var gameOver: Bool
    /// The physics running at the save. A switch made after the last frame (E, then K before the
    /// next frame) is not in the replay yet; loading applies it after the re-simulation.
    var physics: GameSettings.PhysicsMode
    var enhancedConfig: EnhancedPhysicsConfig?
    /// `GameSimulation.stateDigest()` at the save (engine, rules data segment, MiniX86, physics).
    var digest: String
    /// `Replay.encoded()` of the game up to the save (base64 in the JSON).
    var replay: Data

    init(table: Int, slot: Int, date: Date = Date(), frame: Int, scores: [UInt32], gameOver: Bool,
         physics: GameSettings.PhysicsMode, enhancedConfig: EnhancedPhysicsConfig?, digest: String, replay: Data) {
        self.table = table; self.slot = slot; self.date = date; self.frame = frame; self.scores = scores
        self.gameOver = gameOver; self.physics = physics; self.enhancedConfig = enhancedConfig
        self.digest = digest; self.replay = replay
    }
}

/// The SaveStates directory of one support root.
struct PracticeStateStore: Sendable {
    let directory: URL

    init(directory: URL = AppPaths.saveStatesDirectory) { self.directory = directory }

    enum Loaded {
        case missing
        case ok(PracticeStateFile, Replay)
        /// The file did not decode; it was moved aside to `movedTo` (nil if that failed too).
        case damaged(reason: String, movedTo: URL?)
        /// A newer format version or another table's file: left in place.
        case unsupported(String)
    }

    static func fileName(table: Int, slot: Int) -> String { "EP\(table)-slot\(slot).\(PracticeStateFile.fileExtension)" }
    func url(table: Int, slot: Int) -> URL { directory.appendingPathComponent(Self.fileName(table: table, slot: slot)) }
    func exists(table: Int, slot: Int) -> Bool { FileManager.default.fileExists(atPath: url(table: table, slot: slot).path) }

    /// Writes `f` atomically (replacing the slot's previous state).
    func write(_ f: PracticeStateFile) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try enc.encode(f).write(to: url(table: f.table, slot: f.slot), options: .atomic)
    }

    /// Reads the slot's state. A file that does not decode (truncated, not JSON, bad replay data)
    /// is moved aside as `<name>.bad` (replacing an older one), as the high-score and statistics
    /// files are, so the slot is free again.
    func load(table: Int, slot: Int) -> Loaded {
        let u = url(table: table, slot: slot)
        guard let data = try? Data(contentsOf: u) else { return .missing }
        if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           (root["format"] as? String) == PracticeStateFile.formatName,
           let v = (root["version"] as? NSNumber)?.intValue, v > PracticeStateFile.currentVersion {
            return .unsupported("slot \(slot) was saved by a newer version of the app (format \(v))")
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            let f = try dec.decode(PracticeStateFile.self, from: data)
            guard f.format == PracticeStateFile.formatName else { throw PracticeStateError.notAState }
            guard f.table == table, f.slot == slot else {
                return .unsupported("slot \(slot)'s file belongs to table \(f.table), slot \(f.slot)")
            }
            let r = try Replay.decode(f.replay)
            guard r.header.table == table, r.inputs.count == f.frame else { throw PracticeStateError.inconsistent }
            return .ok(f, r)
        } catch {
            let bad = u.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: bad)
            let moved = (try? FileManager.default.moveItem(at: u, to: bad)) != nil
            warn("practice state \(u.path) is damaged (\(error)); " + (moved ? "kept as \(bad.lastPathComponent)" : "could not be moved aside"))
            return .damaged(reason: "\(error)", movedTo: moved ? bad : nil)
        }
    }

    /// The slots of `table` that have a file (not checked further).
    func occupiedSlots(table: Int) -> [Int] { (1...PracticeStateFile.slotCount).filter { exists(table: table, slot: $0) } }

    /// Deletes the table's states (Settings > Library).
    func clear(table: Int) {
        for s in 1...PracticeStateFile.slotCount { try? FileManager.default.removeItem(at: url(table: table, slot: s)) }
    }
}

enum PracticeStateError: Error, CustomStringConvertible {
    case notAState, inconsistent
    var description: String {
        switch self {
        case .notAState: return "not a practice state file"
        case .inconsistent: return "the stored game does not match the state's table or frame"
        }
    }
}
