## Scripted player decisions over the ordinary private seat observation.
import std/json
import sim_types, stances, baselines

proc baselineStance*(
  view: JsonNode, kind: Baseline, params = DefaultBaselineParams
): CabinetStance =
  result = defaultStance()
  result.source = ssScripted
  let you = view["you"]
  if you["out"].getBool():
    result.stance = stCamp
    result.aggression255 = 0
    result.say = if kind == blSpinner: "spun out" else: BulwarkSays[4]
    return
  var cabinet = -1
  for index, alias in CabinetAliases:
    if alias == you["alias"].getStr():
      cabinet = index
  doAssert cabinet >= 0
  if kind == blSpinner:
    for step in 0 ..< CabinetCount:
      let candidate = (cabinet + 1 + view["turn"].getInt() mod 3 + step) mod CabinetCount
      for rival in view["rivals"]:
        if rival["alias"].getStr() == CabinetAliases[candidate] and not rival["out"].getBool():
          result.aimAt = candidate
          break
      if result.aimAt >= 0:
        break
    result.stance = stChase
    result.leadTicks = 0
    result.aggression255 = 255
    result.say = "all gas"
    return
  var
    soonest = -1
    soonestTick = high(int)
    liveCount = 0
    weakest = -1
    weakestLives = high(int)
    weakestBricks = high(int)
  for index in 0 ..< view["balls"].len:
    let ball = view["balls"][index]
    if ball["state"].getStr() != "live":
      continue
    inc liveCount
    let arrival = ball["arrive_in_ticks_for_you"]
    if arrival.kind != JNull and arrival.getInt() < soonestTick:
      soonest = index
      soonestTick = arrival.getInt()
  for rival in view["rivals"]:
    if rival["out"].getBool():
      continue
    let lives = rival["lives"].getInt()
    let bricks = rival["bricks_left"].getInt()
    if lives < weakestLives or (lives == weakestLives and bricks < weakestBricks):
      weakestLives = lives
      weakestBricks = bricks
      for index, alias in CabinetAliases:
        if alias == rival["alias"].getStr():
          weakest = index
  let lastLife = you["lives"].getInt() <= 1
  if soonest >= 0 and soonestTick <= params.reactTicks:
    result.targetBall = soonest
    if lastLife:
      result.stance = stGuard
      result.leadTicks = 16
      result.aggression255 = 255
      result.say = BulwarkSays[3]
    elif view["rules"]["catch_enabled"].getBool() and liveCount == 1 and you["holding"].kind == JNull:
      result.stance = stCatch
      result.aimAt = weakest
      result.leadTicks = 14
      result.aggression255 = clamp(params.aggressionMilli * 255 div 1000, 0, 255)
      result.say = BulwarkSays[1]
    elif soonestTick > 24:
      result.stance = stAim
      result.aimAt = weakest
      result.leadTicks = 12
      result.aggression255 = clamp(params.aggressionMilli * 255 div 1000, 0, 255)
      result.say = BulwarkSays[4]
    else:
      result.stance = stGuard
      result.leadTicks = 16
      result.aggression255 = 242
      result.say = BulwarkSays[0]
  else:
    result.stance = stCamp
    result.postUu = if liveCount > 0: int32(params.campPostCu) * UuPerCu else: 0'i32
    result.aggression255 = if lastLife: 255 elif liveCount > 0: 115 else: 102
    result.say = if liveCount > 0: BulwarkSays[2] else: BulwarkSays[3]
