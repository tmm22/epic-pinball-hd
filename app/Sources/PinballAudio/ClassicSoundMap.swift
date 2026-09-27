import Foundation

/// Facts about the original sound path that the classic mixer reproduces.
/// Evidence for each value is in docs/formats/audio.md.
public enum ClassicSoundMap {
    /// Sound bank loaded for table n (1...13): `SFXn.PIN`. The launcher calls its
    /// loader (cs:0CCA) with AX = selected table + 1 before running EPn.EXE
    /// (cs:3CFB..3D03) and AX = 0 for its own menus. [H]
    public static func sfxBank(forTable table: Int) -> Int { table }
    /// Song loaded for table n: `SONGn.PSM`, subsong "MAINSONG". [H]
    public static func song(forTable table: Int) -> Int { table }
    /// Bank and song the launcher uses for its menus. [H]
    public static let launcherBank = 0
    public static let launcherSong = 0

    /// `sfx_rate_hz` initial value in all 13 tables (EP1 ds:0ADC). [H]
    public static let baseRateHz = 11000
    /// Logical SFX channels: `sfx_play` (EP1 cs:014A) round-robins 4 channels and
    /// stops the channel's previous voice before each play. [H]
    public static let channels = 4
    /// Video frame rate (25.175 MHz / (800 * 525)); the table updates pitch sweeps
    /// once per frame in its main loop. [H]
    public static let frameRateHz = 25_175_000.0 / 420_000.0
    /// Pan positions 0...15 (`sfx_play`: ah >> 4, or ball x / 20, clamped to 15).
    public static let panSteps = 16

    /// Pan the original computes when the sound id has no explicit pan nibble:
    /// `min(ball_x / 20, 15)` (cs:0202..0215).
    public static func pan(forBallX x: Int) -> Int { max(0, min(x / 20, 15)) }

    /// Case-tolerant lookup of an original file (the CD uses upper case, the
    /// launcher opens lower-case names).
    public static func originalFile(_ name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        for candidate in [name.uppercased(), name.lowercased(), name] {
            let url = dir.appendingPathComponent(candidate)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return dir.appendingPathComponent(name.uppercased())
    }

    public static func sfxURL(originalDir: URL, bank: Int) -> URL {
        originalFile("SFX\(bank).PIN", in: originalDir)
    }

    public static func songURL(originalDir: URL, song: Int) -> URL {
        originalFile("SONG\(song).PSM", in: originalDir)
    }
}

/// Resolves the user's `original/` directory (the files from their own CD).
public enum OriginalDataLocator {
    /// `<package>/../original`, from this file's compile-time path
    /// (`app/Sources/PinballAudio/ClassicSoundMap.swift`).
    public static var packageRelativeDefault: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PinballAudio
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("original", isDirectory: true)
    }

    /// Candidates in order: explicit path, `$EPIC_PINBALL_ORIGINAL`,
    /// `$EPIC_PINBALL_DATA/../original`, `<package>/../original`.
    public static func candidates(explicit: String? = nil) -> [URL] {
        var out: [URL] = []
        if let explicit { out.append(URL(fileURLWithPath: explicit, isDirectory: true)) }
        let env = ProcessInfo.processInfo.environment
        if let p = env["EPIC_PINBALL_ORIGINAL"] { out.append(URL(fileURLWithPath: p, isDirectory: true)) }
        if let p = env["EPIC_PINBALL_DATA"] {
            out.append(URL(fileURLWithPath: p, isDirectory: true)
                .deletingLastPathComponent().appendingPathComponent("original", isDirectory: true))
        }
        out.append(packageRelativeDefault)
        return out
    }

    /// First candidate that contains `SFX1.PIN`, or nil.
    public static func resolve(explicit: String? = nil) -> URL? {
        candidates(explicit: explicit).first {
            FileManager.default.fileExists(atPath: ClassicSoundMap.sfxURL(originalDir: $0, bank: 1).path)
        }
    }
}
