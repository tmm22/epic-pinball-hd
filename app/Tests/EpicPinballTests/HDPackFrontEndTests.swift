import Foundation
import PinballCore
@testable import PinballImport
import PinballRender
import XCTest
@testable import EpicPinball

/// Settings > Library "Generate HD packs" and `--make-hd-pack`: the AppModel job (off the main
/// thread, progress, cancellation) writes packs where the renderer's HDPack.locate / load find
/// them. Synthetic table data only (shapes and made-up colours, no game data).
final class HDPackFrontEndTests: XCTestCase {
    /// A minimal library: tables/EP1 with a playfield, one lamp record and a ball.
    static func syntheticLibrary() throws -> URL {
        let root = try tempDir()
        let dir = root.appendingPathComponent("tables/EP1", isDirectory: true)
        let sdir = dir.appendingPathComponent("sprites", isDirectory: true)
        try FileManager.default.createDirectory(at: sdir, withIntermediateDirectories: true)
        var pal = [UInt8](repeating: 0, count: 768)
        for i in 1..<256 { pal[i * 3] = UInt8(i); pal[i * 3 + 1] = UInt8((i * 7) % 256); pal[i * 3 + 2] = UInt8(255 - i) }
        var idx = [UInt8](repeating: 1, count: 320 * 400)
        for y in 0..<400 { for x in 0..<320 where (x - 160) * (x - 160) + (y - 200) * (y - 200) < 2500 { idx[y * 320 + x] = 9 } }
        try NPYFile.data(uint8: idx, shape: [400, 320]).write(to: dir.appendingPathComponent("playfield_idx.npy"))
        try Data(("[" + (0..<256).map { "[\(pal[$0 * 3]), \(pal[$0 * 3 + 1]), \(pal[$0 * 3 + 2])]" }.joined(separator: ", ") + "]").utf8)
            .write(to: dir.appendingPathComponent("palette.json"))
        try PNGFile.writeIndexed(sdir.appendingPathComponent("lamp000_a.png"), width: 10, height: 8,
                                 indices: (0..<80).map { $0 % 3 == 0 ? 20 : 1 }, palette: pal)
        try Data(#"{"sprites": [{"name": "lamp000_a", "group": "lamp", "format": "planar", "w": 10, "h": 8, "x": 20, "y": 30}]}"#.utf8)
            .write(to: sdir.appendingPathComponent("sprites.json"))
        let ball = (0..<(15 * 14)).map { i -> String in let x = i % 15 - 7, y = i / 15 - 7; return x * x + y * y < 40 ? "30" : "0" }
        try Data("{\"ball\": {\"w\": 15, \"h\": 14, \"transparent\": 0, \"pixels\": [\(ball.joined(separator: ", "))]}}".utf8)
            .write(to: dir.appendingPathComponent("engine.json"))
        return root
    }

    func testOptions() throws {
        var o = try Options.parse(["--make-hd-pack", "3", "--scale", "2", "--hd-method", "nearest", "--verify-hd-pack", "--hd-pack-out", "/tmp/x"])
        XCTAssertEqual(o.makeHDPack, [3])
        XCTAssertEqual(o.scale, 2)
        XCTAssertTrue(o.scaleGiven)
        XCTAssertEqual(o.hdPackMethod, "nearest")
        XCTAssertTrue(o.verifyHDPack)
        XCTAssertEqual(o.hdPackOut, "/tmp/x")
        o = try Options.parse(["--make-hd-pack", "all"])
        XCTAssertEqual(o.makeHDPack, Array(1...13))
        XCTAssertFalse(o.scaleGiven)
        XCTAssertThrowsError(try Options.parse(["--make-hd-pack", "14"]))
        XCTAssertThrowsError(try Options.parse(["--make-hd-pack", "1", "--hd-method", "ai"]))
        XCTAssertNil(try Options.parse([]).makeHDPack)
    }

    @MainActor
    private func wait(_ model: AppModel, seconds: Double = 120) {
        let deadline = Date().addingTimeInterval(seconds)
        while model.hdPackRunning && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// The Library tab's action end to end: generated off the main thread into
    /// <support>/HDPacks/EP1, found by HDPack.locate through the --support-dir override and
    /// accepted by HDPack.load without warnings (not stale, every asset the right size).
    @MainActor
    func testGenerateFromTheModelAndLoadInTheRenderer() throws {
        let lib = try Self.syntheticLibrary()
        let support = try tempDir()
        defer { try? FileManager.default.removeItem(at: lib); try? FileManager.default.removeItem(at: support) }
        AppPaths.overrideRoot = support
        HDPack.userPacksRootOverride = AppPaths.hdPacksRoot
        defer { AppPaths.overrideRoot = nil; HDPack.userPacksRootOverride = nil }

        let model = AppModel(settings: SettingsStore(fileURL: support.appendingPathComponent("settings.json")),
                             scores: HighScoreStore(fileURL: support.appendingPathComponent("highscores.json")))
        model.library = GameLibrary(dataRoot: lib, originalDir: nil, origin: .explicit)
        XCTAssertEqual(HDPackGeneration.installedSummary(), "none")
        model.generateHDPacks(tables: [1], scale: 3)
        XCTAssertTrue(model.hdPackRunning)
        let deadline = Date().addingTimeInterval(120)
        while model.hdPackRunning && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard case let .finished(message) = model.hdPackState else { return XCTFail("\(model.hdPackState)") }
        XCTAssertTrue(message.hasPrefix("Made 1 3x pack"), message)
        XCTAssertGreaterThan(model.hdPackProgressReports, 0, "progress reported while running")
        XCTAssertEqual(model.hdPacksVersion, 1)
        XCTAssertEqual(HDPackGeneration.installedSummary(), "table 1 at 3×")

        let dir = try XCTUnwrap(HDPack.locate(table: 1, dataRoot: lib, environment: [:]))
        XCTAssertEqual(dir.standardizedFileURL.path, AppPaths.hdPacksRoot.appendingPathComponent("EP1").standardizedFileURL.path)
        let idx = try NPYReader.read(contentsOf: lib.appendingPathComponent("tables/EP1/playfield_idx.npy")).data
        let pack = try HDPack.load(from: dir, table: 1, playfield: idx)
        XCTAssertEqual(pack.warnings, [])
        XCTAssertEqual(pack.scale, 3)
        XCTAssertNotNil(pack.playfield)
        XCTAssertEqual(pack.sprites.keys.sorted(), ["lamp000_a"])
        XCTAssertEqual(pack.ball.map { [$0.width, $0.height] }, [45, 42])
    }

    @MainActor
    func testCancelAndMissingLibrary() throws {
        let lib = try Self.syntheticLibrary()
        let support = try tempDir()
        defer { try? FileManager.default.removeItem(at: lib); try? FileManager.default.removeItem(at: support) }
        AppPaths.overrideRoot = support
        defer { AppPaths.overrideRoot = nil }
        let model = AppModel(settings: SettingsStore(fileURL: support.appendingPathComponent("settings.json")),
                             scores: HighScoreStore(fileURL: support.appendingPathComponent("highscores.json")))
        model.generateHDPacks(tables: [1], scale: 2)
        guard case .failed = model.hdPackState else { return XCTFail("no library: \(model.hdPackState)") }

        model.library = GameLibrary(dataRoot: lib, originalDir: nil, origin: .explicit)
        model.generateHDPacks(tables: [1, 2, 3], scale: 4)
        model.cancelHDPacks()
        wait(model)
        guard case let .finished(message) = model.hdPackState else { return XCTFail("\(model.hdPackState)") }
        XCTAssertTrue(message.hasPrefix("Cancelled"), message)
        XCTAssertEqual(HDPackGeneration.installed().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.hdPacksRoot.appendingPathComponent("EP1").path))
    }
}
