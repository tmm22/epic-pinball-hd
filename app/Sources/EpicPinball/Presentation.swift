import Foundation
import PinballCore
import PinballRender

/// Front-end side of the classic presentation: loads the table's graphics and strip layout
/// from the user's EXE, runs the original camera and the Enter strip slide, and turns
/// `PresentationState` (filled by the rules interpreter, or the demo driver below) into
/// renderer input. Owns no game data; everything is read at runtime.
@MainActor
final class ClassicPresentation {
    let composer: ClassicComposer
    let exe: TableExe?
    var spec: StripSpec { composer.spec }
    /// Strip rows visible when fully shown (19 in EP1-8, 29 in EP9-13: 240 - window rows).
    let maxStripRows: Int
    /// Strip rows currently on screen (slides 1 row per frame, like the split line moving
    /// 2 scanlines per frame in nudge_tilt cs:0EE0-0F5F).
    private(set) var stripRows: Int
    private(set) var stripShown: Bool
    var camera: ClassicCamera
    /// Current state (from the rules or the demo driver).
    var state = PresentationState()
    /// A message given directly (CLI / demo), overriding `state.message`.
    var directMessage: DotMessage?
    var paused = false
    /// Tri-state lamp sprites from the rules runtime (0 not drawn, 1 a, 2 b), if known.
    var lampSprites: [UInt8]?
    private var plungerSeen = false

    init(composer: ClassicComposer, exe: TableExe?, stripShown: Bool = true) {
        self.composer = composer
        self.exe = exe
        maxStripRows = max(0, ScreenLayout.screenRows - composer.spec.windowRows)
        self.stripShown = stripShown
        stripRows = stripShown ? maxStripRows : 0
        camera = ClassicCamera(anchor: composer.spec.cameraAnchor, easeShift: composer.spec.cameraEaseShift)
    }

    /// Playfield rows on screen right now.
    var windowRows: Int { ScreenLayout.screenRows - stripRows }

    /// camera_max for the current slide position: the slide code moves it 1 per frame
    /// between the two constants (cs:0EEC / 0F33) and stores the exact value at the end.
    var cameraMax: Int {
        if stripRows >= maxStripRows { return spec.cameraMaxShown }
        if stripRows <= 0 { return spec.cameraMaxHidden }
        return max(spec.cameraMaxHidden, spec.cameraMaxShown - (maxStripRows - stripRows))
    }

    static func load(assets: TableAssets, engine: EngineData, dataRoot: URL, originalDir: String?) -> ClassicPresentation? {
        var exe: TableExe?
        if let url = TableExe.locate(table: assets.table, dataRoot: dataRoot, explicitDirectory: originalDir) {
            do { exe = try TableExe(contentsOf: url) } catch { warn("\(error)") }
        } else {
            warn("original/EP\(assets.table).EXE not found (pass --original DIR): no fonts, strip text or messages")
        }
        let gfx: GameGraphics
        do { gfx = try GameGraphics.load(tableDirectory: assets.directory, palette: assets.palette, exe: exe) } catch {
            warn("classic presentation disabled: \(error)")
            return nil
        }
        for w in gfx.warnings { warn(w) }
        var spec = StripSpec()
        if let exe {
            spec = StripSpec.scan(exe: exe, codeSegment: gfx.codeSegment, dataSegment: gfx.dataSegment,
                                  table: assets.table, displayRows: gfx.displayRows)
            if gfx.plunger == nil { spec.fallbacks.removeAll { $0 == "plunger base" } }  // EP8 has no plunger
            if !spec.fallbacks.isEmpty { warn("EP\(assets.table): display fields not found in the EXE, EP1 values used: \(spec.fallbacks.joined(separator: ", "))") }
        } else if assets.table >= 9 {
            spec.windowRows = 211; spec.stripRows = 30; spec.messagesInStrip = true
        }
        let c = ClassicComposer(graphics: gfx, spec: spec, exe: exe, playfield: assets.indices, engine: engine)
        return ClassicPresentation(composer: c, exe: exe)
    }

    // MARK: strip

    func toggleStrip() { stripShown.toggle() }

    func setStrip(shown: Bool, immediately: Bool) {
        stripShown = shown
        if immediately { stripRows = shown ? maxStripRows : 0 }
    }

    // MARK: per frame

    /// One original frame: strip slide (the camera moves with it so the bottom of the view
    /// stays put), then camera_update with the highest active ball.
    func stepFrame(engine: ClassicEngine, manualY: Int?) {
        if stripShown && stripRows < maxStripRows {
            stripRows += 1; camera.y += 1
        } else if !stripShown && stripRows > 0 {
            stripRows -= 1; if camera.y > 0 { camera.y -= 1 }
        }
        camera.update(maxBallY: Self.maxActiveBallY(engine), cameraMax: cameraMax, manualY: manualY)
    }

    static func maxActiveBallY(_ e: ClassicEngine) -> Int {
        var y = 0
        for b in e.balls where b.active != 0 { y = max(y, Int(UInt16(bitPattern: b.y))) }
        return y
    }

    /// Lines appended to the active message by `PresentationState.texts` (draw_text calls
    /// arrive once, the dot list keeps them until the next dmd_message).
    private var appendedLines: [DotLine] = []
    private var lastMessageKey: (Int, Int, Int, Int)?

    /// Takes one frame's state from the producer (rules or demo). Call once per original
    /// frame: `texts` are per-frame events that extend the active message.
    func ingest(_ s: PresentationState) {
        state = s
        if !s.lampSprites.isEmpty { lampSprites = s.lampSprites }
        frameMessage = resolveMessage()
    }

    private var frameMessage: DotMessage?

    /// The message to draw this frame (direct message, else the last ingested one).
    func currentMessage() -> DotMessage? { directMessage ?? frameMessage ?? (state.message == nil ? nil : resolveMessage()) }

    /// The message of `state`. Text: the live bytes the rules pass
    /// (`MessageRef.bytes`, digits patched in), else the string at `MessageRef.exeOffset` in the
    /// user's EXE. Placement: `modeWord`/`position` when the producer set them
    /// (`dsOffset >= 0`), else AH=1 (font8, centred) at a default row.
    private func resolveMessage() -> DotMessage? {
        guard let ref = state.message else { lastMessageKey = nil; appendedLines = []; return nil }
        var text = ref.bytes
        if text.isEmpty, let exe { text = exe.cString(at: ref.exeOffset, max: 64) }
        guard !text.isEmpty else { return nil }
        let known = ref.dsOffset >= 0
        let ax = known ? Int(ref.modeWord) : 0x100 | Int(ref.mode)
        let di = known ? ref.position : (spec.messagesInStrip ? 3 : 10) * 320
        // A new dmd_message call restarts the dot list: drop appended lines.
        let key = (ref.exeOffset, ax, di, ref.framesRemaining)
        if let k = lastMessageKey, k.0 == key.0, k.1 == key.1, k.2 == key.2, key.3 <= k.3 || key.3 < 0 {} else { appendedLines = [] }
        lastMessageKey = key
        for t in state.texts {
            guard let f8 = spec.textRoutines[t.routine] else { continue }
            var bytes = t.bytes
            if bytes.isEmpty, let exe { bytes = exe.cString(at: t.exeOffset, max: 64) }
            appendedLines.append(DotLine(text: bytes, font8: f8, di: t.position))
        }
        return DotMessage(text: text, ax: ax, di: di, appended: appendedLines)
    }

    /// Pushes the frame's presentation into the renderer.
    func apply(to renderer: PinballRenderer, scene: SceneState, engine: ClassicEngine) {
        if engine.plungerCharge > 0 { plungerSeen = true }
        let plungerY = plungerSeen ? spec.plungerBaseY + (Int(engine.plungerCharge) >> spec.plungerShift) : nil
        renderer.stripRows = stripRows
        renderer.present(state, message: currentMessage(), flippers: scene.flippers, plungerY: plungerY, paused: paused,
                         lampSprites: lampSprites)
    }
}

/// The original camera (camera_update cs:308D), integer rows.
struct ClassicCamera {
    var anchor: Int
    var easeShift: Int
    var y = 0

    /// - Parameters: maxBallY = highest active ball's top-left y; cameraMax = ds:0B32;
    ///   manualY = arrow-key scroll.
    mutating func update(maxBallY: Int, cameraMax camMax: Int, manualY: Int?) {
        let target = min(max(maxBallY, anchor), camMax) - anchor
        if let m = manualY { y = min(max(m, 0), camMax - anchor); return }
        if easeShift <= 0 { y = target; return }
        let delta = target - y
        guard delta != 0 else { return }
        var step = abs(delta) >> easeShift
        if step == 0 { step = 1 }
        y += delta > 0 ? step : -step
    }

    mutating func snap(maxBallY: Int, cameraMax camMax: Int) {
        y = min(max(maxBallY, anchor), camMax) - anchor
    }
}

// MARK: - Demo / test driver (no rules needed)

/// Lamp selection for the demo and for snapshots.
enum LampSpec: Equatable {
    case none            // no overlays drawn (bare extracted playfield)
    case allA, allB      // every slot "a" / "b"
    case rest            // per slot the record matching the playfield (visually unchanged)
    case alternate       // even slots "a", odd "b"
    case lit([Int])      // listed slots drawn with the record that differs from the playfield, others at rest
    case explicit([Int: Bool])  // "12a,13b": slot -> record a (true) / b (false), others at rest

    static func parse(_ s: String) throws -> LampSpec {
        switch s.lowercased() {
        case "none", "off": return .none
        case "a", "all": return .allA
        case "b": return .allB
        case "rest": return .rest
        case "alt", "alternate": return .alternate
        default:
            if s.contains(where: { $0 == "a" || $0 == "b" }) {
                var m: [Int: Bool] = [:]
                for part in s.lowercased().split(separator: ",") {
                    guard let last = part.last, last == "a" || last == "b", let r0 = part.dropLast().split(separator: "-").first else {
                        throw Options.ParseError.message("--lamps: bad slot list '\(s)' (use 12a,13-15b or 3,5,7)")
                    }
                    let r = part.dropLast().split(separator: "-").compactMap { Int($0) }
                    guard !r.isEmpty, Int(r0) != nil else { throw Options.ParseError.message("--lamps: bad slot list '\(s)'") }
                    for k in r[0]...(r.count > 1 ? max(r[0], r[1]) : r[0]) { m[k] = last == "a" }
                }
                return .explicit(m)
            }
            var out: [Int] = []
            for part in s.split(separator: ",") {
                let r = part.split(separator: "-").compactMap { Int($0) }
                if r.count == 1 { out.append(r[0]) } else if r.count == 2, r[0] <= r[1] { out += Array(r[0]...r[1]) } else {
                    throw Options.ParseError.message("--lamps: bad slot list '\(s)'")
                }
            }
            return .lit(out)
        }
    }

    func states(count: Int, restIsA: [Bool]) -> [Bool] {
        let rest = (0..<count).map { $0 < restIsA.count ? restIsA[$0] : true }
        switch self {
        case .none: return []
        case .allA: return Array(repeating: true, count: count)
        case .allB: return Array(repeating: false, count: count)
        case .rest: return rest
        case .alternate: return (0..<count).map { $0 % 2 == 0 }
        case let .lit(list):
            var s = rest
            for k in list where k >= 0 && k < count { s[k] = !rest[k] }
            return s
        case let .explicit(m):
            var s = rest
            for (k, a) in m where k >= 0 && k < count { s[k] = a }
            return s
        }
    }
}

/// `--message OFFSET[:AX[:DI[:COLOUR]]]` (hex with 0x or decimal). OFFSET is a file offset in
/// the user's EPn.EXE; AX/DI as the original's dmd_message takes them; COLOUR = EP9-13 dot colour.
struct MessageSpec: Equatable {
    var exeOffset: Int
    var ax: Int?
    var di: Int?
    var colour: UInt8? = nil

    static func parse(_ s: String) throws -> MessageSpec {
        func num(_ t: Substring) -> Int? { t.hasPrefix("0x") ? Int(t.dropFirst(2), radix: 16) : Int(t) }
        let parts = s.split(separator: ":")
        guard let first = parts.first, let off = num(first) else { throw Options.ParseError.message("--message needs OFFSET[:AX[:DI]]") }
        return MessageSpec(exeOffset: off, ax: parts.count > 1 ? num(parts[1]) : nil, di: parts.count > 2 ? num(parts[2]) : nil,
                           colour: parts.count > 3 ? num(parts[3]).map { UInt8(truncatingIfNeeded: $0) } : nil)
    }
}

/// `--message-line OFFSET:font5|font8:DI`: a line appended to the message's dot list.
struct MessageLineSpec: Equatable {
    var exeOffset: Int
    var font8: Bool
    var di: Int

    static func parse(_ s: String) throws -> MessageLineSpec {
        func num(_ t: Substring) -> Int? { t.hasPrefix("0x") ? Int(t.dropFirst(2), radix: 16) : Int(t) }
        let p = s.split(separator: ":")
        guard p.count == 3, let off = num(p[0]), p[1] == "font5" || p[1] == "font8", let di = num(p[2]) else {
            throw Options.ParseError.message("--message-line needs OFFSET:font5|font8:DI")
        }
        return MessageLineSpec(exeOffset: off, font8: p[1] == "font8", di: di)
    }
}

/// Cycles lamps, scores and messages so the presentation can be checked without rules.
struct DemoDriver {
    let lampCount: Int
    let restIsA: [Bool]
    /// Message file offsets to cycle (from rules.json, else found in the EXE's data segment).
    let messages: [Int]
    private(set) var frame = 0
    private(set) var score: UInt32 = 0

    init(lampCount: Int, restIsA: [Bool], messages: [Int]) {
        self.lampCount = lampCount; self.restIsA = restIsA; self.messages = messages
    }

    /// Advances one original frame and returns the state plus a direct message.
    mutating func step(into s: inout PresentationState, messagesInStrip: Bool) -> DotMessage? {
        frame += 1
        // Lamps: a wave of lit slots (every 8th slot, moving each 10 frames), others at rest.
        let phase = (frame / 10) % 8
        s.lamps = LampSpec.lit(Array(stride(from: phase, to: lampCount, by: 8))).states(count: lampCount, restIsA: restIsA)
        if frame % 3 == 0 { score &+= UInt32(1_000 + (frame % 7) * 250) }
        s.scores = [score]
        s.ballNumber = 1 + (frame / 600) % 3
        s.currentPlayer = (frame / 1800) % 2
        // Palette: cycle the lamp colour range slightly (shows overrides reach the GPU).
        s.paletteOverrides = []
        return nil
    }

    func messageSpec(at frame: Int, inStrip: Bool) -> MessageSpec? {
        guard !messages.isEmpty else { return nil }
        let slot = (frame / 180) % (messages.count * 2)
        guard slot % 2 == 0 else { return nil }   // message 3 s, gap 3 s
        return MessageSpec(exeOffset: messages[slot / 2], ax: inStrip ? 0x001 : 0x101, di: (inStrip ? 8 : 12) * 320)
    }

    /// Message offsets: rules.json `messages[].file_offset`, else printable zero-terminated
    /// runs (8-30 upper-case characters) in the first 8 KB of the EXE's data segment.
    static func findMessages(tableDirectory dir: URL, exe: TableExe?, dataSegment: Int) -> [Int] {
        if let d = try? Data(contentsOf: dir.appendingPathComponent("rules.json")),
           let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let list = root["messages"] as? [[String: Any]] {
            let offs = list.compactMap { m -> Int? in
                guard (m["printable"] as? Bool) != false, let s = m["file_offset"] as? String,
                      let len = m["length"] as? Int, len >= 6 else { return nil }
                return Int(s.dropFirst(2), radix: 16)
            }
            if !offs.isEmpty { return offs }
        }
        guard let exe else { return [] }
        let base = exe.fileOffset(segment: dataSegment)
        var out: [Int] = []
        var i = base
        while i < min(exe.bytes.count, base + 0x2000) {
            let s = exe.cString(at: i, max: 40)
            let ok = s.count >= 8 && s.count <= 30 && s.allSatisfy { ($0 >= 0x41 && $0 <= 0x5A) || $0 == 0x20 || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x21 }
                && s.filter({ $0 >= 0x41 && $0 <= 0x5A }).count >= 5 && (i == base || exe.bytes[i - 1] == 0)
            if ok { out.append(i) }
            i += max(1, s.count + 1)
        }
        return out
    }
}
