## The scripted baselines: `bulwark` and `spinner`.
##
## Both emit the SAME stance object on the SAME 120-tick cadence as an LLM
## seat, so their output is legal by construction and directly comparable, and
## both are pure functions of the observation a seat would receive.
##
## `bulwark` is the certification player, the per-turn fallback and the default
## for a seat that registers with neither env var. Four `bulwark`s produce a
## real game — rallies, breaches, at least one elimination on most seeds —
## which is the behaviour the cabinet is about and the anti-regression pin of
## the whole physics tuning (tests/test_baselines.nim).
##
## THE THREE TUNABLES ARE A `BaselineParams` OBJECT, NOT LITERALS.
## tools/tune_baselines.nim sweeps them over a bounded grid,
## tools/ci/baseline_tuning.json records the sweep's pick and
## tests/test_tuning.nim asserts the shipped defaults still equal it. The
## PHYSICS constants and the ROM presets are NOT swept and are not tunable by
## the harness: if the baselines cannot hold a rally, the sweep moves these
## three numbers, not the sim.

import std/strutils
import sim, stances, control

type
  Baseline* = enum
    blBulwark = "bulwark"
    blSpinner = "spinner"

  BaselineParams* = object
    reactTicks*: int           ## how far out a ball counts as "inbound"
    campPostCu*: int           ## where `camp` idles, in along-units
    aggressionMilli*: int      ## the aiming branches' aggression

const DefaultBaselineParams* = BaselineParams(
  ## The sweep's pick (tools/ci/baseline_tuning.json; re-run
  ## tools/tune_baselines.nim to reproduce). `reactTicks` 140 rather than the
  ## design note's opening 56: at 56 a bulwark spends most of the episode in
  ## `camp`, whose window only covers +/-(aggression*43 + 8) cu, so it
  ## conceded balls it could plainly have reached and finished BELOW `spinner`
  ## in a 2/2 mix. At 140 it defends whenever a ball is genuinely inbound and
  ## the mix comes out at parity-or-better, which is what a filler pair is
  ## for. The PHYSICS constants and the ROM presets were not touched.
  reactTicks: 140,
  campPostCu: 0,
  aggressionMilli: 800
)

const BulwarkSays* = [
  "holding the line", "on the ball", "wall up", "middle is mine",
  "your turn next"
]

proc parseBaseline*(text: string): Baseline =
  ## A seat that registers with neither field, or with an unknown baseline
  ## name, is `bulwark`.
  case text.strip().toLowerAscii()
  of "spinner": blSpinner
  else: blBulwark

proc weakestRival(sim: SimServer, cabinet: int): int =
  ## The alive rival with the fewest lives; ties -> fewest bricks left, then
  ## the lowest cabinet index.
  result = -1
  for k in 0 ..< CabinetCount:
    if k == cabinet or sim.cabinets[k].isOut:
      continue
    if result < 0:
      result = k
      continue
    let
      a = sim.cabinets[k]
      b = sim.cabinets[result]
    if a.lives != b.lives:
      if a.lives < b.lives:
        result = k
      continue
    let
      ba = sim.bricksRemaining(k)
      bb = sim.bricksRemaining(result)
    if ba != bb:
      if ba < bb:
        result = k
      continue

proc soonestBall(
  sim: SimServer, cabinet: int
): tuple[index: int, tick: int] =
  ## The live ball whose predicted arrival on my line is soonest.
  result = (-1, PredictTicks + 2)
  for index in 0 ..< sim.balls.len:
    if sim.balls[index].state != bsLive:
      continue
    let arrival = sim.predictBall(index).perSide[cabinet]
    if arrival.reaches and arrival.tick < result.tick:
      result = (index, arrival.tick)

proc liveBallCount(sim: SimServer): int =
  for ball in sim.balls:
    if ball.state == bsLive:
      inc result

proc bulwarkStance*(
  sim: SimServer, cabinet: int, params = DefaultBaselineParams
): CabinetStance =
  ## 1. out -> camp at 0, aggression 0.
  ## 2. a ball inbound inside reactTicks -> catch (warlords, one ball live,
  ##    holding none) / aim at the weakest rival (arrival > 24) / guard.
  ## 3. some ball live -> camp at campPostCu, aggression 0.45.
  ## 4. every ball mid-serve -> camp at 0, aggression 0.40.
  ## 5. in EVERY branch: on the last life the stance is forced to guard (or
  ##    camp when nothing is inbound) with aim_at none and aggression 1.0.
  result = defaultStance()
  result.source = ssScripted
  if cabinet < 0 or cabinet >= CabinetCount or sim.cabinets[cabinet].isOut:
    result.stance = stCamp
    result.postUu = 0
    result.aggression255 = 0
    result.say = BulwarkSays[4]
    return
  let
    lastLife = sim.cabinets[cabinet].lives <= 1
    soonest = sim.soonestBall(cabinet)
    aggression = max(0, min(255, (params.aggressionMilli * 255) div 1000))
  if soonest.index >= 0 and soonest.tick <= params.reactTicks:
    let weakest = sim.weakestRival(cabinet)
    result.targetBall = soonest.index
    if lastLife:
      result.stance = stGuard
      result.aimAt = -1
      result.leadTicks = 16
      result.aggression255 = 255
      result.say = BulwarkSays[3]
      return
    if sim.config.catchEnabled and sim.liveBallCount() == 1 and
        sim.cabinets[cabinet].heldBall < 0:
      result.stance = stCatch
      result.aimAt = weakest
      result.leadTicks = 14
      result.aggression255 = aggression
      result.say = BulwarkSays[1]
      return
    if soonest.tick > 24:
      result.stance = stAim
      result.aimAt = weakest
      result.leadTicks = 12
      result.aggression255 = aggression
      result.say = BulwarkSays[4]
      return
    result.stance = stGuard
    result.aimAt = -1
    result.leadTicks = 16
    result.aggression255 = 242         ## 0.95
    result.say = BulwarkSays[0]
    return
  if sim.liveBallCount() > 0:
    result.stance = stCamp
    result.postUu = int32(params.campPostCu) * UuPerCu
    result.aggression255 = if lastLife: 255 else: 115   ## 0.45
    result.say = BulwarkSays[2]
    return
  result.stance = stCamp
  result.postUu = 0
  result.aggression255 = if lastLife: 255 else: 102     ## 0.40
  result.say = BulwarkSays[3]

proc spinnerStance*(
  sim: SimServer, cabinet: int, turn: int
): CabinetStance =
  ## The second filler, deliberately different in shape and weaker: it never
  ## defends on purpose and never camps. It hits hard, takes a lot of saves and
  ## knockouts, and gets eliminated because chasing with lead_ticks 0 means
  ## arriving late — which gives the ladder a spread and gives a champion a
  ## chaotic neighbour to cope with.
  result = defaultStance()
  result.source = ssScripted
  if cabinet < 0 or cabinet >= CabinetCount or sim.cabinets[cabinet].isOut:
    result.stance = stCamp
    result.postUu = 0
    result.aggression255 = 0
    result.say = "spun out"
    return
  var target = -1
  for step in 0 ..< CabinetCount:
    let candidate = (cabinet + 1 + (turn mod 3) + step) mod CabinetCount
    if candidate != cabinet and not sim.cabinets[candidate].isOut:
      target = candidate
      break
  result.stance = stChase
  result.targetBall = -1
  result.aimAt = target
  result.leadTicks = 0
  result.aggression255 = 255
  result.say = "all gas"

proc baselineStance*(
  sim: SimServer, cabinet: int, kind: Baseline, turn: int,
  params = DefaultBaselineParams
): CabinetStance =
  case kind
  of blBulwark: sim.bulwarkStance(cabinet, params)
  of blSpinner: sim.spinnerStance(cabinet, turn)

proc baselineCommand*(
  sim: SimServer, cabinet: int, kind: Baseline, turn: int,
  params = DefaultBaselineParams
): uint8 =
  ## The convenience path the offline tuner and the tests use: one turn's
  ## stance compiled straight through the shared autopilot.
  sim.paddleCommand(cabinet, sim.baselineStance(cabinet, kind, turn, params))
