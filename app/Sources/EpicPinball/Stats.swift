import Foundation
import PinballCore

/// Play statistics of one table in one physics mode.
struct TableStats: Codable, Equatable, Sendable {
    /// Games that reached game over, plus games left early with a score (`abandoned` of them).
    var games = 0
    var abandoned = 0
    /// Balls served: distinct (player, round) pairs the rules reported during the games.
    var balls = 0
    /// Sum and count of the players' final scores (a 2-player game adds 2 scores).
    var totalScore: UInt64 = 0
    var scores = 0
    var bestScore: UInt32 = 0
    /// Simulated time of the table's original frames while a game ran (pauses and menus excluded).
    var playSeconds = 0.0

    init() {}

    var averageScore: UInt32? { scores > 0 ? UInt32(min(totalScore / UInt64(scores), UInt64(UInt32.max))) : nil }
    var isEmpty: Bool { games == 0 && balls == 0 && playSeconds == 0 }

    enum CodingKeys: String, CodingKey { case games, abandoned, balls, totalScore, scores, bestScore, playSeconds }

    /// Lenient like the settings: a missing or mistyped field keeps its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        games = max(0, get(.games, 0)); abandoned = max(0, get(.abandoned, 0)); balls = max(0, get(.balls, 0))
        totalScore = get(.totalScore, 0); scores = max(0, get(.scores, 0)); bestScore = get(.bestScore, 0)
        playSeconds = max(0, get(.playSeconds, 0.0))
    }

    static func + (a: TableStats, b: TableStats) -> TableStats {
        var s = a
        s.games += b.games; s.abandoned += b.abandoned; s.balls += b.balls
        s.totalScore &+= b.totalScore; s.scores += b.scores; s.bestScore = max(a.bestScore, b.bestScore)
        s.playSeconds += b.playSeconds
        return s
    }
}

/// One game as `GameStatsTracker` saw it, ready to be added to the book.
struct FinishedGame: Equatable, Sendable {
    /// Physics mode at the end of the game (as the high-score entry records it).
    var physics: String
    var scores: [UInt32]
    var balls: Int
    /// Play time by physics mode (a game can switch modes with the E key).
    var seconds: [String: Double]
    /// False: left before game over (new game, table change, quit). Counted only with a score.
    var completed: Bool
    var counts: Bool { completed || scores.contains { $0 > 0 } }
}

/// `stats.json`: `{"version": 1, "tables": {"1": {"classic": TableStats, "enhanced": ...}}}`.
struct StatsBook: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    var tables: [String: [String: TableStats]] = [:]

    func stats(table: Int) -> [String: TableStats] { tables[String(table)] ?? [:] }
    func stats(table: Int, physics: String) -> TableStats { stats(table: table)[physics] ?? TableStats() }

    mutating func record(_ g: FinishedGame, table: Int) {
        var t = stats(table: table)
        for (mode, s) in g.seconds where s > 0 { t[mode, default: TableStats()].playSeconds += s }
        if g.counts {
            var s = t[g.physics] ?? TableStats()
            s.games += 1
            if !g.completed { s.abandoned += 1 }
            s.balls += g.balls
            for v in g.scores {
                s.totalScore &+= UInt64(v)
                s.scores += 1
                s.bestScore = max(s.bestScore, v)
            }
            t[g.physics] = s
        }
        if !t.isEmpty { tables[String(table)] = t }
    }
}

/// Follows the rules' per-frame `PresentationState` and reports each game when it ends.
struct GameStatsTracker: Sendable {
    private(set) var active = false
    private var balls = Set<Int>()
    private var scores: [UInt32] = []
    private var seconds: [String: Double] = [:]
    /// Rounds above this are not balls (the round counter passes the last ball as the game ends).
    var ballsPerGame = 9

    /// One original frame of a running game. Returns the game when this frame ended it.
    mutating func frame(_ st: PresentationState, physics: String, frameSeconds: Double) -> FinishedGame? {
        let n = max(1, min(st.playerCount, st.scores.count))
        if st.gameOver {
            guard active else { return nil }
            scores = Array(st.scores.prefix(n))
            return finish(physics: physics, completed: true)
        }
        active = true
        if (1...max(1, ballsPerGame)).contains(st.ballNumber) { balls.insert(st.currentPlayer * 1000 + st.ballNumber) }
        scores = Array(st.scores.prefix(n))
        seconds[physics, default: 0] += frameSeconds
        return nil
    }

    /// The game is left before game over; nil when no game was running.
    mutating func abandon(physics: String) -> FinishedGame? {
        guard active else { return nil }
        return finish(physics: physics, completed: false)
    }

    private mutating func finish(physics: String, completed: Bool) -> FinishedGame {
        let g = FinishedGame(physics: physics, scores: scores, balls: balls.count, seconds: seconds, completed: completed)
        self = GameStatsTracker(ballsPerGame: ballsPerGame)
        return g
    }

    init(ballsPerGame: Int = 9) { self.ballsPerGame = ballsPerGame }
}

/// Loads and saves the book; a damaged file is kept aside (`stats.json.bad`), as with the high scores.
@MainActor
final class StatsStore {
    let fileURL: URL
    private(set) var book: StatsBook

    init(fileURL: URL = AppPaths.statsFile) {
        self.fileURL = fileURL
        if let d = try? Data(contentsOf: fileURL) {
            if let b = try? JSONDecoder().decode(StatsBook.self, from: d) {
                book = b
            } else {
                warn("statistics file \(fileURL.path) is damaged; kept as .bad, starting a new one")
                let bad = fileURL.appendingPathExtension("bad")
                try? FileManager.default.removeItem(at: bad)
                try? FileManager.default.moveItem(at: fileURL, to: bad)
                book = StatsBook()
            }
        } else {
            book = StatsBook()
        }
    }

    func stats(table: Int) -> [String: TableStats] { book.stats(table: table) }

    func record(_ g: FinishedGame, table: Int) {
        let before = book
        book.record(g, table: table)
        if book != before { save() }
    }

    func clear(table: Int) {
        guard book.tables[String(table)] != nil else { return }
        book.tables[String(table)] = nil
        save()
    }

    func clearAll() {
        guard !book.tables.isEmpty else { return }
        book.tables = [:]
        save()
    }

    private func save() {
        do { try AppPaths.write(book, to: fileURL) } catch { warn("cannot save statistics to \(fileURL.path): \(error)") }
    }
}

/// "1 h 05 min", "12 min", "45 s".
func formatPlayTime(_ s: Double) -> String {
    let t = Int(s.rounded())
    if t >= 3600 { return String(format: "%d h %02d min", t / 3600, (t % 3600) / 60) }
    if t >= 60 { return "\(t / 60) min" }
    return "\(t) s"
}
