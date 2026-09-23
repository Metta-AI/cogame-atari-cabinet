## Headless Atari Cabinet games for Metta post-training.
## Reuses the hosted view, stance parser, autopilot, and simulator.

import std/[hashes, json, os]
import sim, decide, stances, baselines, control

const SystemPrompt = "Play one Atari Cabinet seat. Reply with a JSON stance: " &
  "{\"stance\":\"guard|aim|camp|catch|chase\"," &
  "\"target_ball\":\"B1|B2|any\"," &
  "\"aim_at\":\"RED|BLUE|GREEN|YELLOW|none\"," &
  "\"post\":0,\"lead_ticks\":12,\"aggression\":0.8}. " &
  "You see the public board but no other player's private stance."

var
  game: SimServer
  engine: DecisionEngine
  decisionId: int
  actingSeat: int
  rom = "warlords"

proc activeSeats(): seq[int] =
  for seat in 0 ..< CabinetCount:
    if not game.cabinets[game.cabinetOfSeat(seat)].isOut:
      result.add(seat)

proc stanceJson(stance: CabinetStance): JsonNode =
  %*{
    "stance": $stance.stance,
    "target_ball": (if stance.targetBall < 0: "any" else: ballId(stance.targetBall)),
    "aim_at": (if stance.aimAt < 0: "none" else: aliasOfCabinet(stance.aimAt)),
    "post": stance.postCu(), "lead_ticks": stance.leadTicks,
    "aggression": stance.aggressionFraction(),
    "note": stance.note, "say": stance.say,
  }

proc currentDecision(): JsonNode =
  let turn = game.gameTicksElapsed() div game.config.turnTicks
  %*{
    "kind": "decision", "decision_id": decisionId,
    "seat": actingSeat, "turn": turn,
    "messages": [
      {"role": "system", "content": SystemPrompt},
      {"role": "user", "content": engine.seatViewJson(game, actingSeat, turn)},
    ],
    "action_schema": {
      "type": "object",
      "properties": {
        "stance": {"enum": ["guard", "aim", "camp", "catch", "chase"]},
        "target_ball": {"type": "string"},
        "aim_at": {"type": "string"},
        "post": {"type": "number", "minimum": -43, "maximum": 43},
        "lead_ticks": {"type": "integer", "minimum": 0, "maximum": 48},
        "aggression": {"type": "number", "minimum": 0, "maximum": 1},
      },
    },
  }

proc reset(command: JsonNode): JsonNode =
  if command["players"].getInt() != CabinetCount:
    raise newException(ValueError, "Atari Cabinet has exactly four seats")
  var config = defaultGameConfig()
  config.update($(%*{
    "rom": rom,
    "seed": int(hash(command["seed"].getStr()) and hash(high(int))),
    "num_agents": CabinetCount, "minPlayers": CabinetCount,
    "startWaitTicks": 1,
  }))
  game = initSimServer(config)
  game.gameEventLoggingEnabled = false
  for seat in 0 ..< CabinetCount:
    discard game.addPlayer("P" & $(seat + 1), seat, "", trusted = true)
  while game.phase == Lobby:
    game.step([NeutralCommand, NeutralCommand, NeutralCommand, NeutralCommand])
  engine = DecisionEngine(
    stances: newSeq[CabinetStance](CabinetCount),
    haveStance: newSeq[bool](CabinetCount))
  for seat in 0 ..< CabinetCount:
    engine.stances[seat] = defaultStance()
  decisionId = 0
  actingSeat = activeSeats()[0]
  currentDecision()

proc teacher(): JsonNode =
  let cabinet = game.cabinetOfSeat(actingSeat)
  let turn = game.gameTicksElapsed() div game.config.turnTicks
  %*{"response": $stanceJson(game.baselineStance(cabinet, blBulwark, turn))}

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let cabinet = game.cabinetOfSeat(actingSeat)
  var cabinetOut: array[CabinetCount, bool]
  var ballLive: seq[bool]
  for k in 0 ..< CabinetCount:
    cabinetOut[k] = game.cabinets[k].isOut
  for ball in game.balls:
    ballLive.add(ball.state == bsLive)
  var stance: CabinetStance
  try:
    stance = parseCabinetStance(extractJsonObject(command["response"].getStr()),
      cabinet, cabinetOut, ballLive, game.config.catchEnabled,
      engine.stances[actingSeat], engine.haveStance[actingSeat])
  except JsonParsingError, StanceError:
    return %*{"kind": "rejected", "reason": "reply must be a usable JSON stance"}
  engine.repairStance(game, actingSeat, stance)
  engine.stances[actingSeat] = stance
  engine.haveStance[actingSeat] = true
  let action = stanceJson(stance)
  var nextSeat = CabinetCount
  for seat in activeSeats():
    if seat > actingSeat:
      nextSeat = seat
      break
  if nextSeat < CabinetCount:
    actingSeat = nextSeat
  else:
    var commands = newSeq[uint8](CabinetCount)
    for tick in 0 ..< game.config.turnTicks:
      for seat in 0 ..< CabinetCount:
        let k = game.cabinetOfSeat(seat)
        commands[seat] = game.paddleCommand(k, engine.stances[seat])
      game.step(commands)
      if game.phase != Playing:
        break
    if game.phase == Playing:
      actingSeat = activeSeats()[0]
  inc decisionId
  if game.phase != Playing:
    var scores = newJObject()
    for seat in 0 ..< CabinetCount:
      scores[$seat] = %game.scoreOf(game.cabinetOfSeat(seat))
    return %*{"kind": "accepted", "action": action,
      "observation": {"kind": "terminal", "scores": scores}}
  %*{"kind": "accepted", "action": action,
    "observation": currentDecision()}

when isMainModule:
  if paramCount() > 1:
    raise newException(ValueError, "Pass at most one ROM")
  if paramCount() == 1:
    rom = paramStr(1)
  if rom notin ["warlords", "quadrapong", "foozpong"]:
    raise newException(ValueError, "ROM must be warlords, quadrapong, or foozpong")
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "teacher": teacher()
      of "step": step(command)
      else: raise newException(ValueError, "Unknown bridge command")
    stdout.writeLine($response)
    stdout.flushFile()
