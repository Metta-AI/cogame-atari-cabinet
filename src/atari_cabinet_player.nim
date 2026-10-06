## Ordinary cabinet player: complete standing orders over private seat views.
## PLAYER_PROMPT and inference credentials belong to this process only.
import std/[httpclient, json, options, os, strutils, uri]
import bitworld/spriteprotocol
import whisky
import curly
import cabinet/[sim_types, stances, baselines, player_baselines, player_llm, numeric_codec]

const
  ConnectAttempts = 240      ## 240 x 500 ms = 2 minutes of dialling.
  ConnectRetryMs = 500
  RegistrationResends = 10   ## re-sends after the first, ~1 s apart.
  ResendEveryFrames = 24     ## ~1 s of frames at 24 Hz.
  ReconnectAttempts = 6

proc registrationBlob(prompt, scripted, policy: string, numeric: bool): string =
  ## Policy attribution only. Prompts remain local.
  var node = %*{
    "type": "register",
    "kind": (if numeric: "external" elif prompt.len > 0: "prompt" else: "scripted"),
    "policy": policy
  }
  if scripted.len > 0:
    node["scripted"] = %scripted
  else:
    node["scripted"] = newJNull()
  blobFromSpriteChat($node)

proc readyBlob(): string =
  ## Acknowledge binary viewer frames; standing orders use the Text channel.
  result = newString(1)
  result[0] = char(0x85)

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let
    numericUrl = getEnv("PLAYER_NUMERIC_URL").strip()
    prompt = getEnv("PLAYER_PROMPT").strip()
    scripted = getEnv("PLAYER_SCRIPTED").strip()
    label = block:
      let explicit = getEnv("PLAYER_POLICY_LABEL").strip()
      if explicit.len > 0: explicit
      elif numericUrl.len > 0: "numeric"
      elif prompt.len > 0: "prompt"
      elif scripted.len > 0: scripted
      else: "bulwark"
  let client =
    if prompt.len > 0:
      newLlmClient(getEnv("PLAYER_MODEL", "claude-haiku-4-5-20251001"),
        parseInt(getEnv("PLAYER_MAX_OUTPUT_TOKENS", "900")))
    else: nil

  doAssert numericUrl.len == 0 or prompt.len == 0
  let numericClient = newHttpClient(timeout = 5000)
  numericClient.headers = newHttpHeaders({"Content-Type": "application/json"})
  let numericKey = getEnv("PLAYER_NUMERIC_KEY")
  if numericKey.len > 0: numericClient.headers["Authorization"] = "Bearer " & numericKey
  var seat = -1
  for key, value in decodeQuery(parseUri(url).query):
    if key == "slot": seat = parseInt(value)
  doAssert seat >= 0 and seat < CabinetCount
  let session = getEnv("PLAYER_POLICY_SESSION", "cabinet-" & $getCurrentProcessId())

  proc orders(decision: JsonNode): string =
    let view = decision["view"]
    if numericUrl.len > 0:
      let encoding = numericEncoding(view, decision["turn"].getInt())
      let request = %*{"session": session, "seat": seat,
        "decision_id": encoding["decision_id"], "values": encoding["values"],
        "action_mask": encoding.actionMask()}
      let response = parseJson(numericClient.postContent(numericUrl, $request))
      let action = decodeActions(view, response["actions"])
      return $(%*{"type": "orders", "turn": decision["turn"], "action": action})
    var stance = view.baselineStance(parseBaseline(scripted))
    var cabinet = -1
    var cabinetOut: array[CabinetCount, bool]
    for index, alias in CabinetAliases:
      if alias == view["you"]["alias"].getStr():
        cabinet = index
        cabinetOut[index] = view["you"]["out"].getBool()
      for rival in view["rivals"]:
        if rival["alias"].getStr() == alias:
          cabinetOut[index] = rival["out"].getBool()
    doAssert cabinet >= 0
    var live: seq[bool]
    for ball in view["balls"]:
      live.add(ball["state"].getStr() == "live")
    if prompt.len > 0:
      if client.disabled:
        stance.source = ssFallback
      else:
        client.throttled = false
        # The player performs inference. All seats run concurrently in their
        # own containers; the game owns their shared response deadline.
        let request = client.requestFor(SystemPrompt, userMessage(prompt, $view), seat)
        var batch: RequestBatch
        batch.post(request.url, request.headers, request.body, "player")
        let responses = client.curl.makeRequests(batch,
          max(1, (decision["deadline_ms"].getInt() - 500) div 1000))
        try:
          let text = client.textOf(responses[0].response, responses[0].error, request.url)
          stance = parseCabinetStance(extractJsonObject(text), cabinet,
            cabinetOut, live, view["rules"]["catch_enabled"].getBool(), stance, false)
        except CatchableError as error:
          echo "cabinet player: provider failed: ", error.msg
          stance.source = ssFallback
    var action = stance.stanceRecordNode(decision["turn"].getInt(), 0, cabinet)
    for field in ["k", "turn", "seat", "alias", "cabinet", "source", "latency_ms", "post_milli", "aggression_255"]:
      action.delete(field)
    $(%*{"type": "orders", "turn": decision["turn"], "action": action})

  echo "cabinet player: kind=",
    (if prompt.len > 0: "llm" else: "scripted"),
    " baseline=", (if scripted.len > 0: scripted else: "bulwark"),
    " label=", label

  proc dial(attempts: int): WebSocket =
    ## Bounded dialling. The game bakes its board render caches BEFORE it opens
    ## the listener, and the episode runner starts the players at the same
    ## instant as the game — so the first dial always lands on a closed port.
    for attempt in 0 ..< attempts:
      try:
        return newWebSocket(url)
      except CatchableError as error:
        if attempt == 0:
          echo "cabinet player: game not listening yet (", error.msg,
            "); retrying"
        sleep(ConnectRetryMs)
    nil

  var socket = dial(ConnectAttempts)
  if socket == nil:
    quit("cabinet player: game never accepted a connection", 1)
  echo "cabinet player: connected"

  # Each session is wrapped: whisky's receiveMessage RAISES on a close frame or
  # a truncated read (only a timeout returns none), and mummy's send only
  # QUEUES — so the game's own quit(0) can outrun the flushed frame. A naive
  # player exits 1 on that race and fails certification intermittently
  # (cogame-raid 0.1.3). EXITING 0 ON A DEAD SOCKET IS THE FIX.
  #
  # REGISTRATION IS RE-SENT, NOT SENT ONCE. Joins are slot-sequential, so a
  # seat whose slot is not the next open one is not admitted until the lower
  # slots have joined — and the lobby sends frames to a socket before it is
  # admitted, so the first registration AND a single re-send keyed on the first
  # received frame can both land while the seat has no index yet. The server
  # holds an unappliable registration, and this end keeps re-sending it for the
  # first ~10 s of frames. Registering twice is harmless.
  var reconnects = 0
  while true:
    var sessionFrames = 0
    socket.send(registrationBlob(prompt, scripted, label, numericUrl.len > 0), BinaryMessage)
    var resends = 0
    while true:
      var received: Option[Message]
      try:
        received = socket.receiveMessage()
      except CatchableError as error:
        echo "cabinet player: socket closed (", error.msg, ")"
        break
      if received.isNone:
        continue
      if received.get().kind == TextMessage:
        let decision = parseJson(received.get().data)
        if decision["type"].getStr() == "decision":
          doAssert decision["protocol"].getStr() == "atari-cabinet.player.v2"
          socket.send(orders(decision), TextMessage)
        continue
      inc sessionFrames
      if resends < RegistrationResends and
          sessionFrames mod ResendEveryFrames == 1:
        inc resends
        socket.send(registrationBlob(prompt, scripted, label, numericUrl.len > 0), BinaryMessage)
      socket.send(readyBlob(), BinaryMessage)
    if sessionFrames == 0 or reconnects >= ReconnectAttempts:
      break
    inc reconnects
    echo "cabinet player: re-dialling the seat (attempt ", reconnects, ")"
    socket = dial(ReconnectAttempts)
    if socket == nil:
      echo "cabinet player: game is no longer listening, exiting cleanly"
      break
    echo "cabinet player: reconnected, re-registering"
  numericClient.close()
  quit(0)
