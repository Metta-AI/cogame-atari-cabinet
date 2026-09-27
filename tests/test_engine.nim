import std/[json, unittest]
import cabinet/[sim, stances, control, baselines, decide, server]
import helpers

proc playingGame(config: GameConfig): SimServer =
  result = initSimServer(config)
  result.gameEventLoggingEnabled = false
  for seat in 0 ..< CabinetCount:
    discard result.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
  result.phase = Playing
  result.gameStartTick = 0

suite "ordinary player orders":
  test "complete orders are applied, malformed and stale orders are rejected":
    let game = playingGame(episodeConfig(7))
    var engine = initDecisionEngine(game)
    let action = %*{"stance": "camp", "post": 17, "lead_ticks": 3,
      "aggression": 0.2, "target_ball": "any", "aim_at": "none",
      "note": "private decision", "say": "ready"}
    check not engine.acceptOrders(game, 0, 2, "not JSON")
    check not engine.acceptOrders(game, 0, 2, $(%*{"type": "orders", "turn": 1, "action": action}))
    check not engine.haveStance[0]
    check engine.acceptOrders(game, 0, 2, $(%*{"type": "orders", "turn": 2, "action": action}))
    check engine.haveStance[0]
    check engine.stances[0].stance == stCamp
    check engine.stances[0].postUu == 17 * UuPerCu
    check engine.stances[0].leadTicks == 3
    check engine.stances[0].source == ssExternal
    check not engine.haveStance[1]

  test "game fallback installs the native legal baseline without a provider":
    let game = playingGame(episodeConfig(19))
    var engine = initDecisionEngine(game)
    engine.fallback(game, 1)
    var expected = game.bulwarkStance(game.cabinetOfSeat(1))
    expected.source = ssFallback
    check engine.stances[1] == expected
    check engine.haveStance[1]

  test "the wall-clock stop yields deadline/wall_clock and still scores the board":
    let config = episodeConfig(10)
    var game = playingGame(config)
    var commands = newSeq[uint8](CabinetCount)
    for seat in 0 ..< CabinetCount:
      commands[seat] = NeutralCommand
    for tick in 0 ..< 300:
      game.step(commands)
    game.stopForWallClock()
    check game.phase == GameOver
    check game.endReason == ReasonDeadline
    check game.endRule == EndRuleWallClock
    check game.winnerCabinet >= 0
    var crowns = 0
    for k in 0 ..< CabinetCount:
      if game.cabinets[k].placement == 1:
        inc crowns
    check crowns == 1

  test "a tripped invariant yields fault/sim_fault":
    let config = episodeConfig(11)
    var game = playingGame(config)
    game.faultGame(EndRuleSimFault)
    check game.phase == GameOver
    check game.endReason == ReasonFault
    check game.endRule == EndRuleSimFault
    let document = parseJson(game.playerResultsJson())
    check document["reason"].getStr == ReasonFault
    check document["endRule"].getStr == EndRuleSimFault
    check document["scores"].len == CabinetCount

  test "ONE illegal field is repaired, the rest of the stance survives":
    # A reply that names a ball which was conceded a tick ago used to lose its
    # stance, its post, its lead and its aggression as well: the whole stance
    # was replaced with bulwark's and only note/say/source/latency were kept
    # (r1-9). The note's rule is per FIELD.
    let config = episodeConfig(14)
    var game = playingGame(config)
    var engine = initDecisionEngine(game)
    let cabinet = game.cabinetOfSeat(0)
    game.balls[1].state = bsServing            ## B2 is not live any more
    var stance = defaultStance()
    stance.stance = stCamp
    stance.postUu = PaddleTravelHalf
    stance.leadTicks = 3
    stance.aggression255 = 17
    stance.note = "hold the post"
    stance.say = "camping"
    stance.source = ssExternal
    stance.targetBall = 1                      ## the ONE illegal field
    stance.aimAt = (cabinet + 1) mod CabinetCount
    engine.repairStance(game, 0, stance)
    check stance.stance == stCamp              ## kept
    check stance.postUu == PaddleTravelHalf    ## kept
    check stance.leadTicks == 3                ## kept
    check stance.aggression255 == 17           ## kept
    check stance.aimAt == (cabinet + 1) mod CabinetCount
    check stance.note == "hold the post"
    check stance.say == "camping"
    check stance.source == ssExternal
    check stance.targetBall != 1               ## repaired
    var cabinetOut: array[CabinetCount, bool]
    var ballLive: seq[bool]
    for k in 0 ..< CabinetCount:
      cabinetOut[k] = game.cabinets[k].isOut
    for ball in game.balls:
      ballLive.add(ball.state == bsLive)
    check stance.validateStance(cabinet, cabinetOut, ballLive) == ""

  test "an out-of-range number is CLAMPED, and aim_at at myself takes bulwark's":
    let config = episodeConfig(15)
    var game = playingGame(config)
    var engine = initDecisionEngine(game)
    let cabinet = game.cabinetOfSeat(1)
    var stance = defaultStance()
    stance.stance = stAim
    stance.postUu = PaddleTravelHalf * 4       ## illegal
    stance.leadTicks = 900                     ## illegal
    stance.aggression255 = -3                  ## illegal
    stance.aimAt = cabinet                     ## illegal: my own cabinet
    engine.repairStance(game, 1, stance)
    check stance.stance == stAim
    check stance.postUu == PaddleTravelHalf
    check stance.leadTicks == MaxLeadTicks
    check stance.aggression255 == 0
    check stance.aimAt != cabinet

  test "parseRegistration reads the seat's ONE message and drops anything else":
    check parseRegistration("""{"type":"register","kind":"prompt","policy":"x"}""").ok
    check parseRegistration(
      """{"type":"register","kind":"scripted","scripted":"spinner"}""").scripted ==
      "spinner"
    check not parseRegistration("""{"type":"chat","text":"hi"}""").ok
    check not parseRegistration("hello").ok
    check not parseRegistration("").ok
    check parseBaseline("spinner") == blSpinner
    check parseBaseline("bulwark") == blBulwark
    check parseBaseline("") == blBulwark
    check parseBaseline("nonsense") == blBulwark
