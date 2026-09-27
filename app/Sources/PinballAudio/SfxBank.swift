import Foundation

/// One `SFXn.PIN` sound bank, parsed the way the launcher loads it
/// (PINBALL.EXE file 0x1D7F..0x1E30, see docs/formats/audio.md):
///
/// * header: 0x64 bytes = 25 entries of `(u16 len, u16 paras)`;
/// * loading stops at the first entry whose `paras` is 0;
/// * entry i is played from file offset `(paras + 1) * 16` for `len - 0x28` bytes;
/// * the data is signed 8-bit mono PCM (descriptor flag 0x10 = "raw", so the
///   MASI loader skips its delta decoder).
///
/// Nothing from the bank is stored in the repository; it is read at runtime
/// from the user's own `original/` directory.
public struct SfxBank: Sendable {
    public struct Entry: Sendable, Equatable {
        /// Index in the header = the id the table passes in AL to `sfx_play`.
        public var index: Int
        /// Header `len` field (bytes, counted from `paras * 16`).
        public var headerLength: Int
        /// Header `paras` field (16-byte paragraphs from the file start).
        public var paragraphs: Int
        /// File offset of the first played byte: `(paras + 1) * 16`.
        public var playOffset: Int
        /// Number of played bytes: `len - 0x28` (clamped to the file end and to >= 0).
        public var playLength: Int
    }

    public static let headerEntries = 25
    public static let headerBytes = 0x64
    /// Bytes skipped at `paras * 16` before the played data.
    public static let skipHead = 16
    /// `len - trimTotal` bytes are played.
    public static let trimTotal = 0x28

    public let entries: [Entry]
    /// Signed 8-bit PCM per entry (same order as `entries`, index == entry.index).
    public let samples: [[Int8]]

    public var count: Int { samples.count }

    public enum BankError: Error, CustomStringConvertible {
        case tooShort(Int)
        case missing(URL)
        public var description: String {
            switch self {
            case let .tooShort(n): return "SFX bank is \(n) bytes, shorter than its 0x64-byte header"
            case let .missing(url): return "missing sound bank \(url.path) (it is read from your own copy of the game)"
            }
        }
    }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.headerBytes else { throw BankError.tooShort(bytes.count) }
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        var entries: [Entry] = []
        var samples: [[Int8]] = []
        for i in 0..<Self.headerEntries {
            let len = u16(i * 4)
            let paras = u16(i * 4 + 2)
            if paras == 0 { break } // launcher: `cmp dx,0 / je done` (file 0x1DC6)
            let start = (paras + 1) * 16
            // The launcher computes len - 0x28 in 16 bits; a shorter entry would wrap.
            // No bank on the CD has one, so clamp instead of reproducing the wrap.
            var n = max(0, len - Self.trimTotal)
            n = max(0, min(n, bytes.count - start))
            entries.append(Entry(index: i, headerLength: len, paragraphs: paras,
                                 playOffset: start, playLength: n))
            if n > 0 {
                samples.append(bytes[start..<(start + n)].map { Int8(bitPattern: $0) })
            } else {
                samples.append([])
            }
        }
        self.entries = entries
        self.samples = samples
    }

    public init(contentsOf url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw BankError.missing(url) }
        try self.init(data: try Data(contentsOf: url))
    }

    /// Loads `SFX<bank>.PIN` from the user's original directory.
    public static func load(originalDir: URL, bank: Int) throws -> SfxBank {
        let url = ClassicSoundMap.sfxURL(originalDir: originalDir, bank: bank)
        return try SfxBank(contentsOf: url)
    }
}
