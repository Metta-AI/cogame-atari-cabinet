## The baseline tuner: sweep the THREE `BaselineParams` numbers over a bounded
## grid and print the pick, exactly the way tools/ci/baseline_tuning.json
## records it.
##
##   nim r -d:release --path:src --path:tests tools/tune_baselines.nim
##
## THE PHYSICS CONSTANTS AND THE ROM PRESETS ARE NOT IN THIS GRID and must not
## be added to it. If the baselines cannot hold a rally, these three numbers
## are wrong — the sim is not (design note §Scripted baselines).
##
## The objective, in order: the share of seeds a `bulwark` seat takes placement
## 1 in a 2-bulwark / 2-spinner mix, then the bulwark mean score, then total
## saves. A filler pair that cannot beat the chaotic one gives the ladder no
## spread.

import std/[json, strformat, os]
import cabinet/[sim, baselines]
import helpers

const
  ReactTicksGrid = [20, 32, 44, 56, 68, 80, 96, 140, 200, 240]
  CampPostGrid = [0, 6, 12]
  AggressionGrid = [400, 600, 800, 1000]
  Seeds = 20
  Roms = ["warlords", "quadrapong", "foozpong"]

proc seedOf(index: int): int = index * 7919 + 13

when isMainModule:
  var
    best = DefaultBaselineParams
    bestWins = -1
    bestScore = 0.0
    rows = newJArray()
  for reactTicks in ReactTicksGrid:
    for campPostCu in CampPostGrid:
      for aggressionMilli in AggressionGrid:
        let params = BaselineParams(
          reactTicks: reactTicks, campPostCu: campPostCu,
          aggressionMilli: aggressionMilli)
        var
          wins = 0
          bulwarkScore = 0.0
          saves = 0
          concedes = 0
        for romName in Roms:
          let lives = if romName == "quadrapong": 5 else: 3
          for index in 0 ..< Seeds:
            let episode = runEpisode(
              episodeConfig(seedOf(index), rom = romName,
                startingLives = lives),
              kinds = [blBulwark, blSpinner, blBulwark, blSpinner],
              params = params)
            if episode.winnerSeat mod 2 == 0:
              inc wins
            saves += episode.saves
            concedes += episode.concedes
            for seat in [0, 2]:
              bulwarkScore += episode.results["scores"][seat].getFloat
        rows.add(%*{
          "reactTicks": reactTicks,
          "campPostCu": campPostCu,
          "aggressionMilli": aggressionMilli,
          "bulwarkPlacement1": wins,
          "bulwarkMeanScore": bulwarkScore / float(Seeds * Roms.len * 2),
          "saves": saves,
          "concedes": concedes
        })
        echo &"react={reactTicks} post={campPostCu} aggr={aggressionMilli}: " &
          &"bulwark placement-1 {wins}/{Seeds * Roms.len}, mean " &
          &"{bulwarkScore / float(Seeds * Roms.len * 2):.1f}, saves {saves}, " &
          &"concedes {concedes}"
        if wins > bestWins or
            (wins == bestWins and bulwarkScore > bestScore):
          bestWins = wins
          bestScore = bulwarkScore
          best = params
  echo "PICK: reactTicks=", best.reactTicks, " campPostCu=", best.campPostCu,
    " aggressionMilli=", best.aggressionMilli
  if paramCount() >= 1 and paramStr(1) == "--write":
    var document = parseJson(readFile("tools/ci/baseline_tuning.json"))
    document["pick"] = %*{
      "reactTicks": best.reactTicks,
      "campPostCu": best.campPostCu,
      "aggressionMilli": best.aggressionMilli
    }
    document["sweep"] = rows
    writeFile("tools/ci/baseline_tuning.json", document.pretty() & "\n")
    echo "wrote tools/ci/baseline_tuning.json"
