import Foundation
import XCTest
@testable import PinballImport

/// Tests that need no game data.
final class ByteRegexTests: XCTestCase {
    func b(_ s: [UInt8]) -> [UInt8] { s }

    func testLiteralsGroupsAndWildcards() throws {
        let re = try ByteRegex(#"\x8b\x87(..)\xf7\xd8"#)
        let d: [UInt8] = [0x00, 0x8B, 0x87, 0x34, 0x12, 0xF7, 0xD8, 0x8B, 0x87, 0x0A, 0x00, 0xF7, 0xD8]
        let all = re.all(d)
        XCTAssertEqual(all.map(\.start), [1, 7])
        XCTAssertEqual(all[0].u16(1), 0x1234)
        XCTAssertEqual(all[1].u16(1), 0x000A)   // '.' matches 0x0A (DOTALL)
    }

    func testBackreferenceOptionalAlternationClass() throws {
        let re = try ByteRegex(#"\x81\x3e(..)(..)([\x77\x73]).\x83\x06\1(.)"#)
        let ok: [UInt8] = [0x81, 0x3E, 0x10, 0x20, 0xBC, 0x02, 0x77, 0x06, 0x83, 0x06, 0x10, 0x20, 0x0C]
        var bad = ok; bad[10] = 0x11
        XCTAssertEqual(re.search(ok)?.u8(4), 0x0C)
        XCTAssertNil(re.search(bad))
        let opt = try ByteRegex(#"\x8b\xf8(\x81\xc7..)?\x26\x88\x15"#)
        XCTAssertFalse(opt.search([0x8B, 0xF8, 0x26, 0x88, 0x15])!.has(1))
        XCTAssertTrue(opt.search([0x8B, 0xF8, 0x81, 0xC7, 1, 2, 0x26, 0x88, 0x15])!.has(1))
        let alt = try ByteRegex(#"\x83\xef\x02(?:\x75.|\x74\x03\xe9..)\x83"#)
        XCTAssertEqual(alt.search([0x83, 0xEF, 0x02, 0x74, 0x03, 0xE9, 9, 9, 0x83])?.length, 9)
        let star = try ByteRegex(#"\x80((?:\x81..|\x83.)*)\xe8"#)
        XCTAssertEqual(star.search([0x80, 0x81, 1, 2, 0x83, 3, 0xE8])?.group(1)?.count, 5)
    }

    func testEndAnchorLikePython() throws {
        let re = try ByteRegex(#"\x8b\x9d(..)$"#)
        XCTAssertNotNil(re.search([0x00, 0x8B, 0x9D, 1, 2]))
        XCTAssertNotNil(re.search([0x8B, 0x9D, 1, 2, 0x0A]))     // before a final newline
        XCTAssertNil(re.search([0x8B, 0x9D, 1, 2, 3]))
        XCTAssertNotNil(re.search([0x8B, 0x9D, 1, 2, 3], in: 0..<4))
    }

    func testRawBytesKeepRegexMeaning() throws {
        // Python: rb"\xc6\x06" + struct.pack("<H", 0x2e10) -> the 0x2e byte is '.', matching any byte
        let p: [UInt8] = Array(#"\xc6\x06"#.utf8) + [0x10, 0x2E] + Array("(.)".utf8)
        let re = try ByteRegex(bytes: p)
        XCTAssertEqual(re.search([0xC6, 0x06, 0x10, 0x99, 0x05])?.u8(1), 0x05)
        XCTAssertThrowsError(try ByteRegex(bytes: Array(#"\xc6"#.utf8) + [0x28]))   // unbalanced '(' as in Python
    }
}

final class DecoderUnitTests: XCTestCase {
    func dis(_ bytes: [UInt8], at ip: Int = 0x1000) -> X86Instruction? { X86.decode(bytes, start: 0, limit: bytes.count, address: ip) }

    func testCapstoneSpelling() {
        XCTAssertEqual(dis([0x83, 0xFB, 0xFF])?.text, "cmp bx, -1")
        XCTAssertEqual(dis([0x83, 0xE0, 0xFE])?.text, "and ax, 0xfffe")
        XCTAssertEqual(dis([0x26, 0x8A, 0x05])?.text, "mov al, byte ptr es:[di]")
        XCTAssertEqual(dis([0x8B, 0x8E, 0xFE, 0xFF])?.text, "mov cx, word ptr [bp - 2]")
        XCTAssertEqual(dis([0xC6, 0x06, 0x34, 0x12, 0x80])?.text, "mov byte ptr [0x1234], 0x80")
        XCTAssertEqual(dis([0xE8, 0xFD, 0xFF])?.text, "call 0x1000")
        XCTAssertEqual(dis([0x9A, 0x78, 0x56, 0x34, 0x12])?.text, "lcall 0x1234, 0x5678")
        XCTAssertEqual(dis([0xEA, 0x78, 0x56, 0x34, 0x12])?.text, "ljmp 0x1234:0x5678")
        XCTAssertEqual(dis([0xF3, 0xA4])?.text, "rep movsb byte ptr es:[di], byte ptr [si]")
        XCTAssertEqual(dis([0x98])?.text, "cwde")
        XCTAssertEqual(dis([0xD1, 0x10])?.text, "rcl word ptr [bx + si]")
        XCTAssertEqual(dis([0xF6, 0xC8, 0xC0])?.text, "test al, -0x40")
        XCTAssertNil(dis([0x8D, 0xC0]))       // lea with a register operand
        XCTAssertNil(dis([0x0F, 0x0B]))       // outside the covered map
        XCTAssertEqual(dis([0xF7, 0xE1])?.written.sorted(), ["ax", "dx"])
        XCTAssertEqual(dis([0x61])?.written, [])   // popaw: capstone lists 32-bit names only
    }
}

final class JSONTests: XCTestCase {
    func testPythonCompatibleOutput() throws {
        let v = JSONValue.obj([("a", .ints([1, 2])), ("b", .double(1.0)), ("c", .double(0.76)), ("d", .null), ("e", .string("é\"\n")),
                               ("f", .obj([])), ("g", .array([]))])
        XCTAssertEqual(serialize(v, style: .python), #"{"a": [1, 2], "b": 1.0, "c": 0.76, "d": null, "e": "\u00e9\"\n", "f": {}, "g": []}"#)
        XCTAssertEqual(serialize(v, style: .compact), #"{"a":[1,2],"b":1.0,"c":0.76,"d":null,"e":"\u00e9\"\n","f":{},"g":[]}"#)
        XCTAssertEqual(serialize(.obj([("a", .ints([1]))]), style: .indent(1)), "{\n \"a\": [\n  1\n ]\n}")
        XCTAssertEqual(pyFloat(1e-05), "1e-05")
        XCTAssertEqual(pyFloat(59.94), "59.94")
        XCTAssertEqual(pyRound(0.12345, 3), 0.123)
        XCTAssertEqual(pyRound(2.0 / 3.0, 2), 0.67)
        XCTAssertEqual(pyHex(-5), "-0x5")
        let back = try parseJSON(serialize(v, style: .indent(2)))
        XCTAssertEqual(back, v)
        XCTAssertEqual(back.objectValue?.keys, ["a", "b", "c", "d", "e", "f", "g"])
    }

    func testNPYHeaderMatchesNumpy() {
        let d = NPYFile.data(uint8: [1, 2, 3, 4, 5, 6], shape: [2, 3])
        XCTAssertEqual(d.count % 64, 6 % 64)   // header is padded to 64 bytes
        XCTAssertEqual(Array(d.prefix(8)), [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, 0x01, 0x00])
        let hlen = Int(d[8]) | Int(d[9]) << 8
        XCTAssertEqual((10 + hlen) % 64, 0)
        let header = String(decoding: d[10..<(10 + hlen)], as: UTF8.self)
        XCTAssertTrue(header.hasPrefix("{'descr': '|u1', 'fortran_order': False, 'shape': (2, 3), }"))
        XCTAssertTrue(header.hasSuffix(" \n"))
    }
}

/// ISO 9660 reader against images built here (cooked 2048 and raw 2352 Mode 2 Form 1 sectors).
final class ISO9660UnitTests: XCTestCase {
    static func buildISO(files: [(String, [UInt8])], raw: Bool) -> Data {
        var sectors: [[UInt8]] = Array(repeating: [UInt8](repeating: 0, count: 2048), count: 16)
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
        func both32(_ v: Int) -> [UInt8] { le32(v) + le32(v).reversed() }
        func record(name: [UInt8], lba: Int, size: Int, dir: Bool) -> [UInt8] {
            var r: [UInt8] = [0, 0] + both32(lba) + both32(size) + [UInt8](repeating: 0, count: 7) + [dir ? 2 : 0, 0, 0, 1, 0, 0, 1, UInt8(name.count)] + name
            if r.count % 2 == 1 { r.append(0) }
            r += Array("XA".utf8) + [UInt8](repeating: 0, count: 12)   // an XA system-use field, as on CD-Bridge discs
            r[0] = UInt8(r.count)
            return r
        }
        let pvdLBA = 16, termLBA = 17, rootLBA = 18
        var fileLBA = 19
        var root: [UInt8] = record(name: [0], lba: rootLBA, size: 2048, dir: true) + record(name: [1], lba: rootLBA, size: 2048, dir: true)
        var contents: [[UInt8]] = []
        for (name, data) in files {
            root += record(name: Array((name + ";1").utf8), lba: fileLBA, size: data.count, dir: false)
            let n = max(1, (data.count + 2047) / 2048)
            for s in 0..<n {
                var sec = [UInt8](repeating: 0, count: 2048)
                let chunk = data[min(data.count, s * 2048)..<min(data.count, s * 2048 + 2048)]
                sec.replaceSubrange(0..<chunk.count, with: chunk)
                contents.append(sec)
            }
            fileLBA += n
        }
        var pvd = [UInt8](repeating: 0x20, count: 2048)
        pvd[0] = 1; pvd.replaceSubrange(1..<6, with: Array("CD001".utf8)); pvd[6] = 1
        pvd.replaceSubrange(8..<(8 + 17), with: Array("CD-RTOS CD-BRIDGE".utf8))
        pvd.replaceSubrange(40..<(40 + 7), with: Array("TESTVOL".utf8))
        pvd.replaceSubrange(80..<88, with: both32(fileLBA))
        pvd.replaceSubrange(128..<132, with: [0x00, 0x08, 0x08, 0x00])
        let rootRec = record(name: [0], lba: rootLBA, size: 2048, dir: true)
        pvd.replaceSubrange(156..<190, with: rootRec.prefix(34))
        pvd[156] = 34
        var term = [UInt8](repeating: 0, count: 2048); term[0] = 255; term.replaceSubrange(1..<6, with: Array("CD001".utf8))
        var rootSec = [UInt8](repeating: 0, count: 2048); rootSec.replaceSubrange(0..<root.count, with: root)
        sectors += [pvd, term, rootSec] + contents
        _ = (pvdLBA, termLBA)
        var out = Data()
        for s in sectors {
            if raw {
                out.append(contentsOf: [0x00] + [UInt8](repeating: 0xFF, count: 10) + [0x00, 0, 2, 0, 2])   // sync + header (mode 2)
                out.append(contentsOf: [0, 0, 8, 0, 0, 0, 8, 0])                                           // XA subheader, form 1
                out.append(contentsOf: s)
                out.append(contentsOf: [UInt8](repeating: 0, count: 280))                                  // EDC/ECC
            } else {
                out.append(contentsOf: s)
            }
        }
        return out
    }

    func testCookedAndRawImages() throws {
        let big = (0..<5000).map { UInt8($0 % 251) }
        for raw in [false, true] {
            let url = try tempDir("iso-unit").appendingPathComponent("t.iso")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try ISO9660UnitTests.buildISO(files: [("EP1.EXE", big), ("ID1.DAT", Array("ANDROID             \u{1A}".utf8))], raw: raw).write(to: url)
            let iso = try ISO9660Image(url: url)
            XCTAssertEqual(iso.sectorLayout, raw ? "2352/mode2" : "2048")
            XCTAssertEqual(iso.systemIdentifier, "CD-RTOS CD-BRIDGE")
            XCTAssertEqual(iso.volumeIdentifier, "TESTVOL")
            XCTAssertEqual(iso.entries.map(\.path), ["EP1.EXE", "ID1.DAT"])
            XCTAssertEqual([UInt8](try iso.read(iso.entries[0])), big)
            XCTAssertEqual(TablePipeline.tableName([UInt8](try iso.read(iso.entries[1])), table: 1), "ANDROID")
            // an image without EP*.DAT: found, but the table is reported as not importable
            let scan = try SourceScanner.open(.isoImage(url)).1
            XCTAssertEqual(scan.tables, [])
            XCTAssertEqual(scan.missingTables, Array(1...13))
        }
    }

    func testNotAnISO() throws {
        let url = try tempDir("noiso").appendingPathComponent("x.iso")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data(repeating: 0, count: 100_000).write(to: url)
        XCTAssertThrowsError(try ISO9660Image(url: url))
    }
}

final class ContractTests: XCTestCase {
    func testDefaultRootIsInApplicationSupport() {
        XCTAssertTrue(LibraryLocation.defaultRoot.path.contains("Application Support/EpicPinballHD"))
    }

    func testLibraryLayoutMatchesTheAppLoaders() {
        let root = URL(fileURLWithPath: "/tmp/lib")
        // the root is a data root (tables/EPn like extracted/), originals where GameLibrary.findOriginal looks first
        XCTAssertEqual(LibraryLayout.dataRoot(root), root)
        XCTAssertEqual(LibraryLayout.tableDirectory(root, table: 3).path, "/tmp/lib/tables/EP3")
        XCTAssertEqual(LibraryLayout.originalDirectory(root).path, "/tmp/lib/original")
    }

    /// EngineOverrides.swift is generated from tools/engine_overrides/*.json; it must not drift.
    func testEmbeddedOverridesMatchTools() throws {
        let dir = Repo.root.appendingPathComponent("tools/engine_overrides")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { throw XCTSkip("tools/ not present") }
        let files = names.filter { $0.hasPrefix("EP") && $0.hasSuffix(".json") }
        XCTAssertEqual(Set(files.map { Int($0.dropFirst(2).dropLast(5))! }), Set(EngineOverrides.json.keys))
        for f in files {
            let n = Int(f.dropFirst(2).dropLast(5))!
            let disk = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            XCTAssertEqual(EngineOverrides.json[n], disk.trimmingCharacters(in: .newlines), "EngineOverrides.swift is stale for \(f)")
            XCTAssertNoThrow(try parseJSON(EngineOverrides.json[n]!))
        }
    }
}
