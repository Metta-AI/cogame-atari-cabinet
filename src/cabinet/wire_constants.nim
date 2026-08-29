## The JS wire-constants block: the handful of engine constants the browser
## chromes must agree with (playback speeds, fps, the chrome sprite id, the FX
## tuning). Rendering them ONCE from the same Nim consts the engine runs on is
## what stops a retuned PlaybackSpeeds from silently desyncing every client.
## server.nim splices the block into every served client page and
## tools/gen_wire_constants.nim emits it for the static wasm bundle. Clients
## read `window.CABINET_WIRE`.

import std/strutils
import sim, global

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add $v
  result.add "]"

const WireConstantsJs* =
  # 0.5 is the replay-only half speed (ReplayHalfSpeedIndex, command '5');
  # it rides ahead of the engine's integer PlaybackSpeeds.
  "window.CABINET_WIRE={speeds:[0.5," & jsIntArray(PlaybackSpeeds)[1..^1] &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",shotFxTicks:" & $ShotFxTicks &
  ",shotTrailFalloff:" & $TrailFalloff &
  ",boardW:" & $MapWidth &
  ",boardH:" & $MapHeight &
  "};window.CTF_WIRE=window.CABINET_WIRE;"
  ## The `CTF_WIRE` alias is deliberate and is the ONLY line that mentions it:
  ## `client/chrome_common.js` is the starter's copy (plus the fleet-wide
  ## 0.5x transport patch) and reads `window.CTF_WIRE`, so the block publishes
  ## both names rather than rewiring a file whose byte count is pinned by
  ## tests/test_viewer.nim.

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
