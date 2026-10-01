import Foundation

/// The dot-matrix message effects of render_frame (EP1 cs:3E35..4373, EP10 cs:38E2..3ED7): flying
/// dots, waves, fades and per-dot colour cycling, run from the user's EXE by `MiniX86` on a private
/// copy of the data segment. Nothing here touches the rules' data segment, so classic rules and
/// physics are unchanged; the presentation feeds it the dot list and reads back what the original's
/// plot loop would draw.
///
/// What the original does [H, code read and checked frame by frame against the harness,
/// `tools/emu/dot_effects.py`]:
/// * dmd_message (EP1 cs:15DE) has the font routine write the dot list (one word per dot,
///   `y*320 + x` from the window or strip origin, terminated by three zero words) at ds:L
///   (EP1 ds:10C2), stores AL in the effect byte (ds:0B3A), zeroes the effect's step index
///   (ds:0B3B) and a delay buffer (EP1 ds:4586, 546h words), EP9-13 fill a per-dot colour array
///   (word i at L + 960h + 2i, low byte = the colour byte EP10 ds:00C5), sets the frame counter
///   (ds:0B3D) to 1 and DAC 255 to its start colour (EP1 white, EP9-13 red).
/// * render_frame once per frame: the block for the effect byte moves dots (`dot += table[k]`
///   through the delay buffer, so the wave runs along the list), kills them (a dead dot is the word
///   1), writes DAC 255 for fades (EP1 cs:3E70: grey level ds:0B3F, -1 per frame) or changes the
///   EP9-13 colour bytes (effect 7: `xor 0Fh` on every 4th dot; effect 12: a moving band of
///   subtractions), and ends the message by storing 0FFFFh in the counter. The blocks, their
///   counter thresholds and step tables differ per table; they are executed, not transcribed.
/// * Then the plot loop (EP1 cs:43E8, EP10 cs:3F30): every list word other than 1 up to the zero
///   terminator is a dot in DAC colour 255 (EP1-8) or in its colour byte (EP9-13, which also skip
///   words above the strip, `cmp ax,2580h; ja`). A counter of 0FFFFh instead clears it to 0 and
///   draws nothing: the message is gone.
/// * draw_text / draw_text_hi append further lines at the list's line pointer (EP1 2623:050C),
///   EP9-13 with their own colour byte per dot (EP10 cs:4CB2).
public final class DotEffects {
    /// Where the effect code and its state are, found by code signature (every table has the
    /// same shape; `find` documents the patterns).
    public struct Layout: Sendable, Equatable {
        /// dmd_message entry (`push es; pusha; cmp ah,2; jbe; sub ah,3`).
        public var dmdMessage: Int
        /// EP9-13: dmd_message first stores a word into a CS variable (EP10 cs:1563
        /// `mov word cs:[3E20h],0FFF8h`: effect 12's band position); nil in EP1-8.
        public var csReset: Int?
        public var csResetValue: Int = 0
        /// render_frame entry (`cmp word [counter],0; jne; jmp; cmp byte [effect],1`) and the end
        /// of its effect blocks (where every block jumps to before plotting: EP1 cs:4373).
        public var renderFrame: Int
        public var effectsEnd: Int
        /// DS words/bytes: frame counter, effect byte, step index.
        public var counter: Int, effect: Int, step: Int
        /// The dot list (words) and the delay buffer that dmd_message clears.
        public var list: Int
        public var delay: Int, delayWords: Int
        /// EP9-13: the DS colour byte dmd_message copies into the per-dot colour array at
        /// `list + colourOffset` (`colourWords` words); nil in EP1-8 (dots are DAC 255).
        public var colourVar: Int?
        public var colourOffset: Int, colourWords: Int
        /// DAC 255 as dmd_message sets it (6-bit RGB).
        public var startDAC: [UInt8]
        /// EP9-13: list words above this are not plotted (EP10 cs:3F45); nil = no limit.
        public var plotLimit: Int?
    }

    public let layout: Layout
    private let machine: RulesMachine
    private let x86: MiniX86
    private var csWrites: [Int: UInt8] = [:]
    private var dacIndex = 0, dacPart = 0
    private var dacLatch: [UInt8] = [0, 0, 0]
    /// Number of list words written (the line pointer, in words from `list`).
    private var lineWords = 0

    /// True between a message start and the frame render_frame ends it (counter 0FFFFh).
    public private(set) var active = false
    /// render_frame calls since the last `start`.
    public private(set) var steps = 0
    /// DAC entries the effect code wrote since the last `start` (6-bit RGB), including the start
    /// colour of entry 255.
    public private(set) var dac: [Int: [UInt8]] = [:]
    /// sfx_play calls (AX) the last `step` made (the rules runtime reports EP1's itself).
    public private(set) var sounds: [Int] = []
    /// The counter word right after the last step's effect blocks (0FFFFh = the effect ended it), before
    /// the plot loop's conversion to 0.
    public private(set) var rawCounter = 0
    /// Why the last step stopped early (nil = it reached the end of the effect blocks).
    public private(set) var lastProblem: String?

    /// Builds the runner for a table EXE; nil if the code does not have the expected shape.
    public convenience init?(exe: [UInt8], table: Int) {
        guard let image = try? ExeImage(exe: exe), let layout = Self.find(code: image.code) else { return nil }
        let p = RulesProgram(
            table: table, exe: "EP\(table).EXE", annotated: false, codeSegment: image.entryCS, dataSegment: image.dataSegment,
            dispatcherIP: nil, sensorTable: nil, dsFileOffset: image.dsFileOffset, dsSize: image.dsSize, playerBlock: nil,
            lampFirst: 0, lampCount: 0, lampPhase: nil, lampSlotCount: 0, vars: [:], engineVars: [:], blocks: [], labels: [:],
            hooks: [:], handlers: [:], colourHandler: [:], level1Colours: [], tiltColours: [], lockoutFreeColours: [], gates: [],
            sweeps: [], messages: [:], messageTables: [:], stubs: [:], registerNames: [], maskedRegisters: [])
        guard let m = try? RulesMachine(program: p, exe: exe) else { return nil }
        self.init(machine: m, layout: layout)
        guard Self.decodes(x86, from: layout.renderFrame, to: layout.effectsEnd) else { return nil }
    }

    /// Every instruction reachable from `start` before `end` is in MiniX86's subset (recursive descent:
    /// the blocks keep CS variables between them, EP10 cs:3C14/3C16/3E20, so a linear sweep misreads them).
    static func decodes(_ x: MiniX86, from start: Int, to end: Int) -> Bool {
        var todo = [start], seen = Set<Int>()
        while let ip = todo.popLast() {
            guard ip >= start, ip < end, seen.insert(ip).inserted else { continue }
            guard x.length(at: ip) != nil, let i = X86Decoder.decode(x.machine.code, ip) else { return false }
            if let t = i.target, i.mn != "call" { todo.append(t) }
            if i.mn == "jmp" || i.mn == "ret" || i.mn == "retf" { continue }
            todo.append(i.next)
        }
        return true
    }

    /// `machine` must be a private memory (no engine host): the effect code writes its display
    /// buffers into it.
    init(machine: RulesMachine, layout: Layout) {
        self.machine = machine
        self.layout = layout
        x86 = MiniX86(machine: machine)
        x86.csRead = { [unowned self] a in csWrites[a] ?? machine.code[a & 0xFFFF] }
        x86.csWrite = { [unowned self] a, v in csWrites[a & 0xFFFF] = v }
        x86.callout = { [unowned self] x, _, _, far in
            // The only calls in the effect blocks are `call far sfx_play` (EP1 cs:3E6B, 41EF, ...).
            if far != nil { sounds.append(Int(x.ax)); return .handled }
            return .unknown
        }
        x86.portWrite = { [unowned self] port, v in dacWrite(port, UInt8(v & 0xFF)) }
    }

    private func dacWrite(_ port: Int, _ v: UInt8) {
        switch port {
        case 0x3C8: dacIndex = Int(v); dacPart = 0
        case 0x3C9:
            dacLatch[dacPart] = v & 0x3F
            dacPart += 1
            if dacPart == 3 { dac[dacIndex] = dacLatch; dacPart = 0; dacIndex = (dacIndex + 1) & 0xFF }
        default: break
        }
    }

    private func w16(_ a: Int, _ v: Int) { machine.write(a & 0xFFFF, 2, Int64(v & 0xFFFF)) }
    private func r16(_ a: Int) -> Int { Int(machine.read(a & 0xFFFF, 2)) }

    /// dmd_message after its font routine: `dots` = the list it wrote (nil = the font routine wrote
    /// nothing, EP1-8 AH=2 is a bare `retf`, so the old list stays), AL = the effect byte,
    /// `colour` = the EP9-13 colour byte at the call.
    public func start(dots: [Int]?, effect: Int, colour: UInt8 = 0xFF) {
        let l = layout
        if let a = l.csReset {
            csWrites[a & 0xFFFF] = UInt8(l.csResetValue & 0xFF)
            csWrites[(a + 1) & 0xFFFF] = UInt8(l.csResetValue >> 8)
        }
        w16(l.step, 0)
        machine.write8(l.effect, UInt8(effect & 0xFF))
        if let dots {
            for (i, d) in dots.enumerated() { w16(l.list + 2 * i, d) }
            for k in 0..<3 { w16(l.list + 2 * (dots.count + k), 0) }
            lineWords = dots.count
        }
        for i in 0..<l.delayWords { w16(l.delay + 2 * i, 0) }
        if l.colourVar != nil {
            for i in 0..<l.colourWords { w16(l.list + l.colourOffset + 2 * i, Int(colour)) }
        }
        w16(l.counter, 1)
        dac = [255: l.startDAC]
        active = true
        steps = 0
    }

    /// draw_text / draw_text_hi: a line appended at the line pointer (EP9-13 with its colour byte).
    public func append(dots: [Int], colour: UInt8 = 0xFF) {
        let l = layout
        guard lineWords > 0 || active else { return }   // [50Ch] = 0 before the first message: no-op
        for (i, d) in dots.enumerated() {
            w16(l.list + 2 * (lineWords + i), d)
            if l.colourVar != nil { machine.write8(l.list + 2 * (lineWords + i) + l.colourOffset, colour) }
        }
        lineWords += dots.count
        for k in 0..<3 { w16(l.list + 2 * (lineWords + k), 0) }
    }

    /// One render_frame call. Returns false once the message has ended (nothing is drawn).
    @discardableResult
    public func step() -> Bool {
        guard active else { return false }
        sounds = []
        x86.resetRegisters()
        let r = x86.run(from: layout.renderFrame, to: layout.effectsEnd)
        steps += 1
        switch r {
        case .completed: lastProblem = nil
        default: lastProblem = "\(r)"   // counter 0 (`jmp` past the plotter) or an unexpected stop
        }
        let c = r16(layout.counter)
        rawCounter = c
        if c == 0xFFFF || c == 0 || r != .completed {
            if c == 0xFFFF { w16(layout.counter, 0) }   // cs:43C5: the message is gone, nothing plotted
            active = false
        }
        return active
    }

    /// Back to the EXE's data segment and no message (a new game).
    public func reset() {
        machine.reset()
        csWrites = [:]
        dacIndex = 0; dacPart = 0; dacLatch = [0, 0, 0]
        lineWords = 0; active = false; steps = 0; dac = [:]; sounds = []; lastProblem = nil
    }

    /// The message was cleared by other code (rule code storing 0FFFFh in the counter, EP1 cs:0DAC,
    /// pause_menu cs:1477): nothing is drawn until the next `start`.
    public func stop() {
        w16(layout.counter, 0)
        active = false
    }

    /// Takes the counter from the rules when other code stored into it (EP1 boot cs:04C1 sets 32h,
    /// cs:3ADA 1F4h): render_frame then goes on from that value. 0 ends the message.
    public func setCounter(_ v: Int) {
        w16(layout.counter, v)
        active = v & 0xFFFF != 0
    }

    /// The counter word (diagnostics, tests).
    public var counter: Int { r16(layout.counter) }
    /// The effect's step index word (`Layout.step`).
    public var stepWord: Int { r16(layout.step) }

    /// Everything `step` depends on (the private data segment, the CS variables, the DAC writes), for
    /// save states of the rules runtime.
    public struct State {
        var machine: RulesMachine.State
        var csWrites: [Int: UInt8]
        var dacIndex: Int, dacPart: Int, dacLatch: [UInt8]
        var lineWords: Int, active: Bool, steps: Int
        var dac: [Int: [UInt8]], sounds: [Int], lastProblem: String?
    }

    public func saveState() -> State {
        State(machine: machine.saveState(), csWrites: csWrites, dacIndex: dacIndex, dacPart: dacPart, dacLatch: dacLatch,
              lineWords: lineWords, active: active, steps: steps, dac: dac, sounds: sounds, lastProblem: lastProblem)
    }

    public func restoreState(_ s: State) {
        machine.restoreState(s.machine)
        csWrites = s.csWrites; dacIndex = s.dacIndex; dacPart = s.dacPart; dacLatch = s.dacLatch
        lineWords = s.lineWords; active = s.active; steps = s.steps; dac = s.dac; sounds = s.sounds; lastProblem = s.lastProblem
    }

    /// What the plot loop draws now: list offsets in order, with the EP9-13 colour byte of each
    /// (EP1-8: nil, every dot is DAC 255). Empty while no message is active.
    public func plotted() -> (dots: [Int], colours: [UInt8]?) {
        guard active else { return ([], nil) }
        let l = layout
        var dots: [Int] = []
        var colours: [UInt8]? = l.colourVar == nil ? nil : []
        let limit = l.plotLimit ?? 0xFFFF
        var i = 0
        // The first word is plotted unless it is 1 (or above the limit); after it, a 0 ends the list.
        while i < 0x8000 {
            let a = l.list + 2 * i
            let v = r16(a)
            if i > 0 && v == 0 { break }
            if v <= limit && v != 1 {
                dots.append(v)
                colours?.append(machine.read8(a + l.colourOffset))
            }
            i += 1
        }
        return (dots, colours)
    }

    /// Current DAC 255 (6-bit RGB).
    public var dac255: [UInt8] { dac[255] ?? layout.startDAC }

    // MARK: - discovery

    /// Finds the layout in a 64 KB code segment:
    /// * dmd_message: `push es; pusha; cmp ah,2; jbe +6; sub ah,3` (EP1 cs:15DE; EP9-13 behind
    ///   `mov word cs:[x],imm`, EP10 cs:1563), then within it
    ///   `mov word [step],0; mov [effect],al; lea si,[list]` (cs:1625), `mov cx,n; mov ax,ds; mov es,ax;
    ///   mov ax,0; lea di,[delay]; rep stosw` (cs:1654), EP9-13 `mov al,[colour]; lea di,[list];
    ///   add di,off; mov cx,n; rep stosw` (EP10 cs:15F0), and `mov word [counter],1; mov al,0FFh;
    ///   mov dx,3C8h; out dx,al; inc dx` followed by the three colour writes (cs:1664).
    /// * render_frame: `cmp word [counter],0; jne +3; jmp; cmp byte [effect],1; je +3; jmp` (cs:3E35),
    ///   effect 1's `inc word [counter]; cmp word [counter],n; jae +3; jmp END` gives the end of the
    ///   effect blocks (cs:4373). EP9-13's plotter `lodsw; cmp ax,limit; ja` after END gives the limit.
    public static func find(code c: [UInt8]) -> Layout? {
        func b(_ i: Int) -> Int { Int(c[i & 0xFFFF]) }
        func w(_ i: Int) -> Int { b(i) | b(i + 1) << 8 }
        func match(_ p: Int, _ pat: [Int?]) -> Bool {
            for (k, v) in pat.enumerated() where v != nil && b(p + k) != v! { return false }
            return true
        }
        func search(_ pat: [Int?], in r: Range<Int>) -> Int? {
            for p in r where match(p, pat) { return p }
            return nil
        }
        guard let dm = search([0x06, 0x60, 0x80, 0xFC, 0x02, 0x76, 0x06, 0x80, 0xEC, 0x03], in: 0..<0xFF00) else { return nil }
        let body = dm..<(dm + 0x120)
        guard let s = search([0xC7, 0x06, nil, nil, 0x00, 0x00, 0xA2, nil, nil, 0x8D, 0x36], in: body),
              let d = search([0xB9, nil, nil, 0x8C, 0xD8, 0x8E, 0xC0, 0xB8, 0x00, 0x00, 0x8D, 0x3E, nil, nil, 0xF3, 0xAB], in: body),
              let k = search([0xC7, 0x06, nil, nil, 0x01, 0x00, 0xB0, 0xFF, 0xBA, 0xC8, 0x03, 0xEE, 0x42], in: body) else { return nil }
        let step = w(s + 2), effect = w(s + 7), list = w(s + 11), counter = w(k + 2)
        var rgb: [UInt8] = []
        var i = k + 13, al = 0
        while rgb.count < 3, i < k + 30 {
            if b(i) == 0xB0 { al = b(i + 1); i += 2 } else if b(i) == 0xEE { rgb.append(UInt8(al & 0x3F)); i += 1 } else { break }
        }
        guard rgb.count == 3 else { return nil }
        var colourVar: Int?, colourOffset = 0, colourWords = 0
        if let q = search([0xA0, nil, nil, 0x8D, 0x3E, nil, nil, 0x81, 0xC7, nil, nil, 0xB9, nil, nil, 0xF3, 0xAB], in: body),
           w(q + 5) == list {
            colourVar = w(q + 1); colourOffset = w(q + 9); colourWords = w(q + 12)
        }
        let rfPat: [Int?] = [0x83, 0x3E, counter & 0xFF, counter >> 8, 0x00, 0x75, 0x03, 0xE9, nil, nil,
                             0x80, 0x3E, effect & 0xFF, effect >> 8, 0x01, 0x74, 0x03, 0xE9, nil, nil,
                             0xFF, 0x06, counter & 0xFF, counter >> 8]
        guard let rf = search(rfPat, in: 0..<0xFF00) else { return nil }
        // cmp word [counter], imm16 (81) or imm8 (83); jae +3; jmp END
        var j = rf + 24
        if match(j, [0x81, 0x3E, counter & 0xFF, counter >> 8]) { j += 6 } else if match(j, [0x83, 0x3E, counter & 0xFF, counter >> 8]) { j += 5 } else { return nil }
        guard match(j, [0x73, 0x03, 0xE9]) else { return nil }
        let end = (j + 5 + w(j + 3)) & 0xFFFF
        guard end > rf else { return nil }
        var limit: Int?
        if colourVar != nil, let p = search([0xAD, 0x3D, nil, nil, 0x77], in: end..<(end + 0x100)) { limit = w(p + 2) }
        var csReset: Int?, csResetValue = 0
        if dm >= 7, match(dm - 7, [0x2E, 0xC7, 0x06]) { csReset = w(dm - 4); csResetValue = w(dm - 2) }
        return Layout(dmdMessage: csReset == nil ? dm : dm - 7, csReset: csReset, csResetValue: csResetValue, renderFrame: rf, effectsEnd: end, counter: counter, effect: effect, step: step,
                      list: list, delay: w(d + 12), delayWords: w(d + 1), colourVar: colourVar, colourOffset: colourOffset,
                      colourWords: colourWords, startDAC: rgb, plotLimit: limit)
    }

    /// EP9-13 text routines that store a colour byte per dot (`mov al,[c]; mov cs:[x],al; mov ax,ds;
    /// mov es,ax`, EP10 cs:4C65): routine entry -> DS colour byte.
    public static func textColourVars(code c: [UInt8]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for i in 0..<(0x10000 - 12) where c[i] == 0xA0 && c[i + 3] == 0x2E && c[i + 4] == 0xA2
            && c[i + 7] == 0x8C && c[i + 8] == 0xD8 && c[i + 9] == 0x8E && c[i + 10] == 0xC0 {
            out[i] = Int(c[i + 1]) | Int(c[i + 2]) << 8
        }
        return out
    }
}
