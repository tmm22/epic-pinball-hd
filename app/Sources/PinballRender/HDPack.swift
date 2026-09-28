import CryptoKit
import Foundation
import PinballCore

/// Straight (non-premultiplied) RGBA8 image, top row first.
public struct RGBAImage: Sendable, Equatable {
    public var width: Int, height: Int
    public var pixels: [UInt8]
    public init(width: Int, height: Int, pixels: [UInt8]) { self.width = width; self.height = height; self.pixels = pixels }
}

/// A high-resolution asset pack for one table (format: docs/enhanced/rendering.md).
///
/// Packs are generated on the user's machine from the user's own extracted data
/// (`tools/hdpack/make_pack.py`) and live only in user data directories. Every asset is an
/// exact integer multiple (`scale`) of the original record and is placed at the original
/// position times `scale`, so HD pixel (X, Y) always belongs to original pixel
/// (X / scale, Y / scale). Collision never looks at the pack.
public struct HDPack: Sendable {
    public static let formatName = "epic-pinball-hdpack"
    public static let formatVersion = 1

    public let directory: URL
    public let table: Int
    public let scale: Int
    /// 320*scale x 400*scale, drawn in the base palette's colours (nil = not in the pack or rejected).
    public let playfield: RGBAImage?
    /// By sprites.json name (lamp overlays, flipper frames, plunger, digits, pause banner).
    public let sprites: [String: RGBAImage]
    /// Ball 0 (engine.json ball), (w*scale x h*scale), alpha = coverage.
    public let ball: RGBAImage?
    /// font8 coverage masks: glyph index (from ' ') -> 8*scale x 8*scale bytes.
    public let font8: [Int: [UInt8]]
    public let warnings: [String]

    public enum PackError: Error, CustomStringConvertible {
        case unreadable(URL, String)
        case invalid(URL, String)
        public var description: String {
            switch self {
            case let .unreadable(u, why): return "cannot read HD pack \(u.path): \(why)"
            case let .invalid(u, why): return "invalid HD pack \(u.path): \(why)"
            }
        }
    }

    /// Default per-user location of packs in the app: ~/Library/Application Support/EpicPinballHD/HDPacks/EPn
    public static var userPacksRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("EpicPinballHD/HDPacks", isDirectory: true)
    }

    /// Finds `EP<table>/pack.json`: `$EPIC_PINBALL_HDPACKS`, `<dataRoot>/hdpacks` (the development
    /// layout, extracted/hdpacks), then the per-user Application Support directory.
    public static func locate(table: Int, dataRoot: URL?, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var roots: [URL] = []
        if let e = environment["EPIC_PINBALL_HDPACKS"], !e.isEmpty { roots.append(URL(fileURLWithPath: (e as NSString).expandingTildeInPath, isDirectory: true)) }
        if let d = dataRoot { roots.append(d.appendingPathComponent("hdpacks", isDirectory: true)) }
        roots.append(userPacksRoot)
        for r in roots {
            let dir = r.appendingPathComponent("EP\(table)", isDirectory: true)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("pack.json").path) { return dir }
        }
        return nil
    }

    /// SHA-256 (hex) of the playfield indices, as pack.json's `source.playfield_idx_sha256`.
    public static func playfieldHash(_ indices: [UInt8]) -> String {
        SHA256.hash(data: Data(indices)).map { String(format: "%02x", $0) }.joined()
    }

    /// Loads and validates a pack. Assets whose size does not match the original record (times
    /// the scale), or that the table does not have, are dropped with a warning so the renderer
    /// falls back to the original art for them. `playfield` (the table's indices) enables the
    /// stale-pack check; `graphics` enables per-sprite size checks.
    public static func load(from dir: URL, table: Int, playfield: [UInt8]? = nil, graphics: GameGraphics? = nil,
                            ballSize: (w: Int, h: Int) = (15, 14)) throws -> HDPack {
        let manifestURL = dir.appendingPathComponent("pack.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw PackError.unreadable(manifestURL, "missing") }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PackError.invalid(manifestURL, "not a JSON object")
        }
        guard root["format"] as? String == formatName else { throw PackError.invalid(manifestURL, "format is not \(formatName)") }
        let version = (root["version"] as? NSNumber)?.intValue ?? 0
        guard version >= 1, version <= formatVersion else { throw PackError.invalid(manifestURL, "unsupported version \(version)") }
        guard let packTable = (root["table"] as? NSNumber)?.intValue, packTable == table else {
            throw PackError.invalid(manifestURL, "pack is for table \(root["table"] ?? "?"), not \(table)")
        }
        guard let scale = (root["scale"] as? NSNumber)?.intValue, (2...8).contains(scale) else {
            throw PackError.invalid(manifestURL, "scale must be an integer 2...8")
        }
        var warnings: [String] = []
        func image(_ rel: String?) -> RGBAImage? {
            guard let rel else { return nil }
            let url = dir.appendingPathComponent(rel)
            guard let img = FlipperSpriteSet.decodePNG(url) else { warnings.append("cannot read \(url.path)"); return nil }
            return RGBAImage(width: img.w, height: img.h, pixels: img.rgba)
        }

        var playfieldImage: RGBAImage?
        var stalePlayfield = false
        if let src = root["source"] as? [String: Any], let want = src["playfield_idx_sha256"] as? String, let pf = playfield {
            if want.lowercased() != playfieldHash(pf) {
                stalePlayfield = true
                warnings.append("pack was made from a different playfield (source hash mismatch): HD playfield ignored")
            }
        }
        if !stalePlayfield, let pfRel = root["playfield"] as? String, let img = image(pfRel) {
            if img.width == TableGeometry.width * scale && img.height == TableGeometry.height * scale {
                playfieldImage = img
            } else {
                warnings.append("playfield is \(img.width)x\(img.height), expected \(TableGeometry.width * scale)x\(TableGeometry.height * scale): ignored")
            }
        }

        var sprites: [String: RGBAImage] = [:]
        if let list = root["sprites"] as? [String: Any] {
            for (name, v) in list {
                guard let e = v as? [String: Any], let img = image(e["file"] as? String) else { continue }
                var w = (e["w"] as? NSNumber)?.intValue ?? -1, h = (e["h"] as? NSNumber)?.intValue ?? -1
                if let g = graphics {
                    guard let s = g.byName[name] else { warnings.append("\(name): no such record in this table: ignored"); continue }
                    w = s.w; h = s.h
                }
                guard img.width == w * scale, img.height == h * scale else {
                    warnings.append("\(name): \(img.width)x\(img.height), expected \(w * scale)x\(h * scale): ignored")
                    continue
                }
                sprites[name] = img
            }
        }

        var ball: RGBAImage?
        if let e = root["ball"] as? [String: Any], let img = image(e["file"] as? String) {
            if img.width == ballSize.w * scale, img.height == ballSize.h * scale { ball = img } else {
                warnings.append("ball: \(img.width)x\(img.height), expected \(ballSize.w * scale)x\(ballSize.h * scale): ignored")
            }
        }

        var font8: [Int: [UInt8]] = [:]
        if let fonts = root["fonts"] as? [String: Any], let f8 = fonts["font8"] as? [String: Any], let img = image(f8["file"] as? String) {
            let cell = 8 * scale
            let first = (f8["first"] as? NSNumber)?.intValue ?? 0
            if img.width == cell, img.height % cell == 0 {
                for g in 0..<(img.height / cell) {
                    var m = [UInt8](repeating: 0, count: cell * cell)
                    for y in 0..<cell { for x in 0..<cell { m[y * cell + x] = img.pixels[((g * cell + y) * cell + x) * 4] } }
                    font8[first + g] = m
                }
            } else {
                warnings.append("font8 atlas is \(img.width)x\(img.height), expected \(cell) wide and a multiple of \(cell) tall: ignored")
            }
        }
        return HDPack(directory: dir, table: table, scale: scale, playfield: playfieldImage, sprites: sprites, ball: ball,
                      font8: font8, warnings: warnings)
    }
}
