import Foundation
import Observation
import PinballCore
import SwiftUI

// Replays and practice mode in the front end (docs/enhanced/replays.md): where replay files live,
// which ones are kept, and the in-game banner (HUD) for watching a replay or practising.

extension AppPaths {
    /// `<support>/Replays/`: `EPn-last.epreplay` (the last finished game of table n, replaced by the
    /// next one), `EPn-hs-<date>-<score>.epreplay` (kept while a high-score entry links to it) and
    /// `EPn-saved-<date>-<score>.epreplay` (kept with "Save Replay" until the user deletes it).
    static var replaysDirectory: URL { supportRoot.appendingPathComponent("Replays", isDirectory: true) }
}

/// A replay file with its header (for lists).
struct ReplayInfo: Identifiable, Equatable {
    var name: String
    var header: ReplayHeader
    var id: String { name }
    var url: URL { AppPaths.replaysDirectory.appendingPathComponent(name) }
}

/// The Replays directory: last game, high-score games, saved games.
struct ReplayLibrary: Sendable {
    enum Kind: String { case highScore = "hs", saved }

    /// The app's version for replay headers (the bundle's, "dev" from `swift run`).
    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    var directory: URL { AppPaths.replaysDirectory }

    static func lastName(table: Int) -> String { "EP\(table)-last.\(ReplayFormat.fileExtension)" }
    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }
    func lastURL(table: Int) -> URL? {
        let n = Self.lastName(table: table)
        return exists(n) ? url(n) : nil
    }

    /// Writes the table's last game (replacing the previous one).
    func saveLast(_ r: Replay) throws {
        try r.write(to: url(Self.lastName(table: r.header.table)))
    }

    /// Keeps `r` under a new name; returns the file name.
    func keep(_ r: Replay, kind: Kind) throws -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let score = r.header.finalScores.max() ?? 0
        var name = "EP\(r.header.table)-\(kind.rawValue)-\(f.string(from: r.header.date))-\(score).\(ReplayFormat.fileExtension)"
        var k = 2
        while exists(name) {
            name = "EP\(r.header.table)-\(kind.rawValue)-\(f.string(from: r.header.date))-\(score)-\(k).\(ReplayFormat.fileExtension)"
            k += 1
        }
        try r.write(to: url(name))
        return name
    }

    /// The file names in the directory (empty if it does not exist yet).
    func names() -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []) }

    /// Saved replays of `table`, newest first (files that do not decode are skipped).
    func saved(table: Int) -> [ReplayInfo] {
        let prefix = "EP\(table)-\(Kind.saved.rawValue)-"
        return names().filter { $0.hasPrefix(prefix) && $0.hasSuffix(".\(ReplayFormat.fileExtension)") }
            .compactMap { n in (try? Replay.load(contentsOf: url(n))).map { ReplayInfo(name: n, header: $0.header) } }
            .sorted { $0.header.date != $1.header.date ? $0.header.date > $1.header.date : $0.name > $1.name }
    }

    /// Deletes `table`'s high-score replays that no entry links to any more (pushed off the list).
    func prune(table: Int, referenced: Set<String>) {
        let prefix = "EP\(table)-\(Kind.highScore.rawValue)-"
        for n in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where n.hasPrefix(prefix) && !referenced.contains(n) {
            try? FileManager.default.removeItem(at: url(n))
        }
    }
}

/// What the running table is: a normal game (scores, replay recorded), a practice game (save
/// states; no high scores, no statistics, no replay) or a replay being watched (no input, no
/// high scores, no statistics).
enum SessionKind: Equatable { case normal, practice, watching }

/// The banner over the running table in practice and replay sessions.
@MainActor
@Observable
final class HUDModel {
    var session: SessionKind = .normal
    /// Practice: the current save slot (1-4).
    var slot = 1
    /// Short status line ("State saved"), cleared after a while.
    var flash: String?
    @ObservationIgnored private var flashToken = 0
    // Watching
    var paused = false
    var speed = 1
    var progress = 0.0
    var finished = false
    @ObservationIgnored var onPauseToggle: (() -> Void)?
    @ObservationIgnored var onSpeed: ((Int) -> Void)?
    @ObservationIgnored var onExit: (() -> Void)?

    func show(_ s: String, seconds: Double = 2) {
        flash = s
        flashToken += 1
        let t = flashToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { if self?.flashToken == t { self?.flash = nil } }
        }
    }
}

struct GameHUDView: View {
    @Bindable var model: HUDModel
    /// Cabinet: turned with the picture (OverlayRotation.swift).
    var orientation = OverlayOrientation()

    var body: some View {
        VStack {
            HStack(alignment: .top) {
                switch model.session {
                case .normal: EmptyView()
                case .practice: practiceBadge
                case .watching: replayBar
                }
                Spacer()
            }
            Spacer()
            if let f = model.flash {
                Text(f).font(.system(size: 15, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
                    .padding(.bottom, 24)
            }
        }
        .padding(12)
        .foregroundStyle(Theme.text)
        .cabinetRotated(orientation.rotation)
    }

    private func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 13, weight: .heavy, design: .rounded)).tracking(1.5)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(c))
            .foregroundStyle(Color.black)
    }

    private var practiceBadge: some View {
        HStack(spacing: 10) {
            badge("PRACTICE", Theme.accent2)
            Text("K save state · L restore · 1-4 slot (\(model.slot)) · no scores").font(.caption).foregroundStyle(Theme.dim)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.6)))
        .allowsHitTesting(false)
    }

    private var replayBar: some View {
        HStack(spacing: 8) {
            badge("REPLAY", Theme.accent)
            Button { model.onPauseToggle?() } label: {
                Image(systemName: model.paused || model.finished ? "play.fill" : "pause.fill").frame(width: 16)
            }
            .disabled(model.finished)
            ForEach([1, 2, 4], id: \.self) { s in
                Button { model.onSpeed?(s) } label: {
                    Text("\(s)x").font(.system(size: 12, weight: model.speed == s ? .heavy : .regular, design: .rounded))
                }
                .tint(model.speed == s ? Theme.accent : nil)
            }
            ProgressView(value: min(max(model.progress, 0), 1)).frame(width: 110).tint(Theme.accent)
            Button("Exit") { model.onExit?() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.6)))
    }
}
