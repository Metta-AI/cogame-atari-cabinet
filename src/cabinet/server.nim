## The game server: mummy HTTP + websockets, the join/auth path, the per-turn
## decision layer, the recorded command-byte log and the artifact writes.
##
## Inherited from the starter's `src/ctf/server.nim` with FIVE named edits:
##
## 1. INPUT SOURCE. Where the starter reads `appState.inputMasks` (the socket)
##    into `inputs[playerIndex]`, the cabinet calls `control.paddleCommand`
##    for all four cabinets and passes the command-byte array into `sim.step`.
##    Player sockets contribute NO input: any input mask arriving on a player
##    socket is discarded.
## 2. REPLAY INPUT WRITE. `writeInputFrameMasks` (the press/release wrapper) is
##    DELETED — its `repeatedPressedMask` logic is button semantics and would
##    corrupt a value byte. The cabinet calls `writeInputMaskChange` directly
##    and `decodePaddle` replaces `decodeInputMask`, with the shared
##    `cmd >= 243 -> 40` repair.
## 3. TURN BOUNDARY. Immediately before stepping a tick where
##    `tick mod turnTicks == 0`, the loop runs `decide.turn`, which enforces
##    the inter-batch floor, issues ONE parallel batch over the ALIVE seats,
##    applies the two deadlines and writes the stance / fallback records — all
##    inside a monotonic `turnBudgetMs` bound.
## 4. WALL-CLOCK STOP. A `wallClockBudgetSeconds` check at the top of every
##    loop iteration forces GameOver / deadline / wall_clock.
## 5. SHUTDOWN GRACE. `/healthz` and `/global` keep answering for a bounded
##    ~20 s after the artifacts are written, then the process exits: the
##    episode runner pings `/global` with a 2 s deadline AFTER the player pods
##    start, and a short episode can already be gone.

import std/[json, locks, monotimes, nativesockets, os, strutils, tables, times]
import bitworld/client as bitworldClient
import bitworld/[runtime, spriteprotocol]
import mummy
import sim, global, replays, broadcast, replay_runtime, events, wire_constants
import stances, baselines, control, decide

when defined(posix):
  from std/posix import SHUT_RDWR, shutdown

type
  WebSocketSocketFields = object
    server: Server
    clientSocket: SocketHandle
    clientId: uint64

  WebSocketAppState = object
    lock: Lock
    replayLoaded: bool
    replayServerMode: bool
    chatMessages: Table[WebSocket, string]
    playerIndices: Table[WebSocket, int]
    playerAddresses: Table[WebSocket, string]
    playerSlots: Table[WebSocket, int]
    playerTokens: Table[WebSocket, string]
    playerReady: Table[WebSocket, bool]
    playerViewers: Table[WebSocket, PlayerViewerState]
    globalViewers: Table[WebSocket, GlobalViewerState]
    closedSockets: seq[WebSocket]
    nextAnonymousPlayer: int
    config: GameConfig

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

const
  HealthPath = "/healthz"
  ReplayDataPath = "/replay-data"
  BroadcastFontPath = "/client/font.ttf"
  MaxWsFrameBytes* = 900_000
    ## Hosted replay closes any WS frame larger than 1 MiB (1009 "message too
    ## big"), so outbound sprite packets are chunked under a margin below it.
  ShutdownGraceSeconds = 20
  PlayerReadyPacket = SpriteClientReady

  # The designed broadcast replay page, embedded at compile time: one
  # self-contained file with the shared chrome and the core JS inlined.
  EmbeddedBroadcastReplayHtml =
    staticRead("../../client/replay_broadcast.html").replace(
      "<!-- CHROME_COMMON -->",
      "<script>" & staticRead("../../client/chrome_common.js") & "</script>"
    ).replace(
      "<!-- BROADCAST_CORE -->",
      "<script>" & staticRead("../../client/broadcast_core.js") & "</script>"
    ).spliceWireConstants()
  EmbeddedLeagueReplayerHtml =
    staticRead("../../client/league_replayer.html").replace(
      "<!-- CHROME_COMMON -->",
      "<script>" & staticRead("../../client/chrome_common.js") & "</script>"
    ).spliceWireConstants()
  BroadcastFont = staticRead("../../data/font.ttf")
  StaticAssets = [
    ("/client/art/walls/wall_h.jpg",
      staticRead("../../client/art/walls/wall_h.jpg"), "image/jpeg"),
    ("/client/art/walls/wall_v.jpg",
      staticRead("../../client/art/walls/wall_v.jpg"), "image/jpeg"),
    ("/client/art/lockerroom/bg.jpg",
      staticRead("../../client/art/lockerroom/bg.jpg"), "image/jpeg"),
    ("/client/heart_red.png", staticRead("../../data/heart_red.png"),
      "image/png"),
    ("/client/heart_blue.png", staticRead("../../data/heart_blue.png"),
      "image/png"),
    ("/client/heart_green.png", staticRead("../../data/heart_green.png"),
      "image/png"),
    ("/client/heart_yellow.png", staticRead("../../data/heart_yellow.png"),
      "image/png")
  ]

var appState: WebSocketAppState
var replayBytesForClients: string

proc initAppState() =
  initLock(appState.lock)
  appState.chatMessages = initTable[WebSocket, string]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerAddresses = initTable[WebSocket, string]()
  appState.playerSlots = initTable[WebSocket, int]()
  appState.playerTokens = initTable[WebSocket, string]()
  appState.playerReady = initTable[WebSocket, bool]()
  appState.playerViewers = initTable[WebSocket, PlayerViewerState]()
  appState.globalViewers = initTable[WebSocket, GlobalViewerState]()
  appState.closedSockets = @[]
  appState.nextAnonymousPlayer = 1
  appState.config = defaultGameConfig()

proc isWebSocketUpgrade(request: Request): bool =
  request.headers["Sec-WebSocket-Key"].len > 0

proc markSocketClosed(websocket: WebSocket): bool =
  result = websocket notin appState.closedSockets
  if result:
    appState.closedSockets.add(websocket)

proc removePlayerWebSocketState(websocket: WebSocket): int =
  result = -1
  if websocket in appState.playerIndices:
    result = appState.playerIndices[websocket]
    appState.playerIndices.del(websocket)
  appState.playerViewers.del(websocket)
  appState.chatMessages.del(websocket)
  appState.playerAddresses.del(websocket)
  appState.playerSlots.del(websocket)
  appState.playerTokens.del(websocket)
  appState.playerReady.del(websocket)

proc isPlayerWebSocket(websocket: WebSocket): bool =
  websocket in appState.playerViewers and
    websocket notin appState.globalViewers

proc disconnectWebSocket(websocket: WebSocket) =
  when defined(posix):
    let fields = cast[WebSocketSocketFields](websocket)
    discard shutdown(fields.clientSocket, SHUT_RDWR)
  else:
    websocket.close()

proc cleanPlayerName(name: string): string =
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc playerSlotOf(request: Request): int =
  let text = request.queryParams.getOrDefault("slot", "").strip()
  if text.len == 0:
    return -1
  try:
    result = parseInt(text)
  except ValueError:
    return MaxPlayers
  if result < 0 or result >= MaxPlayers:
    return MaxPlayers

proc playerIdentity(request: Request, slot: int, token: string): string =
  let name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
  if name.len > 0:
    return name
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.configuredPlayerName(slot, token)
      if result.len > 0:
        return
      result = "Player" & $appState.nextAnonymousPlayer
      inc appState.nextAnonymousPlayer

proc hasPlayerCredentialParams(request: Request): bool =
  request.queryParams.getOrDefault("name", "").strip().len > 0 or
    request.queryParams.getOrDefault("slot", "").strip().len > 0 or
    request.queryParams.getOrDefault("token", "").strip().len > 0

proc respondText(request: Request, status: int, body: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  request.respond(status, headers, body)

proc respondForbidden(request: Request, reason: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(403, headers, reason & "\n")

proc respondHtml(request: Request, body: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  request.respond(200, headers, body)

proc httpHandler(request: Request) =
  ## `/client/global` and `/client/player` serve REAL pages and neither opens
  ## the player socket: the certifier probes them (plus /healthz and a
  ## bad-token player websocket) BEFORE starting the player pods, and they are
  ## registered ahead of the catch-all below (lantern 0.1.1).
  if request.path == HealthPath and request.httpMethod == "GET":
    request.respondText(200, "healthy")
  elif request.path == WebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let
      slot = request.playerSlotOf()
      token = request.queryParams.getOrDefault("token", "").strip()
      identity = request.playerIdentity(slot, token)
    {.gcsafe.}:
      withLock appState.lock:
        if not appState.config.playerJoinAllowed(identity, slot, token):
          request.respondForbidden(
            "Player credentials do not match the configured roster.")
          return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers.del(websocket)
        discard removePlayerWebSocketState(websocket)
        appState.playerViewers[websocket] = initPlayerViewerState()
        appState.playerAddresses[websocket] = identity
        appState.playerSlots[websocket] = slot
        appState.playerTokens[websocket] = token
        appState.playerIndices[websocket] =
          if appState.replayLoaded: -1 else: 0x7fffffff
        appState.playerReady[websocket] = false
    echo "player connected: ", identity
  elif (request.path == GlobalWebSocketPath or
      request.path == ReplayWebSocketPath) and
      request.httpMethod == "GET" and request.isWebSocketUpgrade():
    if request.hasPlayerCredentialParams():
      request.respondForbidden(
        "Viewer websocket cannot include player name, slot, or token.")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        discard removePlayerWebSocketState(websocket)
        appState.globalViewers[websocket] = initGlobalViewerState()
  elif request.path == ReplayDataPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "application/octet-stream"
    headers["Cache-Control"] = "no-cache"
    {.gcsafe.}:
      request.respond(200, headers, replayBytesForClients)
  elif request.path in [
      bitworldClient.ReplayClientRoute,
      bitworldClient.CoworldReplayClientRoute] and
      request.httpMethod == "GET":
    request.respondHtml(EmbeddedBroadcastReplayHtml)
  elif request.path == "/client/league" and request.httpMethod == "GET":
    request.respondHtml(EmbeddedLeagueReplayerHtml)
  elif request.path in [
      bitworldClient.PlayerClientRoute,
      bitworldClient.CoworldPlayerClientRoute] and
      request.httpMethod == "GET":
    request.respondHtml(EmbeddedBroadcastReplayHtml)
  elif request.path in [
      bitworldClient.GlobalClientRoute,
      bitworldClient.CoworldGlobalClientRoute] and
      request.httpMethod == "GET":
    request.respondHtml(EmbeddedBroadcastReplayHtml)
  elif request.path == BroadcastFontPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "font/ttf"
    headers["Cache-Control"] = "public, max-age=3600"
    request.respond(200, headers, BroadcastFont)
  elif request.httpMethod == "GET" and (block:
      var hit = false
      for (path, _, _) in StaticAssets:
        if request.path == path:
          hit = true
          break
      hit):
    for (path, body, mime) in StaticAssets:
      if request.path == path:
        var headers: HttpHeaders
        headers["Content-Type"] = mime
        headers["Cache-Control"] = "public, max-age=3600"
        request.respond(200, headers, body)
        break
  else:
    request.respondText(200, "atari-cabinet server")

proc websocketHandler(
  websocket: WebSocket, event: WebSocketEvent, message: Message
) =
  case event
  of OpenEvent:
    discard
  of MessageEvent:
    if message.kind == Ping:
      websocket.send(message.data, Pong)
    elif message.kind == BinaryMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if message.data.len == 1 and
              uint8(message.data[0]) == PlayerReadyPacket:
            if websocket in appState.playerReady:
              appState.playerReady[websocket] = true
          elif websocket in appState.globalViewers:
            appState.globalViewers[websocket].applyGlobalViewerMessage(
              message.data)
          elif websocket in appState.playerViewers:
            # INPUT MASKS FROM A SEAT ARE DISCARDED (named edit 1). Only the
            # registration chat is read.
            var chatText = ""
            appState.playerViewers[websocket].applyPlayerViewerMessage(
              message.data, chatText)
            if chatText.len > 0:
              appState.chatMessages[websocket] = chatText
  of ErrorEvent, CloseEvent:
    var who = ""
    {.gcsafe.}:
      withLock appState.lock:
        if markSocketClosed(websocket) and
            websocket in appState.playerAddresses:
          who = appState.playerAddresses[websocket]
    if who.len > 0:
      echo "player disconnected: ", who

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc parseRegistration*(
  text: string
): tuple[ok: bool, prompt, scripted, policy: string] =
  ## A seat's ONE Sprite v1 chat message, read as its registration:
  ##   {"type":"register","prompt":"…","scripted":"bulwark"|null,"policy":"…"}
  ## Anything that is not that object is not a registration and is dropped:
  ## cabinets do not chat.
  result = (false, "", "", "")
  if text.len == 0 or text[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return
  if node.kind != JObject or node{"type"}.getStr() != "register":
    return
  result.ok = true
  result.prompt = node{"prompt"}.getStr()
  if not node{"scripted"}.isNil and node{"scripted"}.kind == JString:
    result.scripted = node{"scripted"}.getStr()
  result.policy = node{"policy"}.getStr()

proc declarePlayerFailure(slot: int, message: string) =
  ## The game-declared terminal player failure the platform runner polls for,
  ## so a lobby no-show is charged to the seat that caused it instead of
  ## poisoning the whole episode unattributed. Best-effort: outside the
  ## platform (env unset) this is a no-op.
  try:
    writeCogameEnv(
      "COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json")
  except CatchableError as e:
    echo "player-failure declaration failed: ", e.msg

proc runFrameLimiter(
  previousTick: var MonoTime, fastMode: bool, sockets: openArray[WebSocket]
) =
  ## Wall-clock frame pacing, with `fastMode`'s early advance once every
  ## connected seat has acknowledged the frame.
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
  while true:
    let elapsed = getMonoTime() - previousTick
    if elapsed >= frameDuration:
      break
    if fastMode and sockets.len > 0:
      var allReady = true
      {.gcsafe.}:
        withLock appState.lock:
          for websocket in sockets:
            if not appState.playerReady.getOrDefault(websocket, false):
              allReady = false
              break
      if allReady:
        break
    sleep(1)
  previousTick = getMonoTime()

proc runServerLoop*(
  host = "0.0.0.0",
  port = 8080,
  initialConfig = defaultGameConfig(),
  saveReplayPath = "",
  loadReplayPath = "",
  runtimeConfig = RuntimeConfig()
) =
  initAppState()
  if saveReplayPath.len > 0 and loadReplayPath.len > 0:
    raise newException(ReplayError, "Cannot save and load a replay together")
  var replayLoaded = loadReplayPath.len > 0
  var replayData =
    if replayLoaded:
      try:
        loadReplay(loadReplayPath)
      except CatchableError as e:
        # A bad or version-mismatched replay must not kill the server: the
        # viewer would see a dead socket with no explanation.
        echo "replay load failed (serving without replay): ", e.msg
        replayLoaded = false
        ReplayData()
    else:
      ReplayData()
  if replayLoaded:
    replayBytesForClients = readFile(loadReplayPath)
  var initialized =
    if replayLoaded: initReplayRuntime(replayData, runtimeConfig.mismatchQuit)
    else: InitializedReplay()
  var config =
    if replayLoaded: move(initialized.config) else: initialConfig
  var
    replayWriter = openReplayWriter(saveReplayPath, config.configJson())
    replayPlayer =
      if replayLoaded: move(initialized.player) else: ReplayPlayer()
  defer:
    replayWriter.closeReplayWriter()
  appState.replayLoaded = replayLoaded
  appState.replayServerMode = replayLoaded
  appState.config = config

  # The tier-2 event sink and the metrics sink: file:// ONLY, and a loud
  # failure otherwise rather than a silently dropped stream.
  proc filePathOf(name: string): string =
    let uri = getEnv(name)
    if uri.len == 0: ""
    elif uri.startsWith("file://"): uri[7 .. ^1]
    else:
      raise newException(
        ValueError, name & " must be a file:// path, got: " & uri)
  let
    eventsPath = filePathOf("COGAME_EVENTS_URI")
    metricsPath = filePathOf("COGAME_METRICS_URI")

  var
    game =
      if replayLoaded: move(initialized.sim) else: initSimServer(config)
    lastTick = getMonoTime()
    collectedEvents: seq[SimEvent] = @[]
  game.collectEvents = eventsPath.len > 0
  block:
    # Bake the board caches BEFORE the listener opens: a viewer's first-message
    # clock starts at its successful connect, so nothing may be accepted until
    # every frame the loop will ever build can be assembled instantly.
    let warmStart = getMonoTime()
    game.warmBoardRenderCaches()
    echo "board render caches baked in ",
      (getMonoTime() - warmStart).inMilliseconds, " ms"

  let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 4)
  var
    serverThread: Thread[ServerThreadArgs]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()
  echo "atari-cabinet listening on ", host, ":", port

  var
    engine = if replayLoaded: DecisionEngine() else: initDecisionEngine(game)
    seatsSeated = false
    forceStart = false
    lastTurnKey = -1
    episodeStart = getMonoTime()
    deadlineHit = false
    quitAfterFrame = false
    broadcastTracker =
      if replayLoaded: move(initialized.tracker) else: initBroadcastTracker()
    liveSpeedIndex = 0
    commands = newSeq[uint8](CabinetCount)
    turnsRun = 0
  for seat in 0 ..< CabinetCount:
    commands[seat] = NeutralCommand

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      playerViewerStates: seq[PlayerViewerState] = @[]
      socketsToClose: seq[WebSocket] = @[]
      globalViewers: seq[WebSocket] = @[]
      globalStates: seq[GlobalViewerState] = @[]
      replayCommands: seq[char] = @[]
      replaySeekTicks: seq[int] = @[]

    # --- named edit 4: the engine's own hard stop -------------------------
    if not replayLoaded and not deadlineHit and
        (getMonoTime() - episodeStart).inSeconds.int >=
          config.wallClockBudgetSeconds:
      deadlineHit = true
      echo "wall-clock budget of ", config.wallClockBudgetSeconds,
        "s reached; scoring the board as it stands"
      game.stopForWallClock()
      quitAfterFrame = true

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          # A seat that drops keeps its cabinet for the whole episode: its
          # stance source degrades to `bulwark` and it revives on reconnect.
          discard removePlayerWebSocketState(websocket)
          appState.globalViewers.del(websocket)
        appState.closedSockets.setLen(0)

        if not replayLoaded and not seatsSeated and game.lobbyJoinTimedOut():
          # A seat that never connects does NOT end the episode. Report the
          # no-show (lowest missing slot only), then start anyway: that
          # cabinet plays the published `bulwark` baseline for the whole run.
          let stuckSlot = game.nextPlayerSlot()
          declarePlayerFailure(stuckSlot,
            "player slot " & $stuckSlot & " never joined the lobby within " &
            $config.lobbyJoinTimeoutTicks & " lobby ticks (~" &
            $(config.lobbyJoinTimeoutTicks div TargetFps) &
            "s); its cabinet plays the bulwark baseline")
          forceStart = true

        if not replayLoaded:
          var pending: seq[WebSocket]
          for websocket, index in appState.playerIndices:
            if websocket.isPlayerWebSocket() and index == 0x7fffffff:
              pending.add(websocket)
          var progressed = true
          while progressed:
            progressed = false
            for websocket in pending:
              if appState.playerIndices.getOrDefault(websocket, -1) !=
                  0x7fffffff:
                continue
              let
                address = appState.playerAddresses.getOrDefault(
                  websocket, "unknown")
                slot = appState.playerSlots.getOrDefault(websocket, -1)
                token = appState.playerTokens.getOrDefault(websocket, "")
              if game.phase != Lobby:
                appState.playerIndices[websocket] = -1
                continue
              var resolved = -1
              try:
                resolved = game.resolvePlayerSlot(address, token, slot)
              except CabinetError:
                appState.playerIndices[websocket] = -1
                socketsToClose.add(websocket)
                continue
              if resolved != game.nextPlayerSlot():
                continue           ## joins are strictly slot-sequential
              try:
                appState.playerIndices[websocket] =
                  game.addPlayer(address, slot, token)
              except CabinetError:
                appState.playerIndices[websocket] = -1
                socketsToClose.add(websocket)
                continue
              appState.playerSlots[websocket] = resolved
              replayWriter.writeJoin(
                tickTime(game.tickCount), resolved, address, slot, token)
              while replayWriter.lastMasks.len < CabinetCount:
                replayWriter.lastMasks.add(NeutralCommand)
              progressed = true
          if not seatsSeated and game.phase == Lobby and
              (game.players.len >= config.numAgents or forceStart):
            while replayWriter.lastMasks.len < CabinetCount:
              replayWriter.lastMasks.add(NeutralCommand)
            seatsSeated = true
            for seat in 0 ..< CabinetCount:
              game.seatPolicyKind[seat] = engine.policyKind(seat)
            echo "cabinet seated: ", game.players.len, " seats, perm ",
              game.perm, " rom ", config.rom

          # Registrations that cannot be applied YET are HELD, not dropped:
          # joins are slot-sequential and the lobby sends frames to a socket
          # before it is admitted, so a seat's first registration AND its
          # re-send can both land while its player index is still 0x7fffffff.
          # Dropping them made a champion play the scripted baseline for a
          # whole episode (paintball round 3, 2026-08-25).
          var held: seq[(WebSocket, string)]
          for websocket, chatText in appState.chatMessages:
            let index = appState.playerIndices.getOrDefault(websocket, -1)
            if index < 0 or index >= CabinetCount:
              if websocket.isPlayerWebSocket() and
                  parseRegistration(chatText).ok:
                held.add((websocket, chatText))
              continue
            let registration = parseRegistration(chatText)
            if not registration.ok:
              continue
            var policy = engine.seats[index]
            let first = not policy.registered
            policy.registered = true
            policy.prompt = registration.prompt.truncateRunes(MaxPromptRunes)
            policy.isLlm = policy.prompt.len > 0
            policy.baseline = parseBaseline(registration.scripted)
            policy.label =
              if registration.policy.len > 0: registration.policy
              elif policy.isLlm: "prompt"
              else: $policy.baseline
            engine.seats[index] = policy
            game.seatPolicyKind[index] = engine.policyKind(index)
            if first:
              # ONE `register` record and one log line per seat: the seat
              # re-sends its registration for the first ~10 s of frames.
              replayWriter.writeChat(
                tickTime(game.tickCount), index,
                registerRecord(index, game.cabinetOfSeat(index), policy.label,
                  engine.policyKind(index), $policy.baseline))
              echo "seat ", index, " registered: kind=",
                engine.policyKind(index), " baseline=", $policy.baseline
          appState.chatMessages.clear()
          for (websocket, chatText) in held:
            appState.chatMessages[websocket] = chatText

        for websocket, index in appState.playerIndices:
          if not websocket.isPlayerWebSocket():
            continue
          sockets.add(websocket)
          playerIndices.add(index)
          playerViewerStates.add(appState.playerViewers[websocket])
        for websocket, state in appState.globalViewers:
          globalViewers.add(websocket)
          globalStates.add(state)
          if state.replaySeekTick >= 0:
            replaySeekTicks.add(state.replaySeekTick)
          for command in state.replayCommands:
            replayCommands.add(command)
          appState.globalViewers[websocket].replayCommands.setLen(0)
          appState.globalViewers[websocket].replaySeekTick = -1

    for websocket in socketsToClose:
      websocket.disconnectWebSocket()

    # --- named edit 3: the decision turn, then the compiled command bytes --
    var frameEvents = newJArray()
    if replayLoaded:
      frameEvents = replayPlayer.advanceReplayFrame(
        game, broadcastTracker, replaySeekTicks, replayCommands)
    else:
      for command in replayCommands:
        liveSpeedIndex.applySpeedCommand(command)
      if seatsSeated and game.phase == Playing:
        let
          elapsedSeconds = (getMonoTime() - episodeStart).inSeconds.int
          turnTicks = max(1, config.turnTicks)
          turnIndex = game.gameTicksElapsed() div turnTicks
        if game.gameTicksElapsed() mod turnTicks == 0 and
            turnIndex != lastTurnKey:
          lastTurnKey = turnIndex
          inc turnsRun
          let records = engine.turn(game, turnIndex, elapsedSeconds)
          for record in records:
            replayWriter.writeChat(tickTime(game.tickCount), 0, record)
          for seat in 0 ..< CabinetCount:
            if not engine.haveStance[seat]:
              continue
            let stance = engine.stances[seat]
            case stance.source
            of ssLlm: inc game.llmTurns[seat]
            of ssFallback: inc game.fallbackTurns[seat]
            of ssScripted: discard
            let record = boundedStanceRecord(
              stance, turnIndex, seat, game.cabinetOfSeat(seat))
            replayWriter.writeChat(tickTime(game.tickCount), seat, record)
            game.applyStanceRecord(record)
            game.emitEvent(StanceSet, cabinet = game.cabinetOfSeat(seat),
              amount = turnIndex, detail = $stance.stance)
      # Compile ONE byte per cabinet, in CABINET INDEX ORDER, every tick, and
      # record it against the driving SEAT.
      for cabinet in 0 ..< CabinetCount:
        let seat = game.seatOfCabinet(cabinet)
        if seat < 0:
          continue
        let stance =
          if engine.haveStance.len > seat and engine.haveStance[seat]:
            engine.stances[seat]
          else:
            game.bulwarkStance(cabinet, engine.params)
        commands[seat] = game.paddleCommand(cabinet, stance)
      for seat in 0 ..< CabinetCount:
        replayWriter.writeInputMaskChange(
          tickTime(game.tickCount), seat, commands[seat])
      var faultRule = ""
      try:
        game.step(commands)
      except SimGuardError as guard:
        echo "cabinet: SIM GUARD tripped at tick ", game.tickCount, ": ",
          guard.msg
        faultRule = EndRuleSimFault
      except CatchableError as error:
        echo "cabinet: HOST ERROR at tick ", game.tickCount, ": ", error.msg
        faultRule = EndRuleHostError
      if faultRule.len > 0:
        game.faultGame(faultRule)
        quitAfterFrame = true
      replayWriter.writeHash(uint32(game.tickCount), game.gameHash())
      if game.collectEvents:
        for event in game.events:
          collectedEvents.add(event)
        game.events.setLen(0)
      game.stepEvents(broadcastTracker, frameEvents)
      if game.phase == GameOver and game.gameOverTimer <= 0:
        quitAfterFrame = true

    if not replayLoaded and config.fastMode:
      {.gcsafe.}:
        withLock appState.lock:
          for websocket in sockets:
            if websocket in appState.playerReady:
              appState.playerReady[websocket] = false

    # --- the seat streams -------------------------------------------------
    for i in 0 ..< sockets.len:
      var nextState: PlayerViewerState
      let packet = game.buildSpriteProtocolPlayerUpdates(
        playerIndices[i], playerViewerStates[i], nextState)
      {.gcsafe.}:
        withLock appState.lock:
          if sockets[i] in appState.playerViewers:
            appState.playerViewers[sockets[i]] = nextState
      try:
        if packet.len == 0:
          sockets[i].send("", BinaryMessage)
        for chunk in chunkSpritePacket(packet, MaxWsFrameBytes):
          sockets[i].send(blobFromBytes(chunk), BinaryMessage)
      except CatchableError:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(sockets[i])

    # --- the spectator streams -------------------------------------------
    for i in 0 ..< globalViewers.len:
      var nextState: GlobalViewerState
      let packet =
        if replayLoaded:
          game.buildReplayViewerPacket(
            replayPlayer, globalStates[i], nextState, frameEvents)
        else:
          game.buildLiveViewerPacket(
            globalStates[i], nextState, frameEvents, game.tickCount,
            playbackSpeed(liveSpeedIndex), config.maxTicks)
      if packet.len == 0:
        continue
      try:
        for chunk in chunkSpritePacket(packet, MaxWsFrameBytes):
          globalViewers[i].send(blobFromBytes(chunk), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if globalViewers[i] in appState.globalViewers:
              # The websocket thread keeps writing viewer INPUT into this
              # entry while the frame was being built from an earlier
              # snapshot; blindly storing nextState would erase a seek or a
              # command that landed in between.
              let pending = appState.globalViewers[globalViewers[i]]
              var merged = nextState
              merged.mouseX = pending.mouseX
              merged.mouseY = pending.mouseY
              merged.mouseLayer = pending.mouseLayer
              merged.mouseDown = pending.mouseDown
              if pending.clickPending:
                merged.clickPending = true
              if pending.replaySeekTick >= 0:
                merged.replaySeekTick = pending.replaySeekTick
              if pending.replayCommands.len > 0:
                merged.replayCommands.add(pending.replayCommands)
              appState.globalViewers[globalViewers[i]] = merged
      except CatchableError:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(globalViewers[i])

    if quitAfterFrame:
      # The `result` control record: the whole results document, written once
      # into the replay chat stream, so the bytes are SELF-SUFFICIENT.
      replayWriter.writeChat(tickTime(game.tickCount), 0, resultRecord(game))
      replayWriter.closeReplayWriter()
      if saveReplayPath.len > 0 and fileExists(saveReplayPath):
        echo "Replay written: ", saveReplayPath, " (",
          getFileSize(saveReplayPath), " bytes)"
        runtimeConfig.writeReplay(readFile(saveReplayPath))
      if eventsPath.len > 0:
        # Always written when a sink is configured, even with zero events: the
        # summary row is how a reader tells "this match had none" from "the
        # upload never happened".
        writeFile(eventsPath, collectedEvents.eventsJsonl(game.tickCount))
        echo "Events written: ", eventsPath, " (", collectedEvents.len,
          " events)"
      if runtimeConfig.resultsUri.len > 0:
        runtimeConfig.writeResults(game.playerResultsJson() & "\n")
      if metricsPath.len > 0:
        writeFile(metricsPath, $(%*{
          "ticks": game.tickCount,
          "turns": turnsRun,
          "reason": game.endReason,
          "endRule": game.endRule
        }) & "\n")
      echo "episode over: ", game.endReason, "/", game.endRule, " after ",
        game.tickCount, " ticks and ", turnsRun, " decision turns"
      # --- named edit 5: bounded shutdown grace --------------------------
      let graceUntil =
        getMonoTime() + initDuration(seconds = ShutdownGraceSeconds)
      while getMonoTime() < graceUntil:
        sleep(200)
      httpServer.close()
      joinThread(serverThread)
      break

    runFrameLimiter(lastTick, not replayLoaded and config.fastMode, sockets)
