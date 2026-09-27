import Foundation
@testable import PinballCore

/// A synthetic table for rules tests: a made-up MZ image (header, a code segment we assemble by
/// hand, a data segment of our own bytes) and a matching `epic-pinball-rules/1` document. Nothing
/// here comes from the game.
enum RulesFixture {
    static let headerSize = 32
    /// Code at paragraph 0 of the image, data segment at paragraph 0x100.
    static let dataSegment = 0x100
    static var dsFileOffset: Int { headerSize + dataSegment * 16 }
    static let dsSize = 0x800

    // Data-segment layout (all made up).
    static let queue = 0x010, rate = 0x020, sweep = 0x022, sweepStep = 0x023, sweepEnd = 0x025, now = 0x027
    static let score = 0x100, lampPhase = 0x104, lampFirst = 0x105, lampCount = 8
    static let objX = 0x200, objY = 0x202, objVY = 0x204, objVX = 0x206, writeback = 0x210, layer = 0x211
    static let lockout = 0x212, cooldown = 0x213, tilted = 0x214, kick = 0x215, kickerCooldown = 0x216
    static let slotX = 0x220, slotY = 0x22A, slotVX = 0x234, slotVY = 0x23E, slotActive = 0x248, slotLayer = 0x252
    static let counter = 0x300, mode = 0x302, temp = 0x304, temp2 = 0x306, lastAX = 0x308, lastBX = 0x30A, contact = 0x30C
    static let message = 0x400
    /// Jump table for colours 0xAA...0xFF at cs:0x0100 (86 words).
    static let jumpTable = 0x0100
    static let sensorColour = EngineFixture.sensorIndex   // 250

    /// `code` is placed at cs:`codeAt`; the jump table maps `sensorColour` to cs:0x0500 and every
    /// other colour to cs:0x0600 (which is not a lifted block, i.e. the dispatcher's exit).
    static func exe(code: [UInt8] = [], codeAt: Int = 0x0800) -> [UInt8] {
        var img = [UInt8](repeating: 0, count: dsFileOffset + dsSize)
        img[0] = 0x4D; img[1] = 0x5A
        img[8] = UInt8(headerSize / 16)
        for v in 0xAA...0xFF {
            let ip = v == sensorColour ? 0x0500 : 0x0600
            let a = headerSize + jumpTable + 2 * (v - 0xAA)
            img[a] = UInt8(ip & 0xFF); img[a + 1] = UInt8(ip >> 8)
        }
        for (i, b) in code.enumerated() { img[headerSize + codeAt + i] = b }
        // data: lamp table terminated by 0xFF, a message string of our own
        img[dsFileOffset + lampFirst + lampCount] = 0xFF
        for (i, c) in Array("AB0".utf8).enumerated() { img[dsFileOffset + message + i] = c }
        img[dsFileOffset + rate] = UInt8(11000 & 0xFF); img[dsFileOffset + rate + 1] = UInt8(11000 >> 8)
        img[dsFileOffset + queue] = 0xFF; img[dsFileOffset + queue + 1] = 0xFF
        return img
    }

    static func hexs(_ v: Int) -> String { "0x" + String(v, radix: 16) }

    static func ev(_ a: Int, _ size: Int, count: Int? = nil) -> [String: Any] {
        var d: [String: Any] = ["addr": hexs(a), "size": size]
        if let count { d["count"] = count; d["stride"] = 2 }
        return d
    }

    /// The rules document. `blocks` are merged over the default handler/hook graphs.
    static func rules(blocks extra: [String: Any] = [:], sensors: [[String: Any]]? = nil,
                      hooks: [String: Any] = [:], mutate: (inout [String: Any]) -> Void = { _ in }) -> Data {
        var blocks: [String: Any] = [
            // sensor handler for `sensorColour`: remember AX/BX, count, lockout 2, bounce vx
            "L0500": ["ip": "0x0500", "ops": [
                ["op": "set", "var": "last_ax", "w": 2, "val": ["reg", "ax"]],
                ["op": "set", "var": "last_bx", "w": 2, "val": ["reg", "bx"]],
                ["op": "set", "var": "counter", "w": 1, "val": ["add", ["var", "counter", 1], 1]],
                ["op": "lockout", "frames": 2],
                ["op": "ball_commit", "val": 1],
                ["op": "ball", "set": ["vx": ["neg", ["ball", "vx"]]]],
            ], "end": ["return": true]],
            // kicker hook: record the contact pixel, kick 5, cooldown 3, score 100
            "L0700": ["ip": "0x0700", "ops": [
                ["op": "set", "var": "contact", "w": 1, "val": ["contact_colour"]],
                ["op": "set", "var": "kick_strength", "w": 1, "val": 5],
                ["op": "set", "var": "kicker_cooldown", "w": 1, "val": 3],
                ["op": "score", "add": 100],
            ], "end": ["return": true]],
        ]
        for (k, v) in extra { blocks[k] = v }
        var hk: [String: Any] = ["kicker": ["entry": "L0700", "stops": []]]
        for (k, v) in hooks { hk[k] = v }
        var root: [String: Any] = [
            "schema": "epic-pinball-rules/1", "table": 1, "exe": "EP1.EXE", "annotated": false,
            "source": ["code_segment": "0x0000", "data_segment": hexs(dataSegment), "sensor_dispatch": "0x0400",
                       "sensor_table": "cs:0100"],
            "memory": ["data_segment_file_offset": hexs(dsFileOffset), "data_segment_size": dsSize,
                       "player_block": ["start": hexs(score - 1), "end": hexs(lampFirst + lampCount + 1)],
                       "lamps": ["phase": hexs(lampPhase), "first": hexs(lampFirst), "count": lampCount]],
            "lamp_slots": [Any](),
            "engine_vars": [
                "sound.queue": ev(queue, 2), "sound.rate": ev(rate, 2), "sound.now": ev(now, 2),
                "sound.sweep@0022": ev(sweep, 1), "sound.sweep@0022.step_id": ev(sweepStep, 2), "sound.sweep@0022.end_id": ev(sweepEnd, 2),
                "score": ev(score, 4), "tilted": ev(tilted, 1), "ball.writeback": ev(writeback, 1), "ball.layer": ev(layer, 1),
                "ball.x": ev(objX, 2), "ball.y": ev(objY, 2), "ball.vy": ev(objVY, 2), "ball.vx": ev(objVX, 2),
                "sensor_lockout": ev(lockout, 1), "sensor_cooldown": ev(cooldown, 1), "kick_strength": ev(kick, 1),
                "kicker_cooldown": ev(kickerCooldown, 1),
                "ball_slots.x": ev(slotX, 2, count: 5), "ball_slots.y": ev(slotY, 2, count: 5),
                "ball_slots.vx": ev(slotVX, 2, count: 5), "ball_slots.vy": ev(slotVY, 2, count: 5),
                "ball_slots.active": ev(slotActive, 2, count: 5), "ball_slots.layer": ev(slotLayer, 1, count: 5),
            ],
            "vars": ["counter": ev(counter, 1), "mode": ev(mode, 2), "temp": ev(temp, 2), "temp2": ev(temp2, 2),
                     "last_ax": ev(lastAX, 2), "last_bx": ev(lastBX, 2), "contact": ev(contact, 1)],
            "stub_routines": [String: Any](),
            "sound_sweeps": [["var": hexs(sweep), "every_frames_mask": 3, "phase": 1, "rate_step": 1000, "rate_limit": 14000,
                              "ids": [["var": hexs(sweepEnd), "played": "at_end"], ["var": hexs(sweepStep), "played": "each_step"]]]],
            "gates": [["id": "gate0", "routine": "0x0900", "control_var": hexs(temp), "value_if_control_zero": 200,
                       "value_if_control_nonzero": 1, "half": 0, "pixels": [[10, 20], [11, 20]]]],
            "messages": [["ds": message, "file_offset": dsFileOffset + message, "length": 3, "printable": true]],
            "message_tables": [String: Any](),
            "sensors": sensors ?? [["colour": "FA", "value": sensorColour, "level": 0, "handler": "h0500",
                                    "fires_when_tilted": false, "ignores_lockout": false, "regions": [Any]()]],
            "handlers": ["h0500": ["entry": "L0500", "colours": ["FA"]]],
            "hooks": hk,
            "blocks": blocks,
        ]
        mutate(&root)
        return try! JSONSerialization.data(withJSONObject: root)
    }

    static func program(_ data: Data = rules()) throws -> RulesProgram { try RulesProgram.decode(data) }

    /// A synthetic engine with the rules attached (`mode`), rules booted.
    static func engine(rules data: Data = rules(), code: [UInt8] = [], mode: RulesMode = .rules,
                       buffer: [UInt8]? = nil) throws -> (ClassicEngine, RulesRuntime) {
        let e = try EngineFixture.engine(buffer: buffer)
        let r = try RulesRuntime(program: try program(data), exe: exe(code: code))
        r.attach(to: e, mode: mode)
        e.resetToRest()
        r.boot()
        return (e, r)
    }

    /// A block with the given ops that returns.
    static func block(_ ip: Int, _ ops: [[String: Any]], end: [String: Any] = ["return": true]) -> [String: Any] {
        ["ip": hexs(ip), "ops": ops, "end": end]
    }
}
