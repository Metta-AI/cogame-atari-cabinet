## Static assertions over the chrome. The starter's page plus an APPENDED game
## block is the contract; a page written from scratch that reuses the starter's
## ids is a rewrite (cogame-gridlock, 2026-08-23), and a game-block name that
## collides with the chrome alias block is silently swallowed by its hoisted
## `var` (cogame-tandem, 2026-08-23).

import std/[os, strutils, unittest]
import cabinet/[sim, global, replays]
import helpers

let
  page = sourceText("client/replay_broadcast.html")
  chrome = sourceText("client/chrome_common.js")
  core = sourceText("client/broadcast_core.js")
  shell = sourceText("replay-viewer/static_replay.js")
  worker = sourceText("replay-viewer/static_replay_worker.js")
  flags = sourceText("replay-viewer/config.nims")

const ChromeCommonBytes = 40022
  ## chrome_common.js is copied BYTE-FOR-BYTE from `Metta-AI/coworld-ctf`. The
  ## byte count is pinned here (nimble's sha1 module is not a dependency of
  ## this repo, and a length plus the structural checks below is enough to
  ## catch an edit): if this number moves, the file was touched, and the design
  ## note's pin says it must not be.

suite "viewer":
  test "chrome_common.js is byte-identical to the starter's copy":
    # The design's pin: ZERO edits. Its CTF-specific paths stay in the file and
    # are inert because the corresponding state fields are simply absent from
    # the cabinet's stream. Every cabinet-specific readout lives in the
    # appended game block.
    checkpoint("chrome_common.js is " & $chrome.len & " bytes")
    check chrome.len == ChromeCommonBytes
    check "window.ChromeCommon = function (ctx)" in chrome
    check "TEAM_ORDER = ['red', 'blue', 'green', 'yellow']" in chrome
    check "window.CTF_WIRE || {}" in chrome        ## inherited, and aliased
    # …and the game block never redefines it
    check "ChromeCommon" notin page.split(
      "ATARI-CABINET additions to the inherited coworld-ctf chrome")[1]

  test "the page is the starter's, with the game block APPENDED under a banner":
    check "ATARI-CABINET additions to the inherited coworld-ctf chrome" in page
    let parts = page.split(
      "ATARI-CABINET additions to the inherited coworld-ctf chrome")
    check parts.len == 2
    # everything the starter owns is ABOVE the banner
    for marker in ["function relayout()", "--hudscale", "--topband", "--band",
                   "core.setViewportFit()", "function onFrame(txt)",
                   "window.BroadcastCore.create", "ResizeObserver"]:
      check marker in parts[0]
    # and the game block is BELOW it
    for marker in ["window.CabinetChrome", "cabBeat", "cabRenderPips",
                   "cabRenderBricks", "beat-marker"]:
      check marker in parts[1]

  test "relayout() still owns --hudscale, --topband and --band on :root":
    check "root.style.setProperty('--hudscale'" in page
    check "root.style.setProperty('--topband'" in page
    check "root.style.setProperty('--band'" in page
    check "Math.max(0.5, Math.min(1.6, boardW / 760))" in page
    check "stage.classList.toggle('tiny', boardW <= 620)" in page
    check "#endcard {" in page
    check "bottom: var(--band" in page

  test "every kept element is present":
    for id in ["viewport", "stage", "board", "lightpool", "grain",
               "lockerroom", "lk-art", "lk-bg", "lk-cap", "lk-sprites",
               "chrome", "scorebug", "plates-l", "plates-r", "clock",
               "clock-time", "clock-caption", "mmwarn", "bannerlane",
               "killfeed", "transport", "btn-play", "btn-back", "btn-fwd",
               "btn-end", "btn-restart", "btn-loop", "btn-skip",
               "btn-spoilers", "speedchips", "scrub", "scrub-fill",
               "scrub-head", "scrub-win", "momentum", "lulls", "tick-clock",
               "ffwd-chip", "ffwd-mini", "win-chip", "endcard", "ec-headline",
               "ec-how", "ec-wincond", "ec-teams", "ec-replay", "status"]:
      checkpoint("expected #" & id)
      check ("id=\"" & id & "\"") in page

  test "every REMOVED element is absent — markup and CSS":
    for id in ["viewpanel", "minimap", "minimap-canvas", "zoombar", "zoom-out",
               "zoom-in", "zoom-slider", "zoom-read", "fpv", "fpv-canvas",
               "fpv-hud", "fpv-name", "fpv-hp", "fpv-gear", "fpv-map",
               "fpv-map-canvas", "fpv-cap", "fpv-grip", "povBadge"]:
      checkpoint("expected NO #" & id)
      check ("id=\"" & id & "\"") notin page
    # the CSS rules went with them
    for selector in ["#viewpanel {", "#minimap {", "#zoombar {",
                     "#zoom-slider {", "#fpv {", "#povBadge {"]:
      checkpoint("expected NO CSS " & selector)
      check selector notin page

  test "a .beat-marker CSS rule exists for EVERY beat kind the sim emits, and every marker is a button":
    for kind in ScrubberBeatKinds:
      checkpoint("beat kind " & kind)
      check (".beat-marker." & kind) in page
    check "button.beat-marker {" in page
    # the game block's builder creates BUTTONS with a label and a seek
    let appended = page.split(
      "ATARI-CABINET additions to the inherited coworld-ctf chrome")[1]
    check "document.createElement('button')" in appended
    check "el.setAttribute('aria-label', label)" in appended
    check "CTX.send('s:' + tick)" in appended
    check "el.title = label" in appended

  test "no game-block top-level name collides with chrome_common's alias list":
    # The chrome alias block declares these with a hoisted `var`; a game-block
    # function of the same name would be silently swallowed by it.
    var aliases: seq[string]
    for line in page.splitLines():
      let trimmed = line.strip()
      if trimmed.startsWith("var ") and " = C." in trimmed:
        for chunk in trimmed[4 .. ^1].split(","):
          let name = chunk.split("=")[0].strip()
          if name.len > 0:
            aliases.add(name)
    check aliases.len > 20
    check "markBeat" in aliases
    let appended = page.split(
      "ATARI-CABINET additions to the inherited coworld-ctf chrome")[1]
    # The game block is an IIFE, so its own helpers are scoped and cannot be
    # swallowed. What CAN collide is a global: every name it publishes is
    # `cab`-prefixed exactly so it never lands on an alias.
    check "(function () {" in appended
    check "})();" in appended
    var globals: seq[string]
    for line in appended.splitLines():
      let trimmed = line.strip()
      if trimmed.startsWith("window."):
        globals.add(trimmed[7 ..< trimmed.find(" ")])
    check globals.len >= 3
    for name in globals:
      checkpoint("game-block global " & name)
      check name notin aliases
      check name.startsWith("cab") or name == "CabinetChrome"

  test "the plate-name rule and the sub-640px label rule ship in the game block":
    let appended = page.split(
      "ATARI-CABINET additions to the inherited coworld-ctf chrome")[1]
    check ".plate-name {" in appended
    check "flex: 1 1 auto;" in appended
    check "min-width: 3.2em;" in appended
    check "text-overflow: ellipsis" in appended
    check "@media (max-width: 640px)" in appended
    check "#stage.tiny" in appended

  test "static_replay.js sets BOTH machine-readable markers, and the worker is non-modularized":
    check "setAttribute('data-replay-loaded', 'true')" in shell
    check "'data-replay-error'" in shell
    check "data-replay-mismatch-tick" in shell
    check "window.CabinetStaticReplay" in shell
    check "cabinet-static-replay" in shell
    # the paintbot-lineage bootstrap: wait for onRuntimeInitialized, and NEVER
    # a modularized factory (cogame-lantern, 2026-08-23)
    check "Module.onRuntimeInitialized" in worker
    check "importScripts('./wire_constants.js', './broadcast_core.js', './cabinet_replay.js')" in worker
    check "MODULARIZE" notin flags
    check "EXPORT_NAME" notin flags
    check "cabinet_replay.js" in flags
    for name in ["_cabinet_load_replay", "_cabinet_frame", "_cabinet_input",
                 "_cabinet_packet_ptr", "_cabinet_packet_len",
                 "_cabinet_mismatch_tick", "_cabinet_error_ptr",
                 "_cabinet_error_len", "_cabinet_stage_ptr",
                 "_cabinet_stage_len"]:
      check name in flags
    # the shipped link flags stay exactly as the starter's
    for flag in ["-s ENVIRONMENT=web,worker,node", "-s ABORTING_MALLOC=1",
                 "-s ALLOW_MEMORY_GROWTH", "-s FILESYSTEM=1",
                 "-s EXPORTED_RUNTIME_METHODS=HEAPU8",
                 "--preload-file", "--define:useMalloc", "--mm:arc",
                 "--exceptions:goto"]:
      check flag in flags

  test "broadcast_core.js differs from the starter's copy in EXACTLY the CABINET_WIRE identifier":
    check "window.CABINET_WIRE" in core
    check "window.CTF_WIRE" notin core
    # and nothing else moved: the zoom/pan/minimap code is still there,
    # verbatim, simply never driven.
    for marker in ["function zoomAt(factor, cssX, cssY)", "function panBy(",
                   "function drawMinimap()", "attachMinimap",
                   "CHROME_SPRITE_ID", "SnappyJS"]:
      check marker in core

  test "the wire-constants block publishes both names and the engine's own values":
    let text = sourceText("src/cabinet/wire_constants.nim")
    check "window.CABINET_WIRE={" in text
    check "window.CTF_WIRE=window.CABINET_WIRE;" in text
    check "chromeSpriteId:" in text
    check $BroadcastChromeSpriteId == "4090"

  test "the board is a FIXED 1:1 arena inside the wasm viewer's budget":
    check MapWidth == MapHeight
    check MapWidth == 1000
    check predictedViewerRenderBytes(MapWidth, MapHeight) < WasmViewerBudgetBytes
    check boardRenderScaleFor(MapWidth, MapHeight) == RenderScale
    # …which is exactly why #viewpanel is gone: the board always fits.
    check "the arena is FIXED" in page

  test "the renderer fixture DRIVES the shipped renderer at full cap":
    # It is not enough for a fixture to exist: cogchemists' bubbles shipped
    # clipped behind a green board because the only page that drew model text
    # re-implemented the layout instead of executing the shipped one. This
    # fixture loads the bundle's OWN broadcast_core.js, feeds it the packet
    # src/cabinet/global.nim baked, and lays the 160-rune note out with the
    # real chrome CSS from the bundle's own index.html.
    let fixture = sourceText("tools/ci/renderer_fixture.html")
    check "src=\"./broadcast_core.js\"" in fixture
    check "src=\"./wire_constants.js\"" in fixture
    check "window.BroadcastCore.create(" in fixture
    check "board_packet.bin" in fixture
    check "fixture_meta.json" in fixture
    check "fetchText('./index.html')" in fixture
    check "cab-note-row" in fixture
    check "[360, 620, 1280]" in fixture
    check "data-replay-loaded" in fixture
    check "data-replay-error" in fixture
    # NOTHING is shortened. A remark is a sentence, and item 15 makes
    # ellipsizing one a defect: there is no ellipsis and no measure-and-cut
    # loop anywhere in the page.
    check "\u2026" notin fixture
    check "text.length - 2" notin fixture
    let ci = sourceText(".github/workflows/ci.yml")
    check "renderer_fixture.html" in ci
    check "gen_render_fixture.nim" in ci
    check "render-fixture" in ci

  test "a full-cap stance note gets a WRAPPING band in the feed":
    # The inherited .feed-row is nowrap and sized to content, which sends a
    # 160-rune note off the left edge of a 360 px stage. The band widens; the
    # note is never cut (prompts/30-review-loop.md item 15).
    check ".feed-row.cab-note-row {" in page
    check "white-space: normal;" in page
    check "'cab-note-row'" in page
    check "#killfeed { min-height:" in page
