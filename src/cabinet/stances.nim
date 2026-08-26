## The stance schema: what a cabinet's policy (LLM or scripted) may say, how a
## reply is parsed TOLERANTLY, and how an illegal reply is REPAIRED instead of
## rejected.
##
## Both policy kinds emit the SAME object, so the two are strictly comparable
## and one validator covers both — which is what makes the bounded-orders
## assertion in tests/test_baselines.nim meaningful.
##
## RUNE DISCIPLINE. Every cap here is measured in RUNES (Unicode codepoints)
## and every truncation lands on a rune boundary (`runeLen` / `runeSubStr`).
## Slicing a string by BYTE index anywhere on the path to the replay is
## forbidden: a byte-truncated multi-byte character renders fine in a browser
## and then fails a strict UTF-8 parser, which is exactly the class of bug
## that makes a replay unreadable to everything except the one viewer that
## happened to be lenient.

import std/[json, math, strutils, unicode]
import sim_types

type
  Stance* = enum
    ## A closed enum. An unrecognised stance is repaired, never dropped.
    stGuard = "guard"
    stAim = "aim"
    stCamp = "camp"
    stCatch = "catch"
    stChase = "chase"

  StanceSource* = enum
    ssLlm = "llm"
    ssScripted = "scripted"
    ssFallback = "fallback"

  CabinetStance* = object
    note*: string              ## <= MaxNoteRunes
    stance*: Stance
    targetBall*: int           ## ball index, or -1 for "any"
    aimAt*: int                ## cabinet index, or -1 for "none"
    postUu*: int32             ## along-units in µu, |post| <= PaddleTravelHalf
    leadTicks*: int            ## 0..48
    aggression255*: int        ## 0..255
    say*: string               ## <= MaxSayRunes, sanitized
    source*: StanceSource
    latencyMs*: int

  StanceError* = object of ValueError

const
  DefaultLeadTicks* = 12
  DefaultAggression255* = 204          ## 0.8
  MaxLeadTicks* = 48

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc sanitizeSay*(text: string): string =
  ## Capped at MaxSayRunes on a rune boundary FIRST, then the starter's
  ## printable-ASCII shout filter. In that order the rune cut never leaves half
  ## a codepoint for the ASCII filter to smear. Braces are excluded
  ## deliberately: the replay chat stream tells a CONTROL record from a plain
  ## line by a leading '{'.
  result = ""
  for rune in text.truncateRunes(MaxSayRunes).runes:
    let value = int(rune)
    if value >= 32 and value < 127 and value != ord('{') and
        value != ord('}'):
      result.add($rune)
  result = result.strip()

proc sanitizeNote*(text: string): string =
  ## Newlines collapse to spaces so one record stays one line.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(MaxNoteRunes)

proc aggressionFraction*(stance: CabinetStance): float =
  float(stance.aggression255) / 255.0

proc postCu*(stance: CabinetStance): float =
  float(stance.postUu) / float(UuPerCu)

proc defaultStance*(): CabinetStance =
  CabinetStance(
    stance: stGuard, targetBall: -1, aimAt: -1, postUu: 0,
    leadTicks: DefaultLeadTicks, aggression255: DefaultAggression255,
    source: ssScripted)

# ---------------------------------------------------------------------------
#  Tolerant parsing
# ---------------------------------------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair, which is
  ## what recovers a reply whose braces sit inside a quoted string.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      StanceError, "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc parseStanceName*(text: string): tuple[ok: bool, stance: Stance] =
  ## Case-insensitive, whitespace-tolerant, with the documented synonyms:
  ## defend->guard, shoot/attack->aim, hold/sit->camp, grab->catch,
  ## rush->chase.
  let key = text.strip().toLowerAscii().replace("-", "_").replace(" ", "_")
  for stance in Stance:
    if $stance == key:
      return (true, stance)
  case key
  of "defend", "defence", "defense", "block": (true, stGuard)
  of "shoot", "attack", "target", "fire": (true, stAim)
  of "hold", "sit", "idle", "stay", "park": (true, stCamp)
  of "grab", "hold_ball", "grip": (true, stCatch)
  of "rush", "charge", "hunt": (true, stChase)
  else: (false, stGuard)

proc readNumber(node: JsonNode): tuple[ok: bool, value: float] =
  ## An int, a float, or a numeric string. Non-finite reports ok = false so
  ## the caller applies its own default rather than inventing a value.
  if node.isNil:
    return (false, 0.0)
  case node.kind
  of JInt: (true, float(node.getBiggestInt()))
  of JFloat:
    let f = node.getFloat()
    if f != f or f > 1.0e9 or f < -1.0e9: (false, 0.0) else: (true, f)
  of JString:
    let raw = node.getStr().strip().strip(chars = {'%', '+'})
    try:
      let f = parseFloat(raw)
      if f != f: (false, 0.0) else: (true, f)
    except CatchableError:
      (false, 0.0)
  of JBool: (true, (if node.getBool(): 1.0 else: 0.0))
  else: (false, 0.0)

proc parseTargetBall*(
  node: JsonNode, ballLive: openArray[bool]
): int =
  ## "B1" / "b2" / "ball 1" / "1" / "any". An id outside the set, or a ball
  ## that is not currently live, becomes "any" (-1) — the autopilot then takes
  ## the soonest-arriving ball.
  if node.isNil or node.kind == JNull:
    return -1
  var raw =
    if node.kind == JString: node.getStr()
    elif node.kind == JInt: $node.getBiggestInt()
    else: ""
  raw = raw.strip().toLowerAscii().truncateRunes(MaxTargetBallRunes + 8)
  if raw.len == 0 or raw == "any" or raw == "all" or raw == "none":
    return -1
  raw = raw.replace("ball", "").replace("b", "").replace("#", "").strip()
  var index = -1
  try:
    index = parseInt(raw) - 1
  except CatchableError:
    return -1
  if index < 0 or index >= ballLive.len or not ballLive[index]:
    return -1
  index

proc parseAimAt*(
  node: JsonNode, myCabinet: int, cabinetOut: openArray[bool]
): int =
  ## RED / BLUE / GREEN / YELLOW or "none", accepted case-insensitively and
  ## inside prose ("the red cabinet"). Unrecognised, missing, MY OWN alias or
  ## an OUT cabinet all become "none" (-1), and the autopilot then behaves as
  ## `guard`.
  if node.isNil or node.kind != JString:
    return -1
  let raw = node.getStr().strip().toLowerAscii()
  if raw.len == 0 or raw == "none" or raw == "nobody" or raw == "null":
    return -1
  var found = -1
  for i, alias in CabinetAliases:
    if alias.toLowerAscii() in raw:
      if found >= 0 and found != i:
        return -1                ## two aliases named: ambiguous, so none
      found = i
  if found < 0 or found == myCabinet:
    return -1
  if found < cabinetOut.len and cabinetOut[found]:
    return -1
  found

proc quantisePost*(value: float): int32 =
  ## Clamped to +/-43.0 cu and quantised to µu. A |post| beyond the travel
  ## limit is read as a PERCENT of the side and rescaled, which is what
  ## rescues a model that answered "80" meaning "80% along".
  var cu = value
  let limit = float(PaddleTravelHalf) / float(UuPerCu)
  if cu > limit or cu < -limit:
    cu = cu / 100.0 * limit
  if cu > limit: cu = limit
  if cu < -limit: cu = -limit
  int32(round(cu * float(UuPerCu)))

proc parseCabinetStance*(
  payload: JsonNode,
  myCabinet: int,
  cabinetOut: openArray[bool],
  ballLive: openArray[bool],
  catchEnabled: bool,
  previous: CabinetStance,
  havePrevious: bool
): CabinetStance =
  ## Turns one parsed reply into a legal stance, REPAIRING every field the
  ## schema bounds rather than rejecting the reply. Raises StanceError only
  ## when NO usable field can be recovered — that is the one condition the
  ## retry and then the scripted fallback exist for.
  if payload.isNil or payload.kind != JObject:
    raise newException(StanceError, "reply is not a JSON object")
  result = defaultStance()
  result.source = ssLlm
  var usable = 0

  # note / say
  if not payload{"note"}.isNil and payload{"note"}.kind == JString:
    result.note = sanitizeNote(payload{"note"}.getStr())
    if result.note.len > 0:
      inc usable
  if not payload{"say"}.isNil and payload{"say"}.kind == JString:
    result.say = sanitizeSay(payload{"say"}.getStr())

  # stance
  var stanceNode = payload{"stance"}
  if stanceNode.isNil or stanceNode.kind != JString:
    stanceNode = payload{"intent"}          ## a model that reused the word
  if not stanceNode.isNil and stanceNode.kind == JString:
    let parsed = parseStanceName(stanceNode.getStr())
    if parsed.ok:
      result.stance = parsed.stance
      inc usable
    elif havePrevious:
      result.stance = previous.stance
    else:
      result.stance = stGuard
  elif havePrevious:
    result.stance = previous.stance
  # `catch` in a ROM without catchEnabled behaves as `guard`.
  if result.stance == stCatch and not catchEnabled:
    result.stance = stGuard

  # target_ball
  let ballNode =
    if not payload{"target_ball"}.isNil: payload{"target_ball"}
    else: payload{"targetBall"}
  if not ballNode.isNil:
    result.targetBall = parseTargetBall(ballNode, ballLive)
    inc usable

  # aim_at
  let aimNode =
    if not payload{"aim_at"}.isNil: payload{"aim_at"} else: payload{"aimAt"}
  if not aimNode.isNil:
    result.aimAt = parseAimAt(aimNode, myCabinet, cabinetOut)
    inc usable

  # post
  let post = readNumber(payload{"post"})
  if post.ok:
    result.postUu = quantisePost(post.value)
    inc usable
  elif havePrevious:
    result.postUu = previous.postUu

  # lead_ticks
  let leadNode =
    if not payload{"lead_ticks"}.isNil: payload{"lead_ticks"}
    else: payload{"leadTicks"}
  let lead = readNumber(leadNode)
  if lead.ok:
    result.leadTicks = max(0, min(MaxLeadTicks, int(round(lead.value))))
    inc usable
  else:
    result.leadTicks = DefaultLeadTicks

  # aggression: an integer percentage is divided by 100 when it exceeds 1.
  let aggression = readNumber(payload{"aggression"})
  if aggression.ok:
    var value = aggression.value
    if value > 1.0:
      value = value / 100.0
    if value < 0.0: value = 0.0
    if value > 1.0: value = 1.0
    result.aggression255 = int(round(value * 255.0))
    inc usable
  else:
    result.aggression255 = DefaultAggression255

  if usable == 0:
    raise newException(StanceError, "reply carried no usable stance field")

proc validateStance*(
  stance: CabinetStance,
  myCabinet: int,
  cabinetOut: openArray[bool],
  ballLive: openArray[bool]
): string =
  ## "" when the stance is legal, else the first violation. The scripted
  ## baselines are held to exactly this (tests/test_baselines.nim).
  if stance.note.runeLen > MaxNoteRunes:
    return "note exceeds " & $MaxNoteRunes & " runes"
  if stance.say.runeLen > MaxSayRunes:
    return "say exceeds " & $MaxSayRunes & " runes"
  if stance.postUu < -PaddleTravelHalf or stance.postUu > PaddleTravelHalf:
    return "post is outside the travel limit"
  if stance.leadTicks < 0 or stance.leadTicks > MaxLeadTicks:
    return "lead_ticks is outside 0..48"
  if stance.aggression255 < 0 or stance.aggression255 > 255:
    return "aggression is outside 0..255"
  if stance.targetBall >= 0:
    if stance.targetBall >= ballLive.len or not ballLive[stance.targetBall]:
      return "target_ball names a ball that is not live"
  if stance.aimAt >= 0:
    if stance.aimAt == myCabinet:
      return "aim_at names my own cabinet"
    if stance.aimAt >= cabinetOut.len or cabinetOut[stance.aimAt]:
      return "aim_at names an eliminated cabinet"
  ""

# ---------------------------------------------------------------------------
#  Records
# ---------------------------------------------------------------------------

proc stanceRecordNode*(
  stance: CabinetStance, turn, seat, cabinet: int
): JsonNode =
  ## The replay chat record for one turn's stance. Re-applied at playback into
  ## NON-HASHED sim fields only: it drives the scorebug stance chips, the aim
  ## rays, the match feed and tools/replay_summary.py, and can never affect
  ## the simulation.
  # The caps are re-applied HERE, at the record boundary, not only on parse: a
  # stance can also be built by a scripted baseline or by a tool, and EVERY
  # string that reaches the replay must be inside its cap on a RUNE boundary.
  %*{
    "k": "stance",
    "turn": turn,
    "seat": seat,
    "alias": aliasOfCabinet(cabinet),
    "cabinet": cabinet,
    "source": $stance.source,
    "latency_ms": stance.latencyMs,
    "note": stance.note.truncateRunes(MaxNoteRunes),
    "stance": $stance.stance,
    "target_ball":
      (if stance.targetBall < 0: "any" else: "B" & $(stance.targetBall + 1)),
    "aim_at":
      (if stance.aimAt < 0: "none" else: aliasOfCabinet(stance.aimAt)),
    "post": stance.postCu(),
    "post_milli": int((int64(stance.postUu) * 1000'i64) div int64(UuPerCu)),
    "lead_ticks": stance.leadTicks,
    "aggression": stance.aggressionFraction(),
    "aggression_255": stance.aggression255,
    "say": stance.say.truncateRunes(MaxSayRunes)
  }

proc boundedStanceRecord*(
  stance: CabinetStance, turn, seat, cabinet: int
): string =
  ## The serialized stance record, guaranteed <= MaxStanceRecordRunes. The
  ## note is the only unbounded-in-practice field, so it is the one that
  ## shrinks, and the cut still lands on a RUNE boundary. Never cut the
  ## SERIALIZED string — that would emit broken JSON, which is the exact
  ## failure the rune rule exists to prevent.
  var trimmed = stance
  result = $trimmed.stanceRecordNode(turn, seat, cabinet)
  var guard = 0
  while result.runeLen > MaxStanceRecordRunes and guard < 12:
    inc guard
    let keep = max(0, trimmed.note.runeLen - max(8, trimmed.note.runeLen div 2))
    trimmed.note = trimmed.note.truncateRunes(keep)
    trimmed.say = trimmed.say.truncateRunes(max(0, trimmed.say.runeLen - 2))
    result = $trimmed.stanceRecordNode(turn, seat, cabinet)
