import Foundation

// Demo mode in the engine (Attract.swift has the original's code and addresses). Everything keys
// off the DS byte demo_mode, as the original's branches do: `RulesOptions.demo` sets it at boot (the
// entry code's 'D'), a scenario's `"pokes": {"demo_mode": 1}` after it (as the harness pokes it).
// Off, none of this runs and the engine is unchanged.

extension ClassicEngine {
    /// The table's demo-mode code (from the EXE, through the attached rules); nil = not found.
    public var attractLayout: AttractLayout? { rules?.attract }

    /// demo_mode (EP1 ds:6C5A) is 1.
    public var demoMode: Bool {
        guard let a = attractLayout else { return false }
        return dsRead(a.flag, 1) == 1
    }

    /// Sets or clears demo_mode in the data segment (the demo's keys are released either way).
    public func setDemoMode(_ on: Bool) {
        guard let a = attractLayout else { return }
        dsWrite(a.flag, 1, on ? 1 : 0)
        demoKeys = []
    }

    /// The demo's key test would act on a key now (key-repeat counter ds:000A at 0, cs:0CFF): the
    /// original then ends the demo (pause_menu -> quit, cs:13E3).
    public var demoAcceptsKey: Bool {
        guard let a = attractLayout else { return true }
        return dsRead(a.keyRepeat, 1) == 0
    }

    func setDemoKeys(_ k: FrameInput) {
        demoKeys = k
        input = k
    }

    /// attract_autoflip (EP1 cs:0C48..0D1A; EP5 cs:091E..099A), run in the full main loop in place
    /// of the key handling and nudge/tilt (cs:0D1D..0E8A) while demo_mode is set.
    func attractBlock(_ a: AttractLayout) {
        // cs:0C4F: the flip timer runs down, then both flipper keys are released (cs:0C60)
        let t = dsRead(a.flipTimer, 1)
        if t != 0 { dsWrite(a.flipTimer, 1, t - 1) } else { setDemoKeys([]) }
        slots: for i in 0..<min(a.slots, balls.count) {
            if a.activeTest && balls[i].active != 1 { continue }               // cs:0C6F
            if let st = a.stuck {
                // cs:0C76..0CAC: unchanged x,y for `limit` frames -> vx += 1 (one counter for all slots)
                let sx = st.x + 2 * i, sy = st.y + 2 * i
                let x = Int(UInt16(bitPattern: balls[i].x)), y = Int(UInt16(bitPattern: balls[i].y))
                if y == dsRead(sy, 2) && dsRead(sx, 2) == x {
                    let n = (dsRead(st.counter, 1) + 1) & 0xFF
                    dsWrite(st.counter, 1, n)
                    if n == st.limit { balls[i].vx &+= 1 }
                } else {
                    dsWrite(sx, 2, x)
                    dsWrite(sy, 2, y)
                    dsWrite(st.counter, 1, 0)
                }
            }
            // cs:0CB1..0CF1: a ball low over a flipper presses that flipper's key and ends the loop
            let x = Int(UInt16(bitPattern: balls[i].x)), y = Int(UInt16(bitPattern: balls[i].y))
            guard y >= a.flipMinY else { continue }
            if x > a.leftX.upperBound {
                guard a.rightX.contains(x) else { continue }
                setDemoKeys(demoKeys.union(.rightFlipper))
            } else {
                guard x >= a.leftX.lowerBound else { continue }
                setDemoKeys(demoKeys.union(.leftFlipper))
            }
            dsWrite(a.flipTimer, 1, a.flipFrames)
            break slots
        }
        // cs:0CFF: the key-repeat counter runs down (a key at 0 ends the demo: the front end's job)
        let k = dsRead(a.keyRepeat, 1)
        if k != 0 { dsWrite(a.keyRepeat, 1, k - 1) }
    }
}
