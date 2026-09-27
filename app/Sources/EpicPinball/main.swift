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

let options: Options
do {
    options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch Options.ParseError.help {
    print(Options.usage)
    exit(0)
} catch {
    fail("\(error)", code: 2)
}

let dataRoot: URL
do { dataRoot = try DataLocator.resolve(explicit: options.dataDir) } catch { fail("\(error)") }

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

if options.snapshot != nil {
    do {
        try SnapshotMode.run(options: options, assets: assets, engine: engine)
        exit(0)
    } catch {
        fail("snapshot failed: \(error)")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate(options: options, assets: assets, engine: engine)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
