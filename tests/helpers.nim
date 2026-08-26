## Shared test scaffolding: run a whole episode against the scripted layer,
## exactly the way the server does it (one stance per seat per turn, one
## command byte per cabinet per tick), and collect what the assertions need.

import std/[json, os, strutils]
import cabinet/[sim, stances, control, baselines, decide, replays]

type
  EpisodeResult* = object
    sim*: SimServer
    ticks*: int
    commandLog*: seq[seq[uint8]]     ## one row per tick, one byte per seat
    hashes*: seq[uint64]
    concedes*: int
    saves*: int
    chips*: int
    catches*: int
    eliminated*: int
    winnerSeat*: int
    results*: JsonNode

proc episodeConfig*(
  seed: int, rom = "warlords", startingLives = 0, maxTicks = 2880,
  extra = ""
): GameConfig =
  ## The certification fixture's shape: four seats, no LLM, no batch spacing.
  var node = %*{
    "seed": seed,
    "rom": rom,
    "num_agents": 4,
    "minPlayers": 4,
    "maxTicks": maxTicks,
    "startWaitTicks": 1,
    "turnSpacingMs": 0,
    "players": [{"name": "P1"}, {"name": "P2"}, {"name": "P3"}, {"name": "P4"}],
    "tokens": ["token-0", "token-1", "token-2", "token-3"],
    "slots": [{"alias": "RED"}, {"alias": "BLUE"}, {"alias": "GREEN"},
              {"alias": "YELLOW"}]
  }
  if startingLives > 0:
    node["startingLives"] = %startingLives
  if extra.len > 0:
    for key, value in parseJson(extra):
      node[key] = value
  result = defaultGameConfig()
  result.update($node)

proc runEpisode*(
  config: GameConfig,
  kinds: array[CabinetCount, Baseline] = [
    blBulwark, blBulwark, blBulwark, blBulwark],
  params = DefaultBaselineParams,
  replayPath = ""
): EpisodeResult =
  ## One full episode. When `replayPath` is set the episode also writes a real
  ## `COWLDCAB` replay, with the same records the server writes.
  var game = initSimServer(config)
  game.gameEventLoggingEnabled = false
  for seat in 0 ..< CabinetCount:
    let slot = config.slotConfig(seat)
    discard game.addPlayer(
      (if slot.name.len > 0: slot.name else: "P" & $(seat + 1)), seat,
      slot.token)
  var writer = openReplayWriter(replayPath, config.configJson())
  defer: writer.closeReplayWriter()
  if replayPath.len > 0:
    for seat in 0 ..< CabinetCount:
      writer.lastMasks.add(NeutralCommand)
      writer.writeJoin(tickTime(0), seat, "P" & $(seat + 1), seat, "")
      writer.writeChat(tickTime(0), seat, registerRecord(
        seat, game.cabinetOfSeat(seat), $kinds[seat], "scripted",
        $kinds[seat]))
  var
    stances: array[CabinetCount, CabinetStance]
    commands = newSeq[uint8](CabinetCount)
    turn = 0
  for seat in 0 ..< CabinetCount:
    stances[seat] = defaultStance()
    game.seatPolicyKind[seat] = "scripted"
  while game.phase != GameOver and result.ticks < config.maxTicks + 600:
    if game.phase == Playing and
        game.gameTicksElapsed() mod config.turnTicks == 0:
      turn = game.gameTicksElapsed() div config.turnTicks
      for seat in 0 ..< CabinetCount:
        let cabinet = game.cabinetOfSeat(seat)
        stances[seat] = game.baselineStance(cabinet, kinds[seat], turn, params)
        stances[seat].source = ssScripted
        let record = boundedStanceRecord(stances[seat], turn, seat, cabinet)
        game.applyStanceRecord(record)
        if replayPath.len > 0:
          writer.writeChat(tickTime(game.tickCount), seat, record)
    for cabinet in 0 ..< CabinetCount:
      let seat = game.seatOfCabinet(cabinet)
      commands[seat] = game.paddleCommand(cabinet, stances[seat])
    if replayPath.len > 0:
      for seat in 0 ..< CabinetCount:
        writer.writeInputMaskChange(
          tickTime(game.tickCount), seat, commands[seat])
    result.commandLog.add(commands)
    game.step(commands)
    result.hashes.add(game.gameHash())
    if replayPath.len > 0:
      writer.writeHash(uint32(game.tickCount), game.gameHash())
    inc result.ticks
  for k in 0 ..< CabinetCount:
    result.concedes += int(game.cabinets[k].concedes)
    result.saves += int(game.cabinets[k].saves)
    result.chips += int(game.cabinets[k].chips)
    result.catches += int(game.cabinets[k].catches)
    if game.cabinets[k].isOut:
      inc result.eliminated
  result.winnerSeat = game.seatOfCabinet(game.winnerCabinet)
  result.results = parseJson(game.playerResultsJson())
  if replayPath.len > 0:
    writer.writeChat(tickTime(game.tickCount), 0, resultRecord(game))
  result.sim = game

proc replaySteps*(
  config: GameConfig, commandLog: seq[seq[uint8]]
): seq[uint64] =
  ## Re-simulate from the RECORDED bytes alone — the viewer's job.
  var game = initSimServer(config)
  game.gameEventLoggingEnabled = false
  for seat in 0 ..< CabinetCount:
    let slot = config.slotConfig(seat)
    discard game.addPlayer(
      (if slot.name.len > 0: slot.name else: "P" & $(seat + 1)), seat,
      slot.token)
  for row in commandLog:
    game.step(row)
    result.add(game.gameHash())

proc sourceText*(path: string): string =
  ## Reads a repo file from a test binary, whatever the cwd is.
  for prefix in ["", "..", "../.."]:
    let candidate = if prefix.len == 0: path else: prefix / path
    if fileExists(candidate):
      return readFile(candidate)
  raise newException(IOError, "test asset not found: " & path)

proc repoPath*(path: string): string =
  for prefix in ["", "..", "../.."]:
    let candidate = if prefix.len == 0: path else: prefix / path
    if fileExists(candidate) or dirExists(candidate):
      return candidate
  path

proc strippedComments*(text: string): string =
  ## Source text with every comment removed — whole-line AND trailing — so the
  ## "no float" / "no starter identifier" guards read CODE and never trip over
  ## a provenance note or a doc comment that quotes a constant. String
  ## literals are respected, so a `#` inside a string survives.
  for line in text.splitLines():
    var
      keep = ""
      inString = false
      escaped = false
      i = 0
    while i < line.len:
      let ch = line[i]
      if inString:
        keep.add(ch)
        if escaped: escaped = false
        elif ch == '\\': escaped = true
        elif ch == '"': inString = false
        inc i
        continue
      if ch == '"':
        inString = true
        keep.add(ch)
        inc i
        continue
      if ch == '#':
        break
      if ch == '/' and i + 1 < line.len and line[i + 1] == '/':
        break
      keep.add(ch)
      inc i
    result.add(keep)
    result.add('\n')
