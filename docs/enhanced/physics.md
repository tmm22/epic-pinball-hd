# Enhanced physics

`GameSettings.physicsMode = .enhanced` replaces the classic integer ball physics with a smooth,
sub-stepped floating-point model. Everything else stays the original game: the same tables and
collision art (the live collision buffer, including gates and rule-drawn pixels), the same
rules, timers, lamps, sounds and main-loop order at 59.94 Hz, and the same sensor dispatch from the
pixels under the ball. Classic mode is untouched: with no model installed the engine runs exactly
as before (`run_suite.py --modes physics,rules`: 830/830 after the hook changes).

Code: `app/Sources/PinballCore/Enhanced/` (`BallPhysics.swift`, `EnhancedPhysics.swift`,
`EnhancedConfig.swift`, `DistanceField.swift`, `FlipperModel.swift`, `EnhancedValidation.swift`).
Tests: `app/Tests/PinballCoreTests/EnhancedPhysicsTests.swift` (synthetic data) and
`EnhancedTableTests.swift` (your own tables; skipped without them).

## 1. The hook

```swift
public protocol BallPhysics: AnyObject {
    func step(_ engine: ClassicEngine)                                          // replaces physicsStep()
    func frameGravity(_ engine: ClassicEngine, ball i: Int, amount: Int16) -> Bool  // main-loop gravity
}
```

* `ClassicEngine.ballPhysics == nil` (default): `runFrame` calls `physicsStep()` and
  `gravityAndScan` adds gravity exactly as before. `ClassicBallPhysics` is the same thing as an
  explicit model. The only other engine changes are bookkeeping that does not affect the classic
  path: `bufferWriteLog` (non-flipper collision-buffer writes, recorded only when non-nil),
  `bufferGeneration`, `sensorDispatchCount` / `sensorHits`, `finishExternalStep(_:)` and an
  internal `setHitList(_:)`.
* With a model installed, `runFrame` calls `model.step(engine)` for each of the 3 physics steps.
  The main-loop work between steps (drain/serve, plunger, nudge/tilt, rules, lamps, sensor scan)
  is unchanged and reads/writes `engine.balls` in the original's integer encoding.
* Gravity: `gravityAndScan` computes the same `g = params[9] + extra + terms (+ slot bonus)` (16-bit
  wrapping adds are associative, so this is the same value the classic path adds) and offers it to
  the model only under the same `vy <= cutoff` test. The enhanced model spreads it over the frame's
  substeps instead of adding it at once.
* `GameSimulation(engine:mode:options:physics:enhancedConfig:)` and `GameSimulation.physicsMode` /
  `.enhancedConfig` install or remove the model (`EnhancedPhysics.install(on:config:)` /
  `.uninstall(from:)`). `SimulationMode` stays the *presentation* switch (interpolated drawing);
  it never changes the physics.

## 2. The model

**Time.** Every classic step (1/179.82 s) runs `substeps` fixed substeps: 8 in the classic-feel
preset (1438.6 Hz), 10 in the modern preset (1798.2 Hz). Units are pixels and classic steps, so a
velocity of 1.0 is 128 of the original's units.

**Ball shape.** Box centre (7.5, 7.0) and a direction-dependent contact radius taken from the table's
own 48-point probe ring: for an outward wall normal `n`, the distance from the centre at which the
first probe centre enters a straight wall's pixels (ring support function minus half a pixel):
6.0 px up/down, 6.5 px left/right, up to 6.8 px on diagonals. A single isotropic radius (first
version, 6.75 px) made the ball too big for 14-px channels the original passes (EP10/11/13 plunger
exits), so the shape matters. For contacts the outline is 48 points on this curve.

**Collision world.** Built at install time from the live buffer and the wall LUTs, per level (0
table, 1 ramp):
* two masks: walls (`wall`, plus flipper-coloured pixels that are not part of any flipper outline)
  and kickers (`active`, honouring `active_max`); outline pixels of all ten angles of every flipper
  are excluded (flippers are modelled separately); outside the 320-px width and above row 0 is wall,
  below row 400 is open (drain);
* per mask an exact signed Euclidean distance transform (Felzenszwalb-Huttenlocher, capped at 24 px),
  sampled at pixel centres: distance to the nearest solid pixel centre minus 0.5 outside, minus the
  distance to the nearest empty pixel inside;
* a smoothed copy (binomial 5-tap, sigma about 1 px) with central-difference gradients, used only for
  normals. Smoothing sags a distance field by about 0.8 px along medial axes (the centre line of a
  channel) and lifts the inside of 1-px walls above 0, so depths always come from the exact field.
* Updates: rule code and gates write the buffer through `setBufferByte` / `drawGate`, which append
  to `bufferWriteLog`; at the start of every step the model reclassifies those pixels and
  recomputes the fields in a window around them (a box grown by the cap). A power-on reset
  (`bufferGeneration`) or a change of the level-0 classes (EP8's DS-driven bounds, `dynState`) is
  diffed against the current masks. Flipper outline redraws are not watched (flippers are shapes).

**Flippers** (`FlipperShape`). From the ten outline pixel lists in engine.json: consecutive identical
outlines form one pose (EP4/EP12's upper flippers have 4); each pose gets its own small distance
field on a world-aligned grid, so at every whole angle index the surface is exactly the outline the
original draws. EP9-13 draw the whole flipper boundary as a closed loop: its inside is filled
(flood fill from the grid border), otherwise a ball squeezed through the 1-px loop could sit inside
the flipper (found by the fuzz on EP11/EP12). EP1-8 outlines are open (top edge and tip) and stay as
they are. A rigid-rotation fit (principal axis per pose, least-squares pivot from the pose
centroids) gives a pivot and an angle per pose: EP1 left flipper pivot (88.0, 373.2), 34.4 deg of
travel, mean chamfer error of the fit 0.58 px (0.5-1.0 px on every lower flipper). Within a step the
flipper moves continuously from the angle index before `flipperUpdate` to the one after it: the
field is the blend of the two neighbouring indices' poses, each rotated about the pivot to the
interpolated angle. The original's discrete angles, outlines, sprites, sounds and `moving` flags are
all still produced by `ClassicEngine.flipperUpdate`, once per step.

**Motion (swept).** Per substep: gravity share; contact resolution; then conservative advancement:
the clearance is the exact distance to the nearest obstacle (walls, kickers if enabled, each
collidable flipper) minus the largest contact radius. The ball moves the whole remaining substep if
that is less than `clearance / sqrt(2)` (bilinear fields are at most sqrt(2)-Lipschitz), otherwise
that far and loops; in contact it responds and then moves at most 0.3 px beyond the clearance before
resolving again, so no outline point gets more than 0.3 px into a wall (half the thinnest wall)
between contact passes. Every loop is bounded (24 advancement iterations, 4 resolve passes); a
substep that runs out drops the rest of its motion and counts `sweepExhausted` (0 in every run
below).

**Contacts.** For each obstacle near the ball: the outline points inside it (exact field < 0.02 px
slop), grouped into runs of neighbouring points whose normals (smoothed gradient 1 px inside the
ball) agree within 50 deg; one contact per run with the deepest depth and depth-weighted normal. A
ball touching both sides of a channel gets two opposing contacts. A centre-based contact (smoothed
gradient at the centre, exact distance) catches single isolated wall pixels that fall between two
outline points. A ball that starts more than 2 px deep (a level switch over a post, a gate drawn onto
it, a teleport) is moved to the nearest free position within 16 px (rings of 32 directions, 0.5 px
apart), which is what the original's push-out loop does one pixel at a time (`deepContacts`,
`escapes`).

**Responses** (only for approaching contacts; approach slower than `restingSpeed` = 0.06 px/step
ends in resting contact):
* walls, `classicMap` (classic feel): the original's reflection (cs:1C0A..1CF5) is linear in `v`,
  `dv = -(v.n)(20 nx/(divX |n|^2), 64*20/(ny E divY))` with `E = 16 nx^2/ny^2 + 64`, or `0x7FF8`
  when `ny*ny == 1` (the quirk that gives vertical walls a larger y impulse). For each whole degree
  of wall normal the model precomputes which contact directions the original's own ring and
  `contact_direction` produce for a straight wall 0-2 px into the ring, and averages the 2x2 maps
  of those directions (with the table's divisors per level). The smooth wall normal selects and
  interpolates that map. So the classic's angle-dependent restitution and its elliptical normal
  table carry over, without its pixel-position noise. The result is never left approaching.
* walls, `restitution` (modern): normal restitution 0.42 and Coulomb friction 0.08, with optional
  spin (rolling contact takes 2/7 of the slip correction in velocity, the rest in spin).
* kickers: while the kicker is not cooling (and once per step), the model writes the integer ball
  state and calls the original's kicker path (`rules.kicker(ball:contact:)` with the nearest kicker
  pixel's colour, else `kickerHit`), i.e. the same scoring, sounds and cooldown, then applies
  `kick * n` with the classic table normal for that wall angle (classic feel; modern: along the
  smooth normal, 0.85 scale, rubber restitution 0.3). Cooling kickers are walls. EP2's position
  window is honoured, with hysteresis: kicker pixels that switch on while the ball overlaps them stay
  intangible for that ball until it is clear (otherwise it would start 6 px deep).
* flippers: impulse against the surface velocity `omega x (p - pivot)` at the contact point, where
  `omega` is the flipper's rotation over the step times `flipperGain`; restitution relative to the
  surface `flipperRestitution`. The EP4 upper-flipper rule-timer write (cs:1CE8) is done when a
  moving upper flipper hits the ball.
* the nudge impulse (cs:1D06) applies on a wall contact once per step with the same timer,
  direction and key tests; the hard-hit glue (cs:18C5, `bigHit`) runs on wall impacts with the probe
  hits of the ball 1 px into the wall.
* ball-ball: equal discs of radius 7 on the same level, pairs (0,1), (0,2), (1,2) like the original.

**Ball search** (`ballSearchSeconds` 3, `ballSearchKick` 2.5 px/step, both presets; 0 = off): a ball
that has been still for 3 s outside the plunger lane, not touching a flipper (a cradled ball is left
alone), not moved by rule code in that time (holds, kick-out holes) and not tilted is kicked along
the most open upward direction (32 rays, 2 px steps, up to 80 px). Real machines do this for stuck
balls. The original has nooks where its ball rattles indefinitely (a flipper's pivot notch against
the outlane wall on EP2/EP7); the smooth ball comes to a true rest there instead.

**Speed limits.** Classic feel moves at most the table's `step_cap` px per step per axis (like the
original; velocity itself is kept) with a 10 px/step safety cap on the velocity; modern caps the
velocity magnitude at 7 px/step. The original's edge clamps (x < min_x, y < min_y after an upward
move, EP8's max_x) remain as a last resort (`edgeClamps`, 0 in the runs below). No collisions while
the box top is at or below `collision_y_limit` (384), as in the original.

**Sync with the integer state.** After every step the model writes `x, y` (floor of the box's
top-left), `accx, accy` (the fraction in 1/128 px) and `vx, vy` (rounded to 1/128 px/step). At the
start of every step, and after every rule hook it calls, it compares `engine.balls` with what it
last wrote: a changed position is a teleport (serve, sensor write-back, launch), a changed velocity
is applied as a delta (plunger release, rule kicks; an exact 0 stays 0, e.g. the plunger lane's
`vx = 0`), `active` 0/1 starts or stops the body, `layer` is taken as is. So drain/serve, the plunger,
the rules interpreter and the sensor scan work unchanged. Non-finite states are replaced by the last
good one (`nanResets`, 0 in every run).

**Presets** (`EnhancedPhysicsConfig.classicFeel` / `.modern`, `EnhancedPhysicsConfig.preset(_:)`):

| | classic feel | modern |
|---|---|---|
| substeps | 8 (1438.6 Hz) | 10 (1798.2 Hz) |
| walls | classic map per wall angle | e 0.42, friction 0.08, spin |
| flippers | gain 1.30, e 0.25 (fitted, 3) | gain 1.35, e 0.45, friction 0.10 |
| kickers | classic `kick * n_table` | 0.85 x along smooth normal, rubber e 0.3 |
| ball-ball | e 0.45 | e 0.85 |
| speed | per-axis classic step caps | magnitude 7 px/step, drag 0.0004/step |
| gravity | the main loop's, x1 | x1 |

## 3. Validation

All numbers from the release-mode harness over the user's own tables (headless, no rules unless
stated). Reproduce with the tests (`EnhancedTableTests`, sizes from environment variables, see the
file header) or `scratch/enhanced/harness` (not in git).

### (a) Fuzz: 10,000 random launches per table and preset

Ball at a random free spot of level 0 (clearance > 1 px), random direction, speed 0 to 8 px/step
(above the classic caps), random flipper presses, 120 frames or until it drains, the exported
sensor handlers on (level switches happen). After every step: non-finite state, and penetration
into the live buffer's solid pixels measured independently of the distance fields (exact distance
from the centre to each solid pixel square, including the flipper outline as drawn, against the
contact radius in that direction). "Tunnel" = more than 2 px inside.

FUZZ_TABLE

### (b) Classic feel vs the classic engine

**Gravity** is the main loop's own value (`frameGravity`): after 10 frames of free fall both give
exactly `vy = 10 g` (test `testFrameGravityMatchesClassicRate`). **Maximum speed**: both move at most
the table's step caps per axis (EP1 5/5 px/step = 899 px/s; EP2-6 4/4; EP4, EP8-13 x 4 / y 5).

**Bounces** (EP1 normals and divisors; straight walls every 7.5 deg, incidences 0, +-20, +-40, +-60
deg, speeds 0.8-4.5 px/step, 1663 paired shots, no gravity): the normal restitution per wall angle
follows the original's strong angle dependence (the classic ball bounces 4x livelier off diagonal
walls than off axis walls):

| wall normal (deg) | 0 | 15 | 30 | 45 | 60 | 75 | 90 | 105 | 120 | 135 | 150 | 165 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| classic e_n | 0.169 | 0.330 | 0.565 | 0.643 | 0.459 | 0.245 | 0.171 | 0.281 | 0.538 | 0.537 | 0.418 | 0.243 |
| classic feel | 0.175 | 0.319 | 0.533 | 0.645 | 0.443 | 0.272 | 0.176 | 0.312 | 0.528 | 0.615 | 0.366 | 0.200 |

| wall normal (deg) | 180 | 195 | 210 | 225 | 240 | 255 | 270 | 285 | 300 | 315 | 330 | 345 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| classic e_n | 0.169 | 0.266 | 0.472 | 0.684 | 0.494 | 0.253 | 0.171 | 0.279 | 0.562 | 0.549 | 0.514 | 0.316 |
| classic feel | 0.176 | 0.234 | 0.418 | 0.698 | 0.444 | 0.277 | 0.176 | 0.299 | 0.504 | 0.615 | 0.531 | 0.272 |

Mean e_n difference +0.004 (mean absolute 0.084). Outgoing direction per paired shot: median 3.7
deg, mean 11.6 deg, 90th percentile 26.2 deg. Outgoing speed ratio (feel/classic) 1.069 on average:
0.94 head-on, 1.13-1.19 at 60 deg incidence, where the original re-contacts a grazing wall several
times in its push-out loop and loses more tangential speed. A fitted tangential loss term
(`wallTangentialLoss`, `wallGrazingLoss`) made the per-shot error worse (the classic's
position-dependent quantisation dominates), so both are 0. The modern preset (e 0.42 everywhere):
e_n 0.417 at every angle, median direction difference 15.4 deg.

**Flipper shots** (EP1 left flipper, real table, gravity on, rules off; ball 4-34 px right of the
pivot, dropped 4/20/40 px at 0/1/2 px/step, flipper pressed 0-8 frames later, velocity read 12
frames after the press; 165 shots): classic mean 2.71 px/step (sd 1.03), vy -2.63; classic feel
2.75, vy -2.46; per-shot mean |log speed ratio| 0.31, median direction difference 12.9 deg. Fit
(grid over gain 1.0-2.2 x restitution 0-0.45): gain 1.30 / e 0.25 matches the mean speed; per-shot
agreement is limited by the original's quantised kick tables. Shot speed rises with distance from
the pivot in both (4 px: 1.39 vs 1.38; 20 px: 3.40 vs 3.13; 30 px: 3.53 vs 4.34). Modern: 3.26
px/step.

**Kickers** (every group of kicker pixels, 8 directions, 1.5 and 3 px/step, speed 20 frames later):

KICKER_TABLE

### (c) Full games with the rules

`EnhancedValidation.autoplay`: the same `AutoPlayer` as `AutoPlay.run` (plunge, flip at falling
balls), six games per table and mode with plunge strengths of 30-60 frames, 30,000-frame cap, plus
what a player does with a ball that has come to rest outside the lane: after 2 s still, flip both
flippers (and nudge after three tries). "rescues" counts those.

GAMES_TABLE

Notes:
* A ball can come to rest in a few nooks the original also has: the notch between a flipper's pivot
  end and the outlane wall (EP2, EP7), and a pocket at box (58..60, 106..108) on EP12 that traps the
  ball in the classic engine as well (it rattles there indefinitely with sensor BC firing; a nudge
  lifts it only briefly in both). The enhanced ball comes to a true rest there, the classic ball
  jitters.
* EP12 scores above 2e9 appear in classic and enhanced games alike: the level-1 jackpot handler
  h27d9 (sensor C3) adds 2,258,532,704. That is a rules-side issue (reported), not physics.
* Classic itself does not always reach game over within 30,000 frames with this player (EP9, EP10).

### (d) Unit tests

`EnhancedPhysicsTests` (synthetic data, 14 tests): exact EDT vs brute force; one-pixel and
stair-step fields (normal jitter < 1.5 deg on a 1:2 pixel staircase at contact distance); local
field updates equal a full recompute; `ClassicBallPhysics` identical to no model; a ball comes to
rest on a floor at the contact radius; gravity rate; external writes (delta velocity, teleport,
exact zero, deactivation); no tunnelling through a 1-px wall at 40 px/step with one substep;
rule/gate buffer writes update the world; determinism; the float reflection map equals the integer
maths including the `0x7FF8` case; classic direction table; `GameSimulation.physicsMode`.
`EnhancedTableTests` (your tables): flipper fits, fuzz, classic-feel bounce and flipper comparisons,
autoplay games.

## 4. Performance

Release build, Apple silicon: about 2.6 us per ball substep in open play (21 us per classic step,
0.06 ms per frame); more while the ball is in contact with several obstacles (EP3's captive ball
area: up to about 1.7 ms per frame). Building the world for a table takes a few milliseconds in
release (about 1 s in a debug build).

## 5. Limits and open points

* The classic feel is a statistical match, not a trace match: the original's response depends on
  the ball's exact pixel position (which probes hit), the enhanced one on the smooth wall angle.
* Flipper motion follows the original's schedule (one angle index per step); only the impulse uses
  `flipperGain`. Upper flippers with repeated outlines (EP4, EP12) move in the steps where their
  outline changes, like the original.
* Ball-ball uses discs, not the original's ring overlap and forced divisors.
* Spin (modern only) is a simple rolling-contact model; it is not visible in the art.
* The presentation layer still draws from the integer fields (1/128 px precision);
  `EnhancedPhysics.ballCentre(_:)`, `flipperAlpha(group:)` and `flipperPose(_:)` expose the smooth
  state for a renderer that wants it.
