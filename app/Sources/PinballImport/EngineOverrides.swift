// Generated from tools/engine_overrides/EPn.json (hand-verified code addresses, engine constants and
// flags for tools/export_engine_data.py; no game data: pixel lists and tables are referenced by DS
// offset and read from the user's EXE). Embedded so the importer needs no bundle resources.
// PinballImportTests.testEmbeddedOverridesMatchTools checks this file against tools/engine_overrides.
// Regenerate: see docs/enhanced/import.md ("Engine overrides").

enum EngineOverrides {
    /// table number -> override JSON text
    static let json: [Int: String] = [
        2: #"""
{
 "format": "epic-pinball-engine-overrides/1",
 "table": 2,
 "exe": "EP2.EXE",
 "note": "Additive patch for extracted/tables/EP2/engine.json: deep-merge 'patch' into the exporter's output (new keys only; nothing here renames or removes a key). export_engine_data.py does not read this directory yet. Only code addresses (cs:/ds: offsets in EP2's own segments), small engine constants and flags are stored; nothing is copied from the game. Every value is cited in 'evidence' and was checked on the original code with the harness (scenarios in tools/emu/scenarios/EP2/hand/).",
 "patch": {
  "serve": {
   "layer": 1
  },
  "plunger": {
   "lane_layer_test": false
  },
  "drain": {
   "slots": 5,
   "serve_when_empty": 5,
   "clear_layer_on_drain": false,
   "transfer": {
    "when": "after any slot drains, slot 0 is inactive and exactly one of slots 1, 2 is active",
    "from_slots": [
     1,
     2
    ],
    "to_slot": 0,
    "copies": [
     "x",
     "y",
     "vx",
     "vy"
    ],
    "not_copied": [
     "accx",
     "accy",
     "layer"
    ],
    "source_active_after": 0,
    "rule_var_cleared": "0x0171",
    "requires_flag_var": null
   }
  },
  "kicker": {
   "requires_layer0": true,
   "kick_constant_when_y_at_least": {
    "y": 200,
    "kick": 6
   },
   "contact_on_fire_applies_when_tilted": true
  },
  "sensors": {
   "sprite_mask": "word",
   "sprite_mask_note": "a 'sensor' pixel under the ball box fires only if the ball sprite word at the same box position is non-zero: (ball.pixels[i] | ball.pixels[i+1]) != 0, i = row*w + col (i+1 = 210 reads the byte after the sprite copy, ds:63BA). Occluder writes into the copy never change a later test."
  }
 },
 "evidence": {
  "serve.layer": "cs:0AFB mov byte [ball_layer0 ds:5568],1 after the serve stores cs:0AD8..0AF5 (engine.json ball_slots_initial slot 0 also has layer 1). Harness: hand/serve_layer1_plunge record 0 layer 1. On layer 0 the lane art is wall: the first step pushes the ball 19 px out of the lane (the port does this today).",
  "plunger.lane_layer_test": "lane guard cs:0BB4..0BC9 tests active, x >= 280, y >= 220 only; EP1 has cmp byte [ball_layer0],0 at cs:0AA4. Harness: hand/plunger_launch_layer1 charges on layer 1.",
  "drain": "drain loop cs:0A41..0AD6 (di = 10..2, slots 4..0; cx counts empty slots; serve when cx == 5 at cs:0AD3).",
  "drain.transfer": "cs:0A5D clears the drained slot; cs:0A63 slot0 active -> no transfer (cs:0AB7: if slots 1 and 2 are both inactive, ds:0171 = 0); cs:0A6A..0A78 slot1 active and slot2 inactive -> bx=2; cs:0AAB..0AB2 slot1 inactive and slot2 active -> bx=4; cs:0A7B..0AA0 active[bx]=0, active[0]=1, x/y/vx/vy[0] = [bx]; cs:0AA3 ds:0171 = 0. Harness: hand/multiball_drain_transfer record 0 continues with slot 1's ball.",
  "kicker.requires_layer0": "kicker_hit cs:1B47 cmp byte [di+ball_layer],0; je; jmp ret (unreachable today: layer 1 has no active colour range, dh = 0 at cs:19CA).",
  "kicker.kick_constant_when_y_at_least": "kicker_hit cs:1B5D kick_strength = param[2] (ds:557B), then for u16 ball y >= 200 (cs:1B68 cmp [di+y],0C8h; jb) cs:1BD3 mov byte [kick_strength ds:5563],6. Latent in play (param[2] = 6 in EP2); harness: hand/slingshot_kick_const with params.kicker = 3 keeps kick 6.",
  "kicker.contact_on_fire_applies_when_tilted": "cs:1A2B call kicker_hit; cs:1A2E jmp past the append, whatever kicker_hit did: while tilted (kicker_hit returns at cs:1B58..1B5A without setting the cooldown) the kicker colours are no contact at all. Harness: hand/bumper_hit_tilted has no response where the port reflects.",
  "sensors.sprite_mask": "ball_pixel_scan cs:17E9: cs:17ED..17F8 copies the ball sprite (ds:63BC, 4-byte w/h header + 210 bytes) to ds:62E4; si walks it (cs:1818..181C, inc si per pixel cs:1861); cs:184A lockout test, then cs:184F cmp word ptr [si],0; je skip before the dispatch call cs:1854. Only EP2 has this test (EP1 cs:16DA..16E6 and EP3..EP13 scans have none). Harness: plunger_launch (layer 1) rules mode, handler 0xD1 cs:2BD2 fires at frame 119 on the original; without the mask the port fires at frame 118."
 }
}
"""#,
        3: #"""
{
 "format": "epic-pinball-engine-overrides/1",
 "table": 3,
 "exe": "EP3.EXE",
 "note": "Additive patch for extracted/tables/EP3/engine.json: deep-merge 'patch' into the exporter's output (new keys only). export_engine_data.py does not read this directory yet. Only code addresses, small engine constants and flags; every value is cited in 'evidence' and was run on the original code (tools/emu/scenarios/EP3/hand/).",
 "patch": {
  "drain": {
   "slots": 2,
   "serve_when_empty": 2,
   "clear_layer_on_drain": false,
   "transfer": null
  },
  "plunger": {
   "lane_layer_test": true
  },
  "nudge_impulse": {
   "skip_slots": [2]
  }
 },
 "evidence": {
  "drain": "drain loop cs:0763 mov di,4 (slots 1 and 0 only; slot 2 is the captive ball, engine.json ball_slots_initial slot 2 active at (237,175)); serve when cx == 2 (cs:07A4 cmp cx,2; jne). A slot >= 2 is never drained and never counted. Harness: hand/captive_drain_serve serves ball 0 at frame 0 with the captive ball in play.",
  "plunger.lane_layer_test": "cs:0887 cmp byte [ball_layer0 ds:4DD6],0; jne out (as EP1 cs:0AA4).",
  "nudge_impulse.skip_slots": "collision_response cs:1A85 cmp di,4; je ret: slot 2 never gets the nudge impulse (cs:1A8A..1AC5)."
 }
}
"""#,
        4: #"""
{
 "format": "epic-pinball-engine-overrides/1",
 "table": 4,
 "exe": "EP4.EXE",
 "note": "Additive patch for extracted/tables/EP4/engine.json: deep-merge 'patch' into the exporter's output (new keys only). export_engine_data.py does not read this directory yet. The upper-flipper kick tables are NOT copied: only their DS offsets and length are given, the loader reads the words from the user's EP4.EXE data segment (ds = 0x000E, file offset = header + (ds*16 + offset)). Every value is cited in 'evidence' and was checked by hand against the original's trace.",
 "patch": {
  "flipper_kick": {
   "gate_detail": "supersedes gate_note (which omits the upper kick). flipper contact (flipper_contact != 0), all u16 ball coordinates: if y >= side_min_y the EP1 path runs (y -= 1, side/tip kick, return if it applied); otherwise the plain wall push-out (x -= p0[k], y += p1[k]). Then, first response only: if flipper_contact != 0 and y >= top_min_y the EP1 top kick; if flipper_contact != 0 and y < top_min_y the upper_kick below; else the normal kicker/reflection path.",
   "upper_kick": {
    "split_x": 145,
    "vy_zero_if_positive": true,
    "right": {"when": "u16 x >= split_x", "angle_group": 1, "dx": -1, "dy": 1, "vx_sub_table": "0x598f", "vy_sub_table": "0x59a5", "table_words": 10},
    "left": {"when": "u16 x < split_x", "angle_group": 0, "dx": 1, "dy": 1, "vx_sub_table": "0x59bb", "vy_sub_table": "0x59d1", "table_words": 10, "rule_timer": {"var": "0x081c", "size": 2, "value": 400}},
    "order": "if vy > 0 (signed): vy = 0; y += dy; x += dx; vx -= table_vx[angle]; vy -= table_vy[angle]; [left: rule_timer = value]; return (no nudge impulse)",
    "table_segment": "ds"
   }
  },
  "drain": {
   "slots": 5,
   "serve_when_empty": 5,
   "clear_layer_on_drain": true,
   "transfer": {
    "when": "a slot drains while the multiball flag requires_flag_var == 1; the flag and rule_vars_cleared are cleared first; the move happens only if the drained slot is 0 and slot 1 is active",
    "requires_flag_var": "0x08fc",
    "rule_vars_cleared": ["0x08fc", "0x5529", "0x552b", "0x5531"],
    "from_slots": [1],
    "to_slot": 0,
    "copies": ["x", "y", "vx", "vy", "layer"],
    "not_copied": ["accx", "accy"],
    "source_active_after": 0
   }
  },
  "plunger": {
   "lane_layer_test": true
  }
 },
 "evidence": {
  "flipper_kick.side gate": "collision_response cs:1B94 cmp byte [flipper_contact ds:595C],0; je; cs:1B9B cmp word [di+y],12Ch; jb 1BFA (plain push-out cs:1BFA..1C09); else cs:1BA3 y -= 1 and the EP1 side/tip path cs:1BA8..1BF7.",
  "flipper_kick.top gate": "cs:1C0D collided -> ret; cs:1C17 flipper_contact == 0 -> cs:1CF1 normal path; cs:1C21 cmp word [di+y],136h; jb 1C62; cs:1C29..1C5F EP1 top kick.",
  "flipper_kick.upper_kick": "cs:1C62 cmp word [di+x],91h; jb 1CBD. Right cs:1C6A..1C95: bx = 2*[ds:6D35] (right group angle), vy > 0 -> 0 (cs:1C70 jle), inc y, dec x, vx -= [bx+598F], vy -= [bx+59A5], jmp ret. Left cs:1CBD..1CEE: bx = 2*[ds:6D33], same with inc x, [bx+59BB], [bx+59D1], then cs:1CE8 mov word [081C],190h; jmp ret (cs:1E6B, after the nudge impulse). ds:081C is a rule timer: decremented per frame at cs:0A12..0A19, read by the handler at cs:24FD.",
  "flipper_kick.upper_kick check": "fall_upper_right_flipper_held frame 1 step 1 (right angle 5): vx -14 - [598F+10] = -290, vy 0 - [59A5+10] = -252 = original; upper_left_flipper_shot frame 4 step 0 (left angle 3): vx -344 - [59BB+6] = -104, vy -[59D1+6] = -308 = original.",
  "drain.clear_layer_on_drain": "drain loop cs:0A62..0AE6: cs:0A84 mov byte [di+5963],0 = ball_layer[slot] (layer array ds:5965, di = 2*slot+2). Harness: hand/drain_layer_reset serves a layer-1 ball on layer 0.",
  "drain.transfer": "cs:0A89 cmp byte [08FC],1; jne; cs:0A90..0AA1 clear 08FC, 5529, 552B, 5531; cs:0AA7 cmp di,2 (slot 0 drained); cs:0AAC slot 1 active -> cs:0AB3..0ADA active[1]=0, active[0]=1, x/y/vx/vy/layer[0] = slot 1. Not exercised by a scenario: the harness pokes named variables only, and ds:08FC has no name (rule state).",
  "plunger.lane_layer_test": "cs:0BCB cmp byte [ball_layer0 ds:5965],0; jne out."
 }
}
"""#,
        5: #"""
{
 "format": "epic-pinball-engine-overrides/1",
 "table": 5,
 "exe": "EP5.EXE",
 "note": "Additive patch for extracted/tables/EP5/engine.json: deep-merge 'patch' into the exporter's output (new keys only). export_engine_data.py does not read this directory yet. Only code addresses, small engine constants and flags; every value is cited in 'evidence' and was run on the original code (tools/emu/scenarios/EP5/hand/).",
 "patch": {
  "integration": {
   "min_x_set": 0,
   "min_x_note": "x < min_x (signed) -> x = min_x_set (EP1: min_x_set = min_x = 1)"
  },
  "plunger": {
   "lane_layer_test": false
  },
  "drain": {
   "slots": 5,
   "serve_when_empty": 5,
   "clear_layer_on_drain": false,
   "transfer": null
  }
 },
 "evidence": {
  "integration.min_x_set": "cs:1321 cmp word [di+x],1; jge; cs:1328 mov word [di+x],0 (EP1 cs:17A8..17AF stores 1). Harness: hand/x_clamp_left (hit list differs from the port on the first step).",
  "plunger.lane_layer_test": "lane guard cs:081D..0832 tests active, x >= 290, y >= 340 only (no ball_layer test).",
  "drain": "drain loop cs:071C..0740 (slots 4..0, serve when cx == 5 at cs:073D; serve cs:0742..075F with vx = 2, already in engine.json serve.vx).",
  "kicker.cooldown_is_sensor_lockout (already exported)": "one byte ds:43DE: dec cs:06F7..06FE, kicker gate cs:141A cmp byte [43DE],0; jne +9 (not +3), kicker sets 4 cs:1533, sensor handlers set 1/3/15 cs:1AC4..1D5F, pixel scan reads it cs:1233/1262. Harness: hand/bumper_hit_lockout."
 }
}
"""#,
        6: #"""
{
 "format": "epic-pinball-engine-overrides/1",
 "table": 6,
 "exe": "EP6.EXE",
 "note": "Additive patch for extracted/tables/EP6/engine.json: deep-merge 'patch' into the exporter's output (new keys only; nothing here renames or removes a key). export_engine_data.py does not read this directory yet. Only code addresses (cs:/ds: offsets in EP6's own segments), small engine constants and flags; nothing is copied from the game (pixel lists are referenced by their DS offset and read from the user's EXE). Every value is cited in 'evidence' and was run on the original code with the harness (scenarios in tools/emu/scenarios/EP6/hand/, generator scratch/tables/common/extra_scenarios.py).",
 "patch": {
  "gates": [
   {
    "id": "lane_exit_one_way",
    "kind": "ball_position",
    "when": "every_frame, main-loop order: before the per-frame counters (EP6 cs:0990)",
    "flag_var": "0x6bcb",
    "close_if": {
     "flag_ne": 1,
     "ball": 0,
     "x_le": 230
    },
    "open_if": null,
    "reopened_by": "ball_lost_fade (cs:31D3 flag=0, cs:31D8 redraw)",
    "pixels": {
     "list": "0x6bcc",
     "list_format": "u16 count, then count u16 offsets",
     "half": 0
    },
    "value_closed": 236,
    "value_open": 1,
    "side_var": {
     "var": "0x59a8",
     "closed": 1,
     "open": 2
    },
    "draw_ip": "0x3bd4"
   }
  ],
  "plunger": {
   "lane_layer_test": false
  },
  "drain": {
   "slots": 5,
   "serve_when_empty": 5,
   "clear_layer_on_drain": false,
   "transfer": null
  },
  "sensors": {
   "lockout_is_kicker_cooldown": true
  }
 },
 "evidence": {
  "gates": "cs:0979 cmp byte [6BCB],1; je 0990; cs:0980 cmp word [ball_x0 ds:69A3],0E6h; ja 0990; cs:0988 mov byte [6BCB],1; cs:098D call 3BD4. cs:3BD4: ES=[6B6D] (pf_seg_top), dl=ECh/al=1 if [6BCB]==1 else dl=01h/al=2; [59A8]=al; si=6BCC: lodsw count, then per pixel lodsw offset, mov es:[di],dl. Only other writer of [6BCB]: ball_lost_fade cs:31D3 (=0) then cs:31D8 call 3BD4. Boot value [6BCB]=0; the 32 pixels are a diagonal (241,12)..(255,40), 0x4F at boot (not solid). Harness: tools/emu/tables/EP6.json override (physics range cs:0979..099B); hand/gate_one_way_hit: original contact k=3 at frame 4 step 1 on the gate, the port passes through.",
  "plunger.lane_layer_test": "lane guard cs:0AD5..0AEA: cmp word [ball_active0],0; je; cmp word [ball_x0],122h; jb; cmp word [ball_y0],154h; jb (no ball_layer test; EP1 cs:0AA4, EP7 cs:0A36, EP9 cs:0C6D test it). Harness: hand/lane_layer1_plunge (original charge 12 at record 0 on layer 1, port 0).",
  "drain": "drain loop cs:09D2..09F6 (di = 10..2, slots 4..0, cx counts empty slots, serve when cx == 5 at cs:09F3); serve cs:09F8..0A15 stores serve_delay 7, y 15Ah, vy 0, vx 2, x 129h, active 1; no ball_layer store. serve.vx = 2 is already in engine.json: the port's serveBall ignores it (hand/serve_plunger_held: original vx 2 from record 6, port 0).",
  "sensors.lockout_is_kicker_cooldown": "same fact as the exported kicker.cooldown_is_sensor_lockout, stated on the sensor side: kicker_hit cs:198A mov byte [5C3A],4; the only per-frame decrement cs:0990..099B; sensor handlers write [5C3A] (e.g. h29a9 saucer lockout 1, h2b79 lockout 15) and the ball scan reads it. The port keeps two counters: hand/bumper_hit_shared_lockout (event_lockout=8 poked; original kick 0, port kick 8) and, with rules loaded, the saucer h29a9 fires ~10 times per frame in the port instead of once (long_600_scripted, frame 329: original [4927] 49,48,47..., port 39,29,19,...)."
 }
}
"""#,
        7: #"""
{
 "format": "epic-pinball-engine-overrides/1",
 "table": 7,
 "exe": "EP7.EXE",
 "note": "Additive patch for extracted/tables/EP7/engine.json: deep-merge 'patch' into the exporter's output (new keys only; nothing here renames or removes a key). export_engine_data.py does not read this directory yet. Only code addresses (cs:/ds: offsets in EP7's own segments), small engine constants and flags; nothing is copied from the game (pixel lists are referenced by their DS offset and read from the user's EXE). Every value is cited in 'evidence' and was run on the original code with the harness (scenarios in tools/emu/scenarios/EP7/hand/, generator scratch/tables/common/extra_scenarios.py).",
 "patch": {
  "serve": {
   "layer": 0
  },
  "plunger": {
   "lane_layer_test": true
  },
  "drain": {
   "slots": 5,
   "serve_when_empty": 5,
   "clear_layer_on_drain": false,
   "transfer": null
  }
 },
 "evidence": {
  "serve.layer": "serve cs:0A04..0A27: serve_delay 7, y 150h, vy 0, vx 0, x 11Ch, active 1, then cs:0A27 mov byte [ball_layer0 ds:5539],0 (EP1's serve cs:0A77..0A94 has no level store). Harness: hand/serve_clears_layer (layer-1 ball drains; original layer 0 from record 6, port keeps 1).",
  "plunger.lane_layer_test": "lane guard cs:0A2F..0A4B tests active, ball_layer0 == 0 (cs:0A36), x >= 118h, y >= 0DCh, like EP1.",
  "drain": "drain loop cs:09BE..0A02 (di = 10..2, slots 4..0; serve when cx == 5 at cs:09FF); the drained slot's rule vars [50EE]/[50F0]/[50F6] are cleared only when [50F6]==1 (rule state).",
  "sensors.always_fires (already exported = 219)": "ball scan cs:1738 cmp al,0DBh; je 1741 (skips the lockout test at cs:173C). DB is the lane-reversal sensor h28c2. Harness: hand/db_bypasses_lockout (rules mode, event_lockout=20 poked: the reversal still happens; the port matches). Note for rules.py: rules.json sensors[DB].ignores_lockout is false, it should be true."
 }
}
"""#,
        8: #"""
{
  "format": "epic-pinball-engine-overrides/1",
  "table": 8,
  "exe": "EP8.EXE",
  "note": "Additive patch for extracted/tables/EP8/engine.json: deep-merge 'patch' into the exporter's output (new keys only; nothing here renames or removes a key). export_engine_data.py does not read this directory yet. Only code addresses (cs:/ds: offsets in EP8's own segments), small engine constants and flags; nothing is copied from the game (pixel lists are referenced by their DS offset and read from the user's EXE). Every value is cited in 'evidence' and was run on the original code with the harness (scenarios in tools/emu/scenarios/EP8/hand/, generator scratch/tables/common/extra_scenarios.py).",
  "patch": {
    "plunger": {
      "launch_block": {
        "ip": "0x0b62",
        "skip_if": {
          "ball_layer0_var": "0x5f44",
          "ball_layer0_ne": 0,
          "any_active_slots": [
            0,
            1,
            2
          ]
        },
        "serve_delay": {
          "var": "0x5aeb",
          "ball_lost_fade_at": 1,
          "ops_at_1": [
            [
              "0x5ae1",
              2,
              0
            ],
            [
              "0x5ae3",
              2,
              0
            ],
            [
              "0x5ae9",
              2,
              0
            ]
          ]
        },
        "scroll_keys_first": {
          "up": "cs:0278",
          "down": "cs:0279"
        },
        "hold_keys": [
          "ctrl cs:027F",
          "space cs:027C",
          "demo ds:7285"
        ],
        "flag_var": "0x5aec",
        "hold_sets_flag_to": 700,
        "release_if_flag_nonzero": {
          "flag_to": 0,
          "slot": 0,
          "active": 1,
          "x": 148,
          "y": 396,
          "vx": -147,
          "vy": -600,
          "keeps": [
            "accx",
            "accy",
            "layer"
          ]
        },
        "release_ds_ops": [
          [
            "0x5ade",
            2,
            0
          ],
          [
            "0x00c1",
            2,
            0
          ],
          [
            "0x009e",
            2,
            6
          ],
          [
            "0x037f",
            1,
            150
          ]
        ],
        "release_message": {
          "bx": "0x0583",
          "ax": 1,
          "di": "0x1400",
          "call": "cs:0C30 call 15C5 (dmd_message)"
        }
      },
      "lane_present": false
    },
    "drain": {
      "slots": 3,
      "slot_order": [
        2,
        1,
        0
      ],
      "serve_when_empty": null,
      "on_drain": {
        "if_var": "0x055e",
        "eq": 1,
        "then": {
          "set": {
            "0x055e": 0,
            "0x04a7": 235,
            "0x04a6": 224,
            "0x04a9": 223
          }
        },
        "else": {
          "set": {
            "0x5aeb": 7
          }
        }
      },
      "on_drain_ops": [
        {
          "if": [
            "0x055e",
            1,
            1
          ],
          "then": [
            [
              "0x055e",
              1,
              0
            ],
            [
              "0x04a7",
              1,
              235
            ],
            [
              "0x04a6",
              1,
              224
            ],
            [
              "0x04a9",
              1,
              223
            ]
          ],
          "else": [
            [
              "0x5aeb",
              1,
              7
            ],
            {
              "if": [
                "0x0624",
                1,
                1
              ],
              "then": [
                [
                  "0x0624",
                  1,
                  0
                ],
                [
                  "0x5ae1",
                  2,
                  0
                ],
                [
                  "0x5ae3",
                  2,
                  0
                ],
                [
                  "0x5ae9",
                  2,
                  0
                ]
              ]
            }
          ]
        }
      ]
    },
    "nudge": {
      "allowed_if": "any_active_slots [0, 1, 2]",
      "lane_test": false
    },
    "integration": {
      "max_x": 304,
      "max_x_compare": "unsigned, before the signed min_x test (a negative x becomes max_x)"
    },
    "wall": {
      "level0_lo_var": "0x04a7",
      "level0_lo_initial": 235
    },
    "occlusion": {
      "level0_bounds_vars": {
        "front_max": "0x04a6",
        "occludes_max": "0x04a9"
      },
      "level0_bounds_initial": {
        "front_max": 224,
        "occludes_max": 223
      },
      "level0_sensor_max": 240
    },
    "kicker": {
      "kick_override": {
        "var": "0x5d07",
        "eq": 2,
        "kick": 2
      }
    },
    "main_loop_ball_effects": [
      {
        "id": "magnet",
        "ip": "0x05d4",
        "stop": "0x0643",
        "enable_var": "0x0454",
        "enable_eq": 1,
        "ball": 0,
        "centre_vars": [
          "0x0456",
          "0x0458"
        ],
        "strength_var": "0x0460",
        "range": 60,
        "min_d2": 20,
        "formula": "dx = cx - x, dy = cy - y (s16); only if -60 < dx < 60 and -60 < dy < 60 and dx*dx+dy*dy != 0 (16-bit imul products); d2 = max(dx*dx+dy*dy, 20) (unsigned compare); vx -= (dx*s) idiv d2; vy -= (dy*s) idiv d2 (32-bit dividend, 16-bit quotient)"
      },
      {
        "id": "magnet2_dead",
        "ip": "0x0643",
        "stop": "0x06b2",
        "enable_var": "0x0455",
        "note": "same with += and centre ([045A],[045C]); [0455] is 0 at boot and never written"
      },
      {
        "id": "transport",
        "ip": "0x06b2",
        "stop": "0x0843",
        "note": "rule-driven state machine ([04A4] timer set by sensor handler h28c4, [04A3] mode, [04AA] target) that places ball 0, sets its velocity, the lockout [5F3E] and the wall/scan thresholds [04A7]/[04A6]/[04A9]; lifted as rules.json hook main_06b2"
      },
      {
        "id": "toy_shapes",
        "ip": "0x1095",
        "stop": "0x10a9",
        "draw_ip": "0x429e",
        "note": "per lamp slot i = 1.. until [5CC3+i] == 0xFF: al = 2 - [5CC3+i]; cs:429E: rec = ds:0780 + 8*(i-1); if (al & 1) != [rec+8]: [rec+8] = al & 1; draw shape [0962 + 2*min([rec+6],5)] (u16 count, offsets) at segment of row [rec+4] (+[rec+2]) in colour [rec+9] (0 if the bit is 0) into the collision buffer"
      }
    ]
  },
  "evidence": {
    "plunger.launch_block": "cs:0B62 cmp byte [5F44],0; jne exit; cs:0B69..0B7C active[0..2]==1 -> exit; cs:0B7E serve_delay [5AEB]: dec, ==1 -> cs:0B97..0BA9 (ball_lost_fade), exit; cs:0BAF/0BD2 up/down keys scroll [5ADE] and exit; cs:0BF3..0C08 [7285] or cs:[027F] or cs:[027C] -> cs:0C0A mov word [5AEC],2BCh; cs:0C13 [5AEC]==0 -> exit; cs:0C1A..0C65 [5ADE]=0, [00C1]=0, message, [009E]=6, [5AEC]=0, vx0=FF6Dh, vy0=FDA8h, display calls (58C2 VRAM clear, 3904 panel text), active0=1, x0=94h, y0=18Ch, [037F]=96h. Harness: plunger_launch, long_600_scripted, hand/launch_then_hold_active (all diverge at record 0: the port ignores ball.active=0 and has no launch block).",
    "plunger.lane_present": "no lane guard exists; the EP1-fallback lane (x>=280, y>=220) makes the port zero vx and charge the plunger there: hand/no_lane_region (original vx 60 kept, port 0 at record 0) and hand/no_lane_region_plunger (port charge 12).",
    "drain": "cs:0A2D mov di,6 .. cs:0A94 (slots 2,1,0 only; physics_step runs 5 slots); per drained slot cs:0A49 active=0, then [055E]==1 ? reset [055E]/[04A7]/[04A6]/[04A9] : [5AEB]=7 (+ rule vars when [0624]==1); cs:0A96 cmp cx,3; jne +0 (no serve). Harness: hand/drain_no_serve (original slot 0 stays inactive; the port re-serves at the EP1 fallback (284,336) at frame 3).",
    "nudge": "cs:0E23..0E7D: (cs:[027D] | cs:[027E] | cs:[027C]) && [5ACD] != 1 && (active0|active1|active2) && [5ACB] == 0 -> [5ACC] += 23h, [5ACB] = 0Ah, camera [6CF2] -= 10 (min 10); no lane test (engine.json nudge.lane_* are EP1 fallbacks). Not run by any scenario: the harness has no nudge inputs.",
    "integration.max_x": "cs:17A8 cmp word [di+6D00],130h; jbe 17B6; mov word [di+6D00],130h; cs:17B6 cmp word [di+6D00],1; jge; mov ...,1. Harness: hand/right_edge_clamp (original x 304, port 305 at record 2) and hand/left_edge_wrap (x 2 -> 304 in the original, 1 in the port, record 1).",
    "wall.level0_lo_var": "wall test cs:185D mov al,[04A7] (already in tools/emu/tables/EP8.json wall_test.lo_var); writers: cs:0A5B/0739/07A9/0810/3280 (EB), cs:06E8/0712/20D7/2169/2BF8 (FF). With FF only the flipper value FF collides at level 0. The port's wall LUT is static (EB).",
    "occlusion.level0_bounds_vars": "ball scan cs:16AF mov bl,[04A6]; cs:16B3 mov bh,[04A9] (level 1: AFh/BBh at cs:16BE): v <= bl -> ball in front; bl < v <= bh -> the pixel occludes the ball; v > bh and v <= F0h (cs:16D6) -> sensor. Boot/EB state: bl=E0h, bh=DFh (nothing occludes, E1..F0 are sensors). The FF state written with [04A7]=FF: bl=01h, bh=FFh, so every pixel above 01 occludes the ball and no sensor can fire (the ball travels 'under' the playfield). The port's occlusion LUT is static.",
    "kicker.kick_override": "kicker_hit cs:19C0 tilt -> ret; cs:19CA kick = params.kicker ([5F57]); cs:19D0 cooldown [5F3C]=2; cs:19D8 cmp word [5D07],2; jne 1B04; cs:19E5 kick [5F3F]=2 (drop-target mode; [5D07] is 1 at boot and set to 2 by a rule handler at cs:2323). Rule-state gated, so physics mode never sees it.",
    "main_loop_ball_effects": "cs:05D4..0843 and cs:1095..10A9 disassembled in scratch/tables/EP8/mainloop_0459_09e8.asm; cs:429E at 0x429E..0x4316. Added to EP8's harness rules mode (tools/emu/tables/EP8.json override): multi_bounce_upper rules-vs-full mode on the original was different from frame 45 (teleport) before and is identical after. [0454] is set to 1 by kicker_hit cs:1AE4 (third completed target bank, only when [5D07]==2) and by the sensor handler at cs:2659, to 2 (magnet off) at cs:2D13, to 0 at cs:2AE9 and in ball_lost_fade cs:3276.",
    "drain.on_drain_ops": "cs:0A4F..0A8A per drained slot: if byte [055E]==1: [055E]=0, [04A7]=EBh, [04A6]=E0h, [04A9]=DFh; else [5AEB]=7 and, if byte [0624]==1: [0624]=0, words [5AE1]=[5AE3]=[5AE9]=0 (disassembly checked by the integrator)",
    "plunger.launch_block.release_ds_ops": "cs:0C1A..0C65: word [5ADE]=0, word [00C1]=0, dmd_message(bx=583h, ax=1, di=1400h) cs:0C30, word [009E]=6, [5AEC]=0, vx0=FF6Dh, vy0=FDA8h, far 353A:58C2 + cs:3904 (display), active0=1, x0=94h, y0=18Ch, byte [037F]=96h. serve delay reaching 1 (cs:0B97..0BA3) clears words [5AE1]/[5AE3]/[5AE9] before ball_lost_fade.",
    "occlusion.level0_bounds_initial": "boot/EB state of [04A6]=E0h and [04A9]=DFh (drain cs:0A60/0A65 restore them); cs:16D6 cmp al,0F0h: sensor only up to F0h.",
    "wall.level0_dynamic": "cs:185D mov al,[04A7]; cs:1876 cmp es:[bx],al; jb skip: indices below [04A7] are empty at level 0, the rest keep their class (EB..EF active, F0..FE wall, FF flipper)."
  }
}
"""#,
        9: #"""
{
 "format": "epic-pinball-engine-overrides/1",
 "table": 9,
 "exe": "EP9.EXE",
 "note": "Additive patch for extracted/tables/EP9/engine.json: deep-merge 'patch' into the exporter's output (new keys only; nothing here renames or removes a key). export_engine_data.py does not read this directory yet. Only code addresses (cs:/ds: offsets in EP9's own segments), small engine constants and flags; nothing is copied from the game (pixel lists are referenced by their DS offset and read from the user's EXE). Every value is cited in 'evidence' and was run on the original code with the harness (scenarios in tools/emu/scenarios/EP9/hand/, generator scratch/tables/common/extra_scenarios.py).",
 "patch": {
  "gates": [
   {
    "id": "lane_exit_one_way",
    "kind": "ball_position",
    "when": "every_frame, main-loop order: right after the extra-gravity decay (EP9 cs:0550), before the per-frame counters",
    "flag_var": "0x04fd",
    "open_if": {
     "ball": 0,
     "x_ge": 280,
     "every_frame": true
    },
    "close_if": {
     "flag_ne": 1,
     "ball": 0,
     "x_le": 215
    },
    "pixels": {
     "list": "0x04fe",
     "list_format": "u16 count, then count u16 offsets",
     "half": 0
    },
    "value_closed": 250,
    "value_open": 192,
    "draw_ip": "0x4091",
    "also_drawn_by": "ball_lost_fade cs:2F4E (flag=0) / cs:2F53"
   },
   {
    "id": "lane_diverter_timer",
    "kind": "rule_timer",
    "timer_var": "0x3f1e",
    "timer_set_by": "sensor handler cs:241A (120 frames)",
    "on_expiry": "cs:059D..05BF: [3EED+i]=0, [3EAC+i]=2, [3EAE+i]=2 for i=0,1; [3ED0]=1; [3EE8]=1; draw",
    "state_var": "0x3ee8",
    "pixels": [
     {
      "list": "0x051c",
      "half": 1,
      "value_if_state_1": 250,
      "value_if_state_0": 1
     },
     {
      "list": "0x053e",
      "half": 1,
      "value_if_state_1": 1,
      "value_if_state_0": 250
     }
    ],
    "draw_ip": "0x40b0",
    "state_0_by": "ball_lost_fade cs:2D44 (then cs:2D49 draw)"
   }
  ],
  "gravity": {
   "slots": 3
  },
  "sensors": {
   "lockout_per_ball": {
    "array": "0x4183",
    "stride": 2,
    "slots": 3,
    "current_var": "0x418e"
   }
  },
  "plunger": {
   "lane_layer_test": true
  },
  "drain": {
   "slots": 5,
   "serve_when_empty": 5,
   "clear_layer_on_drain": false,
   "transfer": null
  }
 },
 "evidence": {
  "gates[0]": "cs:0550 cmp word [ball_x0 ds:4EFA],118h; jb 0560; cs:0558 mov byte [04FD],0; call 4091 (every frame while x >= 280); cs:0560 cmp byte [04FD],1; je 0577; cmp word [4EFA],0D7h; ja 0577; mov byte [04FD],1; call 4091. cs:4091: ES=[50F4] (pf_seg_top), dl = FAh if [04FD]==1 else C0h; si=04FE: lodsw count, per pixel lodsw offset, mov es:[di],dl. The 14 pixels are the diagonal (246,31)..(233,44), A8h at boot. No rule state involved. Harness: tools/emu/tables/EP9.json override (physics range cs:0545..0577); hand/gate_one_way_hit (original contact k=43 at frame 1 step 1 on the gate, port none) and the generated multi_bounce_upper (record 34).",
  "gates[1]": "cs:058B..05C2 (timer), cs:40B0..40E1 (draw: ES=[50F6] pf_seg_bottom; dl=FAh, dh=01h if [3EE8]==1 else swapped; list 051C (16 px, (269,337)..(284,352)) gets dl, list 053E (30 px, x=286, y 322..351) gets dh). Rule-driven; added to the harness rules mode only.",
  "gravity.slots": "gravity + scan loop cs:131A mov di,0 .. cs:13BA cmp di,6 (slots 0..2; EP1/EP6/EP7/EP8 loop to di=10, 5 slots). Not visible in slot-0 traces (ball-ball pairs are 0-1, 0-2, 1-2 only).",
  "gravity.terms (already exported)": "cs:132F mov ax,[41B5] (params.gravity); add ax,[41BB]; sub ax,[41B9]; add [di+vy],ax. [41B9] = 2 by a sensor handler (cs:2826), 0 at ball end (cs:2D4C). Harness: hand/extra_gravity_fall ([41BB]=30 poked; the port matches).",
  "sensors.lockout_per_ball": "cs:1346 mov cl,[di+4183]; mov [418E],cl (before the scan), cs:1386 mov al,[418E]; mov [di+4183],al (after); per-frame decrements cs:0B0D..0B39 of [4183], [4181] (kicker cooldown), [4185], [4187]. The port has one eventLockout; equivalent for a single ball, differs with 2+ balls in rules mode (not exercised: EP9's rules.json does not load in the port).",
  "kicker.cooldown_set_when_tilted (already exported)": "kicker_hit cs:1B32 mov byte [4181],4; cs:1B37 mov byte [00C2],0; cs:1B3C tilted -> ret. Harness: hand/tilted_bumper_hit (the port matches: no physics effect while tilted)."
 }
}
"""#,
        10: #"""
{
 "format": "epic-pinball-engine-overrides/1",
 "table": 10,
 "exe": "EP10.EXE",
 "generated_by": "table-verification agent (EP10-13), 2026-09-27; hand-maintained",
 "status": "tools/export_engine_data.py does not read tools/engine_overrides/ yet. Keys under 'set' are dotted engine.json paths the exporter should write (additively). No game data is stored here: tables are referenced by data-segment offset and word count and must be read from the user's EXE; the rest are code facts (small integers, addresses). cs/ds offsets are unrelocated, entry code segment / data segment as in tools/emu/tables/EPn.json.",
 "set": {
  "flipper_kick.gate_note": "if not null: a flipper contact with (u16) ball y < side_min_y does NOT take the side/tip kick: it takes the normal one-pixel push-out (x -= pushout[k].x, y += pushout[k].y, no y -= 1) on every iteration, and on the first response it still continues to the flipper top-kick branch (it is not a plain wall reflection). EP10 has no top_min_y: the top kick (EP1 maths) follows for any y (cs:1B5B..1B65).",
  "sensors.lockout_per_ball": {
   "array": "0x3880",
   "stride": 2,
   "slots": 3,
   "scratch": "0x388b",
   "copy_in": "cs:1174",
   "copy_out": "cs:11b7",
   "decrement": "cs:0933 (lockout[0], kicker_cooldown, lockout[1], lockout[2])",
   "note": "the gravity/scan loop (3 slots) copies the ball's own lockout byte into the scratch lockout the handlers read/write before that ball's pixel scan and back after it; the per-frame counters decrement the 3 array bytes, not the scratch copy. There is no event_cooldown in this table."
  },
  "gravity.slots": 3
 },
 "evidence": {
  "flipper gate": "cs:1ad8 cmp byte [flipper_contact],0; je 1b3e | cs:1adf cmp word [di+y],0x12c; jb 1b3e (push-out cs:1b3e..1b4d)",
  "top kick without y test": "cs:1b5b cmp byte [flipper_contact],0; jne 1b65 -> cs:1b65 (vy zero test 0x28, fx/fy x p3/p4)",
  "per-ball lockout": "cs:1174 mov cl,[di+3880]; mov [388b],cl ... cs:11b7 mov [di+3880],al",
  "gravity loop": "cs:11e8 cmp di,6 (slots 0..2); the port loops 5 slots (unobservable while slots 3/4 are never active)",
  "kicker_hit": "cs:195e: cooldown=4 before the tilt test (cooldown_set_when_tilted); y>=200 branch scores only, no kick override"
 }
}
"""#,
        11: #"""
{
 "format": "epic-pinball-engine-overrides/1",
 "table": 11,
 "exe": "EP11.EXE",
 "generated_by": "table-verification agent (EP10-13), 2026-09-27; hand-maintained",
 "status": "tools/export_engine_data.py does not read tools/engine_overrides/ yet. Keys under 'set' are dotted engine.json paths the exporter should write (additively). No game data is stored here: tables are referenced by data-segment offset and word count and must be read from the user's EXE; the rest are code facts (small integers, addresses). cs/ds offsets are unrelocated, entry code segment / data segment as in tools/emu/tables/EPn.json.",
 "set": {
  "flipper_kick.gate_note": "if not null: a flipper contact with (u16) ball y < side_min_y does NOT take the side/tip kick: it takes the normal one-pixel push-out (x -= pushout[k].x, y += pushout[k].y, no y -= 1) on every iteration, and on the first response it still continues to the flipper top-kick branch (it is not a plain wall reflection). First response with (u16) y < top_min_y: the upper kick (flipper_kick.upper_kick) instead of the top kick.",
  "flipper_kick.upper_kick": {
   "vx_table": {
    "ds": "0x3788",
    "words": 10,
    "signed": true
   },
   "vy_table": {
    "ds": "0x379e",
    "words": 10,
    "signed": true
   },
   "angle_group": 1,
   "dx": -1,
   "dy": 1,
   "vy_positive_to_zero": true,
   "code": "cs:1ba5..1bd0",
   "reachable": false,
   "note": "same code as EP12 cs:1A91; unreachable here (only the two lower flippers, whose contacts have y >= 334)"
  },
  "sensors.lockout_per_ball": {
   "array": "0x374b",
   "stride": 2,
   "slots": 3,
   "scratch": "0x3756",
   "copy_in": "cs:11e2",
   "copy_out": "cs:1225",
   "decrement": "cs:0981 (lockout[0], kicker_cooldown, lockout[1], lockout[2])",
   "note": "the gravity/scan loop (3 slots) copies the ball's own lockout byte into the scratch lockout the handlers read/write before that ball's pixel scan and back after it; the per-frame counters decrement the 3 array bytes, not the scratch copy. There is no event_cooldown in this table."
  },
  "gravity.slots": 3,
  "kicker.kick_override": {
   "min_y": 360,
   "kick": 3,
   "code": "cs:1a30 cmp word [di+y],0x168; jae 1a28 -> mov byte [kick],3",
   "reachable": false,
   "note": "kicker_hit replaces params.kicker by 3 when ball y >= 360; no kicker-active pixel (D0..D2) lies at y >= 339 in this table, so never reached"
  }
 },
 "evidence": {
  "flipper gates": "cs:1ad7 (side gate 0x12c -> push-out cs:1b3d), cs:1b64 cmp word [di+y],0x136; jb 1ba5 (upper kick)",
  "per-ball lockout": "cs:11e2 / cs:1225",
  "gravity loop": "cs:1256 cmp di,6"
 }
}
"""#,
        12: #"""
{
 "format": "epic-pinball-engine-overrides/1",
 "table": 12,
 "exe": "EP12.EXE",
 "generated_by": "table-verification agent (EP10-13), 2026-09-27; hand-maintained",
 "status": "tools/export_engine_data.py does not read tools/engine_overrides/ yet. Keys under 'set' are dotted engine.json paths the exporter should write (additively). No game data is stored here: tables are referenced by data-segment offset and word count and must be read from the user's EXE; the rest are code facts (small integers, addresses). cs/ds offsets are unrelocated, entry code segment / data segment as in tools/emu/tables/EPn.json.",
 "set": {
  "flipper_kick.gate_note": "if not null: a flipper contact with (u16) ball y < side_min_y does NOT take the side/tip kick: it takes the normal one-pixel push-out (x -= pushout[k].x, y += pushout[k].y, no y -= 1) on every iteration, and on the first response it still continues to the flipper top-kick branch (it is not a plain wall reflection). First response with (u16) y < top_min_y: the upper kick (flipper_kick.upper_kick) instead of the top kick.",
  "flipper_kick.upper_kick": {
   "vx_table": {
    "ds": "0x374b",
    "words": 10,
    "signed": true
   },
   "vy_table": {
    "ds": "0x3761",
    "words": 10,
    "signed": true
   },
   "angle_group": 1,
   "dx": -1,
   "dy": 1,
   "vy_positive_to_zero": true,
   "code": "cs:1a91..1abc",
   "reachable": true,
   "note": "first response only, flipper_contact != 0, (u16) y < top_min_y (after the push-out): if vy > 0 then vy = 0; y += 1; x -= 1; vx -= vx_table[a]; vy -= vy_table[a], a = angle of flipper group angle_group (the right group ds:4F67, whatever flipper_contact is); raw table values, not multiplied by params. Every contact with the upper-right flipper (outline y 123..152) takes this path. cs:1ae4..1b15 is an unreachable left-hand variant (no references)."
  },
  "sensors.lockout_per_ball": {
   "array": "0x370e",
   "stride": 2,
   "slots": 3,
   "scratch": "0x3719",
   "copy_in": "cs:10cb",
   "copy_out": "cs:110b",
   "decrement": "cs:0871..089d (lockout[0], kicker_cooldown, lockout[1], lockout[2])",
   "note": "the gravity/scan loop (3 slots) copies the ball's own lockout byte into the scratch lockout the handlers read/write before that ball's pixel scan and back after it; the per-frame counters decrement the 3 array bytes, not the scratch copy. There is no event_cooldown in this table."
  },
  "gravity.slots": 3,
  "kicker.kick_override": {
   "min_y": 360,
   "kick": 3,
   "code": "cs:191c cmp word [di+y],0x168; jae 1914 -> mov byte [kick],3",
   "reachable": false,
   "note": "no kicker-active pixel (D0..D2) lies at y >= 337 in this table, so never reached"
  }
 },
 "evidence": {
  "side gate": "cs:19c3 cmp byte [370b],0; je 1a29 | cs:19ca cmp word [di+4ce9],0x12c; jb 1a29 (push-out cs:1a29..1a38)",
  "first-response + top gate": "cs:1a3c cmp byte [4eec],0; jne exit | cs:1a46 flipper_contact test | cs:1a50 cmp word [di+4ce9],0x136; jb 1a91",
  "upper kick": "cs:1a91..1abc (verified on 17 original executions: scratch/tables/EP12/check_upper_kick.py)",
  "per-ball lockout": "cs:10cb mov cl,[di+370e]; mov [3719],cl ... cs:110b mov al,[3719]; mov [di+370e],al",
  "gravity loop": "cs:113f cmp di,6"
 }
}
"""#,
        13: #"""
{
 "format": "epic-pinball-engine-overrides/1",
 "table": 13,
 "exe": "EP13.EXE",
 "generated_by": "table-verification agent (EP10-13), 2026-09-27; hand-maintained",
 "status": "tools/export_engine_data.py does not read tools/engine_overrides/ yet. Keys under 'set' are dotted engine.json paths the exporter should write (additively). No game data is stored here: tables are referenced by data-segment offset and word count and must be read from the user's EXE; the rest are code facts (small integers, addresses). cs/ds offsets are unrelocated, entry code segment / data segment as in tools/emu/tables/EPn.json.",
 "set": {
  "flipper_kick.gate_note": "if not null: a flipper contact with (u16) ball y < side_min_y does NOT take the side/tip kick: it takes the normal one-pixel push-out (x -= pushout[k].x, y += pushout[k].y, no y -= 1) on every iteration, and on the first response it still continues to the flipper top-kick branch (it is not a plain wall reflection). First response with (u16) y < top_min_y: the upper kick (flipper_kick.upper_kick) instead of the top kick.",
  "flipper_kick.upper_kick": {
   "vx_table": {
    "ds": "0x3784",
    "words": 10,
    "signed": true
   },
   "vy_table": {
    "ds": "0x379a",
    "words": 10,
    "signed": true
   },
   "angle_group": 1,
   "dx": -1,
   "dy": 1,
   "vy_positive_to_zero": true,
   "code": "cs:1a3d..1a68",
   "reachable": false,
   "note": "same code as EP12 cs:1A91; unreachable here (lower flipper contacts have y >= 339)"
  },
  "sensors.lockout_per_ball": {
   "array": "0x3747",
   "stride": 2,
   "slots": 3,
   "scratch": "0x3752",
   "copy_in": "cs:106c",
   "copy_out": "cs:10af",
   "decrement": "cs:0843 (lockout[0], kicker_cooldown, lockout[1], lockout[2])",
   "note": "the gravity/scan loop (3 slots) copies the ball's own lockout byte into the scratch lockout the handlers read/write before that ball's pixel scan and back after it; the per-frame counters decrement the 3 array bytes, not the scratch copy. There is no event_cooldown in this table."
  },
  "gravity.slots": 3,
  "kicker.kick_override": {
   "min_y": 360,
   "kick": 3,
   "code": "cs:18c8 cmp word [di+y],0x168; jae 18c0 -> mov byte [kick],3",
   "reachable": false,
   "note": "no kicker-active pixel (D0..D2) lies at y >= 345 in this table, so never reached"
  }
 },
 "evidence": {
  "flipper gates": "cs:196f (side gate -> push-out cs:19d5), cs:19fc cmp word [di+y],0x136; jb 1a3d (upper kick)",
  "per-ball lockout": "cs:106c / cs:10af",
  "gravity loop": "cs:10e0 cmp di,6"
 }
}
"""#,
    ]
}
