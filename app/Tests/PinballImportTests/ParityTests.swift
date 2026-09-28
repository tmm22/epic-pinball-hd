import Foundation
import XCTest
@testable import PinballImport

/// First structural difference between two JSON values ("" if equal).
func jsonDiff(_ a: JSONValue, _ b: JSONValue, path: String = "$", limit: Int = 8) -> [String] {
    var out: [String] = []
    func go(_ a: JSONValue, _ b: JSONValue, _ p: String) {
        if out.count >= limit { return }
        switch (a, b) {
        case let (.object(x), .object(y)):
            for k in x.keys where y[k] == nil { out.append("\(p).\(k): only in swift"); if out.count >= limit { return } }
            for k in y.keys where x[k] == nil { out.append("\(p).\(k): only in python"); if out.count >= limit { return } }
            for k in x.keys { if let yv = y[k] { go(x[k]!, yv, "\(p).\(k)") } }
        case let (.array(x), .array(y)):
            if x.count != y.count { out.append("\(p): length \(x.count) vs \(y.count)") }
            for i in 0..<min(x.count, y.count) { go(x[i], y[i], "\(p)[\(i)]") }
        default:
            if a != b {
                let sa = serialize(a, style: .python), sb = serialize(b, style: .python)
                out.append("\(p): swift \(sa.prefix(200)) vs python \(sb.prefix(200))")
            }
        }
    }
    go(a, b, path)
    return out
}

enum Reference {
    static func table(_ n: Int) -> URL { Repo.extracted.appendingPathComponent("tables/EP\(n)", isDirectory: true) }
    static func json(_ n: Int, _ rel: String) throws -> JSONValue { try parseJSON(Data(contentsOf: table(n).appendingPathComponent(rel))) }
    static func files(_ n: Int) throws -> TableFiles {
        let o = Repo.original
        return TableFiles(exe: [UInt8](try Data(contentsOf: o.appendingPathComponent("EP\(n).EXE"))),
                          dat: [UInt8](try Data(contentsOf: o.appendingPathComponent("EP\(n).DAT"))),
                          id: try? [UInt8](Data(contentsOf: o.appendingPathComponent("ID\(n).DAT"))))
    }
}

final class PipelineParityTests: XCTestCase {
    /// In memory, from original/: every table's outputs equal the Python tools' outputs in extracted/.
    func testAllTablesMatchPythonOutputs() throws {
        try Repo.requireOriginal()
        try Repo.requireExtracted()
        var failures: [String] = []
        let manifest = try parseJSON(Data(contentsOf: Repo.extracted.appendingPathComponent("tables/manifest.json")))
        for n in 1...13 {
            let o = try TablePipeline.run(table: n, files: try Reference.files(n))
            let ref = Reference.table(n)
            func check(_ what: String, _ ok: Bool) { if !ok { failures.append("EP\(n) \(what)") } }
            // byte-for-byte: npy files, palette.json
            check("playfield_idx.npy", NPYFile.data(uint8: o.playfield.playfield, shape: [400, 320]) == (try Data(contentsOf: ref.appendingPathComponent("playfield_idx.npy"))))
            check("palette.json", Data(o.playfield.paletteJSON.utf8) == (try Data(contentsOf: ref.appendingPathComponent("palette.json"))))
            check("collision_idx.npy", NPYFile.data(uint8: o.collision.buffer, shape: [400, 320]) == (try Data(contentsOf: ref.appendingPathComponent("collision_idx.npy"))))
            check("collision.npy", NPYFile.data(uint8: o.collision.classes, shape: [2, 400, 320]) == (try Data(contentsOf: ref.appendingPathComponent("collision.npy"))))
            // structural: JSON
            for (name, mine, theirs) in [("manifest", o.playfield.manifest, manifest[n - 1]!),
                                         ("collision.json", .object(o.collision.info), try Reference.json(n, "collision.json")),
                                         ("sprites.json", o.sprites.json, try Reference.json(n, "sprites/sprites.json")),
                                         ("engine.json", .object(o.engine), try Reference.json(n, "engine.json"))] {
                let d = jsonDiff(mine, theirs)
                if !d.isEmpty { failures.append("EP\(n) \(name):\n    " + d.joined(separator: "\n    ")) }
            }
            // the files as written are byte-identical to Python's json.dump output
            for (name, text) in [("engine.json", serialize(.object(o.engine), style: .compact)),
                                 ("collision.json", serialize(.object(o.collision.info), style: .indent(1))),
                                 ("sprites/sprites.json", serialize(o.sprites.json, style: .indent(1)))] {
                check("\(name) (bytes)", Data(text.utf8) == (try Data(contentsOf: ref.appendingPathComponent(name))))
            }
            print(String(format: "EP%d: %@", n, o.seconds.sorted { $0.key < $1.key }.map { String(format: "%@ %.2fs", $0.key, $0.value) }.joined(separator: ", ")))
        }
        for f in failures { print(f) }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) outputs differ from the Python tools")
    }
}

final class ParitySanityTests: XCTestCase {
    /// The serialized JSON is byte-identical to Python's json.dump output, and jsonDiff catches edits.
    func testSerializedJSONIsByteIdenticalAndDiffDetectsChanges() throws {
        try Repo.requireOriginal()
        try Repo.requireExtracted()
        var identical: [String] = [], different: [String] = []
        for n in [1] {
            let o = try TablePipeline.run(table: n, files: try Reference.files(n))
            let ref = Reference.table(n)
            for (name, text) in [("engine.json", serialize(.object(o.engine), style: .compact)),
                                 ("collision.json", serialize(.object(o.collision.info), style: .indent(1))),
                                 ("sprites/sprites.json", serialize(o.sprites.json, style: .indent(1)))] {
                let theirs = try Data(contentsOf: ref.appendingPathComponent(name))
                if Data(text.utf8) == theirs { identical.append("EP\(n) \(name)") } else {
                    different.append("EP\(n) \(name)")
                    let a = Array(text.utf8), b = [UInt8](theirs)
                    let i = (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
                    print("EP\(n) \(name) first difference at byte \(i): swift ...\(String(decoding: a[max(0, i - 60)..<min(a.count, i + 60)], as: UTF8.self))")
                    print("    python ...\(String(decoding: b[max(0, i - 60)..<min(b.count, i + 60)], as: UTF8.self))")
                }
            }
            // a one-value change must be reported
            var e = o.engine
            var params = e["params"]!.objectValue!
            params["values"] = .ints([1, 2, 3])
            e["params"] = .object(params)
            XCTAssertFalse(jsonDiff(.object(e), try Reference.json(n, "engine.json")).isEmpty)
            XCTAssertTrue(jsonDiff(.object(o.engine), try Reference.json(n, "engine.json")).isEmpty)
        }
        print("byte-identical: \(identical)")
        print("structurally equal only: \(different)")
        XCTAssertTrue(different.isEmpty)
    }
}
