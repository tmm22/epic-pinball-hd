import AppKit
import Foundation
import Observation
import PinballCore
import PinballImport
import PinballRender

/// Front-end state shared by the launcher, settings, import screen and the running game.
@MainActor
@Observable
final class AppModel {
    enum Screen: Equatable { case importer, picker, game }

    enum ImportState: Equatable {
        case idle
        case running(fraction: Double, message: String)
        case failed(String)
        case finished(tables: Int, warnings: [String])
    }

    var screen: Screen = .picker
    var library: GameLibrary?
    var tables: [TableInfo] = []
    var selected = 1
    var importState: ImportState = .idle
    var showSettings = false
    /// Bumped when the high-score book changes (the picker re-reads it).
    var scoresVersion = 0
    /// Connected controllers (Settings > Controls).
    var controllers: [String] = []
    /// Non-fatal problem to show in the picker (e.g. a table failed to load).
    var notice: String?
    /// The running table's HD pack state (Settings > Display); nil outside a game.
    var hdPackStatus: String?

    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let scores: HighScoreStore
    @ObservationIgnored let stats: StatsStore
    @ObservationIgnored var explicitOriginal: String?
    /// Set by the app delegate.
    @ObservationIgnored var onPlay: ((Int) -> Void)?
    @ObservationIgnored var onQuit: (() -> Void)?
    @ObservationIgnored var onImportFinished: (() -> Void)?
    /// Practice game / watch a replay (set by the app delegate; Replays.swift).
    @ObservationIgnored var onPractice: ((Int) -> Void)?
    @ObservationIgnored var onWatch: ((URL) -> Void)?
    @ObservationIgnored let replays = ReplayLibrary()

    init(settings: SettingsStore, scores: HighScoreStore, stats: StatsStore? = nil) {
        self.settings = settings
        self.scores = scores
        self.stats = stats ?? StatsStore()
        selected = settings.frontEnd.lastTable
    }

    var selectedTable: TableInfo? { tables.first { $0.number == selected } }

    func reloadTables() {
        guard let lib = library else { tables = []; return }
        tables = TableCatalog.load(lib)
        if selectedTable?.available != true, let first = tables.first(where: \.available) { selected = first.number }
    }

    func select(_ n: Int) {
        guard (1...TableGeometry.tableCount).contains(n) else { return }
        selected = n
    }

    /// Arrow-key / D-pad movement in the grid (`columns` wide).
    func move(dx: Int, dy: Int, columns: Int) {
        let n = selected - 1 + dx + dy * columns
        if (0..<TableGeometry.tableCount).contains(n) { selected = n + 1 }
    }

    func play() {
        guard let t = selectedTable, t.available else { NSSound.beep(); return }
        settings.frontEnd.lastTable = t.number
        onPlay?(t.number)
    }

    func practice() {
        guard let t = selectedTable, t.available else { NSSound.beep(); return }
        settings.frontEnd.lastTable = t.number
        onPractice?(t.number)
    }

    /// The launcher's view of the Replays directory for one table, read once per `scoresVersion`
    /// (the game bumps it when it writes a replay) instead of on every body evaluation.
    private struct ReplayListing {
        var version: Int, table: Int
        var names: Set<String>
        var saved: [ReplayInfo]
    }
    @ObservationIgnored private var replayListing: ReplayListing?

    private func listing(_ table: Int) -> ReplayListing {
        let v = scoresVersion   // observed: a change re-renders and re-reads
        if let l = replayListing, l.version == v, l.table == table { return l }
        let l = ReplayListing(version: v, table: table, names: replays.names(), saved: replays.saved(table: table))
        replayListing = l
        return l
    }

    /// The table's last finished game, if its replay is there.
    func lastReplay(_ table: Int) -> URL? {
        let n = ReplayLibrary.lastName(table: table)
        return listing(table).names.contains(n) ? replays.url(n) : nil
    }

    func savedReplays(_ table: Int) -> [ReplayInfo] { listing(table).saved }

    /// The replay a high-score entry links to, if the file is still there.
    func replayURL(_ e: HighScoreEntry) -> URL? {
        guard let n = e.replay, listing(selected).names.contains(n) else { return nil }
        return replays.url(n)
    }

    /// Settings > Clear this table's scores: the entries and the high-score replays they linked to.
    func clearScores(table: Int) {
        scores.clear(table: table)
        replays.prune(table: table, referenced: [])
        scoresVersion += 1
    }

    func watch(_ url: URL) { onWatch?(url) }

    func highScores(_ table: Int) -> [HighScoreEntry] {
        _ = scoresVersion
        return scores.entries(table: table)
    }

    /// The table's statistics by physics mode (re-read when `scoresVersion` changes).
    func tableStats(_ table: Int) -> [String: TableStats] {
        _ = scoresVersion
        return stats.stats(table: table)
    }

    // MARK: import

    /// Runs the importer off the main thread into the per-user library, then opens the picker.
    func runImport(from source: ImportSource) {
        if case .running = importState { return }
        importState = .running(fraction: 0, message: "Checking \(source.url.lastPathComponent)…")
        let destination = AppPaths.libraryRoot
        let importer = makeImporter(for: source)
        let model = self
        Task.detached(priority: .userInitiated) {
            let result: Result<ImportedLibrary, Error>
            do {
                let warnings = try importer.validate(source)
                if !warnings.isEmpty {
                    let text = warnings.joined(separator: "; ")
                    await MainActor.run { model.importState = .running(fraction: 0, message: text) }
                }
                let lib = try importer.importGame(from: source, to: destination) { p in
                    Task { @MainActor in
                        if case .running = model.importState { model.importState = .running(fraction: p.fraction, message: p.message) }
                    }
                }
                result = .success(lib)
            } catch {
                result = .failure(error)
            }
            await MainActor.run { model.importDone(result) }
        }
    }

    private func importDone(_ r: Result<ImportedLibrary, Error>) {
        switch r {
        case let .failure(e):
            importState = .failed(String(describing: e))
        case let .success(lib):
            library = GameLibrary(dataRoot: lib.root, originalDir: GameLibrary.findOriginal(near: lib.root, explicit: explicitOriginal),
                                  origin: .library)
            reloadTables()
            importState = .finished(tables: lib.tables.count, warnings: lib.warnings)
            onImportFinished?()
            // Warnings stay visible in the picker too.
            notice = lib.warnings.isEmpty ? nil : "Imported \(lib.tables.count) tables. " + lib.warnings.prefix(3).joined(separator: "; ")
            // The import-done screen offers HD pack generation (ImportView); `--import-hd-packs`
            // answers it for smoke tests. Without tables there is nothing to offer.
            if tables.contains(where: \.available) {
                screen = .importer
                if let answer = importHDPacksAnswer { finishImport(makeHDPacks: answer > 0, scale: max(answer, 1)) }
            } else {
                screen = .picker
            }
        }
    }

    /// `--import-hd-packs S|skip`: the answer to the import-done screen's HD pack offer (S = scale,
    /// 0 = skip); nil = ask (the window waits for a click).
    @ObservationIgnored var importHDPacksAnswer: Int?

    /// The import-done screen's buttons: on to the picker, optionally making HD packs of every
    /// imported table at `scale` in the background first (progress in the picker, Cancel there and
    /// in Settings > Library). Packs made this way also switch Display > Use HD art pack on.
    func finishImport(makeHDPacks: Bool, scale: Int = HDPackGeneration.defaultScale) {
        if makeHDPacks {
            let all = tables.filter(\.available).map(\.number)
            if !all.isEmpty { generateHDPacks(tables: all, scale: scale, useWhenDone: true) }
        }
        screen = .picker
    }

    // MARK: HD packs (Settings > Library)

    enum HDPackState: Equatable {
        case idle
        case running(fraction: Double, message: String)
        case finished(String)
        case failed(String)
    }

    var hdPackState: HDPackState = .idle
    /// Bumped when packs were written (the Library tab re-reads what is installed).
    var hdPacksVersion = 0
    @ObservationIgnored private var hdPackCancel: CancelFlag?
    /// Called on the main actor when a generation job ends (smoke tests print it).
    @ObservationIgnored var onHDPacksFinished: ((HDPackState) -> Void)?
    /// Progress reports received from the current/last job (tests: several can land in one run-loop turn).
    @ObservationIgnored private(set) var hdPackProgressReports = 0

    var hdPackRunning: Bool { if case .running = hdPackState { return true }; return false }

    /// Generates HD packs for `tables` from the library off the main thread into
    /// `AppPaths.hdPacksRoot` (HDPackGeneration / PinballImport.HDPackMaker).
    /// `useWhenDone`: switch Display > Use HD art pack on once at least one pack was made (the
    /// import-done offer; Settings > Library leaves the setting to the user).
    func generateHDPacks(tables: [Int], scale: Int, useWhenDone: Bool = false) {
        guard !hdPackRunning else { return }
        guard let dataRoot = library?.dataRoot else { hdPackState = .failed("No game data: import your game first."); return }
        let flag = CancelFlag()
        hdPackCancel = flag
        hdPackState = .running(fraction: 0, message: "Starting…")
        hdPackProgressReports = 0
        let outputRoot = AppPaths.hdPacksRoot
        let model = self
        Task.detached(priority: .userInitiated) {
            let started = Date()
            let state: HDPackState
            var made = 0
            do {
                let r = try HDPackGeneration.run(tables: tables, dataRoot: dataRoot, outputRoot: outputRoot, scale: scale, progress: { f, m in
                    Task { @MainActor in
                        if model.hdPackRunning { model.hdPackState = .running(fraction: f, message: m); if f > 0 { model.hdPackProgressReports += 1 } }
                    }
                }, isCancelled: { flag.isCancelled })
                let secs = String(format: "%.1f s", Date().timeIntervalSince(started))
                made = r.done.count
                var text = r.done.isEmpty ? "No pack made" : "Made \(r.done.count) \(scale)x pack\(r.done.count == 1 ? "" : "s") in \(secs)"
                if useWhenDone, made > 0 { text += "; Display > Use HD art pack is on" }
                state = r.warnings.isEmpty ? .finished(text + ".") : .finished(text + ". " + r.warnings.prefix(3).joined(separator: "; "))
            } catch is CancellationError {
                state = .finished("Cancelled; packs made before that are kept.")
            } catch {
                state = .failed(String(describing: error))
            }
            let madeCount = made
            await MainActor.run {
                model.hdPackState = state
                model.hdPackCancel = nil
                model.hdPacksVersion += 1
                HDPack.packsChanged()
                if useWhenDone, madeCount > 0 { model.settings.game.useHDPack = true }
                model.onHDPacksFinished?(state)
            }
        }
    }

    func cancelHDPacks() { hdPackCancel?.cancel() }

    func openImportPanel(directories: Bool) {
        let panel = NSOpenPanel()
        panel.title = directories ? "Choose your Epic Pinball folder" : "Choose your Epic Pinball CD image"
        panel.message = directories
            ? "Choose the folder that contains EP1.EXE … (a DOS install, a mounted CD or a GOG game folder)."
            : "Choose the ISO image of your Epic Pinball CD."
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = false
        if !directories { panel.allowedContentTypes = [.init(filenameExtension: "iso") ?? .data, .data] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runImport(from: directories ? .directory(url) : .isoImage(url))
    }
}

extension ImportSource {
    var url: URL {
        switch self {
        case let .isoImage(u): return u
        case let .directory(u): return u
        }
    }
}
