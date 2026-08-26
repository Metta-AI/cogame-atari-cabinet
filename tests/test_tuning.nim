## The shipped BaselineParams are the sweep's committed pick, and the sweep is
## reproducible from the repo.

import std/[json, strutils, unittest]
import cabinet/baselines
import helpers

suite "tuning":
  test "the committed sweep record matches the shipped defaults":
    let tuning = parseJson(sourceText("tools/ci/baseline_tuning.json"))
    check tuning["pick"]["reactTicks"].getInt ==
      DefaultBaselineParams.reactTicks
    check tuning["pick"]["campPostCu"].getInt ==
      DefaultBaselineParams.campPostCu
    check tuning["pick"]["aggressionMilli"].getInt ==
      DefaultBaselineParams.aggressionMilli
    check tuning["seeds"].getInt >= 20
    check tuning["roms"].len == 3
    check tuning["objective"].getStr.len > 40
    check tuning["swept"].getStr == "tools/tune_baselines.nim"

  test "the sweep grid is bounded and contains the pick on every axis":
    let grid = parseJson(sourceText("tools/ci/baseline_tuning.json"))["grid"]
    for axis, values in grid:
      check values.len >= 3
      check values.len <= 24
    proc contains(axis: string, want: int): bool =
      for value in grid[axis]:
        if value.getInt == want:
          return true
      false
    check contains("reactTicks", DefaultBaselineParams.reactTicks)
    check contains("campPostCu", DefaultBaselineParams.campPostCu)
    check contains("aggressionMilli", DefaultBaselineParams.aggressionMilli)

  test "the tuner exists and sweeps ONLY the three tunables":
    let tuner = sourceText("tools/tune_baselines.nim")
    check "BaselineParams" in tuner
    check "reactTicks" in tuner
    check "campPostCu" in tuner
    check "aggressionMilli" in tuner
    # it must not touch the physics or the ROM presets
    for banned in ["BallSpeedMax", "PaddleMaxSpeed", "goalHalfCu",
                   "paddleHalfCu", "ballSpeed0Milli"]:
      check banned notin tuner
