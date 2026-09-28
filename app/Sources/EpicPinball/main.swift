import AppKit
import Foundation
import PinballCore

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

if let d = options.supportDir {
    AppPaths.overrideRoot = URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
}

/// Data root for the headless modes and direct starts: `--data`, `$EPIC_PINBALL_DATA`, the
/// developer `../extracted` candidates (as before), then the imported library (whose original
/// files are then used unless `--original` is given).
func resolveDataRoot(_ o: inout Options) -> URL {
    do { return try DataLocator.resolve(explicit: o.dataDir) } catch {
        if o.dataDir == nil, GameLibrary.hasTables(AppPaths.libraryRoot) {
            let root = AppPaths.libraryRoot
            if o.originalDir == nil { o.originalDir = GameLibrary.findOriginal(near: root, explicit: nil)?.path }
            return root
        }
        fail("\(error)")
    }
}

let headless = options.trace != nil || options.snapshot != nil || (options.autoplay != nil && options.snapshot == nil)

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

    let assets: TableAssets
    let engine: ClassicEngine
    do {
        assets = try TableAssets.load(dataRoot: dataRoot, table: options.table)
        engine = try EngineAssets.makeEngine(dataRoot: dataRoot, table: options.table)
        if let gp = options.gravityPhase { engine.gravityPhase = gp }
    } catch {
        fail("\(error)")
    }

    if let n = options.autoplay, options.snapshot == nil {
        if options.physics == .enhanced { _ = EnhancedPhysics.install(on: engine, config: .classicFeel) }
        let report = AutoPlay.run(engine: engine, frames: n, options: options.rulesOptions)
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
        settings.game.fullTableView = false
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
            let engine = try EngineAssets.makeEngine(dataRoot: dataRoot, table: o.table)
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
            try UISnapshot.run(screen: options.uiScreen, model: model, size: options.size, to: path)
            exit(0)
        } catch { fail("ui snapshot failed: \(error)") }
    }
    return AppDelegate(options: options, startMode: start, model: model)
}

let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
