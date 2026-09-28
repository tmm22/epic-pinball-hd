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

    @ObservationIgnored var onItem: ((Item) -> Void)?

    var items: [Item] {
        switch mode {
        case .pauseMenu: return Item.allCases
        case .gameOver: return [.newGame, .chooseTable, .settings, .quit]
        default: return []
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

    var body: some View {
        ZStack {
            if model.active { Color.black.opacity(0.55).ignoresSafeArea() }
            switch model.mode {
            case .none: EmptyView()
            case .pauseMenu: menuPanel(title: "Paused", subtitle: model.tableName)
            case .gameOver: gameOverPanel
            case .initials: initialsPanel
            }
        }
        .foregroundStyle(Theme.text)
        .allowsHitTesting(model.active)
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
                    Text(it.rawValue).font(.system(size: 17, weight: .semibold, design: .rounded))
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
            Text("Game Over").font(.system(size: 30, weight: .heavy, design: .rounded))
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
