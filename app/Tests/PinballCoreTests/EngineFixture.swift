import Foundation
@testable import PinballCore

/// A synthetic engine.json (our own made-up numbers, no game data) for unit tests.
enum EngineFixture {
    static let wallIndex = 200, activeIndex = 201, flipperIndex = 202, occluderIndex = 150, sensorIndex = 250
    static let flipperRow = 390

    /// Probe ring: 48 points on the outline of a 15x14 box, k=1 east, counter-clockwise.
    static func ring() -> [(Int, Int)] {
        (0..<48).map { i in
            let a = Double(i) * 2 * Double.pi / 48
            let x = Int((7 + 7 * cos(a)).rounded()), y = Int((6.5 - 6.5 * sin(a)).rounded())
            return (min(14, max(0, x)), min(13, max(0, y)))
        }
    }

    static func dictionary(params: [Int] = [16, 18, 7, 3, 6, 1, 5, 2, 4, 5]) -> [String: Any] {
        let r = ring()
        var normals: [[Int]] = [], push: [[Int]] = []
        for i in 0..<48 {
            let a = Double(i) * 2 * Double.pi / 48
            // velocity normal (-t0, t1) must point back into the ball: probe east -> normal west.
            var t0 = Int((50 * cos(a)).rounded()), t1 = Int((40 * sin(a)).rounded())
            if t0 == 0 { t0 = 1 }
            if t1 == 0 { t1 = 1 }
            normals.append([t0, t1])
            push.append([t0 > 0 ? 1 : (t0 < 0 ? -1 : 0), abs(t1) > 5 ? (t1 > 0 ? 1 : -1) : 0])
        }
        var wall0 = [Int](repeating: 0, count: 256), wall1 = [Int](repeating: 0, count: 256)
        wall0[wallIndex] = 1; wall0[activeIndex] = 3; wall0[flipperIndex] = 5
        wall1[wallIndex + 10] = 1
        var occ0 = [Int](repeating: 0, count: 256)
        occ0[occluderIndex] = 1; occ0[sensorIndex] = 3
        let gateOps: [[String: Any]] = [
            ["op": "if", "lhs": ["var", "obj_vx"], "cmp": "gt", "rhs": ["const", 0], "size": 16,
             "then": [["op": "set", "var": "lockout", "expr": ["const", 2]]],
             "else": [["op": "set", "var": "writeback", "expr": ["const", 1]],
                      ["op": "set", "var": "obj_vx", "expr": ["neg", ["var", "obj_vx"]] as [Any]],
                      ["op": "set", "var": "obj_x", "expr": ["add", ["var", "obj_x"], ["const", 3]] as [Any]],
                      ["op": "set", "var": "lockout", "expr": ["const", 2]]]],
        ]
        let sensorLevel0: [String: Any] = [String(sensorIndex): ["always": true, "ops": gateOps] as [String: Any]]
        let positions: [[Int]] = (0..<10).map { a in (0..<6).map { flipperRow * 320 + 100 + a * 3 + $0 } }
        return [
            "format": "epic-pinball-engine", "version": 1, "table": 1,
            "params": ["names": ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"], "values": params],
            "integration": ["step_cap": ["x_pos": 5, "x_neg": 4, "y_pos": 5, "y_neg": 5], "acc_clamp_pos": 2000,
                            "acc_clamp_neg": -2000, "min_x": 1, "min_y": 1, "y_reset": 3, "collision_y_limit": 384],
            "gravity": ["cutoff": 320, "extra_var": NSNull(), "extra_initial": 0],
            "probe_ring": ["offsets": r.map { $0.1 * 320 + $0.0 }],
            "normals": normals, "pushout": push,
            "wall": ["codes": ["empty", "wall", "wall_conditional", "active", "active_conditional", "flipper"], "lut": [wall0, wall1]],
            "occlusion": ["codes": ["ball_in_front", "occludes_ball", "sensor", "sensor_conditional"],
                          "lut": [occ0, [Int](repeating: 0, count: 256)], "ranges": [[149, 150], [0, 0]]],
            "kicker": ["cooldown_frames": 3, "tilt_disables": true],
            "collision": ["flipper_contact_split_x": 140],
            "flipper_kick": ["ranges": ["lo": 5, "side_max": 31, "top_max": 40, "side_index": 31, "tip_index": 41],
                             "vy_zero_side": 30, "vy_zero_top": 40, "fx": [-2, -2, -1, 0, 1, 1, 2, 3, 3, 4],
                             "fy": [40, 41, 42, 42, 41, 41, 40, 39, 38, 38]],
            "nudge_impulse": ["min_timer": 2, "dir_min": 4, "dir_max": 42, "vy_shift": 3, "vx": 20],
            "flipper_groups": [["key": "left", "value": flipperIndex, "rest_angle": 9, "init_angle": 2, "init_drawn": 2]],
            "flippers": [["group": 0, "positions": positions,
                          "sprite": ["frames": ["f0.png", "f1.png", "f2.png", "f3.png"], "x": 96, "y": 380, "w": 40, "h": 16]]],
            "flipper_erase_value": 42,
            "flipper_map": ["contact1_moving": 0, "contact2_moving": 0, "contact1_angle": 0, "contact2_angle": 0],
            "plunger": ["step": 10, "max": 50, "cmp": "ja", "lane_min_x": 280, "lane_min_y": 220],
            "serve": ["x": 284, "y": 336, "delay": 7],
            "drain_y": 399,
            "nudge": ["tilt_add": 35, "frames": 10, "tilt_threshold": 80, "lane_min_x": 280, "lane_max_y": 100],
            "ball_ball": ["divisor": 30, "max_dx": 15, "max_dy": 14],
            "ball": ["w": 15, "h": 14, "transparent": 0, "pixels": (0..<210).map { $0 % 15 == 0 ? 0 : 9 }],
            "sensors": ["levels": [sensorLevel0, [String: Any]()], "always_fires_value": 254],
            "timing": ["frame_hz": 59.94, "steps_per_frame": 3],
            "fallbacks": [String](),
        ]
    }

    static func json(_ mutate: (inout [String: Any]) -> Void = { _ in }) -> Data {
        var d = dictionary()
        mutate(&d)
        return try! JSONSerialization.data(withJSONObject: d)
    }

    static func engine(buffer: [UInt8]? = nil) throws -> ClassicEngine {
        let data = try EngineData.decode(json())
        return try ClassicEngine(data: data, startBuffer: buffer ?? [UInt8](repeating: 0, count: 320 * 400))
    }
}
