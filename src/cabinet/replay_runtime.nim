## Deterministic replay playback shared by the native server and the WASM
## viewer. Byte-identical logic on both sides — that is the whole point: the
## browser re-steps the SAME `sim.nim` from the SAME recorded command bytes
## and compares `gameHash` against the recorded hash every tick.

import std/json
import bitworld/spriteprotocol
import sim, broadcast, global, replays

type
  InitializedReplay* = object
    config*: GameConfig
    sim*: SimServer
    player*: ReplayPlayer
    tracker*: BroadcastTracker

proc initReplayRuntime*(
  data: ReplayData,
  mismatchQuit: bool,
  gameEventLoggingEnabled = true
): InitializedReplay =
  ## Builds playback state from the recorded config JSON.
  result.config = defaultGameConfig()
  result.config.update(data.configJson)
  result.sim = initSimServer(result.config)
  result.sim.gameEventLoggingEnabled = gameEventLoggingEnabled
  result.player = initReplayPlayer(data)
  result.player.mismatchQuit = mismatchQuit
  # The whole-match precompute walk starts here and advances a bounded slice
  # per presentation frame (advanceReplayPlayback); only the short lobby walk
  # to the first Playing tick — the spectator start — is paid up front.
  result.player.initReplayScan(result.sim)
  while result.sim.phase != Playing and
      result.sim.tickCount < result.player.replayMaxTick() and
      result.player.hashIndex < result.player.data.hashes.len and
      not result.player.hashValidationFailed:
    result.player.stepReplay(result.sim)
  if result.player.startTick < 0 and result.sim.phase == Playing:
    result.player.startTick = result.sim.gameStartTick
  result.player.seekReplay(result.sim, result.player.replayStartTick())
  result.player.playing = true
  result.tracker = initBroadcastTracker()

proc advanceReplayFrame*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  tracker: var BroadcastTracker,
  seekTicks: openArray[int],
  commands: openArray[char]
): JsonNode =
  ## Applies viewer controls and advances one public presentation frame.
  var didSeek = false
  for seekTick in seekTicks:
    replay.applyReplaySeek(sim, seekTick)
    didSeek = true
  for command in commands:
    let tickBefore = sim.tickCount
    replay.applyReplayCommand(sim, command)
    if sim.tickCount != tickBefore:
      didSeek = true
  if didSeek:
    tracker.resync(sim)
    replay.cancelEndHold()
  let events = newJArray()
  let
    simPtr = sim.addr
    trackerPtr = tracker.addr
  replay.advanceReplayPlayback(
    sim,
    proc () = simPtr[].stepEvents(trackerPtr[], events),
    proc () = trackerPtr[].resync(simPtr[]))
  result = events

proc buildReplayViewerPacket*(
  sim: var SimServer,
  replay: ReplayPlayer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  events: JsonNode
): seq[uint8] =
  ## The board plus the chrome, for one viewer.
  result = sim.buildBoardPacket(state, nextState)
  # The lead chrome (momentum series, beat markers, lull spans) waits for the
  # background precompute walk: it ships ONCE per viewer, so sending before
  # the walk finishes would freeze a half-scanned timeline into the HUD.
  let sendLead = not state.momentumSent and replay.scanComplete()
  result.addSprite(
    BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0],
    sim.buildStateJson(
      events,
      replay.playing,
      replay.replaySpeed(),
      replay.replayMaxTick(),
      replay.looping,
      true,
      replay.hashMismatchTick,
      replay.replayStartTick(),
      replay.endHoldSecondsLeft(),
      replay.skipLulls,
      replay.skipLulls and replay.playing and
        replay.isLullTick(sim.tickCount),
      if sendLead: replay.leadSeries else: @[],
      if sendLead: replay.lullSpans else: @[],
      if sendLead: replay.beatEvents else: nil))
  if sendLead:
    nextState.momentumSent = true

proc buildLiveViewerPacket*(
  sim: var SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  events: JsonNode,
  tick, speed, maxTick: int
): seq[uint8] =
  ## The same board and the same chrome for a LIVE spectator, with the
  ## transport disabled (there is nothing to seek yet).
  result = sim.buildBoardPacket(state, nextState)
  result.addSprite(
    BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0],
    sim.buildStateJson(
      events, true, speed, maxTick, false, false, -1, sim.gameStartTick, 0,
      false, false, @[], @[], nil))
  discard tick
