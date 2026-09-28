import Foundation
import PinballCore

/// Emissive mask for the lamp glow, from the lamp overlay records themselves.
///
/// Each lamp slot has two opaque records ("a", "b"). Which one is the lit look differs by
/// table (EP1 mostly "b", EP8/EP10 mostly "a"), so the renderer does not trust the letter:
/// a pixel of the record currently shown emits in proportion to how much brighter it is than
/// the same table pixel in the slot's other record (or the bare playfield where the other
/// record does not cover it). The mask is 0...255 per table pixel (R8Unorm, scaled by
/// `maskScale` in the shader). Lamps that switch to their brighter record outside the
/// blinking states (3/4) get a short flasher pulse.
final class LampLighting {
    struct Emission { var offsets: [Int32]; var weights: [Float] }

    /// emission[k][0] when record "a" is shown, [1] for "b".
    private let emission: [[Emission]]
    private var lastShown: [Bool?]
    private var pulses: [Float]
    private(set) var mask: [UInt8]
    private var dirty = true
    /// Mask value 255 == this weight (room for pulses above 1).
    static let maskScale: Float = 2.6
    var pulseGain: Float = 0.8

    init(graphics g: GameGraphics, playfield: [UInt8], palette: Palette) {
        let w = TableGeometry.width, h = TableGeometry.height
        func lum(_ i: UInt8) -> Float {
            let c = palette[Int(i)]
            return (0.2126 * Float(c.r) + 0.7152 * Float(c.g) + 0.0722 * Float(c.b)) / 255
        }
        func pixel(_ s: IndexedSprite?, _ tx: Int, _ ty: Int) -> UInt8? {
            guard let s, tx >= s.x, ty >= s.y, tx < s.x + s.w, ty < s.y + s.h else { return nil }
            return s.pixels[(ty - s.y) * s.w + (tx - s.x)]
        }
        func emit(_ shown: IndexedSprite?, other: IndexedSprite?) -> Emission {
            guard let s = shown, ClassicComposer.blitterAccepts(s) else { return Emission(offsets: [], weights: []) }
            var o: [Int32] = [], ws: [Float] = []
            for r in 0..<s.h {
                for c in 0..<s.w {
                    let tx = s.x + c, ty = s.y + r
                    guard tx >= 0, ty >= 0, tx < w, ty < h else { continue }
                    let v = s.pixels[r * s.w + c]
                    let alt = pixel(other, tx, ty) ?? playfield[ty * w + tx]
                    let d = lum(v) - lum(alt)
                    if d > 0.04 {
                        o.append(Int32(ty * w + tx))
                        ws.append(min(1, (d - 0.04) * 3.2))
                    }
                }
            }
            return Emission(offsets: o, weights: ws)
        }
        var em: [[Emission]] = []
        for k in 0..<g.lampCount {
            let a = g.lampA.indices.contains(k) ? g.lampA[k] : nil
            let b = g.lampB.indices.contains(k) ? g.lampB[k] : nil
            em.append([emit(a, other: b), emit(b, other: a)])
        }
        emission = em
        lastShown = Array(repeating: nil, count: g.lampCount)
        pulses = Array(repeating: 0, count: g.lampCount)
        mask = [UInt8](repeating: 0, count: w * h)
    }

    /// Updates from the composer's shown records. `framesAdvanced` decays the pulses (one
    /// simulation frame = 0.8x). Returns true if the mask changed.
    func update(composer c: ClassicComposer, lampStates: [UInt8], framesAdvanced: Int) -> Bool {
        var changed = dirty
        dirty = false
        if framesAdvanced > 0 {
            for k in pulses.indices where pulses[k] > 0 {
                pulses[k] *= pow(0.8, Float(framesAdvanced))
                if pulses[k] < 0.02 { pulses[k] = 0 }
                changed = true
            }
        }
        for k in 0..<emission.count {
            let s = c.lampRecordShown(k)
            guard s != lastShown[k] else { continue }
            changed = true
            if let s {
                let now = emission[k][s ? 0 : 1].offsets.count
                let before = lastShown[k].map { emission[k][$0 ? 0 : 1].offsets.count } ?? 0
                let st = k < lampStates.count ? lampStates[k] : 0
                // Switched on (to the record that emits more) outside the blinking states.
                if lastShown[k] != nil, now > before, st != 3, st != 4 { pulses[k] = 1 }
            }
            lastShown[k] = s
        }
        guard changed else { return false }
        for i in mask.indices { mask[i] = 0 }
        for k in 0..<emission.count {
            guard let s = lastShown[k] else { continue }
            let e = emission[k][s ? 0 : 1]
            let gain = (1 + pulses[k] * pulseGain) / Self.maskScale * 255
            for (i, o) in e.offsets.enumerated() {
                let v = UInt8(min(255, (e.weights[i] * gain).rounded()))
                if v > mask[Int(o)] { mask[Int(o)] = v }
            }
        }
        return true
    }

    var hasPulse: Bool { pulses.contains { $0 > 0 } }
}
