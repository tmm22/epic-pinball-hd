#!/usr/bin/env python3
"""Write the scenario sets: EP1's hand-made set (tools/emu/scenarios/*.json) and generated
per-table sets (tools/emu/scenarios/EPn/*.json).

EP1 set: start positions were chosen with the harness itself: every start box is clear of solid
colours (with a 3 px margin, except the lane/plunger start which is the game's own serve
position) and the first contact of each wall/bumper scenario was checked to be of the
advertised kind (see docs/formats/emulation.md, "Scenario set").

Per-table sets (tools/emu/scenegen.py): plunger, flipper, bumper/slingshot, wall and long
scripted runs placed from each table's own geometry and verified on the original code.

  .venv/bin/python tools/emu/make_scenarios.py              # EP1 hand-made set (as before)
  .venv/bin/python tools/emu/make_scenarios.py --table 4 12 # generated sets -> scenarios/EP4/, EP12/
  .venv/bin/python tools/emu/make_scenarios.py --all        # generated sets for EP2..EP13
  (--table 1 writes a generated EP1 set to scenarios/EP1/, a check of the generator;
   the hand-made EP1 files stay where they are)
"""
import argparse
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'scenarios')

L, R, P = 1, 2, 4


def seq(*parts, total):
    """seq((mask, nframes), ...) padded with 0 to `total` frames."""
    out = []
    for m, n in parts:
        out += [m] * n
    return (out + [0] * total)[:total]


def ball(x, y, vx=0, vy=0, xf=0, yf=0):
    return dict(x=x, y=y, xf=xf, yf=yf, vx=vx, vy=vy)


S = {}
S['plunger_launch'] = dict(
    description='Ball at the serve position (284,336); plunger held 62 frames (charge saturates at 708 '
                'after 59), released, ball goes up the lane and round the top arc.',
    frames=300, ball=ball(284, 336), inputs=seq((P, 62), total=300))
S['plunger_short'] = dict(
    description='Weak plunge: plunger held 20 frames (charge 240), ball falls back into the lane.',
    frames=240, ball=ball(284, 336), inputs=seq((0, 5), (P, 20), total=240))
S['fall_left_flipper_held'] = dict(
    description='Free fall from (100,300) onto the left flipper, left flipper held from frame 0.',
    frames=150, ball=ball(100, 300), inputs=seq((L, 150), total=150))
S['fall_left_flipper_released'] = dict(
    description='Free fall from (100,300) onto the resting left flipper, no input.',
    frames=150, ball=ball(100, 300), inputs=[])
S['fall_right_flipper_held'] = dict(
    description='Free fall from (190,300) onto the right flipper, right flipper held from frame 0.',
    frames=150, ball=ball(190, 300), inputs=seq((R, 150), total=150))
S['fall_right_flipper_released'] = dict(
    description='Free fall from (190,300) onto the resting right flipper, no input.',
    frames=150, ball=ball(190, 300), inputs=[])
S['left_flipper_shot'] = dict(
    description='Free fall from (110,300); left flipper pressed at frame 34 (the ball lands at frame 37 '
                'if nothing is pressed) and held 20 frames: moving-flipper top kick (k 32..40) on two steps.',
    frames=200, ball=ball(110, 300), inputs=seq((0, 34), (L, 20), total=200))
S['right_flipper_shot'] = dict(
    description='Free fall from (178,300); right flipper pressed at frame 36 and held 20 frames: '
                'moving-flipper top kick.',
    frames=200, ball=ball(178, 300), inputs=seq((0, 36), (R, 20), total=200))
S['left_flipper_side_kick'] = dict(
    description='Free fall from (132,300) near the left flipper tip; flipper pressed at frame 33: contact '
                'k=30 on the moving flipper, side-kick path (+56,-140 per push-out iteration).',
    frames=200, ball=ball(132, 300), inputs=seq((0, 33), (L, 20), total=200))
S['bumper_hit'] = dict(
    description='Ball at (190,86) moving right (vx=300) into the right-hand pop bumper (colours CF..D2, y<200): '
                'kicker response v += 8*n.',
    frames=200, ball=ball(190, 86, vx=300), inputs=[])
S['slingshot_left_hit'] = dict(
    description='Ball at (110,290) moving left/down into the left slingshot (kicker colours, y>=200).',
    frames=200, ball=ball(110, 290, vx=-250, vy=50), inputs=[])
S['slingshot_right_hit'] = dict(
    description='Ball at (180,290) moving right/down into the right slingshot.',
    frames=200, ball=ball(180, 290, vx=250, vy=50), inputs=[])
S['diagonal_wall_hit'] = dict(
    description='Ball at (166,164) moving up-right (250,-250); first contact k=7 (diagonal normal), no kicker.',
    frames=120, ball=ball(166, 164, vx=250, vy=-250), inputs=[])
S['flat_wall_hit'] = dict(
    description='Ball at (82,200) moving left (vx=-300) into a vertical wall; first contact k=25 (west).',
    frames=120, ball=ball(82, 200, vx=-300), inputs=[])
S['flat_ceiling_hit'] = dict(
    description='Ball at (70,188) moving straight up (vy=-350) into a horizontal wall; first contact k=13 (north).',
    frames=120, ball=ball(70, 188, vy=-350), inputs=[])
S['multi_bounce_upper'] = dict(
    description='Fast ball in the upper playfield, (150,130) with (250,-350): several wall/bumper contacts.',
    frames=300, ball=ball(150, 130, vx=250, vy=-350), inputs=[])


S['upper_layer_loop'] = dict(
    description='Ball on the upper level (layer 1, ramp/habitrail) at (158,110) inside the centre loop, '
                'moving up (vy=-450): only colours BC..C7 collide, divisors 17+3, no kickers.',
    frames=250, ball=dict(ball(158, 110, vy=-450), layer=1), inputs=[])


def long_inputs(total=600):
    m = [0] * total
    for f in range(0, 55):
        m[f] |= P                       # launch
    for start in range(120, total, 45):  # periodic flips, alternating sides, both every 4th time
        side = [L, R, L | R][(start // 45) % 3]
        for f in range(start, min(total, start + 12)):
            m[f] |= side
    for f in range(330, 385):            # plunge again (only acts if a new ball was served into the lane)
        m[f] |= P
    return m


S['long_600_scripted'] = dict(
    description='600 frames: plunger launch, then scripted flipper presses every 45 frames; on drain the '
                "game's own serve code puts a new ball in the lane (on_drain=continue) and a second plunge "
                'is scripted at frames 330..384.',
    frames=600, ball=ball(284, 336), inputs=long_inputs(), on_drain='continue')


# ---------------------------------------------------------------------------------------------
# Adversarial scenarios (differential testing, tools/emu/diff_traces.py).  Start states were found
# with the harness (scratch/diff/search.py, search_tip.py, explore.py, ramp.py): every one of them
# starts clear of solid colours and was checked to produce the advertised contact in the ORIGINAL
# code's trace (hit lists are ds:6C20 at the first response).
# ---------------------------------------------------------------------------------------------
A = {}
A['adv_thin_wall_fast_lane'] = dict(
    description='Ball in the upper plunger lane (284,150) with vx=2000 (capped at 5 px/step, backlog clamped): the '
                'first step already overlaps the 1-px outer lane wall at x=300 (hits [41,8], straddle on both arcs); '
                '4 push-out iterations, k=48 via the +24 rule.',
    frames=60, ball=ball(284, 150, vx=2000))
A['adv_thin_wall_fast_straddle'] = dict(
    description='(54,164) with (693,97), 5.4 px/step: first contact hits [41,40,39,4,3], i.e. a thin wall inside the '
                'box between the upper-right and lower-right arcs; span 38 > 24 gives k=46 (+24 rule), 4 responses.',
    frames=150, ball=ball(54, 164, vx=693, vy=97))
A['adv_thin_wall_fast_diag'] = dict(
    description='(185,254) with (1300,-1519): max-speed diagonal; first contact hits [41,40,3,2,1] (k=45), 3 responses.',
    frames=150, ball=ball(185, 254, vx=1300, vy=-1519))
A['adv_wrap_quirk_wide'] = dict(
    description='(157,320) with (468,520): first contact hits 48..31 and 1 (19 probes). min 1 / max 48 is the wrap '
                'case, which always yields k=48 although the hits centre near k=40 (collision.md s4 quirk).',
    frames=150, ball=ball(157, 320, vx=468, vy=520))
A['adv_wrap_quirk_low'] = dict(
    description='(93,140) with (132,-377): first contact hits [48,9..1]; wrap case gives k=48 although the hits '
                'centre near k=4.',
    frames=150, ball=ball(93, 140, vx=132, vy=-377))
A['adv_wrap_quirk_split'] = dict(
    description='(118,298) with (391,80): first contact hits [48,45,43,42,41,2,1] (gaps in the run), wrap case k=48.',
    frames=150, ball=ball(118, 298, vx=391, vy=80))
A['adv_near_wrap_low'] = dict(
    description='(175,207) with (105,-169): first contact hits [3,2,1] (contains 1 but not 48): no wrap, k=2.',
    frames=150, ball=ball(175, 207, vx=105, vy=-169))
A['adv_near_wrap_high'] = dict(
    description='(216,216) with (169,105): first contact hits [48,47,46] (contains 48 but not 1): no wrap, k=47.',
    frames=150, ball=ball(216, 216, vx=169, vy=105))
A['adv_rest_on_raised_left'] = dict(
    description='Ball dropped from (105,330) onto the left flipper held up from frame 0 (angle 0, not moving): it '
                'rolls to the pivot and sits cradled near (81..86,354) with tiny bounces (k 31..40) for 300 frames.',
    frames=300, ball=ball(105, 330), inputs=seq((L, 300), total=300))
A['adv_rest_on_raised_right'] = dict(
    description='Ball dropped from (190,330) onto the right flipper held up: cradled near (202..209,353), k 33..42.',
    frames=300, ball=ball(190, 330), inputs=seq((R, 300), total=300))
A['adv_cradle_release_repress_left'] = dict(
    description='Left cradle (as adv_rest_on_raised_left) for 200 frames, flipper released for 3 frames (it drops '
                'with the ball on it), then pressed again while the ball is still in contact.',
    frames=300, ball=ball(105, 330), inputs=seq((L, 200), (0, 3), (L, 57), total=300))
A['adv_cradle_flutter_right'] = dict(
    description='Right cradle for 150 frames, then the flipper is released/pressed every 2 frames (moving flag '
                'toggles while the ball rests on the outline).',
    frames=300, ball=ball(190, 330), inputs=seq((R, 150), *([(0, 2), (R, 2)] * 25), total=300))
A['adv_cradle_both_flippers'] = dict(
    description='Right cradle for 120 frames, released 2 frames, then both flippers pressed (mask 3) while the ball '
                'is on the right flipper.',
    frames=240, ball=ball(190, 330), inputs=seq((R, 120), (0, 2), (L | R, 50), total=240))
A['adv_press_during_roll_36'] = dict(
    description='Ball lands on the resting left flipper (k=32 at frame 29) and rolls toward the tip; left pressed '
                'at frame 36 while it is on the outline: moving-flipper side kick (k 30/31, flipper_contact 1).',
    frames=200, ball=ball(120, 330), inputs=seq((0, 36), (L, 15), total=200))
A['adv_press_during_roll_38'] = dict(
    description='As adv_press_during_roll_36, pressed at frame 38: 4 side-kick iterations in one step (k 28..30).',
    frames=200, ball=ball(120, 330), inputs=seq((0, 38), (L, 15), total=200))
A['adv_press_during_roll_39'] = dict(
    description='As adv_press_during_roll_36, pressed at frame 39, near the tip (k 31 then 27).',
    frames=200, ball=ball(120, 330), inputs=seq((0, 39), (L, 15), total=200))
A['adv_flipper_tip_kick_right'] = dict(
    description='(157,316) with (-8,-9), right flipper pressed at frame 36: at frame 37 step 1 the moving right '
                'flipper touches the ball on the wrap side (hits [48,3,2,1] -> k=48, flipper_contact 2): the tip-index '
                'path (k-1 > 40) adds the tip kick on each of the 9 iterations, v becomes (-638,-1152).',
    frames=150, ball=ball(157, 316, vx=-8, vy=-9), inputs=seq((0, 36), (R, 20), total=150))
A['adv_flipper_tip_kick_right_b'] = dict(
    description='(181,306) with (49,51), right flipper pressed at frame 45: tip contact k=48,47,46.',
    frames=150, ball=ball(181, 306, vx=49, vy=51), inputs=seq((0, 45), (R, 20), total=150))
A['adv_top_edge_clamp'] = dict(
    description='(200,12) moving up at vy=-1500: after an upward move y < 1, so y=3 and vy=0 (cs:1813).',
    frames=60, ball=ball(200, 12, vx=100, vy=-1500))
A['adv_left_edge_clamp'] = dict(
    description='(3,220) outside the left wall moving left at vx=-1000: x < 1 is set to 1 every step; the backlog '
                'saturates at -1360 after the move.  (Run longer, the ball falls onto wall art out there at frame 24 '
                'and the original livelocks in the push-out loop.)',
    frames=20, ball=ball(3, 220, vx=-1000))
A['adv_below_limit_reentry'] = dict(
    description='(145,390) below the collision limit (y >= 384: no wall test) moving up at vy=-700 between the '
                'resting flippers: collision resumes at y < 384 and the ball flies up the centre.',
    frames=120, ball=ball(145, 390, vy=-700))
A['adv_plunger_overcharge'] = dict(
    description='Plunger charge poked to 1990 (above the 700 cap, so holding adds nothing), one frame held, then '
                'released: vy=-1990, a 5 px/step run up the dotted 1-px lane walls and round the top at max speed.',
    frames=180, ball=ball(284, 336), inputs=[P], pokes=dict(plunger_charge=1990))
A['adv_ramp_entry_left'] = dict(
    description='Rules mode. (95,110) moving up-left into the left ramp entrance (sensor F0, handler cs:206F): '
                'layer 0 -> 1 at frame 4 (extra gravity 13), ride on the upper level, exit on F1 (cs:2082) at frame 73 '
                'where y >= 200 stops the ball (vx=vy=0).  Also passes F9 on layer 1 (a scoring-only handler).',
    frames=150, ball=ball(95, 110, vx=-60, vy=-450), mode='rules')
A['adv_ramp_entry_center'] = dict(
    description='Rules mode. (160,150) straight up into the centre ramp entrance: F0 at frame 3, upper level, F1 at '
                'frame 73.  Ends at frame 74, before the saucer sensor F6 (cs:2379, a table rule the port does not '
                'run) captures the ball at frame 75.',
    frames=74, ball=ball(160, 150, vy=-450), mode='rules')
A['adv_ramp_entry_right'] = dict(
    description='Rules mode. (250,170) with (150,-450) into the right ramp entrance: F0 at frame 4, F9 on layer 1, '
                'F1 at frame 46 (ball stopped).',
    frames=125, ball=ball(250, 170, vx=150, vy=-450), mode='rules')

# Scenarios on which the ORIGINAL code never returns from physics_step: the push-out loop
# (cs:1826..18FA) has no iteration cap and the ball oscillates between two positions forever, inside
# the timer ISR with interrupts off (cs:2FC6 cli; nothing in physics_step re-enables them), so the
# real game would freeze.  They live in scenarios_pathological/ so that tools which need a full
# trace skip them; diff_traces.py checks that the port matches up to that step and flags it.
H = {}
H['hang_left_outlane_bottom'] = dict(
    description='(107,241) with (-695,82): after 40 steps the ball reaches the bottom of the left outlane at '
                '(24..25,383) and the push-out loop alternates k=27 / k=48 (x 24 <-> 25) forever.',
    frames=40, ball=ball(107, 241, vx=-695, vy=82))
H['hang_fast_upward'] = dict(
    description='(192,156) with (-570,-1916): hangs in frame 4 step 1 on thin wall art.',
    frames=40, ball=ball(192, 156, vx=-570, vy=-1916))


def write_set(S, out, table=1):
    os.makedirs(out, exist_ok=True)
    for name, s in S.items():
        scn = dict(name=name, table=table, frames=s['frames'], ball=s['ball'], inputs=s.get('inputs', []),
                   description=s['description'])
        for k in ('on_drain', 'mode', 'pokes'):
            if k in s:
                scn[k] = s[k]
        inputs = scn.pop('inputs')
        text = json.dumps(scn, indent=1)
        text = text[:-2] + ',\n "inputs": ' + json.dumps(inputs, separators=(',', ':')) + '\n}\n'
        with open(os.path.join(out, name + '.json'), 'w') as f:
            f.write(text)


def write_generated(n):
    sys.path.insert(0, HERE)
    import scenegen
    G, t = scenegen.generate(n, log=lambda m: print(m, file=sys.stderr))
    out = os.path.join(OUT, f'EP{n}')
    for old in glob.glob(os.path.join(out, '*.json')):   # stale files of kinds no longer found
        os.remove(old)
    write_set(G, out, table=n)
    print(f'EP{n}: wrote {len(G)} scenarios to {os.path.relpath(out)}: {" ".join(G)}')
    return G


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--table', type=int, nargs='+', help='generate per-table sets (scenarios/EPn/)')
    ap.add_argument('--all', action='store_true', help='generate sets for EP2..EP13')
    a = ap.parse_args()
    if a.table or a.all:
        for n in (a.table or []) + (list(range(2, 14)) if a.all else []):
            write_generated(n)
        return
    write_set(S, OUT)
    write_set(A, OUT)
    write_set(H, os.path.join(HERE, 'scenarios_pathological'))
    print(f'wrote {len(S)} + {len(A)} adversarial scenarios to {OUT}, {len(H)} to scenarios_pathological/')


if __name__ == '__main__':
    main()
