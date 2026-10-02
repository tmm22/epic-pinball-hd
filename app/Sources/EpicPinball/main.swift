import AppKit
import Foundation
import MachO
import PinballCore
import PinballImport
import PinballRender

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("EpicPinball: \(message)\n".utf8))
    exit(code)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("EpicPinball: warning: \(message)\n".utf8))
}

var options: Options
do {
    options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch Options.ParseError.help {
    print(Options.usage)
    exit(0)
} catch {
    fail("\(error)", code: 2)
}

// `--list-dylibs`: every image dyld mapped into this process (tools/package_app.sh checks the
// embedded libraries with it under the hardened runtime, which ignores DYLD_PRINT_LIBRARIES).
if options.listDylibs {
    for i in 0..<_dyld_image_count() { if let n = _dyld_get_image_name(i) { print(String(cString: n)) } }
    exit(0)
}

if let d = options.supportDir {
    AppPaths.overrideRoot = URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    HDPack.userPacksRootOverride = AppPaths.hdPacksRoot
}
if let d = options.libraryDir {
    AppPaths.libraryOverride = URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
}
// Process-wide switches read by PinballCore / PinballRender (RulesBackend.default, RenderSettings.fromEnvironment).
if let b = options.rulesBackend { setenv("EPIC_PINBALL_RULES", b.rawValue, 1) }
if let r = options.renderSpec { setenv("EPIC_PINBALL_RENDER", r, 1) }

/// Data root for the headless modes and direct starts: `--data`; `--library`; `$EPIC_PINBALL_DATA`
/// and (outside a packaged .app only) the developer `../extracted` candidates, as before; then the
/// imported library. For an explicit `--data` and for a library the user's original files next
/// to it (`<root>/original`) are used unless `--original` is given; the developer default keeps
/// the loaders' own search order (so harness traces are unchanged).
func resolveDataRoot(_ o: inout Options) -> URL {
    func withOriginal(_ root: URL) -> URL {
        if o.originalDir == nil { o.originalDir = GameLibrary.findOriginal(near: root, explicit: nil)?.path }
        return root
    }
    if let d = o.dataDir {
        return withOriginal(URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL)
    }
    let lib = AppPaths.libraryRoot
    if o.libraryDir != nil {
        guard GameLibrary.hasTables(lib) else {
            fail("no imported tables in \(lib.path) (import them with --headless-import CD.iso --library \(lib.path))")
        }
        return withOriginal(lib)
    }
    var candidates: [URL] = []
    if GameLibrary.runningFromAppBundle {
        if let env = ProcessInfo.processInfo.environment["EPIC_PINBALL_DATA"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env, isDirectory: true).standardizedFileURL)
        }
    } else {
        candidates = DataLocator.defaultCandidates()
    }
    var isDir: ObjCBool = false
    for c in candidates where FileManager.default.fileExists(atPath: c.appendingPathComponent("tables").path, isDirectory: &isDir) && isDir.boolValue {
        return c
    }
    if GameLibrary.hasTables(lib) { return withOriginal(lib) }
    fail("\(AssetError.missingDataRoot(candidates + [lib]))\n(or import your CD first: EpicPinball --headless-import CD.iso)")
}

// `--headless-import SRC`: the first-launch import without a window (tests, packaging checks).
if let src = options.headlessImport {
    let u = URL(fileURLWithPath: (src as NSString).expandingTildeInPath).standardizedFileURL
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { fail("\(u.path) does not exist") }
    let source: ImportSource = isDir.boolValue ? .directory(u) : .isoImage(u)
    let importer = makeImporter(for: source)
    let destination = AppPaths.libraryRoot
    let started = Date()
    do {
        for w in try importer.validate(source) { print("check: \(w)") }
        let lastMessage = LockedString()
        let lib = try importer.importGame(from: source, to: destination) { p in
            guard lastMessage.swap(p.message) != p.message else { return }
            print(String(format: "%3.0f%% %@", p.fraction * 100, p.message))
        }
        for w in lib.warnings { print("warning: \(w)") }
        print("imported \(lib.tables.count) tables into \(lib.root.path) in \(String(format: "%.2f", Date().timeIntervalSince(started))) s: "
              + lib.tables.map { "\($0.number) \($0.name)" }.joined(separator: ", "))
        exit(lib.tables.isEmpty ? 1 : 0)
    } catch {
        fail("import failed: \(error)")
    }
}

// `--make-hd-pack N|all`: HD packs without a window (HDPackGeneration.swift).
if let tables = options.makeHDPack {
    var o = options
    let dataRoot = resolveDataRoot(&o)
    exit(HDPackCLI.run(tables: tables, options: o, dataRoot: dataRoot))
}

let headless = options.trace != nil || options.snapshot != nil || (options.autoplay != nil && options.snapshot == nil)
    || options.playReplay != nil

if headless {
    let dataRoot = resolveDataRoot(&options)
    if let tracePath = options.trace {
        do {
            try TraceMode.run(options: options, scenarioPath: tracePath, dataRoot: dataRoot)
            exit(0)
        } catch {
            fail("trace failed: \(error)")
        }
    }

    // `--play-replay FILE`: re-simulate a replay on a new engine and compare the final state.
    if let path = options.playReplay {
        do {
            let replay = try Replay.load(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            let check = try ReplayPlayer.verify(replay, dataRoot: dataRoot, originalDir: options.originalURL)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(check)
            if let p = options.autoplayJSON { try data.write(to: URL(fileURLWithPath: (p as NSString).expandingTildeInPath)) }
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            exit(check.matches ? 0 : 4)
        } catch {
            fail("replay \(path): \(error)")
        }
    }

    let assets: TableAssets
    let engine: ClassicEngine
    do {
        assets = try TableAssets.load(dataRoot: dataRoot, table: options.table)
        engine = try EngineAssets.makeEngine(dataRoot: dataRoot, table: options.table, originalDir: options.originalURL)
        if let gp = options.gravityPhase { engine.gravityPhase = gp }
    } catch {
        fail("\(error)")
    }

    if let n = options.autoplay, options.snapshot == nil {
        let report: AutoPlayReport
        if let out = options.recordReplay {
            // Recorded: the physics model is installed after the start (the app's and the replay's order).
            var replay: Replay?
            report = AutoPlay.run(engine: engine, frames: n, options: options.rulesOptions, physics: options.physics) { replay = $0 }
            guard var r = replay else { fail("no replay recorded") }
            r.header.appVersion = ReplayLibrary.appVersion
            r.header.setDigests(dataRoot: dataRoot, originalDir: options.originalURL)
            let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            do { try r.write(to: url) } catch { fail("cannot write \(out): \(error)") }
            FileHandle.standardError.write(Data("replay: \(url.path), \(r.header.frames) frames, digest \(r.header.finalDigest)\n".utf8))
        } else {
            if options.physics == .enhanced { _ = EnhancedPhysics.install(on: engine, config: .classicFeel) }
            report = AutoPlay.run(engine: engine, frames: n, options: options.rulesOptions)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? enc.encode(report)) ?? Data()
        if let p = options.autoplayJSON {
            do { try data.write(to: URL(fileURLWithPath: (p as NSString).expandingTildeInPath)) } catch { fail("cannot write \(p): \(error)") }
        }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        exit(report.loopGuardTrips == 0 && report.ruleFaults.isEmpty ? 0 : 3)
    }

    do {
        let o = options
        try MainActor.assumeIsolated { try SnapshotMode.run(options: o, assets: assets, engine: engine, dataRoot: dataRoot) }
        exit(0)
    } catch {
        fail("snapshot failed: \(error)")
    }
}

// Window app: launcher / import screen, or straight into a table.
let delegate: AppDelegate = MainActor.assumeIsolated {
    let direct = options.directPlay
    let settings = SettingsStore()
    if direct {
        // A direct start is a developer / smoke-test run: the CLI flags decide, nothing is saved.
        settings.persist = false
        settings.game.physicsMode = options.physics
        settings.game.upscaleFilter = GameSettings.UpscaleFilter(rawValue: options.filter.rawValue)
            ?? (options.filter.rawValue.hasPrefix("xbrz") ? .xbrz : .nearest)
        settings.frontEnd.pixelAspect = options.aspect.rawValue
        settings.frontEnd.showStrip = options.stripShown
        settings.frontEnd.players = options.players
        settings.frontEnd.ballsPerGame = options.balls
        settings.game.fullTableView = options.full
        settings.game.useHDPack = options.hdPack
        settings.game.dynamicLighting = options.lighting.map { $0 != .off } ?? false
        settings.game.lightingStrength = options.lighting == .vivid ? .vivid : .subtle
        // Not CLI flags: the defaults, so a direct start does not depend on the stored file.
        let defaults = GameSettings()
        settings.game.outputScaling = defaults.outputScaling
        settings.game.enhancedPreset = defaults.enhancedPreset
        settings.game.audioInterpolation = defaults.audioInterpolation
        settings.game.crtScanlines = defaults.crtScanlines
        settings.game.crtCurvature = defaults.crtCurvature
        settings.game.crtMask = defaults.crtMask
        settings.game.roundDots = defaults.roundDots
        settings.game.stripInFullTable = defaults.stripInFullTable
        settings.game.rotateFlippers = defaults.rotateFlippers
        settings.game.highRefresh = options.highRefreshFlag
        settings.game.displayRotation = options.rotation ?? .none
        settings.game.scoreWindow = options.scoreWindow
        settings.game.scoreWindowRotation = options.scoreRotation ?? .none
        if let v = options.volume { settings.frontEnd.masterVolume = v }
    }
    let model = AppModel(settings: settings, scores: HighScoreStore())
    model.explicitOriginal = options.originalDir
    let start: StartMode
    if direct {
        var o = options
        let dataRoot = resolveDataRoot(&o)
        options = o
        do {
            let assets = try TableAssets.load(dataRoot: dataRoot, table: o.table)
            let engine = try EngineAssets.makeEngine(dataRoot: dataRoot, table: o.table, originalDir: o.originalURL)
            if let gp = o.gravityPhase { engine.gravityPhase = gp }
            start = .direct(dataRoot: dataRoot, assets: assets, engine: engine)
        } catch { fail("\(error)") }
        model.library = GameLibrary(dataRoot: dataRoot, originalDir: GameLibrary.findOriginal(near: dataRoot, explicit: o.originalDir),
                                    origin: o.dataDir != nil ? .explicit : .developer)
    } else {
        model.library = GameLibrary.locate(explicitData: options.dataDir, explicitOriginal: options.originalDir)
        if options.tableGiven { model.selected = options.table }
        model.screen = model.library == nil || options.forceImport ? .importer : .picker
        model.reloadTables()
        if options.tableGiven { model.selected = options.table }
        start = .launcher
    }
    if let path = options.uiSnapshot {
        do {
            try UISnapshot.run(screen: options.uiScreen, model: model, size: options.size, to: path, rotation: options.rotation ?? .none)
            exit(0)
        } catch { fail("ui snapshot failed: \(error)") }
    }
    return AppDelegate(options: options, startMode: start, model: model)
}

let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

/// A string shared with the importer's progress callback (called from worker threads).
final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    /// Stores `new` and returns the previous value.
    func swap(_ new: String) -> String { lock.lock(); defer { lock.unlock() }; let old = value; value = new; return old }
}
