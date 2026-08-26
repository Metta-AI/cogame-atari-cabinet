## The formula, its sign, and the placement chain.

import std/[json, math, random, strutils, unittest]
import cabinet/[sim, baselines]
import helpers

proc scoreFor(
  startingLives, livesLeft: int, crown: bool,
  knockouts, chips, saves: int
): float =
  var micro = (LivesTermMicro * int64(livesLeft)) div int64(startingLives)
  if crown: micro += CrownMicro
  micro += KnockoutMicro * int64(knockouts)
  micro += ChipMicro * int64(chips)
  micro += SaveMicro * int64(saves)
  float(micro) / 1_000_000.0

suite "scoring":
  test "the seven worked examples reproduce to 3 decimals":
    check abs(scoreFor(3, 2, true, 6, 22, 71) - 95.750) < 0.0005
    check abs(scoreFor(3, 2, false, 3, 9, 58) - 65.000) < 0.0005
    check abs(scoreFor(3, 0, false, 2, 6, 40) - 17.000) < 0.0005
    check abs(scoreFor(3, 0, false, 0, 1, 12) - 3.500) < 0.0005
    check abs(scoreFor(3, 3, true, 1, 4, 63) - 94.750) < 0.0005
    check abs(scoreFor(3, 0, false, 0, 0, 4) - 1.000) < 0.0005
    check abs(scoreFor(5, 0, false, 4, 0, 21) - 13.250) < 0.0005

  test "the lives term is exactly 60 x livesLeft / startingLives with no drift":
    for startingLives in [3, 5, 9]:
      for livesLeft in 0 .. startingLives:
        let micro = (LivesTermMicro * int64(livesLeft)) div int64(startingLives)
        check micro >= 0
        check micro <= LivesTermMicro
        # full lives is exactly the whole term, whatever the ROM
        if livesLeft == startingLives:
          check micro == LivesTermMicro

  test "no term is negative and no score is ever below 0.000":
    for romName in ["warlords", "quadrapong", "foozpong"]:
      let config = episodeConfig(88, rom = romName, maxTicks = 960)
      let episode = runEpisode(config)
      for k in 0 ..< CabinetCount:
        check episode.sim.cabinets[k].scoreMicro >= 0
        check episode.sim.scoreOf(k) >= 0.0
      for value in episode.results["scores"]:
        check value.getFloat >= 0.0

  test "a knockout is credited to lastTouch, never to the conceder":
    let config = episodeConfig(4242, startingLives = 3)
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    for seat in 0 ..< CabinetCount:
      discard game.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
    game.phase = Playing
    game.balls[0].state = bsLive
    game.balls[0].lastTouch = 1
    let before = game.cabinets[1].knockouts
    game.concede(0, 0)
    check game.cabinets[1].knockouts == before + 1
    check game.cabinets[0].knockouts == 0
    check game.cabinets[0].concedes == 1
    check game.cabinets[0].lives == int32(config.startingLives - 1)
    # a ball nobody touched credits nobody
    game.balls[1].state = bsLive
    game.balls[1].lastTouch = -1
    game.concede(2, 1)
    for k in 0 ..< CabinetCount:
      check game.cabinets[k].knockouts <= 1

  test "a cabinet chipping its OWN brick scores nothing":
    let config = episodeConfig(5, startingLives = 3)
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    game.phase = Playing
    # aim a ball at cabinet 0's own brick with lastTouch = 0
    let box = brickBox(0, 0, 4)
    game.balls[0].state = bsLive
    game.balls[0].lastTouch = 0
    game.balls[0].x = (box.x0 + box.x1) div 2
    game.balls[0].y = box.y1 + BallHalf + 4_000
    game.balls[0].dir = fromLocalDir(48, 0)
    game.balls[0].speed = ballSpeed0Uu(config)
    var commands = newSeq[uint8](CabinetCount)
    for seat in 0 ..< CabinetCount:
      commands[seat] = NeutralCommand
    for tick in 0 ..< 12:
      game.step(commands)
    check game.cabinets[0].chips == 0

  test "the placement chain is total over 20 000 randomised end states":
    var rng = initRand(31415)
    let config = episodeConfig(6)
    for trial in 0 ..< 20_000:
      var game = initSimServer(config)
      game.gameEventLoggingEnabled = false
      for k in 0 ..< CabinetCount:
        game.cabinets[k].lives = int32(rng.rand(3))
        game.cabinets[k].isOut = game.cabinets[k].lives == 0
        game.cabinets[k].outTick =
          if game.cabinets[k].isOut: int32(rng.rand(2880)) else: -1
        game.cabinets[k].saves = int32(rng.rand(80))
        game.cabinets[k].knockouts = int32(rng.rand(6))
      game.finishGame(ReasonComplete, EndRuleFullTime)
      var seen: array[CabinetCount + 1, int]
      var crowns = 0
      for k in 0 ..< CabinetCount:
        let place = int(game.cabinets[k].placement)
        check place >= 1 and place <= CabinetCount
        inc seen[place]
        if place == 1:
          inc crowns
      check crowns == 1
      for place in 1 .. CabinetCount:
        check seen[place] == 1
      # a cabinet with lives always outranks one without
      for a in 0 ..< CabinetCount:
        for b in 0 ..< CabinetCount:
          if game.cabinets[a].lives > 0 and game.cabinets[b].lives == 0:
            check game.cabinets[a].placement < game.cabinets[b].placement

  test "win[s] == (placements[s] == 1) in the emitted results":
    let config = episodeConfig(4242, startingLives = 3, maxTicks = 960)
    let episode = runEpisode(config)
    let results = episode.results
    var crowns = 0
    for seat in 0 ..< CabinetCount:
      let
        won = results["win"][seat].getBool
        place = results["placements"][seat].getInt
      check won == (place == 1)
      if won:
        inc crowns
    check crowns == 1

  test "an elimination ends the episode iff exactly one cabinet still has lives":
    let config = episodeConfig(11, startingLives = 1, maxTicks = 2880)
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    for seat in 0 ..< CabinetCount:
      discard game.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
    game.phase = Playing
    game.gameStartTick = 0
    var commands = newSeq[uint8](CabinetCount)
    for seat in 0 ..< CabinetCount:
      commands[seat] = NeutralCommand
    # knock three cabinets out by hand; the fourth must end it
    for k in [0, 1, 2]:
      game.balls[0].state = bsLive
      game.balls[0].lastTouch = 3
      game.concede(k, 0)
      check game.cabinets[k].isOut
    check game.aliveCabinets() == 1
    game.step(commands)
    check game.phase == GameOver
    check game.endReason == ReasonComplete
    check game.endRule == EndRuleLastStanding
    check game.winnerCabinet == 3

  test "the lives term makes the three ROMs comparable to within 4 percent":
    # 0 … max achievable is what the normalisation exists for.
    for startingLives in [3, 5]:
      let best = scoreFor(startingLives, startingLives, true, 6, 27, 90)
      check best > 100.0
      check best < 130.0
