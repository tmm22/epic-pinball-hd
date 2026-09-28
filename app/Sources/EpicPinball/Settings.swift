import Foundation
import Observation
import PinballCore
import PinballImport

/// Per-user locations of everything the front end writes. Nothing here is ever inside the app
/// bundle: settings, high scores and the imported library live in
/// `~/Library/Application Support/EpicPinballHD/` (or `--support-dir DIR` for tests).
enum AppPaths {
    /// `--support-dir`: replaces the Application Support root (tests, screenshots).
    nonisolated(unsafe) static var overrideRoot: URL?

    static var supportRoot: URL {
        if let o = overrideRoot { return o }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("EpicPinballHD", isDirectory: true)
    }
    static var settingsFile: URL { supportRoot.appendingPathComponent("settings.json") }
    static var highScoresFile: URL { supportRoot.appendingPathComponent("highscores.json") }
    /// `--library`: replaces the imported library's location only (settings and high scores stay
    /// in `supportRoot`).
    nonisolated(unsafe) static var libraryOverride: URL?

    /// The importer's output (PinballImport.LibraryLocation.defaultRoot unless overridden).
    static var libraryRoot: URL {
        if let l = libraryOverride { return l }
        return overrideRoot.map { $0.appendingPathComponent("Library", isDirectory: true) } ?? LibraryLocation.defaultRoot
    }

    static func ensureSupportRoot() throws {
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)
    }

    /// Atomic JSON write into the support directory.
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(value).write(to: url, options: .atomic)
    }
}

/// Settings that only the front end reads (the shared, cross-track ones are `GameSettings`).
/// Decoding is lenient: a missing or malformed field keeps its default, so a settings file from
/// an older or newer build never resets everything.
struct FrontEndSettings: Codable, Equatable, Sendable {
    var keyBindings = KeyBindings.defaults
    var controllerEnabled = true
    var haptics = true
    var startFullscreen = false
    /// "square" (1:1) or "vga" (1.2 tall pixels, 4:3).
    var pixelAspect = "square"
    var masterVolume = 0.9
    var players = 1
    var ballsPerGame = 3
    var lastTable = 1
    var showStrip = true

    init() {}

    enum CodingKeys: String, CodingKey {
        case keyBindings, controllerEnabled, haptics, startFullscreen, pixelAspect, masterVolume
        case players, ballsPerGame, lastTable, showStrip
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FrontEndSettings()
        func get<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        keyBindings = get(.keyBindings, d.keyBindings)
        controllerEnabled = get(.controllerEnabled, d.controllerEnabled)
        haptics = get(.haptics, d.haptics)
        startFullscreen = get(.startFullscreen, d.startFullscreen)
        pixelAspect = get(.pixelAspect, d.pixelAspect)
        masterVolume = min(max(get(.masterVolume, d.masterVolume), 0), 1)
        players = min(max(get(.players, d.players), 1), 4)
        ballsPerGame = min(max(get(.ballsPerGame, d.ballsPerGame), 1), 9)
        lastTable = min(max(get(.lastTable, d.lastTable), 1), TableGeometry.tableCount)
        showStrip = get(.showStrip, d.showStrip)
    }
}

/// The settings file: `{"version": 1, "game": GameSettings, "frontEnd": FrontEndSettings}`.
struct StoredSettings: Equatable {
    var game = GameSettings()
    var frontEnd = FrontEndSettings()

    static let version = 1

    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let game = try JSONSerialization.jsonObject(with: enc.encode(self.game))
        let fe = try JSONSerialization.jsonObject(with: enc.encode(frontEnd))
        return try JSONSerialization.data(withJSONObject: ["version": Self.version, "game": game, "frontEnd": fe],
                                          options: [.prettyPrinted, .sortedKeys])
    }

    /// Lenient: unknown keys are ignored, missing ones keep the defaults. `GameSettings` is a
    /// shared contract that other tracks extend, so its stored object is merged over the
    /// encoded defaults before decoding (a field added later does not invalidate the file);
    /// a field whose stored value no longer decodes is dropped and keeps its default.
    static func decode(_ data: Data) -> StoredSettings {
        var out = StoredSettings()
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return out }
        if let g = root["game"] as? [String: Any] { out.game = mergeDecode(GameSettings(), stored: g) }
        if let f = root["frontEnd"], let d = try? JSONSerialization.data(withJSONObject: f),
           let fe = try? JSONDecoder().decode(FrontEndSettings.self, from: d) {
            out.frontEnd = fe
        }
        return out
    }

    static func mergeDecode<T: Codable>(_ defaults: T, stored: [String: Any]) -> T {
        guard let dd = try? JSONEncoder().encode(defaults),
              var base = (try? JSONSerialization.jsonObject(with: dd)) as? [String: Any] else { return defaults }
        for (k, v) in stored where base[k] != nil { base[k] = v }
        if let d = try? JSONSerialization.data(withJSONObject: base), let t = try? JSONDecoder().decode(T.self, from: d) {
            return t
        }
        // Some stored value has the wrong type: take the fields one at a time.
        var good = (try? JSONSerialization.jsonObject(with: dd)) as? [String: Any] ?? [:]
        for (k, v) in stored where good[k] != nil {
            var trial = good
            trial[k] = v
            if let d = try? JSONSerialization.data(withJSONObject: trial), (try? JSONDecoder().decode(T.self, from: d)) != nil {
                good = trial
            }
        }
        if let d = try? JSONSerialization.data(withJSONObject: good), let t = try? JSONDecoder().decode(T.self, from: d) { return t }
        return defaults
    }
}

/// Observable settings, persisted to `AppPaths.settingsFile` on every change.
@MainActor
@Observable
final class SettingsStore {
    var game: GameSettings { didSet { if game != oldValue { changed() } } }
    var frontEnd: FrontEndSettings { didSet { if frontEnd != oldValue { changed() } } }
    /// Called after any change (the running game applies it live).
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored let fileURL: URL
    @ObservationIgnored var persist = true
    @ObservationIgnored private(set) var lastSaveError: String?

    init(fileURL: URL = AppPaths.settingsFile) {
        self.fileURL = fileURL
        let s = (try? Data(contentsOf: fileURL)).map(StoredSettings.decode) ?? StoredSettings()
        game = s.game
        frontEnd = s.frontEnd
    }

    func resetToDefaults() {
        game = GameSettings()
        let keepTable = frontEnd.lastTable
        frontEnd = FrontEndSettings()
        frontEnd.lastTable = keepTable
    }

    private func changed() {
        save()
        onChange?()
    }

    func save() {
        guard persist else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try StoredSettings(game: game, frontEnd: frontEnd).encoded().write(to: fileURL, options: .atomic)
            lastSaveError = nil
        } catch {
            lastSaveError = "\(error)"
            warn("cannot save settings to \(fileURL.path): \(error)")
        }
    }
}

extension GameSettings.UpscaleFilter {
    var label: String {
        switch self {
        case .nearest: return "Sharp pixels (original)"
        case .smooth: return "Smooth"
        case .xbrz: return "xBRZ-style edges"
        case .crt: return "CRT scanlines"
        }
    }
}

extension GameSettings.PhysicsMode {
    var label: String {
        switch self {
        case .classic: return "Classic (bit-exact original engine)"
        case .enhanced: return "Enhanced (smooth motion)"
        }
    }
}
