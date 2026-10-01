import AppKit
import CoreHaptics
import Foundation
import GameController
import PinballCore

/// Everything a key can be bound to. Game actions map to the original's input flags
/// (keyboard_isr EP1 cs:314B, docs/formats/engine.md section 5); the rest are front-end commands.
enum GameAction: String, CaseIterable, Codable, Sendable {
    case leftFlipper, rightFlipper
    /// The original's Ctrl: plunger only.
    case plunger
    /// The original's Space: plunger while the ball is in the lane, nudge elsewhere.
    case launchOrNudge
    /// Z / ',' (nudge A, vx +20) and '/' (nudge B, vx -20).
    case nudgeA, nudgeB
    case scrollUp, scrollDown
    case toggleStrip, pause, menu, restart
    case toggleMusic, toggleSfx
    case volumeDown, volumeUp, musicDown, musicUp
    case fullTable, cycleFilter, pixelAspect, physicsMode
    /// Saves the current output frame as a PNG (Settings > Display > Screenshots).
    case screenshot
    /// FPS / frame time / input latency overlay.
    case perfOverlay
    /// Practice mode: save / restore the whole simulation state.
    case saveState, loadState

    var label: String {
        switch self {
        case .leftFlipper: return "Left flipper"
        case .rightFlipper: return "Right flipper"
        case .plunger: return "Plunger"
        case .launchOrNudge: return "Plunger in lane / nudge"
        case .nudgeA: return "Nudge (ball right)"
        case .nudgeB: return "Nudge (ball left)"
        case .scrollUp: return "Scroll up"
        case .scrollDown: return "Scroll down"
        case .toggleStrip: return "Show / hide score strip"
        case .pause: return "Pause"
        case .menu: return "Menu"
        case .restart: return "New game"
        case .toggleMusic: return "Music on / off"
        case .toggleSfx: return "Sound effects on / off"
        case .volumeDown: return "Volume down"
        case .volumeUp: return "Volume up"
        case .musicDown: return "Music volume down"
        case .musicUp: return "Music volume up"
        case .fullTable: return "Full table view"
        case .cycleFilter: return "Cycle upscale filter"
        case .pixelAspect: return "Pixel aspect"
        case .physicsMode: return "Classic / enhanced"
        case .screenshot: return "Save screenshot"
        case .perfOverlay: return "Performance overlay"
        case .saveState: return "Practice: save state"
        case .loadState: return "Practice: restore state"
        }
    }

    /// Held actions feed the simulation every frame; the others fire once per key press.
    var isHeld: Bool {
        switch self {
        case .leftFlipper, .rightFlipper, .plunger, .launchOrNudge, .nudgeA, .nudgeB, .scrollUp, .scrollDown: return true
        default: return false
        }
    }

    /// Key presses that repeat while held (volume steps).
    var repeats: Bool { [.volumeDown, .volumeUp, .musicDown, .musicUp].contains(self) }
}

/// macOS virtual key codes (kVK_*, ANSI positions) used by the defaults and the key-name table.
enum KeyCode {
    static let a: UInt16 = 0, s: UInt16 = 1, f: UInt16 = 3, z: UInt16 = 6, x: UInt16 = 7, e: UInt16 = 14, r: UInt16 = 15
    static let k: UInt16 = 40, l: UInt16 = 37
    static let equal: UInt16 = 24, minus: UInt16 = 27, rightBracket: UInt16 = 30, leftBracket: UInt16 = 33, p: UInt16 = 35
    static let returnKey: UInt16 = 36, comma: UInt16 = 43, slash: UInt16 = 44, m: UInt16 = 46, period: UInt16 = 47
    static let tab: UInt16 = 48, space: UInt16 = 49, delete: UInt16 = 51, escape: UInt16 = 53
    static let rightCommand: UInt16 = 54, leftCommand: UInt16 = 55, leftShift: UInt16 = 56, capsLock: UInt16 = 57
    static let leftOption: UInt16 = 58, leftControl: UInt16 = 59, rightShift: UInt16 = 60, rightOption: UInt16 = 61
    static let rightControl: UInt16 = 62, keypadEnter: UInt16 = 76
    static let f10: UInt16 = 109, f12: UInt16 = 111
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126

    /// Modifier keys arrive as flagsChanged; their state is read from the device-dependent
    /// bits of the modifier flags (NX_DEVICE*KEYMASK), which tell left from right.
    static let modifierMasks: [(code: UInt16, mask: UInt)] = [
        (leftShift, 0x02), (rightShift, 0x04), (leftControl, 0x01), (rightControl, 0x2000),
        (leftOption, 0x20), (rightOption, 0x40), (leftCommand, 0x08), (rightCommand, 0x10),
    ]

    static let names: [UInt16: String] = {
        var n: [UInt16: String] = [
            leftShift: "Left Shift", rightShift: "Right Shift", leftControl: "Left Control", rightControl: "Right Control",
            leftOption: "Left Option", rightOption: "Right Option", leftCommand: "Left Command", rightCommand: "Right Command",
            capsLock: "Caps Lock", space: "Space", returnKey: "Return", keypadEnter: "Enter", tab: "Tab", escape: "Esc",
            delete: "Delete", left: "Left Arrow", right: "Right Arrow", up: "Up Arrow", down: "Down Arrow",
            comma: ",", period: ".", slash: "/", minus: "-", equal: "=", leftBracket: "[", rightBracket: "]",
            39: "'", 41: ";", 42: "\\", 50: "`", 117: "Forward Delete", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12",
        ]
        let letters: [(UInt16, String)] = [
            (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"), (38, "J"), (40, "K"),
            (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"), (15, "R"), (1, "S"), (17, "T"), (32, "U"),
            (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z"),
            (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9"),
            (82, "Keypad 0"), (83, "Keypad 1"), (84, "Keypad 2"), (85, "Keypad 3"), (86, "Keypad 4"), (87, "Keypad 5"),
            (88, "Keypad 6"), (89, "Keypad 7"), (91, "Keypad 8"), (92, "Keypad 9"), (65, "Keypad ."), (67, "Keypad *"),
            (69, "Keypad +"), (78, "Keypad -"), (75, "Keypad /"),
        ]
        for (c, s) in letters { n[c] = s }
        return n
    }()

    static func name(_ code: UInt16) -> String { names[code] ?? "Key \(code)" }

    /// Letter or digit typed by `code` (initials entry), independent of the keyboard layout's
    /// modifiers. Uses the ANSI table above.
    static func character(_ code: UInt16) -> Character? {
        guard let s = names[code], s.count == 1, let ch = s.first, ch.isLetter || ch.isNumber else { return nil }
        return ch
    }
}

/// Action -> key codes. Stored by action name so an unknown action in the file is ignored.
struct KeyBindings: Codable, Equatable, Sendable {
    var map: [String: [UInt16]]

    /// The original's keys (engine.md section 5): Shift or arrows flip, Ctrl plunges, Space
    /// plunges in the lane and nudges elsewhere, Z / ',' and '/' nudge, '.' and X also work the
    /// right flipper. The rest are the port's keys (app/README.md).
    static let defaults = KeyBindings(map: [
        GameAction.leftFlipper.rawValue: [KeyCode.leftShift, KeyCode.left],
        GameAction.rightFlipper.rawValue: [KeyCode.rightShift, KeyCode.right, KeyCode.period, KeyCode.x],
        GameAction.plunger.rawValue: [KeyCode.leftControl, KeyCode.rightControl],
        GameAction.launchOrNudge.rawValue: [KeyCode.space],
        GameAction.nudgeA.rawValue: [KeyCode.z, KeyCode.comma],
        GameAction.nudgeB.rawValue: [KeyCode.slash],
        GameAction.scrollUp.rawValue: [KeyCode.up],
        GameAction.scrollDown.rawValue: [KeyCode.down],
        GameAction.toggleStrip.rawValue: [KeyCode.returnKey, KeyCode.keypadEnter],
        GameAction.pause.rawValue: [KeyCode.p],
        GameAction.menu.rawValue: [KeyCode.escape],
        GameAction.restart.rawValue: [KeyCode.r],
        GameAction.toggleMusic.rawValue: [KeyCode.m],
        GameAction.toggleSfx.rawValue: [KeyCode.s],
        GameAction.volumeDown.rawValue: [KeyCode.minus],
        GameAction.volumeUp.rawValue: [KeyCode.equal],
        GameAction.musicDown.rawValue: [KeyCode.leftBracket],
        GameAction.musicUp.rawValue: [KeyCode.rightBracket],
        GameAction.fullTable.rawValue: [KeyCode.tab],
        GameAction.cycleFilter.rawValue: [KeyCode.f],
        GameAction.pixelAspect.rawValue: [KeyCode.a],
        GameAction.physicsMode.rawValue: [KeyCode.e],
        // Function keys: the original reads none in play (F1 only inside its quit prompt), so
        // these never shadow a table key. Also in the menus: Shift-Cmd-S, View > Performance Overlay.
        GameAction.screenshot.rawValue: [KeyCode.f12],
        GameAction.perfOverlay.rawValue: [KeyCode.f10],
        GameAction.saveState.rawValue: [KeyCode.k],
        GameAction.loadState.rawValue: [KeyCode.l],
    ])

    init(map: [String: [UInt16]]) { self.map = map }

    init(from decoder: Decoder) throws {
        let stored = try decoder.singleValueContainer().decode([String: [UInt16]].self)
        var m = Self.defaults.map
        for a in GameAction.allCases { if let k = stored[a.rawValue] { m[a.rawValue] = k } }
        // An action the file does not know yet (added by a later build) gets its default keys
        // only where the user has not bound them to something else.
        let used = Set(GameAction.allCases.filter { stored[$0.rawValue] != nil }.flatMap { m[$0.rawValue] ?? [] })
        for a in GameAction.allCases where stored[a.rawValue] == nil { m[a.rawValue]?.removeAll { used.contains($0) } }
        // The menu must stay reachable from the keyboard.
        if m[GameAction.menu.rawValue]?.isEmpty ?? true { m[GameAction.menu.rawValue] = [KeyCode.escape] }
        map = m
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(map)
    }

    func keys(_ a: GameAction) -> [UInt16] { map[a.rawValue] ?? [] }

    /// Actions bound to `code` (a key may drive several, e.g. by user choice).
    func actions(for code: UInt16) -> [GameAction] { GameAction.allCases.filter { keys($0).contains(code) } }

    /// Binds `code` to `action` only (removes it from any other action). `replace` drops the
    /// action's other keys; otherwise the key is added.
    mutating func bind(_ code: UInt16, to action: GameAction, replace: Bool) {
        for a in GameAction.allCases { map[a.rawValue]?.removeAll { $0 == code } }
        if replace { map[action.rawValue] = [code] } else { map[action.rawValue, default: []].append(code) }
        if map[GameAction.menu.rawValue]?.isEmpty ?? true { map[GameAction.menu.rawValue] = [KeyCode.escape] }
    }

    func label(_ a: GameAction) -> String {
        let k = keys(a)
        return k.isEmpty ? "(none)" : k.map(KeyCode.name).joined(separator: ", ")
    }

    /// The simulation input for a set of held keys (keyboard_isr's flags).
    func frameInput(held: Set<UInt16>) -> FrameInput {
        var i: FrameInput = []
        func on(_ a: GameAction) -> Bool { keys(a).contains { held.contains($0) } }
        if on(.leftFlipper) { i.insert(.leftFlipper) }
        if on(.rightFlipper) { i.insert(.rightFlipper) }
        if on(.plunger) { i.insert(.plunger) }
        if on(.launchOrNudge) { i.insert(.space) }
        if on(.nudgeA) { i.insert(.nudgeA) }
        if on(.nudgeB) { i.insert(.nudgeB) }
        return i
    }

    func scroll(held: Set<UInt16>) -> Int {
        (keys(.scrollDown).contains { held.contains($0) } ? 1 : 0) - (keys(.scrollUp).contains { held.contains($0) } ? 1 : 0)
    }
}

/// Held keys, with modifiers tracked per side from flagsChanged. Reports presses and releases
/// so callers get edges for modifier keys (flippers on Shift) as for ordinary keys.
struct KeyboardState {
    private(set) var held = Set<UInt16>()

    /// Returns the key codes pressed and released by this modifier-flags change.
    mutating func modifiersChanged(rawFlags: UInt, capsLock: Bool) -> (pressed: [UInt16], released: [UInt16]) {
        var pressed: [UInt16] = [], released: [UInt16] = []
        for (code, mask) in KeyCode.modifierMasks {
            let down = rawFlags & mask != 0
            if down, !held.contains(code) { held.insert(code); pressed.append(code) }
            if !down, held.contains(code) { held.remove(code); released.append(code) }
        }
        if capsLock != held.contains(KeyCode.capsLock) {
            if capsLock { held.insert(KeyCode.capsLock); pressed.append(KeyCode.capsLock) } else {
                held.remove(KeyCode.capsLock); released.append(KeyCode.capsLock)
            }
        }
        return (pressed, released)
    }

    /// Returns true when the key was not already held.
    @discardableResult
    mutating func press(_ code: UInt16) -> Bool { held.insert(code).inserted }
    mutating func release(_ code: UInt16) { held.remove(code) }
    mutating func releaseAll() { held.removeAll() }
}

// MARK: - Game controllers

/// Buttons of the menu layer (pause menu, initials, launcher), as edges.
enum PadButton: Sendable { case up, down, left, right, accept, back, menu }

/// Polls every connected extended gamepad (MFi, Xbox, DualShock/DualSense) once per display
/// frame. In game: shoulders or triggers flip, A (or D-pad down / right stick down) holds the
/// plunger, the left stick nudges (right = nudge A, left = nudge B), B nudges like Space,
/// Menu opens the pause menu. Optional haptics: a short tick on flipper presses and nudges.
@MainActor
final class GamepadInput {
    var enabled = true
    var hapticsEnabled = true
    private(set) var connected: [String] = []
    /// Called when a controller goes away while controllers are enabled (the game pauses).
    var onDisconnect: (() -> Void)?
    private var lastButtons: Set<String> = []
    private var lastInput: FrameInput = []
    private var hapticEngines: [ObjectIdentifier: CHHapticEngine] = [:]
    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                if self?.enabled == true { self?.onDisconnect?() }
            }
        })
        // No startWirelessControllerDiscovery: controllers paired in System Settings connect on their
        // own, and discovery would need Bluetooth permission.
        GCController.shouldMonitorBackgroundEvents = false
        refresh()
    }

    func invalidate() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        for e in hapticEngines.values { e.stop() }
        hapticEngines.removeAll()
    }

    private func refresh() {
        connected = GCController.controllers().compactMap { $0.extendedGamepad != nil ? ($0.vendorName ?? "Game controller") : nil }
    }

    /// The simulation input from all controllers (empty when disabled or none connected).
    func frameInput() -> FrameInput {
        guard enabled else { return [] }
        var i: FrameInput = []
        for c in GCController.controllers() {
            guard let g = c.extendedGamepad else { continue }
            if g.leftShoulder.isPressed || g.leftTrigger.value > 0.3 { i.insert(.leftFlipper) }
            if g.rightShoulder.isPressed || g.rightTrigger.value > 0.3 { i.insert(.rightFlipper) }
            if g.buttonA.isPressed || g.dpad.down.isPressed || g.rightThumbstick.yAxis.value < -0.6 { i.insert(.plunger) }
            if g.buttonB.isPressed { i.insert(.space) }
            let x = g.leftThumbstick.xAxis.value
            if x > 0.6 { i.insert(.nudgeA) } else if x < -0.6 { i.insert(.nudgeB) }
        }
        let newly = i.subtracting(lastInput)
        if hapticsEnabled, !newly.isDisjoint(with: [.leftFlipper, .rightFlipper, .nudgeA, .nudgeB]) {
            pulse(intensity: newly.isDisjoint(with: [.nudgeA, .nudgeB]) ? 0.45 : 0.9)
        }
        lastInput = i
        return i
    }

    /// Scroll from the right stick (-1 up, +1 down).
    func scroll() -> Int {
        guard enabled else { return 0 }
        for c in GCController.controllers() {
            guard let g = c.extendedGamepad else { continue }
            let y = g.rightThumbstick.yAxis.value
            if y > 0.6 { return -1 }
        }
        return 0
    }

    /// Menu-layer button edges since the previous call.
    func menuPresses() -> [PadButton] {
        guard enabled else { lastButtons = []; return [] }
        var now = Set<String>()
        for c in GCController.controllers() {
            guard let g = c.extendedGamepad else { continue }
            if g.dpad.up.isPressed || g.leftThumbstick.yAxis.value > 0.6 { now.insert("up") }
            if g.dpad.down.isPressed || g.leftThumbstick.yAxis.value < -0.6 { now.insert("down") }
            if g.dpad.left.isPressed || g.leftShoulder.isPressed { now.insert("left") }
            if g.dpad.right.isPressed || g.rightShoulder.isPressed { now.insert("right") }
            if g.buttonA.isPressed { now.insert("accept") }
            if g.buttonB.isPressed { now.insert("back") }
            if g.buttonMenu.isPressed { now.insert("menu") }
        }
        let edges = now.subtracting(lastButtons)
        lastButtons = now
        let order: [(String, PadButton)] = [("up", .up), ("down", .down), ("left", .left), ("right", .right),
                                            ("accept", .accept), ("back", .back), ("menu", .menu)]
        return order.compactMap { edges.contains($0.0) ? $0.1 : nil }
    }

    /// Forget held state (so a button held across a mode switch does not fire again).
    func resync() {
        _ = menuPresses()
        let h = hapticsEnabled
        hapticsEnabled = false
        lastInput = frameInput()
        hapticsEnabled = h
    }

    private func pulse(intensity: Float) {
        for c in GCController.controllers() {
            guard let h = c.haptics else { continue }
            let key = ObjectIdentifier(c)
            var engine = hapticEngines[key]
            if engine == nil {
                engine = h.createEngine(withLocality: .default)
                if let e = engine { try? e.start(); hapticEngines[key] = e }
            }
            guard let e = engine else { continue }
            let ev = CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8),
            ], relativeTime: 0)
            if let pattern = try? CHHapticPattern(events: [ev], parameters: []),
               let player = try? e.makePlayer(with: pattern) {
                try? player.start(atTime: CHHapticTimeImmediate)
            }
        }
    }
}
