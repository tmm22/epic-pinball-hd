import Foundation

/// Fixed geometry of every Epic Pinball table (confirmed for all 13 extracted
/// playfields: raw 320x400 8bpp, shown through a 320x200 Mode X window).
public enum TableGeometry {
    public static let width = 320
    public static let height = 400
    /// Height of the original's visible scrolling window.
    public static let windowHeight = 200
    public static let tableCount = 13
}

/// Playfield art + palette for one table, loaded at runtime from the user's own
/// extracted data. Nothing here is ever bundled with the app.
public struct TableAssets: Sendable {
    public let table: Int
    /// 8-bit palette indices, row-major, `TableGeometry.width * TableGeometry.height`.
    public let indices: [UInt8]
    public var palette: Palette
    public let directory: URL

    public init(table: Int, indices: [UInt8], palette: Palette, directory: URL) {
        self.table = table
        self.indices = indices
        self.palette = palette
        self.directory = directory
    }

    /// Loads `<dataRoot>/tables/EP<table>/{playfield_idx.npy,palette.json}`.
    public static func load(dataRoot: URL, table: Int) throws -> TableAssets {
        guard (1...TableGeometry.tableCount).contains(table) else { throw AssetError.badTable(table) }
        let dir = dataRoot.appendingPathComponent("tables/EP\(table)", isDirectory: true)
        let npyURL = dir.appendingPathComponent("playfield_idx.npy")
        let palURL = dir.appendingPathComponent("palette.json")
        let fm = FileManager.default
        for url in [npyURL, palURL] where !fm.fileExists(atPath: url.path) {
            throw AssetError.missingFile(url, dataRoot: dataRoot)
        }
        let array: NPYArray2D
        do { array = try NPYReader.read(contentsOf: npyURL) } catch {
            throw AssetError.invalidFile(npyURL, String(describing: error))
        }
        guard array.rows == TableGeometry.height, array.columns == TableGeometry.width else {
            throw AssetError.invalidFile(npyURL, "shape is (\(array.rows), \(array.columns)), expected (\(TableGeometry.height), \(TableGeometry.width))")
        }
        let palette: Palette
        do { palette = try Palette.load(contentsOf: palURL) } catch {
            throw AssetError.invalidFile(palURL, String(describing: error))
        }
        return TableAssets(table: table, indices: array.data, palette: palette, directory: dir)
    }
}

public enum AssetError: Error, CustomStringConvertible {
    case badTable(Int)
    case missingDataRoot([URL])
    case missingFile(URL, dataRoot: URL)
    case invalidFile(URL, String)

    public var description: String {
        switch self {
        case let .badTable(n):
            return "table \(n) is out of range - choose 1...\(TableGeometry.tableCount)"
        case let .missingDataRoot(tried):
            return """
            could not find extracted game data. Tried:
            \(tried.map { "  - \($0.path)" }.joined(separator: "\n"))
            Extract your own copy of the game first (tools/extract.py writes extracted/tables/EPn/), \
            then pass --data <dir> pointing at the 'extracted' directory.
            """
        case let .missingFile(url, root):
            return """
            missing \(url.path)
            (data root: \(root.path)). Run tools/extract.py on your own copy of the game, \
            or pass --data <dir> pointing at the 'extracted' directory.
            """
        case let .invalidFile(url, why):
            return "could not read \(url.path): \(why)"
        }
    }
}

/// Resolves the data root (the `extracted/` directory).
public enum DataLocator {
    /// `<package>/../extracted`, derived from this source file's compile-time path
    /// (`app/Sources/PinballCore/TableAssets.swift` -> `app/../extracted`).
    public static var packageRelativeDefault: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PinballCore
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // app (package root)
            .deletingLastPathComponent() // project root
            .appendingPathComponent("extracted", isDirectory: true)
            .standardizedFileURL
    }

    /// Candidate roots in priority order when no `--data` flag was given.
    public static func defaultCandidates(currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                                         environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var out: [URL] = []
        if let env = environment["EPIC_PINBALL_DATA"], !env.isEmpty { out.append(URL(fileURLWithPath: env, isDirectory: true)) }
        out.append(packageRelativeDefault)
        out.append(currentDirectory.appendingPathComponent("../extracted", isDirectory: true).standardizedFileURL)
        out.append(currentDirectory.appendingPathComponent("extracted", isDirectory: true).standardizedFileURL)
        var seen = Set<String>()
        return out.filter { seen.insert($0.path).inserted }
    }

    /// Returns the explicit root if given (without checking it - `TableAssets.load`
    /// reports precisely which file is missing), else the first existing candidate
    /// that contains a `tables` directory.
    public static func resolve(explicit: String?) throws -> URL {
        if let explicit {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        let candidates = defaultCandidates()
        var isDir: ObjCBool = false
        for c in candidates where FileManager.default.fileExists(atPath: c.appendingPathComponent("tables").path, isDirectory: &isDir) && isDir.boolValue {
            return c
        }
        throw AssetError.missingDataRoot(candidates)
    }
}
