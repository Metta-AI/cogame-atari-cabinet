## The autopilot: one deterministic function, shared by every policy.
##
## `paddleCommand(sim, cabinet, stance)` is evaluated once per tick per
## cabinet in INDEX order and returns the command byte the replay records.
## Both LLM stances and scripted-baseline stances are compiled by this same
## code, so the two policy kinds are strictly comparable and a baseline is
## legal by construction.
##
## It sits OUTSIDE the determinism boundary — the starter's rule: recorded
## BYTES, not re-run logic — so it may use floating point. The sim never sees
## anything but the byte.
##
## It has NO memory across ticks, no knowledge of any other seat's stance, and
## no access to anything the seat's own observation does not carry
## (tests/test_locality.nim).

import sim, stances

const
  PredictTicks* = 240
  PredictReflections* = 4
  AimReflections* = 2
  DeadbandUu* = 1_500'i32

type
  Arrival* = object
    reaches*: bool
    tick*: int
    along*: int32

  BallPrediction* = object
    perSide*: array[CabinetCount, Arrival]
    perSideFar*: array[CabinetCount, Arrival]
      ## The same walk against the FAR bar's own depth line
      ## (`FarPaddleDepth`, 20 cu in FRONT of the near line). foozpong's second
      ## row has to be told where the ball crosses ITS line: aiming it at the
      ## near line's arrival puts it 20 cu behind the ball on every
      ## non-perpendicular trajectory.
    firstSide*: int            ## whose line it reaches first, -1 for none
    firstTick*: int

proc predictBall*(sim: SimServer, index: int): BallPrediction =
  ## Straight-line propagation with exact wall reflections, bounded at
  ## `PredictReflections` reflections and `PredictTicks` ticks, DELIBERATELY
  ## ignoring bricks and every other paddle: a prediction that modelled other
  ## paddles would be modelling other policies.
  ##
  ## The same walk backs the observation's `arrive_*` triple, so a policy is
  ## never guessing at a quantity the engine already knows.
  result.firstSide = -1
  result.firstTick = PredictTicks + 1
  let ball = sim.balls[index]
  if ball.state != bsLive:
    return
  var
    x = ball.x
    y = ball.y
    dir = ball.dir
    reflections = 0
  let
    speed = ball.speed
    goalHalf = goalHalfUu(sim.config)
  for tick in 1 .. PredictTicks:
    let vector = dirVector(dir)
    let
      dx = int32((int64(speed) * int64(vector.x)) div int64(DirQ12One))
      dy = int32((int64(speed) * int64(vector.y)) div int64(DirQ12One))
      nx = x + dx
      ny = y + dy
    # Paddle-line crossings, before the wall bounce that may follow.
    for side in 0 ..< CabinetCount:
      if result.perSide[side].reaches:
        continue
      let
        before = localOf(side, x, y).depth
        after = localOf(side, nx, ny).depth
      if before > PaddleDepth and after <= PaddleDepth:
        result.perSide[side].reaches = true
        result.perSide[side].tick = tick
        result.perSide[side].along = localOf(side, nx, ny).along
        if tick < result.firstTick:
          result.firstTick = tick
          result.firstSide = side
    for side in 0 ..< CabinetCount:
      if result.perSideFar[side].reaches:
        continue
      let
        before = localOf(side, x, y).depth
        after = localOf(side, nx, ny).depth
      if before > FarPaddleDepth and after <= FarPaddleDepth:
        result.perSideFar[side].reaches = true
        result.perSideFar[side].tick = tick
        result.perSideFar[side].along = localOf(side, nx, ny).along
    x = nx
    y = ny
    # Wall reflections / mouth exits.
    var bounced = false
    for side in 0 ..< CabinetCount:
      let local = localOf(side, x, y)
      if local.depth >= BallHalf:
        continue
      let inGap = not sim.cabinets[side].isOut and
        local.along > -goalHalf and local.along < goalHalf
      if inGap:
        return                       ## it goes through the mouth: walk over
      let repaired = worldOf(side, local.along, BallHalf)
      x = repaired.x
      y = repaired.y
      dir =
        if sideIsHorizontal(side): reflectHorizontal(dir)
        else: reflectVertical(dir)
      bounced = true
    if bounced:
      inc reflections
      if reflections > PredictReflections:
        return

proc rayHitsMouth*(
  sim: SimServer, cabinet: int, startX, startY: int32, dir: uint8,
  target: int
): bool =
  ## Walks an outgoing ray with up to `AimReflections` wall reflections and
  ## reports whether it crosses `target`'s mouth segment.
  if target < 0 or target >= CabinetCount or sim.cabinets[target].isOut:
    return false
  var
    x = startX
    y = startY
    d = dir
    reflections = 0
  let
    speed = max(1'i32, ballSpeedMaxUu(sim.config) div 2)
    goalHalf = goalHalfUu(sim.config)
  for _ in 1 .. PredictTicks:
    let vector = dirVector(d)
    let
      dx = int32((int64(speed) * int64(vector.x)) div int64(DirQ12One))
      dy = int32((int64(speed) * int64(vector.y)) div int64(DirQ12One))
    x = x + dx
    y = y + dy
    for side in 0 ..< CabinetCount:
      let local = localOf(side, x, y)
      if local.depth >= BallHalf:
        continue
      let inGap = not sim.cabinets[side].isOut and
        local.along > -goalHalf and local.along < goalHalf
      if inGap:
        return side == target
      let repaired = worldOf(side, local.along, BallHalf)
      x = repaired.x
      y = repaired.y
      d =
        if sideIsHorizontal(side): reflectHorizontal(d)
        else: reflectVertical(d)
      inc reflections
      if reflections > AimReflections:
        return false

proc aimOffsetJ*(
  sim: SimServer, cabinet: int, arriveAlong: int32, target: int
): int =
  ## For each of the 13 outgoing indices j = -6 … +6, test whether the ray
  ## crosses `target`'s mouth; take the SMALLEST |j| that does (a shallower
  ## deflection is a smaller demand on the bar). If none does, take j = +/-6
  ## toward the target's side by the counter-clockwise index difference.
  if target < 0 or target >= CabinetCount:
    return 0
  let contact = worldOf(
    cabinet, arriveAlong, PaddleDepth + PaddleThickHalf + BallHalf)
  for magnitude in 0 .. 6:
    for sign in [1, -1]:
      let j = magnitude * sign
      if magnitude == 0 and sign < 0:
        continue
      let dir = fromLocalDir(16 - 2 * j, cabinet)
      if sim.rayHitsMouth(cabinet, contact.x, contact.y, dir, target):
        return j
  # Nothing lands: throw it hard toward the target's side. +along touches the
  # next cabinet counter-clockwise, so a +1 difference wants +6.
  let diff = ((target - cabinet) mod CabinetCount + CabinetCount) mod
    CabinetCount
  if diff == 1: 6 elif diff == 3: -6 else: 6

proc predictedContactNow(
  sim: SimServer, cabinet: int, prediction: BallPrediction
): bool =
  ## True when the chosen ball reaches my paddle line THIS tick, close enough
  ## to the bar to be grippable.
  if not prediction.perSide[cabinet].reaches:
    return false
  if prediction.perSide[cabinet].tick > 1:
    return false
  let
    reach = paddleHalfUu(sim.config) + BallHalf
    delta = prediction.perSide[cabinet].along - sim.cabinets[cabinet].alongCentre
  delta >= -reach and delta <= reach

proc driveLevel(
  target, current: int32, ticks: int
): int =
  ## `want = (c* - c) / max(1, min(leadTicks, arriveTick))`, then
  ## `near = 4 + clamp(round(want / PaddleStepSpeed), -4, +4)`, with the
  ## documented deadband.
  let delta = target - current
  if delta > -DeadbandUu and delta < DeadbandUu:
    return 4
  let span = max(1, ticks)
  let want = float(delta) / float(span)
  var level = int(want / float(PaddleStepSpeed) + (if want >= 0: 0.5 else: -0.5))
  if level < -4: level = -4
  if level > 4: level = 4
  4 + level

proc paddleCommand*(
  sim: SimServer, cabinet: int, stance: CabinetStance
): uint8 =
  ## The command byte for one cabinet this tick.
  if sim.phase != Playing or cabinet < 0 or cabinet >= CabinetCount or
      sim.cabinets[cabinet].isOut:
    return NeutralCommand

  let
    paddleHalf = paddleHalfUu(sim.config)
    centre = sim.cabinets[cabinet].alongCentre
  var predictions: seq[BallPrediction]
  for index in 0 ..< sim.balls.len:
    predictions.add(sim.predictBall(index))

  # --- 2. ball choice ------------------------------------------------------
  var chosen = -1
  if stance.targetBall >= 0 and stance.targetBall < sim.balls.len and
      sim.balls[stance.targetBall].state == bsLive and
      predictions[stance.targetBall].perSide[cabinet].reaches:
    chosen = stance.targetBall
  if chosen < 0 and stance.stance == stChase:
    # `chase` goes for WHICHEVER BALL ARRIVES SOONEST — anywhere on the board,
    # not just on my own line. That is the stance's whole character: it is how
    # a chaser ends up shadowing a ball that was never coming at it and leaves
    # its own mouth open. `guard`/`aim`/`camp` only ever consider balls that
    # reach MY line.
    var best = PredictTicks + 2
    for index in 0 ..< sim.balls.len:
      if sim.balls[index].state != bsLive:
        continue
      if predictions[index].firstSide >= 0 and
          predictions[index].firstTick < best:
        best = predictions[index].firstTick
        chosen = index
  if chosen < 0:
    var best = PredictTicks + 2
    for index in 0 ..< sim.balls.len:
      if sim.balls[index].state != bsLive:
        continue
      let arrival = predictions[index].perSide[cabinet]
      if arrival.reaches and arrival.tick < best:
        best = arrival.tick
        chosen = index
  var secondTick = PredictTicks + 2
  var second = -1
  for index in 0 ..< sim.balls.len:
    if index == chosen or sim.balls[index].state != bsLive:
      continue
    let arrival = predictions[index].perSide[cabinet]
    if arrival.reaches and arrival.tick < secondTick:
      secondTick = arrival.tick
      second = index

  # --- 6. grip (evaluated first: a release also aims with `near`) ----------
  var grip = 0
  var releaseJ = 0
  let holding = sim.cabinets[cabinet].heldBall >= 0
  if holding:
    let held = int(sim.cabinets[cabinet].heldBall)
    let holdTicks = int(sim.balls[held].holdTicks)
    let want = 24 + int(stance.aggressionFraction() * 24.0 + 0.5)
    if holdTicks >= want or (second >= 0 and secondTick <= 24):
      grip = 2
      releaseJ =
        if stance.aimAt >= 0:
          sim.aimOffsetJ(cabinet, centre, stance.aimAt)
        else: 0
      if releaseJ < -4: releaseJ = -4
      if releaseJ > 4: releaseJ = 4
  elif stance.stance == stCatch and sim.config.catchEnabled and
      chosen >= 0 and sim.predictedContactNow(cabinet, predictions[chosen]):
    grip = 1

  # --- 3. desired contact offset -----------------------------------------
  var offset = 0'i32
  var effective = stance.stance
  if effective == stCatch and not sim.config.catchEnabled:
    effective = stGuard
  if effective in {stAim, stChase}:
    if stance.aimAt < 0 or stance.aimAt == cabinet or
        sim.cabinets[max(0, stance.aimAt)].isOut:
      effective = stGuard
    elif chosen >= 0:
      # `aim` takes the SMALLEST |j| that reaches the target's mouth (a
      # shallower deflection is a smaller demand on the bar). `chase` takes
      # THE MOST AGGRESSIVE aim available — |j| = 6, the very tip of the bar —
      # which is what "maximum damage, and it is how you end up out of
      # position" means: a tip contact is a knife edge, so a chase that is a
      # centimetre off misses altogether.
      let j =
        if effective == stChase:
          let diff = ((stance.aimAt - cabinet) mod CabinetCount +
            CabinetCount) mod CabinetCount
          if diff == 3: -6 else: 6
        else:
          sim.aimOffsetJ(
            cabinet, predictions[chosen].perSide[cabinet].along, stance.aimAt)
      offset = int32((int64(j) * int64(paddleHalf)) div 6'i64)

  # --- 4. desired bar centre ---------------------------------------------
  var wanted = 0'i32
  var horizon = stance.leadTicks
  if chosen >= 0:
    let arrival = predictions[chosen].perSide[cabinet]
    # `lead_ticks` is HOW FAR AHEAD THE AUTOPILOT COMMITS THE BAR. Inside that
    # window it commits to the interception point; outside it, it merely
    # SHADOWS the ball's current along-projection. That is what makes
    # lead_ticks 0 arrive late — the whole reason `spinner` (chase,
    # lead_ticks 0) is a weaker policy than `bulwark` — and what makes
    # champion #1's "keep lead_ticks between 8 and 20" a real instruction.
    let intercept = arrival.along - offset
    let shadow = localOf(cabinet, sim.balls[chosen].x, sim.balls[chosen].y).along
    let committed =
      if arrival.reaches and arrival.tick <= max(1, stance.leadTicks): intercept
      else: shadow
    case effective
    of stCamp:
      let window = int32(stance.aggressionFraction() * 43.0 * float(UuPerCu)) +
        8'i32 * UuPerCu
      let gap = arrival.along - stance.postUu
      wanted =
        if gap > -window and gap < window: committed else: stance.postUu
    of stChase:
      wanted = committed
      horizon = 0
    else:
      wanted = committed
    horizon =
      if arrival.reaches: max(1, min(max(1, horizon), arrival.tick))
      else: max(1, horizon)
  else:
    wanted = if effective == stCamp: stance.postUu else: 0'i32
    horizon = max(1, stance.leadTicks)
  if wanted < -PaddleTravelHalf: wanted = -PaddleTravelHalf
  if wanted > PaddleTravelHalf: wanted = PaddleTravelHalf

  # --- 5. drive -----------------------------------------------------------
  var near =
    if grip == 2: 4 + releaseJ
    else: driveLevel(wanted, centre, horizon)

  # --- 7. far paddle (foozpong) ------------------------------------------
  var far = 4
  if sim.config.farPaddle:
    var farBall = if second >= 0: second else: chosen
    if farBall >= 0:
      # The same steps 1-5 at FarPaddleDepth, with off = 0 always: the far bar
      # is told where the ball crosses ITS OWN line, not the near one's.
      let prediction = predictions[farBall]
      var farTarget = 0'i32
      var farHorizon = stance.leadTicks
      let arrival =
        if prediction.perSideFar[cabinet].reaches:
          prediction.perSideFar[cabinet]
        else:
          prediction.perSide[cabinet]
      if arrival.reaches:
        farTarget = arrival.along
        farHorizon = min(farHorizon, arrival.tick)
      else:
        farTarget = int32(int64(stance.postUu) div 2'i64)
      if farTarget < -PaddleTravelHalf: farTarget = -PaddleTravelHalf
      if farTarget > PaddleTravelHalf: farTarget = PaddleTravelHalf
      far = driveLevel(
        farTarget, sim.cabinets[cabinet].farAlongCentre, farHorizon)
    else:
      far = driveLevel(
        int32(int64(stance.postUu) div 2'i64),
        sim.cabinets[cabinet].farAlongCentre, stance.leadTicks)
  encodePaddle(near, far, grip)
