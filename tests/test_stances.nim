## Tolerant parsing and repair, and the RUNE discipline.

import std/[json, strutils, unicode, unittest]
import cabinet/[sim, stances]
import helpers

const
  NoneOut: array[CabinetCount, bool] = [false, false, false, false]
  BothLive = @[true, true]

proc parse(text: string, myCabinet = 2, cabinetOut = NoneOut,
    live = BothLive, catchEnabled = true,
    previous = defaultStance(), havePrevious = false): CabinetStance =
  parseCabinetStance(extractJsonObject(text), myCabinet, cabinetOut, live,
    catchEnabled, previous, havePrevious)

suite "stances":
  test "prose-prefixed and fenced JSON both parse":
    let a = parse("""Sure! Here is my stance:
```json
{"stance":"aim","aim_at":"BLUE","note":"take the shot"}
```
Hope that helps.""")
    check a.stance == stAim
    check a.aimAt == 1
    check a.note == "take the shot"
    let b = parse("""I think {"stance":"camp","post":12.5} is right""")
    check b.stance == stCamp
    check b.postUu == 125_000

  test "an integer percentage aggression is divided by 100":
    check parse("""{"aggression":80,"stance":"guard"}""").aggression255 == 204
    check parse("""{"aggression":"0.5","stance":"guard"}""").aggression255 == 128
    check parse("""{"aggression":1,"stance":"guard"}""").aggression255 == 255

  test "an out-of-range post given in percent is rescaled, then clamped":
    check parse("""{"post":80,"stance":"camp"}""").postUu == 344_000
    check parse("""{"post":-999,"stance":"camp"}""").postUu == -PaddleTravelHalf
    check parse("""{"post":43,"stance":"camp"}""").postUu == PaddleTravelHalf

  test "aim_at is accepted inside prose and rejected when it is me or out":
    check parse("""{"aim_at":"the red cabinet"}""").aimAt == 0
    check parse("""{"aim_at":"red"}""").aimAt == 0
    check parse("""{"aim_at":"GREEN"}""", myCabinet = 2).aimAt == -1
    var eliminated = NoneOut
    eliminated[1] = true
    check parse("""{"aim_at":"BLUE"}""", cabinetOut = eliminated).aimAt == -1
    check parse("""{"aim_at":"nobody"}""").aimAt == -1
    check parse("""{"aim_at":"RED and BLUE"}""").aimAt == -1

  test "target_ball is accepted as ball 2 / 2 / B2, and rejected when not live":
    check parse("""{"target_ball":"ball 2"}""").targetBall == 1
    check parse("""{"target_ball":"2"}""").targetBall == 1
    check parse("""{"target_ball":"B1"}""").targetBall == 0
    check parse("""{"target_ball":"any"}""").targetBall == -1
    check parse("""{"target_ball":"B3"}""").targetBall == -1
    check parse("""{"target_ball":"B2"}""", live = @[true, false]).targetBall == -1

  test "every stance synonym lands, and an unknown stance keeps last turn's":
    check parse("""{"stance":"defend"}""").stance == stGuard
    check parse("""{"stance":"shoot"}""").stance == stAim
    check parse("""{"stance":"attack"}""").stance == stAim
    check parse("""{"stance":"hold"}""").stance == stCamp
    check parse("""{"stance":"sit"}""").stance == stCamp
    check parse("""{"stance":"grab"}""").stance == stCatch
    check parse("""{"stance":"rush"}""").stance == stChase
    check parse("""{"stance":" AIM "}""").stance == stAim
    var previous = defaultStance()
    previous.stance = stChase
    check parse("""{"stance":"waltz","note":"?"}""",
      previous = previous, havePrevious = true).stance == stChase
    check parse("""{"stance":"waltz","note":"?"}""").stance == stGuard

  test "catch in a ROM without catchEnabled is repaired to guard":
    check parse("""{"stance":"catch"}""", catchEnabled = false).stance == stGuard
    check parse("""{"stance":"catch"}""", catchEnabled = true).stance == stCatch

  test "NaN and absent fields fall back to the documented defaults":
    let stance = parse("""{"stance":"guard","post":null,"lead_ticks":"nope"}""")
    check stance.postUu == 0
    check stance.leadTicks == DefaultLeadTicks
    check stance.aggression255 == DefaultAggression255
    var previous = defaultStance()
    previous.postUu = 90_000
    check parse("""{"stance":"guard"}""",
      previous = previous, havePrevious = true).postUu == 90_000

  test "a 300-character note is cut to 160 RUNES":
    let long = "x".repeat(300)
    let stance = parse("""{"note":"""" & long & """","stance":"guard"}""")
    check stance.note.runeLen == MaxNoteRunes
    check stance.note.validateUtf8() == -1

  test "a say whose 48th and 49th characters are a 4-byte emoji cuts on the RUNE boundary":
    # 47 ASCII runes, then a 4-byte emoji at rune 48, then another.
    let say = "a".repeat(47) & "\u{1F3AF}\u{1F3AF}"
    check say.runeLen == 49
    check say.len == 47 + 8
    var stance = defaultStance()
    stance.say = say
    let cut = say.truncateRunes(MaxSayRunes)
    check cut.runeLen == MaxSayRunes
    check cut.validateUtf8() == -1
    # the sanitiser drops the non-ASCII rune ENTIRELY rather than half of it
    let sanitised = sanitizeSay(say)
    check sanitised.validateUtf8() == -1
    check sanitised.runeLen <= MaxSayRunes
    check '{' notin sanitised
    # and the record round-trips through a strict JSON parser
    var record = defaultStance()
    record.say = say
    record.note = "\u{1F3AF}".repeat(200)
    let text = boundedStanceRecord(record, 3, 1, 2)
    check text.runeLen <= MaxStanceRecordRunes
    check text.validateUtf8() == -1
    let parsed = parseJson(text)
    check parsed["k"].getStr == "stance"
    check parsed["say"].getStr.runeLen <= MaxSayRunes

  test "a reply with no usable field raises, which is what the retry is for":
    expect StanceError:
      discard parse("""{"unrelated":true}""")
    expect StanceError:
      discard parse("""no json at all""")

  test "the emitted record carries both the readable float and the exact integers":
    var stance = defaultStance()
    stance.stance = stAim
    stance.aimAt = 1
    stance.targetBall = 0
    stance.postUu = -125_000
    stance.aggression255 = 204
    let node = stance.stanceRecordNode(7, 2, 3)
    check node["stance"].getStr == "aim"
    check node["aim_at"].getStr == "BLUE"
    check node["target_ball"].getStr == "B1"
    check node["post"].getFloat == -12.5
    check node["post_milli"].getInt == -12_500
    check node["aggression_255"].getInt == 204
    check node["alias"].getStr == "YELLOW"

  test "validateStance rejects exactly what the schema forbids":
    var stance = defaultStance()
    check stance.validateStance(2, NoneOut, BothLive) == ""
    stance.aimAt = 2
    check stance.validateStance(2, NoneOut, BothLive).len > 0
    stance.aimAt = 1
    var eliminated = NoneOut
    eliminated[1] = true
    check stance.validateStance(2, eliminated, BothLive).len > 0
    stance.aimAt = -1
    stance.targetBall = 1
    check stance.validateStance(2, NoneOut, @[true, false]).len > 0
    stance.targetBall = -1
    stance.postUu = PaddleTravelHalf + 1
    check stance.validateStance(2, NoneOut, BothLive).len > 0
