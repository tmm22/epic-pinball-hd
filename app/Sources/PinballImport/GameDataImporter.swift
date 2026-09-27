// PinballImport: turns the user's own Epic Pinball files (CD image, installed
// folder, or GOG install) into the runtime data the app needs, entirely in
// Swift (no Python). Output goes to a per-user library directory, never into
// the app bundle.
//
// Shared contract between the importer (producer) and the front end's
// first-launch flow (consumer). Extend additively.
import Foundation
import PinballCore

public enum ImportSource: Sendable, Equatable {
    /// An ISO 9660 CD image (e.g. the 1995 "Complete Collection" CD).
    case isoImage(URL)
    /// A directory that contains EP1.EXE ... (DOS install, mounted CD, GOG game dir).
    case directory(URL)
}

public struct ImportProgress: Sendable {
    public var fraction: Double
    public var message: String
    public init(fraction: Double, message: String) { self.fraction = fraction; self.message = message }
}

public struct ImportedTable: Sendable, Equatable {
    public var number: Int          // 1...13
    public var name: String         // from IDn.DAT (read from the user's files)
    public var dataDirectory: URL   // per-table output directory
    public init(number: Int, name: String, dataDirectory: URL) {
        self.number = number; self.name = name; self.dataDirectory = dataDirectory
    }
}

public struct ImportedLibrary: Sendable, Equatable {
    /// Root of the imported library (layout mirrors ../extracted/tables/EPn and
    /// keeps a copy/reference of the original files the engine reads at runtime).
    public var root: URL
    public var tables: [ImportedTable]
    public var warnings: [String]
    public init(root: URL, tables: [ImportedTable], warnings: [String]) {
        self.root = root; self.tables = tables; self.warnings = warnings
    }
}

public protocol GameDataImporting: Sendable {
    /// Quick check that a source looks like a supported Epic Pinball release.
    func validate(_ source: ImportSource) throws -> [String]
    /// Full import into `destination`; calls `progress` from any thread.
    func importGame(from source: ImportSource, to destination: URL,
                    progress: @Sendable (ImportProgress) -> Void) throws -> ImportedLibrary
}

public enum LibraryLocation {
    /// Default per-user library: ~/Library/Application Support/EpicPinballHD/Library
    public static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("EpicPinballHD/Library", isDirectory: true)
    }
}
