import AppKit
import PinballCore
import SwiftUI

/// Colours of the front end (original design: a dark cabinet with an electric-teal accent).
enum Theme {
    static let background = LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.10), Color(red: 0.09, green: 0.05, blue: 0.14)],
                                           startPoint: .top, endPoint: .bottom)
    static let panel = Color.white.opacity(0.06)
    static let panelBorder = Color.white.opacity(0.10)
    static let accent = Color(red: 0.20, green: 0.85, blue: 0.85)
    static let accent2 = Color(red: 0.95, green: 0.35, blue: 0.65)
    static let text = Color.white
    static let dim = Color.white.opacity(0.6)
}

/// The launcher: table picker (previews and names from the user's files) with the selected
/// table's high scores and game options.
struct LauncherView: View {
    @Bindable var model: AppModel
    /// Snapshot mode (`--launcher-snapshot`): plain stacks instead of scroll views so
    /// `ImageRenderer` draws everything.
    var staticLayout = false
    static let columns = 5

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 20) {
                grid.frame(maxWidth: .infinity)
                detail.frame(width: 340)
            }
            .padding(20)
            HDPackProgressBar(model: model)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppMark().frame(width: 34, height: 34)
            Text("Epic Pinball").font(.system(size: 26, weight: .heavy, design: .rounded))
            Text("HD").font(.system(size: 14, weight: .bold, design: .rounded)).padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Theme.accent2))
            Spacer()
            if let n = model.notice {
                Text(n).font(.callout).foregroundStyle(.orange).lineLimit(2)
            }
            Button { model.showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                .keyboardShortcut(",", modifiers: .command)
            Button { model.onQuit?() } label: { Label("Quit", systemImage: "power") }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(Color.black.opacity(0.35))
    }

    @ViewBuilder private var grid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 14), count: Self.columns)
        let content = LazyVGrid(columns: cols, spacing: 14) {
            ForEach(model.tables) { t in
                TableCard(table: t, selected: t.number == model.selected, best: model.highScores(t.number).first,
                          vga: model.settings.frontEnd.pixelAspect == "vga")
                    .onTapGesture(count: 2) { model.select(t.number); model.play() }
                    .onTapGesture { model.select(t.number) }
            }
        }
        if staticLayout { content } else { ScrollView { content.padding(2) } }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let t = model.selectedTable {
                HStack(alignment: .top, spacing: 14) {
                    TablePreview(image: t.preview, vga: model.settings.frontEnd.pixelAspect == "vga")
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .frame(height: 220)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t.name).font(.system(size: 22, weight: .bold, design: .rounded))
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        Text("Table \(t.number)").font(.caption).foregroundStyle(Theme.dim)
                        if let p = t.problem { Text(p).font(.caption).foregroundStyle(.orange) }
                    }
                }
                HighScoreList(entries: model.highScores(t.number), watchable: { model.replayURL($0) != nil },
                              onWatch: { e in if let u = model.replayURL(e) { model.watch(u) } })
                TableStatsView(stats: model.tableStats(t.number))
                ReplaysRow(model: model, table: t.number)
                GameOptionsRow(settings: model.settings)
                HStack {
                    Button { model.play() } label: {
                        Text("Play").font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
                    Button { model.practice() } label: {
                        Text("Practice").font(.title3).padding(.vertical, 6).padding(.horizontal, 4)
                    }
                    .buttonStyle(.bordered)
                    .help("Save and restore the game state with K and L; practice games are not scored")
                }
                .disabled(!t.available)
            }
            Spacer(minLength: 0)
            Text("Arrows choose, Return plays. Esc in a game opens the menu.").font(.caption).foregroundStyle(Theme.dim)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.panelBorder))
    }
}

struct TablePreview: View {
    var image: CGImage?
    var vga: Bool
    /// Width / height of the shown picture: the image's own shape (the table art is 160x200,
    /// portrait), with VGA's 1.2x tall pixels when that pixel shape is chosen.
    var aspect: CGFloat {
        let w = CGFloat(image?.width ?? TableCatalog.selectScreenArtWidth), h = CGFloat(image?.height ?? 200)
        return w / (h * (vga ? 1.2 : 1))
    }
    var body: some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let img = image {
                Image(decorative: img, scale: 1).resizable().interpolation(.none)
            } else {
                AppMark().opacity(0.25).padding(30)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
    }
}

struct TableCard: View {
    var table: TableInfo
    var selected: Bool
    var best: HighScoreEntry?
    var vga: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TablePreview(image: table.preview, vga: vga)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(table.available ? 1 : 0.35)
            HStack(alignment: .firstTextBaseline) {
                Text("\(table.number)").font(.caption.monospacedDigit()).foregroundStyle(Theme.accent)
                Text(table.name).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                    .minimumScaleFactor(0.7).help(table.name)
            }
            Text(best.map { "\($0.initials)  \(formatScore($0.score))" } ?? (table.available ? "No scores yet" : "Not imported"))
                .font(.caption.monospacedDigit()).foregroundStyle(Theme.dim).lineLimit(1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.accent.opacity(0.18) : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Theme.accent : Theme.panelBorder, lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }
}

struct HighScoreList: View {
    var entries: [HighScoreEntry]
    var highlight: Set<Int> = []
    /// Launcher: entries whose replay is kept get a watch button.
    var watchable: (HighScoreEntry) -> Bool = { _ in false }
    var onWatch: ((HighScoreEntry) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("HIGH SCORES").font(.caption.bold()).foregroundStyle(Theme.accent)
            if entries.isEmpty {
                Text("No scores yet").font(.callout).foregroundStyle(Theme.dim)
            }
            ForEach(Array(entries.enumerated()), id: \.offset) { i, e in
                HStack {
                    Text("\(i + 1).").frame(width: 26, alignment: .trailing).foregroundStyle(Theme.dim)
                    Text(e.initials).frame(width: 44, alignment: .leading)
                    Spacer()
                    Text(formatScore(e.score))
                    if let w = onWatch {
                        if watchable(e) {
                            Button { w(e) } label: { Image(systemName: "play.circle") }
                                .buttonStyle(.plain).foregroundStyle(Theme.accent).help("Watch the replay of this game")
                        } else {
                            Image(systemName: "play.circle").hidden()
                        }
                    }
                }
                .font(.system(size: 13, weight: highlight.contains(i) ? .heavy : .regular, design: .monospaced))
                .foregroundStyle(highlight.contains(i) ? Theme.accent2 : Theme.text)
            }
        }
    }
}

/// The table's statistics (stats.json), one column per physics mode that has been played.
struct TableStatsView: View {
    var stats: [String: TableStats]

    private var modes: [(String, TableStats)] {
        GameSettings.PhysicsMode.allCases.compactMap { m in stats[m.rawValue].flatMap { $0.isEmpty ? nil : (m.rawValue.capitalized, $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("STATISTICS").font(.caption.bold()).foregroundStyle(Theme.accent)
            if modes.isEmpty {
                Text("No games played yet").font(.callout).foregroundStyle(Theme.dim)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    if modes.count > 1 || modes.first?.0 != "Classic" {
                        GridRow {
                            Text("")
                            ForEach(modes, id: \.0) { Text($0.0).foregroundStyle(Theme.dim).gridColumnAlignment(.trailing) }
                        }
                    }
                    row("Games") { "\($0.games)" }
                    row("Balls") { "\($0.balls)" }
                    row("Best") { $0.scores > 0 ? formatScore($0.bestScore) : "-" }
                    row("Average") { $0.averageScore.map(formatScore) ?? "-" }
                    row("Play time") { formatPlayTime($0.playSeconds) }
                }
                .font(.system(size: 12, design: .monospaced))
            }
        }
    }

    private func row(_ label: String, _ value: @escaping (TableStats) -> String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.dim)
            ForEach(modes, id: \.0) { Text(value($0.1)).gridColumnAlignment(.trailing) }
        }
    }
}

/// The selected table's replays: the last finished game and the ones kept with Save Replay.
struct ReplaysRow: View {
    var model: AppModel
    var table: Int
    var body: some View {
        let last = model.lastReplay(table)
        let saved = model.savedReplays(table)
        if last != nil || !saved.isEmpty {
            HStack {
                if let u = last {
                    Button { model.watch(u) } label: { Label("Watch last game", systemImage: "play.rectangle") }
                }
                if !saved.isEmpty {
                    Menu {
                        ForEach(saved) { r in
                            Button("\(r.header.date.formatted(date: .abbreviated, time: .shortened))  \(formatScore(r.header.finalScores.max() ?? 0))") {
                                model.watch(r.url)
                            }
                        }
                    } label: { Label("Saved replays", systemImage: "film.stack") }
                    .fixedSize()
                }
                Spacer()
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }
}

struct GameOptionsRow: View {
    @Bindable var settings: SettingsStore
    var body: some View {
        HStack {
            Picker("Players", selection: $settings.frontEnd.players) { ForEach(1...4, id: \.self) { Text("\($0)").tag($0) } }
                .frame(width: 130)
            Picker("Balls", selection: $settings.frontEnd.ballsPerGame) { ForEach(ballChoices(settings.frontEnd.ballsPerGame), id: \.self) { Text("\($0)").tag($0) } }
                .frame(width: 110)
        }
        .pickerStyle(.menu)
    }
}

/// The original's choices (3 or 5 balls), plus the stored value if it is another one
/// (settings.json or `--balls` allow 1-9), so the picker never shows an empty selection.
func ballChoices(_ current: Int) -> [Int] {
    [3, 5].contains(current) ? [3, 5] : ([3, 5, current]).sorted()
}

func formatScore(_ s: UInt32) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.groupingSeparator = ","
    return f.string(from: NSNumber(value: s)) ?? "\(s)"
}

/// The app's own mark: a ball between two flippers (abstract; no game artwork).
struct AppMark: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let r = CGRect(x: (size.width - s) / 2, y: (size.height - s) / 2, width: s, height: s)
            ctx.fill(Path(roundedRect: r, cornerRadius: s * 0.22), with: .linearGradient(
                Gradient(colors: [Color(red: 0.12, green: 0.10, blue: 0.30), Color(red: 0.03, green: 0.04, blue: 0.10)]),
                startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY)))
            func flipper(_ left: Bool) -> Path {
                var p = Path()
                let py = r.minY + s * 0.74, px = left ? r.minX + s * 0.22 : r.maxX - s * 0.22
                let tx = left ? r.midX - s * 0.06 : r.midX + s * 0.06, ty = r.minY + s * 0.82
                p.move(to: CGPoint(x: px, y: py)); p.addLine(to: CGPoint(x: tx, y: ty))
                return p.strokedPath(StrokeStyle(lineWidth: s * 0.09, lineCap: .round))
            }
            ctx.fill(flipper(true), with: .color(Theme.accent))
            ctx.fill(flipper(false), with: .color(Theme.accent2))
            let b = CGRect(x: r.midX - s * 0.13, y: r.minY + s * 0.22, width: s * 0.26, height: s * 0.26)
            ctx.fill(Path(ellipseIn: b), with: .radialGradient(Gradient(colors: [.white, Color(white: 0.55)]),
                                                                center: CGPoint(x: b.midX - s * 0.04, y: b.midY - s * 0.04),
                                                                startRadius: 0, endRadius: s * 0.16))
        }
    }
}

// MARK: - First launch

struct ImportView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            AppMark().frame(width: 96, height: 96)
            Text("Welcome to Epic Pinball HD").font(.system(size: 30, weight: .heavy, design: .rounded))
            Text("""
                This app plays the tables from your own copy of Epic Pinball. Choose the CD image \
                (for example the 1995 Complete Collection .iso) or a folder with the game's files \
                (EP1.EXE …). The game data is converted once and kept only on this Mac, in your \
                Library folder; nothing is uploaded or bundled with the app.
                """)
                .multilineTextAlignment(.center).foregroundStyle(Theme.dim).frame(maxWidth: 560)
            switch model.importState {
            case .idle:
                buttons
            case let .running(f, msg):
                VStack(spacing: 8) {
                    ProgressView(value: min(max(f, 0), 1)).frame(width: 420).tint(Theme.accent)
                    Text(msg).font(.callout).foregroundStyle(Theme.dim).lineLimit(2)
                }
            case let .failed(err):
                VStack(spacing: 10) {
                    Text("Import failed").font(.headline).foregroundStyle(.orange)
                    Text(err).font(.callout).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: 560)
                    buttons
                }
            case let .finished(n, warnings):
                ImportDonePanel(model: model, tables: n, warnings: warnings)
            }
            Spacer()
            Text("Developers: start with --data DIR to use an extracted/ directory instead.")
                .font(.caption).foregroundStyle(Theme.dim.opacity(0.7))
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .foregroundStyle(Theme.text)
    }

    private var buttons: some View {
        HStack(spacing: 14) {
            Button { model.openImportPanel(directories: false) } label: { Label("Choose CD image…", systemImage: "opticaldisc") }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            Button { model.openImportPanel(directories: true) } label: { Label("Choose game folder…", systemImage: "folder") }
                .buttonStyle(.bordered)
            if model.library != nil {
                Button("Cancel") { model.screen = .picker }.buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
    }
}
