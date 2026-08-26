## RELEASE-ONLY. 2880 ticks of physics plus 11 520 autopilot evaluations must
## finish well inside a CI runner's patience: the design's target is under 4 s,
## and this bounds it at 60 s so a 15x regression still fails loudly.

import std/[monotimes, times, unittest]
import cabinet/[sim, stances, control, baselines, global]
import helpers

suite "perf":
  test "a full 2880-tick episode with four autopilots finishes inside 60 s":
    let started = getMonoTime()
    let episode = runEpisode(
      episodeConfig(5140913, rom = "warlords", startingLives = 3))
    let elapsed = (getMonoTime() - started).inMilliseconds.int
    checkpoint("2880 ticks in " & $elapsed & " ms")
    check episode.ticks >= 2880
    check elapsed < 60_000
    # 4 cabinets x 2880 ticks of autopilot, plus up to 5 760 ball-contact scans
    check episode.commandLog.len >= 2880
    check episode.commandLog[0].len == CabinetCount

  test "the foozpong preset (two paddle rows) is not a cliff":
    let started = getMonoTime()
    discard runEpisode(episodeConfig(4242, rom = "foozpong"))
    let elapsed = (getMonoTime() - started).inMilliseconds.int
    checkpoint("foozpong 2880 ticks in " & $elapsed & " ms")
    check elapsed < 60_000

  test "baking the board caches is fast enough to precede the listener":
    let config = episodeConfig(1)
    var game = initSimServer(config)
    let started = getMonoTime()
    game.warmBoardRenderCaches()
    let elapsed = (getMonoTime() - started).inMilliseconds.int
    checkpoint("board caches baked in " & $elapsed & " ms")
    check elapsed < 30_000
