## The wasm replay entry: the SAME `src/cabinet/sim.nim` the native server ran,
## compiled to wasm32 and re-stepped in the browser from the recorded command
## bytes, with the recorded `gameHash` re-checked every tick.
##
## Forked from the starter's `replay-viewer/ctf_replay.nim`: the stage-note
## buffer, the ABORTING_MALLOC diagnostics, the capacity preflight and the
## `emscripten_exit_with_live_runtime` lifetime are all kept.

import std/json
import cabinet/[broadcast, global, replay_runtime, replays, sim]

var
  runtimeLoaded = false
  replay: ReplayPlayer
  game: SimServer
  viewer: GlobalViewerState
  tracker: BroadcastTracker
  packet: seq[uint8]
  lastError: string

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals instead of trapping. The bundle is therefore linked
## with -s ABORTING_MALLOC=1 and this fixed buffer, stamped BEFORE each risky
## phase, stays readable from JS after the abort (aborting kills the call
## stack, not the linear memory), so the page can still report what the
## runtime was doing.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc renderCurrent(events: JsonNode) =
  var nextViewer: GlobalViewerState
  packet = game.buildReplayViewerPacket(replay, viewer, nextViewer, events)
  viewer = nextViewer

proc cabinetLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "cabinet_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    let replayData = parseReplayBytes(data.bytesFromPointer(int(length)))
    stampStage("initialize replay runtime")
    # Match the native default: keep a historical replay usable after the
    # first integrity mismatch and surface the warning in the shared chrome.
    var initialized = initReplayRuntime(
      replayData, mismatchQuit = false, gameEventLoggingEnabled = false)
    game = move(initialized.sim)
    replay = move(initialized.player)
    tracker = move(initialized.tracker)
    viewer = initGlobalViewerState()
    runtimeLoaded = true
    let note = " (board " & $MapWidth & "x" & $MapHeight & ")"
    # Refuse boards whose render buffers cannot fit the 32-bit address space
    # BEFORE baking starts, so the page gets a clean diagnostic instead of an
    # OOM abort. The fixed cabinet arena passes with ~40x headroom.
    stampStage("check viewer capacity" & note)
    let predicted = predictedViewerRenderBytes(MapWidth, MapHeight)
    if predicted > WasmViewerBudgetBytes:
      raise newException(CabinetError,
        "replay board is too large for the browser viewer" & note &
        ": needs ~" & $(predicted shr 20) &
        " MB of render buffers, beyond the wasm32 2 GB address space")
    frameStage = "advance replay" & note
    stampStage("render first frame" & note)
    renderCurrent(newJArray())
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc cabinetInput(data: ptr uint8, length: cint)
    {.exportc: "cabinet_input", cdecl.} =
  if runtimeLoaded:
    viewer.applyGlobalViewerMessage(data.bytesFromPointer(int(length)))

proc cabinetFrame(): cint {.exportc: "cabinet_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  try:
    let seekTicks =
      if viewer.replaySeekTick >= 0: @[viewer.replaySeekTick]
      else: newSeq[int]()
    let events = replay.advanceReplayFrame(
      game, tracker, seekTicks, viewer.replayCommands)
    renderCurrent(events)
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc cabinetPacketPointer(): ptr uint8
    {.exportc: "cabinet_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: packet[0].addr

proc cabinetPacketLength(): cint {.exportc: "cabinet_packet_len", cdecl.} =
  cint(packet.len)

proc cabinetMismatchTick(): cint {.exportc: "cabinet_mismatch_tick", cdecl.} =
  if runtimeLoaded: cint(replay.hashMismatchTick) else: -1

proc cabinetErrorPointer(): ptr uint8 {.exportc: "cabinet_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc cabinetErrorLength(): cint {.exportc: "cabinet_error_len", cdecl.} =
  cint(lastError.len)

proc cabinetStagePointer(): ptr uint8 {.exportc: "cabinet_stage_ptr", cdecl.} =
  ## Unlike cabinet_error_*, this stays valid after an allocation-failure
  ## abort, so JS can report what the runtime was doing.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc cabinetStageLength(): cint {.exportc: "cabinet_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing the render caches, the font and every global while the wasm module
  # stays alive and JS keeps calling cabinet_load_replay / cabinet_frame. The
  # whole session would then run on freed globals (spurious hash mismatches,
  # frozen playback, out-of-bounds seeks). Unwinding main through emscripten's
  # live-runtime exit skips the destructor epilogue entirely.
  emscriptenExitWithLiveRuntime()
