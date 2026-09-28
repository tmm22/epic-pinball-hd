import AppKit
import Foundation
import Observation
import PinballCore
import PinballImport

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

    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let scores: HighScoreStore
    @ObservationIgnored var explicitOriginal: String?
    /// Set by the app delegate.
    @ObservationIgnored var onPlay: ((Int) -> Void)?
    @ObservationIgnored var onQuit: (() -> Void)?
    @ObservationIgnored var onImportFinished: (() -> Void)?

    init(settings: SettingsStore, scores: HighScoreStore) {
        self.settings = settings
        self.scores = scores
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

    func highScores(_ table: Int) -> [HighScoreEntry] {
        _ = scoresVersion
        return scores.entries(table: table)
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
            // Straight to the picker; warnings stay visible there.
            notice = lib.warnings.isEmpty ? nil : "Imported \(lib.tables.count) tables. " + lib.warnings.prefix(3).joined(separator: "; ")
            screen = .picker
        }
    }

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
