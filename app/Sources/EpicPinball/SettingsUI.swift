import AppKit
import PinballCore
import SwiftUI

/// Settings panel bound to `GameSettings` (shared with the renderer, physics and audio) and
/// the front end's own settings. Every change is saved at once and applied to a running game.
struct SettingsView: View {
    @Bindable var model: AppModel
    var onClose: () -> Void
    /// Tab shown first (0 Game ... 4 Library; `--ui-screen settings-display` etc.).
    @State var tab = 0
    /// Sheet height (UI snapshots pass a taller one to show every row at once).
    var height: CGFloat = SettingsView.sheetSize.height
    static let sheetSize = CGSize(width: 620, height: 520)

    static let tabNames = ["game", "display", "audio", "controls", "library"]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                GameTab(settings: model.settings).tabItem { Text("Game") }.tag(0)
                DisplayTab(settings: model.settings, hdStatus: model.hdPackStatus).tabItem { Text("Display") }.tag(1)
                AudioTab(settings: model.settings).tabItem { Text("Audio") }.tag(2)
                ControlsTab(model: model, settings: model.settings).tabItem { Text("Controls") }.tag(3)
                LibraryTab(model: model).tabItem { Text("Library") }.tag(4)
            }
            .padding(16)
            HStack {
                Button("Restore Defaults") { model.settings.resetToDefaults() }
                Spacer()
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: SettingsView.sheetSize.width, height: height)
    }
}

private struct GameTab: View {
    @Bindable var settings: SettingsStore
    var body: some View {
        Form {
            Picker("Physics", selection: $settings.game.physicsMode) {
                ForEach(GameSettings.PhysicsMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Text("Classic runs the original integer engine exactly (59.94 frames/s). Enhanced keeps the "
                 + "same rules and timing with smoother motion.").font(.caption).foregroundStyle(.secondary)
            Picker("Enhanced physics feel", selection: $settings.game.enhancedPreset) {
                ForEach(EnhancedPhysicsConfig.Preset.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .disabled(settings.game.physicsMode != .enhanced)
            Text("Classic feel is fitted to the original's bounces and flipper shots; Modern uses physically "
                 + "based bounces, spin and livelier flippers.").font(.caption).foregroundStyle(.secondary)
            Picker("Players", selection: $settings.frontEnd.players) { ForEach(1...4, id: \.self) { Text("\($0)").tag($0) } }
            Picker("Balls per game", selection: $settings.frontEnd.ballsPerGame) { ForEach(ballChoices(settings.frontEnd.ballsPerGame), id: \.self) { Text("\($0)").tag($0) } }
            Toggle("Pause when inactive", isOn: $settings.frontEnd.pauseWhenInactive)
            Text("Opens the pause menu when the window loses focus or a game controller disconnects.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Attract mode when idle", isOn: $settings.frontEnd.attractMode)
            Text("After 15 seconds without input, before a game starts or in the table picker, the table "
                 + "plays itself as the original's demo does. Any key leaves it; attract games never count "
                 + "for high scores.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct DisplayTab: View {
    @Bindable var settings: SettingsStore
    var hdStatus: String?
    var body: some View {
        Form {
            Section("Picture") {
                Picker("Upscale filter", selection: $settings.game.upscaleFilter) {
                    ForEach(GameSettings.UpscaleFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Pixel shape", selection: $settings.frontEnd.pixelAspect) {
                    Text("Square pixels").tag("square")
                    Text("VGA monitor (4:3)").tag("vga")
                }
                Picker("Scaling", selection: $settings.game.outputScaling) {
                    ForEach(GameSettings.OutputScaling.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Show the whole table (320×400)", isOn: $settings.game.fullTableView)
                Toggle("Score strip visible", isOn: $settings.frontEnd.showStrip)
                Toggle("High refresh rate (ProMotion), interpolated motion", isOn: $settings.game.highRefresh)
                Picker("Dynamic lighting", selection: $settings.game.lightingChoice) {
                    Text("Off").tag(GameSettings.LightingChoice.off)
                    ForEach(GameSettings.LightingStrength.allCases, id: \.self) { Text($0.label).tag(GameSettings.LightingChoice(rawValue: $0.rawValue)!) }
                }
                Toggle("Use HD art pack when installed", isOn: $settings.game.useHDPack)
                if let hdStatus { LabeledContent("HD pack") { Text(hdStatus).lineLimit(3) } }
                Toggle("Start in full screen", isOn: $settings.frontEnd.startFullscreen)
                Toggle("Performance overlay (frame rate, frame time, flipper latency)", isOn: $settings.frontEnd.showPerfOverlay)
                Text("HD packs are generated from your own game files (Library > Generate HD packs) and live in "
                     + "Application Support/EpicPinballHD/HDPacks or next to your library; nothing is bundled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Enhanced rendering") {
                Toggle("Round message dots", isOn: $settings.game.roundDots)
                Toggle("Score strip in the whole-table view", isOn: $settings.game.stripInFullTable)
                Toggle("Rotate flippers (high refresh)", isOn: $settings.game.rotateFlippers)
                Text("Used with any filter other than Sharp pixels, an HD pack, lighting or Fill scaling (the "
                     + "original picture is unchanged). Rotated flippers need high refresh and an HD pack or the "
                     + "smooth, xBRZ or CRT filter; otherwise the game's flipper frames are cross-faded.")
                    .font(.caption).foregroundStyle(.secondary)
                CRTSlider(label: "CRT scanlines", value: $settings.game.crtScanlines, range: GameSettings.crtScanlinesRange,
                          defaultValue: GameSettings().crtScanlines)
                CRTSlider(label: "CRT curvature", value: $settings.game.crtCurvature, range: GameSettings.crtCurvatureRange,
                          defaultValue: GameSettings().crtCurvature)
                CRTSlider(label: "CRT shadow mask", value: $settings.game.crtMask, range: GameSettings.crtMaskRange,
                          defaultValue: GameSettings().crtMask)
                Text(settings.game.upscaleFilter == .crt ? "The CRT sliders apply to the CRT scanlines filter."
                     : "The CRT sliders apply when the upscale filter is CRT scanlines.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cabinet") {
                Picker("Rotate picture", selection: $settings.game.displayRotation) {
                    ForEach(GameSettings.DisplayRotation.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Score display in its own window (second screen)", isOn: $settings.game.scoreWindow)
                Picker("Rotate score window", selection: $settings.game.scoreWindowRotation) {
                    ForEach(GameSettings.DisplayRotation.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .disabled(!settings.game.scoreWindow)
                Text("Rotate the picture for a monitor turned on its side (90° clockwise when the monitor's "
                     + "right-hand edge is at the top); with the whole table shown it fills a portrait screen, and "
                     + "the menus turn with it. The score window can be moved to a backglass display and has its "
                     + "own rotation; both windows remember where they were.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Screenshots") {
                LabeledContent("Folder") {
                    HStack {
                        Text(settings.frontEnd.screenshotDirectory.path).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary).help(settings.frontEnd.screenshotDirectory.path)
                        Button("Choose…") { chooseScreenshotFolder() }
                        if !settings.frontEnd.screenshotFolder.isEmpty {
                            Button("Default") { settings.frontEnd.screenshotFolder = "" }
                        }
                    }
                }
                Text("In a game: \(settings.frontEnd.keyBindings.label(.screenshot)) or Shift-Cmd-S saves a screenshot, "
                     + "\(settings.frontEnd.keyBindings.label(.perfOverlay)) shows the performance overlay.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseScreenshotFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the screenshot folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.frontEnd.screenshotDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.frontEnd.screenshotFolder = url.path
    }
}

/// A CRT parameter: slider, value and a reset to the built-in default.
private struct CRTSlider: View {
    var label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var defaultValue: Double
    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: $value, in: range).frame(minWidth: 160)
                Text(String(format: "%.0f%%", (value - range.lowerBound) / (range.upperBound - range.lowerBound) * 100))
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                Button("Reset") { value = defaultValue }.disabled(abs(value - defaultValue) < 1e-9)
            }
        }
    }
}

private struct AudioTab: View {
    @Bindable var settings: SettingsStore
    var body: some View {
        Form {
            LabeledContent("Master") { Slider(value: $settings.frontEnd.masterVolume, in: 0...1) }
            LabeledContent("Music") { Slider(value: $settings.game.musicVolume, in: 0...1) }
            LabeledContent("Sound effects") { Slider(value: $settings.game.sfxVolume, in: 0...1) }
            Picker("Resampling", selection: $settings.game.audioInterpolation) {
                ForEach(GameSettings.AudioInterpolation.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Text("Original plays effects and music with nearest-neighbour resampling, like the game's "
                 + "Sound Blaster driver; Smooth interpolates.").font(.caption).foregroundStyle(.secondary)
            Text("In a game: M music on/off, S effects on/off, - / = master volume, [ / ] music volume.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct ControlsTab: View {
    @Bindable var model: AppModel
    @Bindable var settings: SettingsStore
    @State private var capturing: GameAction?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Game controller", isOn: $settings.frontEnd.controllerEnabled)
                Toggle("Haptics", isOn: $settings.frontEnd.haptics).disabled(!model.settings.frontEnd.controllerEnabled)
                Spacer()
                Text(model.controllers.isEmpty ? "No controller connected" : model.controllers.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Controller: shoulders or triggers flip, A (or D-pad down) plunger, left stick nudges, "
                 + "B nudges like Space, Menu opens the menu.").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(GameAction.allCases, id: \.self) { a in
                    HStack {
                        Text(a.label)
                        Spacer()
                        Text(capturing == a ? "Press a key… (Esc cancels)" : model.settings.frontEnd.keyBindings.label(a))
                            .foregroundStyle(capturing == a ? Theme.accent2 : .secondary)
                            .font(.system(.body, design: .rounded))
                        Button(capturing == a ? "Cancel" : "Set") { capturing == a ? stop() : start(a) }
                        Button("Add") { start(a, add: true) }.disabled(capturing != nil)
                    }
                }
            }
            HStack {
                Button("Original keys") { model.settings.frontEnd.keyBindings = .defaults }
                Spacer()
                Text("Practice games: 1-4 choose the save slot (keys not bound above).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)   // inset like the other tabs' grouped forms
        .onDisappear { stop() }
    }

    @State private var adding = false

    private func start(_ a: GameAction, add: Bool = false) {
        stop()
        capturing = a
        adding = add
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { ev in
            guard let target = capturing else { return ev }
            let code = ev.keyCode
            if ev.type == .flagsChanged {
                // Only on press of a modifier (its device bit set).
                guard let m = KeyCode.modifierMasks.first(where: { $0.code == code }),
                      ev.modifierFlags.rawValue & m.mask != 0 else { return nil }
            } else if code == KeyCode.escape && target != .menu {
                stop(); return nil
            }
            model.settings.frontEnd.keyBindings.bind(code, to: target, replace: !adding)
            stop()
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        capturing = nil
    }
}

private struct LibraryTab: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            LabeledContent("Game data") { Text(model.library?.dataRoot.path ?? "none").textSelection(.enabled).lineLimit(3) }
            LabeledContent("Found as") { Text(model.library?.origin.rawValue ?? "-") }
            LabeledContent("Original files") { Text(model.library?.originalDir?.path ?? "not found").textSelection(.enabled).lineLimit(3) }
            LabeledContent("Settings & scores") { Text(AppPaths.supportRoot.path).textSelection(.enabled).lineLimit(3) }
            HStack {
                Button("Import again…") { model.showSettings = false; model.importState = .idle; model.screen = .importer }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.library?.dataRoot ?? AppPaths.supportRoot])
                }
                Spacer()
                Button("Clear this table's scores", role: .destructive) {
                    model.clearScores(table: model.selected)
                }
            }
            HStack {
                Text("Statistics (stats.json): games, balls, scores and play time per table.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear this table's statistics", role: .destructive) {
                    model.stats.clear(table: model.selected); model.scoresVersion += 1
                }
                Button("Clear all statistics", role: .destructive) { model.stats.clearAll(); model.scoresVersion += 1 }
            }
            let _ = model.scoresVersion   // re-read the slots after Clear
            HStack {
                Text("Practice save states (SaveStates): \(PracticeStateStore().occupiedSlots(table: model.selected).count) of \(PracticeStateFile.slotCount) slots used for this table.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear this table's save states", role: .destructive) {
                    PracticeStateStore().clear(table: model.selected); model.scoresVersion += 1
                }
            }
            HDPackSection(model: model)
        }
        .formStyle(.grouped)
    }
}

/// "Generate HD packs": made on this Mac from the user's own files with the built-in xBRZ
/// (PinballImport.HDPackMaker), written to Application Support/EpicPinballHD/HDPacks.
private struct HDPackSection: View {
    @Bindable var model: AppModel
    @State private var scale = HDPackGeneration.defaultScale
    @State private var allTables = true

    var body: some View {
        Section("HD art packs") {
            let _ = model.hdPacksVersion
            LabeledContent("Installed") { Text(HDPackGeneration.installedSummary()).lineLimit(2) }
            Picker("Scale", selection: $scale) {
                ForEach(HDPackGeneration.appScales, id: \.self) { Text("\($0)×").tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Picker("Tables", selection: $allTables) {
                    Text("All tables").tag(true)
                    Text("Table \(model.selected)").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if model.hdPackRunning {
                    Button("Cancel") { model.cancelHDPacks() }
                } else {
                    Button("Generate HD packs") {
                        let tables = allTables ? model.tables.filter(\.available).map(\.number) : [model.selected]
                        model.generateHDPacks(tables: tables.isEmpty ? [model.selected] : tables, scale: scale)
                    }
                    .disabled(model.library == nil)
                }
            }
            switch model.hdPackState {
            case .idle: EmptyView()
            case let .running(f, m): ProgressView(value: f) { Text(m).font(.caption) }
            case let .finished(m): Text(m).font(.caption).foregroundStyle(.secondary)
            case let .failed(m): Text(m).font(.caption).foregroundStyle(.red)
            }
            Text("Made on this Mac from your own game files with the built-in xBRZ filter (under a second per table), "
                 + "stored in \(AppPaths.hdPacksRoot.path). Use them with Display > Use HD art pack; a table that is "
                 + "running picks up a new pack when it is started again.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
