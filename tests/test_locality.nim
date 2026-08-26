## The two name spaces and the information invariants.
##
## The physics is PUBLIC and the players are NOT. Both halves are asserted:
## the positive half (every ball, every paddle, every brick bit and every
## cabinet's lives really are in the seat's view) and the negative half (no
## other seat's stance, note, say or prompt, no perm, no seed, no RNG state, no
## future serve direction, no wall-clock fact and no real name).

import std/[json, random, strutils, unittest]
import cabinet/[sim, stances, control, baselines, decide, global]
import helpers

suite "locality":
  test "over 200 randomised states a seat's view carries the WHOLE board":
    var rng = initRand(4242)
    for trial in 0 ..< 200:
      let config = episodeConfig(rng.rand(1_000_000), rom = "warlords")
      var game = initSimServer(config)
      game.gameEventLoggingEnabled = false
      for seat in 0 ..< CabinetCount:
        discard game.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
      game.phase = Playing
      game.gameStartTick = 0
      for k in 0 ..< CabinetCount:
        game.cabinets[k].alongCentre =
          int32(rng.rand(int(PaddleTravelHalf) * 2) - int(PaddleTravelHalf))
        game.cabinets[k].lives = int32(rng.rand(3) + 1)
        game.cabinets[k].bricks[0][rng.rand(BricksPerRow - 1)] = false
      for i in 0 ..< game.balls.len:
        game.balls[i].state = bsLive
        game.balls[i].x = int32(rng.rand(int(ArenaSide) - 40_000) + 20_000)
        game.balls[i].y = int32(rng.rand(int(ArenaSide) - 40_000) + 20_000)
        game.balls[i].dir = uint8(rng.rand(63))
      var engine = initDecisionEngine(game)
      let seat = rng.rand(3)
      let view = parseJson(engine.seatViewJson(game, seat, 3))
      # every ball
      check view["balls"].len == game.balls.len
      # every rival, with its lives, bricks and paddle
      check view["rivals"].len == CabinetCount - 1
      for rival in view["rivals"]:
        check rival.hasKey("lives")
        check rival.hasKey("bricks_left")
        check rival.hasKey("paddle_along")
        check rival["alias"].getStr in @CabinetAliases
      # every brick bit of MY castle, and my own paddle
      check view["you"]["bricks"]["cols"].len == BricksPerRow
      check view["you"]["paddle"].hasKey("along")
      check view["you"]["mouth"].hasKey("half")
      check view["rules"]["points"]["per_life_kept"].getFloat > 0.0

  test "a seat's view carries NO other seat's stance, prompt, note or say":
    let config = episodeConfig(7)
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    for seat in 0 ..< CabinetCount:
      discard game.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
    game.phase = Playing
    var engine = initDecisionEngine(game)
    for seat in 0 ..< CabinetCount:
      engine.seats[seat].prompt =
        "SECRET-PROMPT-" & $seat & " never leaves the server"
      engine.seats[seat].isLlm = true
      var stance = defaultStance()
      stance.note = "SECRET-NOTE-" & $seat
      stance.say = "SECRET-SAY-" & $seat
      stance.aimAt = (seat + 1) mod CabinetCount
      engine.stances[seat] = stance
      engine.haveStance[seat] = true
      game.applyStanceRecord(
        boundedStanceRecord(stance, 0, seat, game.cabinetOfSeat(seat)))
    for seat in 0 ..< CabinetCount:
      let view = engine.seatViewJson(game, seat, 1)
      for other in 0 ..< CabinetCount:
        if other == seat:
          continue
        check ("SECRET-NOTE-" & $other) notin view
        check ("SECRET-SAY-" & $other) notin view
        check ("SECRET-PROMPT-" & $other) notin view
      # not even its OWN prompt: the operator block is added by the LLM layer,
      # never by the view.
      check ("SECRET-PROMPT-" & $seat) notin view
      # its own last stance is legitimate; another seat's is not
      let parsed = parseJson(view)
      if parsed["your_last_stance"].kind != JNull:
        check parsed["your_last_stance"].hasKey("stance")

  test "a seat's view carries NO perm, seed, RNG state, future serve or wall clock":
    let config = episodeConfig(987654)
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    for seat in 0 ..< CabinetCount:
      discard game.addPlayer("daveey-real-name-" & $seat, seat, "", trusted = true)
    game.phase = Playing
    var engine = initDecisionEngine(game)
    for seat in 0 ..< CabinetCount:
      let view = engine.seatViewJson(game, seat, 1)
      let parsed = parseJson(view)
      check not parsed.hasKey("perm")
      check not parsed.hasKey("seed")
      check not parsed.hasKey("rng")
      check not parsed.hasKey("rngDraws")
      check "987654" notin view                 ## the seed
      check "perm" notin view
      check $game.rng.s0 notin view
      check $game.rng.s1 notin view
      for other in 0 ..< CabinetCount:
        check ("daveey-real-name-" & $other) notin view
      # no host or wall-clock fact
      for banned in ["wallClock", "wall_clock", "turnBudget", "elapsed_wall",
                     "budget", "latency"]:
        check banned notin view

  test "the board a SEAT is streamed carries no real name":
    let config = episodeConfig(3)
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    for seat in 0 ..< CabinetCount:
      discard game.addPlayer("champion-" & $seat, seat, "", trusted = true)
    game.phase = Playing
    game.warmBoardRenderCaches()
    check not config.showPlayerLabels
    for seat in 0 ..< CabinetCount:
      var state = initPlayerViewerState()
      var next: PlayerViewerState
      let packet = game.buildSpriteProtocolPlayerUpdates(seat, state, next)
      var text = ""
      for value in packet:
        if value >= 32'u8 and value < 127'u8:
          text.add(char(value))
      for other in 0 ..< CabinetCount:
        check ("champion-" & $other) notin text
      # the aliases ARE there: a station on the board is public
      var sawAlias = false
      for alias in CabinetAliases:
        if alias in text:
          sawAlias = true
      check sawAlias

  test "the SPECTATOR side does carry the real names — both, not either":
    let config = episodeConfig(5, maxTicks = 240)
    let episode = runEpisode(config)
    let results = episode.results
    for seat in 0 ..< CabinetCount:
      check results["names"][seat].getStr.len > 0
      check results["aliases"][seat].getStr in @CabinetAliases
      check results["cabinets"][seat].getInt == episode.sim.cabinetOfSeat(seat)

  test "paddleCommand cannot see more than the sim, the cabinet and its stance":
    # A structural assertion: the signature is (SimServer, int, CabinetStance).
    # Anything else — another seat's stance, the wall clock, the RNG — would
    # have to be a new parameter, which this line would stop compiling.
    let signature: proc (sim: SimServer, cabinet: int,
      stance: CabinetStance): uint8 {.nimcall.} = paddleCommand
    check signature != nil
    let config = episodeConfig(6)
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    game.phase = Playing
    # …and it is a PURE function: no memory across calls.
    var stance = defaultStance()
    let a = signature(game, 0, stance)
    let b = signature(game, 0, stance)
    check a == b
