import Foundation
import XCTest
@testable import PinballImport

final class ProgressLog: @unchecked Sendable {
    let lock = NSLock()
    var items: [ImportProgress] = []
    func add(_ p: ImportProgress) { lock.lock(); items.append(p); lock.unlock() }
}

func tempDir(_ tag: String) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("ep-import-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// Same pixels (after the app's PNG decode) in two PNG files.
func samePixels(_ a: URL, _ b: URL) -> Bool {
    guard let x = PNGFile.read(a), let y = PNGFile.read(b) else { return false }
    return x.w == y.w && x.h == y.h && x.rgba == y.rgba
}

func isStale(_ a: URL, comparedTo b: URL) -> Bool {
    let d = { (u: URL) in (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? .distantPast }
    return d(a) < d(b)
}

/// Our ball.png against the reference palette.json applied to the reference engine.json ball indices.
func ballMatchesReferencePalette(_ png: URL, _ refTable: URL) -> Bool {
    guard let mine = PNGFile.read(png),
          let eng = try? parseJSON(Data(contentsOf: refTable.appendingPathComponent("engine.json"))),
          let pal = try? parseJSON(Data(contentsOf: refTable.appendingPathComponent("palette.json"))),
          let px = eng["ball"]?["pixels"]?.arrayValue, let w = eng["ball"]?["w"]?.intValue, let h = eng["ball"]?["h"]?.intValue,
          mine.w == w, mine.h == h, px.count == w * h else { return false }
    for i in 0..<(w * h) {
        guard let rgb = pal[px[i].intValue!]?.arrayValue else { return false }
        for c in 0..<3 where mine.rgba[i * 4 + c] != UInt8(rgb[c].intValue!) { return false }
        if mine.rgba[i * 4 + 3] != 255 { return false }
    }
    return true
}

final class ISOImportTests: XCTestCase {
    func requireISO() throws -> URL {
        guard let iso = Repo.iso else { throw XCTSkip("no CD image (*.iso) in the checkout") }
        return iso
    }

    func testISOReaderListsTheCDAndMatchesExtractedFiles() throws {
        let iso = try ISO9660Image(url: try requireISO())
        XCTAssertEqual(iso.systemIdentifier, "CD-RTOS CD-BRIDGE")
        XCTAssertEqual(iso.sectorLayout, "2048")
        print("volume \(iso.volumeIdentifier), \(iso.entries.count) entries")
        let names = Set(iso.entries.map(\.path))
        for n in 1...13 { XCTAssertTrue(names.contains("EP\(n).EXE")); XCTAssertTrue(names.contains("SONG\(n).PSM")) }
        // every file also present in original/ has the same bytes
        guard FileManager.default.fileExists(atPath: Repo.original.path) else { return }
        var compared = 0
        for e in iso.entries where !e.isDirectory {
            let o = Repo.original.appendingPathComponent(e.path)
            guard FileManager.default.fileExists(atPath: o.path) else { continue }
            XCTAssertEqual(try iso.read(e), try Data(contentsOf: o), e.path)
            compared += 1
        }
        print("ISO files byte-identical to original/: \(compared)")
        XCTAssertGreaterThan(compared, 100)
    }

    /// The full import from the user's CD image: every library file against the Python outputs.
    func testFullImportFromISOMatchesPythonOutputs() throws {
        let isoURL = try requireISO()
        try Repo.requireExtracted()
        let dest = try tempDir("iso")
        defer { try? FileManager.default.removeItem(at: dest) }
        let log = ProgressLog()
        let importer = GameDataImporter(options: ImportOptions(rules: .copy(from: Repo.extracted)))
        let t0 = CFAbsoluteTimeGetCurrent()
        let lib = try importer.importGame(from: .isoImage(isoURL), to: dest) { log.add($0) }
        let seconds = CFAbsoluteTimeGetCurrent() - t0
        print(String(format: "full import of %d tables: %.2f s", lib.tables.count, seconds))
        XCTAssertEqual(lib.tables.map(\.number), Array(1...13))
        XCTAssertEqual(log.items.last?.fraction, 1)
        XCTAssertTrue(log.items.count >= 13 + 2)
        XCTAssertTrue(log.items.allSatisfy { $0.fraction >= 0 && $0.fraction <= 1 })
        print("warnings: \(lib.warnings)")

        let fm = FileManager.default
        var bad: [String] = []
        var checked = 0
        for t in lib.tables {
            let n = t.number
            let ref = Reference.table(n)
            XCTAssertEqual(t.dataDirectory.standardizedFileURL, LibraryLayout.tableDirectory(dest, table: n).standardizedFileURL)
            // byte-identical files
            for f in ["playfield_idx.npy", "palette.json", "collision_idx.npy", "collision.npy", "collision.json", "engine.json",
                      "sprites/sprites.json", "rules.json"] {
                checked += 1
                if (try? Data(contentsOf: t.dataDirectory.appendingPathComponent(f))) != (try? Data(contentsOf: ref.appendingPathComponent(f))) {
                    bad.append("EP\(n) \(f)")
                }
            }
            // same pixels in every PNG the Python tools wrote (sprites + previews), except contact sheets
            // and the collision visualisation (dev-only images the importer does not produce)
            var pngs = ["playfield.png", "preview.png", "ball.png"]
            let sref = ref.appendingPathComponent("sprites")
            pngs += (try fm.contentsOfDirectory(atPath: sref.path)).filter { $0.hasSuffix(".png") && !$0.hasPrefix("_sheet_") }.map { "sprites/" + $0 }
            pngs += (try fm.contentsOfDirectory(atPath: ref.path)).filter { $0.hasPrefix("playfield_composited") }
            for p in pngs {
                checked += 1
                if p == "ball.png" && isStale(ref.appendingPathComponent(p), comparedTo: ref.appendingPathComponent("palette.json")) {
                    // collision.py wrote this ball.png before palette.json last changed (EP8): compare with the
                    // reference palette applied to the reference ball indices (engine.json) instead
                    if !ballMatchesReferencePalette(t.dataDirectory.appendingPathComponent(p), ref) { bad.append("EP\(n) \(p) vs palette.json") }
                    continue
                }
                if !samePixels(t.dataDirectory.appendingPathComponent(p), ref.appendingPathComponent(p)) { bad.append("EP\(n) \(p) pixels") }
            }
            // copies of the originals
            for f in ["EP\(n).EXE", "EP\(n).DAT", "ID\(n).DAT", "SFX\(n).PIN", "SONG\(n).PSM"] {
                checked += 1
                if (try? Data(contentsOf: LibraryLayout.originalDirectory(dest).appendingPathComponent(f))) != (try? Data(contentsOf: Repo.original.appendingPathComponent(f))) {
                    bad.append("original/\(f)")
                }
            }
        }
        let manifest = try Data(contentsOf: dest.appendingPathComponent("tables/manifest.json"))
        XCTAssertEqual(try parseJSON(manifest), try parseJSON(Data(contentsOf: Repo.extracted.appendingPathComponent("tables/manifest.json"))))
        print("checked \(checked) files, \(bad.count) differ")
        for b in bad { print("  differs: \(b)") }
        XCTAssertTrue(bad.isEmpty)
        // library.json round trip
        let back = LibraryLayout.load(dest)
        XCTAssertEqual(back?.tables.map(\.name), lib.tables.map(\.name))
        XCTAssertEqual(lib.tables.first?.name, TablePipeline.tableName(try [UInt8](Data(contentsOf: Repo.original.appendingPathComponent("ID1.DAT"))), table: 1))
        XCTAssertFalse(fm.fileExists(atPath: dest.appendingPathComponent(".import-staging").path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dest.path).filter { $0.hasPrefix(".import-") }, [])
    }

    func testImportWithoutRulesMarksDirectExe() throws {
        let isoURL = try requireISO()
        let dest = try tempDir("norules")
        defer { try? FileManager.default.removeItem(at: dest) }
        let lib = try GameDataImporter(options: ImportOptions(rules: .none, tables: [1, 8])).importGame(from: .isoImage(isoURL), to: dest) { _ in }
        XCTAssertEqual(lib.tables.map(\.number), [1, 8])
        XCTAssertFalse(FileManager.default.fileExists(atPath: LibraryLayout.tableDirectory(dest, table: 1).appendingPathComponent("rules.json").path))
        let j = try parseJSON(Data(contentsOf: LibraryLayout.manifestURL(dest)))
        XCTAssertEqual(j["tables"]?[0]?["rules"]?.stringValue, "direct-exe")
        XCTAssertFalse(lib.warnings.contains { $0.contains("rules") })   // direct-exe is the app's default backend
        // re-import over an existing library replaces it and leaves foreign items alone
        let foreign = dest.appendingPathComponent("hd-packs", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let lib2 = try GameDataImporter(options: ImportOptions(rules: .none, tables: [2])).importGame(from: .isoImage(isoURL), to: dest) { _ in }
        XCTAssertEqual(lib2.tables.map(\.number), [2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: LibraryLayout.tableDirectory(dest, table: 1).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }
}

/// Directory sources: installed game, GOG-style subfolder, disc image inside a folder, missing tables.
/// Built from symlinks to the user's files in a temporary folder (nothing is copied).
final class SourceLayoutTests: XCTestCase {
    func link(_ names: [String], into dir: URL, lowercase: Bool = false) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in names {
            let src = Repo.original.appendingPathComponent(n)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(lowercase ? n.lowercased() : n), withDestinationURL: src)
        }
    }
    func tableFiles(_ tables: ClosedRange<Int>) -> [String] {
        tables.flatMap { ["EP\($0).EXE", "EP\($0).DAT", "ID\($0).DAT", "SFX\($0).PIN", "SONG\($0).PSM"] } + ["SFX0.PIN", "SONG0.PSM", "PINBALL.EXE"]
    }

    func testInstalledFolderAndGOGSubfolderAreDetected() throws {
        try Repo.requireOriginal()
        let root = try tempDir("dirs")
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = root.appendingPathComponent("EPIC")
        try link(tableFiles(1...13), into: plain)
        var s = try GameDataImporter().scan(.directory(plain))
        XCTAssertEqual(s.kind, "directory"); XCTAssertEqual(s.tables, Array(1...13)); XCTAssertEqual(s.missingTables, [])
        // GOG-style: DOSBox files next to a game subfolder, lower-case names
        let gog = root.appendingPathComponent("GOG Games/Epic Pinball")
        try FileManager.default.createDirectory(at: gog.appendingPathComponent("DOSBOX"), withIntermediateDirectories: true)
        try Data("[autoexec]\n".utf8).write(to: gog.appendingPathComponent("dosboxEPIC.conf"))
        try link(tableFiles(1...13), into: gog.appendingPathComponent("EPIC"), lowercase: true)
        s = try GameDataImporter().scan(.directory(gog))
        XCTAssertEqual(s.kind, "directory-subfolder"); XCTAssertEqual(s.gameFolder, "EPIC"); XCTAssertEqual(s.tables, Array(1...13))
        // a macOS app bundle wrapping the game (e.g. a Boxer / DOSBox wrapper)
        let app = root.appendingPathComponent("Epic Pinball.app/Contents/Resources/game/EPIC")
        try link(tableFiles(1...13), into: app)
        s = try GameDataImporter().scan(.directory(root.appendingPathComponent("Epic Pinball.app")))
        XCTAssertEqual(s.gameFolder, "Contents/Resources/game/EPIC"); XCTAssertEqual(s.tables.count, 13)
        // an import from the GOG layout gives the same engine.json as from the CD
        let dest = try tempDir("gog")
        defer { try? FileManager.default.removeItem(at: dest) }
        let lib = try GameDataImporter(options: ImportOptions(rules: .none, tables: [5])).importGame(from: .directory(gog), to: dest) { _ in }
        XCTAssertEqual(lib.tables.map(\.number), [5])
        if FileManager.default.fileExists(atPath: Reference.table(5).path) {
            XCTAssertEqual(try Data(contentsOf: LibraryLayout.tableDirectory(dest, table: 5).appendingPathComponent("engine.json")),
                           try Data(contentsOf: Reference.table(5).appendingPathComponent("engine.json")))
        }
    }

    func testMissingAndExtraTablesAreReported() throws {
        try Repo.requireOriginal()
        let root = try tempDir("partial")
        defer { try? FileManager.default.removeItem(at: root) }
        try link(tableFiles(1...3), into: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("SONG2.PSM"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("EP3.DAT"))
        try Data([0x4D, 0x5A]).write(to: root.appendingPathComponent("EP14.EXE"))
        let s = try GameDataImporter().scan(.directory(root))
        XCTAssertEqual(s.tables, [1, 2])
        XCTAssertEqual(s.missingTables, [3] + Array(4...13))
        XCTAssertEqual(s.missingOptional[2], ["SONG2.PSM"])
        XCTAssertEqual(s.extraFiles, ["EP14.EXE"])
        let w = try GameDataImporter().validate(.directory(root))
        XCTAssertTrue(w.contains { $0.contains("EP3.DAT") })
        XCTAssertTrue(w.contains { $0.contains("SONG2.PSM") })
        XCTAssertTrue(w.contains { $0.contains("EP14.EXE") })
    }

    func testDiscImageInsideAFolder() throws {
        guard let iso = Repo.iso else { throw XCTSkip("no CD image") }
        let root = try tempDir("gogimg")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("game.gog"), withDestinationURL: iso)
        try Data("FILE \"game.gog\" BINARY\n".utf8).write(to: root.appendingPathComponent("game.ins"))
        let s = try GameDataImporter().scan(.directory(root))
        XCTAssertEqual(s.kind, "disc-image-in-directory"); XCTAssertEqual(s.discImage, "game.gog"); XCTAssertEqual(s.tables, Array(1...13))
    }

    func testFolderWithoutTheGameIsAnError() throws {
        let root = try tempDir("empty")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("README.TXT"))
        XCTAssertThrowsError(try GameDataImporter().validate(.directory(root))) { e in
            XCTAssertTrue(String(describing: e).contains("EP1.EXE"))
        }
        XCTAssertThrowsError(try GameDataImporter().importGame(from: .directory(root), to: root.appendingPathComponent("lib")) { _ in })
    }
}

/// `EP_IMPORT_OUT=/path swift test --filter DevLibraryTests`: import the user's CD image (or
/// original/) into /path, e.g. for pointing the app at a library (`--data /path --original /path/original`).
final class DevLibraryTests: XCTestCase {
    func testWriteLibraryWhenRequested() throws {
        guard let out = ProcessInfo.processInfo.environment["EP_IMPORT_OUT"], !out.isEmpty else { throw XCTSkip("EP_IMPORT_OUT not set") }
        let source: ImportSource = Repo.iso.map { .isoImage($0) } ?? .directory(Repo.original)
        let t0 = CFAbsoluteTimeGetCurrent()
        let lib = try GameDataImporter().importGame(from: source, to: URL(fileURLWithPath: out)) { p in
            print(String(format: "%5.1f%% %@", p.fraction * 100, p.message))
        }
        print(String(format: "imported %d tables into %@ in %.2f s", lib.tables.count, lib.root.path, CFAbsoluteTimeGetCurrent() - t0))
    }
}
