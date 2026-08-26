## The arena: the fixed square geometry, the four side-local frames, the brick
## lattice, the swept box-contact tests, the bounded seeded serve sampler and
## the seeded seat->side permutation.
##
## The ctf map generator, the map pool, the wall mask and the procedural
## terrain are DELETED, not ported: this arena is one 100 x 100 box that never
## changes.
##
## NO FLOATING POINT IN THIS FILE (grep-enforced, tests/test_determinism.nim).
## Every product or quotient of two sim quantities is computed in `int64`.

import sim_types

const
  ArenaHalf* = ArenaSide div 2

type
  Frac* = object
    ## A contact time in [0, 1] as an exact rational, so two candidate
    ## contacts are ordered by integer cross-multiplication in `int64` — no
    ## division, no `isqrt`, no float.
    num*, den*: int64

  ContactKind* = enum
    ckNone
    ckPaddle
    ckFarPaddle
    ckBrick
    ckMouth
    ckWall

  Contact* = object
    kind*: ContactKind
    cabinet*: int32
    row*, col*: int32
    axisX*: bool           ## the crossed face is VERTICAL (x-component flips)
    t*: Frac
    x*, y*: int32          ## the contact point, µu

# ---------------------------------------------------------------------------
#  The seeded stream
# ---------------------------------------------------------------------------

proc initRngState*(seed: int): RngState =
  ## SplitMix64-seeded xorshift128+ state. The whole stream lives in the
  ## uint64 domain so a draw is identical on wasm32 and amd64 — the starter's
  ## documented `rand(int)` hazard, avoided by construction.
  var z = cast[uint64](int64(seed)) + 0x9E3779B97F4A7C15'u64
  proc mix(v: var uint64): uint64 =
    v += 0x9E3779B97F4A7C15'u64
    var x = v
    x = (x xor (x shr 30)) * 0xBF58476D1CE4E5B9'u64
    x = (x xor (x shr 27)) * 0x94D049BB133111EB'u64
    x xor (x shr 31)
  result.s0 = mix(z)
  result.s1 = mix(z)
  if result.s0 == 0 and result.s1 == 0:
    result.s0 = 0x9E3779B97F4A7C15'u64

proc next*(rng: var RngState): uint64 =
  ## One xorshift128+ step.
  var
    s1 = rng.s0
    s0 = rng.s1
  rng.s0 = s0
  s1 = s1 xor (s1 shl 23)
  rng.s1 = s1 xor s0 xor (s1 shr 17) xor (s0 shr 26)
  rng.s1 + s0

proc drawInt*(rng: var RngState, draws: var int32, lo, hi: int32): int32 =
  ## The ONE draw helper. `draws` is a monotonic counter mixed into
  ## `gameHash`, so a divergence in HOW MANY draws a build took is caught at
  ## the tick it happens rather than as a mysterious position mismatch later.
  inc draws
  if hi <= lo:
    return lo
  let span = uint64(int64(hi) - int64(lo) + 1)
  int32(int64(lo) + int64(rng.next() mod span))

proc drawPermutation*(rng: var RngState, draws: var int32):
    array[CabinetCount, int32] =
  ## The seat -> cabinet permutation, drawn once at t = 0 by Fisher-Yates over
  ## the one dedicated stream. Never visible to any seat.
  for i in 0 ..< CabinetCount:
    result[i] = int32(i)
  var i = CabinetCount - 1
  while i > 0:
    let j = int(drawInt(rng, draws, 0'i32, int32(i)))
    let tmp = result[i]
    result[i] = result[j]
    result[j] = tmp
    dec i

# ---------------------------------------------------------------------------
#  Side-local frames
# ---------------------------------------------------------------------------

proc localOf*(side: int, x, y: int32): tuple[along, depth: int32] =
  ## World µu (origin top-left, y DOWN) -> side `side`'s local frame.
  ## `depth` is the perpendicular distance from that side into the arena and
  ## `along` is signed, oriented so +along is COUNTER-CLOCKWISE around the box
  ## (your +along end touches the next cabinet counter-clockwise).
  case side and 3
  of 0: (x - ArenaHalf, ArenaSide - y)
  of 1: (ArenaSide - y - ArenaHalf, ArenaSide - x)
  of 2: (ArenaHalf - x, y)
  else: (y - ArenaHalf, x)

proc worldOf*(side: int, along, depth: int32): tuple[x, y: int32] =
  ## The inverse of `localOf`.
  case side and 3
  of 0: (along + ArenaHalf, ArenaSide - depth)
  of 1: (ArenaSide - depth, ArenaSide - (along + ArenaHalf))
  of 2: (ArenaHalf - along, depth)
  else: (depth, along + ArenaHalf)

proc sideIsHorizontal*(side: int): bool =
  ## Sides 0 (SOUTH) and 2 (NORTH) are horizontal surfaces; 1 and 3 vertical.
  (side and 1) == 0

proc goalHalfUu*(config: GameConfig): int32 =
  int32(config.goalHalfCu) * UuPerCu

proc paddleHalfUu*(config: GameConfig): int32 =
  int32(config.paddleHalfCu) * UuPerCu

proc farPaddleHalfUu*(config: GameConfig): int32 =
  int32(config.farPaddleHalfCu) * UuPerCu

proc ballSpeed0Uu*(config: GameConfig): int32 =
  ## Thousandths of a cu/tick -> µu/tick.
  int32((int64(config.ballSpeed0Milli) * int64(UuPerCu)) div 1000'i64)

proc ballSpeedStepUu*(config: GameConfig): int32 =
  int32((int64(config.ballSpeedStepMilli) * int64(UuPerCu)) div 1000'i64)

proc ballSpeedMaxUu*(config: GameConfig): int32 =
  int32((int64(config.ballSpeedMaxMilli) * int64(UuPerCu)) div 1000'i64)

# ---------------------------------------------------------------------------
#  The brick lattice
# ---------------------------------------------------------------------------

proc brickAlongCentre*(col: int): int32 =
  ## Column `col` (0..8) sits at along -16, -12, … +16 cu.
  int32(col - (BricksPerRow div 2)) * int32(BrickColumnStepCu) * UuPerCu

proc brickRowDepths*(row: int): tuple[lo, hi: int32] =
  ## Row 1 occupies depth 8.00..10.50 cu; row 2 (schema-only in v1) 4.00..6.50.
  if row == 0: (BrickRowDepthLo, BrickRowDepthHi)
  else: (BrickRow2DepthLo, BrickRow2DepthHi)

# ---------------------------------------------------------------------------
#  Exact rational time comparison
# ---------------------------------------------------------------------------

proc initFrac*(num, den: int64): Frac =
  if den < 0: Frac(num: -num, den: -den) else: Frac(num: num, den: den)

proc isBefore*(a, b: Frac): bool =
  ## a < b, by integer cross-multiplication (both denominators positive).
  a.num * b.den < b.num * a.den

proc atOrBefore*(a, b: Frac): bool =
  a.num * b.den <= b.num * a.den

proc fracValueUu*(a: Frac, delta: int32): int32 =
  ## delta * a, truncating toward zero (Nim's `div`), so the result is
  ## symmetric under negation.
  if a.den == 0:
    return 0
  int32((int64(delta) * a.num) div a.den)

# ---------------------------------------------------------------------------
#  Swept contact: point (the ball's centre) against a Minkowski-expanded box
# ---------------------------------------------------------------------------

type Slab = object
  hit: bool
  enter, exit: Frac

proc slabTimes(p, d, lo, hi: int32): Slab =
  ## Entry/exit times of a 1-D ray p + t*d against the interval [lo, hi].
  ## A zero delta either never leaves the slab (already inside) or never
  ## enters it.
  if d == 0:
    if p < lo or p > hi:
      return Slab(hit: false)
    return Slab(hit: true, enter: initFrac(0, 1), exit: initFrac(1, 1))
  let
    t0 = initFrac(int64(lo) - int64(p), int64(d))
    t1 = initFrac(int64(hi) - int64(p), int64(d))
  if isBefore(t0, t1):
    Slab(hit: true, enter: t0, exit: t1)
  else:
    Slab(hit: true, enter: t1, exit: t0)

proc sweptBox*(
  px, py, dx, dy: int32,
  x0, y0, x1, y1: int32
): tuple[hit: bool, t: Frac, axisX: bool] =
  ## The earliest time in [0, 1] at which a ball centred at (px, py) moving by
  ## (dx, dy) first OVERLAPS the axis-aligned box [x0,x1] x [y0,y1] expanded
  ## by `BallHalf` on every side (the ball is an axis-aligned square of
  ## half-side BallHalf). `axisX` names the crossed face: true = a vertical
  ## surface (the x-component flips), false = a horizontal one.
  result = (false, initFrac(0, 1), false)
  let
    ex0 = x0 - BallHalf
    ey0 = y0 - BallHalf
    ex1 = x1 + BallHalf
    ey1 = y1 + BallHalf
  # Already overlapping at t = 0 is not a NEW contact: the resolution order
  # advances the ball to its contact point and reflects, so a still-touching
  # ball on the following tick must not re-trigger. The caller's
  # one-contact-per-tick rule plus this guard is what makes that true.
  let
    sx = slabTimes(px, dx, ex0, ex1)
    sy = slabTimes(py, dy, ey0, ey1)
  if not sx.hit or not sy.hit:
    return
  let
    enter = if isBefore(sx.enter, sy.enter): sy.enter else: sx.enter
    exit = if isBefore(sx.exit, sy.exit): sx.exit else: sy.exit
    zero = initFrac(0, 1)
    one = initFrac(1, 1)
  if isBefore(exit, enter):
    return
  if isBefore(one, enter) or isBefore(exit, zero):
    return
  let clamped = if isBefore(enter, zero): zero else: enter
  result = (true, clamped, not isBefore(sx.enter, sy.enter))

proc sideDepthCrossing*(
  side: int, px, py, dx, dy, targetDepth: int32
): tuple[hit: bool, t: Frac] =
  ## The time at which the ball's CENTRE crosses side `side`'s depth line
  ## `targetDepth`, moving inward-to-outward. Depth is an affine function of
  ## one world coordinate, so this is a 1-D rational crossing.
  result = (false, initFrac(0, 1))
  let
    d0 = localOf(side, px, py).depth
    d1 = localOf(side, px + dx, py + dy).depth
  if d0 <= targetDepth:
    # Already at or past the line: the previous tick resolved it.
    return
  if d1 > targetDepth:
    return
  let span = int64(d0) - int64(d1)
  if span <= 0:
    return
  result = (true, initFrac(int64(d0) - int64(targetDepth), span))
