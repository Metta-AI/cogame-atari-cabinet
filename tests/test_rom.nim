## The preset machinery, and EVERY variant constructed and stepped — not just
## the certification fixture (collab-cooking 0.1.1, 2026-08-25).

import std/[json, strutils, unittest]
import cabinet/[sim, stances, control, baselines]
import helpers

proc manifest(): JsonNode = parseJson(sourceText("coworld_manifest_template.json"))

suite "rom":
  test "applyPreset obeys defaults -> preset -> explicit, in that order":
    # The cert fixture's own case: rom warlords (3 lives) + startingLives 9
    # resolves to NINE, not three.
    var config = defaultGameConfig()
    config.update("""{"rom":"warlords","startingLives":9}""")
    check config.rom == "warlords"
    check config.startingLives == 9
    check config.brickRows == 1
    check config.catchEnabled
    # …and without the explicit key the preset wins over the default.
    var preset = defaultGameConfig()
    preset.update("""{"rom":"quadrapong"}""")
    check preset.startingLives == 5
    check preset.brickRows == 0
    check not preset.catchEnabled
    check preset.goalHalfCu == 22
    # an explicit key beats the preset in BOTH directions
    var mixed = defaultGameConfig()
    mixed.update("""{"rom":"foozpong","goalHalfCu":22,"catchEnabled":true}""")
    check mixed.farPaddle
    check mixed.goalHalfCu == 22
    check mixed.catchEnabled

  test "each named ROM resolves to exactly its row of the preset table":
    let want = {
      "warlords": (3, 2, 1, true, false, 18, 7, 550),
      "quadrapong": (5, 2, 0, false, false, 22, 6, 650),
      "foozpong": (3, 2, 0, false, true, 18, 6, 600)
    }
    for (name, row) in want:
      var config = defaultGameConfig()
      config.update("""{"rom":"""" & name & """"}""")
      check config.startingLives == row[0]
      check config.ballCount == row[1]
      check config.brickRows == row[2]
      check config.catchEnabled == row[3]
      check config.farPaddle == row[4]
      check config.goalHalfCu == row[5]
      check config.paddleHalfCu == row[6]
      check config.ballSpeed0Milli == row[7]

  test "an unknown rom is refused loudly":
    var config = defaultGameConfig()
    expect CabinetError:
      config.update("""{"rom":"pitfall"}""")
    check not knownRom("pitfall")
    for name in RomNames:
      check knownRom(name)

  test "EVERY manifest variant's game_config constructs and steps 600 ticks with four bulwarks":
    let document = manifest()
    check document["variants"].len == 3
    for variant in document["variants"]:
      var config = defaultGameConfig()
      var node = variant["game_config"]
      node["tokens"] = %["t0", "t1", "t2", "t3"]
      node["startWaitTicks"] = %1
      config.update($node)
      check config.numAgents == CabinetCount
      var game = initSimServer(config)
      game.gameEventLoggingEnabled = false
      for seat in 0 ..< CabinetCount:
        discard game.addPlayer("P" & $(seat + 1), seat, "t" & $seat)
      var
        stances: array[CabinetCount, CabinetStance]
        commands = newSeq[uint8](CabinetCount)
      for seat in 0 ..< CabinetCount:
        stances[seat] = defaultStance()
      for tick in 0 ..< 600:
        if game.phase == Playing and
            game.gameTicksElapsed() mod config.turnTicks == 0:
          for seat in 0 ..< CabinetCount:
            stances[seat] = game.bulwarkStance(game.cabinetOfSeat(seat))
        for cabinet in 0 ..< CabinetCount:
          commands[game.seatOfCabinet(cabinet)] =
            game.paddleCommand(cabinet, stances[game.seatOfCabinet(cabinet)])
        game.step(commands)
      check game.tickCount == 600
      check game.phase in [Playing, GameOver]

  test "the certification fixture's game_config constructs and plays":
    let document = manifest()
    var node = document["certification"]["game_config"]
    node["tokens"] = %["t0", "t1", "t2", "t3"]
    node["startWaitTicks"] = %1
    var config = defaultGameConfig()
    config.update($node)
    check config.rom == "warlords"
    check config.startingLives == 9        ## the explicit key beat the preset
    check config.numAgents == CabinetCount
    check config.maxTicks == 1440
    check config.turnSpacingMs == 0
    let episode = runEpisode(config)
    check episode.sim.phase == GameOver
    check episode.sim.endReason == ReasonComplete
    # 1440 ticks at 24 fps is 60 s of playback: comfortably longer than the
    # viewer smoke's soak, so a finished replay never reads as "frozen".
    check episode.ticks >= 1440

  test "farPaddle false leaves the far nibble with NO observable effect":
    let config = episodeConfig(17, rom = "warlords")
    check not config.farPaddle
    var a = initSimServer(config)
    var b = initSimServer(config)
    a.gameEventLoggingEnabled = false
    b.gameEventLoggingEnabled = false
    for seat in 0 ..< CabinetCount:
      discard a.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
      discard b.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
    var
      plain = newSeq[uint8](CabinetCount)
      farred = newSeq[uint8](CabinetCount)
    for seat in 0 ..< CabinetCount:
      plain[seat] = encodePaddle(5, 4, 0)
      farred[seat] = encodePaddle(5, 8, 0)     ## a full far drive
    for tick in 0 ..< 400:
      a.step(plain)
      b.step(farred)
      check a.gameHash() == b.gameHash()

  test "catchEnabled false makes grip == 1 a no-op":
    let config = episodeConfig(19, rom = "quadrapong")
    check not config.catchEnabled
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    for seat in 0 ..< CabinetCount:
      discard game.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
    var commands = newSeq[uint8](CabinetCount)
    for seat in 0 ..< CabinetCount:
      commands[seat] = encodePaddle(4, 4, 1)
    for tick in 0 ..< 1200:
      game.step(commands)
      for k in 0 ..< CabinetCount:
        check game.cabinets[k].heldBall < 0
        check game.cabinets[k].catches == 0
      for ball in game.balls:
        check ball.state != bsHeld

  test "brickRows 0 removes every brick from the hash and from the state":
    let config = episodeConfig(23, rom = "quadrapong")
    check config.brickRows == 0
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    check game.bricksTotal() == 0
    for k in 0 ..< CabinetCount:
      check game.bricksLeft(k) == 0
      for col in 0 ..< BricksPerRow:
        check game.brickColumnEmpty(k, col)
    let before = game.gameHash()
    # flipping a brick bit that no ROM uses cannot move the hash… because the
    # bits are all false and stay false.
    check game.gameHash() == before
