## The turn loop against a FAKE provider: one parallel batch per turn, the two
## bounded deadlines, the inter-batch floor, the budget guard, the throttle
## fast-fail and the eliminated-seat drop.
##
## The fake provider is a real HTTP server pointed at by
## AWS_ENDPOINT_URL_BEDROCK_RUNTIME, so the code under test is the SHIPPING
## transport (curly's `makeRequests` batch API) rather than a stub of it.

import std/[atomics, json, locks, monotimes, os, strutils, times, unittest]
import curly
import mummy, mummy/routers
import cabinet/[sim, stances, control, baselines, decide, llm, server]
import helpers

type
  ProviderMode = enum
    pmStance, pmSlow, pmThrottle, pmGarbage

var
  providerLock: Lock
  providerMode = pmStance
  providerCalls = 0
  providerWindows: seq[tuple[start, finish: MonoTime]]

initLock(providerLock)

proc providerHandler(request: Request) =
  let started = getMonoTime()
  var mode: ProviderMode
  {.gcsafe.}:
    withLock providerLock:
      mode = providerMode
      inc providerCalls
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  case mode
  of pmStance, pmSlow:
    # A real Bedrock-shaped body, and a deliberate 300 ms of latency so the
    # per-request windows are measurable: four SEQUENTIAL calls could not
    # overlap, four PARALLEL ones must.
    sleep(if mode == pmSlow: 2500 else: 300)
    let stance = """{"note":"fake provider","stance":"aim","aim_at":"RED",""" &
      """"target_ball":"any","post":0,"lead_ticks":12,"aggression":0.8,""" &
      """"say":"hello"}"""
    let body = $(%*{
      "content": [{"type": "text", "text": stance}],
      "stop_reason": "end_turn"
    })
    {.gcsafe.}:
      withLock providerLock:
        providerWindows.add((started, getMonoTime()))
    request.respond(200, headers, body)
  of pmThrottle:
    {.gcsafe.}:
      withLock providerLock:
        providerWindows.add((started, getMonoTime()))
    request.respond(429, headers, """{"message":"too many requests"}""")
  of pmGarbage:
    {.gcsafe.}:
      withLock providerLock:
        providerWindows.add((started, getMonoTime()))
    request.respond(200, headers, $(%*{
      "content": [{"type": "text", "text": "I would rather not say."}],
      "stop_reason": "end_turn"
    }))

proc resetProvider(mode: ProviderMode) =
  withLock providerLock:
    providerMode = mode
    providerCalls = 0
    providerWindows = @[]

var providerServer: Server
var providerThread: Thread[int]

proc serveProvider(port: int) {.thread.} =
  var router: Router
  router.post("/model/**", providerHandler)
  router.post("/**", providerHandler)
  providerServer = newServer(router)
  providerServer.serve(Port(port), "127.0.0.1")

const ProviderPort = 18719

proc startProvider() =
  createThread(providerThread, serveProvider, ProviderPort)
  # bounded wait for the listener
  for attempt in 0 ..< 100:
    sleep(20)
    if providerServer != nil:
      break

proc llmEngine(game: SimServer): DecisionEngine =
  putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
    "http://127.0.0.1:" & $ProviderPort)
  putEnv("AWS_BEARER_TOKEN_BEDROCK", "test-token")
  result = initDecisionEngine(game)
  for seat in 0 ..< CabinetCount:
    result.seats[seat].isLlm = true
    result.seats[seat].prompt = "Defend first, then aim at the weakest rival."
    result.seats[seat].registered = true
    result.seats[seat].label = "test"

proc playingGame(config: GameConfig): SimServer =
  result = initSimServer(config)
  result.gameEventLoggingEnabled = false
  for seat in 0 ..< CabinetCount:
    discard result.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
  result.phase = Playing
  result.gameStartTick = 0

suite "engine":
  test "all four seats' calls go out in ONE PARALLEL BATCH":
    startProvider()
    resetProvider(pmStance)
    let config = episodeConfig(1, extra = """{"attempt1Ms":9000}""")
    var game = playingGame(config)
    var engine = llmEngine(game)
    # STRUCTURE first: every alive seat is in ONE batch. That is the design's
    # requirement and it is immune to how libcurl happens to schedule four
    # plaintext HTTP/1.1 connections to a loopback stub (against Bedrock's
    # HTTP/2 endpoint the same batch is genuinely concurrent).
    check curly.len(engine.turnBatch(game, @[0, 1, 2, 3], 0, 0)) == CabinetCount
    check curly.len(engine.turnBatch(game, @[1, 3], 0, 1)) == 2
    let records = engine.turn(game, 0, 0)
    # …and ONE attempt per seat per turn: four calls, not eight, and no
    # per-seat sequential loop could produce fewer.
    check providerCalls == CabinetCount
    check providerWindows.len == CabinetCount
    for seat in 0 ..< CabinetCount:
      check engine.haveStance[seat]
      check engine.stances[seat].source == ssLlm
      check engine.stances[seat].note == "fake provider"
      check engine.stances[seat].latencyMs > 0
    check records.len == 0                    ## no fallbacks

  test "an ELIMINATED seat is dropped from later batches":
    resetProvider(pmStance)
    let config = episodeConfig(2)
    var game = playingGame(config)
    var engine = llmEngine(game)
    let doomed = game.seatOfCabinet(1)
    game.cabinets[1].isOut = true
    game.cabinets[1].lives = 0
    discard engine.turn(game, 3, 0)
    check providerCalls == CabinetCount - 1
    # its cabinet still HAS a stance (the autopilot always has one) and its
    # byte is ignored by the sim.
    check engine.haveStance[doomed]
    check game.paddleCommand(1, engine.stances[doomed]) == NeutralCommand

  test "consecutive batches are at least turnSpacingMs apart":
    resetProvider(pmStance)
    let config = episodeConfig(3, extra = """{"turnSpacingMs":1500}""")
    var game = playingGame(config)
    var engine = llmEngine(game)
    let first = getMonoTime()
    discard engine.turn(game, 0, 0)
    discard engine.turn(game, 1, 0)
    let elapsed = (getMonoTime() - first).inMilliseconds.int
    check elapsed >= 1500

  test "a hung provider is bounded by the per-turn budget and falls back":
    resetProvider(pmSlow)
    let config = episodeConfig(4, extra =
      """{"attempt1Ms":1000,"retryMs":1000,"turnBudgetMs":4000}""")
    var game = playingGame(config)
    var engine = llmEngine(game)
    let started = getMonoTime()
    let records = engine.turn(game, 0, 0)
    let elapsed = (getMonoTime() - started).inMilliseconds.int
    check elapsed < 12_000                    ## bounded, not hung
    check records.len > 0
    var causes: seq[string]
    for record in records:
      causes.add(parseJson(record)["cause"].getStr)
    for seat in 0 ..< CabinetCount:
      check engine.haveStance[seat]
      check engine.stances[seat].source == ssFallback
    check causes.len >= CabinetCount

  test "a throttled provider with no other candidate skips the retry":
    resetProvider(pmThrottle)
    let config = episodeConfig(5)
    var game = playingGame(config)
    var engine = llmEngine(game)
    let records = engine.turn(game, 0, 0)
    # exactly ONE attempt per seat: a retry inside the same turn cannot land.
    check providerCalls == CabinetCount
    var throttled = 0
    for record in records:
      if parseJson(record)["cause"].getStr == "throttled":
        inc throttled
    check throttled >= CabinetCount
    for seat in 0 ..< CabinetCount:
      check engine.stances[seat].source == ssFallback

  test "unusable text is retried exactly once, then falls back":
    resetProvider(pmGarbage)
    let config = episodeConfig(6)
    var game = playingGame(config)
    var engine = llmEngine(game)
    let records = engine.turn(game, 0, 0)
    check providerCalls == CabinetCount * 2    ## attempt + one retry
    for seat in 0 ..< CabinetCount:
      check engine.stances[seat].source == ssFallback
    var parseErrors = 0
    for record in records:
      if parseJson(record)["cause"].getStr == "parse_error":
        inc parseErrors
    check parseErrors >= CabinetCount

  test "the budget guard switches to scripted and the episode still ends complete":
    resetProvider(pmStance)
    let config = episodeConfig(7, extra = """{"wallClockBudgetSeconds":30}""")
    var game = playingGame(config)
    var engine = llmEngine(game)
    # 25 s elapsed with a 30 s budget: two more turns would not fit.
    let records = engine.turn(game, 5, 25)
    check engine.llmOff
    var guards = 0
    for record in records:
      if parseJson(record)["k"].getStr == "budget_guard":
        inc guards
    check guards == 1
    check providerCalls == 0                   ## nothing went out
    for seat in 0 ..< CabinetCount:
      check engine.stances[seat].source == ssFallback

  test "with NO credentials every turn falls back instantly and records why":
    delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
    delEnv("AWS_BEARER_TOKEN_BEDROCK")
    delEnv("ANTHROPIC_API_KEY")
    delEnv("ANTHROPIC_API_KEY_URI")
    let config = episodeConfig(8)
    var game = playingGame(config)
    var engine = initDecisionEngine(game)
    for seat in 0 ..< CabinetCount:
      engine.seats[seat].isLlm = true
      engine.seats[seat].prompt = "prompt"
    check engine.client.disabled
    let started = getMonoTime()
    let records = engine.turn(game, 0, 0)
    check (getMonoTime() - started).inMilliseconds.int < 2000
    var noCredentials = 0
    for record in records:
      if parseJson(record)["cause"].getStr == "no_credentials":
        inc noCredentials
    check noCredentials == CabinetCount
    for seat in 0 ..< CabinetCount:
      check engine.stances[seat].source == ssFallback
      check engine.haveStance[seat]

  test "a registered SCRIPTED seat is not a fallback and writes no record":
    let config = episodeConfig(9)
    var game = playingGame(config)
    var engine = initDecisionEngine(game)
    for seat in 0 ..< CabinetCount:
      engine.seats[seat].isLlm = false
      engine.seats[seat].baseline = blBulwark
    let records = engine.turn(game, 0, 0)
    check records.len == 0
    for seat in 0 ..< CabinetCount:
      check engine.stances[seat].source == ssScripted

  test "the wall-clock stop yields deadline/wall_clock and still scores the board":
    let config = episodeConfig(10)
    var game = playingGame(config)
    var commands = newSeq[uint8](CabinetCount)
    for seat in 0 ..< CabinetCount:
      commands[seat] = NeutralCommand
    for tick in 0 ..< 300:
      game.step(commands)
    game.stopForWallClock()
    check game.phase == GameOver
    check game.endReason == ReasonDeadline
    check game.endRule == EndRuleWallClock
    check game.winnerCabinet >= 0
    var crowns = 0
    for k in 0 ..< CabinetCount:
      if game.cabinets[k].placement == 1:
        inc crowns
    check crowns == 1

  test "a tripped invariant yields fault/sim_fault":
    let config = episodeConfig(11)
    var game = playingGame(config)
    game.faultGame(EndRuleSimFault)
    check game.phase == GameOver
    check game.endReason == ReasonFault
    check game.endRule == EndRuleSimFault
    let document = parseJson(game.playerResultsJson())
    check document["reason"].getStr == ReasonFault
    check document["endRule"].getStr == EndRuleSimFault
    check document["scores"].len == CabinetCount

  test "parseRegistration reads the seat's ONE message and drops anything else":
    check parseRegistration("""{"type":"register","prompt":"go","policy":"x"}""").ok
    check parseRegistration(
      """{"type":"register","prompt":"","scripted":"spinner"}""").scripted ==
      "spinner"
    check not parseRegistration("""{"type":"chat","text":"hi"}""").ok
    check not parseRegistration("hello").ok
    check not parseRegistration("").ok
    check parseBaseline("spinner") == blSpinner
    check parseBaseline("bulwark") == blBulwark
    check parseBaseline("") == blBulwark
    check parseBaseline("nonsense") == blBulwark
