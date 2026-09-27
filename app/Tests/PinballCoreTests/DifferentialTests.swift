import Foundation
import XCTest
@testable import PinballCore

/// Differential regression tests: the Swift port against the ORIGINAL EP1 machine code.
///
/// * `testMatchesOriginalCodeLive` runs every scenario in tools/emu/scenarios/ and
///   tools/emu/scenarios_pathological/ through the emulator harness (tools/emu/run_scenario.py
///   --batch, which executes the user's own original/EP1.EXE under Unicorn) and through
///   `TraceRunner`, and requires identical traces. Skipped when the venv, the EXE or the
///   extracted data are missing, or when EP_SKIP_LIVE_DIFF is set.
/// * `testMatchesGoldenTraces` does the same against traces saved by
///   `tools/emu/diff_traces.py --save-golden` in scratch/diff/golden/ (no Python needed).
///
/// Scenarios on which the original never returns from physics_step (push-out livelock) end
/// with a `{"orig_error":"hang",...}` line: the port must match every earlier record and flag
/// `extra.loop_guard` in the record of that step. A divide fault (`"fault"`) is handled alike
/// with `extra.divide_faults`.
final class DifferentialTests: XCTestCase {
    static let project = DataLocator.packageRelativeDefault.deletingLastPathComponent()
    static let dataRoot = DataLocator.packageRelativeDefault
    static let scenarioDirs = ["tools/emu/scenarios", "tools/emu/scenarios_pathological"]
    /// Port-only diagnostics that the original's traces never contain.
    static let portOnly: Set<String> = ["loop_guard", "divide_faults"]

    static func scenarioURLs() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for d in scenarioDirs {
            let dir = project.appendingPathComponent(d)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            out += names.filter { $0.hasSuffix(".json") }.sorted().map { dir.appendingPathComponent($0) }
        }
        return out
    }

    static func parseLines(_ text: String) -> [[String: Any]] {
        text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    /// Flattens a record to "field" -> value for comparison and messages.
    static func flatten(_ r: [String: Any]) -> [String: NSObject] {
        var d: [String: NSObject] = [:]
        for (k, v) in r {
            if let sub = v as? [String: Any] {
                for (k2, v2) in sub where !(k == "extra" && portOnly.contains(k2)) { d["\(k).\(k2)"] = v2 as? NSObject ?? NSNull() }
            } else {
                d[k] = v as? NSObject ?? NSNull()
            }
        }
        return d
    }

    /// Compares the port's trace for one scenario with the original's. Returns nil when they
    /// match (including the hang/fault rule), else a description of the first divergence.
    static func compare(reference ref: [[String: Any]], port: [[String: Any]]) -> String? {
        var orig = ref
        var error: [String: Any]?
        if let last = orig.last, last["orig_error"] != nil { error = last; orig.removeLast() }
        for i in 0..<min(orig.count, port.count) {
            let a = flatten(orig[i]), b = flatten(port[i])
            if a != b {
                let keys = Set(a.keys).union(b.keys).sorted().filter { a[$0] != b[$0] }
                let fields = keys.map { "\($0): \(a[$0].map { "\($0)" } ?? "-") vs \(b[$0].map { "\($0)" } ?? "-")" }
                return "record \(i) (frame \(orig[i]["frame"] ?? "?") step \(orig[i]["step"] ?? "?")) differs (original vs port): "
                    + fields.joined(separator: ", ")
            }
        }
        if let error {
            let kind = error["orig_error"] as? String ?? "?"
            let key = kind == "hang" ? "loop_guard" : "divide_faults"
            guard port.count > orig.count else {
                return "the original \(kind)s after \(orig.count) records, the port trace has only \(port.count)"
            }
            let flagged = ((port[orig.count]["extra"] as? [String: Any])?[key] as? Int ?? 0) > 0
            return flagged ? nil : "the original \(kind)s at record \(orig.count), but the port does not flag extra.\(key) there"
        }
        if orig.count != port.count { return "identical records, but \(orig.count) (original) vs \(port.count) (port)" }
        return nil
    }

    /// Runs all scenarios through the port and compares with `<name>.jsonl` in `refDir`.
    func runComparisons(refDir: URL) throws -> (compared: Int, failures: [String]) {
        let engine = try EngineAssets.makeEngine(dataRoot: Self.dataRoot, table: 1)
        var compared = 0
        var failures: [String] = []
        for url in Self.scenarioURLs() {
            let name = url.deletingPathExtension().lastPathComponent
            guard let refText = try? String(contentsOf: refDir.appendingPathComponent("\(name).jsonl"), encoding: .utf8) else { continue }
            let sc = try Scenario.load(contentsOf: url)
            guard sc.table == 1 else { continue }
            let port = Self.parseLines(TraceRunner.run(sc, engine: engine))
            if let msg = Self.compare(reference: Self.parseLines(refText), port: port) {
                failures.append("\(name): \(msg)")
            }
            compared += 1
        }
        return (compared, failures)
    }

    func requireData() throws {
        guard FileManager.default.fileExists(atPath: Self.dataRoot.appendingPathComponent("tables/EP1/engine.json").path),
              FileManager.default.fileExists(atPath: Self.dataRoot.appendingPathComponent("tables/EP1/collision_idx.npy").path) else {
            throw XCTSkip("no extracted EP1 data (engine.json, collision_idx.npy)")
        }
        if Self.scenarioURLs().isEmpty { throw XCTSkip("no scenarios in tools/emu/") }
    }

    func testMatchesOriginalCodeLive() throws {
        try requireData()
        if ProcessInfo.processInfo.environment["EP_SKIP_LIVE_DIFF"] != nil { throw XCTSkip("EP_SKIP_LIVE_DIFF is set") }
        let fm = FileManager.default
        let python = Self.project.appendingPathComponent(".venv/bin/python")
        let runner = Self.project.appendingPathComponent("tools/emu/run_scenario.py")
        guard fm.isExecutableFile(atPath: python.path), fm.fileExists(atPath: runner.path),
              fm.fileExists(atPath: Self.project.appendingPathComponent("original/EP1.EXE").path) else {
            throw XCTSkip("needs .venv/bin/python (with unicorn), tools/emu/run_scenario.py and original/EP1.EXE")
        }
        let out = fm.temporaryDirectory.appendingPathComponent("ep-diff-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: out) }
        let p = Process()
        p.executableURL = python
        p.currentDirectoryURL = Self.project
        p.arguments = [runner.path, "--batch", out.path] + Self.scenarioDirs.map { Self.project.appendingPathComponent($0).path }
        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        try p.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self)
            if msg.contains("No module named") { throw XCTSkip("harness dependencies missing: \(msg.suffix(200))") }
            XCTFail("harness failed (\(p.terminationStatus)): \(msg.suffix(600))")
            return
        }
        let (compared, failures) = try runComparisons(refDir: out)
        XCTAssertGreaterThan(compared, 0, "harness wrote no traces")
        for f in failures { XCTFail(f) }
    }

    func testMatchesGoldenTraces() throws {
        try requireData()
        let dir = Self.project.appendingPathComponent("scratch/diff/golden")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw XCTSkip("no golden traces; run `.venv/bin/python tools/emu/diff_traces.py --save-golden`")
        }
        let (compared, failures) = try runComparisons(refDir: dir)
        if compared == 0 { throw XCTSkip("no golden trace matches a scenario") }
        for f in failures { XCTFail(f) }
    }

    /// The comparison rules themselves (synthetic records, no data needed).
    func testCompareRules() {
        func rec(_ f: Int, _ x: Int, extra: [String: Any] = [:]) -> [String: Any] {
            ["frame": f, "step": 0, "ball": ["x": x, "y": 1], "k": NSNull(), "extra": extra]
        }
        XCTAssertNil(Self.compare(reference: [rec(0, 1), rec(1, 2)], port: [rec(0, 1), rec(1, 2)]))
        XCTAssertNotNil(Self.compare(reference: [rec(0, 1), rec(1, 2)], port: [rec(0, 1), rec(1, 3)]))
        XCTAssertNotNil(Self.compare(reference: [rec(0, 1)], port: [rec(0, 1), rec(1, 3)]))
        let hang: [String: Any] = ["orig_error": "hang", "frame": 1, "step": 0]
        XCTAssertNil(Self.compare(reference: [rec(0, 1), hang], port: [rec(0, 1), rec(1, 9, extra: ["loop_guard": 1])]))
        XCTAssertNotNil(Self.compare(reference: [rec(0, 1), hang], port: [rec(0, 1), rec(1, 9)]))
        // port-only keys are ignored in ordinary records
        XCTAssertNil(Self.compare(reference: [rec(0, 1)], port: [rec(0, 1, extra: ["divide_faults": 1])]))
    }
}
