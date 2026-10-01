import Foundation
import PinballCore
import PinballImport

/// HD pack generation in the app (Settings > Library) and from the command line
/// (`--make-hd-pack`), through PinballImport's HDPackMaker (the Swift port of
/// tools/hdpack/make_pack.py). Packs are written to `AppPaths.hdPacksRoot/EPn`, which
/// HDPack.locate searches; they are made from the user's own data and stay on this Mac.
enum HDPackGeneration {
    static let appScales = [2, 3, 4]
    static let defaultScale = 4

    /// Tables with a pack under `root` and its scale (pack.json only; HDPack.load validates).
    static func installed(root: URL = AppPaths.hdPacksRoot) -> [(table: Int, scale: Int)] {
        (1...TableGeometry.tableCount).compactMap { n in
            let u = HDPackMaker.packDirectory(root: root, table: n).appendingPathComponent("pack.json")
            guard let d = try? Data(contentsOf: u), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let s = (j["scale"] as? NSNumber)?.intValue else { return nil }
            return (n, s)
        }
    }

    static func installedSummary(root: URL = AppPaths.hdPacksRoot) -> String {
        let packs = installed(root: root)
        if packs.isEmpty { return "none" }
        // "all 13 tables at 4×", "tables 1, 10 at 4×; table 3 at 2×"
        return Dictionary(grouping: packs, by: \.scale).sorted { $0.key > $1.key }.map { scale, list in
            let tables = list.map(\.table)
            let which = tables.count == TableGeometry.tableCount ? "all \(tables.count) tables"
                : (tables.count == 1 ? "table " : "tables ") + tables.map(String.init).joined(separator: ", ")
            return "\(which) at \(scale)×"
        }.joined(separator: "; ")
    }

    /// Generates the packs one table after another (each uses every core). `progress` gets the
    /// overall fraction; `isCancelled` stops between assets. Tables without data are skipped
    /// with a warning. Returns (done, warnings) or throws CancellationError.
    static func run(tables: [Int], dataRoot: URL, outputRoot: URL, scale: Int, method: HDPackMaker.Method = .xbrz,
                    progress: @escaping @Sendable (Double, String) -> Void,
                    isCancelled: @escaping @Sendable () -> Bool) throws -> (done: [HDPackMaker.Result], warnings: [String]) {
        var done: [HDPackMaker.Result] = []
        var warnings: [String] = []
        for (k, n) in tables.enumerated() {
            if isCancelled() { throw CancellationError() }
            let label = tables.count == 1 ? "Table \(n)" : "Table \(n) (\(k + 1) of \(tables.count))"
            guard FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent("tables/EP\(n)/playfield_idx.npy").path) else {
                warnings.append("table \(n): no data"); continue
            }
            progress(Double(k) / Double(tables.count), "\(label)…")
            do {
                let r = try HDPackMaker.make(table: n, dataRoot: dataRoot, output: HDPackMaker.packDirectory(root: outputRoot, table: n),
                                             scale: scale, method: method, progress: { p in
                    progress((Double(k) + p.fraction) / Double(tables.count), "\(label)…")
                }, isCancelled: isCancelled)
                done.append(r)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                warnings.append("table \(n): \(error)")
            }
        }
        progress(1, "Done")
        return (done, warnings)
    }
}

/// A cancellation flag shared with the worker.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// `--make-hd-pack N|all [--scale S] [--hd-method M] [--verify-hd-pack] [--hd-pack-out DIR]`.
enum HDPackCLI {
    static func run(tables: [Int], options o: Options, dataRoot: URL) -> Int32 {
        let scale = o.scaleGiven ? o.scale : HDPackGeneration.defaultScale
        guard HDPackMaker.scales.contains(scale) else {
            warn("--make-hd-pack: --scale must be \(HDPackMaker.scales.lowerBound)...\(HDPackMaker.scales.upperBound)")
            return 2
        }
        let method = HDPackMaker.Method(rawValue: o.hdPackMethod) ?? .xbrz
        let root = o.hdPackOut.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL }
            ?? AppPaths.hdPacksRoot
        var status: Int32 = 0
        let started = Date()
        for n in tables {
            let out = HDPackMaker.packDirectory(root: root, table: n)
            do {
                let r = try HDPackMaker.make(table: n, dataRoot: dataRoot, output: out, scale: scale, method: method)
                print("EP\(n): \(scale)x \(method.rawValue), playfield \(TableGeometry.width * scale)x\(TableGeometry.height * scale), "
                      + "\(r.sprites) sprites, ball \(r.ball ? "yes" : "no"), font8 \(r.font8Glyphs) glyphs -> \(out.path) in "
                      + String(format: "%.2f s", r.seconds))
                if o.verifyHDPack {
                    let t0 = Date()
                    let v = try HDPackMaker.verify(pack: out, dataRoot: dataRoot, table: n)
                    let pf = v.assets.first { $0.name == "playfield" }?.check
                    print("  verify: \(v.assets.count) assets, all aligned \(v.allAligned), aggregate best shift "
                          + "(\(v.aggregateBestShift.dy), \(v.aggregateBestShift.dx)), playfield box MAE \(pf.map { String($0.boxMAE) } ?? "-"), "
                          + "centre exact \(pf.map { String($0.centreExact) } ?? "-")" + String(format: " (%.2f s)", Date().timeIntervalSince(t0)))
                    if !v.ok { print("  ALIGNMENT CHECK FAILED (see \(out.path)/verify.json)"); status = 1 }
                }
            } catch {
                warn("EP\(n): \(error)")
                status = 1
            }
        }
        if tables.count > 1 { print(String(format: "%d tables in %.2f s", tables.count, Date().timeIntervalSince(started))) }
        return status
    }
}
