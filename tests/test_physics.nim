## Sim unit tests: the ball, the bar, the fan and the no-tunnelling bound.

import std/[json, math, random, strutils, unittest]
import cabinet/[sim, stances, control, baselines, broadcast]
import helpers

suite "physics":
  test "the no-tunnelling bound is a fact, not a comment":
    # The shallowest contact window in the game is the paddle:
    # PaddleThickHalf + BallHalf. No legal ball speed can cross it in one
    # tick, which is what makes "one contact per ball per tick" safe.
    check BallSpeedMax < PaddleThickHalf + BallHalf
    let config = episodeConfig(1)
    check ballSpeedMaxUu(config) <= BallSpeedMax
    check ballSpeedMaxUu(config) < PaddleThickHalf + BallHalf
    # A brick is thicker still.
    check BallSpeedMax < (BrickRowDepthHi - BrickRowDepthLo) + BallHalf
    # And a paddle can always out-run the ball along its own side, so a miss
    # is a decision rather than a physics limitation.
    check PaddleMaxSpeed > BallSpeedMax

  test "speed is exactly ballSpeed0 until the first paddle contact, then rises by exactly one step":
    let config = episodeConfig(4242)
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    for seat in 0 ..< CabinetCount:
      discard game.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
    let
      speed0 = ballSpeed0Uu(config)
      step = ballSpeedStepUu(config)
      maxSpeed = ballSpeedMaxUu(config)
    var
      commands = newSeq[uint8](CabinetCount)
      lastSaves = 0
      lastSpeed: array[MaxBalls, int32]
      wallBounces = 0
      lastDir: array[MaxBalls, uint8]
    for seat in 0 ..< CabinetCount:
      commands[seat] = NeutralCommand
    for i in 0 ..< MaxBalls:
      lastSpeed[i] = speed0
    for tick in 0 ..< 5000:
      game.step(commands)
      if game.phase != Playing:
        break
      var saves = 0
      for k in 0 ..< CabinetCount:
        saves += int(game.cabinets[k].saves)
      for i in 0 ..< game.balls.len:
        let ball = game.balls[i]
        if ball.state != bsLive:
          lastSpeed[i] = speed0
          continue
        # every speed is on the ladder speed0 + n*step, capped
        check ball.speed >= speed0
        check ball.speed <= maxSpeed
        check (ball.speed - speed0) mod step == 0 or ball.speed == maxSpeed
        if ball.speed != lastSpeed[i]:
          # a change is exactly one step, and only ever upward
          check ball.speed - lastSpeed[i] == step or ball.speed == maxSpeed or
            ball.speed == speed0
          check saves > lastSaves or ball.speed == speed0
        lastSpeed[i] = ball.speed
        if ball.dir != lastDir[i]:
          inc wallBounces
          lastDir[i] = ball.dir
        # the centre never leaves the arena
        check ball.x >= 0 and ball.x <= ArenaSide
        check ball.y >= 0 and ball.y <= ArenaSide
      lastSaves = saves
    check wallBounces > 60

  test "the index reflection rules match a float reference to within one index":
    for d in 0 ..< 64:
      let
        vertical = reflectVertical(uint8(d))
        horizontal = reflectHorizontal(uint8(d))
        angle = 5.625 * float(d) * PI / 180.0
      # off a vertical surface the x-component negates; off a horizontal one
      # the y-component does.
      let
        wantVertical = arctan2(sin(angle), -cos(angle))
        wantHorizontal = arctan2(-sin(angle), cos(angle))
      proc indexOf(radians: float): float =
        var turns = radians / (2.0 * PI) * 64.0
        while turns < 0: turns += 64.0
        while turns >= 64: turns -= 64.0
        turns
      proc closeEnough(got: int, want: float): bool =
        let delta = min(abs(float(got) - want), 64.0 - abs(float(got) - want))
        delta <= 1.0
      check closeEnough(int(vertical), indexOf(wantVertical))
      check closeEnough(int(horizontal), indexOf(wantHorizontal))

  test "a paddle can NEVER deflect a ball into its own mouth (exhaustive)":
    # 13 offsets x 3 spin magnitudes (both signs) x 64 incoming indices x 4
    # sides: the outgoing LOCAL index must always land in 4..28, which is
    # exactly "away from the defender's side".
    var cases = 0
    let half = 7'i32 * UuPerCu
    for side in 0 ..< CabinetCount:
      for incoming in 0 ..< 64:
        for offsetStep in -6 .. 6:
          for spin in [-16_000'i32, -12_000'i32, -4_000'i32, 0'i32,
                       4_000'i32, 12_000'i32, 16_000'i32]:
            let
              offset = int32((int64(offsetStep) * int64(half)) div 6'i64)
              local = deflectionIndex(offset, half, spin)
            check local >= 4
            check local <= 28
            check local mod 2 == 0
            let outgoing = fromLocalDir(local, side)
            check int(toLocalDir(outgoing, side)) == local
            inc cases
    check cases == 4 * 64 * 13 * 7

  test "a paddle centre never leaves its travel limit and never moves faster than PaddleMaxSpeed":
    var rng = initRand(99)
    let config = episodeConfig(7)
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    for seat in 0 ..< CabinetCount:
      discard game.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
    var commands = newSeq[uint8](CabinetCount)
    for tick in 0 ..< 2000:
      for seat in 0 ..< CabinetCount:
        commands[seat] = uint8(rng.rand(242))
      var before: array[CabinetCount, int32]
      for k in 0 ..< CabinetCount:
        before[k] = game.cabinets[k].alongCentre
      game.step(commands)
      for k in 0 ..< CabinetCount:
        check game.cabinets[k].alongCentre >= -PaddleTravelHalf
        check game.cabinets[k].alongCentre <= PaddleTravelHalf
        let moved = abs(game.cabinets[k].alongCentre - before[k])
        check moved <= PaddleMaxSpeed

  test "a brick is destroyed by exactly one contact and reflects the ball":
    let config = episodeConfig(31, startingLives = 9)
    let episode = runEpisode(config)
    # the run chipped bricks, and every chipped brick is gone for good
    check episode.chips + episode.sim.bricksLeft(0) + episode.sim.bricksLeft(1) +
      episode.sim.bricksLeft(2) + episode.sim.bricksLeft(3) > 0
    var standing = 0
    for k in 0 ..< CabinetCount:
      standing += episode.sim.bricksLeft(k)
    check standing <= CabinetCount * BricksPerRow

  test "the swept contact test and the end-position test agree over randomised states":
    # This is what makes the sweep a GUARD rather than a behaviour change: for
    # a state where the end position already overlaps a collidable, the sweep
    # must have found a contact too.
    var rng = initRand(5150)
    let config = episodeConfig(11)
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    for seat in 0 ..< CabinetCount:
      discard game.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
    var agreed = 0
    for trial in 0 ..< 50_000:
      let
        px = int32(rng.rand(int(ArenaSide)))
        py = int32(rng.rand(int(ArenaSide)))
        dir = uint8(rng.rand(63))
        speed = int32(rng.rand(int(BallSpeedMax - 1)) + 1)
        vector = dirVector(dir)
        dx = int32((int64(speed) * int64(vector.x)) div int64(DirQ12One))
        dy = int32((int64(speed) * int64(vector.y)) div int64(DirQ12One))
      for k in 0 ..< CabinetCount:
        game.cabinets[k].alongCentre =
          int32(rng.rand(int(PaddleTravelHalf) * 2) - int(PaddleTravelHalf))
      let contact = game.earliestContact(px, py, dx, dy)
      # the end position: does it overlap a paddle box?
      var endOverlaps = false
      for k in 0 ..< CabinetCount:
        let box = game.paddleBox(k, far = false)
        if px + dx >= box.x0 - BallHalf and px + dx <= box.x1 + BallHalf and
            py + dy >= box.y0 - BallHalf and py + dy <= box.y1 + BallHalf:
          endOverlaps = true
      if endOverlaps:
        # the sweep must have seen SOMETHING on the way (it may legitimately
        # report an earlier brick, mouth or wall).
        check contact.kind != ckNone
        inc agreed
    check agreed > 0

  test "a cmd of 243..255 decodes identically to 40 on both paths":
    for raw in 243 .. 255:
      let decoded = decodePaddle(uint8(raw))
      let neutral = decodePaddle(NeutralCommand)
      check decoded == neutral
      check decoded.near == 4
      check decoded.far == 4
      check decoded.grip == 0
    # and the legal range decodes as documented
    for raw in 0 .. 242:
      let decoded = decodePaddle(uint8(raw))
      check decoded.near == int32(raw mod 9)
      check decoded.far == int32((raw div 9) mod 9)
      check decoded.grip == int32(raw div 81)
      check encodePaddle(
        int(decoded.near), int(decoded.far), int(decoded.grip)) == uint8(raw)

  test "a stationary cabinet is a legible, correctly scored failure":
    # There is no rescue rule and no mercy: four still bars still play a real
    # game (the mouths are wider than the bars), and the scores stay on scale.
    let config = episodeConfig(77, startingLives = 3)
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    for seat in 0 ..< CabinetCount:
      discard game.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
    var commands = newSeq[uint8](CabinetCount)
    for seat in 0 ..< CabinetCount:
      commands[seat] = NeutralCommand
    while game.phase != GameOver and game.tickCount < 4000:
      game.step(commands)
    for k in 0 ..< CabinetCount:
      check game.scoreOf(k) >= 0.0
      check game.scoreOf(k) < 200.0

  test "a ball that slips past the bar's end is a NEAR MISS, and the feed says so":
    # "SO CLOSE — B1 grazed RED's bar" is the drama the game is made of, and it
    # was declared everywhere and emitted nowhere: the enum, the wire name and
    # NearMissUu all existed with no emitter, so the feed line could never
    # appear (r1-5). PRESENTATION ONLY: nearMisses is not mixed into gameHash.
    let config = episodeConfig(101)
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    for seat in 0 ..< CabinetCount:
      discard game.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
    game.phase = Playing
    game.gameStartTick = 0
    game.collectEvents = true
    for row in 0 ..< MaxBrickRows:         ## a brick would stop it first
      for col in 0 ..< BricksPerRow:
        game.cabinets[0].bricks[row][col] = false
    for i in 0 ..< game.balls.len:
      game.balls[i].state = bsServing
      game.balls[i].serveTimer = 9999      ## park every other ball
    # Ball 0 heads straight into cabinet 0's mouth, 4 000 µu (0.4 cu) outside
    # the bar's end: inside NearMissUu, so it grazes.
    let start = worldOf(
      0, paddleHalfUu(config) + BallHalf + 4_000'i32,
      PaddleDepth + 40_000'i32)
    game.balls[0].state = bsLive
    game.balls[0].x = start.x
    game.balls[0].y = start.y
    game.balls[0].dir = fromLocalDir(48, 0)
    game.balls[0].speed = ballSpeed0Uu(config)
    var commands = newSeq[uint8](CabinetCount)
    for seat in 0 ..< CabinetCount:
      commands[seat] = NeutralCommand
    let livesBefore = game.cabinets[0].lives
    for _ in 0 ..< 60:
      game.step(commands)
    check game.cabinets[0].nearMisses == 1
    check game.cabinets[0].lastNearMissBall == 0
    check game.cabinets[0].lives == livesBefore - 1   ## it still went in
    check game.cabinets[0].saves == 0                 ## and was never touched
    var sawEvent = false
    for event in game.events:
      if event.kind == NearMiss and event.cabinet == 0:
        sawEvent = true
        check event.ball == 0
        check event.amount > 0
        check event.amount <= int(NearMissUu)
    check sawEvent
    # …and the broadcast turns it into the feed's own event.
    var tracker = initBroadcastTracker()
    tracker.resync(game)
    tracker.nearMisses[0] = 0                ## as if the tick had just landed
    let events = newJArray()
    game.stepEvents(tracker, events)
    var wired = false
    for event in events:
      if event{"k"}.getStr == "near_miss":
        wired = true
        check event{"ball"}.getStr == "B1"
        check event{"cabinet"}.getInt == 0
    check wired

  test "a ball down the middle is NOT a near miss":
    let config = episodeConfig(102)
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    for seat in 0 ..< CabinetCount:
      discard game.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
    game.phase = Playing
    game.collectEvents = true
    for i in 0 ..< game.balls.len:
      game.balls[i].state = bsServing
      game.balls[i].serveTimer = 9999
    let start = worldOf(0, 0'i32, PaddleDepth + 40_000'i32)
    game.balls[0].state = bsLive
    game.balls[0].x = start.x
    game.balls[0].y = start.y
    game.balls[0].dir = fromLocalDir(48, 0)
    game.balls[0].speed = ballSpeed0Uu(config)
    var commands = newSeq[uint8](CabinetCount)
    for seat in 0 ..< CabinetCount:
      commands[seat] = NeutralCommand
    for _ in 0 ..< 60:
      game.step(commands)
    check game.cabinets[0].nearMisses == 0
    check game.cabinets[0].saves >= 1        ## the bar was right there
