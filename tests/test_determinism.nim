## THE DETERMINISM GATE. If this fails, the physics or a build flag changed:
## fix the code, never the test.
##
## The replay viewer is a wasm32 build of the SAME `sim.nim` the amd64 server
## ran, and their per-tick `gameHash` chains must match bit-for-bit. These are
## the properties that make that true by construction.

import std/[json, math, os, strutils, unittest]
import cabinet/[sim, stances, baselines]
import helpers

const GuardedModules = [
  "src/cabinet/sim.nim", "src/cabinet/arena.nim", "src/cabinet/rom.nim",
  "src/cabinet/trig.nim", "src/cabinet/sim_types.nim",
  "src/cabinet/sim_config.nim", "src/cabinet/sim_state.nim"
]

suite "determinism":
  test "(a) the same seed, rom and command log give the identical hash at every tick":
    let config = episodeConfig(5140913, startingLives = 3)
    let first = runEpisode(config)
    let second = runEpisode(config)
    check first.ticks == second.ticks
    check first.hashes == second.hashes
    # …and a fresh sim replaying the RECORDED BYTES reproduces every hash.
    let replayed = replaySteps(config, first.commandLog)
    check replayed.len == first.hashes.len
    check replayed == first.hashes

  test "(b) a one-unit change in any command byte changes the final hash":
    let config = episodeConfig(5140913, startingLives = 3, maxTicks = 480)
    let episode = runEpisode(config)
    let baseline = replaySteps(config, episode.commandLog)
    var mutated = episode.commandLog
    # nudge one drive level at a tick where the game is being played
    let at = min(240, mutated.len - 1)
    mutated[at][0] = uint8((int(mutated[at][0]) + 1) mod 243)
    let changed = replaySteps(config, mutated)
    check changed[^1] != baseline[^1]

  test "(c) the committed golden hashes still hold for all three ROMs":
    let golden = parseJson(sourceText("tests/data/golden_hashes.json"))
    check golden["seed"].getInt == 5140913
    check golden["gameVersion"].getStr == GameVersion
    for rom in ["warlords", "quadrapong", "foozpong"]:
      let config = episodeConfig(
        golden["seed"].getInt, rom = rom,
        startingLives = golden["startingLives"].getInt,
        maxTicks = golden["maxTicks"].getInt)
      let episode = runEpisode(config)
      let want = golden["roms"][rom]
      check episode.ticks == want["ticks"].getInt
      var i = 0
      var checked = 0
      for entry in want["hashes"]:
        let
          tick = entry[0].getInt
          expected = uint64(entry[1].getBiggestInt())
        check tick <= episode.hashes.len
        if tick <= episode.hashes.len:
          check episode.hashes[tick - 1] == expected
          inc checked
        inc i
      check checked == want["hashes"].len

  test "(d) no floating point, no fast-math and no rand( in the guarded modules":
    for path in GuardedModules:
      let body = strippedComments(sourceText(path))
      for banned in ["sin(", "cos(", "tan(", "arctan", "arcsin", "exp(",
                     " ln(", "pow(", "sqrt(", "hypot(", "float"]:
        if banned in body:
          checkpoint(path & " contains " & banned)
          check false
      # only drawInt may draw from the seeded stream
      if "rand(" in body:
        checkpoint(path & " calls rand(")
        check false
    for path in ["Dockerfile", "Dockerfile.replay-viewer",
                 "replay-viewer/config.nims"]:
      check "-ffast-math" notin sourceText(path)

  test "(e) DirQ64 re-derives from math.cos / math.sin entry by entry":
    for d in 0 ..< DirCount:
      let angle = 5.625 * float(d) * PI / 180.0
      check DirQ64[d].x == int32(round(4096.0 * cos(angle)))
      check DirQ64[d].y == int32(round(-4096.0 * sin(angle)))
    check DirQ64.len == 64
    check DirQ12One == 4096

  test "(f) perm and the first 200 serve directions are pure functions of the seed":
    for seed in [1, 5140913, 2147483646]:
      var a = initRngState(seed)
      var b = initRngState(seed)
      var da, db: int32 = 0
      let permA = drawPermutation(a, da)
      let permB = drawPermutation(b, db)
      check permA == permB
      check da == db
      # a permutation of 0..3
      var seen: array[CabinetCount, bool]
      for value in permA:
        check value >= 0 and value < CabinetCount
        seen[value] = true
      for flag in seen:
        check flag
      for i in 0 ..< 200:
        check drawInt(a, da, 0'i32, 63'i32) == drawInt(b, db, 0'i32, 63'i32)
      check da == db
    # and the config JSON echoes the same permutation the sim draws
    let config = episodeConfig(20250826)
    let game = initSimServer(config)
    let echoed = parseJson(config.configJson())["perm"]
    for seat in 0 ..< CabinetCount:
      check echoed[seat].getInt == int(game.perm[seat])

  test "(g) rngDraws is identical between two runs of the same command log":
    let config = episodeConfig(4242, startingLives = 3, maxTicks = 960)
    let first = runEpisode(config)
    let second = runEpisode(config)
    check first.sim.rngDraws == second.sim.rngDraws
    check first.sim.serveFallbacks == second.sim.serveFallbacks
    # the draw counter is hashed, so a divergence would already have failed (a)
    check first.sim.rngDraws > 0

  test "no ctf_/CTF_/paintball identifier survives in src, replay-viewer or client":
    var offenders: seq[string]
    for dir in ["src", "replay-viewer", "client"]:
      for path in walkDirRec(repoPath(dir)):
        if path.endsWith(".nim") or path.endsWith(".js") or
            path.endsWith(".nims") or path.endsWith(".html"):
          # chrome_common.js is copied BYTE-FOR-BYTE from the starter and its
          # sha256 is pinned by tests/test_viewer.nim, so its inherited
          # CTF_WIRE read is deliberate and exempt.
          if path.endsWith("chrome_common.js"):
            continue
          # wire_constants.nim publishes `window.CTF_WIRE` as an ALIAS of
          # `window.CABINET_WIRE` on purpose, and it is the only place that
          # name may appear: chrome_common.js is byte-identical to the
          # starter's and reads it, so the block publishes both names rather
          # than editing a file whose sha256 is pinned.
          if path.endsWith("wire_constants.nim"):
            check "window.CABINET_WIRE={" in readFile(path)
            continue
          let body = strippedComments(readFile(path))
          for banned in ["ctf_", "CTF_", "paintball", "Paintball"]:
            if banned in body:
              offenders.add(path & ": " & banned)
    if offenders.len > 0:
      checkpoint(offenders.join(", "))
    check offenders.len == 0
