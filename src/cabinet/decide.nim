## General seat observations, order validation, and bounded game fallback.
import std/json
import sim, stances, baselines, control

type
  SeatPolicy* = object
    ## Public policy attribution only; strategy lives in the player.
    kind*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    seats*: seq[SeatPolicy]
    stances*: seq[CabinetStance]
    haveStance*: seq[bool]
    params*: BaselineParams

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.seats = newSeq[SeatPolicy](CabinetCount)
  result.stances = newSeq[CabinetStance](CabinetCount)
  result.haveStance = newSeq[bool](CabinetCount)
  result.params = DefaultBaselineParams
  for i in 0 ..< result.seats.len:
    result.seats[i].baseline = blBulwark
    result.seats[i].label = "bulwark"
    result.stances[i] = defaultStance()

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if engine.seats[seat].registered: engine.seats[seat].kind else: "fallback"

# ---------------------------------------------------------------------------
#  The per-seat board view
# ---------------------------------------------------------------------------

proc round2(value: float): float =
  ## Every number shown to a policy is rounded to 2 decimals.
  float(int(value * 100.0 + (if value >= 0: 0.5 else: -0.5))) / 100.0

proc cabinetXY(x, y: int32): array[2, float] =
  ## World µu (y down) -> CABINET coordinates: 0..100 from the bottom-left
  ## corner, x right, y up. The only coordinates a policy ever sees.
  [round2(float(x) / float(UuPerCu)),
   round2(float(ArenaSide - y) / float(UuPerCu))]

proc seatViewJson*(
  engine: DecisionEngine, sim: SimServer, seat, turnIndex: int
): string =
  ## Everything this seat may legitimately know. The physics is PUBLIC — every
  ## ball, every paddle, every brick bit, every cabinet's lives — and the
  ## PLAYERS are not: no other seat's stance, note, say, prompt, latency or
  ## policy label, no `perm`, no seed, no RNG state, no future serve direction,
  ## no wall-clock or budget fact, and no real name anywhere
  ## (tests/test_locality.nim asserts both halves).
  let
    cabinet = sim.cabinetOfSeat(seat)
    cab = sim.cabinets[cabinet]
    goalHalf = float(goalHalfUu(sim.config)) / float(UuPerCu)
    ticksLeft = max(0, sim.gameStartTick + sim.config.maxTicks - sim.tickCount)
  var predictions: seq[BallPrediction]
  for index in 0 ..< sim.balls.len:
    predictions.add(sim.predictBall(index))

  var cols = newJArray()
  for col in 0 ..< BricksPerRow:
    cols.add(%(not sim.brickColumnEmpty(cabinet, col)))

  var you = %*{
    "alias": aliasOfCabinet(cabinet),
    "side": sideNameOfCabinet(cabinet),
    "lives": int(cab.lives),
    "out": cab.isOut,
    "paddle": {
      "along": round2(float(cab.alongCentre) / float(UuPerCu)),
      "vel": round2(float(cab.paddleVel) / float(UuPerCu)),
      "half": round2(float(paddleHalfUu(sim.config)) / float(UuPerCu)),
      "depth": round2(float(PaddleDepth) / float(UuPerCu)),
      "travel_half": round2(float(PaddleTravelHalf) / float(UuPerCu))
    },
    "far_paddle": newJNull(),
    "holding":
      (if cab.heldBall >= 0: %ballId(int(cab.heldBall)) else: newJNull()),
    "mouth": {"half": round2(goalHalf), "open": not cab.isOut},
    "bricks": {
      "left": sim.bricksRemaining(cabinet),
      "of": sim.bricksTotal(),
      "cols": cols
    },
    "score": sim.scoreOf(cabinet)
  }
  if sim.config.farPaddle:
    you["far_paddle"] = %*{
      "along": round2(float(cab.farAlongCentre) / float(UuPerCu)),
      "vel": round2(float(cab.farPaddleVel) / float(UuPerCu)),
      "half": round2(float(farPaddleHalfUu(sim.config)) / float(UuPerCu)),
      "depth": round2(float(FarPaddleDepth) / float(UuPerCu))
    }

  var balls = newJArray()
  for index in 0 ..< sim.balls.len:
    let ball = sim.balls[index]
    let vector = dirVector(ball.dir)
    var item = %*{
      "id": ballId(index),
      "state": $ball.state,
      "pos": cabinetXY(ball.x, ball.y),
      "vel": [
        round2(float(ball.speed) * float(vector.x) /
          (float(DirQ12One) * float(UuPerCu))),
        round2(-float(ball.speed) * float(vector.y) /
          (float(DirQ12One) * float(UuPerCu)))
      ],
      "speed": round2(float(ball.speed) / float(UuPerCu)),
      "deg": round2(float(int(ball.dir)) * 5.625),
      "last_touch":
        (if ball.lastTouch >= 0: %aliasOfCabinet(int(ball.lastTouch))
         else: newJNull()),
      "held_by":
        (if ball.heldBy >= 0: %aliasOfCabinet(int(ball.heldBy))
         else: newJNull()),
      "arrive_at": newJNull(),
      "arrive_in_ticks": newJNull(),
      "arrive_along": newJNull(),
      "arrive_in_ticks_for_you": newJNull()
    }
    if ball.state == bsLive:
      if predictions[index].firstSide >= 0:
        item["arrive_at"] = %aliasOfCabinet(predictions[index].firstSide)
        item["arrive_in_ticks"] = %predictions[index].firstTick
      let mine = predictions[index].perSide[cabinet]
      if mine.reaches:
        item["arrive_in_ticks_for_you"] = %mine.tick
        item["arrive_along"] = %round2(float(mine.along) / float(UuPerCu))
    balls.add(item)

  var rivals = newJArray()
  for k in 0 ..< CabinetCount:
    if k == cabinet:
      continue
    rivals.add(%*{
      "alias": aliasOfCabinet(k),
      "side": sideNameOfCabinet(k),
      "lives": int(sim.cabinets[k].lives),
      "out": sim.cabinets[k].isOut,
      "bricks_left": sim.bricksRemaining(k),
      "paddle_along":
        (if sim.cabinets[k].isOut: newJNull()
         else: %round2(float(sim.cabinets[k].alongCentre) / float(UuPerCu))),
      "score": sim.scoreOf(k)
    })

  var node = %*{
    "turn": turnIndex,
    "of": sim.turnsPerEpisode(),
    "clock": {
      "tick": sim.gameTicksElapsed(),
      "of": sim.config.maxTicks,
      "left_s": round2(float(ticksLeft) / float(TargetFps))
    },
    "rom": sim.config.rom,
    "you": you,
    "balls": balls,
    "rivals": rivals,
    "neighbours": {
      "plus_along": aliasOfCabinet((cabinet + 1) mod CabinetCount),
      "minus_along": aliasOfCabinet((cabinet + 3) mod CabinetCount)
    },
    "rules": {
      "starting_lives": sim.config.startingLives,
      "ball_count": sim.balls.len,
      "brick_rows": sim.config.brickRows,
      "catch_enabled": sim.config.catchEnabled,
      "far_paddle": sim.config.farPaddle,
      "points": {
        "per_life_kept":
          round2(float(LivesTermMicro) /
            (1_000_000.0 * float(max(1, sim.config.startingLives)))),
        "crown": float(CrownMicro) / 1_000_000.0,
        "knockout": float(KnockoutMicro) / 1_000_000.0,
        "chip": float(ChipMicro) / 1_000_000.0,
        "save": float(SaveMicro) / 1_000_000.0
      },
      "note": "the last cabinet with lives standing wins; nothing is ever " &
        "subtracted"
    }
  }
  if seat < engine.haveStance.len and engine.haveStance[seat]:
    let previous = engine.stances[seat]
    node["your_last_stance"] = %*{
      "stance": $previous.stance,
      "target_ball":
        (if previous.targetBall < 0: "any" else: ballId(previous.targetBall)),
      "aim_at":
        (if previous.aimAt < 0: "none" else: aliasOfCabinet(previous.aimAt)),
      "post": round2(previous.postCu()),
      "lead_ticks": previous.leadTicks,
      "aggression": round2(previous.aggressionFraction())
    }
  else:
    node["your_last_stance"] = newJNull()
  $node

# ---------------------------------------------------------------------------
#  Records
# ---------------------------------------------------------------------------

proc registerRecord*(
  seat, cabinet: int, policy, kind, baseline: string
): string =
  ## The REDACTED registration record. The seat's PROMPT is never written:
  ## only the policy label, the kind, and which baseline a scripted seat
  ## picked.
  $(%*{
    "k": "register",
    "seat": seat,
    "alias": aliasOfCabinet(cabinet),
    "cabinet": cabinet,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc fallbackRecord*(
  turn, seat, attempt: int, cause, detail: string
): string =
  $(%*{
    "k": "fallback",
    "turn": turn,
    "seat": seat,
    "attempt": attempt,
    "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc resultRecord*(sim: SimServer): string =
  ## The `result` control record — the episode's whole results document,
  ## written once into the replay chat stream at episode end. It is what makes
  ## the replay SELF-SUFFICIENT: without it the outcome exists only at
  ## COGAME_RESULTS_URI and `replay_summary.py`'s `results` reads `{}` for a
  ## spectator holding the bytes. The document is already valid JSON, so it is
  ## embedded verbatim rather than re-parsed: nothing on the path to the
  ## artifact writes may raise.
  "{\"k\":\"result\",\"results\":" & sim.playerResultsJson() & "}"

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

proc bulwarkFor*(
  engine: DecisionEngine, sim: SimServer, seat: int
): CabinetStance =
  ## The published `bulwark` stance — the per-turn fallback for any seat.
  sim.bulwarkStance(sim.cabinetOfSeat(seat), engine.params)

proc repairStance*(
  engine: DecisionEngine, sim: SimServer, seat: int,
  stance: var CabinetStance
) =
  ## A field the model left out keeps LAST turn's value, else `bulwark`'s. The
  ## parser already defaults each field; this is the second half of the rule —
  ## a policy that named three fields meant the fourth to carry on.
  ##
  ## The repair is PER FIELD. Discarding a whole stance because one field was
  ## illegal threw away four legal decisions to fix one: a reply that named a
  ## ball that had just been conceded lost its stance, its post, its lead and
  ## its aggression too, and the seat played bulwark for the turn while the
  ## record said otherwise.
  let cabinet = sim.cabinetOfSeat(seat)
  var
    cabinetOut: array[CabinetCount, bool]
    ballLive: seq[bool]
  for k in 0 ..< CabinetCount:
    cabinetOut[k] = sim.cabinets[k].isOut
  for ball in sim.balls:
    ballLive.add(ball.state == bsLive)
  if stance.validateStance(cabinet, cabinetOut, ballLive).len == 0:
    return
  let fallback = engine.bulwarkFor(sim, seat)
  # The caps and the bounds are CLAMPED, which is what the parser does with an
  # out-of-range number and what keeps "post hard right" meaning that…
  stance.note = stance.note.truncateRunes(MaxNoteRunes)
  stance.say = stance.say.truncateRunes(MaxSayRunes)
  stance.postUu = clamp(stance.postUu, -PaddleTravelHalf, PaddleTravelHalf)
  stance.leadTicks = clamp(stance.leadTicks, 0, MaxLeadTicks)
  stance.aggression255 = clamp(stance.aggression255, 0, 255)
  # …while a REFERENCE to something that is not there any more (a ball that is
  # not live, my own cabinet, a cabinet that is out) has no legal
  # interpretation, so that field alone takes bulwark's.
  if stance.targetBall >= 0 and
      (stance.targetBall >= ballLive.len or not ballLive[stance.targetBall]):
    stance.targetBall = fallback.targetBall
  if stance.aimAt >= 0 and
      (stance.aimAt == cabinet or stance.aimAt >= CabinetCount or
       cabinetOut[stance.aimAt]):
    stance.aimAt = fallback.aimAt
  # validateStance is the authority on legality and this repair enumerates its
  # rules by hand; if the two ever drift, the seat still plays something legal.
  if stance.validateStance(cabinet, cabinetOut, ballLive).len > 0:
    var repaired = fallback
    repaired.note = stance.note
    repaired.say = stance.say
    repaired.source = stance.source
    repaired.latencyMs = stance.latencyMs
    stance = repaired

proc acceptOrders*(
  engine: var DecisionEngine, sim: SimServer, seat, turnIndex: int,
  text: string
): bool =
  ## Reject stale/malformed orders; the common deadline supplies fallback.
  try:
    let node = parseJson(text)
    if node.kind != JObject or node{"type"}.getStr() != "orders" or
        node{"turn"}.getInt(-1) != turnIndex:
      return false
    var cabinetOut: array[CabinetCount, bool]
    for cabinet in 0 ..< CabinetCount:
      cabinetOut[cabinet] = sim.cabinets[cabinet].isOut
    var live: seq[bool]
    for ball in sim.balls:
      live.add(ball.state == bsLive)
    var stance = parseCabinetStance(
      node["action"], sim.cabinetOfSeat(seat), cabinetOut, live,
      sim.config.catchEnabled, engine.stances[seat], engine.haveStance[seat])
    stance.source = ssExternal
    engine.repairStance(sim, seat, stance)
    engine.stances[seat] = stance
    engine.haveStance[seat] = true
    result = true
  except CatchableError:
    result = false

proc fallback*(engine: var DecisionEngine, sim: SimServer, seat: int) =
  var stance = engine.bulwarkFor(sim, seat)
  stance.source = ssFallback
  engine.stances[seat] = stance
  engine.haveStance[seat] = true
