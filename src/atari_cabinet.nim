## THE CABINET — the game server entrypoint.
##
## Seed randomisation happens HERE, BEFORE `config.update`, so every
## seed-derived draw follows the FINAL seed: the seat -> cabinet permutation is
## the first draw of the stream and the replay's config JSON echoes it, so a
## seed injected after the parse would publish a permutation the sim never
## played (tests/test_startup.nim).

import std/[json, os, sysrand]
import bitworld/runtime
import cabinet/[sim, server]

const LegacyFixedSeed = 0xA6019
  ## The old compiled-in default seed. A config carrying it — or no seed at
  ## all — is "nobody chose a seed" and gets a fresh random one: with a public
  ## fixed seed every serve direction would be pre-computable by opponents.

proc seedPinned(configJson: string): bool =
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed") and
      node["seed"].getInt != LegacyFixedSeed
  except CatchableError:
    false  # config.update reports the real parse error.

proc randomSeed(): int =
  ## A crypto-random 31-bit seed from the OS.
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(CabinetError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc stripUnpinnedSeed(configJson: string): string =
  if configJson.len == 0:
    return configJson
  try:
    let node = parseJson(configJson)
    if node.kind == JObject and node.hasKey("seed"):
      node.delete("seed")
    $node
  except CatchableError:
    configJson

when isMainModule:
  let runtimeConfig = readRuntimeConfig()
  if getEnv("COGAME_CONFIG_URI").len == 0 and runtimeConfig.config.len == 0:
    echo "atari-cabinet: no config supplied; using the packaged defaults"
  let localReplayPath =
    if runtimeConfig.replayUri.len > 0:
      getTempDir() / ("cabinet-replay-" & $getCurrentProcessId() & ".replay")
    else:
      ""
  var config = defaultGameConfig()
  try:
    if seedPinned(runtimeConfig.config):
      config.update(runtimeConfig.config)
    else:
      config.seed = randomSeed()
      config.update(stripUnpinnedSeed(runtimeConfig.config))
      echo "seed not pinned; randomized"
  except CabinetError as error:
    # A clean message and a non-zero exit, never a traceback
    # (tests/test_startup.nim).
    quit("atari-cabinet: bad config: " & error.msg, 1)
  echo "atari-cabinet config: rom=", config.rom, " seed=", config.seed,
    " num_agents=", config.numAgents, " lives=", config.startingLives,
    " balls=", config.ballCount, " maxTicks=", config.maxTicks,
    " turnTicks=", config.turnTicks, " budget=",
    config.wallClockBudgetSeconds, "s"

  let loadReplayPath =
    if runtimeConfig.replayMode:
      let path = getTempDir() /
        ("cabinet-load-replay-" & $getCurrentProcessId() & ".replay")
      writeFile(path, runtimeConfig.replay)
      path
    else:
      ""
  runServerLoop(
    runtimeConfig.host,
    runtimeConfig.port,
    config,
    localReplayPath,
    loadReplayPath,
    runtimeConfig)
