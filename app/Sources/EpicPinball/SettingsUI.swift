import AppKit
import PinballCore
import SwiftUI

/// Settings panel bound to `GameSettings` (shared with the renderer, physics and audio) and
/// the front end's own settings. Every change is saved at once and applied to a running game.
struct SettingsView: View {
    @Bindable var model: AppModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GameTab(settings: model.settings).tabItem { Text("Game") }
                DisplayTab(settings: model.settings, hdStatus: model.hdPackStatus).tabItem { Text("Display") }
                AudioTab(settings: model.settings).tabItem { Text("Audio") }
                ControlsTab(model: model, settings: model.settings).tabItem { Text("Controls") }
                LibraryTab(model: model).tabItem { Text("Library") }
            }
            .padding(16)
            HStack {
                Button("Restore Defaults") { model.settings.resetToDefaults() }
                Spacer()
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 620, height: 520)
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
            Picker("Players", selection: $settings.frontEnd.players) { ForEach(1...4, id: \.self) { Text("\($0)").tag($0) } }
            Picker("Balls per game", selection: $settings.frontEnd.ballsPerGame) { ForEach(ballChoices(settings.frontEnd.ballsPerGame), id: \.self) { Text("\($0)").tag($0) } }
        }
        .formStyle(.grouped)
    }
}

private struct DisplayTab: View {
    @Bindable var settings: SettingsStore
    var hdStatus: String?
    var body: some View {
        Form {
            Picker("Upscale filter", selection: $settings.game.upscaleFilter) {
                ForEach(GameSettings.UpscaleFilter.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Pixel shape", selection: $settings.frontEnd.pixelAspect) {
                Text("Square pixels").tag("square")
                Text("VGA monitor (4:3)").tag("vga")
            }
            Toggle("Show the whole table (320×400)", isOn: $settings.game.fullTableView)
            Toggle("Score strip visible", isOn: $settings.frontEnd.showStrip)
            Toggle("High refresh rate (ProMotion), interpolated motion", isOn: $settings.game.highRefresh)
            Toggle("Dynamic lighting", isOn: $settings.game.dynamicLighting)
            Toggle("Use HD art pack when installed", isOn: $settings.game.useHDPack)
            Toggle("Start in full screen", isOn: $settings.frontEnd.startFullscreen)
            if let hdStatus { LabeledContent("HD pack") { Text(hdStatus).lineLimit(3) } }
            Text("HD packs are generated from your own game files (tools/hdpack/make_pack.py) and live in "
                 + "Application Support/EpicPinballHD/HDPacks or next to your library; nothing is bundled.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct AudioTab: View {
    @Bindable var settings: SettingsStore
    var body: some View {
        Form {
            LabeledContent("Master") { Slider(value: $settings.frontEnd.masterVolume, in: 0...1) }
            LabeledContent("Music") { Slider(value: $settings.game.musicVolume, in: 0...1) }
            LabeledContent("Sound effects") { Slider(value: $settings.game.sfxVolume, in: 0...1) }
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
            }
        }
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
                    model.scores.clear(table: model.selected); model.scoresVersion += 1
                }
            }
        }
        .formStyle(.grouped)
    }
}
