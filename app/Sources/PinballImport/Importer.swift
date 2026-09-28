// GameDataImporting in pure Swift: finds the game in the user's source, copies the original
// files the engine reads at runtime, runs the extraction pipeline for every table (in
// parallel) and writes the library (docs/enhanced/import.md).
import Foundation

public struct ImportOptions: Sendable {
    public enum Rules: Sendable, Equatable {
        /// Do not provide rules.json (the app runs the rules directly from the EXE once that
        /// track lands; until then such a table plays physics only).
        case none
        /// Copy `<dir>/tables/EPn/rules.json` (a tools/rules.py output directory) when present.
        case copy(from: URL)
        /// `copy` from the developer checkout's extracted/ directory if it exists, else `none`.
        case automatic
    }
    public var rules: Rules = .automatic
    /// Import only these tables (default: every table the source has).
    public var tables: [Int]? = nil
    /// Tables processed in parallel.
    public var concurrency: Int = max(1, ProcessInfo.processInfo.activeProcessorCount)
    public init(rules: Rules = .automatic, tables: [Int]? = nil) { self.rules = rules; self.tables = tables }
}

/// Paths inside an imported library (the layout is documented in docs/enhanced/import.md).
/// The root is laid out like the developer `extracted/` directory (`tables/EPn/...`) plus
/// `original/` and `library.json`, so it can be passed straight to `--data`.
public enum LibraryLayout {
    public static let format = "epic-pinball-library/1"
    public static let importerVersion = 1
    /// What the app's `--data` / DataLocator should point at: the root itself (it contains `tables/`,
    /// laid out like the developer `extracted/` directory).
    public static func dataRoot(_ root: URL) -> URL { root }
    /// Copies of the user's EPn.EXE / SFXn.PIN / SONGn.PSM / EPn.DAT / IDn.DAT: `<root>/original`
    /// (where the front end's GameLibrary.findOriginal looks first; pass it as `--original`).
    public static func originalDirectory(_ root: URL) -> URL { root.appendingPathComponent("original", isDirectory: true) }
    public static func tableDirectory(_ root: URL, table n: Int) -> URL { root.appendingPathComponent("tables/EP\(n)", isDirectory: true) }
    /// The items of a root the importer writes (and replaces on re-import); anything else is left alone.
    public static let ownedItems = ["tables", "original", "library.json"]
    public static func manifestURL(_ root: URL) -> URL { root.appendingPathComponent("library.json") }
    /// Files every imported table directory has (what the app loads).
    public static let requiredTableFiles = ["playfield_idx.npy", "palette.json", "collision_idx.npy", "collision.json", "engine.json",
                                            "sprites/sprites.json", "preview.png"]

    /// Reads library.json back into an `ImportedLibrary` (nil if there is no complete library).
    public static func load(_ root: URL) -> ImportedLibrary? {
        guard let d = try? Data(contentsOf: manifestURL(root)), let j = try? parseJSON(d), j["format"]?.stringValue == format else { return nil }
        var tables: [ImportedTable] = []
        for t in j["tables"]?.arrayValue ?? [] {
            guard let n = t["number"]?.intValue, let name = t["name"]?.stringValue else { continue }
            let dir = tableDirectory(root, table: n)
            guard requiredTableFiles.allSatisfy({ FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }) else { return nil }
            tables.append(ImportedTable(number: n, name: name, dataDirectory: dir))
        }
        return ImportedLibrary(root: root, tables: tables, warnings: (j["warnings"]?.arrayValue ?? []).compactMap(\.stringValue))
    }
}

extension ImportSource {
    /// `.isoImage` for disc-image files, `.directory` otherwise.
    public static func detect(_ url: URL) -> ImportSource {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue { return .isoImage(url) }
        return .directory(url)
    }
    var url: URL { switch self { case let .isoImage(u), let .directory(u): return u } }
}

public struct GameDataImporter: GameDataImporting {
    public var options: ImportOptions
    public init(options: ImportOptions = ImportOptions()) { self.options = options }

    /// The developer checkout's extracted/ (tools/*.py outputs), if present.
    public static var developmentExtracted: URL? {
        let u = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("extracted", isDirectory: true)
        return FileManager.default.fileExists(atPath: u.appendingPathComponent("tables").path) ? u : nil
    }

    /// Where the game is in `source` and what it contains.
    public func scan(_ source: ImportSource) throws -> SourceScan { try SourceScanner.open(source).1 }

    public func validate(_ source: ImportSource) throws -> [String] {
        let (files, scan) = try SourceScanner.open(source)
        guard !scan.tables.isEmpty else { throw ImportError("no importable table (each needs EPn.EXE and EPn.DAT)") }
        var warnings = ["found: \(scan.layout); tables \(scan.tables.map(String.init).joined(separator: ", "))"] + scan.warnings
        for n in scan.tables {
            do {
                let exe = try MZImage(name: "EP\(n).EXE", data: [UInt8](try files.read(SourceScanner.join(scan.gameFolder, "EP\(n).EXE"))))
                _ = try exe.playfieldSegments()
                _ = try exe.dataSegment()
            } catch {
                warnings.append("table \(n): EP\(n).EXE is not a table executable this importer understands (\(error))")
            }
        }
        return warnings
    }

    public func importGame(from source: ImportSource, to destination: URL,
                           progress: @Sendable (ImportProgress) -> Void) throws -> ImportedLibrary {
        let started = CFAbsoluteTimeGetCurrent()
        progress(ImportProgress(fraction: 0, message: "Reading \(source.url.lastPathComponent)"))
        let (files, scan) = try SourceScanner.open(source)
        var tables = scan.tables
        if let only = options.tables { tables = tables.filter { only.contains($0) } }
        guard !tables.isEmpty else { throw ImportError("no importable table in \(source.url.path) (each needs EPn.EXE and EPn.DAT)") }
        var warnings = scan.warnings

        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let stagingOriginal = LibraryLayout.originalDirectory(staging)
        let stagingData = staging
        try fm.createDirectory(at: stagingOriginal, withIntermediateDirectories: true)
        try fm.createDirectory(at: stagingData.appendingPathComponent("tables", isDirectory: true), withIntermediateDirectories: true)

        // 1. copy the original files the engine reads at runtime
        var copy: [String] = []
        for n in tables { copy += ["EP\(n).EXE", "EP\(n).DAT", "ID\(n).DAT", "SFX\(n).PIN", "SONG\(n).PSM"] }
        copy += ["SFX0.PIN", "SONG0.PSM"]
        copy = copy.filter { files.has(SourceScanner.join(scan.gameFolder, $0)) }
        var tableFiles: [Int: TableFiles] = [:]
        var bytes: [String: [UInt8]] = [:]
        for (i, name) in copy.enumerated() {
            progress(ImportProgress(fraction: 0.02 + 0.13 * Double(i) / Double(copy.count), message: "Copying \(name)"))
            let d = try files.read(SourceScanner.join(scan.gameFolder, name))
            try d.writeAtomically(to: stagingOriginal.appendingPathComponent(name))
            if name.hasPrefix("EP") || name.hasPrefix("ID") { bytes[name] = [UInt8](d) }
        }
        for n in tables {
            tableFiles[n] = TableFiles(exe: bytes["EP\(n).EXE"]!, dat: bytes["EP\(n).DAT"]!, id: bytes["ID\(n).DAT"])
        }

        // 2. the extraction pipeline, tables in parallel
        let rulesDir: URL? = {
            switch options.rules {
            case .none: return nil
            case let .copy(u): return u
            case .automatic: return GameDataImporter.developmentExtracted
            }
        }()
        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var done = 0
            var next = 0
            var results: [Int: TableRecord] = [:]
            var errors: [Int: String] = [:]
        }
        let col = Collector()
        let total = tables.count
        let tf = tableFiles
        let work = tables
        progress(ImportProgress(fraction: 0.15, message: "Extracting \(total) tables"))
        let workers = max(1, min(options.concurrency, total))
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while true {
                col.lock.lock()
                let k = col.next
                col.next += 1
                col.lock.unlock()
                guard k < total else { return }
                let n = work[k]
                let t0 = CFAbsoluteTimeGetCurrent()
                do {
                    let out = try TablePipeline.run(table: n, files: tf[n]!)
                    let dir = stagingData.appendingPathComponent("tables/EP\(n)", isDirectory: true)
                    try TablePipeline.write(out, to: dir)
                    var rules = "direct-exe"
                    if let rd = rulesDir {
                        let src = rd.appendingPathComponent("tables/EP\(n)/rules.json")
                        if FileManager.default.fileExists(atPath: src.path) {
                            try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent("rules.json"))
                            rules = "rules.json"
                        }
                    }
                    let rec = TableRecord(outputs: out, rules: rules, seconds: CFAbsoluteTimeGetCurrent() - t0)
                    col.lock.lock(); col.results[n] = rec; col.done += 1; let d = col.done; col.lock.unlock()
                    progress(ImportProgress(fraction: 0.15 + 0.8 * Double(d) / Double(total), message: "Table \(n): \(out.name)"))
                } catch {
                    col.lock.lock(); col.errors[n] = String(describing: error); col.done += 1; let d = col.done; col.lock.unlock()
                    progress(ImportProgress(fraction: 0.15 + 0.8 * Double(d) / Double(total), message: "Table \(n) failed"))
                }
            }
        }
        for (n, e) in col.errors.sorted(by: { $0.key < $1.key }) { warnings.append("table \(n) was not imported: \(e)") }
        let done = tables.filter { col.results[$0] != nil }
        guard !done.isEmpty else { throw ImportError("no table could be imported:\n" + warnings.joined(separator: "\n")) }
        for n in done where col.results[n]!.rules == "direct-exe" {
            warnings.append("table \(n): no rules.json available; the rules have to run directly from EP\(n).EXE")
        }

        // 3. manifests
        progress(ImportProgress(fraction: 0.96, message: "Writing the library"))
        let manifest = JSONValue.array(done.map { col.results[$0]!.outputs.playfield.manifest })
        try Data(serialize(manifest, style: .indent(2)).utf8).writeAtomically(to: stagingData.appendingPathComponent("tables/manifest.json"))
        let lib = libraryJSON(source: source, scan: scan, tables: done.map { col.results[$0]! }, copied: copy, warnings: warnings,
                              seconds: CFAbsoluteTimeGetCurrent() - started)
        try Data(serialize(lib, style: .indent(1)).utf8).writeAtomically(to: LibraryLayout.manifestURL(staging))

        // 4. swap the importer-owned items into place (other items in the root are left alone)
        for item in LibraryLayout.ownedItems {
            let dst = destination.appendingPathComponent(item)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: staging.appendingPathComponent(item), to: dst)
        }
        progress(ImportProgress(fraction: 1, message: "Imported \(done.count) tables"))
        return ImportedLibrary(root: destination,
                               tables: done.map { ImportedTable(number: $0, name: col.results[$0]!.outputs.name,
                                                                dataDirectory: LibraryLayout.tableDirectory(destination, table: $0)) },
                               warnings: warnings)
    }

    struct TableRecord {
        var outputs: TableOutputs
        var rules: String
        var seconds: Double
    }

    func libraryJSON(source: ImportSource, scan: SourceScan, tables: [TableRecord], copied: [String], warnings: [String], seconds: Double) -> JSONValue {
        let iso = ISO8601DateFormatter()
        var src: [(String, JSONValue)] = [
            ("kind", .string({ if case .isoImage = source { return "iso" } else { return "directory" } }())),
            ("path", .string(source.url.path)), ("layout", .string(scan.layout)), ("detected", .string(scan.kind)),
            ("game_folder", .string(scan.gameFolder)),
        ]
        if let d = scan.discImage { src.append(("disc_image", .string(d))) }
        if let v = scan.volumeIdentifier { src.append(("volume_id", .string(v))) }
        let tjs: [JSONValue] = tables.map { r in
            let o = r.outputs, n = o.number
            let orig = ["EP\(n).EXE", "EP\(n).DAT", "ID\(n).DAT", "SFX\(n).PIN", "SONG\(n).PSM"].filter { copied.contains($0) }
            return .obj([
                ("number", .int(n)), ("name", .string(o.name)),
                ("directory", .string("tables/EP\(n)")),
                ("exe_sha1", o.engine["source"]?["sha1"] ?? .null),
                ("original_files", .strings(orig.map { "original/" + $0 })),
                ("sound", .bool(orig.contains("SFX\(n).PIN") && orig.contains("SONG\(n).PSM"))),
                ("rules", .string(r.rules)),
                ("palette_method", o.playfield.manifest["palette_method"] ?? .null),
                ("engine_fallbacks", o.engine["fallbacks"] ?? .array([])),
                ("engine_overrides", .bool(o.engine["overrides"] != nil)),
                ("discover", o.discoverError.map { .string("failed: \($0)") } ?? .string("ok")),
                ("seconds", .double(pyRound(r.seconds, 3))),
            ])
        }
        return .obj([
            ("format", .string(LibraryLayout.format)),
            ("importer_version", .int(LibraryLayout.importerVersion)),
            ("created", .string(iso.string(from: Date()))),
            ("source", .obj(src)),
            ("data_root", .string(".")),
            ("original_root", .string("original")),
            ("tables", .array(tjs)),
            ("missing_tables", .ints(scan.missingTables)),
            ("extra_files", .strings(scan.extraFiles)),
            ("launcher_sound", .bool(copied.contains("SFX0.PIN") && copied.contains("SONG0.PSM"))),
            ("warnings", .strings(warnings)),
            ("import_seconds", .double(pyRound(seconds, 3))),
            ("note", .string("Everything in tables/ and original/ is derived from or copied from the user's own files; nothing here may be redistributed. Formats: docs/enhanced/import.md.")),
        ])
    }
}
