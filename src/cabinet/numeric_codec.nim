## Numeric policy surface over the same private view and complete stance orders.
## Post uses whole cabinet units; speech and notes remain empty.
import std/[json, math, strutils]
import sim_types, stances

const
  ActionSizes* = [5, MaxBalls + 1, CabinetCount + 1, 87, 49, 256]
  ObservationSize* = 115

proc aliasCode(node: JsonNode): int =
  if node.kind == JNull or node.getStr() == "none": return 0
  for index, alias in CabinetAliases:
    if node.getStr() == alias: return index + 1
  raise newException(ValueError, "Unknown cabinet alias")

proc actionMaskForView*(view: JsonNode): JsonNode =
  result = newJArray()
  for stance in Stance:
    result.add(%(stance != stCatch or view["rules"]["catch_enabled"].getBool()))
  result.add(%true)
  for ballIndex in 0 ..< MaxBalls:
    result.add(%(ballIndex < view["balls"].len and view["balls"][ballIndex]["state"].getStr() == "live"))
  result.add(%true)
  for alias in CabinetAliases:
    var aliveRival = false
    for rival in view["rivals"]:
      if rival["alias"].getStr() == alias: aliveRival = not rival["out"].getBool()
    result.add(%aliveRival)
  for head in 3 ..< ActionSizes.len:
    for unused in 0 ..< ActionSizes[head]: result.add(%true)

proc numericEncoding*(view: JsonNode, decisionId: int): JsonNode =
  var values = newJArray()
  let you = view["you"]
  for number in [float(view["turn"].getInt()) / float(view["of"].getInt()),
                 float(view["clock"]["tick"].getInt()) / float(view["clock"]["of"].getInt()),
                 float(aliasCode(you["alias"])) / 4.0,
                 float(you["lives"].getInt()) / float(view["rules"]["starting_lives"].getInt()),
                 float(you["bricks"]["left"].getInt()) / 27.0,
                 you["score"].getFloat() / 100.0,
                 float(ord(you["out"].getBool())),
                 float(ord(view["rules"]["catch_enabled"].getBool())),
                 float(ord(view["rules"]["far_paddle"].getBool())),
                 float(view["rules"]["brick_rows"].getInt()) / 3.0]:
    values.add(%number)
  for rom in ["warlords", "quadrapong", "foozpong"]:
    values.add(%ord(view["rom"].getStr() == rom))
  for field in ["along", "vel", "half", "depth", "travel_half"]:
    values.add(%(you["paddle"][field].getFloat() / 100.0))
  for field in ["along", "vel", "half", "depth"]:
    values.add(%(if you["far_paddle"].kind == JNull: 0.0
                else: you["far_paddle"][field].getFloat() / 100.0))
  values.add(%(you["mouth"]["half"].getFloat() / 50.0))
  for col in you["bricks"]["cols"]: values.add(%ord(col.getBool()))
  for ballIndex in 0 ..< MaxBalls:
    if ballIndex >= view["balls"].len:
      for unused in 0 ..< 18: values.add(%0)
      continue
    let ball = view["balls"][ballIndex]
    values.add(%1)
    for state in ["live", "held", "serving", "dead"]:
      values.add(%ord(ball["state"].getStr() == state))
    for field in ["pos", "vel"]:
      for coordinate in ball[field]: values.add(%(coordinate.getFloat() / 100.0))
    for field in ["speed", "deg"]:
      values.add(%(ball[field].getFloat() / (if field == "deg": 360.0 else: 100.0)))
    for field in ["last_touch", "held_by", "arrive_at"]:
      values.add(%(float(aliasCode(ball[field])) / 4.0))
    for field in ["arrive_in_ticks", "arrive_along", "arrive_in_ticks_for_you"]:
      values.add(%(if ball[field].kind == JNull: -1.0 else: ball[field].getFloat() / 100.0))
    values.add(%ord(you["holding"] == ball["id"]))
  for rival in view["rivals"]:
    values.add(%(float(aliasCode(rival["alias"])) / 4.0))
    values.add(%(float(rival["lives"].getInt()) / float(view["rules"]["starting_lives"].getInt())))
    values.add(%ord(rival["out"].getBool()))
    values.add(%(float(rival["bricks_left"].getInt()) / 27.0))
    values.add(%(if rival["paddle_along"].kind == JNull: 0.0 else: rival["paddle_along"].getFloat() / 100.0))
    values.add(%(rival["score"].getFloat() / 100.0))
  let previous = view["your_last_stance"]
  values.add(%ord(previous.kind != JNull))
  for stance in Stance:
    values.add(%ord(previous.kind != JNull and previous["stance"].getStr() == $stance))
  for field in ["post", "lead_ticks", "aggression"]:
    values.add(%(if previous.kind == JNull: 0.0 else: previous[field].getFloat()))
  values.add(%(if previous.kind == JNull: 0 else: aliasCode(previous["aim_at"])))
  values.add(%(if previous.kind == JNull: 0 else: (if previous["target_ball"].getStr() == "any": 0 else: parseInt(previous["target_ball"].getStr()[1 .. ^1]))))
  doAssert values.len == ObservationSize
  let mask = actionMaskForView(view)
  var heads = newJArray()
  var offset = 0
  for head, size in ActionSizes:
    var choices = newJArray()
    for choice in 0 ..< size:
      var value: JsonNode
      case head
      of 0: value = %($Stance(choice))
      of 1: value = %(if choice == 0: "any" else: "B" & $choice)
      of 2: value = %(if choice == 0: "none" else: CabinetAliases[choice - 1])
      of 3: value = %(choice - 43)
      of 4: value = %choice
      of 5: value = %(float(choice) / 255.0)
      choices.add(if mask[offset + choice].getBool(): value else: newJNull())
    heads.add(%*{"name": ["stance", "target_ball", "aim_at", "post", "lead_ticks", "aggression"][head],
      "choices": choices})
    offset += size
  %*{"decision_id": decisionId, "values": values, "action_heads": heads}

proc actionMask*(encoding: JsonNode): JsonNode =
  result = newJArray()
  for head in encoding["action_heads"]:
    for choice in head["choices"]: result.add(%(choice.kind != JNull))

proc decodeActions*(view, actions: JsonNode): JsonNode =
  doAssert actions.len == ActionSizes.len
  let mask = actionMaskForView(view)
  var offset = 0
  for head, size in ActionSizes:
    let choice = actions[head].getInt()
    doAssert choice >= 0 and choice < size
    doAssert mask[offset + choice].getBool()
    offset += size
  %*{"stance": $Stance(actions[0].getInt()),
     "target_ball": (if actions[1].getInt() == 0: "any" else: "B" & $actions[1].getInt()),
     "aim_at": (if actions[2].getInt() == 0: "none" else: CabinetAliases[actions[2].getInt() - 1]),
     "post": actions[3].getInt() - 43, "lead_ticks": actions[4].getInt(),
     "aggression": float(actions[5].getInt()) / 255.0, "note": "", "say": ""}

proc encodeStance*(stance: CabinetStance): JsonNode =
  ## The numeric grid preserves the engine's aggression byte and lead ticks.
  %*[ord(stance.stance), stance.targetBall + 1, stance.aimAt + 1,
     int(round(stance.postCu())) + 43, stance.leadTicks, stance.aggression255]
