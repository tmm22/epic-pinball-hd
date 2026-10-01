# Enhanced physics

`GameSettings.physicsMode = .enhanced` replaces the classic integer ball physics with a smooth,
sub-stepped floating-point model. Everything else stays the original game: the same tables and
collision art (the live collision buffer, including gates and rule-drawn pixels), the same
rules, timers, lamps, sounds and main-loop order at 59.94 Hz, and the same sensor dispatch from the
pixels under the ball. Classic mode is untouched: with no model installed the engine runs exactly
as before (`run_suite.py --modes physics,rules`: 830/830 after the hook changes).
The preset is `GameSettings.enhancedPreset` (`classicFeel`, the default, or `modern`; Settings > Game >
"Enhanced physics feel"), applied live through `GameSimulation.enhancedConfig`.

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
  the model only under the same `vy <= cutoff` test. The enhanced model adds it to the integer `vy`
  at once, exactly like the original, so the sensor scan and rule code that run right after it see
  the classic `vy`, and a rule that *sets* the velocity overrides this frame's gravity as it does in
  the original (a kick-out hole holds the ball with `v = 0` every frame). The body itself receives
  the same amount spread evenly over the frame's substeps; `syncIn` applies only what the main loop
  and the rules changed on top of it.
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
* flippers, `impulse` (modern): impulse against the surface velocity `omega x (p - pivot)` at the
  contact point, where `omega` is the flipper's rotation over the step times `flipperGain`;
  restitution relative to the surface `flipperRestitution`, Coulomb friction `flipperFriction`. The
  EP4 upper-flipper rule-timer write (cs:1CE8) is done when a moving upper flipper hits the ball.
* flippers, `classicKick` (classic feel): the original's moving-flipper branch of
  collision_response (cs:1AF3..1BB0) driven by the smooth contact. The contact normal is mapped to
  the contact direction the original's probe ring would report (the same table as for walls), which
  selects
  * the **top kick** (direction 33..41, the ball on top of the flipper; and every contact above
    `side_min_y` on EP4/EP8-13): `vy = 0` if `vy >= vy_zero_top`, `vx += -+fx[a] * p3`,
    `vy -= fy[a] * p4` with the contact side's flipper angle before this step's update; or the
    **upper-flipper kick** above `top_min_y` (EP4, EP12) with its `vx_sub / vy_sub` tables and rule
    timer;
  * the **side / tip kick** (other directions): `v += n[31 | 41] * (p5, p6)` per push-out iteration
    of the original, `vy` zeroed first when `vy >= vy_zero_side`; the original pushes the ball up
    1 px per iteration, so the number of iterations is taken as `ceil(approach / |n.y|)` (1..6)
    from the closing speed.

  Each kind of kick is given at most once per `flipperKickWindow` (0.75 classic steps, a rolling
  window; the original kicks once per step, on the first response). As in the original, a flipper
  counts as moving for the kick in a step in which it moves up *and* in the step after it reached the
  top (the original tests the `moving` flag the previous step's `flipper_update` left), a contact
  alone is enough (the original's outline jumps into the ball; no approach is needed), and the
  outline pushes the ball out by position only: velocity comes from the kicks alone (a velocity
  "carry" by the rising surface made shots up to 1.7 px/step too fast on EP11-13, whose top kick
  is only 0.75 px/step). A flipper that is not moving up is a wall with the classic reflection map
  (`flipper_contact = 0` in the original). The result is the original's shot: nearly vertical (the
  top kick changes `vx` by a few 1/128 px/step only), 1.9 px/step per top kick on EP1 (2.25 on EP10),
  with a second kick when the flipper catches the ball again.
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
move, EP8's max_x) remain as a last resort, applied only where the clamped position is free (`edgeClamps`). No collisions while
the box top is at or below `collision_y_limit` (384), as in the original.

**Sync with the integer state.** After every step the model writes `x, y` (floor of the box's
top-left), `accx, accy` (the fraction in 1/128 px) and `vx, vy` (rounded to 1/128 px/step). At the
start of every step, and after every rule hook it calls, it compares `engine.balls` with what it
last wrote: a changed position is a teleport (serve, sensor write-back, launch), a changed velocity
is applied as a delta (plunger release, rule kicks, ejects that set an absolute velocity) against
what the model wrote plus this frame's gravity; an exact 0 stays 0 and also cancels the rest of
this frame's gravity (the plunger lane's `vx = 0`, a kick-out hole holding the ball at `v = 0`:
before this, the held ball crept about 5 px out of EP10's holes during a 90-frame hold); `active`
0/1 starts or stops the body, `layer` is taken as is. So drain/serve, the plunger,
the rules interpreter and the sensor scan work unchanged. Non-finite states are replaced by the last
good one (`nanResets`, 0 in every run).

**Presets** (`EnhancedPhysicsConfig.classicFeel` / `.modern`, `EnhancedPhysicsConfig.preset(_:)`):

| | classic feel | modern |
|---|---|---|
| substeps | 8 (1438.6 Hz) | 10 (1798.2 Hz) |
| walls | classic map per wall angle | e 0.42, friction 0.08, spin |
| flippers | original kicks (`classicKick`), window 0.75 step | impulse: gain 1.35, e 0.45, friction 0.10 |
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

| table | preset | steps | NaN | tunnel > 2 px | max penetration (px) | sweep exhausted | deep contacts | drained | slowest launch (ms) |
|---|---|---|---|---|---|---|---|---|---|
| EP1 | classicFeel | 3,289,053 | 0 | 0 | 0.61 | 0 | 160 | 1697 | 261 |
| EP1 | modern | 3,327,969 | 0 | 0 | 0.46 | 0 | 122 | 1645 | 140 |
| EP2 | classicFeel | 3,188,766 | 0 | 0 | 0.51 | 0 | 84 | 2294 | 150 |
| EP2 | modern | 3,293,778 | 0 | 0 | 0.45 | 0 | 69 | 1920 | 140 |
| EP3 | classicFeel | 3,254,193 | 0 | 0 | 0.41 | 0 | 2268 | 2167 | 253 |
| EP3 | modern | 3,326,868 | 0 | 0 | 0.41 | 0 | 1719 | 1636 | 183 |
| EP4 | classicFeel | 3,225,600 | 0 | 0 | 0.53 | 0 | 139 | 2328 | 253 |
| EP4 | modern | 3,252,243 | 0 | 0 | 0.52 | 0 | 137 | 2173 | 253 |
| EP5 | classicFeel | 3,320,670 | 0 | 0 | 0.44 | 0 | 83 | 1566 | 150 |
| EP5 | modern | 3,344,139 | 0 | 0 | 0.39 | 0 | 79 | 1492 | 184 |
| EP6 | classicFeel | 3,318,018 | 0 | 0 | 0.48 | 0 | 89 | 1596 | 197 |
| EP6 | modern | 3,321,186 | 0 | 0 | 0.51 | 0 | 68 | 1711 | 457 |
| EP7 | classicFeel | 3,209,103 | 0 | 0 | 0.47 | 0 | 163 | 2312 | 145 |
| EP7 | modern | 3,260,463 | 0 | 0 | 0.44 | 0 | 193 | 2016 | 188 |
| EP8 | classicFeel | 3,307,938 | 0 | 0 | 0.44 | 0 | 71 | 1546 | 279 |
| EP8 | modern | 3,332,862 | 0 | 0 | 0.44 | 0 | 57 | 1453 | 313 |
| EP9 | classicFeel | 3,327,261 | 0 | 0 | 0.43 | 0 | 243 | 1546 | 147 |
| EP9 | modern | 3,347,919 | 0 | 0 | 0.45 | 0 | 256 | 1452 | 166 |
| EP10 | classicFeel | 3,191,226 | 0 | 0 | 0.40 | 0 | 156 | 2467 | 91 |
| EP10 | modern | 3,243,714 | 0 | 0 | 0.41 | 0 | 195 | 2259 | 138 |
| EP11 | classicFeel | 3,324,771 | 0 | 0 | 0.52 | 0 | 172 | 1708 | 142 |
| EP11 | modern | 3,319,671 | 0 | 0 | 0.43 | 0 | 163 | 1771 | 159 |
| EP12 | classicFeel | 3,316,581 | 0 | 0 | 0.40 | 0 | 1968 | 1717 | 103 |
| EP12 | modern | 3,326,208 | 0 | 0 | 0.41 | 0 | 1866 | 1629 | 133 |
| EP13 | classicFeel | 3,124,335 | 0 | 0 | 0.41 | 0 | 316 | 2849 | 74 |
| EP13 | modern | 3,221,949 | 0 | 0 | 0.40 | 0 | 346 | 2336 | 73 |

Every launch of every table and preset: no non-finite state, no tunnelling (largest penetration
0.61 px, the 0.3 px advancement allowance plus smoothing), no livelock (every sweep loop finished,
the slowest launch of 120 frames took 0.46 s). "Deep contacts" are starts more than 2 px inside
something, which a random launch point or a level switch produces (EP3's and EP12's level-1
walls); all were resolved. Before the last fix in this round, three runs had one to three
penetrations of 2.0-3.4 px: an extra centre-contact check (since removed, it made EP7/EP9 worse)
and the original's y edge clamp, which on EP8 put the ball into the top corners' walls. The clamps
now apply only where the clamped position is free.

### (b) Classic feel vs the classic engine

**Gravity** is the main loop's own value (`frameGravity`): after 10 frames of free fall both give
exactly `vy = 10 g` (test `testFrameGravityMatchesClassicRate`). **Maximum speed**: both move at most
the table's step caps per axis (EP1 5/5 px/step = 899 px/s; EP2-6 4/4; EP4, EP8-13 x 4 / y 5).

**Bounces** (EP1 normals and divisors; straight walls every 7.5 deg, incidences 0, +-20, +-40, +-60
deg, speeds 0.8-4.5 px/step, 1665 paired shots, no gravity): the normal restitution per wall angle
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
deg, mean 11.8 deg, 90th percentile 26.6 deg. Outgoing speed ratio (feel/classic) 1.069 on average:
0.94 head-on, 1.13-1.19 at 60 deg incidence, where the original re-contacts a grazing wall several
times in its push-out loop and loses more tangential speed. A fitted tangential loss term
(`wallTangentialLoss`, `wallGrazingLoss`) made the per-shot error worse (the classic's
position-dependent quantisation dominates), so both are 0. The modern preset (e 0.42 everywhere):
e_n 0.417 at every angle, median direction difference 15.4 deg.

**Flipper shots.** The original's flipper does not behave like a rigid bat: a ball on top of a
moving flipper gets `vy -= fy[a] * p4` once per step (1.9 px/step on EP1, 2.25 on EP10, 0.75 on
EP11-13) with `vx` changed by a few 1/128 px/step only, so its shots go nearly straight up and their
speed is quantised by the number of steps in contact (EP10: 2.25 or 4.5 px/step). A physical
impulse from the flipper's angular velocity (the first version of the classic feel preset, and the
modern preset) sends the ball off along the flipper normal instead, 11-16 deg away from the
original's direction, and misses the original's centre shots. The classic feel preset therefore
uses `classicKick` (section 2); the table below compares both.

*Shots from real play* (`EnhancedValidation.flipperShotSnapshots` / `replayShots`): nine classic
autoplay games per table (plunge 30-60 frames, 8,000 frames each); the ball 4 frames before every
shot (turning from falling to rising faster than 1 px/step below y 290, flippers at rest), replayed
from that state with the same inputs in both engines (rules off); the most upward velocity reached
in the next 16 frames. Mean |log speed ratio| per shot / median direction difference / mean upward
speed classic vs enhanced:

| table | shots | classic feel (`classicKick`) | classic feel with impulse flippers (gain 1.3, e 0.25) | modern |
|---|---|---|---|---|
| EP1 | 120 | 0.116 / 0.9 deg / 3.05 vs 2.98 | 0.444 / 16.0 deg / 3.05 vs 3.12 | 0.474 / 14.3 deg / 3.05 vs 3.88 |
| EP2 | 163 | 0.146 / 1.1 deg / 3.14 vs 3.00 | 0.428 / 10.9 deg / 3.14 vs 2.94 | 0.476 / 13.8 deg / 3.14 vs 3.34 |
| EP3 | 125 | 0.173 / 0.9 deg / 2.95 vs 2.87 | 0.509 / 14.8 deg / 2.95 vs 2.98 | 0.577 / 13.1 deg / 2.95 vs 3.72 |
| EP4 | 90 | 0.239 / 1.1 deg / 3.34 vs 3.20 | 0.514 / 11.7 deg / 3.34 vs 2.75 | 0.454 / 14.8 deg / 3.34 vs 3.02 |
| EP5 | 44 | 0.080 / 0.5 deg / 2.36 vs 2.37 | 0.381 / 10.4 deg / 2.36 vs 2.62 | 0.478 / 11.7 deg / 2.36 vs 3.23 |
| EP6 | 198 | 0.270 / 1.0 deg / 3.75 vs 3.46 | 0.396 / 13.6 deg / 3.75 vs 3.11 | 0.404 / 13.2 deg / 3.75 vs 3.84 |
| EP7 | 170 | 0.250 / 1.2 deg / 2.75 vs 2.52 | 0.675 / 12.8 deg / 2.75 vs 2.83 | 0.731 / 11.0 deg / 2.75 vs 3.48 |
| EP8 | 45 | 0.106 / 0.7 deg / 3.69 vs 3.57 | 0.215 / 14.2 deg / 3.69 vs 3.12 | 0.243 / 14.9 deg / 3.69 vs 4.26 |
| EP9 | 194 | 0.187 / 0.9 deg / 3.42 vs 3.29 | 0.515 / 13.9 deg / 3.42 vs 3.07 | 0.505 / 13.5 deg / 3.42 vs 3.76 |
| EP10 | 148 | 0.140 / 1.0 deg / 3.63 vs 3.54 | 0.288 / 11.0 deg / 3.63 vs 3.31 | 0.333 / 12.5 deg / 3.63 vs 3.70 |
| EP11 | 50 | 0.175 / 3.2 deg / 3.00 vs 3.44 | 0.534 / 18.7 deg / 3.00 vs 4.84 | 0.579 / 14.4 deg / 3.00 vs 4.98 |
| EP12 | 77 | 0.262 / 5.2 deg / 3.03 vs 3.51 | 0.556 / 12.7 deg / 3.03 vs 4.78 | 0.581 / 14.0 deg / 3.03 vs 4.90 |
| EP13 | 46 | 0.220 / 0.8 deg / 2.46 vs 2.66 | 0.967 / 21.7 deg / 2.46 vs 5.84 | 1.042 / 20.8 deg / 2.46 vs 6.27 |

With `classicKick` the direction matches to about a degree on EP1-10 (3-5 deg on EP11-13, whose
weak top kick leaves more shots to the side / tip kicks) and the per-shot speed error is 0.08-0.27
(0.21-0.97 for the impulse). The kick window (0.75 step) was chosen on this data: mean |log speed
ratio| over the 13 tables 0.206 at 0.5 step, 0.182 at 0.75, 0.210 at 1.0. Letting the rising
surface also carry the ball (set the relative normal velocity to zero) made EP11-13 up to 1.7
px/step too fast; the original moves the ball out by position only, and so does the model now.

*Drop shots* (`EnhancedValidation.flipperShot`, EP1 left flipper, gravity on, rules off; ball 4-34
px right of the pivot, dropped 4/20/40 px at 0/1/2 px/step, flipper pressed 0-8 frames later,
velocity 12 frames after the press; 165 shots): classic mean 2.71 px/step (vy -2.63), classic feel
2.66 (vy -2.57), mean |log speed ratio| 0.159, median direction difference 1.1 deg (the impulse
version: 0.31 and 12.9 deg). EP10: 2.80 vs 2.72, 0.189, 1.2 deg. Modern on EP1: 3.26 px/step,
median direction difference 10.8 deg.

**Kickers** (every group of kicker pixels, 8 directions, 1.5 and 3 px/step, speed 20 frames later):

| table | classic: kicked / shots, exit speed | classic feel | modern |
|---|---|---|---|
| EP1 | 132/144, 1.44 | 130/144, 1.28 | 130/144, 1.70 |
| EP2 | 109/148, 1.01 | 105/148, 1.14 | 106/148, 1.77 |
| EP3 | 63/70, 0.84 | 62/70, 0.85 | 62/70, 1.46 |
| EP4 | 14/14, 0.76 | 14/14, 0.75 | 14/14, 0.96 |
| EP5 | 132/154, 1.08 | 131/154, 1.03 | 129/154, 2.05 |
| EP6 | 119/138, 1.67 | 113/138, 1.68 | 112/138, 2.06 |
| EP7 | 50/52, 0.79 | 50/52, 0.87 | 50/52, 1.08 |
| EP9 | 45/50, 1.17 | 45/50, 1.01 | 44/50, 1.47 |
| EP10 | 110/116, 1.32 | 108/116, 1.43 | 108/116, 1.76 |
| EP11 | 32/34, 1.00 | 32/34, 0.93 | 32/34, 1.45 |
| EP12 | 57/104, 0.99 | 46/104, 0.96 | 50/104, 1.53 |
| EP13 | 25/34, 0.88 | 24/34, 0.75 | 27/34, 0.94 |

(EP8 has no kicker pixels.) Exit speeds in px/step.

### (c) Full games with the rules

`EnhancedValidation.autoplay`: the same `AutoPlayer` as `AutoPlay.run` (plunge, flip at falling
balls), six games per table and mode with plunge strengths of 30-60 frames, 30,000-frame cap, plus
what a player does with a ball that has come to rest outside the lane: after 2 s still, flip both
flippers (and nudge after three tries). "rescues" counts those.

| table | mode | game over | frames/game | sensors/frame | distinct sensors | median score | drains | rescues (flip/nudge) |
|---|---|---|---|---|---|---|---|---|
| EP1 | classic | 6/6 | 3128 | 4.10 | 31 | 5,685,000 | 18 | 0/0 |
| EP1 | classicFeel | 6/6 | 4206 | 3.14 | 31 | 5,615,000 | 18 | 0/0 |
| EP1 | modern | 6/6 | 7352 | 4.38 | 31 | 15,215,000 | 18 | 3/0 |
| EP2 | classic | 6/6 | 3927 | 28.81 | 37 | 6,200,000 | 18 | 2/0 |
| EP2 | classicFeel | 6/6 | 5953 | 15.32 | 34 | 8,215,000 | 18 | 23/0 |
| EP2 | modern | 6/6 | 2608 | 25.46 | 37 | 3,245,000 | 18 | 0/0 |
| EP3 | classic | 6/6 | 4002 | 3.32 | 24 | 45,700 | 18 | 0/0 |
| EP3 | classicFeel | 6/6 | 2343 | 6.97 | 25 | 206,000 | 18 | 0/0 |
| EP3 | modern | 6/6 | 2534 | 6.68 | 25 | 196,600 | 18 | 0/0 |
| EP4 | classic | 6/6 | 2109 | 0.77 | 16 | 560,000 | 18 | 0/0 |
| EP4 | classicFeel | 6/6 | 1976 | 1.78 | 14 | 1,500,000 | 18 | 0/0 |
| EP4 | modern | 6/6 | 1112 | 1.76 | 8 | 1,000,000 | 18 | 0/0 |
| EP5 | classic | 6/6 | 2532 | 0.61 | 25 | 4,450 | 18 | 0/0 |
| EP5 | classicFeel | 6/6 | 4548 | 0.63 | 23 | 3,550 | 18 | 0/0 |
| EP5 | modern | 6/6 | 2478 | 0.98 | 25 | 4,450 | 18 | 0/0 |
| EP6 | classic | 6/6 | 4953 | 2.20 | 41 | 7,650,000 | 18 | 0/0 |
| EP6 | classicFeel | 6/6 | 3317 | 2.99 | 41 | 1,955,000 | 18 | 0/0 |
| EP6 | modern | 6/6 | 2156 | 1.94 | 40 | 2,525,000 | 18 | 0/0 |
| EP7 | classic | 6/6 | 4986 | 5.04 | 43 | 5,503,000 | 18 | 0/0 |
| EP7 | classicFeel | 6/6 | 7359 | 9.61 | 44 | 21,945,000 | 18 | 3/0 |
| EP7 | modern | 6/6 | 4834 | 4.95 | 44 | 3,270,000 | 18 | 1/0 |
| EP8 | classic | 6/6 | 1560 | 0.00 | 5 | 960,000 | 18 | 0/0 |
| EP8 | classicFeel | 6/6 | 6730 | 0.01 | 11 | 4,360,000 | 18 | 0/0 |
| EP8 | modern | 6/6 | 2287 | 0.01 | 5 | 1,720,000 | 18 | 0/0 |
| EP9 | classic | 5/6 | 9350 | 0.63 | 32 | 333,800 | 15 | 0/0 |
| EP9 | classicFeel | 6/6 | 5427 | 1.24 | 33 | 394,000 | 18 | 2/0 |
| EP9 | modern | 6/6 | 5776 | 1.08 | 33 | 480,650 | 18 | 1/0 |
| EP10 | classic | 2/6 | 21197 | 4.49 | 20 | 12,510,000 | 7 | 0/0 |
| EP10 | classicFeel | 4/6 | 12241 | 0.59 | 20 | 7,870,000 | 13 | 0/0 |
| EP10 | modern | 5/6 | 6670 | 0.34 | 20 | 7,240,000 | 16 | 0/0 |
| EP11 | classic | 6/6 | 2785 | 0.89 | 13 | 1,450,000 | 18 | 3/1 |
| EP11 | classicFeel | 6/6 | 3022 | 1.20 | 16 | 2,175,000 | 18 | 0/0 |
| EP11 | modern | 6/6 | 3612 | 0.93 | 16 | 2,155,000 | 18 | 0/0 |
| EP12 | classic | 6/6 | 3635 | 0.99 | 18 | 2,259,717,704 | 18 | 3/1 |
| EP12 | classicFeel | 6/6 | 4799 | 1.13 | 21 | 2,700,000 | 18 | 0/0 |
| EP12 | modern | 3/6 | 17111 | 1.00 | 24 | 2,190,000 | 10 | 363/0 |
| EP13 | classic | 6/6 | 1303 | 0.27 | 8 | 2,130,000 | 18 | 0/0 |
| EP13 | classicFeel | 6/6 | 1581 | 1.66 | 20 | 1,175,000 | 18 | 0/0 |
| EP13 | modern | 6/6 | 1166 | 0.89 | 21 | 2,805,000 | 18 | 0/0 |

Every table reaches game over in classic feel, in every one of the six games except EP10 (4/6;
classic itself 2/6), with the rules firing throughout (distinct sensors 11-44, as many as or more
than classic on 10 tables). The test `testAutoplayGamesEnhanced` (plunge 45, then 30 and 60 until
a game ends) passes on all 13 tables in both presets.

Sensor rates are a property of where the ball goes, and autoplay games are chaotic, so they are
only comparable in order of magnitude (0.5x-2x on most tables). Two effects dominate the
outliers:
* The classic engine's own aggregate is inflated by games it never finishes: on EP10 plunges of 30
  and 36 frames leave the classic ball bouncing in the plunger lane for all 30,000 frames (0 sensor
  dispatches), and plunges of 42 and 60 put it into a loop (flipper shot straight up into the
  kick-out hole at box (171, 79), eject, ramps, hole again) that fires about 9 sensors per frame
  for 28,000 frames. 4.49 per frame is the mean over those games; in the games that end, classic
  fires 0.8-5 per frame and classic feel 0.6-2.6.
* EP2 fires a sensor every frame the ball sits on certain lanes (27-29 per frame in classic);
  classic feel 15.

**What was wrong on EP10** (the failing check of the previous round, classic feel 0.076 sensor
dispatches per frame against 0.82): not the sensors, the ball never got into EP10's three kick-out
holes (six games of up to 8,000 frames: 0 holds in 26,700 frames, classic 45 in 39,200). Two causes, both fixed:
1. *Flipper shots.* EP10's holes and ramps sit at the top centre and are reached by the
   original's vertical 4.5 px/step double top kicks. The physical flipper impulse gave angled shots
   (11 deg off) and only 31% strong ones (classic 59%). `classicKick` (above) gives 1.0 deg and 56%.
2. *Holds.* A hole holds the ball by writing `v = 0` every frame after the main loop's gravity. The
   model kept that frame's gravity pending and spread it over the substeps, so a held ball crept
   down (1 px per 16 frames) and the rules saw `vy` without the gravity the original's scan sees.
   Gravity now goes into the integer `vy` at once like the original, an exact 0 written by the
   rules cancels it (section 2, sync), and the body gets the same amount spread over the substeps.
   Test `testRuleVelocityWritesAfterGravity`.

After both fixes: 18 holds in 29,400 frames on EP10, the plunge-45 game fires 2.41 sensors per
frame (classic 0.82) and the threshold of the test (0.2 x classic) was not changed.

Other notes:
* A ball can come to rest in a few nooks the original also has: the notch between a flipper's pivot
  end and the outlane wall (EP2, EP7), and a pocket at box (58..60, 106..108) on EP12. The EP12
  pocket is closed by a gate the rules draw across the lane below sensor BC (pixels about
  (70..78, 118..120)) once the ball has passed BC; the ball is then enclosed (lane wall above, gate
  below) and the classic ball is trapped there as well (it rattles indefinitely with BC firing). The
  modern preset gets into that lane more often (363 rescues, 3/6 games over), classic feel 0/6.
  This is table/rules behaviour (reported), not something the physics should work around.
* EP12 scores above 2e9 appear in classic and enhanced games alike: the level-1 jackpot handler
  h27d9 (sensor C3) adds 2,258,632,704. Checked by the integrator against the original code: at
  cs:2883 the handler does `mov cx,[0x34ad]` then `add score,100000` / `loop`; with `[0x34ad] = 0`
  the x86 `loop` runs 65,536 times, and 65,536 x 100,000 mod 2^32 = 2,258,632,704. It is the
  original's own bug, reproduced exactly (both rules backends), not a port or physics issue.
* Classic itself does not always reach game over within 30,000 frames with this player (EP9, EP10).

### (d) Unit tests

`EnhancedPhysicsTests` (synthetic data, 17 tests): exact EDT vs brute force; one-pixel and
stair-step fields (normal jitter < 1.5 deg on a 1:2 pixel staircase at contact distance); local
field updates equal a full recompute; `ClassicBallPhysics` identical to no model; a ball comes to
rest on a floor at the contact radius; gravity rate; external writes (delta velocity, teleport,
exact zero, deactivation); rule velocity writes after the frame's gravity (a held ball does not
creep, the scan sees the classic `vy`, a plunger delta and an absolute eject survive); ball search;
closed flipper outlines filled; no tunnelling through a 1-px wall at 40 px/step with one substep;
rule/gate buffer writes update the world; determinism; the float reflection map equals the integer
maths including the `0x7FF8` case; classic direction table; `GameSimulation.physicsMode`.
`EnhancedTableTests` (your tables, 6 tests): flipper fits, fuzz, classic-feel bounces, drop shots
and shots from real play against the classic engine, autoplay games (EP1 and EP10 by default, all 13
with `EP_ENHANCED_GAMES=1`). Debug `swift test` runs all 23 in about 4.5 minutes.

## 4. Performance

Release build, Apple silicon: about 2.6 us per ball substep in open play (21 us per classic step,
0.06 ms per frame); more while the ball is in contact with several obstacles (EP3's captive ball
area: up to about 1.7 ms per frame). Building the world for a table takes a few milliseconds in
release (about 1 s in a debug build).

## 5. Limits and open points

* The classic feel is a statistical match, not a trace match: the original's response depends on
  the ball's exact pixel position (which probes hit), the enhanced one on the smooth wall angle.
* Flipper motion follows the original's schedule (one angle index per step); the flipper sweeps
  continuously within the step. In classic feel the velocity it gives comes from the original's
  kick tables (`classicKick`), with one tuned parameter (`flipperKickWindow`); the modern preset uses
  the physical impulse, which on EP11-13 gives much faster shots than the original (4.8-6.3 vs
  2.5-3.0 px/step), because those tables' original top kick is weak. Upper flippers with repeated outlines (EP4, EP12) move in the steps where their
  outline changes, like the original.
* Ball-ball uses discs, not the original's ring overlap and forced divisors.
* Spin (modern only) is a simple rolling-contact model; it is not visible in the art.
* The presentation draws the balls from `EnhancedPhysics.ballCentre(_:)` at full precision
  (`GameSimulation.ballPosition`, see rendering.md "High refresh"), and the flippers' angle index
  from `flipperAlpha(group:)`. Both are sampled at frame boundaries, where `flipperAlpha` is a whole
  index; the continuous motion on screen comes from interpolating between frames.
