## The replay codec wrapper and playback machinery — the starter's, adapted.
##
## Two named edits to the inherited file:
##
## 1. `serializeReplaySim` / `deserializeReplaySim` cover the cabinet's sim
##    fields (keyframes are how the viewer seeks). There are no static map
##    bakes to set aside: this arena is one fixed box, so the whole `SimServer`
##    goes through flatty.
## 2. `CtfReplayMagic "COWLDCTF"` -> `CabinetReplayMagic "COWLDCAB"`, with
##    `GameName` / `GameVersion` from sim_types and the starter's prepend-only
##    changelog discipline on the version const.
##
## The action log is ONE COMMAND BYTE PER SEAT PER TICK, written on change only
## by `writeInputMaskChange` — the codec's own guard. Nothing else in the loop
## is re-derived at playback.

import std/json
import flatty
import bitworld/replays as replayCodec
import sim, broadcast

type
  ReplayKeyframe* = object
    tick*: int
    simBytes*: string
    joinIndex*: int
    leaveIndex*: int
    chatIndex*: int
    inputIndex*: int
    hashIndex*: int
    masks*: seq[uint8]
    hashValidationFailed*: bool
    hashMismatchTick*: int

  ReplayPlayer* = object
    data*: ReplayData
    joinIndex*: int
    leaveIndex*: int
    chatIndex*: int
    inputIndex*: int
    hashIndex*: int
    masks*: seq[uint8]
    playing*: bool
    looping*: bool
    speedIndex*: int
    mismatchQuit*: bool
    hashValidationFailed*: bool
    hashMismatchTick*: int
    keyframes*: seq[ReplayKeyframe]
    startTick*: int
      ## The first tick the match is actually PLAYED. Playback auto-starts
      ## here, loops back here, and the scrubber is offset by it, so the shown
      ## timeline is 0 = first action.
    leadSeries*: seq[seq[int]]
      ## [tick, scorePerCabinet…] change-points across the WHOLE episode, so
      ## the momentum graph draws its full-timeline shape at once instead of
      ## accumulating as it plays.
    endHoldFrames*: int
    pendingSeekTick*: int
    skipLulls*: bool
    lullSpans*: seq[array[2, int]]
    beatEvents*: JsonNode
    scan: ReplayScan
    scanDone: bool

  ReplayScan = ref object
    ## The in-flight whole-match precompute walk: a second sim stepped from
    ## tick 0 that derives keyframes, the lead series, the story beats and the
    ## lull spans without touching on-screen playback state. It advances a
    ## bounded slice per presentation frame, so a long replay is on screen
    ## immediately instead of after seconds of black.
    sim: SimServer
    builder: ReplayPlayer
    beatTracker: BroadcastTracker
    beatTicks: seq[int]
    lastLead: seq[int]
    interval: int
    maxTick: int

export PlaybackSpeeds
export replayCodec

const
  ReplayKeyframeTicks* = 120
  ReplayEndHoldSeconds* = 10
  LullLeadTicks* = 2 * ReplayFps
  MinLullTicks* = 6 * ReplayFps
  LullSpeedBoost* = 8
  MaxLullTicksPerFrame* = 64
  SeekTicksPerFrame* = 240
  CabinetReplayMagic* = "COWLDCAB"
  CabinetReplayFormatVersion* = 1'u16
  CabinetReplaySpec* = ReplaySpec(
    magic: CabinetReplayMagic,
    formatVersion: CabinetReplayFormatVersion,
    gameName: GameName,
    gameVersion: GameVersion,
    joinKind: rjkNameSlotToken,
    allowChat: true,
    allowCompressed: true,
    hashOrder: rhoStop
  )
  ScrubberBeatKinds* = ["concede", "breach", "eliminated", "last_standing",
    "over"]
    ## The ONLY kinds that become scrubber markers. `save`, `chip`, `serve`,
    ## `catch`, `release`, `near_miss` and `say` fire dozens to hundreds of
    ## times and would bury the timeline.

proc tickTime*(tick: int): uint32 =
  replayCodec.tickTime(tick, ReplayFps)

proc writeInputMaskChange*(
  replayWriter: var ReplayWriter, time: uint32, seat: int, command: uint8
) =
  ## Writes one replay input event when a SEAT's command byte changes. Lives
  ## here rather than in server.nim because the byte log IS the replay's action
  ## stream: the test that proves the recorded bytes re-simulate to the
  ## identical hash chain has to write it exactly the way the server does, and
  ## two copies of this would be two chances to drift.
  if seat < 0 or seat >= replayWriter.lastMasks.len:
    return
  if replayWriter.lastMasks[seat] == command:
    return
  replayWriter.writeInput(ReplayInput(
    time: time, player: uint8(seat), keys: command))
  replayWriter.lastMasks[seat] = command

proc openReplayWriter*(path: string, configJson: string): ReplayWriter =
  replayCodec.openReplayWriter(path, configJson, CabinetReplaySpec)

proc parseReplayBytes*(bytes: string): ReplayData =
  replayCodec.parseReplayBytes(bytes, CabinetReplaySpec)

proc loadReplay*(path: string): ReplayData =
  replayCodec.loadReplay(path, CabinetReplaySpec)

proc serializeReplaySim*(sim: var SimServer): string =
  ## One keyframe. The arena is a fixed box with no static bakes, so the whole
  ## sim goes through flatty; the ROM preset and `perm` are already in the
  ## config JSON.
  sim.toFlatty()

proc deserializeReplaySim*(bytes: string): SimServer =
  bytes.fromFlatty(SimServer)

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  result.data = data
  result.masks = @[]
  result.playing = true
  result.looping = true
  result.speedIndex = 0
  result.skipLulls = true
  result.hashMismatchTick = -1
  result.pendingSeekTick = -1
  result.beatEvents = newJArray()

proc replaySpeed*(replay: ReplayPlayer): int =
  PlaybackSpeeds[clamp(replay.speedIndex, 0, PlaybackSpeeds.high)]

proc replayMaxTick*(replay: ReplayPlayer): int =
  if replay.data.hashes.len == 0:
    return 0
  int(replay.data.hashes[^1].tick)

proc replayStartTick*(replay: ReplayPlayer): int =
  clamp(max(0, replay.startTick), 0, replay.replayMaxTick())

proc resetReplay*(replay: var ReplayPlayer) =
  replay.joinIndex = 0
  replay.leaveIndex = 0
  replay.chatIndex = 0
  replay.inputIndex = 0
  replay.hashIndex = 0
  replay.hashValidationFailed = false
  replay.hashMismatchTick = -1
  replay.masks = @[]

proc saveReplayKeyframe(
  replay: ReplayPlayer, sim: var SimServer
): ReplayKeyframe =
  ReplayKeyframe(
    tick: sim.tickCount,
    simBytes: serializeReplaySim(sim),
    joinIndex: replay.joinIndex,
    leaveIndex: replay.leaveIndex,
    chatIndex: replay.chatIndex,
    inputIndex: replay.inputIndex,
    hashIndex: replay.hashIndex,
    masks: replay.masks,
    hashValidationFailed: replay.hashValidationFailed,
    hashMismatchTick: replay.hashMismatchTick)

proc restoreReplayKeyframe(
  replay: var ReplayPlayer, sim: var SimServer, keyframe: ReplayKeyframe
) =
  let logging = sim.gameEventLoggingEnabled
  var restored = deserializeReplaySim(keyframe.simBytes)
  restored.gameEventLoggingEnabled = logging
  sim = move(restored)
  replay.joinIndex = keyframe.joinIndex
  replay.leaveIndex = keyframe.leaveIndex
  replay.chatIndex = keyframe.chatIndex
  replay.inputIndex = keyframe.inputIndex
  replay.hashIndex = keyframe.hashIndex
  replay.masks = keyframe.masks
  replay.hashValidationFailed = keyframe.hashValidationFailed
  replay.hashMismatchTick = keyframe.hashMismatchTick

proc replayKeyframeIndex(replay: ReplayPlayer, tick: int): int =
  for i, keyframe in replay.keyframes:
    if keyframe.tick > tick:
      break
    result = i

proc ensureReplaySeat(replay: var ReplayPlayer, seat: int) =
  while replay.masks.len <= seat:
    replay.masks.add(NeutralCommand)

proc applyReplayEvents(replay: var ReplayPlayer, sim: var SimServer) =
  ## Applies the recorded joins, leaves, inputs and chat records for this tick.
  let time = tickTime(sim.tickCount)
  while replay.leaveIndex < replay.data.leaves.len and
      replay.data.leaves[replay.leaveIndex].time <= time:
    let leave = replay.data.leaves[replay.leaveIndex]
    if int(leave.player) >= 0 and int(leave.player) < sim.players.len:
      sim.removePlayerAt(int(leave.player))
    # A leave does NOT shift the command-byte rows: the four cabinets are
    # fixed for the whole episode and the recorded bytes are indexed BY SEAT,
    # so deleting a row would silently re-point every byte after it.
    inc replay.leaveIndex
  while replay.joinIndex < replay.data.joins.len and
      replay.data.joins[replay.joinIndex].time <= time:
    let join = replay.data.joins[replay.joinIndex]
    if int(join.player) != sim.players.len:
      raise newException(ReplayError, "Replay player join order is invalid")
    discard sim.addPlayer(join.name, join.slot, join.token, trusted = true)
    replay.ensureReplaySeat(int(join.player))
    inc replay.joinIndex
  while replay.inputIndex < replay.data.inputs.len and
      replay.data.inputs[replay.inputIndex].time <= time:
    let input = replay.data.inputs[replay.inputIndex]
    replay.ensureReplaySeat(int(input.player))
    replay.masks[int(input.player)] = input.keys
    inc replay.inputIndex
  while replay.chatIndex < replay.data.chats.len and
      replay.data.chats[replay.chatIndex].time <= time:
    let chat = replay.data.chats[replay.chatIndex]
    # CONTROL records (register / stance / fallback / budget_guard / result)
    # ride the chat stream as JSON objects and are told apart by a leading
    # '{'. Only the `stance` records are re-applied, and only into
    # NON-HASHED presentation state, so the hash chain cannot move.
    if chat.message.len > 0 and chat.message[0] == '{':
      sim.applyStanceRecord(chat.message)
    inc replay.chatIndex

proc replayCommands(replay: var ReplayPlayer, seats: int): seq[uint8] =
  result = newSeq[uint8](max(seats, CabinetCount))
  for seat in 0 ..< result.len:
    replay.ensureReplaySeat(seat)
    result[seat] = replay.masks[seat]

proc checkReplayHash(replay: var ReplayPlayer, sim: SimServer) =
  ## One divergent bit is caught at the tick it happens.
  if replay.hashValidationFailed:
    if sim.tickCount >= replay.replayMaxTick():
      replay.playing = false
    return
  if replay.hashIndex >= replay.data.hashes.len:
    replay.playing = false
    return
  let expected = replay.data.hashes[replay.hashIndex]
  if int(expected.tick) < sim.tickCount:
    let message = "Replay hash tick is missing at tick " & $sim.tickCount & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  if int(expected.tick) > sim.tickCount:
    return
  let hash = sim.gameHash()
  if hash != expected.hash:
    let message = "Replay hash mismatch at tick " & $sim.tickCount &
      "; expected " & $expected.hash & ", got " & $hash & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  inc replay.hashIndex

proc stepReplay*(replay: var ReplayPlayer, sim: var SimServer) =
  ## Advances playback by one simulation tick, from the RECORDED bytes.
  replay.applyReplayEvents(sim)
  let commands = replay.replayCommands(sim.players.len)
  sim.step(commands)
  replay.checkReplayHash(sim)

proc buildLullSpans*(
  beatTicks: seq[int], startTick, maxTick: int
): seq[array[2, int]] =
  ## The quiet spans between beats, keeping LullLeadTicks of context on both
  ## sides and dropping spans shorter than MinLullTicks: skipping a short
  ## breather is more jarring than watching it.
  var prevBeat = startTick
  for i in 0 .. beatTicks.len:
    let nextBeat =
      if i < beatTicks.len: beatTicks[i]
      else: maxTick + LullLeadTicks + 1
    let
      a = prevBeat + LullLeadTicks + 1
      b = min(nextBeat - LullLeadTicks - 1, maxTick)
    if b - a + 1 >= MinLullTicks:
      result.add([a, b])
    if i < beatTicks.len:
      prevBeat = nextBeat

proc scanComplete*(replay: ReplayPlayer): bool =
  replay.scanDone

proc advanceReplayScan*(replay: var ReplayPlayer, maxTicks: int)

proc initReplayScan*(
  replay: var ReplayPlayer, initialSim: SimServer,
  interval = ReplayKeyframeTicks
) =
  replay.keyframes = @[]
  replay.leadSeries = @[]
  replay.lullSpans = @[]
  replay.beatEvents = newJArray()
  replay.scanDone = false
  var scan = ReplayScan(interval: max(interval, 1))
  scan.sim = initialSim
  scan.sim.gameEventLoggingEnabled = false
  scan.builder = initReplayPlayer(replay.data)
  scan.builder.looping = false
  scan.builder.mismatchQuit = replay.mismatchQuit
  scan.maxTick = scan.builder.replayMaxTick()
  replay.keyframes.add(scan.builder.saveReplayKeyframe(scan.sim))
  scan.lastLead = scan.sim.scoreLead()
  var first = @[scan.sim.tickCount]
  first.add(scan.lastLead)
  replay.leadSeries.add(first)
  scan.beatTracker = initBroadcastTracker()
  scan.beatTracker.resync(scan.sim)
  replay.startTick =
    if scan.sim.phase == Playing: scan.sim.gameStartTick else: -1
  replay.scan = scan
  replay.advanceReplayScan(0)

proc advanceReplayScan*(replay: var ReplayPlayer, maxTicks: int) =
  if replay.scan == nil:
    return
  let scan = replay.scan
  var stepsLeft = maxTicks
  while stepsLeft > 0 and scan.builder.playing and
      scan.sim.tickCount < scan.maxTick:
    try:
      scan.builder.stepReplay(scan.sim)
    except ReplayError as error:
      if replay.mismatchQuit:
        raise
      echo "replay scan stopped at tick ", scan.sim.tickCount, ": ", error.msg
      scan.builder.playing = false
      break
    if replay.startTick < 0 and scan.sim.phase == Playing:
      replay.startTick = scan.sim.gameStartTick
    let lead = scan.sim.scoreLead()
    if lead != scan.lastLead:
      var point = @[scan.sim.tickCount]
      point.add(lead)
      replay.leadSeries.add(point)
      scan.lastLead = lead
    var stepBeats = newJArray()
    scan.sim.stepEvents(scan.beatTracker, stepBeats)
    for event in stepBeats:
      if event["k"].getStr() in ScrubberBeatKinds:
        replay.beatEvents.add(event)
        scan.beatTicks.add(scan.sim.tickCount)
    if scan.sim.tickCount mod scan.interval == 0 or
        scan.sim.tickCount == scan.maxTick:
      replay.keyframes.add(scan.builder.saveReplayKeyframe(scan.sim))
    dec stepsLeft
  if scan.builder.playing and scan.sim.tickCount < scan.maxTick:
    return
  if replay.leadSeries.len == 0 or
      replay.leadSeries[^1][0] != scan.sim.tickCount:
    var final = @[scan.sim.tickCount]
    final.add(scan.lastLead)
    replay.leadSeries.add(final)
  replay.lullSpans = buildLullSpans(
    scan.beatTicks, replay.replayStartTick(), scan.maxTick)
  replay.scan = nil
  replay.scanDone = true

proc replayScanTicksPerFrame*(sim: SimServer): int =
  ## A deterministic scan slice per presentation frame (frame-counted, no clock
  ## reads — machine speed must not change what any frame contains).
  discard sim
  96

proc buildReplayKeyframes*(
  replay: var ReplayPlayer, initialSim: SimServer,
  interval = ReplayKeyframeTicks
) =
  ## The synchronous whole walk (tests and offline tools).
  replay.initReplayScan(initialSim, interval)
  replay.advanceReplayScan(int.high)

proc isLullTick*(replay: ReplayPlayer, tick: int): bool =
  for span in replay.lullSpans:
    if tick < span[0]:
      return false
    if tick <= span[1]:
      return true
  false

proc replayStepBudget*(replay: ReplayPlayer, tick: int): int =
  let speed = replay.replaySpeed()
  if replay.skipLulls and replay.isLullTick(tick):
    return min(speed * LullSpeedBoost, MaxLullTicksPerFrame)
  speed

proc seekReplay*(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  if replay.keyframes.len > 0:
    replay.restoreReplayKeyframe(
      sim, replay.keyframes[replay.replayKeyframeIndex(tick)])
  else:
    let logging = sim.gameEventLoggingEnabled
    sim = initSimServer(sim.config)
    sim.gameEventLoggingEnabled = logging
    replay.resetReplay()
  while sim.tickCount < tick and replay.hashIndex < replay.data.hashes.len:
    replay.stepReplay(sim)

proc convergeSeek*(replay: var ReplayPlayer, sim: var SimServer): bool =
  ## Walks a pending seek up to SeekTicksPerFrame ticks closer to its target,
  ## so the first frame after a scrubber click already MOVES instead of
  ## stalling the viewer for the whole gap.
  if replay.pendingSeekTick < 0:
    return false
  var stepped = 0
  while sim.tickCount < replay.pendingSeekTick and
      replay.hashIndex < replay.data.hashes.len and
      stepped < SeekTicksPerFrame:
    replay.stepReplay(sim)
    inc stepped
  if sim.tickCount >= replay.pendingSeekTick or
      replay.hashIndex >= replay.data.hashes.len:
    replay.pendingSeekTick = -1
  stepped > 0

proc beginSeek*(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  let target = clamp(tick, replay.replayStartTick(), replay.replayMaxTick())
  if replay.keyframes.len > 0:
    replay.restoreReplayKeyframe(
      sim, replay.keyframes[replay.replayKeyframeIndex(target)])
  else:
    let logging = sim.gameEventLoggingEnabled
    sim = initSimServer(sim.config)
    sim.gameEventLoggingEnabled = logging
    replay.resetReplay()
  replay.pendingSeekTick = target

proc applyReplaySeek*(
  replay: var ReplayPlayer, sim: var SimServer, tick: int
) =
  replay.playing = false
  replay.beginSeek(sim, tick)

proc applySpeedCommand*(speedIndex: var int, command: char) =
  case command
  of '+', '=': speedIndex = min(speedIndex + 1, PlaybackSpeeds.high)
  of '-', '_': speedIndex = max(speedIndex - 1, 0)
  of '1': speedIndex = 0
  of '2': speedIndex = 1
  of '3': speedIndex = 2
  of '4': speedIndex = 3
  of '8': speedIndex = 4
  of '6': speedIndex = 5
  else: discard

proc applyReplayCommand*(
  replay: var ReplayPlayer, sim: var SimServer, command: char
) =
  case command
  of ' ': replay.playing = not replay.playing
  of 'p': replay.playing = true
  of 'P': replay.playing = false
  of '+', '=', '-', '_', '1', '2', '3', '4', '8', '6':
    applySpeedCommand(replay.speedIndex, command)
  of ',', '<':
    replay.playing = false
    replay.pendingSeekTick = -1
    replay.seekReplay(sim, replay.replayStartTick())
  of 'b':
    replay.playing = false
    replay.beginSeek(sim, max(replay.replayStartTick(), sim.tickCount - 1))
  of 'e':
    replay.playing = false
    replay.beginSeek(sim, replay.replayMaxTick())
  of 'r': replay.looping = not replay.looping
  of 'f': replay.skipLulls = not replay.skipLulls
  of '.', '>':
    replay.playing = false
    replay.beginSeek(sim, sim.tickCount + ReplayFps * 5)
  else: discard

proc cancelEndHold*(replay: var ReplayPlayer) =
  replay.endHoldFrames = 0

proc endHoldSecondsLeft*(replay: ReplayPlayer): int =
  if replay.endHoldFrames <= 0: 0
  else: (replay.endHoldFrames + ReplayFps - 1) div ReplayFps

proc advanceReplayPlayback*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  onStep: proc () {.closure.},
  onJump: proc () {.closure.}
) =
  ## One real-time playback frame. A LOOPING replay does not restart the moment
  ## playback stops: the final game-over frame holds for ReplayEndHoldSeconds
  ## first, so the end segment is readable instead of flashing.
  if replay.pendingSeekTick >= 0:
    if replay.convergeSeek(sim):
      onJump()
    return
  replay.advanceReplayScan(sim.replayScanTicksPerFrame())
  if replay.playing and replay.endHoldFrames > 0:
    replay.endHoldFrames = 0
    replay.seekReplay(sim, replay.replayStartTick())
    onJump()
  if replay.playing:
    replay.endHoldFrames = 0
    var stepsTaken = 0
    while replay.playing and
        stepsTaken < replay.replayStepBudget(sim.tickCount):
      replay.stepReplay(sim)
      onStep()
      inc stepsTaken
    if replay.looping and not replay.playing:
      replay.endHoldFrames = ReplayEndHoldSeconds * ReplayFps
  elif replay.endHoldFrames > 0:
    dec replay.endHoldFrames
    if replay.endHoldFrames == 0 and replay.looping:
      replay.seekReplay(sim, replay.replayStartTick())
      replay.playing = true
      onJump()

proc playbackSpeed*(speedIndex: int): int =
  PlaybackSpeeds[clamp(speedIndex, 0, PlaybackSpeeds.high)]
