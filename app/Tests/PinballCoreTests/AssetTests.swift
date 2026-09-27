import Foundation
import XCTest
@testable import PinballCore

final class NPYTests: XCTestCase {
    /// Builds a .npy file the way numpy does (header padded so data is 64-byte aligned).
    static func makeNPY(descr: String = "|u1", shape: String = "(2, 3)", fortran: String = "False",
                        version: UInt8 = 1, payload: [UInt8] = [1, 2, 3, 4, 5, 6]) -> Data {
        var header = "{'descr': '\(descr)', 'fortran_order': \(fortran), 'shape': \(shape), }"
        let prefix = version == 1 ? 10 : 12
        while (prefix + header.utf8.count + 1) % 64 != 0 { header += " " }
        header += "\n"
        var d = Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, version, 0])
        let n = header.utf8.count
        if version == 1 { d += [UInt8(n & 0xFF), UInt8(n >> 8)] } else { d += [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), 0, 0] }
        d += Data(header.utf8)
        d += payload
        return d
    }

    func testParsesVersion1() throws {
        let a = try NPYReader.parse(Self.makeNPY())
        XCTAssertEqual(a.rows, 2)
        XCTAssertEqual(a.columns, 3)
        XCTAssertEqual(a[1, 0], 4)
        XCTAssertEqual(a.data, [1, 2, 3, 4, 5, 6])
    }

    func testParsesVersion2() throws {
        let a = try NPYReader.parse(Self.makeNPY(version: 2))
        XCTAssertEqual(a.rows, 2)
        XCTAssertEqual(a.data.count, 6)
    }

    func testRejectsBadInput() {
        XCTAssertThrowsError(try NPYReader.parse(Data("hello world, not numpy".utf8))) {
            XCTAssertEqual($0 as? NPYError, .badMagic)
        }
        XCTAssertThrowsError(try NPYReader.parse(Self.makeNPY(descr: "<u2"))) {
            XCTAssertEqual($0 as? NPYError, .unsupportedDType("<u2"))
        }
        XCTAssertThrowsError(try NPYReader.parse(Self.makeNPY(shape: "(6,)")))
        XCTAssertThrowsError(try NPYReader.parse(Self.makeNPY(fortran: "True")))
        XCTAssertThrowsError(try NPYReader.parse(Self.makeNPY(payload: [1, 2, 3]))) {
            XCTAssertEqual($0 as? NPYError, .truncatedData(expected: 6, actual: 3))
        }
    }
}

final class PaletteTests: XCTestCase {
    func testParsesJSON() throws {
        let entries = (0..<256).map { "[\($0), \(255 - $0), 7]" }.joined(separator: ",")
        let p = try Palette.parseJSON(Data("[\(entries)]".utf8))
        XCTAssertEqual(p[10], Palette.RGB(r: 10, g: 245, b: 7))
        XCTAssertEqual(p.rgba8.count, 1024)
        XCTAssertEqual(Array(p.rgba8[40..<44]), [10, 245, 7, 255])
    }

    func testRejectsWrongCountAndRange() {
        XCTAssertThrowsError(try Palette.parseJSON(Data("[[0,0,0]]".utf8))) {
            XCTAssertEqual($0 as? PaletteError, .wrongCount(1))
        }
        let bad = (0..<256).map { $0 == 3 ? "[0, 256, 0]" : "[0,0,0]" }.joined(separator: ",")
        XCTAssertThrowsError(try Palette.parseJSON(Data("[\(bad)]".utf8))) {
            XCTAssertEqual($0 as? PaletteError, .badEntry(index: 3))
        }
    }
}

final class TableAssetTests: XCTestCase {
    func testMissingDataGivesClearError() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("no-such-ep-data-\(UUID())")
        XCTAssertThrowsError(try TableAssets.load(dataRoot: root, table: 1)) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("playfield_idx.npy"), text)
            XCTAssertTrue(text.contains("--data"), text)
        }
        XCTAssertThrowsError(try TableAssets.load(dataRoot: root, table: 14))
    }

    /// Uses the user's own extracted data when present; skipped otherwise.
    func testLoadsExtractedTablesIfPresent() throws {
        let root = DataLocator.packageRelativeDefault
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("tables/EP1/playfield_idx.npy").path) else {
            throw XCTSkip("no extracted data at \(root.path)")
        }
        for n in [1, 2, 10] {
            let t = try TableAssets.load(dataRoot: root, table: n)
            XCTAssertEqual(t.indices.count, TableGeometry.width * TableGeometry.height)
            XCTAssertEqual(t.palette.entries.count, 256)
        }
    }
}
