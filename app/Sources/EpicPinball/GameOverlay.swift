import Observation
import SwiftUI

/// What is drawn over the running table: the pause menu (Esc), the initials entry after a
/// game that made the high-score list, and the game-over panel. Input is routed here by
/// `GameController` (keyboard and controller), the mouse works on the buttons too.
@MainActor
@Observable
final class OverlayModel {
    enum Mode: Equatable { case none, pauseMenu, initials, gameOver }

    enum Item: String, CaseIterable {
        case resume = "Resume", newGame = "New Game", settings = "Settings…", chooseTable = "Choose Table", quit = "Quit"
        // Replays and practice (Replays.swift)
        case practice = "Practice Mode", saveState = "Save State", loadState = "Restore State", endPractice = "End Practice"
        case saveReplay = "Save Replay", watchReplay = "Watch Replay", watchAgain = "Watch Again"
    }

    var mode: Mode = .none
    var index = 0
    var tableName = ""
    // Initials entry
    var initials = InitialsEntry()
    var initialsPrompt = ""
    var initialsScore: UInt32 = 0
    // Game over
    var finalScores: [UInt32] = []
    var entries: [HighScoreEntry] = []
    var highlight: Set<Int> = []
    // Replays and practice
    var session: SessionKind = .normal
    /// The game just finished has a replay (game over: Save Replay / Watch Replay).
    var replayAvailable = false
    var replaySaved = false
    /// Practice: the current slot has a state (this session or on disk).
    var stateSaved = false
    /// Practice: the slot Save State / Restore State use (1-4).
    var stateSlot = 1
    /// A line under the scores (replay check, "practice games are not scored").
    var note: String?

    @ObservationIgnored var onItem: ((Item) -> Void)?

    var items: [Item] {
        switch (mode, session) {
        case (.pauseMenu, .normal): return [.resume, .newGame, .practice, .settings, .chooseTable, .quit]
        case (.pauseMenu, .practice):
            return [.resume, .saveState] + (stateSaved ? [.loadState] : []) + [.newGame, .endPractice, .settings, .chooseTable, .quit]
        case (.pauseMenu, .watching): return [.resume, .watchAgain, .settings, .chooseTable, .quit]
        case (.gameOver, .normal):
            return [.newGame] + (replayAvailable ? [.saveReplay, .watchReplay] : []) + [.chooseTable, .settings, .quit]
        case (.gameOver, .practice): return (stateSaved ? [.loadState] : []) + [.newGame, .endPractice, .chooseTable, .settings, .quit]
        case (.gameOver, .watching): return [.watchAgain, .chooseTable, .quit]
        default: return []
        }
    }

    func label(_ it: Item) -> String {
        switch it {
        case .saveReplay where replaySaved: return "Replay Saved"
        case .saveState, .loadState: return "\(it.rawValue) (Slot \(stateSlot))"
        default: return it.rawValue
        }
    }

    var gameOverTitle: String {
        switch session {
        case .normal: return "Game Over"
        case .practice: return "Practice Over"
        case .watching: return "Replay Finished"
        }
    }

    var active: Bool { mode != .none }

    func moveSelection(_ d: Int) {
        let n = items.count
        guard n > 0 else { return }
        index = ((index + d) % n + n) % n
    }

    func activate() {
        let it = items
        guard index < it.count else { return }
        onItem?(it[index])
    }
}

struct GameOverlayView: View {
    @Bindable var model: OverlayModel
    /// Cabinet: turned with the picture (OverlayRotation.swift).
    var orientation = OverlayOrientation()

    var body: some View {
        ZStack {
            if model.active { Color.black.opacity(0.55).ignoresSafeArea() }
            switch model.mode {
            case .none: EmptyView()
            case .pauseMenu: menuPanel(title: model.session == .practice ? "Practice" : (model.session == .watching ? "Replay Paused" : "Paused"),
                                       subtitle: model.tableName)
            case .gameOver: gameOverPanel
            case .initials: initialsPanel
            }
        }
        .foregroundStyle(Theme.text)
        .allowsHitTesting(model.active)
        .cabinetRotated(orientation.rotation)
    }

    private func panel<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 14, content: c)
            .padding(28)
            .frame(minWidth: 320)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.07, green: 0.07, blue: 0.13).opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.accent.opacity(0.6), lineWidth: 1.5))
            .shadow(radius: 20)
    }

    private func menuPanel(title: String, subtitle: String) -> some View {
        panel {
            Text(title).font(.system(size: 30, weight: .heavy, design: .rounded))
            if !subtitle.isEmpty { Text(subtitle).foregroundStyle(Theme.dim) }
            menuItems
            Text("Up/Down and Return, or Esc to resume").font(.caption).foregroundStyle(Theme.dim)
        }
    }

    private var menuItems: some View {
        VStack(spacing: 6) {
            ForEach(Array(model.items.enumerated()), id: \.offset) { i, it in
                Button { model.index = i; model.activate() } label: {
                    Text(model.label(it)).font(.system(size: 17, weight: .semibold, design: .rounded))
                        .frame(width: 220).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(i == model.index ? Theme.accent : Color.white.opacity(0.08)))
                        .foregroundStyle(i == model.index ? Color.black : Theme.text)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var gameOverPanel: some View {
        panel {
            Text(model.gameOverTitle).font(.system(size: 30, weight: .heavy, design: .rounded))
            Text(model.tableName).foregroundStyle(Theme.dim)
            if !model.finalScores.isEmpty {
                HStack(spacing: 18) {
                    ForEach(Array(model.finalScores.enumerated()), id: \.offset) { i, s in
                        VStack {
                            if model.finalScores.count > 1 { Text("Player \(i + 1)").font(.caption).foregroundStyle(Theme.dim) }
                            Text(formatScore(s)).font(.system(size: 20, weight: .bold, design: .monospaced))
                        }
                    }
                }
            }
            if let n = model.note { Text(n).font(.caption).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(width: 300) }
            HighScoreList(entries: model.entries, highlight: model.highlight).frame(width: 260)
            menuItems
        }
    }

    private var initialsPanel: some View {
        panel {
            Text("High Score!").font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(Theme.accent2)
            Text(model.initialsPrompt).foregroundStyle(Theme.dim)
            Text(formatScore(model.initialsScore)).font(.system(size: 24, weight: .bold, design: .monospaced))
            HStack(spacing: 10) {
                ForEach(0..<HighScoreBook.initialsLength, id: \.self) { i in
                    let ch = model.initials.letters[i]
                    Text(ch == " " ? "_" : String(ch))
                        .font(.system(size: 40, weight: .heavy, design: .monospaced))
                        .frame(width: 54, height: 64)
                        .background(RoundedRectangle(cornerRadius: 8).fill(i == model.initials.position ? Theme.accent.opacity(0.35) : Color.white.opacity(0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(i == model.initials.position ? Theme.accent : .clear, lineWidth: 2))
                }
            }
            Text("Flippers or Up/Down pick a letter, plunger or Return takes it. Or just type.")
                .font(.caption).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(width: 300)
        }
    }
}
