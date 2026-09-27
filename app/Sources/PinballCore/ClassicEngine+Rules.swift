import Foundation

// The engine side of the rules layer: the DS bus bindings (`RulesHost`) and the per-frame order of
// the original main loop when rules run (EP1 addresses; the harness modes are in emulation.md 2).

extension ClassicEngine: RulesHost {
    public func rulesField(_ f: EngineField) -> Int {
        func w(_ v: Int16) -> Int { Int(UInt16(bitPattern: v)) }
        switch f {
        case .objX: return w(obj.x)
        case .objY: return w(obj.y)
        case .objVX: return w(obj.vx)
        case .objVY: return w(obj.vy)
        case .writeback: return Int(writeback)
        case .layer: return Int(curLayer)
        case let .slotX(i): return w(balls[i].x)
        case let .slotY(i): return w(balls[i].y)
        case let .slotVX(i): return w(balls[i].vx)
        case let .slotVY(i): return w(balls[i].vy)
        case let .slotAccX(i): return w(balls[i].accx)
        case let .slotAccY(i): return w(balls[i].accy)
        case let .slotActive(i): return Int(balls[i].active)
        case let .slotLayer(i): return Int(balls[i].layer)
        case .lockout: return Int(eventLockout)
        case .cooldown: return Int(eventCooldown)
        case .kickerCooldown: return Int(kickerCooldown)
        case .kickStrength: return Int(kickStrength)
        case .tilted: return tilted ? 1 : 0
        case .extraGravity: return w(extraGravity)
        case .serveDelay: return Int(serveDelay)
        case .plungerCharge: return Int(plungerCharge)
        case .nudgeTimer: return Int(nudgeTimer)
        case .tiltMeter: return Int(tiltMeter)
        case .hitCount: return hitList.count
        case let .flipperAngle(g): return groups.indices.contains(g) ? w(groups[g].angle) : 0
        case let .flipperDrawn(g): return groups.indices.contains(g) ? w(groups[g].drawn) : 0
        case let .flipperMoving(g): return groups.indices.contains(g) && groups[g].moving ? 1 : 0
        case let .param(i): return w(params[i])
        case let .lockoutSlot(i): return lockoutSlots.indices.contains(i) ? Int(lockoutSlots[i]) : 0
        }
    }

    public func rulesSetField(_ f: EngineField, _ v: Int) {
        let s = Int16(truncatingIfNeeded: v), b = UInt8(truncatingIfNeeded: v)
        switch f {
        case .objX: obj.x = s
        case .objY: obj.y = s
        case .objVX: obj.vx = s
        case .objVY: obj.vy = s
        case .writeback: writeback = b
        case .layer: curLayer = b
        case let .slotX(i): balls[i].x = s
        case let .slotY(i): balls[i].y = s
        case let .slotVX(i): balls[i].vx = s
        case let .slotVY(i): balls[i].vy = s
        case let .slotAccX(i): balls[i].accx = s
        case let .slotAccY(i): balls[i].accy = s
        case let .slotActive(i): balls[i].active = UInt16(truncatingIfNeeded: v)
        case let .slotLayer(i): balls[i].layer = b
        case .lockout: eventLockout = b
        case .cooldown: eventCooldown = b
        case .kickerCooldown: kickerCooldown = b
        case .kickStrength: kickStrength = b
        case .tilted: tilted = b != 0
        case .extraGravity: extraGravity = s
        case .serveDelay: serveDelay = b
        case .plungerCharge: plungerCharge = UInt16(truncatingIfNeeded: v)
        case .nudgeTimer: nudgeTimer = b
        case .tiltMeter: tiltMeter = b
        case .hitCount: break   // read-only view of the probe's hit list
        case let .flipperAngle(g): if groups.indices.contains(g) { groups[g].angle = s }
        case let .flipperDrawn(g): if groups.indices.contains(g) { groups[g].drawn = s }
        case let .flipperMoving(g): if groups.indices.contains(g) { groups[g].moving = b != 0 }
        case let .param(i): params[i] = s
        case let .lockoutSlot(i): if lockoutSlots.indices.contains(i) { lockoutSlots[i] = b }
        }
    }

    public func rulesPixel(_ i: Int) -> UInt8 { pixel(i) }

    public func rulesSetPixel(_ i: Int, _ v: UInt8) {
        if i >= 0 && i < buffer.count { setBufferByte(i, v) }
    }

    public func rulesInput(_ which: Int) -> Int {
        which == 0 ? (input.contains(.leftFlipper) ? 1 : 0) : (input.contains(.rightFlipper) ? 1 : 0)
    }

    /// The main loop with rules, in the original order (EP1 cs:04D2..1243). Pieces a table has no
    /// hook or glue for fall back to the physics engine's own version.
    func rulesFrameLogic(_ r: RulesRuntime) {
        let full = rulesMode == .full
        if full, r.hasAutomaticHooks {
            for item in r.schedule(engine: self) { runScheduled(item, r) }
            return
        }
        if full {
            r.runRange("preFrame")                                            // EP10 cs:053E (ball steering)
            r.runRange("attract")                                             // cs:04D2 (multi-player)
        }
        if !r.hook("frame_timers") { if extraGravity != 0 { extraGravity &-= 1 } }   // cs:06E2..0711
        positionGates()                                                       // EP6 cs:0979, EP9 cs:0550
        r.runRange("ruleTimers")                                              // EP9 cs:058B, EP8 cs:05D4 (rules glue)
        if full { r.runRange("postTimers") }                                  // EP10 cs:0571 (top gate)
        if full {
            r.runRange("scroller")                                            // cs:0813 DMD scroller
            r.soundBlock()                                                    // cs:0898 sounds
        }
        if !(full && r.hook("frame_counters")) {                              // cs:09DC..0A17
            frameCounters()                                                   // cs:09EC..0A0D
        }
        if full { r.runRange("dmdTimer") }                                    // cs:0A17
        if !r.hook("drain") { drainCheck() }                                  // cs:0A31..0A9A
        plungerLane()                                                         // cs:0A9D..0C48
        nudgeTilt()                                                           // cs:0DFD..0E8A
        if full {
            r.hook("flipper_lane_change")                                     // cs:102E..1080
            r.lampUpdate()                                                    // cs:10C2 lamp_update
            r.hook("lamp_flash")                                              // cs:10D0..10F5
            r.runRange("scoreDirty")                                          // cs:111E
            r.hook("iq_display")                                              // cs:1134..119F
        }
        r.runRange("preGravity")                                              // EP8 cs:1095 toy shapes (rules glue)
        gravityAndScan()                                                      // cs:119F..1236
        if full { r.renderFrame() }                                           // cs:1236 render_frame
    }

    /// One piece of the automatic full-mode main loop (EP2-EP13, `RulesRuntime.schedule`).
    func runScheduled(_ item: RulesRuntime.MainLoopItem, _ r: RulesRuntime) {
        switch item {
        case let .hook(name): r.hook(name)
        case let .glue(name): r.runRange(name)
        case .decay: if extraGravity != 0 { extraGravity &-= 1 }
        case .gates: positionGates()
        case .sound: r.soundBlock()
        case .counters: frameCounters()
        case .drain: drainCheck()
        case .lane: plungerLane()
        case .nudge: nudgeTilt()
        case .lamps: r.lampUpdate()
        case .gravity: gravityAndScan()
        case .render: r.renderFrame()
        }
    }

    /// A new game with the attached rules in `full` mode: power-on state, flippers at rest, the
    /// data segment as the original's init leaves it, and the EXE's own ball slots (slot 0 waits in
    /// the plunger lane), exactly how the original enters its main loop. Without rules this is
    /// `resetToRest` plus a served ball.
    public func startGame(options: RulesOptions = RulesOptions()) {
        resetToRest()
        guard let r = rules else {
            for i in balls.indices { balls[i].active = 0 }
            serveBall()
            return
        }
        r.options = options
        rulesMode = .full
        sensorsEnabled = true
        r.boot()
    }

    /// Presentation snapshot for the current frame. Rules-derived fields (lamps, scores, message,
    /// sounds, ...) are filled by the attached rules and their per-frame queues are cleared.
    public func takePresentation() -> PresentationState {
        var s = PresentationState()
        s.tilted = tilted
        rules?.takePresentation(into: &s)
        return s
    }
}
