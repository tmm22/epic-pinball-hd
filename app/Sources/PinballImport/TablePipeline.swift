// One table through the whole extraction pipeline (extract -> collision -> sprites -> engine),
// in memory, then written to `<library>/data/tables/EPn/`.
import Foundation

public struct TableFiles: Sendable {
    public var exe: [UInt8]       // EPn.EXE
    public var dat: [UInt8]       // EPn.DAT (preview PCX)
    public var id: [UInt8]?       // IDn.DAT (table name)
    public init(exe: [UInt8], dat: [UInt8], id: [UInt8]?) { self.exe = exe; self.dat = dat; self.id = id }
}

struct TableOutputs {
    var number: Int
    var name: String
    var playfield: PlayfieldExtract
    var collision: CollisionAnalysis
    var sprites: SpriteExtract
    var engine: JSONObject
    var discoverError: String?
    var seconds: [String: Double] = [:]
}

enum TablePipeline {
    /// IDn.DAT: 20-byte name, space padded, 0x1A terminated (code page 437; the names are ASCII).
    static func tableName(_ id: [UInt8]?, table n: Int) -> String {
        guard let id else { return "Table \(n)" }
        let bytes = id.prefix { $0 != 0x1A && $0 != 0 }
        let s = String(bytes.map { Character(UnicodeScalar($0 < 0x80 ? $0 : 0x3F)) }).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "Table \(n)" : s
    }

    static func run(table n: Int, files: TableFiles) throws -> TableOutputs {
        var t = CFAbsoluteTimeGetCurrent()
        var times: [String: Double] = [:]
        func lap(_ k: String) { let now = CFAbsoluteTimeGetCurrent(); times[k] = now - t; t = now }
        let exe = try MZImage(name: "EP\(n).EXE", data: files.exe)
        let pfx = try PlayfieldExtract.run(table: n, exe: exe, dat: files.dat)
        lap("playfield")
        let col = try CollisionAnalysis(table: n, exe: exe)
        try col.analyse()
        lap("collision")
        let fadeOffset = pfx.manifest["palette_method"]?.stringValue == "fade-code" ? pfx.manifest["palette_file_offset"]?.hexInt : nil
        let spr = SpriteExtract(table: n, exe: exe, playfield: pfx.playfield, palette: pfx.palette, paletteOffset: fadeOffset)
        try spr.run()
        lap("sprites")
        var emu: EmuConfig? = nil
        var discoverError: String? = nil
        do { emu = try Discover.run(exe: exe) } catch let e as DiscoverNotFound { discoverError = e.what }
        let overrides = try EngineOverrides.json[n].map { try parseJSON($0) }
        let eng = try EngineExport(table: n, exe: exe, collision: .object(col.info), sprites: spr.json)
            .export(emuConfig: emu, overrides: overrides)
        lap("engine")
        return TableOutputs(number: n, name: tableName(files.id, table: n), playfield: pfx, collision: col, sprites: spr, engine: eng,
                            discoverError: discoverError, seconds: times)
    }

    static func write(_ o: TableOutputs, to dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try o.playfield.write(to: dir)
        try o.collision.write(to: dir, palette: o.playfield.palette)
        try o.sprites.write(to: dir)
        try Data(serialize(.object(o.engine), style: .compact).utf8).writeAtomically(to: dir.appendingPathComponent("engine.json"))
    }
}
