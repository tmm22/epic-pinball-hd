// Where the user's game files come from: an ISO 9660 image, or a directory (installed DOS
// game, mounted CD, GOG install). The game folder inside the source is found by file names
// (EP1.EXE ... EP13.EXE, case-insensitive), searching subfolders and disc images.
import Foundation

/// Read access to the files of one source (paths relative to the source root, '/'-separated).
final class SourceFiles: @unchecked Sendable {
    enum Backing { case directory(URL), iso(ISO9660Image) }
    let backing: Backing
    /// lower-cased relative path -> (actual relative path, size)
    private(set) var files: [String: (path: String, size: Int)] = [:]
    /// relative directory paths ("" = root), for layout reporting
    private(set) var directories: Set<String> = [""]

    init(directory root: URL, maxDepth: Int = 6, maxEntries: Int = 50_000) {
        backing = .directory(root)
        let fm = FileManager.default
        var queue: [(URL, String, Int)] = [(root, "", 0)]
        var seen = 0
        while !queue.isEmpty && seen < maxEntries {
            let (dir, rel, depth) = queue.removeFirst()
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey],
                                                           options: [.skipsHiddenFiles]) else { continue }
            for u in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                seen += 1
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
                let r = rel.isEmpty ? u.lastPathComponent : rel + "/" + u.lastPathComponent
                if v?.isDirectory == true {
                    if v?.isSymbolicLink != true && depth < maxDepth { directories.insert(r); queue.append((u, r, depth + 1)) }
                } else {
                    var size = v?.fileSize ?? 0
                    if v?.isSymbolicLink == true {   // report the target's size (a linked disc image)
                        size = (try? u.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
                    }
                    files[r.lowercased()] = (r, size)
                }
            }
        }
    }

    init(iso: ISO9660Image) {
        backing = .iso(iso)
        for e in iso.entries {
            if e.isDirectory { directories.insert(e.path) } else { files[e.path.lowercased()] = (e.path, e.size) }
        }
    }

    func has(_ rel: String) -> Bool { files[rel.lowercased()] != nil }

    func read(_ rel: String) throws -> Data {
        guard let f = files[rel.lowercased()] else { throw ImportError("missing \(rel)") }
        switch backing {
        case let .directory(root): return try Data(contentsOf: root.appendingPathComponent(f.path))
        case let .iso(img):
            guard let e = img.entries.first(where: { $0.path == f.path }) else { throw ImportError("missing \(rel) in the image") }
            return try img.read(e)
        }
    }

    /// Files directly inside `dir` ("" = root), lower-cased names.
    func names(in dir: String) -> [String] {
        let prefix = dir.isEmpty ? "" : dir.lowercased() + "/"
        return files.keys.filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }.map { String($0.dropFirst(prefix.count)) }
    }
}

/// The result of looking at a source: where the game is, which tables it has, what is missing.
public struct SourceScan: Sendable {
    /// Human-readable layout, e.g. "ISO 9660 image (CD-RTOS CD-BRIDGE, volume EPICPINCD21), game files in the root".
    public var layout: String
    /// Short machine tag: "iso", "directory", "directory-subfolder", "disc-image-in-directory".
    public var kind: String
    /// Folder (relative to the source, or to the disc image) that holds EPn.EXE; "" = root.
    public var gameFolder: String
    /// Disc image used inside a directory source (GOG .gog/.iso/.bin), relative path.
    public var discImage: String?
    public var volumeIdentifier: String?
    /// Tables whose EPn.EXE and EPn.DAT are both present.
    public var tables: [Int]
    /// Of 1...13, the tables that cannot be imported.
    public var missingTables: [Int]
    /// Per table, optional runtime files that are missing (IDn.DAT, SFXn.PIN, SONGn.PSM).
    public var missingOptional: [Int: [String]]
    /// EP*.EXE files outside 1...13 (not a table this importer knows).
    public var extraFiles: [String]
    public var warnings: [String]

    public static let tableRange = 1...13
}

enum SourceScanner {
    static let imageExtensions: Set<String> = ["iso", "gog", "bin", "img", "cdr"]

    static func tableNumbers(in names: [String]) -> (known: Set<Int>, extra: [String]) {
        var known = Set<Int>(), extra: [String] = []
        for n in names where n.hasPrefix("ep") && n.hasSuffix(".exe") {
            let mid = n.dropFirst(2).dropLast(4)
            guard !mid.isEmpty, mid.allSatisfy(\.isNumber), let v = Int(mid) else { continue }
            if SourceScan.tableRange.contains(v) { known.insert(v) } else { extra.append(n.uppercased()) }
        }
        return (known, extra.sorted())
    }

    /// The folder with the most EPn.EXE (shallowest on ties).
    static func bestFolder(_ files: SourceFiles) -> (String, Set<Int>, [String])? {
        var best: (String, Set<Int>, [String])? = nil
        for d in files.directories.sorted(by: { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }) {
            let (k, x) = tableNumbers(in: files.names(in: d))
            if k.isEmpty { continue }
            if best == nil || k.count > best!.1.count { best = (d, k, x) }
        }
        return best
    }

    static func join(_ dir: String, _ name: String) -> String { dir.isEmpty ? name : dir + "/" + name }

    static func describe(_ iso: ISO9660Image) -> String {
        var parts = ["ISO 9660 image"]
        var meta: [String] = []
        if !iso.systemIdentifier.isEmpty { meta.append(iso.systemIdentifier) }
        if !iso.volumeIdentifier.isEmpty { meta.append("volume \(iso.volumeIdentifier)") }
        if iso.sectorLayout != "2048" { meta.append("\(iso.sectorLayout) sectors") }
        if !meta.isEmpty { parts.append("(" + meta.joined(separator: ", ") + ")") }
        return parts.joined(separator: " ")
    }

    /// Opens the source and locates the game folder. Throws if no table can be found.
    static func open(_ source: ImportSource) throws -> (SourceFiles, SourceScan) {
        switch source {
        case let .isoImage(url):
            let iso = try ISO9660Image(url: url)
            let files = SourceFiles(iso: iso)
            guard let (dir, _, _) = bestFolder(files) else {
                throw ImportError("\(url.lastPathComponent): no Epic Pinball table files (EP1.EXE ... EP13.EXE) on this disc image")
            }
            var scan = summarize(files, folder: dir, kind: "iso", layout: describe(iso) + (dir.isEmpty ? ", game files in the root" : ", game files in \(dir)/"))
            scan.volumeIdentifier = iso.volumeIdentifier
            return (files, scan)
        case let .directory(url):
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw ImportError("\(url.path) does not exist") }
            if !isDir.boolValue {
                // a disc image passed as a "directory"
                return try open(.isoImage(url))
            }
            let files = SourceFiles(directory: url)
            let plain = bestFolder(files)
            // disc images inside the folder (GOG ships some DOS games as game.gog + game.ins)
            var bestImage: (String, ISO9660Image, SourceFiles, String, Int)? = nil
            if plain == nil || plain!.1.count < SourceScan.tableRange.count {
                for (_, f) in files.files.sorted(by: { $0.key < $1.key }) where imageExtensions.contains((f.path as NSString).pathExtension.lowercased()) && f.size > 1_000_000 {
                    guard let iso = try? ISO9660Image(url: url.appendingPathComponent(f.path)) else { continue }
                    let inner = SourceFiles(iso: iso)
                    if let (d, k, _) = bestFolder(inner), k.count > (bestImage?.4 ?? 0) { bestImage = (f.path, iso, inner, d, k.count) }
                }
            }
            if let img = bestImage, img.4 > (plain?.1.count ?? 0) {
                var scan = summarize(img.2, folder: img.3, kind: "disc-image-in-directory",
                                     layout: "folder with a disc image: \(img.0), " + describe(img.1) + (img.3.isEmpty ? "" : ", game files in \(img.3)/"))
                scan.discImage = img.0
                scan.volumeIdentifier = img.1.volumeIdentifier
                return (img.2, scan)
            }
            guard let (dir, _, _) = plain else {
                throw ImportError("\(url.path): no Epic Pinball table files (EP1.EXE ... EP13.EXE) in this folder, its subfolders or a disc image in it")
            }
            let layout = dir.isEmpty ? "folder with the game files (installed game or mounted CD)"
                                     : "folder with the game files in the subfolder \(dir)/ (e.g. a GOG install)"
            return (files, summarize(files, folder: dir, kind: dir.isEmpty ? "directory" : "directory-subfolder", layout: layout))
        }
    }

    static func summarize(_ files: SourceFiles, folder: String, kind: String, layout: String) -> SourceScan {
        let names = Set(files.names(in: folder))
        let (known, extra) = tableNumbers(in: Array(names))
        var tables: [Int] = [], missing: [Int] = [], optional: [Int: [String]] = [:], warnings: [String] = []
        for n in SourceScan.tableRange {
            guard known.contains(n) else { missing.append(n); continue }
            if !names.contains("ep\(n).dat") {
                missing.append(n)
                warnings.append("table \(n): EP\(n).EXE is present but EP\(n).DAT (its preview screen, used to verify the palette) is missing")
                continue
            }
            tables.append(n)
            let opt = ["ID\(n).DAT", "SFX\(n).PIN", "SONG\(n).PSM"].filter { !names.contains($0.lowercased()) }
            if !opt.isEmpty { optional[n] = opt }
        }
        for n in missing where !known.contains(n) { warnings.append("table \(n): EP\(n).EXE not found") }
        for (n, o) in optional.sorted(by: { $0.key < $1.key }) {
            warnings.append("table \(n): missing \(o.joined(separator: ", "))" + (o.contains { $0.hasPrefix("SFX") || $0.hasPrefix("SONG") } ? " (no sound for this table)" : ""))
        }
        for f in extra { warnings.append("\(f): not one of the 13 tables of the Complete Collection; ignored") }
        if !names.contains("sfx0.pin") || !names.contains("song0.psm") { warnings.append("launcher sounds SFX0.PIN / SONG0.PSM not found") }
        return SourceScan(layout: layout, kind: kind, gameFolder: folder, discImage: nil, volumeIdentifier: nil, tables: tables,
                          missingTables: missing, missingOptional: optional, extraFiles: extra, warnings: warnings)
    }
}
