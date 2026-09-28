import CoreGraphics
import Foundation
import ImageIO
import PinballCore

/// Where the game data for this run comes from: the runtime data root (`tables/EPn/...`, the
/// importer's library or a developer `extracted/` directory) and the user's original files
/// (EPn.EXE, EPn.DAT, IDn.DAT, SFXn.PIN, SONGn.PSM). Nothing is bundled with the app.
struct GameLibrary: Equatable {
    var dataRoot: URL
    var originalDir: URL?
    /// How it was found (shown in Settings > Library).
    var origin: Origin

    enum Origin: String { case explicit = "--data", library = "imported library", developer = "developer data (extracted/)" }

    /// A library is usable when at least one table has its runtime files.
    static func hasTables(_ root: URL) -> Bool {
        (1...TableGeometry.tableCount).contains { TableCatalog.tableFilesPresent(root: root, table: $0) }
    }

    /// True when running from a packaged .app (then the compile-time `../extracted` fallback
    /// is not used, so a fresh install shows the import screen).
    static var runningFromAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Resolution order: `--data DIR`; the imported library in Application Support;
    /// `$EPIC_PINBALL_DATA`; and (outside a .app only) the developer `../extracted` candidates.
    static func locate(explicitData: String?, explicitOriginal: String?) -> GameLibrary? {
        let fm = FileManager.default
        if let e = explicitData {
            let root = URL(fileURLWithPath: (e as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            return GameLibrary(dataRoot: root, originalDir: findOriginal(near: root, explicit: explicitOriginal), origin: .explicit)
        }
        let lib = AppPaths.libraryRoot
        if hasTables(lib) {
            return GameLibrary(dataRoot: lib, originalDir: findOriginal(near: lib, explicit: explicitOriginal), origin: .library)
        }
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["EPIC_PINBALL_DATA"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        if !runningFromAppBundle { candidates += DataLocator.defaultCandidates() }
        for c in candidates where fm.fileExists(atPath: c.appendingPathComponent("tables").path) && hasTables(c) {
            return GameLibrary(dataRoot: c.standardizedFileURL, originalDir: findOriginal(near: c, explicit: explicitOriginal),
                               origin: .developer)
        }
        return nil
    }

    /// The directory holding the user's EPn.EXE files: explicit, `$EPIC_PINBALL_ORIGINAL`,
    /// `<root>/original`, `<root>` itself, then `original/` next to the root (the development layout).
    static func findOriginal(near root: URL, explicit: String?) -> URL? {
        var dirs: [URL] = []
        if let e = explicit { dirs.append(URL(fileURLWithPath: (e as NSString).expandingTildeInPath, isDirectory: true)) }
        if let e = ProcessInfo.processInfo.environment["EPIC_PINBALL_ORIGINAL"], !e.isEmpty {
            dirs.append(URL(fileURLWithPath: e, isDirectory: true))
        }
        dirs.append(root.appendingPathComponent("original", isDirectory: true))
        dirs.append(root)
        dirs.append(root.deletingLastPathComponent().appendingPathComponent("original", isDirectory: true))
        let fm = FileManager.default
        return dirs.first { d in (1...TableGeometry.tableCount).contains { fm.fileExists(atPath: d.appendingPathComponent("EP\($0).EXE").path) } }?
            .standardizedFileURL
    }
}

/// One entry of the table picker, read from the user's files at runtime.
struct TableInfo: Identifiable {
    var number: Int
    /// From IDn.DAT (20 bytes, space padded, 0x1A terminated); "Table n" if it is missing.
    var name: String
    /// EPn.DAT (the original table-select screen, PCX), else `tables/EPn/preview.png`.
    var preview: CGImage?
    /// Runtime files present (engine.json, playfield, palette).
    var available: Bool
    var problem: String?
    var id: Int { number }
}

enum TableCatalog {
    static let requiredFiles = ["playfield_idx.npy", "palette.json", "engine.json"]

    static func tableFilesPresent(root: URL, table: Int) -> Bool {
        let dir = root.appendingPathComponent("tables/EP\(table)", isDirectory: true)
        return requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    static func load(_ lib: GameLibrary) -> [TableInfo] {
        (1...TableGeometry.tableCount).map { n in
            let dir = lib.dataRoot.appendingPathComponent("tables/EP\(n)", isDirectory: true)
            let missing = requiredFiles.filter { !FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
            var name: String?
            var preview: CGImage?
            if let o = lib.originalDir {
                name = (try? Data(contentsOf: o.appendingPathComponent("ID\(n).DAT"))).flatMap(tableName)
                preview = (try? Data(contentsOf: o.appendingPathComponent("EP\(n).DAT"))).flatMap { try? PCXImage.decode($0).cgImage() }
            }
            if preview == nil { preview = loadPNG(dir.appendingPathComponent("preview.png")) }
            preview = preview.map(tableArt)
            return TableInfo(number: n, name: name ?? "Table \(n)", preview: preview, available: missing.isEmpty,
                             problem: missing.isEmpty ? nil : "missing \(missing.joined(separator: ", "))")
        }
    }

    /// The original table-select screen (320x200) has the table art in its left half and an empty
    /// high-score box in its right half (the same on all 13 tables): keep the art. Other sizes
    /// are returned unchanged.
    static let selectScreenArtWidth = 160
    static func tableArt(_ image: CGImage) -> CGImage {
        guard image.width == 320, image.height == 200,
              let c = image.cropping(to: CGRect(x: 0, y: 0, width: selectScreenArtWidth, height: 200)) else { return image }
        return c
    }

    /// IDn.DAT: up to 20 bytes of name, space padded, 0x1A (DOS EOF) terminated.
    static func tableName(_ d: Data) -> String? {
        let bytes = d.prefix(32).prefix { $0 != 0x1A && $0 != 0 }
        guard let s = String(bytes: bytes.map { $0 < 0x20 || $0 > 0x7E ? 0x20 : $0 }, encoding: .ascii) else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    static func loadPNG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// ZSoft PCX v5, 8 bits per pixel, 1 plane, RLE, with the 256-colour palette at the end of the
/// file (the original's EPn.DAT table-select screens; docs/formats/README.md).
struct PCXImage: Equatable {
    var width: Int
    var height: Int
    /// Palette indices, row-major.
    var pixels: [UInt8]
    /// 256 RGB triples (8-bit components).
    var palette: [UInt8]

    enum DecodeError: Error, Equatable { case notPCX, unsupported(String), truncated }

    static func decode(_ data: Data) throws -> PCXImage {
        let d = [UInt8](data)
        guard d.count >= 128, d[0] == 0x0A else { throw DecodeError.notPCX }
        guard d[2] == 1, d[3] == 8 else { throw DecodeError.unsupported("encoding \(d[2]), \(d[3]) bpp") }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        let xmin = u16(4), ymin = u16(6), xmax = u16(8), ymax = u16(10)
        guard d[65] == 1 else { throw DecodeError.unsupported("\(d[65]) planes") }
        let bpl = u16(66)
        let w = xmax - xmin + 1, h = ymax - ymin + 1
        guard w > 0, h > 0, w <= 4096, h <= 4096, bpl >= w else { throw DecodeError.unsupported("size \(w)x\(h), \(bpl) bytes per line") }
        let total = bpl * h
        var out = [UInt8](repeating: 0, count: total)
        var pos = 128, o = 0
        while o < total {
            guard pos < d.count else { throw DecodeError.truncated }
            let b = d[pos]; pos += 1
            var count = 1, value = b
            if b >= 0xC0 {
                guard pos < d.count else { throw DecodeError.truncated }
                count = Int(b & 0x3F); value = d[pos]; pos += 1
            }
            let end = min(o + count, total)
            if end > o { for k in o..<end { out[k] = value } }
            o += count
        }
        var pixels = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { pixels[y * w + x] = out[y * bpl + x] } }
        var pal = [UInt8](repeating: 0, count: 768)
        if d.count >= 769, d[d.count - 769] == 0x0C { pal = Array(d[(d.count - 768)...]) }
        return PCXImage(width: w, height: h, pixels: pixels, palette: pal)
    }

    var rgba: [UInt8] {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for (i, p) in pixels.enumerated() {
            out[i * 4] = palette[Int(p) * 3]; out[i * 4 + 1] = palette[Int(p) * 3 + 1]; out[i * 4 + 2] = palette[Int(p) * 3 + 2]
        }
        return out
    }

    func cgImage() -> CGImage? {
        let bytes = rgba
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
