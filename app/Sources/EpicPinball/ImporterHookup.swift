import Foundation
import PinballCore
import PinballImport

/// The one place the front end chooses a `GameDataImporting` implementation: the PinballImport
/// track's pure-Swift importer (CD image or game folder -> the per-user library). Developer
/// folders that already contain `tables/EPn/` (an `extracted/` directory made by the Python
/// tools) are handled by `ExtractedFolderImporter` instead.
///
/// No rules.json is imported (`rules: .none`): the default rules backend runs the table rules
/// straight from the copied EPn.EXE, so a library is the same on every Mac (the importer's
/// `.automatic` would copy a developer checkout's lifted rules when one exists).
func libraryImporter() -> any GameDataImporting {
    GameDataImporter(options: ImportOptions(rules: .none))
}

func makeImporter(for source: ImportSource) -> any GameDataImporting {
    if case let .directory(u) = source, GameLibrary.hasTables(u) { return ExtractedFolderImporter() }
    return libraryImporter()
}

/// Developer import: copies an existing runtime-data directory (`tables/EPn/...`, as written by
/// tools/extract.py and friends) plus the original files next to it (`original/`, or the
/// directory itself) into the library. Everything copied is the user's own data.
struct ExtractedFolderImporter: GameDataImporting {
    enum Failure: Error, CustomStringConvertible {
        case noTables(URL)
        var description: String {
            switch self { case let .noTables(u): return "\(u.path) has no tables/EPn/ runtime data" }
        }
    }

    func validate(_ source: ImportSource) throws -> [String] {
        guard case let .directory(u) = source, GameLibrary.hasTables(u) else { throw Failure.noTables(source.url) }
        return GameLibrary.findOriginal(near: u, explicit: nil) == nil
            ? ["no original EPn.EXE found next to it: no fonts, messages or sound"] : []
    }

    func importGame(from source: ImportSource, to destination: URL,
                    progress: @Sendable (ImportProgress) -> Void) throws -> ImportedLibrary {
        guard case let .directory(src) = source, GameLibrary.hasTables(src) else { throw Failure.noTables(source.url) }
        let fm = FileManager.default
        var warnings: [String] = []
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let tablesOut = staging.appendingPathComponent("tables", isDirectory: true)
        try fm.createDirectory(at: tablesOut, withIntermediateDirectories: true)
        var imported: [ImportedTable] = []
        let original = GameLibrary.findOriginal(near: src, explicit: nil)
        let steps = Double(TableGeometry.tableCount + (original == nil ? 0 : 1))
        for n in 1...TableGeometry.tableCount {
            progress(ImportProgress(fraction: Double(n - 1) / steps, message: "Table \(n)…"))
            let from = src.appendingPathComponent("tables/EP\(n)", isDirectory: true)
            guard TableCatalog.tableFilesPresent(root: src, table: n) else { warnings.append("table \(n): no runtime data"); continue }
            let to = tablesOut.appendingPathComponent("EP\(n)", isDirectory: true)
            try fm.copyItem(at: from, to: to)
            var name = "Table \(n)"
            if let o = original, let d = try? Data(contentsOf: o.appendingPathComponent("ID\(n).DAT")), let s = TableCatalog.tableName(d) { name = s }
            imported.append(ImportedTable(number: n, name: name, dataDirectory: destination.appendingPathComponent("tables/EP\(n)")))
        }
        for extra in ["music", "sfx"] {
            let f = src.appendingPathComponent(extra)
            if fm.fileExists(atPath: f.path) { try fm.copyItem(at: f, to: staging.appendingPathComponent(extra)) }
        }
        if let o = original {
            progress(ImportProgress(fraction: (steps - 1) / steps, message: "Original files…"))
            let out = staging.appendingPathComponent("original", isDirectory: true)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: o.path) {
                let u = o.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                try fm.copyItem(at: u, to: out.appendingPathComponent(name))
            }
        } else {
            warnings.append("no original EPn.EXE found: no fonts, messages or sound")
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: staging, to: destination)
        progress(ImportProgress(fraction: 1, message: "Done"))
        return ImportedLibrary(root: destination, tables: imported, warnings: warnings)
    }
}
