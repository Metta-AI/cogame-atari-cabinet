## GameConfig lifecycle: defaults, the tolerant JSON reader, validation and
## the config echo the replay carries.
##
## The ROM preset is applied HERE, between the schema defaults and the
## explicitly supplied keys (rom.applyPreset), which is the order
## tests/test_rom.nim pins and the order the certification fixture relies on
## when it overrides `startingLives: 9` on top of `rom: "warlords"`.
##
## NO FLOATING POINT IN THIS FILE.

import std/[json, strutils]
import sim_types, arena, rom

proc defaultGameConfig*(): GameConfig =
  ## Schema defaults. Every field is also a `config_schema` property in
  ## coworld_manifest_template.json — tests/test_manifest.nim asserts the
  ## schema covers every field `update` reads.
  GameConfig(
    seed: 0,
    speed: 1,
    numAgents: CabinetCount,
    minPlayers: MinPlayersDefault,
    maxTicks: MaxTicksDefault,
    maxGames: 1,
    startWaitTicks: DefaultStartWaitTicks,
    gameOverTicks: DefaultGameOverTicks,
    lobbyJoinTimeoutTicks: DefaultLobbyJoinTimeoutTicks,
    fastMode: true,
    showPlayerLabels: false,
    closedRoster: false,
    slots: @[],
    turnTicks: DefaultTurnTicks,
    turnBudgetMs: DefaultTurnBudgetMs,
    attempt1Ms: DefaultAttempt1Ms,
    retryMs: DefaultRetryMs,
    turnSpacingMs: DefaultTurnSpacingMs,
    wallClockBudgetSeconds: DefaultWallClockBudgetSeconds,
    model: "",
    maxOutputTokens: DefaultMaxOutputTokens,
    rom: RomWarlords,
    startingLives: 3,
    ballCount: 2,
    brickRows: 1,
    catchEnabled: true,
    farPaddle: false,
    goalHalfCu: 18,
    paddleHalfCu: 7,
    farPaddleHalfCu: 5,
    ballSpeed0Milli: 550,
    ballSpeedStepMilli: 35,
    ballSpeedMaxMilli: 1300,
    holdTicksMax: int(HoldTicksMax),
    serveDelayTicks: int(ServeDelayTicks)
  )

proc readConfigInt(node: JsonNode, name: string, value: var int) =
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JInt:
    raise newException(
      CabinetError, "Config field " & name & " must be an integer.")
  value = item.getInt()

proc readConfigBool(node: JsonNode, name: string, value: var bool) =
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JBool:
    raise newException(
      CabinetError, "Config field " & name & " must be a boolean.")
  value = item.getBool()

proc readConfigString(node: JsonNode, name: string, value: var string) =
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JString:
    raise newException(
      CabinetError, "Config field " & name & " must be a string.")
  value = item.getStr()

proc readConfigSlots(node: JsonNode, slots: var seq[PlayerSlotConfig]) =
  if not node.hasKey("slots"):
    return
  let items = node["slots"]
  if items.kind != JArray:
    raise newException(CabinetError, "Config field slots must be an array.")
  if items.len > MaxPlayers:
    raise newException(
      CabinetError,
      "Config field slots cannot have more than " & $MaxPlayers & " entries.")
  if slots.len < items.len:
    slots.setLen(items.len)
  for i, item in items.elems:
    if item.kind != JObject:
      raise newException(
        CabinetError, "Config field slots[" & $i & "] must be an object.")
    item.readConfigString("token", slots[i].token)
    item.readConfigString("alias", slots[i].alias)

proc readConfigPlayers(node: JsonNode, slots: var seq[PlayerSlotConfig]) =
  if not node.hasKey("players"):
    return
  let items = node["players"]
  if items.kind != JArray:
    raise newException(CabinetError, "Config field players must be an array.")
  if items.len > MaxPlayers:
    raise newException(
      CabinetError,
      "Config field players cannot have more than " & $MaxPlayers &
        " entries.")
  if slots.len < items.len:
    slots.setLen(items.len)
  for i, item in items.elems:
    if item.kind != JObject:
      raise newException(
        CabinetError, "Config field players[" & $i & "] must be an object.")
    if not item.hasKey("name") or item["name"].kind != JString or
        item["name"].getStr().len == 0:
      raise newException(
        CabinetError,
        "Config field players[" & $i & "].name is required and must be a " &
          "non-empty string.")
    slots[i].name = item["name"].getStr()

proc readConfigTokens(node: JsonNode, slots: var seq[PlayerSlotConfig]) =
  if not node.hasKey("tokens"):
    return
  let items = node["tokens"]
  if items.kind != JArray:
    raise newException(CabinetError, "Config field tokens must be an array.")
  if items.len > MaxPlayers:
    raise newException(
      CabinetError,
      "Config field tokens cannot have more than " & $MaxPlayers & " entries.")
  if slots.len < items.len:
    slots.setLen(items.len)
  for i, item in items.elems:
    if item.kind != JString:
      raise newException(
        CabinetError, "Config field tokens[" & $i & "] must be a string.")
    slots[i].token = item.getStr()

proc validate*(config: GameConfig) =
  ## Every bound here is also a `config_schema` bound in the manifest, so a
  ## variant the platform accepts is a variant this sim will run.
  if not knownRom(config.rom):
    raise newException(
      CabinetError,
      "Config field rom must be one of " & RomNames.join(", ") & ", got \"" &
        config.rom & "\".")
  if config.numAgents < 1 or config.numAgents > CabinetCount:
    raise newException(
      CabinetError,
      "Config field num_agents must be between 1 and " & $CabinetCount & ".")
  if config.maxTicks <= 0:
    raise newException(CabinetError, "Config field maxTicks must be positive.")
  if config.turnTicks <= 0:
    raise newException(CabinetError, "Config field turnTicks must be positive.")
  if config.maxTicks mod config.turnTicks != 0:
    raise newException(
      CabinetError, "Config field maxTicks must be a multiple of turnTicks.")
  if config.startingLives < 1 or config.startingLives > 12:
    raise newException(
      CabinetError, "Config field startingLives must be between 1 and 12.")
  if config.ballCount < 1 or config.ballCount > MaxBalls:
    raise newException(
      CabinetError,
      "Config field ballCount must be between 1 and " & $MaxBalls & ".")
  if config.brickRows < 0 or config.brickRows > MaxBrickRows:
    raise newException(
      CabinetError,
      "Config field brickRows must be between 0 and " & $MaxBrickRows & ".")
  if config.goalHalfCu < 8 or config.goalHalfCu > 30:
    raise newException(
      CabinetError, "Config field goalHalfCu must be between 8 and 30.")
  if config.paddleHalfCu < 3 or config.paddleHalfCu > 12:
    raise newException(
      CabinetError, "Config field paddleHalfCu must be between 3 and 12.")
  if config.farPaddleHalfCu < 3 or config.farPaddleHalfCu > 12:
    raise newException(
      CabinetError, "Config field farPaddleHalfCu must be between 3 and 12.")
  if config.ballSpeed0Milli < 300 or config.ballSpeed0Milli > 900:
    raise newException(
      CabinetError, "Config field ballSpeed0Milli must be between 300 and 900.")
  if config.ballSpeedStepMilli < 0 or config.ballSpeedStepMilli > 120:
    raise newException(
      CabinetError,
      "Config field ballSpeedStepMilli must be between 0 and 120.")
  if config.ballSpeedMaxMilli < 500 or config.ballSpeedMaxMilli > 1600:
    raise newException(
      CabinetError,
      "Config field ballSpeedMaxMilli must be between 500 and 1600.")
  if config.ballSpeedMaxMilli < config.ballSpeed0Milli:
    raise newException(
      CabinetError,
      "Config field ballSpeedMaxMilli must not be below ballSpeed0Milli.")
  if config.holdTicksMax < 0 or config.holdTicksMax > 96:
    raise newException(
      CabinetError, "Config field holdTicksMax must be between 0 and 96.")
  if config.serveDelayTicks < 0 or config.serveDelayTicks > 120:
    raise newException(
      CabinetError, "Config field serveDelayTicks must be between 0 and 120.")
  if config.goalHalfCu * UuPerCu > PaddleTravelHalf + paddleHalfUu(config):
    raise newException(
      CabinetError,
      "Config field goalHalfCu is wider than the paddle can cover.")
  # DEGRADE, NEVER HANG. The two batch deadlines must fit inside the per-turn
  # budget, and a sub-second deadline is not the deadline it claims to be:
  # curly hands it to CURLOPT_TIMEOUT, whose granularity is whole seconds and
  # whose conversion FLOORS.
  if config.attempt1Ms < 1000 or config.retryMs < 1000:
    raise newException(
      CabinetError,
      "Config fields attempt1Ms and retryMs must be at least 1000 ms " &
        "(curly's CURLOPT_TIMEOUT granularity is whole seconds).")
  if config.attempt1Ms + config.retryMs > config.turnBudgetMs:
    raise newException(
      CabinetError,
      "Config fields attempt1Ms + retryMs must fit inside turnBudgetMs.")
  if config.wallClockBudgetSeconds <= 0:
    raise newException(
      CabinetError, "Config field wallClockBudgetSeconds must be positive.")

proc update*(config: var GameConfig, jsonText: string) =
  ## Applies one runtime config JSON: defaults -> the named ROM preset -> the
  ## explicitly supplied keys, then validate.
  if jsonText.len == 0:
    config.validate()
    return
  var node: JsonNode
  try:
    node = parseJson(jsonText)
  except CatchableError as e:
    raise newException(
      CabinetError, "Could not parse config JSON: " & e.msg)
  if node.kind != JObject:
    raise newException(CabinetError, "Config must be a JSON object.")

  # 1. the ROM name, 2. its preset over the defaults (skipping every key the
  # config named itself), 3. the explicit keys.
  node.readConfigString("rom", config.rom)
  if not knownRom(config.rom):
    raise newException(
      CabinetError,
      "Config field rom must be one of " & RomNames.join(", ") & ", got \"" &
        config.rom & "\".")
  var explicitKeys: seq[string]
  for key in node.keys:
    explicitKeys.add(key)
  config.applyPreset(explicitKeys)

  node.readConfigInt("seed", config.seed)
  node.readConfigInt("speed", config.speed)
  node.readConfigInt("num_agents", config.numAgents)
  node.readConfigInt("numAgents", config.numAgents)
  node.readConfigInt("minPlayers", config.minPlayers)
  node.readConfigInt("maxTicks", config.maxTicks)
  node.readConfigInt("maxGames", config.maxGames)
  node.readConfigInt("startWaitTicks", config.startWaitTicks)
  node.readConfigInt("gameOverTicks", config.gameOverTicks)
  node.readConfigInt("lobbyJoinTimeoutTicks", config.lobbyJoinTimeoutTicks)
  node.readConfigBool("fastMode", config.fastMode)
  node.readConfigBool("showPlayerLabels", config.showPlayerLabels)
  node.readConfigBool("closedRoster", config.closedRoster)
  node.readConfigInt("turnTicks", config.turnTicks)
  node.readConfigInt("turnBudgetMs", config.turnBudgetMs)
  node.readConfigInt("attempt1Ms", config.attempt1Ms)
  node.readConfigInt("retryMs", config.retryMs)
  node.readConfigInt("turnSpacingMs", config.turnSpacingMs)
  node.readConfigInt("wallClockBudgetSeconds", config.wallClockBudgetSeconds)
  node.readConfigString("model", config.model)
  node.readConfigInt("maxOutputTokens", config.maxOutputTokens)
  node.readConfigInt("startingLives", config.startingLives)
  node.readConfigInt("ballCount", config.ballCount)
  node.readConfigInt("brickRows", config.brickRows)
  node.readConfigBool("catchEnabled", config.catchEnabled)
  node.readConfigBool("farPaddle", config.farPaddle)
  node.readConfigInt("goalHalfCu", config.goalHalfCu)
  node.readConfigInt("paddleHalfCu", config.paddleHalfCu)
  node.readConfigInt("farPaddleHalfCu", config.farPaddleHalfCu)
  node.readConfigInt("ballSpeed0Milli", config.ballSpeed0Milli)
  node.readConfigInt("ballSpeedStepMilli", config.ballSpeedStepMilli)
  node.readConfigInt("ballSpeedMaxMilli", config.ballSpeedMaxMilli)
  node.readConfigInt("holdTicksMax", config.holdTicksMax)
  node.readConfigInt("serveDelayTicks", config.serveDelayTicks)
  node.readConfigSlots(config.slots)
  node.readConfigTokens(config.slots)
  node.readConfigPlayers(config.slots)
  if config.minPlayers > config.numAgents:
    config.minPlayers = config.numAgents
  config.validate()

proc seatCount*(config: GameConfig): int =
  max(1, min(CabinetCount, config.numAgents))

proc configuredPlayerName*(
  config: GameConfig, requestedSlot: int, token: string
): string =
  ## The configured identity for a tokenized slot request.
  if token.len == 0:
    return ""
  if requestedSlot >= 0 and requestedSlot < config.slots.len:
    let slot = config.slots[requestedSlot]
    if slot.name.len > 0 and slot.token.len > 0 and slot.token == token:
      return slot.name
    return ""
  for slot in config.slots:
    if slot.name.len > 0 and slot.token.len > 0 and slot.token == token:
      return slot.name

proc playerJoinAllowed*(
  config: GameConfig, address: string, slot: int, token: string
): bool =
  ## Whether a websocket may join at all (a 403 before the upgrade otherwise).
  if slot >= MaxPlayers:
    return false
  if slot >= config.slots.len:
    return not config.closedRoster
  if slot >= 0 and config.slots[slot].token.len > 0 and
      token != config.slots[slot].token:
    return false
  true

proc configJson*(config: GameConfig): string =
  ## The replay's config JSON: everything the wasm viewer needs to rebuild
  ## this exact episode, including the FULLY RESOLVED ROM preset, the seeded
  ## seat->cabinet permutation and the whole geometry table. The viewer never
  ## re-runs a generator, so a missing key here would re-simulate a different
  ## game.
  var
    players = newJArray()
    slots = newJArray()
    tokens = newJArray()
    includePlayers = false
  for i, slot in config.slots:
    if slot.name.len > 0:
      includePlayers = true
    tokens.add(%slot.token)
    players.add(%*{"name": slot.name})
    slots.add(%*{
      "alias":
        if slot.alias.len > 0: slot.alias
        else: aliasOfCabinet(i)
    })
  # `perm` is the FIRST draw of the seeded stream, so it is a pure function of
  # the seed and can be echoed here — before tick 0 — and the sim re-derives
  # the identical permutation (tests/test_determinism.nim (f)).
  var
    rng = initRngState(config.seed)
    draws: int32 = 0
    perm = drawPermutation(rng, draws)
    permJson = newJArray()
  for value in perm:
    permJson.add(%int(value))
  var node = %*{
    "seed": config.seed,
    "speed": config.speed,
    "num_agents": config.numAgents,
    "minPlayers": config.minPlayers,
    "maxTicks": config.maxTicks,
    "maxGames": config.maxGames,
    "startWaitTicks": config.startWaitTicks,
    "gameOverTicks": config.gameOverTicks,
    "lobbyJoinTimeoutTicks": config.lobbyJoinTimeoutTicks,
    "fastMode": config.fastMode,
    "showPlayerLabels": config.showPlayerLabels,
    "closedRoster": config.closedRoster,
    "turnTicks": config.turnTicks,
    "turnBudgetMs": config.turnBudgetMs,
    "attempt1Ms": config.attempt1Ms,
    "retryMs": config.retryMs,
    "turnSpacingMs": config.turnSpacingMs,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "maxOutputTokens": config.maxOutputTokens,
    "rom": config.rom,
    "startingLives": config.startingLives,
    "ballCount": config.ballCount,
    "brickRows": config.brickRows,
    "catchEnabled": config.catchEnabled,
    "farPaddle": config.farPaddle,
    "goalHalfCu": config.goalHalfCu,
    "paddleHalfCu": config.paddleHalfCu,
    "farPaddleHalfCu": config.farPaddleHalfCu,
    "ballSpeed0Milli": config.ballSpeed0Milli,
    "ballSpeedStepMilli": config.ballSpeedStepMilli,
    "ballSpeedMaxMilli": config.ballSpeedMaxMilli,
    "holdTicksMax": config.holdTicksMax,
    "serveDelayTicks": config.serveDelayTicks,
    "perm": permJson,
    "geometry": {
      "arenaSideUu": ArenaSide,
      "uuPerCu": UuPerCu,
      "ballHalfUu": BallHalf,
      "paddleDepthUu": PaddleDepth,
      "paddleThickHalfUu": PaddleThickHalf,
      "farPaddleDepthUu": FarPaddleDepth,
      "paddleTravelHalfUu": PaddleTravelHalf,
      "paddleStepSpeedUu": PaddleStepSpeed,
      "paddleMaxSpeedUu": PaddleMaxSpeed,
      "brickRowDepthLoUu": BrickRowDepthLo,
      "brickRowDepthHiUu": BrickRowDepthHi,
      "brickRow2DepthLoUu": BrickRow2DepthLo,
      "brickRow2DepthHiUu": BrickRow2DepthHi,
      "bricksPerRow": BricksPerRow,
      "brickHalfWidthUu": BrickHalfWidth,
      "brickColumnStepCu": BrickColumnStepCu,
      "outfanAngles": OutfanAngles,
      "boardUuPerPixel": BoardUuPerPixel,
      "mapWidth": MapWidth,
      "mapHeight": MapHeight
    },
    "rewards": {
      "perLifeKeptMicro": LivesTermMicro,
      "crownMicro": CrownMicro,
      "knockoutMicro": KnockoutMicro,
      "chipMicro": ChipMicro,
      "saveMicro": SaveMicro
    },
    "tokens": tokens,
    "slots": slots
  }
  if config.model.len > 0:
    node["model"] = %config.model
  if includePlayers:
    node["players"] = players
  $node
