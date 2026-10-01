import Foundation
import PinballCore

/// Attract mode in the front end (docs/enhanced/attract.md). The original has no idle state inside a
/// table: PINBALL.EXE's menu counts 900 idle frames (file 0x843..0x85C) and then starts a table with
/// players 'D', which plays itself until any key or game over sends it back to the menu. The app
/// maps that onto its own screens:
/// * a table whose game has not started (no game key since it was set up), or whose game-over panel
///   has been left alone, switches to a demo game after the same idle time; any key or controller
///   button leaves it for a fresh game, and a demo game over goes back to that ready state;
/// * the table picker, after the same idle time, opens the selected table in attract mode; a key or
///   the demo's game over returns to the picker, as the original returns to its menu.
/// The demo itself is the original's code (`RulesOptions.demo`, ClassicEngine+Attract.swift). Attract
/// games never reach the high-score book.
@MainActor
final class AttractTracker {
    /// PINBALL.EXE's 900 idle menu frames, at the table frame rate ([M]: the menu's own frame rate
    /// was not measured), or `--attract-delay S`.
    static var idleSeconds: Double { delayOverride ?? 900 / 59.94 }
    nonisolated(unsafe) static var delayOverride: Double?

    struct Session: Equatable {
        /// Started by the launcher's idle timer: leaving returns to the picker.
        var fromLauncher: Bool
    }

    /// FrontEndSettings.attractMode (and the table has the demo code).
    var enabled = false
    /// Seconds without input in an eligible state.
    var idle: Double = 0
    /// A game key was used since the current game was set up: the game has started.
    var touched = false
    var session: Session?
    var active: Bool { session != nil }
}

extension GameController {
    /// The table can run the original's demo (its code was found in the EXE and the rules run).
    var attractAvailable: Bool { sim.engine.attractLayout != nil && sim.engine.rules != nil && presentationSource != nil }

    /// Starts a demo game now (idle timeout, the launcher's timer, or `--attract`).
    func enterAttract(fromLauncher: Bool) {
        guard attractAvailable else { return }
        attract.session = AttractTracker.Session(fromLauncher: fromLauncher)
        attract.idle = 0
        var o = rulesOptions
        o.demo = true
        // The original's demo never plunges on EP2-EP13 (no cs:0B79); the app releases at full charge there.
        sim.engine.attractLaunch = true
        sim.inputProvider = nil
        startFreshGame(options: o)
        // No split line in demo mode (cs:0E9D..0F54 is skipped): the original shows no score panel.
        presentation?.setStrip(shown: false, immediately: true)
    }

    /// Ends the demo: a fresh game on this table, or back to the picker when the launcher started it.
    func leaveAttract() {
        guard let s = attract.session else { return }
        attract.session = nil
        sim.engine.attractLaunch = false
        if s.fromLauncher, let back = onReturnToPicker {
            DispatchQueue.main.async { back() }   // not from inside draw(in:) or a key event of this view
            return
        }
        newGame()
        presentation?.setStrip(shown: store.map { mainWindowShowsStrip($0) } ?? true, immediately: true)
    }

    /// A key or button while the demo runs: the original's key test (cs:0CFF) ends the demo once its
    /// key-repeat counter is 0. Returns true when the input was taken by attract mode.
    func attractInput() -> Bool {
        attract.idle = 0
        guard attract.active else { return false }
        if sim.engine.demoAcceptsKey { leaveAttract() }
        return true
    }

    /// The demo game is over: the original quits to the menu (cs:34C3 / EP10 cs:052C); no high scores.
    func attractGameOver() { leaveAttract() }

    /// Once per display frame: counts idle time in the states where the original would sit in its
    /// menu, and starts the demo after `AttractTracker.idleSeconds`.
    func attractTick(dt: Double) {
        guard attract.enabled, !attract.active, session == .normal, attractAvailable, sim.inputProvider == nil, demo == nil, !paused,
              view?.window?.attachedSheet == nil else { attract.idle = 0; return }
        let ready = overlay.mode == .none && !gameOver && !attract.touched
        guard ready || overlay.mode == .gameOver else { attract.idle = 0; return }
        attract.idle += min(max(dt, 0), 0.25)
        if attract.idle >= AttractTracker.idleSeconds { enterAttract(fromLauncher: false) }
    }
}
