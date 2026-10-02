import Foundation
import XCTest
@testable import PinballCore

/// The visible whole-screen fades (`ScreenFade`) against the original in the harness
/// (tools/emu/screen_fades.py): the DAC at every wait_frame of the boot, the state the boot leaves, and
/// every pass of the quit path's fade-out with entry counts 0 and FFh.
final class ScreenFadeTests: XCTestCase {
    func testLayouts() throws {
        var found = 0
        for n in 1...13 {
            guard let exe = RulesDirectTests.exe(n), let image = try? ExeImage(exe: exe) else { continue }
            found += 1
            let f = try XCTUnwrap(ScreenFade.find(code: image.code, ds: image.dsBytes), "EP\(n)")
            print("ScreenFade EP\(n): W \(String(f.working, radix: 16)) B \(String(f.base, radix: 16)) in \(f.fadeInPasses)>>\(f.fadeInShift)"
                  + "\(f.fadeInDuringIntro ? " (intro)" : "") intro \(f.introFrames) out \(f.fadeOutPasses) count \(String(f.fadeOutCount, radix: 16))"
                  + " score \(f.scoreScreenPass.map(String.init) ?? "-") ring calls \(f.introRingCalls)")
            XCTAssertEqual(f.fadeOutPasses, 18, "EP\(n)")
            XCTAssertEqual(f.fadeInDuringIntro, n >= 9, "EP\(n)")
            if n == 1 {
                XCTAssertEqual(f.working, 0x5012); XCTAssertEqual(f.base, 0x0DC0); XCTAssertEqual(f.fadeInPasses, 17)
                XCTAssertEqual(f.fadeOutCount, 0x0AD3); XCTAssertEqual(f.scoreScreenPass, 5); XCTAssertEqual(f.introFrames, 177)
            }
        }
        if found == 0 { throw XCTSkip("no original EXEs") }
    }

    /// The pass arithmetic (EP1 cs:1320..1335 fade-in, cs:137A..1388 fade-out) on single values.
    func testArithmetic() {
        let f = ScreenFade(base: 0, working: 0, fadeInPasses: 17, fadeInShift: 3, fadeInDuringIntro: false, introFrames: 0,
                           darkenShift: nil, fadeOutPasses: 18, fadeOutCount: 0, fadeOutCountInitial: 0, scoreScreenPass: 5)
        var m = ScreenFade.Machine(working: [UInt8](repeating: 0, count: 768), dac: [UInt8](repeating: 0, count: 768))
        var base = [UInt8](repeating: 0, count: 768)
        base[0] = 252; base[1] = 128
        f.fadeInPass(&m, base: base)
        XCTAssertEqual(Array(m.dac.prefix(3)), [8, 5, 0])   // 63>>3 + 1, 32>>3 + 1
        m.working[0] = 60; m.working[765] = 9
        _ = f.fadeOut(&m, count: 255, passes: 0..<1)
        XCTAssertEqual(m.working[0], 52)
        XCTAssertEqual(m.working[765], 9)   // entry 255 left alone with count FFh
    }

    /// The app's sequence: the boot fade-in blocks play for its frames and starts from its first frame; a game-over
    /// fade-out runs its first passes, holds, and the next boot runs the rest before the fade-in.
    func testPlayerSequence() {
        let f = ScreenFade(base: 0, working: 0, fadeInPasses: 17, fadeInShift: 3, fadeInDuringIntro: false, introFrames: 0,
                           darkenShift: nil, fadeOutPasses: 18, fadeOutCount: 0, fadeOutCountInitial: 0, scoreScreenPass: 5)
        var ds = [UInt8](repeating: 0, count: 768)
        for i in 0..<768 { ds[i] = UInt8(4 * (i % 64)) }
        var p = ScreenFadePlayer(fade: f, ds: ds)
        XCTAssertEqual(p.bootFrames.count, 17)
        XCTAssertNil(p.current)
        p.boot()
        XCTAssertEqual(p.current?.count, 256, "boot: all 256 entries")
        XCTAssertEqual(p.current, ScreenFade.overrides(p.bootFrames[0]))
        var shown = 1
        while p.blocksPlay { p.step(); shown += 1 }
        XCTAssertEqual(shown, 17)
        XCTAssertEqual(p.current, ScreenFade.overrides(p.bootFrames[16]))
        p.step()
        XCTAssertNil(p.current, "after the fade-in the rules' palette")
        // game over: 5 passes over entries 0..254, then the palette stays
        let start = ScreenFade.Machine(working: p.bootFrames[16], dac: p.bootFrames[16])
        p.gameOver(from: start)
        XCTAssertEqual(p.current?.count, 255, "DAC 255 is left alone")
        var out = 1
        while p.blocksPlay { p.step(); out += 1 }
        XCTAssertEqual(out, 5)
        let held = p.current
        for _ in 0..<10 { p.step() }
        XCTAssertEqual(p.current, held)
        XCTAssertTrue(p.holding)
        // next game: 13 more passes, then the fade-in
        p.boot()
        var seq = [p.current]
        while p.blocksPlay { p.step(); seq.append(p.current) }
        XCTAssertEqual(seq.count, 13 + 17)
        XCTAssertFalse(p.holding)
        var m = start
        let all = f.fadeOut(&m, count: 0xFF, passes: 0..<18)
        XCTAssertEqual(held, ScreenFade.overrides(all[4], count: 0xFF), "held after pass 5")
        XCTAssertEqual(seq[12], ScreenFade.overrides(all[17], count: 0xFF), "the 18th pass")
        XCTAssertEqual(seq[13], ScreenFade.overrides(p.bootFrames[0]), "then the fade-in")
        // EP9-EP13: no passes before the (earlier) final-score screen, all 18 at the next boot
        var g = f
        g.scoreScreenPass = nil
        var q = ScreenFadePlayer(fade: g, ds: ds)
        q.gameOver(from: start)
        XCTAssertNil(q.current)
        XCTAssertFalse(q.blocksPlay)
        q.boot()
        var n = 1
        while q.blocksPlay { q.step(); n += 1 }
        XCTAssertEqual(n, 18 + 17)
        q.gameOver(from: start)
        q.cancel()
        XCTAssertFalse(q.holding)
        XCTAssertNil(q.current)
    }

    func testMatchesOriginalLive() throws {
        if ProcessInfo.processInfo.environment["EP_SKIP_LIVE_DIFF"] != nil { throw XCTSkip("EP_SKIP_LIVE_DIFF is set") }
        let project = DotEffectsTests.project, fm = FileManager.default
        let python = project.appendingPathComponent(".venv/bin/python"), tool = project.appendingPathComponent("tools/emu/screen_fades.py")
        guard fm.isExecutableFile(atPath: python.path), fm.fileExists(atPath: tool.path) else { throw XCTSkip("needs .venv and tools/emu") }
        var tables: [Int] = [], fades: [ScreenFade] = [], images: [ExeImage] = []
        for n in 1...13 {
            guard let exe = RulesDirectTests.exe(n), let image = try? ExeImage(exe: exe),
                  let f = ScreenFade.find(code: image.code, ds: image.dsBytes) else { continue }
            tables.append(n); fades.append(f); images.append(image)
        }
        guard !tables.isEmpty else { throw XCTSkip("no tables") }
        let out = fm.temporaryDirectory.appendingPathComponent("ep-screenfade-\(ProcessInfo.processInfo.processIdentifier).json")
        defer { try? fm.removeItem(at: out) }
        let p = Process()
        p.executableURL = python
        p.currentDirectoryURL = project
        p.arguments = [tool.path, "--tables", tables.map(String.init).joined(separator: ","), "-o", out.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { XCTFail("harness failed: \(String(decoding: errData, as: UTF8.self).suffix(600))"); return }
        let results = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [[String: Any]])
        func hex(_ s: Any?) -> [UInt8] {
            guard let s = s as? String else { return [] }
            var o: [UInt8] = [], it = s.makeIterator()
            while let a = it.next(), let b = it.next() { o.append(UInt8(String([a, b]), radix: 16) ?? 0) }
            return o
        }
        func machine(_ d: Any?) -> ScreenFade.Machine {
            let d = d as? [String: Any] ?? [:]
            return ScreenFade.Machine(working: hex(d["working"]), dac: hex(d["dac"]),
                                      counter: UInt8(d["counter"] as? Int ?? 0), speed: UInt8(d["speed"] as? Int ?? 0))
        }
        /// nil when equal, else the count and the first differing index.
        func diff(_ a: [UInt8], _ b: [UInt8]) -> String? {
            guard a != b else { return nil }
            let d = (0..<max(a.count, b.count)).filter { $0 >= a.count || $0 >= b.count || a[$0] != b[$0] }
            let i = d[0]
            return "\(d.count) bytes differ, first \(i): port \(i < a.count ? Int(a[i]) : -1) original \(i < b.count ? Int(b[i]) : -1)"
        }
        func check(_ a: [UInt8], _ b: [UInt8], _ what: @autoclosure () -> String) {
            if let d = diff(a, b) { XCTFail("\(what()): \(d)") }
        }
        var frames = 0
        for (k, n) in tables.enumerated() {
            let f = fades[k], r = results[k]
            let boot = f.boot(ds: images[k].dsBytes)
            let orig = (r["boot"] as? [[String: Any]] ?? []).map { hex($0["dac"]) }
            // EP1-EP8: the fade-in's frames, then the intro scroll; EP9-EP13: one intro frame per pass.
            XCTAssertEqual(orig.count, (f.fadeInDuringIntro ? 0 : f.fadeInPasses) + f.introFrames, "EP\(n) boot frame count")
            for (i, want) in orig.prefix(f.fadeInPasses).enumerated() {
                check(i < boot.frames.count ? boot.frames[i] : [], want, "EP\(n) boot frame \(i)")
            }
            // Written by other code after the fade: DAC 255 by the boot's dmd_message (EP1 cs:166F: 3F,3F,3F; EP9-EP13
            // 3F,0,0), and on EP3 / EP5 entries B0h..BFh by lamp_update's colour-lamp pulse (EP3 cs:3A6C -> cs:3B5A,
            // lamps above 32h, one DAC entry each per frame), which the port does not model.
            let others: Set<Int> = Set([255] + ((n == 3 || n == 5) ? Array(0xB0...0xBF) : []))
            func masked(_ d: [UInt8]) -> [UInt8] {
                var o = d
                for i in others where 3 * i + 2 < o.count { o[3 * i] = 0; o[3 * i + 1] = 0; o[3 * i + 2] = 0 }
                return o
            }
            if f.cycle == nil {   // the intro scroll shows the fade-in's last palette (EP8 rotates its ring)
                for (i, d) in orig.enumerated().dropFirst(f.fadeInPasses) {
                    check(masked(d), masked(boot.end.dac), "EP\(n) intro frame \(i)")
                }
            }
            let after = machine(r["after_boot"])
            check(boot.end.working, after.working, "EP\(n) W after boot")
            check(masked(boot.end.dac), masked(after.dac), "EP\(n) DAC after boot")
            XCTAssertEqual([boot.end.counter, boot.end.speed], [after.counter, after.speed], "EP\(n) rotation counter / speed after boot")
            frames += min(orig.count, f.fadeInPasses)
            for o in r["fade_out"] as? [[String: Any]] ?? [] {
                var m = machine(o["start"])
                let count = o["count"] as? Int ?? 0
                let got = f.fadeOut(&m, count: count, passes: 0..<f.fadeOutPasses)
                let want = (o["frames"] as? [Any] ?? []).map(hex)
                XCTAssertEqual(got.count, want.count, "EP\(n) fade-out \(count) passes")
                for (i, (a, b)) in zip(got, want).enumerated() { check(a, b, "EP\(n) fade-out \(count) pass \(i)") }
                frames += want.count
            }
            print("ScreenFade EP\(n): boot \(f.fadeInPasses) fade-in frames + \(f.introFrames) intro frames, 2 x \(f.fadeOutPasses) fade-out passes compared")
        }
        print("ScreenFade: \(frames) DAC frames compared on \(tables.count) tables")
    }
}
