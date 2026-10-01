import Foundation
import XCTest
@testable import PinballCore

/// Palette fades (`PaletteFade` in the rules presentation) against the original in the harness
/// (tools/emu/dot_effects.py --games): the 6-bit working palette after boot and after every frame of
/// a drain, the end of the ball and the next plunge.
final class PaletteFadeTests: XCTestCase {
    func testLayouts() throws {
        var found = 0
        for n in 1...13 {
            guard let exe = RulesDirectTests.exe(n), let image = try? ExeImage(exe: exe) else { continue }
            found += 1
            let f = PaletteFade.find(code: image.code)
            print("PaletteFade EP\(n): " + (f.map { "W \(String($0.working, radix: 16)) B \(String($0.base, radix: 16)) flag "
                + "\($0.flag.map { String($0, radix: 16) } ?? "-") passes \($0.fadeInPasses)/\($0.dimPasses)" } ?? "none"))
            if n == 1 { XCTAssertEqual(f, PaletteFade(base: 0x0DC0, working: 0x5012, flag: 0x096F, fadeInPasses: 17, dimPasses: 3)) }
        }
        if found == 0 { throw XCTSkip("no original EXEs") }
    }

    /// The fade arithmetic (EP1 cs:1320..1335 and cs:32F1..32FF) on single values.
    func testArithmetic() {
        let f = PaletteFade(base: 0, working: 0, flag: 1, fadeInPasses: 17, dimPasses: 3)
        XCTAssertEqual(f.bootPalette(base: [252, 128, 0] + [UInt8](repeating: 0, count: 765)).prefix(3), [60, 32, 0])
        var w: [UInt8] = [60, 32, 0, 1]
        f.dim(&w)
        XCTAssertEqual(w, [39, 20, 0, 0])   // 60 -> 52 -> 45 -> 39
        XCTAssertEqual(f.restored(base: [252, 128, 3]), [63, 32, 0])
    }

    func testMatchesOriginalLive() throws {
        if ProcessInfo.processInfo.environment["EP_SKIP_LIVE_DIFF"] != nil { throw XCTSkip("EP_SKIP_LIVE_DIFF is set") }
        let project = DotEffectsTests.project, fm = FileManager.default
        let python = project.appendingPathComponent(".venv/bin/python"), tool = project.appendingPathComponent("tools/emu/dot_effects.py")
        guard fm.isExecutableFile(atPath: python.path), fm.fileExists(atPath: tool.path) else { throw XCTSkip("needs .venv and tools/emu") }
        var games: [[String: Any]] = [], tables: [Int] = []
        for n in 1...13 {
            guard let exe = RulesDirectTests.exe(n), let image = try? ExeImage(exe: exe), let f = PaletteFade.find(code: image.code),
                  (try? EngineAssets.makeEngine(dataRoot: DataLocator.packageRelativeDefault, table: n)) != nil else { continue }
            var pal: [String: Any] = ["working": f.working]
            if let fl = f.flag { pal["flag"] = fl }
            // drain at once, then hold the plunger for the next ball and let go
            let inputs = [Int](repeating: 0, count: 330) + [Int](repeating: 4, count: 40)
            games.append(["table": n, "frames": 420, "mode": "full", "on_drain": "continue", "inputs": inputs, "palette": pal,
                          "ball": ["x": 150, "y": 330, "vx": 0, "vy": 300, "layer": 0]])
            tables.append(n)
        }
        guard !games.isEmpty else { throw XCTSkip("no tables") }
        let dir = fm.temporaryDirectory.appendingPathComponent("ep-palfade-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let input = dir.appendingPathComponent("games.json"), output = dir.appendingPathComponent("out.json")
        try JSONSerialization.data(withJSONObject: games).write(to: input)
        let p = Process()
        p.executableURL = python
        p.currentDirectoryURL = project
        p.arguments = [tool.path, "--games", input.path, "-o", output.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { XCTFail("harness failed: \(String(decoding: errData, as: UTF8.self).suffix(600))"); return }
        let results = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [[String: Any]])
        for backend in RulesBackend.allCases {
            for (k, n) in tables.enumerated() {
                let e = try EngineAssets.makeEngine(dataRoot: DataLocator.packageRelativeDefault, table: n, rules: false)
                let r = try RulesRuntime.load(dataRoot: DataLocator.packageRelativeDefault, table: n, backend: backend)
                r.attach(to: e, mode: .off)
                let sc = try Scenario.parse(JSONSerialization.data(withJSONObject: games[k]))
                sc.apply(to: e)
                let frames = results[k]["frames"] as? [[String: Any]] ?? []
                var same = 0, dims = 0, restores = 0, firstBad: String?
                var lastFlag = -1
                for (f, want) in frames.enumerated() {
                    e.input = sc.input(frame: f)
                    e.runFrame()
                    _ = e.takePresentation()
                    let w = want["working"] as? [Int] ?? []
                    if ProcessInfo.processInfo.environment["EP_DBG"] != nil, let fl = r.paletteFade?.flag, let wf = want["flag"] as? Int,
                       Int(r.machine.read8(fl)) != wf { print("DBG EP\(n) \(backend) frame \(f): port flag \(r.machine.read8(fl)) original \(wf)") }
                    if let fl = want["flag"] as? Int {
                        if lastFlag == 0 && fl == 1 { dims += 1 }
                        if lastFlag == 1 && fl == 0 { restores += 1 }
                        lastFlag = fl
                    }
                    // EP8's ring entries rotate (PaletteCycle, reported separately): not part of the fade model.
                    let ring = r.paletteCycle.map { (3 * $0.firstIndex)..<(3 * ($0.firstIndex + $0.colours)) } ?? 0..<0
                    let got = r.fadedPalette ?? []
                    let diff = (0..<min(got.count, w.count)).filter { !ring.contains($0) && Int(got[$0]) != w[$0] }
                    if got.count == w.count && diff.isEmpty { same += 1 } else if firstBad == nil {
                        firstBad = "frame \(f) flag \(want["flag"] ?? "-"): \(diff.count) components differ"
                            + (diff.first.map { " (first \($0): port \(got[$0]) original \(w[$0]))" } ?? "")
                    }
                }
                print("PaletteFade EP\(n) \(backend): \(same)/\(frames.count) frames identical, \(dims) dims, \(restores) restores"
                      + (firstBad.map { "; " + $0 } ?? ""))
                XCTAssertNil(firstBad, "EP\(n) \(backend)")
            }
        }
    }
}
