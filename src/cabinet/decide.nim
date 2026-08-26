## The decision layer: the per-turn loop that asks every ALIVE cabinet's
## policy what its stance is for the next five seconds, and always has an
## answer.
##
## Cadence: one turn every `turnTicks` (120 ticks = 5.0 s of sim time), 24
## turns per episode. At each turn the server builds every alive seat's request
## body and issues them as ONE PARALLEL BATCH — the cabinet is a
## simultaneous-decision game, so querying seats one after another would
## multiply the wall clock for no gain. At most 4 calls per turn x 24 turns =
## 96 calls per episode, at most 4 in flight.
##
## DEGRADE, NEVER HANG. Every wait here is bounded: attempt 1 gets
## `attempt1Ms`, the single retry gets `retryMs`, the inter-batch wall floor is
## a bounded sleep, and the whole turn is wrapped in a monotonic
## `turnBudgetMs` deadline. A provider throttle with no other candidate model
## skips the retry outright (it cannot land). On a second failure the seat
## plays the `bulwark` stance for that turn and a `fallback` record names the
## cause. NO FAILURE MODE LEAVES A PADDLE UNCOMMANDED: the autopilot always
## has a stance — this turn's, else last turn's, else `bulwark`'s.

import std/[json, monotimes, os, strutils, times]
import curly
import sim, stances, baselines, llm, control

type
  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field —
    ## or never registers at all — is `bulwark`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    seats*: seq[SeatPolicy]
    stances*: seq[CabinetStance]
    haveStance*: seq[bool]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool              ## the budget guard fired; scripted from here on
    params*: BaselineParams

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.client = newLlmClient(sim.config)
  result.seats = newSeq[SeatPolicy](CabinetCount)
  result.stances = newSeq[CabinetStance](CabinetCount)
  result.haveStance = newSeq[bool](CabinetCount)
  result.params = DefaultBaselineParams
  for i in 0 ..< result.seats.len:
    result.seats[i].baseline = blBulwark
    result.seats[i].label = "bulwark"
    result.stances[i] = defaultStance()

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isLlm:
    "llm"
  else:
    "scripted"

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
      "arrive_along": newJNull()
    }
    if ball.state == bsLive:
      if predictions[index].firstSide >= 0:
        item["arrive_at"] = %aliasOfCabinet(predictions[index].firstSide)
        item["arrive_in_ticks"] = %predictions[index].firstTick
      let mine = predictions[index].perSide[cabinet]
      if mine.reaches:
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

proc budgetGuardRecord*(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

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

proc scriptedFor*(
  engine: DecisionEngine, sim: SimServer, seat, turn: int
): CabinetStance =
  sim.baselineStance(
    sim.cabinetOfSeat(seat), engine.seats[seat].baseline, turn, engine.params)

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
  let legality = stance.validateStance(
    sim.cabinetOfSeat(seat),
    (block:
      var flags: array[CabinetCount, bool]
      for k in 0 ..< CabinetCount: flags[k] = sim.cabinets[k].isOut
      flags),
    (block:
      var live: seq[bool]
      for ball in sim.balls: live.add(ball.state == bsLive)
      live))
  if legality.len == 0:
    return
  # An illegal field is repaired, never fatal.
  var repaired = engine.bulwarkFor(sim, seat)
  repaired.note = stance.note
  repaired.say = stance.say
  repaired.source = stance.source
  repaired.latencyMs = stance.latencyMs
  stance = repaired

proc turnBatch*(
  engine: DecisionEngine,
  sim: SimServer,
  open: seq[int],
  turnIndex, attempt: int
): RequestBatch =
  ## EVERY open seat's request body, in ONE batch. This is the whole shape of
  ## the decision layer: the cabinet is a simultaneous-decision game, so the
  ## batch goes out through `curly.makeRequests` in one call and seats are
  ## NEVER queried one after another. tests/test_engine.nim asserts the batch
  ## really does carry every alive seat.
  for seat in open:
    var user = engine.seatViewJson(sim, seat, turnIndex)
    if attempt > 0:
      user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
        "the JSON object described above, starting with '{'.")
    let request = engine.client.requestFor(
      SystemPrompt, userMessage(engine.seats[seat].prompt, user))
    result.post(request.url, request.headers, request.body, $seat)

proc turn*(
  engine: var DecisionEngine,
  sim: SimServer,
  turnIndex: int,
  elapsedSeconds: int
): seq[string] =
  ## Runs ONE decision turn and installs every seat's stance. Returns the
  ## replay chat records the turn produced. Never raises: every failure path
  ## ends in a legal stance.
  let budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
  ## `turnStart` is re-taken AFTER the inter-batch rate floor below, because
  ## the floor is a separate, separately-bounded wait: measuring the budget
  ## from before it meant a turn that slept 8 s and then timed out attempt 1 at
  ## 9 s had "spent" 17 s of a 16 s budget and SKIPPED the single retry the
  ## design promises, while a turn that slept 6 s got it. The budget wraps the
  ## CALLS (attempt1Ms + retryMs = 14 000 <= turnBudgetMs = 16 000); the guard's
  ## own per-turn estimate at :360 already adds turnSpacingMs on top.
  var turnStart = getMonoTime()
  ## Throttle state is PER TURN: a 429 on turn k says nothing about turn k+1.
  engine.client.throttled = false

  # --- budget guard: settle EARLY rather than overrun ----------------------
  # If two more full turns (spacing INCLUDED) would not fit inside the
  # engine's own wall-clock stop, switch the LLM off for the rest of the
  # episode and finish on the scripted layer (microseconds per turn), so the
  # episode ends complete/* rather than deadline.
  if not engine.llmOff:
    let turnSeconds =
      (sim.config.turnBudgetMs + sim.config.turnSpacingMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.add(budgetGuardRecord(
        turnIndex, max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "cabinet: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  # --- which seats need a call? -------------------------------------------
  var open: seq[int]
  for seat in 0 ..< min(CabinetCount, engine.seats.len):
    let cabinet = sim.cabinetOfSeat(seat)
    if cabinet < 0 or sim.cabinets[cabinet].isOut:
      # An ELIMINATED seat is dropped from every later batch: its paddle is
      # gone and its byte is ignored.
      engine.stances[seat] = engine.bulwarkFor(sim, seat)
      engine.haveStance[seat] = true
      continue
    if engine.seats[seat].isLlm and not engine.llmOff and
        not engine.client.disabled:
      open.add(seat)
    elif engine.seats[seat].isLlm:
      # An LLM seat that CANNOT call the LLM this turn is a FALLBACK, not a
      # scripted policy, and the design's `fallback.cause` enum names both
      # reasons it happens. Recording it is what makes the two countable.
      var stance = engine.bulwarkFor(sim, seat)
      stance.source = ssFallback
      engine.stances[seat] = stance
      engine.haveStance[seat] = true
      let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
      result.add(fallbackRecord(turnIndex, seat, 1, cause,
        "the LLM is unavailable for this turn; playing bulwark"))
      echo "cabinet llm: seat ", seat, " falling back to bulwark (", cause,
        ") on turn ", turnIndex
    else:
      var stance = engine.scriptedFor(sim, seat, turnIndex)
      stance.source = ssScripted
      engine.stances[seat] = stance
      engine.haveStance[seat] = true

  # --- the rate floor ------------------------------------------------------
  # The Bedrock sidecar caps 30 requests/minute PER EPISODE and four seats per
  # batch sits right on it. Hold the START of consecutive batches
  # `turnSpacingMs` apart, which pins the episode at <= 20 rpm. The cert
  # fixture sets it to 0, so offline runs pay nothing.
  if open.len > 0 and engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true
    turnStart = engine.lastBatchStart

  # --- up to two PARALLEL batches -----------------------------------------
  var
    attempt = 0
    budgetTimedOut = false
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      # No record here: the tail below installs the bulwark stance for every
      # still-open seat and records exactly ONE fallback per seat per turn.
      # Recording again here gave the seat TWO fallback records for one turn,
      # which phase 60 counts.
      budgetTimedOut = true
      break
    let deadlineMs =
      if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
    var batch = engine.turnBatch(sim, open, turnIndex, attempt)
    let started = getMonoTime()
    # curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    # SECONDS and whose conversion FLOORS — which is why sim_config rejects a
    # sub-second value, making this floor an identity (9000 -> 9 s).
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int]
    for position, seat in open:
      var cause = "parse_error"
      try:
        let text = engine.client.textOf(
          responses[position].response, responses[position].error,
          batch[position].url)
        var cabinetOut: array[CabinetCount, bool]
        for k in 0 ..< CabinetCount:
          cabinetOut[k] = sim.cabinets[k].isOut
        var live: seq[bool]
        for ball in sim.balls:
          live.add(ball.state == bsLive)
        var stance = parseCabinetStance(
          extractJsonObject(text), sim.cabinetOfSeat(seat), cabinetOut, live,
          sim.config.catchEnabled, engine.stances[seat],
          engine.haveStance[seat])
        stance.source = ssLlm
        stance.latencyMs = latency
        engine.repairStance(sim, seat, stance)
        engine.stances[seat] = stance
        engine.haveStance[seat] = true
      except CatchableError as error:
        if responses[position].error.len > 0:
          cause = (if "timeout" in responses[position].error.toLowerAscii():
                     "timeout" else: "transport_error")
        elif error.msg.startsWith("llm throttled"):
          ## Name the throttle for what it is: reporting a 429 as
          ## `parse_error` is what made a hosted log unreadable.
          cause = "throttled"
        result.add(fallbackRecord(
          turnIndex, seat, attempt + 1, cause, error.msg))
        echo "cabinet llm: seat ", seat, " attempt ", attempt + 1,
          " failed, falling back if it fails again: ", error.msg
        stillOpen.add(seat)
    open = stillOpen
    inc attempt
    if engine.client.throttled and open.len > 0:
      # FAIL FAST. The only model left answered 429, so the retry batch would
      # be refused the same way: spend the rest of the turn on the scripted
      # layer instead of on a call that cannot land.
      echo "cabinet llm: provider throttled with no other candidate; ",
        open.len, " seat(s) fall back for turn ", turnIndex
      break

  # --- anything still open plays bulwark for this turn --------------------
  for seat in open:
    var stance = engine.bulwarkFor(sim, seat)
    stance.source = ssFallback
    engine.stances[seat] = stance
    engine.haveStance[seat] = true
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif budgetTimedOut: "timeout"
      elif engine.client.throttled: "throttled"
      else: "parse_error"
    result.add(fallbackRecord(turnIndex, seat, 2, cause,
      "seat fell back to the bulwark stance"))
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "cabinet llm: seat ", seat, " falling back to bulwark (", cause,
      ") on turn ", turnIndex
