import Foundation
import PinballCore

/// Animates dot messages the way render_frame does (`DotEffects`: the original's effect code run
/// from the user's EXE): builds the dot list dmd_message would write (`DotText`), appends
/// draw_text lines, steps one render_frame per original frame and gives back the dots the plot
/// loop draws, their colours and DAC 255 (fades).
public final class MessageAnimator {
    public let effects: DotEffects
    let graphics: GameGraphics
    let spec: StripSpec

    public init?(exe: TableExe, graphics: GameGraphics, spec: StripSpec) {
        guard let fx = DotEffects(exe: exe.bytes, table: graphics.table) else { return nil }
        effects = fx
        self.graphics = graphics
        self.spec = spec
    }

    public var active: Bool { effects.active }
    /// render_frame calls since the message started.
    public var steps: Int { effects.steps }

    /// dmd_message with this text, AX and DI. Returns false where the original returns at once
    /// (string longer than 30 characters or too wide to centre: nothing changes, cs:15FC).
    @discardableResult
    public func start(_ m: DotMessage) -> Bool {
        var ah = m.font
        if ah <= 2 {
            var len = 0
            while len < m.text.count, m.text[len] != 0 {
                len += 1
                if len > 0x1E { return false }
            }
            if 0x140 - (ah == 2 ? 8 : (ah == 0 ? 11 : 16)) * len < 0 { return false }
        } else {
            ah -= 3
        }
        let dots = DotText.dots(m, font8: graphics.font8, font5: graphics.font5, font5b: graphics.font5b)
        // EP1-8 AH=2: the font routine is a bare `retf` (cs:5925), the old list stays.
        let keep = ah == 2 && graphics.font5b.isEmpty
        effects.start(dots: keep ? nil : dots, effect: m.effect, colour: m.colour ?? spec.messageDotColour)
        return true
    }

    /// A draw_text / draw_text_hi line appended to the list.
    public func append(_ line: DotLine) {
        effects.append(dots: DotText.lineDots(line, font8: graphics.font8, font5: graphics.font5), colour: line.colour)
    }

    /// One render_frame. Returns false once the message has ended.
    @discardableResult
    public func step() -> Bool {
        let alive = effects.step()
        shown = alive ? frame() : nil
        return alive
    }

    /// What the plot loop would draw from the list now (offsets from the window / strip origin)
    /// and the palette indices: DAC 255 in EP1-8, the per-dot colour byte in EP9-13.
    public func frame() -> (dots: [Int], colours: [UInt8]) {
        let p = effects.plotted()
        return (p.dots, p.colours ?? [UInt8](repeating: 255, count: p.dots.count))
    }

    /// What is on screen: the dots the last render_frame call plotted. nil = none (no message, it
    /// ended, or nothing plotted yet). A message started after that frame's render_frame (from a
    /// physics step) is first plotted by the next frame's call, so the old dots stay until then.
    public private(set) var shown: (dots: [Int], colours: [UInt8])?

    /// The rules' message being followed (`MessageRef.serial`).
    public private(set) var serial: Int?

    /// Follows the rules' message for one original frame: a new `serial` restarts the list
    /// (dmd_message), then one render_frame per `renderFrames` tick, with the frame's draw_text
    /// lines appended between the calls they were drawn between (`TextRef.afterRenders`).
    /// `message` is the resolved DotMessage of `ref` (text, AX, DI, colour; its `appended` is
    /// ignored), `line` turns a TextRef into its DotLine.
    public func follow(_ ref: MessageRef?, message: DotMessage?, texts: [TextRef], line: (TextRef) -> DotLine?) {
        guard let ref, ref.serial >= 0, ref.renderFrames >= 0, let m = message else {
            if serial != nil { effects.stop(); serial = nil }
            shown = nil
            return
        }
        if ref.serial != serial {
            serial = ref.serial
            var first = m
            first.appended = []
            start(first)
        }
        let mine = texts.filter { $0.messageSerial == ref.serial }
        func lines(after k: Int) {
            for t in mine where t.afterRenders == k { if let l = line(t) { append(l) } }
        }
        // render_frame stops counting once the message has ended (`steps` stays put). EP2-13's rules
        // do not run the counter, so they keep reporting the message with a growing `renderFrames`:
        // stop at the end, and append the rest of the frame's lines to the (unplotted) list in order.
        while steps < ref.renderFrames, effects.active {
            lines(after: steps)
            step()
        }
        if effects.active {
            lines(after: steps)
        } else {
            for t in mine where t.afterRenders >= steps { if let l = line(t) { append(l) } }
        }
        // Counter values other code stored (EP1's boot sets 32h): the rules keep EP1's exactly.
        if ref.counter >= 0, effects.counter != ref.counter {
            effects.setCounter(ref.counter)
            if !effects.active { shown = nil }
        }
    }

    /// DAC 255 now, 8-bit (6-bit value << 2 | >> 4, as the VGA read-back).
    public var dac255: Palette.RGB {
        let v = effects.dac255
        func c(_ x: UInt8) -> UInt8 { let y = min(x, 63); return y << 2 | y >> 4 }
        return Palette.RGB(r: c(v[0]), g: c(v[1]), b: c(v[2]))
    }

    public func stop() {
        effects.stop()
        shown = nil
        serial = nil
    }
}
