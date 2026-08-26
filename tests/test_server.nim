## The websocket/HTTP contract, exercised against a REAL server process: the
## routes the certifier probes before the player pods start, the registration
## path, the artifact writes and the shutdown grace.

import std/[json, os, strutils, times, unittest]
import curly, whisky
import bitworld/runtime
import cabinet/[sim, server, global, decide, stances, baselines]
import helpers

const
  Port = 18821
  Base = "http://127.0.0.1:" & $Port
  NoShowPort = 18822
  NoShowBase = "http://127.0.0.1:" & $NoShowPort

type ServerArgs = object
  config: GameConfig
  port: int
  replayPath: string
  resultsPath: string
  failurePath: string

var serverThread: Thread[ServerArgs]

proc serve(args: ServerArgs) {.thread.} =
  {.gcsafe.}:
    putEnv("COGAME_RESULTS_URI", "file://" & args.resultsPath)
    if args.failurePath.len > 0:
      putEnv("COGAME_PLAYER_FAILURE_URI", "file://" & args.failurePath)
    else:
      delEnv("COGAME_PLAYER_FAILURE_URI")
    runServerLoop("127.0.0.1", args.port, args.config, args.replayPath, "",
      RuntimeConfig(host: "127.0.0.1", port: args.port,
        resultsUri: "file://" & args.resultsPath))

suite "server":
  test "the routes the certifier probes answer, and neither /client/ page opens the player socket":
    let work = getTempDir() / "cabinet-server-test"
    createDir(work)
    let
      replayPath = work / "episode.replay"
      resultsPath = work / "results.json"
    removeFile(replayPath)
    removeFile(resultsPath)
    # A tiny episode: the lobby budget expires almost immediately, so the
    # cabinets play the bulwark baseline and the run finishes on its own — the
    # no-show path, which must NOT end the episode.
    var config = episodeConfig(4242, startingLives = 1, maxTicks = 240)
    config.lobbyJoinTimeoutTicks = 24
    config.minPlayers = 4
    config.gameOverTicks = 4
    createThread(serverThread, serve,
      ServerArgs(config: config, port: Port, replayPath: replayPath,
        resultsPath: resultsPath))
    let pool = newCurlPool(2)
    # bounded wait for the listener (the board caches bake first)
    var healthy = false
    for attempt in 0 ..< 200:
      sleep(100)
      try:
        if pool.get(Base & "/healthz").code == 200:
          healthy = true
          break
      except CatchableError:
        discard
    check healthy
    check pool.get(Base & "/healthz").body == "healthy"
    # /client/global and /client/player serve REAL pages, and neither is a
    # websocket upgrade (lantern 0.1.1: the certifier probes both BEFORE the
    # player pods start).
    for route in ["/client/global", "/client/player", "/client/replay",
                  "/clients/replay"]:
      let response = pool.get(Base & route)
      checkpoint(route & " -> " & $response.code)
      check response.code == 200
      check "<!DOCTYPE html>" in response.body
      check "id=\"board\"" in response.body
      check "window.CABINET_WIRE=" in response.body
      check "window.ChromeCommon" in response.body
    # A bad player slot/token is a 403 BEFORE the upgrade — which is what the
    # certifier's own bad-token probe does, so it is tested through a real
    # websocket handshake rather than a plain GET (a plain GET to /player is
    # not an upgrade at all and falls through to the catch-all).
    var refused = false
    try:
      let socket = newWebSocket(
        "ws://127.0.0.1:" & $Port & "/player?slot=0&token=wrong")
      socket.close()
    except CatchableError:
      refused = true
    check refused
    # …and a viewer socket carrying player credentials is refused too
    var viewerRefused = false
    try:
      let socket = newWebSocket(
        "ws://127.0.0.1:" & $Port & "/global?slot=0&token=t")
      socket.close()
    except CatchableError:
      viewerRefused = true
    check viewerRefused
    # the catch-all is a plain 200, never an accidental page
    check pool.get(Base & "/nothing-here").code == 200
    # let the episode finish: no seat ever connects, so the lobby budget
    # expires, the no-show is reported and the cabinets play bulwark.
    var wrote = false
    for attempt in 0 ..< 600:
      sleep(100)
      if fileExists(resultsPath) and getFileSize(resultsPath) > 10:
        wrote = true
        break
    check wrote
    let results = parseJson(readFile(resultsPath))
    check results["names"].len == CabinetCount
    check results["scores"].len == CabinetCount
    check results["reason"].getStr in [ReasonComplete, ReasonDeadline]
    check results["rom"].getStr == "warlords"
    # /healthz and /global keep answering for the shutdown grace, which is why
    # a short episode does not fail the runner's post-start ping.
    var stillAnswering = false
    try:
      stillAnswering = pool.get(Base & "/healthz").code == 200
    except CatchableError:
      discard
    check stillAnswering
    # the replay is on disk and carries the whole episode
    check fileExists(replayPath)
    check getFileSize(replayPath) > 500
    joinThread(serverThread)
    check not fileExists(work / "player_failure.json")

  test "a seat that never joins is REPORTED, and the run still ends normally":
    # DEGRADE, NEVER HANG at the lobby: a no-show is charged to the seat that
    # caused it (COGAME_PLAYER_FAILURE_URI, lowest missing slot only) and the
    # episode starts anyway, with that cabinet playing the published bulwark
    # baseline. The report was code only -- nothing asserted it (r1-23).
    let work = getTempDir() / "cabinet-noshow-test"
    createDir(work)
    let
      replayPath = work / "episode.replay"
      resultsPath = work / "results.json"
      failurePath = work / "player_failure.json"
    for path in [replayPath, resultsPath, failurePath]:
      removeFile(path)
    var config = episodeConfig(2718, startingLives = 1, maxTicks = 240)
    config.lobbyJoinTimeoutTicks = 24
    config.minPlayers = 4
    config.gameOverTicks = 4
    createThread(serverThread, serve,
      ServerArgs(config: config, port: NoShowPort, replayPath: replayPath,
        resultsPath: resultsPath, failurePath: failurePath))
    let pool = newCurlPool(2)
    var healthy = false
    for attempt in 0 ..< 200:
      sleep(100)
      try:
        if pool.get(NoShowBase & "/healthz").code == 200:
          healthy = true
          break
      except CatchableError:
        discard
    check healthy
    var wrote = false
    for attempt in 0 ..< 600:
      sleep(100)
      if fileExists(resultsPath) and getFileSize(resultsPath) > 10:
        wrote = true
        break
    check wrote
    # the no-show is named…
    check fileExists(failurePath)
    let failure = parseJson(readFile(failurePath))
    check failure["failed_policy_index"].getInt == 0
    check "never joined the lobby" in failure["message"].getStr
    # …and the episode still reached a normal ending, scored, with a replay.
    let results = parseJson(readFile(resultsPath))
    check results["reason"].getStr in [ReasonComplete, ReasonDeadline]
    check results["scores"].len == CabinetCount
    check getFileSize(replayPath) > 500
    # /healthz and /global keep answering through the 20 s shutdown grace: the
    # platform runner pings after the artifacts land, and a server that had
    # already exited would be read as a crashed episode. 15 s, per §Tests 11.
    let graceUntil = getTime() + initDuration(seconds = 15)
    var pings = 0
    while getTime() < graceUntil:
      sleep(1000)
      check pool.get(NoShowBase & "/healthz").code == 200
      check pool.get(NoShowBase & "/global").code == 200
      inc pings
    check pings >= 14
    joinThread(serverThread)

  test "an input mask from a seat is DISCARDED and a non-registration chat is dropped":
    # The seat's only authored message is its registration; everything else on
    # that socket is dropped, because the server computes every command byte.
    var state = initPlayerViewerState()
    var chat = ""
    # a Sprite v1 input packet (0x84) must leave `chat` untouched
    var input = newString(2)
    input[0] = char(0x84)
    input[1] = char(0xff)
    state.applyPlayerViewerMessage(input, chat)
    check chat.len == 0
    # a chat packet IS read
    var packet = newString(3 + 5)
    packet[0] = char(0x81)
    packet[1] = char(5)
    packet[2] = char(0)
    packet[3 .. 7] = "hello"
    state.applyPlayerViewerMessage(packet, chat)
    check chat == "hello"
    # …but only a `register` object is a registration
    check not parseRegistration("hello").ok
    check parseRegistration("""{"type":"register","prompt":"x"}""").ok

  test "a prompt over 4000 runes is TRUNCATED at the transport, never rejected":
    let long = "x".repeat(9000)
    let registration = parseRegistration(
      $(%*{"type": "register", "prompt": long, "policy": "big"}))
    check registration.ok
    check registration.prompt.len == 9000
    # the server truncates on the way into the seat policy
    check registration.prompt.truncateRunes(MaxPromptRunes).len ==
      MaxPromptRunes

  test "the viewer's own input channel reads transport commands and seeks":
    var viewer = initGlobalViewerState()
    proc chatPacket(text: string): string =
      result = newString(3 + text.len)
      result[0] = char(0x81)
      result[1] = char(text.len and 0xff)
      result[2] = char((text.len shr 8) and 0xff)
      result[3 .. 2 + text.len] = text
    viewer.applyGlobalViewerMessage(chatPacket(" "))
    check viewer.replayCommands == @[' ']
    viewer.applyGlobalViewerMessage(chatPacket("s:1234"))
    check viewer.replaySeekTick == 1234
    viewer.applyGlobalViewerMessage(chatPacket("v:2"))
    check viewer.povSelectPending == 2

  test "the register record is REDACTED: the prompt never reaches the replay":
    let record = registerRecord(1, 2, "castellan", "llm", "bulwark")
    check "prompt" notin record
    let parsed = parseJson(record)
    check parsed["k"].getStr == "register"
    check parsed["seat"].getInt == 1
    check parsed["cabinet"].getInt == 2
    check parsed["alias"].getStr == "GREEN"
    check parsed["policy"].getStr == "castellan"
    check parsed["kind"].getStr == "llm"
    # the label is capped
    let long = registerRecord(0, 0, "y".repeat(400), "llm", "bulwark")
    check parseJson(long)["policy"].getStr.len == MaxPolicyLabelRunes

# The mummy server ran on its own thread inside this process. Nim's exit path
# then tears down module globals while libcurl's and mummy's own threads are
# being reaped, which segfaults on some runners AFTER every test has already
# reported. Exiting explicitly with the suite's own result keeps the harness
# honest without pretending the teardown race is a test failure.
quit(programResult)
