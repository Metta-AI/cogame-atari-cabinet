## Sim-state services shared by the roster machinery and the gameplay core:
## the SimServer type itself, the lobby countdown, the tier-2 event sink, the
## non-hashed stance feed, and the REPLAY HASH.
##
## NO FLOATING POINT IN THIS FILE.

import std/[json]
import sim_types, sim_config

type
  SimServer* = object
    config*: GameConfig
    phase*: GamePhase
    tickCount*: int
    gameStartTick*: int
    gameOverTimer*: int
    startWaitTimer*: int
    lobbyTicks*: int
    cabinets*: array[CabinetCount, Cabinet]
    balls*: seq[Ball]
    perm*: array[CabinetCount, int32]
      ## seat -> cabinet. Drawn once at t = 0 from config.seed. NEVER visible
      ## to any seat (tests/test_locality.nim).
    rng*: RngState
    rngDraws*: int32
    serveFallbacks*: int32
    players*: seq[Player]
    rewardAccounts*: seq[RewardAccount]
    nextJoinOrder*: int
    seatNames*: array[CabinetCount, string]
    seatPolicyKind*: array[CabinetCount, string]
    llmTurns*: array[CabinetCount, int]
    fallbackTurns*: array[CabinetCount, int]
    endReason*: string
    endRule*: string
    winnerCabinet*: int
    lastConcede*: int
      ## tick of the most recent concede, for the near-miss feed dampening.
    # ---- presentation state (never hashed) ----------------------------------
    stances*: array[CabinetCount, StanceView]
    haveStance*: array[CabinetCount, bool]
    feedStances*: seq[string]
    events*: seq[SimEvent]
    collectEvents*: bool
    gameEventLoggingEnabled*: bool
    lastLobbyPlayersLogged*: int
    lastLobbyNeededLogged*: int
    lastLobbySecondsLogged*: int

const MaxFeedStances* = 8
  ## How many stance lines the match feed keeps. The feed shows four rows at a
  ## time and a seek re-hydrates from the keyframe, so a short ring is all the
  ## client can ever draw.

proc seatCount*(sim: SimServer): int =
  sim.config.seatCount()

proc cabinetOfSeat*(sim: SimServer, seat: int): int =
  ## Seat -> cabinet, through the seeded permutation.
  if seat < 0 or seat >= CabinetCount:
    return -1
  int(sim.perm[seat])

proc seatOfCabinet*(sim: SimServer, cabinet: int): int =
  ## The inverse: which seat drives this cabinet, or -1.
  for seat in 0 ..< CabinetCount:
    if int(sim.perm[seat]) == cabinet:
      return seat
  -1

proc aliveCabinets*(sim: SimServer): int =
  for cabinet in sim.cabinets:
    if not cabinet.isOut:
      inc result

proc turnsPerEpisode*(sim: SimServer): int =
  max(1, sim.config.maxTicks div max(1, sim.config.turnTicks))

proc gameTicksElapsed*(sim: SimServer): int =
  max(0, sim.tickCount - sim.gameStartTick)

# ---------------------------------------------------------------------------
#  Lobby
# ---------------------------------------------------------------------------

proc lobbyIsStarting*(sim: SimServer): bool =
  sim.players.len >= sim.config.minPlayers

proc lobbyStartTicksRemaining*(sim: SimServer): int =
  if not sim.lobbyIsStarting() or sim.config.startWaitTicks <= 0:
    return 0
  if sim.startWaitTimer > 0: sim.startWaitTimer else: sim.config.startWaitTicks

proc lobbyStartSecondsRemaining*(sim: SimServer): int =
  let ticks = sim.lobbyStartTicksRemaining()
  if ticks <= 0:
    return 0
  max(1, (ticks + TargetFps - 1) div TargetFps)

proc lobbyJoinTimedOut*(sim: SimServer): bool =
  ## A seat that never connects does NOT end the episode: the lobby budget
  ## expires, the no-show is reported, and its cabinet plays `bulwark`.
  sim.phase == Lobby and sim.config.lobbyJoinTimeoutTicks > 0 and
    sim.lobbyTicks >= sim.config.lobbyJoinTimeoutTicks

proc logGameEvent*(sim: SimServer, text: string) =
  if sim.gameEventLoggingEnabled:
    echo text

proc logLobbyWaiting*(sim: var SimServer) =
  let
    needed = max(0, sim.config.minPlayers - sim.players.len)
    players = sim.players.len
  if players == sim.lastLobbyPlayersLogged and
      needed == sim.lastLobbyNeededLogged:
    return
  sim.lastLobbyPlayersLogged = players
  sim.lastLobbyNeededLogged = needed
  sim.lastLobbySecondsLogged = -1
  sim.logGameEvent("waiting for players: " & $players & "/" &
    $sim.config.minPlayers & ", need " & $needed & " more")

proc logLobbyCountdown*(sim: var SimServer) =
  let seconds = sim.lobbyStartSecondsRemaining()
  if seconds <= 0 or seconds == sim.lastLobbySecondsLogged:
    return
  sim.lastLobbySecondsLogged = seconds
  sim.logGameEvent("game starting in " & $seconds)

# ---------------------------------------------------------------------------
#  The tier-2 event sink
# ---------------------------------------------------------------------------

proc emitEvent*(
  sim: var SimServer,
  kind: SimEventKind,
  cabinet = -1,
  by = -1,
  ball = -1,
  amount = 0,
  detail = "",
  x = 0,
  y = 0
) =
  ## Appends one tier-2 analysis event; a no-op unless `collectEvents` is on,
  ## so a live server nobody is analysing pays nothing. `SimEvent` never
  ## enters `gameHash`.
  if not sim.collectEvents:
    return
  sim.events.add SimEvent(
    tick: sim.tickCount, kind: kind, cabinet: cabinet, by: by, ball: ball,
    amount: amount, detail: detail, x: x, y: y)

# ---------------------------------------------------------------------------
#  The non-hashed stance feed
# ---------------------------------------------------------------------------

proc applyStanceRecord*(sim: var SimServer, record: string) =
  ## Applies one `stance` chat record into NON-HASHED presentation state.
  ## Called by the live server as it writes the record AND by the replay's
  ## chat re-application, so the feed, the aim rays and the stance chips tell
  ## the same story either way. It can never affect the simulation.
  if record.len == 0 or record[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(record)
  except CatchableError:
    return
  if node.kind != JObject or node{"k"}.getStr() != "stance":
    return
  let seat = node{"seat"}.getInt(-1)
  if seat < 0 or seat >= CabinetCount:
    return
  var view = StanceView(
    turn: node{"turn"}.getInt(0),
    seat: seat,
    cabinet: node{"cabinet"}.getInt(sim.cabinetOfSeat(seat)),
    source: node{"source"}.getStr("scripted"),
    stance: node{"stance"}.getStr("guard"),
    targetBall: node{"target_ball"}.getStr("any"),
    aimAt: node{"aim_at"}.getStr("none"),
    postMilliCu: node{"post_milli"}.getInt(0),
    leadTicks: node{"lead_ticks"}.getInt(12),
    aggression255: node{"aggression_255"}.getInt(204),
    note: node{"note"}.getStr(""),
    say: node{"say"}.getStr(""))
  view.sayUntil =
    if view.say.len > 0: sim.tickCount + 60 else: 0
  sim.stances[seat] = view
  sim.haveStance[seat] = true
  sim.feedStances.add(record)
  if sim.feedStances.len > MaxFeedStances:
    sim.feedStances.delete(0)

# ---------------------------------------------------------------------------
#  The replay hash
# ---------------------------------------------------------------------------

proc mixHash(hash: var uint64, value: uint64) =
  ## FNV-1a. Deterministic on every target.
  hash = hash xor value
  hash *= 1099511628211'u64

proc mixHashInt(hash: var uint64, value: int) =
  hash.mixHash(cast[uint64](int64(value)))

proc mixHashI32(hash: var uint64, value: int32) =
  hash.mixHash(cast[uint64](int64(value)))

proc mixHashI64(hash: var uint64, value: int64) =
  hash.mixHash(cast[uint64](value))

proc mixHashBool(hash: var uint64, value: bool) =
  hash.mixHashInt(ord(value))

proc gameHash*(sim: SimServer): uint64 =
  ## The per-tick integrity chain the browser re-checks. It mixes every field
  ## the wasm viewer must re-derive from the recorded command bytes, and NOTHING
  ## presentational: no FX, no notes, no `say`, no feed text, no stances and no
  ## policy labels.
  result = 14695981039346656037'u64
  result.mixHashInt(sim.tickCount)
  result.mixHashInt(ord(sim.phase))
  result.mixHashInt(sim.gameStartTick)
  result.mixHashInt(sim.gameOverTimer)
  result.mixHashInt(sim.startWaitTimer)
  result.mixHashInt(sim.lobbyTicks)
  result.mixHashInt(sim.winnerCabinet)
  result.mixHashInt(sim.players.len)
  for cabinet in sim.cabinets:
    result.mixHashI32(cabinet.lives)
    result.mixHashBool(cabinet.isOut)
    result.mixHashI32(cabinet.outTick)
    result.mixHashI32(cabinet.alongCentre)
    result.mixHashI32(cabinet.paddleVel)
    result.mixHashI32(cabinet.farAlongCentre)
    result.mixHashI32(cabinet.farPaddleVel)
    result.mixHashI32(cabinet.heldBall)
    for row in 0 ..< MaxBrickRows:
      for col in 0 ..< BricksPerRow:
        result.mixHashBool(cabinet.bricks[row][col])
    result.mixHashI32(cabinet.saves)
    result.mixHashI32(cabinet.chips)
    result.mixHashI32(cabinet.knockouts)
    result.mixHashI32(cabinet.concedes)
    result.mixHashI32(cabinet.catches)
    result.mixHashI64(cabinet.scoreMicro)
    result.mixHashI32(cabinet.placement)
  result.mixHashInt(sim.balls.len)
  for ball in sim.balls:
    result.mixHashInt(ord(ball.state))
    result.mixHashI32(ball.x)
    result.mixHashI32(ball.y)
    result.mixHash(uint64(ball.dir))
    result.mixHashI32(ball.speed)
    result.mixHashI32(ball.lastTouch)
    result.mixHashI32(ball.holdTicks)
    result.mixHashI32(ball.serveTimer)
    result.mixHashI32(ball.heldBy)
  # A divergence in HOW MANY draws a build took is caught at the tick it
  # happens rather than as a mysterious position mismatch later.
  result.mixHashI32(sim.rngDraws)
  result.mixHashI32(sim.serveFallbacks)
  var permDigest = 0'u64
  for value in sim.perm:
    permDigest = permDigest * 5'u64 + uint64(int64(value) + 1)
  result.mixHash(permDigest)
