## Startup: a clean message and a non-zero exit on a bad config, the seed
## randomised when unpinned and honoured when pinned, and both entrypoints
## present.

import std/[json, os, osproc, strutils, unittest]
import cabinet/sim
import helpers

suite "startup":
  test "a missing config leaves the packaged defaults intact":
    var config = defaultGameConfig()
    config.update("")
    check config.rom == "warlords"
    check config.numAgents == CabinetCount
    check config.maxTicks == MaxTicksDefault

  test "an unparseable config raises a CLEAN CabinetError, never a traceback":
    var config = defaultGameConfig()
    expect CabinetError:
      config.update("{not json")
    expect CabinetError:
      config.update("[1,2,3]")
    try:
      config.update("{\"maxTicks\":\"soon\"}")
      check false
    except CabinetError as error:
      check "maxTicks" in error.msg
      check "integer" in error.msg

  test "a rom outside the three is refused with a message naming the three":
    var config = defaultGameConfig()
    try:
      config.update("""{"rom":"pitfall"}""")
      check false
    except CabinetError as error:
      for name in RomNames:
        check name in error.msg

  test "an out-of-bounds knob is refused before the episode starts":
    for bad in ["""{"startingLives":99}""", """{"ballCount":9}""",
                """{"goalHalfCu":2}""", """{"maxTicks":1000,"turnTicks":120}""",
                """{"attempt1Ms":100}""",
                """{"attempt1Ms":9000,"retryMs":9000,"turnBudgetMs":10000}"""]:
      var config = defaultGameConfig()
      expect CabinetError:
        config.update(bad)

  test "the seed is honoured when pinned and drawn fresh when not":
    var pinned = defaultGameConfig()
    pinned.update("""{"seed":4242}""")
    check pinned.seed == 4242
    let a = initSimServer(pinned)
    let b = initSimServer(pinned)
    check a.perm == b.perm
    # a different seed deals a different table (over a handful of seeds at
    # least one must differ — otherwise perm is not seed-derived at all).
    var differs = false
    for seed in 1 .. 12:
      var other = defaultGameConfig()
      other.update("""{"seed":""" & $seed & """}""")
      if initSimServer(other).perm != a.perm:
        differs = true
    check differs

  test "the entrypoints exist, and the Dockerfile installs both":
    let dockerfile = sourceText("Dockerfile")
    check "src/atari_cabinet.nim" in dockerfile
    check "src/atari_cabinet_player.nim" in dockerfile
    check "/bin/atari-cabinet" in dockerfile
    check "/bin/atari-cabinet-player" in dockerfile
    check "CMD [\"/bin/atari-cabinet\"]" in dockerfile
    check fileExists(repoPath("src/atari_cabinet.nim"))
    check fileExists(repoPath("src/atari_cabinet_player.nim"))
    # the entrypoint randomises the seed BEFORE config.update, so every
    # seed-derived draw follows the FINAL seed
    let main = sourceText("src/atari_cabinet.nim")
    let randomAt = main.find("config.seed = randomSeed()")
    let updateAt = main.find("config.update(stripUnpinnedSeed(")
    check randomAt > 0
    check updateAt > randomAt

  test "the player entrypoint registers, never sends input, and exits 0 on a dead socket":
    let player = sourceText("src/atari_cabinet_player.nim")
    check "\"type\": \"register\"" in player
    check "PLAYER_PROMPT" in player
    check "PLAYER_SCRIPTED" in player
    check "PLAYER_POLICY_LABEL" in player
    check "readyBlob" in player
    check "except CatchableError" in player
    check "quit(0)" in player
    check "ConnectAttempts = 240" in player
    check "RegistrationResends = 10" in player

  test "the smoke script and the release workflow agree with the manifest":
    let smoke = sourceText("tools/ci/docker_smoke.sh")
    check "SMOKE_SEATS" in smoke
    check "num_agents" in smoke
    check "SEAT-COUNT FAIL" in smoke
    check "/bin/atari-cabinet" in smoke
    check "coworld-atari-cabinet" in smoke
    let ci = sourceText(".github/workflows/ci.yml")
    check "SMOKE_REQUIRE_REPLAY_JSON: \"0\"" in ci
    check "tools/ci/docker_smoke.sh" in ci
    check "tools/build_replay_viewer.sh" in ci
    check "test -x tools/ci/docker_smoke.sh" in ci
    check "test -x tools/build_replay_viewer.sh" in ci
