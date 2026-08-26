## THE CABINET — the gameplay core and the step loop.
##
## Four cabinets, one square CRT, two balls, two minutes. Every ball that
## crosses your mouth costs you a life; the last cabinet with lives standing
## wins. Full rules: docs/RULES.md, design note §The game.
##
## `sim.nim` imports and RE-EXPORTS every sim module, so `import cabinet/sim`
## sees everything (the starter's convention).
##
## NO FLOATING POINT IN THIS FILE (grep-enforced, tests/test_determinism.nim).
## Every product or quotient of two sim quantities goes through `int64`.

import sim_types, trig, arena, rom, sim_config, sim_state, roster
export sim_types, trig, arena, rom, sim_config, sim_state, roster

const
  NeutralCommand* = 40'u8
    ## near = 4, far = 4, grip = 0: both bars still, no grip. 243 of the 256
    ## byte values are legal and `cmd >= 243` is REPAIRED to this in both the
    ## server and the replay runtime, so a corrupt byte can never desynchronise
    ## the two.
  MaxCommand* = 242'u8
  ServeRejectAttempts* = 32
  ServeFallbackScan* = [6'u8, 22'u8, 38'u8, 54'u8, 10'u8, 26'u8, 42'u8, 58'u8]
  MaxServeFallbacks* = 8
  SecondBallDirOffset* = 7
  NearMissUu* = 12_000'i32        ## 1.20 cu past the bar's end
  SpinStrong* = 12_000'i32
  SpinWeak* = 4_000'i32

proc decodePaddle*(cmd: uint8): tuple[near, far, grip: int32] =
  ## The command byte: `near = cmd mod 9`, `far = (cmd div 9) mod 9`,
  ## `grip = cmd div 81`. Shared by the server and the replay runtime.
  var value = int(cmd)
  if value >= 243:
    value = int(NeutralCommand)
  (int32(value mod 9), int32((value div 9) mod 9), int32(value div 81))

proc encodePaddle*(near, far, grip: int): uint8 =
  ## The inverse, clamped into the legal range.
  let
    n = max(0, min(8, near))
    f = max(0, min(8, far))
    g = max(0, min(2, grip))
  uint8(g * 81 + f * 9 + n)

proc roundDiv*(a, b: int64): int64 =
  ## round(a / b) for b > 0, symmetric under negation of `a`, all integer.
  if b == 0:
    return 0
  if a >= 0: (2 * a + b) div (2 * b)
  else: -((-2 * a + b) div (2 * b))

# ---------------------------------------------------------------------------
#  Construction
# ---------------------------------------------------------------------------

proc initSimServer*(config: GameConfig): SimServer =
  ## A fresh episode. The seat -> cabinet permutation is the first draw of the
  ## seeded stream, so it is a pure function of `config.seed` and the replay's
  ## config JSON can echo it before tick 0.
  result.config = config
  result.phase = Lobby
  result.tickCount = 0
  result.gameStartTick = 0
  result.winnerCabinet = -1
  result.endReason = ""
  result.endRule = ""
  result.gameEventLoggingEnabled = true
  result.lastLobbyPlayersLogged = -1
  result.lastLobbyNeededLogged = -1
  result.lastLobbySecondsLogged = -1
  result.rng = initRngState(config.seed)
  result.rngDraws = 0
  result.perm = drawPermutation(result.rng, result.rngDraws)
  for k in 0 ..< CabinetCount:
    result.cabinets[k].lives = int32(config.startingLives)
    result.cabinets[k].outTick = -1
    result.cabinets[k].heldBall = -1
    result.cabinets[k].placement = 0
    for row in 0 ..< MaxBrickRows:
      for col in 0 ..< BricksPerRow:
        result.cabinets[k].bricks[row][col] = row < config.brickRows
  result.balls = newSeq[Ball](max(1, min(MaxBalls, config.ballCount)))
  for i in 0 ..< result.balls.len:
    result.balls[i] = Ball(
      state: bsServing,
      x: ArenaHalf, y: ArenaHalf,
      dir: 0, speed: ballSpeed0Uu(config),
      lastTouch: -1, holdTicks: 0, serveTimer: 0, heldBy: -1)
  for seat in 0 ..< CabinetCount:
    result.seatNames[seat] = ""
    result.seatPolicyKind[seat] = "scripted"

proc ballId*(index: int): string =
  "B" & $(index + 1)

proc ballIndexOfId*(id: string): int =
  ## "B1".."B3" (case-insensitive) -> index, else -1.
  if id.len != 2 or (id[0] != 'B' and id[0] != 'b'):
    return -1
  let digit = int(id[1]) - int('0')
  if digit < 1 or digit > MaxBalls:
    return -1
  digit - 1

# ---------------------------------------------------------------------------
#  Geometry of the live board
# ---------------------------------------------------------------------------

proc paddleBox*(
  sim: SimServer, cabinet: int, far: bool
): tuple[x0, y0, x1, y1: int32] =
  ## One paddle's world-space axis-aligned box.
  let
    half = if far: farPaddleHalfUu(sim.config) else: paddleHalfUu(sim.config)
    centre =
      if far: sim.cabinets[cabinet].farAlongCentre
      else: sim.cabinets[cabinet].alongCentre
    depth = if far: FarPaddleDepth else: PaddleDepth
    a = worldOf(cabinet, centre - half, depth - PaddleThickHalf)
    b = worldOf(cabinet, centre + half, depth + PaddleThickHalf)
  (min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y))

proc brickBox*(
  cabinet, row, col: int
): tuple[x0, y0, x1, y1: int32] =
  ## One brick's world-space axis-aligned box.
  let
    depths = brickRowDepths(row)
    centre = brickAlongCentre(col)
    a = worldOf(cabinet, centre - BrickHalfWidth, depths.lo)
    b = worldOf(cabinet, centre + BrickHalfWidth, depths.hi)
  (min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y))

proc bricksLeft*(sim: SimServer, cabinet: int): int =
  for row in 0 ..< sim.config.brickRows:
    for col in 0 ..< BricksPerRow:
      if sim.cabinets[cabinet].bricks[row][col]:
        inc result

proc bricksTotal*(sim: SimServer): int =
  sim.config.brickRows * BricksPerRow

proc brickColumnEmpty*(sim: SimServer, cabinet, col: int): bool =
  for row in 0 ..< sim.config.brickRows:
    if sim.cabinets[cabinet].bricks[row][col]:
      return false
  true

proc dirPointsAtCabinet*(dir: uint8): int =
  ## Which cabinet's side a ray leaving the arena CENTRE reaches first.
  ## Integer and tie-broken deterministically toward the x axis, so a
  ## diagonal serve always names the same side on every build.
  let v = dirVector(dir)
  let
    ax = if v.x < 0: -v.x else: v.x
    ay = if v.y < 0: -v.y else: v.y
  if ax >= ay:
    if v.x > 0: 1 else: 3          ## EAST : WEST
  else:
    if v.y > 0: 0 else: 2          ## y DOWN is SOUTH : NORTH

proc serveDirectionLegal*(sim: SimServer, dir: uint8): bool =
  ## No ball is served nearly parallel to a wall (`dir mod 16` in {0, 1, 15}
  ## is rejected) and none is served straight at a cabinet that is already
  ## out.
  let m = int(dir) mod 16
  if m == 0 or m == 1 or m == 15:
    return false
  let target = dirPointsAtCabinet(dir)
  if target >= 0 and sim.cabinets[target].isOut:
    return false
  true

proc drawServeDirection(sim: var SimServer): uint8 =
  ## Bounded rejection sampling. DEGRADE, NEVER HANG applies to sampling too:
  ## an unbounded rejection loop inside a hashed step function is exactly the
  ## hang the rule forbids, so after `ServeRejectAttempts` the serve takes the
  ## first legal index of a fixed scan.
  for _ in 0 ..< ServeRejectAttempts:
    let candidate = uint8(drawInt(sim.rng, sim.rngDraws, 0'i32, 63'i32))
    if sim.serveDirectionLegal(candidate):
      return candidate
  inc sim.serveFallbacks
  for candidate in ServeFallbackScan:
    if sim.serveDirectionLegal(candidate):
      return candidate
  ServeFallbackScan[0]

proc serveBall(sim: var SimServer, index: int, offsetIndex: int) =
  ## Serves one ball from the arena centre.
  var ball = sim.balls[index]
  var dir = drawServeDirection(sim)
  if offsetIndex > 0:
    dir = uint8((int(dir) + SecondBallDirOffset * offsetIndex) mod 64)
  ball.state = bsLive
  ball.x = ArenaHalf
  ball.y = ArenaHalf
  ball.dir = dir
  ball.speed = ballSpeed0Uu(sim.config)
  ball.lastTouch = -1
  ball.holdTicks = 0
  ball.serveTimer = 0
  ball.heldBy = -1
  ball.trailLen = 0
  sim.balls[index] = ball
  sim.emitEvent(Serve, ball = index, amount = int(dir))

# ---------------------------------------------------------------------------
#  Scoring
# ---------------------------------------------------------------------------

proc recomputeScore(sim: var SimServer, cabinet: int) =
  ## Every term is NON-NEGATIVE, so the minimum score is 0.000 and higher is
  ## always better: conceding is punished by not EARNING the lives term rather
  ## than by a negative number, which keeps the whole scale readable on a
  ## scorebug.
  let
    cab = sim.cabinets[cabinet]
    starting = int64(max(1, sim.config.startingLives))
  var micro = (LivesTermMicro * int64(max(0'i32, cab.lives))) div starting
  if cab.placement == 1:
    micro += CrownMicro
  micro += KnockoutMicro * int64(cab.knockouts)
  micro += ChipMicro * int64(cab.chips)
  micro += SaveMicro * int64(cab.saves)
  sim.cabinets[cabinet].scoreMicro = micro

proc outranks(sim: SimServer, a, b: int): bool =
  ## The placement chain, exactly as designed:
  ##  1. a cabinet with lives outranks every cabinet with none;
  ##  2. among the living: more lives, then more bricks, then more saves, then
  ##     the LOWER cabinet index;
  ##  3. among the eliminated: LATER outTick, then more knockouts, then the
  ##     lower cabinet index.
  ## The index tiebreak makes the chain total, so `placements` is always a
  ## strict permutation of 1..4 and exactly one seat takes the crown.
  let
    ca = sim.cabinets[a]
    cb = sim.cabinets[b]
  if (ca.lives > 0) != (cb.lives > 0):
    return ca.lives > 0
  if ca.lives > 0:
    if ca.lives != cb.lives:
      return ca.lives > cb.lives
    let
      ba = sim.bricksLeft(a)
      bb = sim.bricksLeft(b)
    if ba != bb:
      return ba > bb
    if ca.saves != cb.saves:
      return ca.saves > cb.saves
    return a < b
  if ca.outTick != cb.outTick:
    return ca.outTick > cb.outTick
  if ca.knockouts != cb.knockouts:
    return ca.knockouts > cb.knockouts
  a < b

proc assignPlacements(sim: var SimServer) =
  ## Sorts the four cabinets by the total chain above and stamps 1..4.
  var order: array[CabinetCount, int]
  for i in 0 ..< CabinetCount:
    order[i] = i
  for i in 1 ..< CabinetCount:
    var j = i
    while j > 0 and sim.outranks(order[j], order[j - 1]):
      let tmp = order[j]
      order[j] = order[j - 1]
      order[j - 1] = tmp
      dec j
  for rank, cabinet in order:
    sim.cabinets[cabinet].placement = int32(rank + 1)
  sim.winnerCabinet = order[0]

proc finishGame*(sim: var SimServer, reason, rule: string) =
  ## Ends the episode: places the four cabinets, folds the crown into the
  ## winner's score and enters the game-over hold.
  if sim.phase == GameOver:
    return
  sim.assignPlacements()
  for k in 0 ..< CabinetCount:
    sim.recomputeScore(k)
  if sim.endReason.len == 0:
    sim.endReason = reason
  if sim.endRule.len == 0:
    sim.endRule = rule
  sim.emitEvent(PhaseChange, amount = ord(GameOver), detail = sim.endRule)
  sim.phase = GameOver
  sim.gameOverTimer = max(1, sim.config.gameOverTicks)
  sim.logGameEvent(
    "game over: " & sim.endReason & "/" & sim.endRule & " — " &
    aliasOfCabinet(sim.winnerCabinet) & " takes it with " &
    $sim.cabinets[sim.winnerCabinet].lives & " lives left")

# ---------------------------------------------------------------------------
#  Contacts
# ---------------------------------------------------------------------------

proc earliestContact*(
  sim: SimServer, px, py, dx, dy: int32
): Contact =
  ## The earliest swept contact along `pos -> pos + delta`, with ties broken
  ## in this exact priority order: paddles (near then far, cabinet index
  ## order), bricks (cabinet order, row then column), mouth lines, solid
  ## walls. Crossing times are compared by integer cross-multiplication.
  result.kind = ckNone
  proc consider(best: var Contact, candidate: Contact) =
    if candidate.kind == ckNone:
      return
    if best.kind == ckNone or isBefore(candidate.t, best.t):
      best = candidate
  # (a) paddles
  for k in 0 ..< CabinetCount:
    if sim.cabinets[k].isOut:
      continue
    let box = sim.paddleBox(k, far = false)
    let hit = sweptBox(px, py, dx, dy, box.x0, box.y0, box.x1, box.y1)
    if hit.hit:
      consider(result, Contact(
        kind: ckPaddle, cabinet: int32(k), row: -1, col: -1,
        axisX: hit.axisX, t: hit.t))
    if sim.config.farPaddle:
      let farBox = sim.paddleBox(k, far = true)
      let farHit = sweptBox(
        px, py, dx, dy, farBox.x0, farBox.y0, farBox.x1, farBox.y1)
      if farHit.hit:
        consider(result, Contact(
          kind: ckFarPaddle, cabinet: int32(k), row: -1, col: -1,
          axisX: farHit.axisX, t: farHit.t))
  # (b) bricks
  for k in 0 ..< CabinetCount:
    if sim.cabinets[k].isOut:
      continue
    for row in 0 ..< sim.config.brickRows:
      for col in 0 ..< BricksPerRow:
        if not sim.cabinets[k].bricks[row][col]:
          continue
        let box = brickBox(k, row, col)
        let hit = sweptBox(px, py, dx, dy, box.x0, box.y0, box.x1, box.y1)
        if hit.hit:
          consider(result, Contact(
            kind: ckBrick, cabinet: int32(k), row: int32(row), col: int32(col),
            axisX: hit.axisX, t: hit.t))
  # (c) mouth lines
  let goalHalf = goalHalfUu(sim.config)
  for k in 0 ..< CabinetCount:
    if sim.cabinets[k].isOut:
      continue
    let crossing = sideDepthCrossing(k, px, py, dx, dy, 0'i32)
    if not crossing.hit:
      continue
    let
      cx = px + fracValueUu(crossing.t, dx)
      cy = py + fracValueUu(crossing.t, dy)
      along = localOf(k, cx, cy).along
    if along > -goalHalf and along < goalHalf:
      consider(result, Contact(
        kind: ckMouth, cabinet: int32(k), row: -1, col: -1,
        axisX: not sideIsHorizontal(k), t: crossing.t))
  # (d) solid walls — the non-mouth part of any side, or the whole side of an
  #     out cabinet.
  for k in 0 ..< CabinetCount:
    let crossing = sideDepthCrossing(k, px, py, dx, dy, BallHalf)
    if not crossing.hit:
      continue
    let
      cx = px + fracValueUu(crossing.t, dx)
      cy = py + fracValueUu(crossing.t, dy)
      along = localOf(k, cx, cy).along
    if not sim.cabinets[k].isOut and along > -goalHalf and along < goalHalf:
      continue                     ## the gap: the ball flies through
    consider(result, Contact(
      kind: ckWall, cabinet: int32(k), row: -1, col: -1,
      axisX: not sideIsHorizontal(k), t: crossing.t))
  if result.kind != ckNone:
    result.x = px + fracValueUu(result.t, dx)
    result.y = py + fracValueUu(result.t, dy)

proc spinOf(paddleVel: int32): int =
  let magnitude = if paddleVel < 0: -paddleVel else: paddleVel
  let step =
    if magnitude >= SpinStrong: 2
    elif magnitude >= SpinWeak: 1
    else: 0
  if paddleVel < 0: -step else: step

proc deflectionIndex*(
  offset, paddleHalf, paddleVel: int32
): int =
  ## The deflection fan, in side-local indices. `offset` is the signed contact
  ## offset from the bar's centre along +along, so a hit on the +along half
  ## sends the ball toward +along — the classic paddle behaviour — and
  ## sweeping the bar as you hit steepens the angle.
  ##
  ## The result is ALWAYS in 4..28 (22.5 deg .. 157.5 deg), so the outgoing
  ## ball always travels away from the defender's side: a paddle can never
  ## deflect a ball into its own mouth (tests/test_physics.nim, exhaustive).
  let half = max(1'i32, paddleHalf)
  var j = int(roundDiv(int64(offset) * 6'i64, int64(half))) + spinOf(paddleVel)
  if j < -6: j = -6
  if j > 6: j = 6
  16 - 2 * j

proc releaseIndex*(near: int32): int =
  ## A gripped ball is AIMED BY THE DRIVE LEVEL in the byte that releases it:
  ## `j = near - 4`, so the release rides the same recorded byte as everything
  ## else and the viewer re-derives it with no extra record. Range 8..24.
  var j = int(near) - 4
  if j < -6: j = -6
  if j > 6: j = 6
  16 - 2 * j

# ---------------------------------------------------------------------------
#  The tick
# ---------------------------------------------------------------------------

proc concede*(sim: var SimServer, cabinet, ballIndex: int) =
  ## A ball crossed cabinet `cabinet`'s mouth line inside the gap.
  let shooter = int(sim.balls[ballIndex].lastTouch)
  sim.cabinets[cabinet].lives = max(0'i32, sim.cabinets[cabinet].lives - 1)
  inc sim.cabinets[cabinet].concedes
  if shooter >= 0 and shooter != cabinet:
    inc sim.cabinets[shooter].knockouts
  sim.lastConcede = sim.tickCount
  sim.emitEvent(
    Concede, cabinet = cabinet, by = shooter, ball = ballIndex,
    amount = int(sim.cabinets[cabinet].lives))
  sim.logGameEvent(
    aliasOfCabinet(cabinet) & " concedes " & ballId(ballIndex) &
    (if shooter >= 0 and shooter != cabinet: " to " & aliasOfCabinet(shooter)
     else: "") & " — " & $sim.cabinets[cabinet].lives & " lives left")
  # The ball is removed and re-served from the centre.
  var ball = sim.balls[ballIndex]
  ball.state = bsServing
  ball.x = ArenaHalf
  ball.y = ArenaHalf
  ball.speed = ballSpeed0Uu(sim.config)
  ball.lastTouch = -1
  ball.heldBy = -1
  ball.holdTicks = 0
  ball.serveTimer = int32(max(0, sim.config.serveDelayTicks))
  ball.trailLen = 0
  sim.balls[ballIndex] = ball
  if sim.cabinets[cabinet].lives <= 0 and not sim.cabinets[cabinet].isOut:
    sim.cabinets[cabinet].isOut = true
    sim.cabinets[cabinet].outTick = int32(sim.tickCount)
    sim.cabinets[cabinet].heldBall = -1
    for row in 0 ..< MaxBrickRows:
      for col in 0 ..< BricksPerRow:
        sim.cabinets[cabinet].bricks[row][col] = false
    sim.emitEvent(Eliminated, cabinet = cabinet, amount = sim.tickCount)
    sim.logGameEvent(aliasOfCabinet(cabinet) & " is OUT")

proc releaseHeldBall(sim: var SimServer, cabinet, ballIndex: int, near: int32) =
  var ball = sim.balls[ballIndex]
  let localDir = releaseIndex(near)
  ball.state = bsLive
  ball.dir = fromLocalDir(localDir, cabinet)
  ball.heldBy = -1
  ball.holdTicks = 0
  ball.lastTouch = int32(cabinet)
  sim.balls[ballIndex] = ball
  sim.cabinets[cabinet].heldBall = -1
  sim.emitEvent(Release, cabinet = cabinet, ball = ballIndex,
    amount = localDir)

proc containBall(sim: var SimServer, index: int) =
  ## Belt and braces on top of the swept test: after motion no live ball may
  ## sit outside the box. §Time proves no collidable is thinner than one tick
  ## of travel, but a CORNER reflection applies its remaining displacement
  ## without further contact resolution, and at `BallSpeedMax` that remainder
  ## can just cross the adjacent wall plane. Rather than fault the episode for
  ## a one-µu overshoot, push the ball back to the wall face and reflect it —
  ## deterministic, integer, and identical in both builds.
  if sim.balls[index].state != bsLive:
    return
  let goalHalf = goalHalfUu(sim.config)
  for k in 0 ..< CabinetCount:
    var ball = sim.balls[index]
    let local = localOf(k, ball.x, ball.y)
    if local.depth >= BallHalf:
      continue
    let inGap = not sim.cabinets[k].isOut and
      local.along > -goalHalf and local.along < goalHalf
    if local.depth < 0 and inGap:
      sim.concede(k, index)
      return
    if inGap:
      # Flying THROUGH the mouth: there is no wall here to bounce off, and
      # pushing it back out would silently make every mouth un-scoreable.
      continue
    let repaired = worldOf(k, local.along, BallHalf)
    ball.x = repaired.x
    ball.y = repaired.y
    ball.dir =
      if sideIsHorizontal(k): reflectHorizontal(ball.dir)
      else: reflectVertical(ball.dir)
    sim.balls[index] = ball

proc pushTrail(sim: var SimServer, index: int) =
  ## Presentation only (never hashed): the 6-frame motion trail the board
  ## draws, brightest at the ball.
  var ball = sim.balls[index]
  var i = BallTrailLength - 1
  while i > 0:
    ball.trailX[i] = ball.trailX[i - 1]
    ball.trailY[i] = ball.trailY[i - 1]
    dec i
  ball.trailX[0] = ball.x
  ball.trailY[0] = ball.y
  if ball.trailLen < int32(BallTrailLength):
    inc ball.trailLen
  sim.balls[index] = ball

proc stepPaddles(sim: var SimServer, commands: openArray[uint8]) =
  ## Cabinet index order, never seat order: seat order varies with `perm` and
  ## the loop must not.
  for k in 0 ..< CabinetCount:
    if sim.cabinets[k].isOut:
      sim.cabinets[k].paddleVel = 0
      sim.cabinets[k].farPaddleVel = 0
      continue
    let seat = sim.seatOfCabinet(k)
    let cmd =
      if seat >= 0 and seat < commands.len: commands[seat]
      else: NeutralCommand
    let decoded = decodePaddle(cmd)
    let wantNear = (decoded.near - 4'i32) * PaddleStepSpeed
    let before = sim.cabinets[k].alongCentre
    var next = before + wantNear
    if next < -PaddleTravelHalf: next = -PaddleTravelHalf
    if next > PaddleTravelHalf: next = PaddleTravelHalf
    sim.cabinets[k].alongCentre = next
    sim.cabinets[k].paddleVel = next - before
    if sim.config.farPaddle:
      let wantFar = (decoded.far - 4'i32) * PaddleStepSpeed
      let farBefore = sim.cabinets[k].farAlongCentre
      var farNext = farBefore + wantFar
      if farNext < -PaddleTravelHalf: farNext = -PaddleTravelHalf
      if farNext > PaddleTravelHalf: farNext = PaddleTravelHalf
      sim.cabinets[k].farAlongCentre = farNext
      sim.cabinets[k].farPaddleVel = farNext - farBefore
    else:
      sim.cabinets[k].farAlongCentre = 0
      sim.cabinets[k].farPaddleVel = 0

proc stepBall(sim: var SimServer, index: int, commands: openArray[uint8]) =
  var ball = sim.balls[index]
  case ball.state
  of bsServing:
    if ball.serveTimer > 0:
      dec ball.serveTimer
      sim.balls[index] = ball
      return
    sim.balls[index] = ball
    sim.serveBall(index, 0)
    return
  of bsHeld:
    let holder = int(ball.heldBy)
    if holder < 0 or holder >= CabinetCount or sim.cabinets[holder].isOut:
      ball.state = bsLive
      ball.heldBy = -1
      ball.holdTicks = 0
      sim.balls[index] = ball
      return
    # A held ball does not move: its centre is pinned in front of the bar.
    let pinned = worldOf(
      holder, sim.cabinets[holder].alongCentre,
      PaddleDepth + PaddleThickHalf + BallHalf)
    ball.x = pinned.x
    ball.y = pinned.y
    inc ball.holdTicks
    sim.balls[index] = ball
    let seat = sim.seatOfCabinet(holder)
    let cmd =
      if seat >= 0 and seat < commands.len: commands[seat]
      else: NeutralCommand
    let decoded = decodePaddle(cmd)
    if ball.holdTicks >= int32(max(0, sim.config.holdTicksMax)) or
        decoded.grip == 2:
      sim.releaseHeldBall(holder, index, decoded.near)
    return
  of bsLive:
    discard

  # --- live: one displacement, at most ONE contact ---------------------------
  let vector = dirVector(ball.dir)
  let
    dx = int32((int64(ball.speed) * int64(vector.x)) div int64(DirQ12One))
    dy = int32((int64(ball.speed) * int64(vector.y)) div int64(DirQ12One))
  let contact = sim.earliestContact(ball.x, ball.y, dx, dy)
  if contact.kind == ckNone:
    ball.x = ball.x + dx
    ball.y = ball.y + dy
    sim.balls[index] = ball
    sim.containBall(index)
    sim.pushTrail(index)
    return

  let k = int(contact.cabinet)
  ball.x = contact.x
  ball.y = contact.y
  var newDir = ball.dir
  var newSpeed = ball.speed
  var departs = true

  case contact.kind
  of ckPaddle, ckFarPaddle:
    let far = contact.kind == ckFarPaddle
    let
      half = if far: farPaddleHalfUu(sim.config) else: paddleHalfUu(sim.config)
      centre =
        if far: sim.cabinets[k].farAlongCentre else: sim.cabinets[k].alongCentre
      paddleVel =
        if far: sim.cabinets[k].farPaddleVel else: sim.cabinets[k].paddleVel
      contactAlong = localOf(k, contact.x, contact.y).along
    var offset = contactAlong - centre
    if offset < -half: offset = -half
    if offset > half: offset = half
    inc sim.cabinets[k].saves
    ball.lastTouch = int32(k)
    newDir = fromLocalDir(deflectionIndex(offset, half, paddleVel), k)
    let maxSpeed = ballSpeedMaxUu(sim.config)
    newSpeed = min(maxSpeed, ball.speed + ballSpeedStepUu(sim.config))
    sim.emitEvent(
      Save, cabinet = k, ball = index, amount = int(newSpeed),
      x = int(contact.x), y = int(contact.y))
    # A catch: the ball is GRIPPED instead of departing.
    if not far and sim.config.catchEnabled and
        sim.cabinets[k].heldBall < 0:
      let seat = sim.seatOfCabinet(k)
      let cmd =
        if seat >= 0 and seat < commands.len: commands[seat]
        else: NeutralCommand
      if decodePaddle(cmd).grip == 1:
        departs = false
        ball.state = bsHeld
        ball.heldBy = int32(k)
        ball.holdTicks = 0
        ball.speed = newSpeed
        ball.dir = newDir
        let pinned = worldOf(
          k, sim.cabinets[k].alongCentre,
          PaddleDepth + PaddleThickHalf + BallHalf)
        ball.x = pinned.x
        ball.y = pinned.y
        sim.cabinets[k].heldBall = int32(index)
        inc sim.cabinets[k].catches
        sim.emitEvent(Catch, cabinet = k, ball = index)
  of ckBrick:
    let
      row = int(contact.row)
      col = int(contact.col)
      shooter = int(ball.lastTouch)
    sim.cabinets[k].bricks[row][col] = false
    # A cabinet chipping its OWN wall scores nothing — stated so it is not a
    # loophole.
    if shooter >= 0 and shooter != k:
      inc sim.cabinets[shooter].chips
    newDir =
      if contact.axisX: reflectVertical(ball.dir)
      else: reflectHorizontal(ball.dir)
    sim.emitEvent(Chip, cabinet = k, by = shooter, ball = index, amount = col)
    if sim.brickColumnEmpty(k, col):
      sim.emitEvent(Breach, cabinet = k, amount = col)
    if sim.bricksLeft(k) == 0 and sim.config.brickRows > 0:
      sim.emitEvent(WallDown, cabinet = k)
  of ckMouth:
    sim.balls[index] = ball
    sim.concede(k, index)
    return
  of ckWall:
    newDir =
      if contact.axisX: reflectVertical(ball.dir)
      else: reflectHorizontal(ball.dir)
  of ckNone:
    discard

  if not departs:
    sim.balls[index] = ball
    return
  ball.dir = newDir
  ball.speed = newSpeed
  # The remaining fraction of the displacement, along the NEW index. One ball
  # takes at most one contact per tick.
  let remaining = initFrac(contact.t.den - contact.t.num, contact.t.den)
  let outVector = dirVector(newDir)
  let
    fullX = int32((int64(newSpeed) * int64(outVector.x)) div int64(DirQ12One))
    fullY = int32((int64(newSpeed) * int64(outVector.y)) div int64(DirQ12One))
  ball.x = ball.x + fracValueUu(remaining, fullX)
  ball.y = ball.y + fracValueUu(remaining, fullY)
  sim.balls[index] = ball
  sim.containBall(index)
  sim.pushTrail(index)

proc guardInvariants(sim: SimServer) =
  ## Step 7's invariant guards. A trip ends the episode `fault/sim_fault`
  ## with a partial replay, never a silent non-zero exit.
  for i, ball in sim.balls:
    if ball.state == bsLive:
      if ball.x < 0 or ball.x > ArenaSide or ball.y < 0 or ball.y > ArenaSide:
        raise newException(SimGuardError,
          "ball " & ballId(i) & " centre left the arena at (" & $ball.x &
          ", " & $ball.y & ")")
    if ball.speed > ballSpeedMaxUu(sim.config) or
        ball.speed < ballSpeed0Uu(sim.config):
      raise newException(SimGuardError,
        "ball " & ballId(i) & " speed " & $ball.speed & " is out of range")
    if int(ball.dir) > 63:
      raise newException(SimGuardError,
        "ball " & ballId(i) & " direction index " & $ball.dir & " is illegal")
    if ball.holdTicks < 0 or ball.holdTicks > HoldTicksMax:
      raise newException(SimGuardError,
        "ball " & ballId(i) & " holdTicks " & $ball.holdTicks & " is illegal")
  for k in 0 ..< CabinetCount:
    if sim.cabinets[k].alongCentre < -PaddleTravelHalf or
        sim.cabinets[k].alongCentre > PaddleTravelHalf:
      raise newException(SimGuardError,
        aliasOfCabinet(k) & " paddle centre left its travel limit")
  if sim.serveFallbacks > MaxServeFallbacks:
    raise newException(SimGuardError,
      "the serve sampler fell through to its fixed scan " &
      $sim.serveFallbacks & " times")

proc startGame(sim: var SimServer) =
  sim.emitEvent(PhaseChange, amount = ord(Playing), detail = "playing")
  sim.phase = Playing
  sim.gameStartTick = sim.tickCount + 1
  sim.logGameEvent(
    "cabinet up: rom=" & sim.config.rom & " lives=" &
    $sim.config.startingLives & " balls=" & $sim.balls.len &
    " bricks/row=" & $sim.config.brickRows)

proc step*(sim: var SimServer, commands: openArray[uint8]) =
  ## One tick. `commands` is one byte per SEAT, in seat order — the exact
  ## bytes the replay records, so the wasm viewer re-derives every frame from
  ## them without ever running the autopilot or the LLM.
  case sim.phase
  of Lobby:
    sim.logLobbyWaiting()
    inc sim.lobbyTicks
    if sim.lobbyIsStarting():
      if sim.startWaitTimer <= 0:
        sim.startWaitTimer = max(1, sim.config.startWaitTicks)
      dec sim.startWaitTimer
      sim.logLobbyCountdown()
      if sim.startWaitTimer <= 0:
        sim.startGame()
    elif sim.lobbyJoinTimedOut():
      # A SEAT THAT NEVER CONNECTS DOES NOT END THE EPISODE. The lobby budget
      # expires, the server reports the no-show to COGAME_PLAYER_FAILURE_URI,
      # and the game starts anyway: that cabinet plays the published `bulwark`
      # baseline for the whole run, and three live cabinets against one
      # baseline is still a game. Deterministic at playback too — the recorded
      # joins reproduce the same lobby length.
      sim.logGameEvent(
        "lobby budget expired with " & $sim.players.len & "/" &
        $sim.config.minPlayers & " seats; the empty cabinets play bulwark")
      sim.startGame()
  of Playing:
    sim.stepPaddles(commands)
    for index in 0 ..< sim.balls.len:
      sim.stepBall(index, commands)
    for k in 0 ..< CabinetCount:
      sim.recomputeScore(k)
    sim.guardInvariants()
    # End checks, in order.
    if sim.aliveCabinets() <= 1:
      sim.emitEvent(LastStanding, cabinet = -1)
      sim.finishGame(ReasonComplete, EndRuleLastStanding)
    elif sim.tickCount + 1 >= sim.gameStartTick + sim.config.maxTicks:
      sim.finishGame(ReasonComplete, EndRuleFullTime)
  of GameOver:
    if sim.gameOverTimer > 0:
      dec sim.gameOverTimer
  inc sim.tickCount

proc stopForWallClock*(sim: var SimServer) =
  ## The engine's own hard stop: score the state as it stands, write the
  ## game-over frame and a complete replay up to this tick. Declared
  ## acceptable for phase-60 verification — it means the hosted LLM was slow,
  ## not that the game broke.
  sim.endReason = ReasonDeadline
  sim.endRule = EndRuleWallClock
  sim.finishGame(ReasonDeadline, EndRuleWallClock)

proc faultGame*(sim: var SimServer, rule: string) =
  sim.endReason = ReasonFault
  sim.endRule = rule
  sim.finishGame(ReasonFault, rule)
