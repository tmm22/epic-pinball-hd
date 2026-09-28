import Foundation
import PinballCore
import PinballImport
import XCTest
@testable import EpicPinball

// Front-end logic that needs no window: settings persistence, key bindings, high scores,
// initials entry, the table catalog (PCX / ID decoding) and library discovery. All fixtures
// are synthetic; no game data is used or needed.

final class SettingsPersistenceTests: XCTestCase {
    func testRoundTrip() throws {
        var s = StoredSettings()
        s.game.physicsMode = .enhanced
        s.game.upscaleFilter = .crt
        s.game.highRefresh = true
        s.game.musicVolume = 0.25
        s.frontEnd.players = 3
        s.frontEnd.keyBindings.bind(KeyCode.a, to: .leftFlipper, replace: true)
        let back = StoredSettings.decode(try s.encoded())
        XCTAssertEqual(back, s)
    }

    func testMissingAndUnknownFieldsKeepDefaults() {
        let json = #"{"version":1,"game":{"physicsMode":"enhanced","futureField":42},"frontEnd":{"players":2,"somethingNew":true}}"#
        let s = StoredSettings.decode(Data(json.utf8))
        XCTAssertEqual(s.game.physicsMode, .enhanced)
        XCTAssertEqual(s.game.upscaleFilter, GameSettings().upscaleFilter)
        XCTAssertEqual(s.game.sfxVolume, GameSettings().sfxVolume)
        XCTAssertEqual(s.frontEnd.players, 2)
        XCTAssertEqual(s.frontEnd.keyBindings, KeyBindings.defaults)
    }

    func testWrongTypesAreDroppedPerField() {
        let json = #"{"game":{"physicsMode":"warp","musicVolume":0.3,"highRefresh":"yes"},"frontEnd":{"players":"four","ballsPerGame":5}}"#
        let s = StoredSettings.decode(Data(json.utf8))
        XCTAssertEqual(s.game.physicsMode, .classic)
        XCTAssertEqual(s.game.musicVolume, 0.3)
        XCTAssertFalse(s.game.highRefresh)
        XCTAssertEqual(s.frontEnd.players, 1)
        XCTAssertEqual(s.frontEnd.ballsPerGame, 5)
    }

    func testGarbageGivesDefaults() {
        XCTAssertEqual(StoredSettings.decode(Data("not json".utf8)), StoredSettings())
    }

    func testClampsOutOfRange() {
        let json = #"{"frontEnd":{"players":9,"masterVolume":3,"lastTable":99}}"#
        let s = StoredSettings.decode(Data(json.utf8))
        XCTAssertEqual(s.frontEnd.players, 4)
        XCTAssertEqual(s.frontEnd.masterVolume, 1)
        XCTAssertEqual(s.frontEnd.lastTable, TableGeometry.tableCount)
    }

    @MainActor
    func testStoreSavesOnChange() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("settings.json")
        let a = SettingsStore(fileURL: url)
        var changes = 0
        a.onChange = { changes += 1 }
        a.game.fullTableView = true
        a.frontEnd.haptics = false
        XCTAssertEqual(changes, 2)
        let b = SettingsStore(fileURL: url)
        XCTAssertTrue(b.game.fullTableView)
        XCTAssertFalse(b.frontEnd.haptics)
    }

    @MainActor
    func testNonPersistingStoreWritesNothing() throws {
        let url = try tempDir().appendingPathComponent("settings.json")
        let s = SettingsStore(fileURL: url)
        s.persist = false
        s.game.fullTableView = true
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

final class KeyBindingTests: XCTestCase {
    func testDefaultsAreTheOriginalKeys() {
        let b = KeyBindings.defaults
        XCTAssertEqual(b.frameInput(held: [KeyCode.leftShift]), .leftFlipper)
        XCTAssertEqual(b.frameInput(held: [KeyCode.left]), .leftFlipper)
        XCTAssertEqual(b.frameInput(held: [KeyCode.rightShift]), .rightFlipper)
        XCTAssertEqual(b.frameInput(held: [KeyCode.right]), .rightFlipper)
        XCTAssertEqual(b.frameInput(held: [KeyCode.leftControl]), .plunger)
        XCTAssertEqual(b.frameInput(held: [KeyCode.rightControl]), .plunger)
        XCTAssertEqual(b.frameInput(held: [KeyCode.space]), .space)
        XCTAssertEqual(b.frameInput(held: [KeyCode.z]), .nudgeA)
        XCTAssertEqual(b.frameInput(held: [KeyCode.comma]), .nudgeA)
        XCTAssertEqual(b.frameInput(held: [KeyCode.slash]), .nudgeB)
        XCTAssertEqual(b.frameInput(held: [KeyCode.leftShift, KeyCode.rightShift, KeyCode.leftControl]),
                       [.leftFlipper, .rightFlipper, .plunger])
        XCTAssertEqual(b.frameInput(held: [KeyCode.m, KeyCode.p]), [])
        XCTAssertEqual(b.actions(for: KeyCode.escape), [.menu])
        XCTAssertEqual(b.scroll(held: [KeyCode.up]), -1)
        XCTAssertEqual(b.scroll(held: [KeyCode.down]), 1)
    }

    func testEveryActionHasADefault() {
        for a in GameAction.allCases { XCTAssertFalse(KeyBindings.defaults.keys(a).isEmpty, "\(a)") }
    }

    func testBindMovesTheKey() {
        var b = KeyBindings.defaults
        b.bind(KeyCode.leftShift, to: .plunger, replace: true)
        XCTAssertEqual(b.keys(.plunger), [KeyCode.leftShift])
        XCTAssertFalse(b.keys(.leftFlipper).contains(KeyCode.leftShift))
        XCTAssertEqual(b.frameInput(held: [KeyCode.leftShift]), .plunger)
        b.bind(KeyCode.a, to: .plunger, replace: false)
        XCTAssertEqual(b.keys(.plunger), [KeyCode.leftShift, KeyCode.a])
    }

    func testMenuStaysReachable() {
        var b = KeyBindings.defaults
        b.bind(KeyCode.escape, to: .pause, replace: false)
        XCTAssertEqual(b.keys(.menu), [KeyCode.escape])
        let json = #"{"menu":[],"leftFlipper":[0]}"#
        let d = try! JSONDecoder().decode(KeyBindings.self, from: Data(json.utf8))
        XCTAssertEqual(d.keys(.menu), [KeyCode.escape])
        XCTAssertEqual(d.keys(.leftFlipper), [0])
        XCTAssertEqual(d.keys(.rightFlipper), KeyBindings.defaults.keys(.rightFlipper))
    }

    func testModifierSidesFromDeviceBits() {
        var k = KeyboardState()
        var r = k.modifiersChanged(rawFlags: 0x02, capsLock: false)
        XCTAssertEqual(r.pressed, [KeyCode.leftShift])
        r = k.modifiersChanged(rawFlags: 0x02 | 0x04, capsLock: false)
        XCTAssertEqual(r.pressed, [KeyCode.rightShift])
        XCTAssertEqual(k.held, [KeyCode.leftShift, KeyCode.rightShift])
        r = k.modifiersChanged(rawFlags: 0x04 | 0x2000, capsLock: false)
        XCTAssertEqual(r.pressed, [KeyCode.rightControl])
        XCTAssertEqual(r.released, [KeyCode.leftShift])
        r = k.modifiersChanged(rawFlags: 0, capsLock: false)
        XCTAssertEqual(Set(r.released), [KeyCode.rightShift, KeyCode.rightControl])
        XCTAssertTrue(k.held.isEmpty)
    }

    func testKeyNamesAndCharacters() {
        XCTAssertEqual(KeyCode.name(KeyCode.leftShift), "Left Shift")
        XCTAssertEqual(KeyCode.name(KeyCode.z), "Z")
        XCTAssertEqual(KeyCode.name(250), "Key 250")
        XCTAssertEqual(KeyCode.character(KeyCode.z), "Z")
        XCTAssertEqual(KeyCode.character(29), "0")
        XCTAssertNil(KeyCode.character(KeyCode.space))
        XCTAssertNil(KeyCode.character(KeyCode.comma))
    }
}

final class HighScoreTests: XCTestCase {
    func entry(_ i: String, _ s: UInt32) -> HighScoreEntry { HighScoreEntry(initials: i, score: s, date: Date(timeIntervalSince1970: 0)) }

    func testRankingAndCapacity() {
        var b = HighScoreBook()
        XCTAssertNil(b.rank(for: 0, table: 1), "zero never qualifies")
        for k in 1...10 { XCTAssertNotNil(b.insert(entry("A\(k)", UInt32(k * 1000)), table: 1)) }
        XCTAssertEqual(b.entries(table: 1).map(\.score), (1...10).reversed().map { UInt32($0 * 1000) })
        XCTAssertNil(b.rank(for: 1000, table: 1), "a tie with the last entry does not pass it")
        XCTAssertNil(b.rank(for: 999, table: 1))
        XCTAssertEqual(b.insert(entry("NEW", 5500), table: 1), 5)
        XCTAssertEqual(b.entries(table: 1).count, 10)
        XCTAssertEqual(b.entries(table: 1).last?.score, 2000)
        XCTAssertTrue(b.entries(table: 2).isEmpty, "tables are separate")
    }

    func testTiesKeepOlderEntryAhead() {
        var b = HighScoreBook()
        b.insert(entry("OLD", 5000), table: 3)
        XCTAssertEqual(b.insert(entry("NEW", 5000), table: 3), 1)
        XCTAssertEqual(b.entries(table: 3).map(\.initials), ["OLD", "NEW"])
    }

    func testInitialsNormalised() {
        XCTAssertEqual(HighScoreBook.normalise("ab"), "AB ")
        XCTAssertEqual(HighScoreBook.normalise("abcd"), "ABC")
        XCTAssertEqual(HighScoreBook.normalise("a#b"), "AB ")
    }

    @MainActor
    func testStorePersistsAndSurvivesDamage() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("highscores.json")
        let s = HighScoreStore(fileURL: url)
        XCTAssertEqual(s.add(entry("PJM", 123_456), table: 7), 0)
        XCTAssertEqual(HighScoreStore(fileURL: url).entries(table: 7).first?.initials, "PJM")
        try Data("{broken".utf8).write(to: url)
        let d = HighScoreStore(fileURL: url)
        XCTAssertTrue(d.entries(table: 7).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("bad").path))
    }

    func testInitialsEntry() {
        var e = InitialsEntry()
        XCTAssertEqual(e.text, "AAA")
        e.step(-1)
        XCTAssertEqual(e.letters[0], " ", "wraps from A backwards to the end of the alphabet")
        e.step(1); e.step(1)
        XCTAssertEqual(e.letters[0], "B")
        e.accept()
        e.type("x")
        XCTAssertEqual(e.position, 2)
        e.back()
        XCTAssertEqual(e.position, 1)
        e.type("7"); e.type("q")
        XCTAssertTrue(e.done)
        XCTAssertEqual(e.text, "B7Q")
        e.type("z")
        XCTAssertEqual(e.text, "B7Q", "no change once done")
        XCTAssertEqual(InitialsEntry(start: "pj").text, "PJ ")
    }
}

final class CatalogTests: XCTestCase {
    /// A synthetic 4x3 PCX: RLE runs, a literal >= 0xC0 escaped as a run of 1, and a palette.
    static func makePCX(width: Int = 4, height: Int = 3, bytesPerLine: Int = 4) -> Data {
        var h = [UInt8](repeating: 0, count: 128)
        h[0] = 0x0A; h[1] = 5; h[2] = 1; h[3] = 8
        h[8] = UInt8(width - 1); h[10] = UInt8(height - 1)
        h[65] = 1; h[66] = UInt8(bytesPerLine)
        var d = h
        d += [0xC4, 7]                 // row 0: 7 7 7 7
        d += [1, 2, 0xC1, 0xC8, 3]     // row 1: 1 2 200 3
        d += [0xC2, 9, 0xC2, 5]        // row 2: 9 9 5 5
        d += [0x0C]
        var pal = [UInt8](repeating: 0, count: 768)
        for i in 0..<256 { pal[i * 3] = UInt8(i); pal[i * 3 + 1] = UInt8(255 - i); pal[i * 3 + 2] = 17 }
        return Data(d + pal)
    }

    func testPCXDecode() throws {
        let p = try PCXImage.decode(Self.makePCX())
        XCTAssertEqual(p.width, 4)
        XCTAssertEqual(p.height, 3)
        XCTAssertEqual(p.pixels, [7, 7, 7, 7, 1, 2, 200, 3, 9, 9, 5, 5])
        XCTAssertEqual(Array(p.rgba[24..<28]), [200, 55, 17, 255])
        XCTAssertNotNil(p.cgImage())
    }

    func testPCXRejectsOtherFiles() {
        XCTAssertThrowsError(try PCXImage.decode(Data([0x89, 0x50, 0x4E, 0x47] + [UInt8](repeating: 0, count: 200))))
        var d = [UInt8](Self.makePCX())
        XCTAssertThrowsError(try PCXImage.decode(Data(d.prefix(130))), "truncated RLE")
        d[3] = 4
        XCTAssertThrowsError(try PCXImage.decode(Data(d)))
    }

    func testTableName() {
        let raw = Array("TEST TABLE".utf8) + [UInt8](repeating: 0x20, count: 10) + [0x1A]
        XCTAssertEqual(TableCatalog.tableName(Data(raw)), "TEST TABLE")
        XCTAssertNil(TableCatalog.tableName(Data([0x20, 0x20, 0x1A])))
    }

    func testLibraryDiscoveryAndCatalog() throws {
        let root = try tempDir()
        XCTAssertFalse(GameLibrary.hasTables(root))
        let t3 = root.appendingPathComponent("tables/EP3", isDirectory: true)
        try FileManager.default.createDirectory(at: t3, withIntermediateDirectories: true)
        for f in TableCatalog.requiredFiles { try Data([0]).write(to: t3.appendingPathComponent(f)) }
        XCTAssertTrue(GameLibrary.hasTables(root))
        XCTAssertNil(GameLibrary.findOriginal(near: root, explicit: nil))
        let orig = root.appendingPathComponent("original", isDirectory: true)
        try FileManager.default.createDirectory(at: orig, withIntermediateDirectories: true)
        try Data([0]).write(to: orig.appendingPathComponent("EP3.EXE"))
        try Data(Array("SYNTHETIC".utf8) + [0x1A]).write(to: orig.appendingPathComponent("ID3.DAT"))
        try Self.makePCX().write(to: orig.appendingPathComponent("EP3.DAT"))
        XCTAssertEqual(GameLibrary.findOriginal(near: root, explicit: nil)?.standardizedFileURL.path, orig.standardizedFileURL.path)

        let lib = GameLibrary(dataRoot: root, originalDir: orig, origin: .explicit)
        let tables = TableCatalog.load(lib)
        XCTAssertEqual(tables.count, TableGeometry.tableCount)
        XCTAssertEqual(tables[2].name, "SYNTHETIC")
        XCTAssertTrue(tables[2].available)
        XCTAssertNotNil(tables[2].preview)
        XCTAssertFalse(tables[0].available)
        XCTAssertEqual(tables[0].name, "Table 1")
    }

    func testExplicitDataWins() throws {
        let root = try tempDir()
        let lib = GameLibrary.locate(explicitData: root.path, explicitOriginal: nil)
        XCTAssertEqual(lib?.origin, .explicit)
        XCTAssertEqual(lib?.dataRoot.path, root.standardizedFileURL.path)
    }

    func testExtractedFolderImporter() throws {
        let src = try tempDir()
        let t1 = src.appendingPathComponent("tables/EP1", isDirectory: true)
        try FileManager.default.createDirectory(at: t1, withIntermediateDirectories: true)
        for f in TableCatalog.requiredFiles { try Data([1]).write(to: t1.appendingPathComponent(f)) }
        let orig = src.appendingPathComponent("original", isDirectory: true)
        try FileManager.default.createDirectory(at: orig, withIntermediateDirectories: true)
        try Data([0]).write(to: orig.appendingPathComponent("EP1.EXE"))
        try Data(Array("ONE".utf8) + [0x1A]).write(to: orig.appendingPathComponent("ID1.DAT"))
        let dest = try tempDir().appendingPathComponent("Library", isDirectory: true)
        let imp = makeImporter(for: .directory(src))
        XCTAssertTrue(imp is ExtractedFolderImporter)
        XCTAssertEqual(try imp.validate(.directory(src)), [])
        let fractions = LockedArray()
        let lib = try imp.importGame(from: .directory(src), to: dest) { fractions.append($0.fraction) }
        XCTAssertEqual(lib.tables.map(\.number), [1])
        XCTAssertEqual(lib.tables.first?.name, "ONE")
        XCTAssertTrue(GameLibrary.hasTables(dest))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("original/EP1.EXE").path))
        XCTAssertEqual(fractions.values.last, 1)
        XCTAssertEqual(fractions.values, fractions.values.sorted())
        // An ISO or a plain folder goes to the library importer.
        XCTAssertFalse(makeImporter(for: .isoImage(src.appendingPathComponent("x.iso"))) is ExtractedFolderImporter)
    }
}

final class LockedArray: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [Double] = []
    func append(_ x: Double) { lock.lock(); v.append(x); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return v }
}

func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("ep-frontend-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
