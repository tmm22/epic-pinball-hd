import AppKit
import SwiftUI

/// `--ui-snapshot PATH --ui-screen S`: renders a front-end screen in an offscreen window and
/// writes it as PNG (verification without driving the UI). The overlay screens are drawn over
/// a plain background with sample scores; the launcher shows the user's tables and scores.
enum UISnapshot {
    @MainActor
    static func run(screen: String, model: AppModel, size: (Int, Int)?, to path: String) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let (w, h) = size ?? (1180, 800)
        let content: AnyView
        switch screen {
        case "import":
            model.screen = .importer
            content = AnyView(ImportView(model: model))
        case "settings":
            content = AnyView(SettingsView(model: model) {}.background(Color(nsColor: .windowBackgroundColor)))
        case "pause", "initials", "gameover":
            let o = OverlayModel()
            o.tableName = model.selectedTable?.name ?? "Table 1"
            o.finalScores = [1_234_560, 987_650]
            let sample = ["ABC", "PJM", "ZZZ", "KID", "ACE"].enumerated().map { i, s in
                HighScoreEntry(initials: s, score: UInt32(5_000_000 - i * 750_000), date: Date())
            }
            o.entries = sample
            o.highlight = [2]
            o.initials = InitialsEntry(start: "PA")
            o.initials.position = 2
            o.initialsScore = 1_234_560
            o.initialsPrompt = "Player 1, enter your initials"
            o.mode = screen == "pause" ? .pauseMenu : screen == "initials" ? .initials : .gameOver
            content = AnyView(ZStack {
                if let img = model.selectedTable?.preview {
                    Image(decorative: img, scale: 1).resizable().interpolation(.none).aspectRatio(contentMode: .fill)
                } else {
                    Theme.background
                }
                GameOverlayView(model: o)
            })
        default:
            model.screen = .picker
            content = AnyView(LauncherView(model: model))
        }
        let host = NSHostingView(rootView: content.frame(width: CGFloat(w), height: CGFloat(h)))
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: w, height: h), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw NSError(domain: "UISnapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "no bitmap"])
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "UISnapshot", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
        window.orderOut(nil)
        print("wrote \(url.path) (\(rep.pixelsWide)x\(rep.pixelsHigh), \(screen), \(model.tables.filter(\.available).count) tables available, "
              + "library \(model.library?.dataRoot.path ?? "none"))")
    }
}
