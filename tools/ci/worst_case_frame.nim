## THE WORST-CASE TEXT FRAME — one frame, built to hurt, from the SHIPPED path.
##
## docker_smoke.sh runs with no ANTHROPIC_API_KEY, so every seat in every CI
## episode plays the scripted baseline and every replay CI can produce carries
## almost no model text. Nothing that plays such a replay can exercise the
## chrome that exists only to show what a model said (cogchemists, 2026-08-24).
##
## This module builds that missing frame WITHOUT re-implementing anything: a
## real `SimServer`, mid-rally, whose four seats have each just returned a
## worst-case LLM reply — a full-cap 48-rune `say` and a full-cap 160-rune
## `note`, wrapped in prose and a markdown fence — parsed by the real
## `parseCabinetStance`, recorded by the real `boundedStanceRecord` and applied
## by the real `applyStanceRecord`. The frame it returns is the real viewer
## packet: `global.addBoard`'s pixie-baked text sprites at the geometry
## `global.nim` places them at, plus the chrome JSON `broadcast.nim` writes.
##
## Two gates consume it:
##   * `tests/test_render_text.nim` — every baked string's placed rectangle is
##     inside the board, asserted in Nim against the same bytes;
##   * `tools/ci/gen_render_fixture.nim` — writes the packet out so
##     `tools/ci/renderer_fixture.html` can render it in a real browser through
##     the real `client/broadcast_core.js` and hand every drawn string to
##     `viewer_smoke.mjs --strict-text-bounds`.

import std/[json, unicode]
import bitworld/spriteprotocol
import cabinet/[sim, stances, broadcast, global, replay_runtime]

export sim, global, spriteprotocol

const
  WorstCaseStances* = ["aim", "chase", "catch", "camp"]
    ## One of each shape, so the chip strings differ in length per seat.

proc worstCaseReply*(alias, stance, aimAt: string): string =
  ## What a chatty model actually sends: prose, a fenced JSON object, and both
  ## string fields well OVER their cap so the server's own rune truncation is
  ## the thing that decides the final length. The note carries a 4-byte emoji
  ## so the caps are exercised in RUNES, not bytes.
  let note = alias & " is on one life and its wall is down to two bricks; " &
    "take the free shot now \u{1F3AF} and keep the middle lane covered until " &
    "the rebound comes back off the far wall, then reset to the post."
  # The 48th rune of every alias's say is a LETTER: `sanitizeSay` strips the
  # trimmed string, so a cut landing on a space would hand the fixture a
  # 47-rune remark and quietly weaken it.
  let say = alias & " takes the next shot and holds the near-corner-rebound" &
    "-lane while the wall holds"
  "Here is my move for this turn.\n\n```json\n" & $(%*{
    "note": note,
    "stance": stance,
    "target_ball": "any",
    "aim_at": aimAt,
    "post": 0.0,
    "lead_ticks": 12,
    "aggression": 0.8,
    "say": say
  }) & "\n```\nGood luck.\n"

proc worstCaseFrame*(
  rom = "warlords", seed = 20260826
): tuple[sim: SimServer, packet: seq[uint8]] =
  ## A playing arena with a full-cap remark on EVERY seat at once, and the
  ## viewer packet that state produces.
  var config = defaultGameConfig()
  config.update($(%*{
    "seed": seed,
    "rom": rom,
    "num_agents": 4,
    "minPlayers": 4,
    "maxTicks": 1440,
    "startWaitTicks": 1,
    "turnSpacingMs": 0,
    "players": [{"name": "P1"}, {"name": "P2"}, {"name": "P3"}, {"name": "P4"}],
    "tokens": ["token-0", "token-1", "token-2", "token-3"],
    "slots": [{"alias": "RED"}, {"alias": "BLUE"}, {"alias": "GREEN"},
              {"alias": "YELLOW"}]
  }))
  var game = initSimServer(config)
  game.gameEventLoggingEnabled = false
  for seat in 0 ..< CabinetCount:
    discard game.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
  # Mid-rally, not the serve: balls live, paddles off centre, one brick gone.
  var commands = newSeq[uint8](CabinetCount)
  for seat in 0 ..< CabinetCount:
    commands[seat] = NeutralCommand
  while game.phase == Lobby:
    game.step(commands)
  for _ in 0 ..< 48:
    game.step(commands)

  # The four replies, through the real parse -> record -> apply path.
  var cabinetOut: array[CabinetCount, bool]
  for k in 0 ..< CabinetCount:
    cabinetOut[k] = game.cabinets[k].isOut
  var live: seq[bool]
  for ball in game.balls:
    live.add(ball.state == bsLive)
  for seat in 0 ..< CabinetCount:
    let
      cabinet = game.cabinetOfSeat(seat)
      alias = aliasOfCabinet(cabinet)
      aimAt = aliasOfCabinet((cabinet + 1) mod CabinetCount)
      reply = worstCaseReply(alias, WorstCaseStances[seat], aimAt)
    var stance = parseCabinetStance(
      extractJsonObject(reply), cabinet, cabinetOut, live,
      config.catchEnabled, defaultStance(), false)
    stance.source = ssLlm
    stance.latencyMs = 1234
    game.applyStanceRecord(
      boundedStanceRecord(stance, 1, seat, cabinet))
    # The whole point of the fixture is FULL-CAP text: a reply that arrived
    # short would leave it passing while testing nothing (checklist item 15).
    let view = game.stances[seat]
    if view.say.runeLen != MaxSayRunes:
      raise newException(ValueError, "seat " & $seat & " say is " &
        $view.say.runeLen & " runes, expected " & $MaxSayRunes)
    if view.note.runeLen != MaxNoteRunes:
      raise newException(ValueError, "seat " & $seat & " note is " &
        $view.note.runeLen & " runes, expected " & $MaxNoteRunes)

  var
    tracker = initBroadcastTracker()
    events = newJArray()
    state = initGlobalViewerState()
    nextState: GlobalViewerState
  tracker.resync(game)
  game.stepEvents(tracker, events)
  result = (game, game.buildLiveViewerPacket(
    state, nextState, events, game.tickCount, 1, config.maxTicks))

proc chromeJson*(packet: seq[uint8]): string =
  ## The broadcast chrome JSON the packet carries — the same bytes
  ## broadcast_core.js routes to `onText`, read back out of the reserved 1x1
  ## sprite's label (`BroadcastChromeSpriteId`).
  for message in parseSpritePacket(packet):
    if message.kind == spkSprite and
        message.sprite.id == BroadcastChromeSpriteId:
      return message.sprite.label
  ""

type TextPlacement* = object
  ## One baked string as the board actually places it, in board pixels.
  text*: string
  spriteId*, objectId*, x*, y*, width*, height*: int

proc textPlacements*(packet: seq[uint8]): seq[TextPlacement] =
  ## Every string `global.addBoard` baked in this packet, with the rectangle
  ## the packet places it at. Read from the SHIPPED bytes with bitworld's own
  ## parser: nothing here re-derives a layout.
  var baked: seq[tuple[id, width, height: int, label: string]]
  for message in parseSpritePacket(packet):
    case message.kind
    of spkSprite:
      if message.sprite.id >= TextSpriteBase and
          message.sprite.id < TextSpriteBase + TextSpritePool:
        baked.add((message.sprite.id, message.sprite.width,
          message.sprite.height, message.sprite.label))
    of spkObject:
      for sprite in baked:
        if sprite.id == message.objectDef.spriteId:
          result.add(TextPlacement(
            text: sprite.label, spriteId: sprite.id,
            objectId: message.objectDef.id,
            x: message.objectDef.x, y: message.objectDef.y,
            width: sprite.width, height: sprite.height))
          break
    else:
      discard
