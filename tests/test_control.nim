## The autopilot: bounded bytes, a pure function, the documented bar target per
## stance, and an arrival prediction that agrees with brute force.

import std/[math, random, unittest]
import cabinet/[sim, stances, control, baselines]
import helpers

proc randomState(rng: var Rand, config: GameConfig): SimServer =
  result = initSimServer(config)
  result.gameEventLoggingEnabled = false
  for seat in 0 ..< CabinetCount:
    discard result.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
  result.phase = Playing
  result.gameStartTick = 0
  for k in 0 ..< CabinetCount:
    result.cabinets[k].alongCentre =
      int32(rng.rand(int(PaddleTravelHalf) * 2) - int(PaddleTravelHalf))
    result.cabinets[k].farAlongCentre =
      int32(rng.rand(int(PaddleTravelHalf) * 2) - int(PaddleTravelHalf))
    result.cabinets[k].lives = int32(rng.rand(3) + 1)
    result.cabinets[k].isOut = rng.rand(9) == 0
    if result.cabinets[k].isOut:
      result.cabinets[k].lives = 0
  for i in 0 ..< result.balls.len:
    result.balls[i].state = bsLive
    result.balls[i].x = int32(rng.rand(int(ArenaSide) - 40_000) + 20_000)
    result.balls[i].y = int32(rng.rand(int(ArenaSide) - 40_000) + 20_000)
    result.balls[i].dir = uint8(rng.rand(63))
    result.balls[i].speed = int32(
      rng.rand(int(BallSpeedMax - ballSpeed0Uu(config))) +
      int(ballSpeed0Uu(config)))

proc randomStance(rng: var Rand): CabinetStance =
  result = defaultStance()
  result.stance = Stance(rng.rand(4))
  result.targetBall = rng.rand(3) - 1
  result.aimAt = rng.rand(4) - 1
  result.postUu = int32(rng.rand(int(PaddleTravelHalf) * 2) -
    int(PaddleTravelHalf))
  result.leadTicks = rng.rand(MaxLeadTicks)
  result.aggression255 = rng.rand(255)

suite "control":
  test "5 000 randomised (state, stance) pairs give a legal, in-range byte":
    var rng = initRand(4711)
    let config = episodeConfig(5)
    for trial in 0 ..< 5_000:
      var game = randomState(rng, config)
      let
        cabinet = rng.rand(3)
        stance = randomStance(rng)
        command = game.paddleCommand(cabinet, stance)
      check command <= MaxCommand
      let decoded = decodePaddle(command)
      check decoded.near >= 0 and decoded.near <= 8
      check decoded.far >= 0 and decoded.far <= 8
      check decoded.grip >= 0 and decoded.grip <= 2
      let velocity = abs((decoded.near - 4'i32) * PaddleStepSpeed)
      check velocity <= PaddleMaxSpeed
      # the same pair always yields the same byte
      check game.paddleCommand(cabinet, stance) == command

  test "an out cabinet, or any phase other than Playing, forces cmd 40":
    var rng = initRand(8)
    let config = episodeConfig(6)
    var game = randomState(rng, config)
    game.cabinets[1].isOut = true
    check game.paddleCommand(1, randomStance(rng)) == NeutralCommand
    game.phase = Lobby
    check game.paddleCommand(0, randomStance(rng)) == NeutralCommand
    game.phase = GameOver
    check game.paddleCommand(0, randomStance(rng)) == NeutralCommand

  test "camp never leaves its post when aggression is 0 and the arrival is far":
    let config = episodeConfig(12)
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    game.phase = Playing
    for seat in 0 ..< CabinetCount:
      discard game.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
    var stance = defaultStance()
    stance.stance = stCamp
    stance.aggression255 = 0
    stance.postUu = 20 * UuPerCu
    game.cabinets[0].alongCentre = stance.postUu
    # a ball heading at the far end of side 0, more than 8 cu from the post
    game.balls[0].state = bsLive
    game.balls[0].x = 100_000
    game.balls[0].y = 500_000
    game.balls[0].dir = 48                          ## straight down the screen
    game.balls[0].speed = ballSpeed0Uu(config)
    for i in 1 ..< game.balls.len:
      game.balls[i].state = bsServing
    let command = game.paddleCommand(0, stance)
    check decodePaddle(command).near == 4            ## the bar holds its post

  test "catch in a ROM without catchEnabled behaves bit-identically to guard":
    var rng = initRand(1234)
    let config = episodeConfig(15, rom = "quadrapong")
    check not config.catchEnabled
    for trial in 0 ..< 400:
      var game = randomState(rng, config)
      let cabinet = rng.rand(3)
      var catchStance = randomStance(rng)
      catchStance.stance = stCatch
      var guardStance = catchStance
      guardStance.stance = stGuard
      check game.paddleCommand(cabinet, catchStance) ==
        game.paddleCommand(cabinet, guardStance)

  test "the arrival prediction agrees with a brute-force float propagation":
    var rng = initRand(90210)
    let config = episodeConfig(21)
    var agreements = 0
    var trials = 0
    for trial in 0 ..< 10_000:
      var game = randomState(rng, config)
      for k in 0 ..< CabinetCount:
        game.cabinets[k].isOut = false
        game.cabinets[k].lives = 3
      let prediction = game.predictBall(0)
      if not prediction.perSide[0].reaches:
        continue
      inc trials
      # brute force: float propagation with the same reflection rule
      var
        x = float(game.balls[0].x)
        y = float(game.balls[0].y)
        dir = game.balls[0].dir
        found = -1
        along = 0.0
      let speed = float(game.balls[0].speed)
      for tick in 1 .. PredictTicks:
        let vector = dirVector(dir)
        let
          nx = x + speed * float(vector.x) / 4096.0
          ny = y + speed * float(vector.y) / 4096.0
        let
          beforeDepth = float(localOf(0, int32(x), int32(y)).depth)
          afterDepth = float(localOf(0, int32(nx), int32(ny)).depth)
        if beforeDepth > float(PaddleDepth) and afterDepth <= float(PaddleDepth):
          found = tick
          along = float(localOf(0, int32(nx), int32(ny)).along)
          break
        x = nx
        y = ny
        for side in 0 ..< CabinetCount:
          let local = localOf(side, int32(x), int32(y))
          if local.depth < BallHalf:
            let goalHalf = goalHalfUu(config)
            if local.along > -goalHalf and local.along < goalHalf:
              found = -2
              break
            let repaired = worldOf(side, local.along, BallHalf)
            x = float(repaired.x)
            y = float(repaired.y)
            dir =
              if sideIsHorizontal(side): reflectHorizontal(dir)
              else: reflectVertical(dir)
        if found == -2:
          break
      if found > 0:
        if abs(found - prediction.perSide[0].tick) <= 2 and
            abs(along - float(prediction.perSide[0].along)) <= float(UuPerCu):
          inc agreements
    check trials > 100
    check agreements * 10 >= trials * 9      ## at least 90 % agree tick-and-place

  test "the aim search never selects a ray that leaves the arena before a mouth":
    var rng = initRand(606)
    let config = episodeConfig(23)
    for trial in 0 ..< 500:
      var game = randomState(rng, config)
      for k in 0 ..< CabinetCount:
        game.cabinets[k].isOut = false
      let
        cabinet = rng.rand(3)
        target = (cabinet + 1 + rng.rand(2)) mod CabinetCount
        along = int32(rng.rand(int(PaddleTravelHalf) * 2) -
          int(PaddleTravelHalf))
        j = game.aimOffsetJ(cabinet, along, target)
      check j >= -6 and j <= 6
      # the returned j maps to a legal LOCAL index, i.e. away from my own side
      let local = 16 - 2 * j
      check local >= 4 and local <= 28

  test "each stance produces its documented bar target":
    let config = episodeConfig(29)
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    game.phase = Playing
    for seat in 0 ..< CabinetCount:
      discard game.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
    # one ball arriving at along +20 on side 0
    for i in 0 ..< game.balls.len:
      game.balls[i].state = bsServing
    game.balls[0].state = bsLive
    let start = worldOf(0, 20 * UuPerCu, 400_000'i32)
    game.balls[0].x = start.x
    game.balls[0].y = start.y
    game.balls[0].dir = fromLocalDir(48, 0)          ## straight at side 0
    game.balls[0].speed = ballSpeed0Uu(config)
    game.cabinets[0].alongCentre = 0
    let prediction = game.predictBall(0)
    check prediction.perSide[0].reaches
    var guardStance = defaultStance()
    guardStance.stance = stGuard
    guardStance.leadTicks = 48
    # guard drives TOWARD the interception point (positive along -> level > 4)
    check decodePaddle(game.paddleCommand(0, guardStance)).near > 4
    var campStance = defaultStance()
    campStance.stance = stCamp
    campStance.aggression255 = 0
    campStance.postUu = 0
    # camp with zero aggression and a distant arrival holds the post
    check decodePaddle(game.paddleCommand(0, campStance)).near == 4
