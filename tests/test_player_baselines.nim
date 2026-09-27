import std/[json, unittest]
import cabinet/[sim, stances, control, baselines, player_baselines, decide]
import helpers

suite "ordinary player baseline parity":
  test "private observations preserve complete scripted orders in all ROMs":
    var decisions = 0
    for rom in ["warlords", "quadrapong", "foozpong"]:
      for seed in [7, 19]:
        var game = initSimServer(episodeConfig(seed, rom = rom))
        game.gameEventLoggingEnabled = false
        for seat in 0 ..< CabinetCount:
          discard game.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
        var engine = initDecisionEngine(game)
        var commands = newSeq[uint8](CabinetCount)
        while game.phase != GameOver:
          if game.phase == Playing and game.gameTicksElapsed() mod game.config.turnTicks == 0:
            let turn = game.gameTicksElapsed() div game.config.turnTicks
            for seat in 0 ..< CabinetCount:
              let cabinet = game.cabinetOfSeat(seat)
              let view = parseJson(engine.seatViewJson(game, seat, turn))
              for kind in [blBulwark, blSpinner]:
                let native = game.baselineStance(cabinet, kind, turn)
                let player = view.baselineStance(kind)
                check player == native
                inc decisions
              engine.stances[seat] = view.baselineStance(blBulwark)
              engine.haveStance[seat] = true
          for cabinet in 0 ..< CabinetCount:
            let seat = game.seatOfCabinet(cabinet)
            commands[seat] = game.paddleCommand(cabinet, engine.stances[seat])
          game.step(commands)
    echo "private-view parity decisions: ", decisions
