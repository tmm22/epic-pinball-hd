import Foundation
import XCTest

/// Paths of the developer checkout (tests skip cleanly when the user's data is absent).
enum Repo {
    /// app/Tests/PinballImportTests/TestSupport.swift -> repo root
    static let root: URL = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var original: URL { root.appendingPathComponent("original", isDirectory: true) }
    static var extracted: URL { root.appendingPathComponent("extracted", isDirectory: true) }
    static var python: URL { root.appendingPathComponent(".venv/bin/python") }
    static var iso: URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: root.path) else { return nil }
        return items.filter { $0.lowercased().hasSuffix(".iso") }.sorted().first.map { root.appendingPathComponent($0) }
    }
    static var scratch: URL { root.appendingPathComponent("scratch/importer", isDirectory: true) }

    static func requireOriginal(file: StaticString = #filePath, line: UInt = #line) throws {
        guard FileManager.default.fileExists(atPath: original.appendingPathComponent("EP1.EXE").path) else {
            throw XCTSkip("original/EP1.EXE not present (user data absent)")
        }
    }
    static func requireExtracted() throws {
        guard FileManager.default.fileExists(atPath: extracted.appendingPathComponent("tables/EP1/engine.json").path) else {
            throw XCTSkip("extracted/ reference data not present")
        }
    }

    /// Runs the repo's Python with a script; nil if Python (or the module the script needs) is missing.
    static func runPython(_ script: String, args: [String] = []) -> (status: Int32, out: String)? {
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return nil }
        let p = Process()
        p.executableURL = python
        p.arguments = ["-c", script] + args
        p.currentDirectoryURL = root
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
