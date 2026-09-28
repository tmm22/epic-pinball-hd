import Foundation

/// One high-score entry: three initials, as the original's entry screen takes them.
struct HighScoreEntry: Codable, Equatable, Sendable {
    var initials: String
    var score: UInt32
    var date: Date
    /// Players in that game and which one scored (1-based), for display only.
    var players: Int = 1
    var player: Int = 1
    /// "classic" or "enhanced" physics, so the two can be told apart later.
    var physics: String = "classic"
}

/// Per-table top-10 lists, persisted as JSON in Application Support
/// (`{"version": 1, "tables": {"1": [...], ...}}`). Higher score ranks first; on a tie the
/// older entry stays ahead (a new score must beat an entry to pass it).
struct HighScoreBook: Codable, Equatable, Sendable {
    static let capacity = 10
    static let initialsLength = 3

    var version = 1
    var tables: [String: [HighScoreEntry]] = [:]

    func entries(table: Int) -> [HighScoreEntry] { tables[String(table)] ?? [] }

    /// The rank (0-based) `score` would take, or nil if it does not make the list.
    func rank(for score: UInt32, table: Int) -> Int? {
        guard score > 0 else { return nil }
        let list = entries(table: table)
        let r = list.firstIndex { score > $0.score } ?? list.count
        return r < Self.capacity ? r : nil
    }

    /// Inserts and trims to 10; returns the entry's rank (0-based) or nil if it did not qualify.
    @discardableResult
    mutating func insert(_ e: HighScoreEntry, table: Int) -> Int? {
        guard let r = rank(for: e.score, table: table) else { return nil }
        var list = entries(table: table)
        var entry = e
        entry.initials = Self.normalise(e.initials)
        list.insert(entry, at: r)
        if list.count > Self.capacity { list.removeLast(list.count - Self.capacity) }
        tables[String(table)] = list
        return r
    }

    /// Upper-case, A-Z / 0-9 / space / '.', padded or cut to 3 characters.
    static func normalise(_ s: String) -> String {
        let allowed = Set(InitialsEntry.alphabet)
        var out = String(s.uppercased().filter { allowed.contains($0) }.prefix(initialsLength))
        while out.count < initialsLength { out.append(" ") }
        return out
    }
}

/// Loads and saves the book; a damaged file is kept aside (`highscores.json.bad`) rather than
/// silently overwritten.
@MainActor
final class HighScoreStore {
    let fileURL: URL
    private(set) var book: HighScoreBook

    init(fileURL: URL = AppPaths.highScoresFile) {
        self.fileURL = fileURL
        let fm = FileManager.default
        if let d = try? Data(contentsOf: fileURL) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let b = try? dec.decode(HighScoreBook.self, from: d) {
                book = b
            } else {
                warn("high score file \(fileURL.path) is damaged; kept as .bad, starting a new one")
                let bad = fileURL.appendingPathExtension("bad")
                try? fm.removeItem(at: bad)
                try? fm.moveItem(at: fileURL, to: bad)
                book = HighScoreBook()
            }
        } else {
            book = HighScoreBook()
        }
    }

    func entries(table: Int) -> [HighScoreEntry] { book.entries(table: table) }
    func qualifies(_ score: UInt32, table: Int) -> Bool { book.rank(for: score, table: table) != nil }

    @discardableResult
    func add(_ e: HighScoreEntry, table: Int) -> Int? {
        let r = book.insert(e, table: table)
        if r != nil { save() }
        return r
    }

    func clear(table: Int) {
        book.tables[String(table)] = nil
        save()
    }

    private func save() {
        do { try AppPaths.write(book, to: fileURL) } catch { warn("cannot save high scores to \(fileURL.path): \(error)") }
    }
}

/// Initials entry in the original's style: three letters picked one at a time (flippers or
/// Up/Down step through the alphabet, plunger/Space/Return takes the letter). Typing a letter
/// sets it and moves on; Delete steps back.
struct InitialsEntry: Equatable, Sendable {
    static let alphabet: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789. ")

    var letters: [Character] = ["A", "A", "A"]
    var position = 0
    var done: Bool { position >= HighScoreBook.initialsLength }
    var text: String { String(letters) }

    init(start: String? = nil) {
        if let s = start {
            let n = HighScoreBook.normalise(s)
            if n.trimmingCharacters(in: .whitespaces).count > 0 { letters = Array(n) }
        }
    }

    mutating func step(_ delta: Int) {
        guard !done else { return }
        let a = Self.alphabet
        let i = a.firstIndex(of: letters[position]) ?? 0
        letters[position] = a[((i + delta) % a.count + a.count) % a.count]
    }

    mutating func accept() { if !done { position += 1 } }

    mutating func back() { if position > 0 { position -= 1 } }

    mutating func type(_ ch: Character) {
        guard !done else { return }
        let u = Character(ch.uppercased())
        guard Self.alphabet.contains(u) else { return }
        letters[position] = u
        position += 1
    }
}
