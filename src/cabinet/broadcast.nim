## The broadcast channel: state deltas -> the events the chrome tells its story
## with, and the ONE state JSON the viewer reads.
##
## `stepEvents` derives its events from state deltas during playback, so they
## cost no replay bytes and are identical live and in replay. `buildStateJson`
## keeps the STARTER'S KEY NAMES above the fold (`t, mt, ph, lob, pl, sp, mx,
## st, lp, sk, ff, en, mm, bs, pov, teams, roster, events, lead, beats, lulls,
## over, hold`) so the byte-identical `client/chrome_common.js` runs unmodified
## against cabinet values; everything cabinet-specific lives under `cab` and
## `stances`, consumed only by the appended game block.

import std/[json, strutils]
import sim

type
  BroadcastTracker* = object
    ## The previous frame's state, so a delta can be named.
    lives*: array[CabinetCount, int32]
    isOut*: array[CabinetCount, bool]
    saves*: array[CabinetCount, int32]
    chips*: array[CabinetCount, int32]
    catches*: array[CabinetCount, int32]
    nearMisses*: array[CabinetCount, int32]
    bricks*: array[CabinetCount, int]
    columnEmpty*: array[CabinetCount, array[BricksPerRow, bool]]
    ballState*: array[MaxBalls, int]
    ballHeld*: array[MaxBalls, int32]
    phase*: int
    over*: bool
    turn*: int
    stanceTurn*: array[CabinetCount, int]
    synced*: bool

proc initBroadcastTracker*(): BroadcastTracker =
  result.synced = false
  for i in 0 ..< CabinetCount:
    result.stanceTurn[i] = -1

proc resync*(tracker: var BroadcastTracker, sim: SimServer) =
  ## After a seek or a loop the tracker must not report the whole match as one
  ## tick's worth of deltas.
  for k in 0 ..< CabinetCount:
    tracker.lives[k] = sim.cabinets[k].lives
    tracker.isOut[k] = sim.cabinets[k].isOut
    tracker.saves[k] = sim.cabinets[k].saves
    tracker.chips[k] = sim.cabinets[k].chips
    tracker.catches[k] = sim.cabinets[k].catches
    tracker.nearMisses[k] = sim.cabinets[k].nearMisses
    tracker.bricks[k] = sim.bricksRemaining(k)
    for col in 0 ..< BricksPerRow:
      tracker.columnEmpty[k][col] = sim.brickColumnEmpty(k, col)
  for i in 0 ..< MaxBalls:
    tracker.ballState[i] = if i < sim.balls.len: ord(sim.balls[i].state) else: 0
    tracker.ballHeld[i] = if i < sim.balls.len: sim.balls[i].heldBy else: -1
  tracker.phase = ord(sim.phase)
  tracker.over = sim.phase == GameOver
  tracker.turn = sim.gameTicksElapsed() div max(1, sim.config.turnTicks)
  for seat in 0 ..< CabinetCount:
    tracker.stanceTurn[seat] =
      if sim.haveStance[seat]: sim.stances[seat].turn else: -1
  tracker.synced = true

proc stepEvents*(
  sim: SimServer, tracker: var BroadcastTracker, events: JsonNode
) =
  ## Appends this tick's broadcast events. BEATS (the scrubber's markers) are
  ## `concede`, `breach`, `eliminated`, `last_standing` and `over` only:
  ## `save`, `chip`, `serve`, `catch`, `release`, `near_miss` and `say` fire
  ## dozens to hundreds of times and would bury the scrubber.
  if not tracker.synced:
    tracker.resync(sim)
    return
  let tick = sim.tickCount
  if ord(sim.phase) != tracker.phase:
    events.add(%*{"k": "phase", "t": tick, "ph": ($sim.phase).toLowerAscii()})
    tracker.phase = ord(sim.phase)
  for k in 0 ..< CabinetCount:
    if sim.cabinets[k].saves > tracker.saves[k]:
      events.add(%*{
        "k": "save", "t": tick, "cabinet": k, "team": teamKeyOfCabinet(k),
        "count": int(sim.cabinets[k].saves)})
    if sim.cabinets[k].chips > tracker.chips[k]:
      events.add(%*{
        "k": "chip", "t": tick, "cabinet": k, "team": teamKeyOfCabinet(k),
        "count": int(sim.cabinets[k].chips)})
    if sim.cabinets[k].catches > tracker.catches[k]:
      events.add(%*{
        "k": "catch", "t": tick, "cabinet": k, "team": teamKeyOfCabinet(k)})
    if sim.cabinets[k].nearMisses > tracker.nearMisses[k]:
      events.add(%*{
        "k": "near_miss", "t": tick, "cabinet": k,
        "team": teamKeyOfCabinet(k),
        "ball": ballId(max(0, int(sim.cabinets[k].lastNearMissBall)))})
    let bricks = sim.bricksRemaining(k)
    for col in 0 ..< BricksPerRow:
      let empty = sim.brickColumnEmpty(k, col)
      if empty and not tracker.columnEmpty[k][col]:
        events.add(%*{
          "k": "breach", "t": tick, "cabinet": k, "col": col,
          "team": teamKeyOfCabinet(k)})
      tracker.columnEmpty[k][col] = empty
    if bricks == 0 and tracker.bricks[k] > 0:
      events.add(%*{
        "k": "wall_down", "t": tick, "cabinet": k,
        "team": teamKeyOfCabinet(k)})
    if sim.cabinets[k].lives < tracker.lives[k]:
      events.add(%*{
        "k": "concede", "t": tick, "cabinet": k,
        "team": teamKeyOfCabinet(k),
        "livesLeft": int(sim.cabinets[k].lives)})
    if sim.cabinets[k].isOut and not tracker.isOut[k]:
      events.add(%*{
        "k": "eliminated", "t": tick, "cabinet": k,
        "team": teamKeyOfCabinet(k),
        "placement": int(sim.cabinets[k].placement)})
    tracker.lives[k] = sim.cabinets[k].lives
    tracker.isOut[k] = sim.cabinets[k].isOut
    tracker.saves[k] = sim.cabinets[k].saves
    tracker.chips[k] = sim.cabinets[k].chips
    tracker.catches[k] = sim.cabinets[k].catches
    tracker.nearMisses[k] = sim.cabinets[k].nearMisses
    tracker.bricks[k] = bricks
  for i in 0 ..< sim.balls.len:
    let state = ord(sim.balls[i].state)
    if state != tracker.ballState[i]:
      if sim.balls[i].state == bsLive and tracker.ballState[i] == ord(bsServing):
        events.add(%*{
          "k": "serve", "t": tick, "ball": ballId(i),
          "dir": int(sim.balls[i].dir)})
      elif tracker.ballState[i] == ord(bsHeld):
        events.add(%*{"k": "release", "t": tick, "ball": ballId(i)})
      tracker.ballState[i] = state
    tracker.ballHeld[i] = sim.balls[i].heldBy
  let turn = sim.gameTicksElapsed() div max(1, sim.config.turnTicks)
  if turn != tracker.turn:
    tracker.turn = turn
    events.add(%*{"k": "turn_end", "t": tick, "turn": turn})
  for seat in 0 ..< CabinetCount:
    let stanceTurn =
      if sim.haveStance[seat]: sim.stances[seat].turn else: -1
    if stanceTurn != tracker.stanceTurn[seat]:
      tracker.stanceTurn[seat] = stanceTurn
      if sim.haveStance[seat] and sim.stances[seat].say.len > 0:
        events.add(%*{
          "k": "say", "t": tick, "cabinet": sim.stances[seat].cabinet,
          "team": teamKeyOfCabinet(sim.stances[seat].cabinet),
          "say": sim.stances[seat].say})
  if sim.phase == GameOver and not tracker.over:
    tracker.over = true
    if sim.endRule == EndRuleLastStanding:
      events.add(%*{
        "k": "last_standing", "t": tick, "cabinet": sim.winnerCabinet,
        "team": teamKeyOfCabinet(sim.winnerCabinet)})
    events.add(%*{
      "k": "over", "t": tick, "winner": teamKeyOfCabinet(sim.winnerCabinet),
      "draw": false, "endRule": sim.endRule, "reason": sim.endReason})
    events.add(%*{
      "k": "gameover", "t": tick,
      "winner": teamKeyOfCabinet(sim.winnerCabinet), "draw": false})

proc teamsJson(sim: SimServer): JsonNode =
  ## EXACTLY four keys, and they are the four colour names chrome_common
  ## already knows (`TEAM_ORDER = ['red','blue','green','yellow']`).
  result = newJObject()
  for k in 0 ..< CabinetCount:
    result[teamKeyOfCabinet(k)] = %*{
      "score": sim.scoreOf(k),
      "lives": int(sim.cabinets[k].lives),
      "startingLives": sim.config.startingLives,
      "bricks": sim.bricksRemaining(k),
      "knockouts": int(sim.cabinets[k].knockouts),
      "chips": int(sim.cabinets[k].chips),
      "saves": int(sim.cabinets[k].saves),
      "catches": int(sim.cabinets[k].catches),
      "out": sim.cabinets[k].isOut,
      "policies": [sim.seatName(sim.seatOfCabinet(k))]
    }

proc rosterJson(sim: SimServer): JsonNode =
  ## Spectator side ONLY: this is the one place a real policy name appears.
  result = newJArray()
  for seat in 0 ..< CabinetCount:
    let cabinet = sim.cabinetOfSeat(seat)
    result.add(%*{
      "s": seat,
      "name": sim.seatName(seat),
      "pol": sim.seatName(seat),
      "team": teamKeyOfCabinet(cabinet),
      "alias": aliasOfCabinet(cabinet),
      "cabinet": cabinet,
      "kind": sim.seatPolicyKind[seat],
      "alive": not sim.cabinets[cabinet].isOut,
      "lives": max(0, int(sim.cabinets[cabinet].lives) - 1),
      "knockouts": int(sim.cabinets[cabinet].knockouts),
      "saves": int(sim.cabinets[cabinet].saves),
      "chips": int(sim.cabinets[cabinet].chips),
      "catches": int(sim.cabinets[cabinet].catches),
      "llmTurns": sim.llmTurns[seat],
      "fallbackTurns": sim.fallbackTurns[seat],
      "placement": int(sim.cabinets[cabinet].placement)
    })

proc cabJson(sim: SimServer): JsonNode =
  var cabinets = newJArray()
  for k in 0 ..< CabinetCount:
    var bricks = newJArray()
    for col in 0 ..< BricksPerRow:
      bricks.add(%(not sim.brickColumnEmpty(k, col)))
    let seat = sim.seatOfCabinet(k)
    let view = sim.stances[max(0, seat)]
    cabinets.add(%*{
      "k": k,
      "team": teamKeyOfCabinet(k),
      "alias": aliasOfCabinet(k),
      "side": sideNameOfCabinet(k),
      "lives": int(sim.cabinets[k].lives),
      "out": sim.cabinets[k].isOut,
      "paddle": float(sim.cabinets[k].alongCentre) / float(UuPerCu),
      "paddleVel": float(sim.cabinets[k].paddleVel) / float(UuPerCu),
      "far":
        (if sim.config.farPaddle:
          %(float(sim.cabinets[k].farAlongCentre) / float(UuPerCu))
        else: newJNull()),
      "held":
        (if sim.cabinets[k].heldBall >= 0:
          %ballId(int(sim.cabinets[k].heldBall)) else: newJNull()),
      "mouthOpen": not sim.cabinets[k].isOut,
      "bricks": bricks,
      "stance": (if seat >= 0 and sim.haveStance[seat]: view.stance else: ""),
      "aimAt":
        (if seat >= 0 and sim.haveStance[seat] and view.aimAt != "none":
          %view.aimAt else: newJNull())
    })
  var balls = newJArray()
  for i in 0 ..< sim.balls.len:
    let ball = sim.balls[i]
    var trail = newJArray()
    for stage in 0 ..< int(ball.trailLen):
      trail.add(%[
        float(ball.trailX[stage]) / float(UuPerCu),
        float(ArenaSide - ball.trailY[stage]) / float(UuPerCu)])
    let vector = dirVector(ball.dir)
    balls.add(%*{
      "id": ballId(i),
      "p": [float(ball.x) / float(UuPerCu),
            float(ArenaSide - ball.y) / float(UuPerCu)],
      "v": [float(ball.speed) * float(vector.x) /
              (float(DirQ12One) * float(UuPerCu)),
            -float(ball.speed) * float(vector.y) /
              (float(DirQ12One) * float(UuPerCu))],
      "speed": float(ball.speed) / float(UuPerCu),
      "dir": int(ball.dir),
      "state": $ball.state,
      "lastTouch":
        (if ball.lastTouch >= 0: %int(ball.lastTouch) else: newJNull()),
      "heldBy": (if ball.heldBy >= 0: %int(ball.heldBy) else: newJNull()),
      "trail": trail
    })
  var bubbles = newJArray()
  for seat in 0 ..< CabinetCount:
    if sim.haveStance[seat] and sim.stances[seat].say.len > 0 and
        sim.tickCount <= sim.stances[seat].sayUntil:
      bubbles.add(%*{
        "cabinet": sim.stances[seat].cabinet,
        "say": sim.stances[seat].say,
        "until": sim.stances[seat].sayUntil})
  %*{
    "rom": sim.config.rom,
    "arena": {
      "side": float(ArenaSide) / float(UuPerCu),
      "goalHalf": float(goalHalfUu(sim.config)) / float(UuPerCu),
      "paddleDepth": float(PaddleDepth) / float(UuPerCu),
      "farPaddleDepth":
        (if sim.config.farPaddle:
          %(float(FarPaddleDepth) / float(UuPerCu)) else: newJNull()),
      "paddleHalf": float(paddleHalfUu(sim.config)) / float(UuPerCu),
      "brickRows": sim.config.brickRows,
      "bricksPerRow": BricksPerRow,
      "catchEnabled": sim.config.catchEnabled
    },
    "cabinets": cabinets,
    "balls": balls,
    "bubbles": bubbles
  }

proc stancesJson(sim: SimServer): JsonNode =
  result = newJArray()
  for seat in 0 ..< CabinetCount:
    if not sim.haveStance[seat]:
      continue
    let view = sim.stances[seat]
    result.add(%*{
      "turn": view.turn,
      "seat": seat,
      "alias": aliasOfCabinet(view.cabinet),
      "cabinet": view.cabinet,
      "source": view.source,
      "stance": view.stance,
      "targetBall": view.targetBall,
      "aimAt": (if view.aimAt == "none": newJNull() else: %view.aimAt),
      "post": float(view.postMilliCu) / 1000.0,
      "leadTicks": view.leadTicks,
      "aggression": float(view.aggression255) / 255.0,
      "note": view.note,
      "say": view.say
    })

proc overJson(sim: SimServer): JsonNode =
  var teams = newJObject()
  for k in 0 ..< CabinetCount:
    teams[teamKeyOfCabinet(k)] = %*{
      "placement": int(sim.cabinets[k].placement),
      "score": sim.scoreOf(k),
      "lives": int(sim.cabinets[k].lives)
    }
  %*{
    "winner": teamKeyOfCabinet(sim.winnerCabinet),
    "draw": false,
    "timeLimit": sim.endRule == EndRuleFullTime,
    "endRule": sim.endRule,
    "reason": sim.endReason,
    "ticks": sim.tickCount,
    "rom": sim.config.rom,
    "teams": teams
  }

proc buildStateJson*(
  sim: SimServer,
  events: JsonNode,
  playing: bool,
  speed: int,
  maxTick: int,
  looping: bool,
  transportEnabled: bool,
  mismatchTick: int,
  startTick: int,
  holdSeconds: int,
  skipLulls: bool,
  fastForward: bool,
  lead: seq[seq[int]],
  lulls: seq[array[2, int]],
  beats: JsonNode
): string =
  ## The one state frame. Everything above `cab` is the starter's schema.
  var node = %*{
    "t": sim.tickCount,
    "mt": sim.config.maxTicks,
    "ph": ($sim.phase).toLowerAscii(),
    "lob": sim.lobbyStartSecondsRemaining(),
    "pl": playing,
    "sp": speed,
    "mx": maxTick,
    "st": startTick,
    "lp": looping,
    "sk": skipLulls,
    "ff": fastForward,
    "en": transportEnabled,
    "mm": mismatchTick,
    "bs": sim.balls.len,
    "pov": -1,
    "boardW": MapWidth,
    "boardH": MapHeight,
    "turn": sim.gameTicksElapsed() div max(1, sim.config.turnTicks),
    "turns": sim.turnsPerEpisode(),
    "turnTicks": sim.config.turnTicks,
    "teams": sim.teamsJson(),
    "roster": sim.rosterJson(),
    "events": events,
    "cab": sim.cabJson(),
    "stances": sim.stancesJson(),
    "hold": holdSeconds
  }
  if lead.len > 0:
    var series = newJArray()
    for point in lead:
      var row = newJArray()
      for value in point:
        row.add(%value)
      series.add(row)
    var teams = newJArray()
    for k in 0 ..< CabinetCount:
      teams.add(%teamKeyOfCabinet(k))
    node["lead"] = %*{"teams": teams, "pts": series}
  if lulls.len > 0:
    var spans = newJArray()
    for span in lulls:
      spans.add(%[span[0], span[1]])
    node["lulls"] = spans
  if beats != nil and beats.len > 0:
    node["beats"] = beats
  if sim.phase == GameOver:
    node["over"] = sim.overJson()
  $node

proc scoreLead*(sim: SimServer): seq[int] =
  ## One lead value per cabinet, in cabinet order — the metric the momentum
  ## graph plots. Whole score points: the change-point series stays compact
  ## and the four curves read as "who is winning".
  for k in 0 ..< CabinetCount:
    result.add(int(sim.cabinets[k].scoreMicro div 1_000_000'i64))
