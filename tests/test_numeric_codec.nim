## Full-game parity, legal masks, and boundaries over real private observations.
import std/[json, unittest]
import cabinet/[sim, decide, stances, baselines, control, numeric_codec]

suite "ordinary numeric stance codec":
  test "all ROMs and ball counts preserve baseline simulation":
    var checked = 0
    for rom in ["warlords", "quadrapong", "foozpong"]:
      for ballCount in 1 .. MaxBalls:
        var config = defaultGameConfig()
        config.update($(%*{"rom": rom, "seed": 19, "ballCount": ballCount,
          "startWaitTicks": 1, "maxTicks": 2880}))
        var game = initSimServer(config)
        game.gameEventLoggingEnabled = false
        for seat in 0 ..< CabinetCount:
          discard game.addPlayer("P" & $seat, seat, "", trusted = true)
        while game.phase == Lobby:
          game.step([NeutralCommand, NeutralCommand, NeutralCommand, NeutralCommand])
        var engine = initDecisionEngine(game)
        while game.phase == Playing:
          let turn = game.gameTicksElapsed() div config.turnTicks
          for seat in 0 ..< CabinetCount:
            let cabinet = game.cabinetOfSeat(seat)
            if game.cabinets[cabinet].isOut: continue
            let view = parseJson(engine.seatViewJson(game, seat, turn))
            let encoding = numericEncoding(view, turn)
            check encoding["values"].len == ObservationSize
            var total = 0
            for size in ActionSizes: total += size
            check encoding.actionMask().len == total
            var cabinetOut: array[CabinetCount, bool]
            var ballLive: seq[bool]
            for index in 0 ..< CabinetCount: cabinetOut[index] = game.cabinets[index].isOut
            for ball in game.balls: ballLive.add(ball.state == bsLive)
            let native = game.baselineStance(cabinet, blBulwark, turn)
            let heads = encodeStance(native)
            let decoded = parseCabinetStance(decodeActions(view, heads), cabinet,
              cabinetOut, ballLive, config.catchEnabled, defaultStance(), false)
            check decoded.stance == native.stance
            check decoded.targetBall == native.targetBall
            check decoded.aimAt == native.aimAt
            check decoded.postUu == native.postUu
            check decoded.leadTicks == native.leadTicks
            check decoded.aggression255 == native.aggression255
            var offset = 0
            for head, size in ActionSizes:
              for choice in 0 ..< size:
                if not encoding.actionMask()[offset + choice].getBool(): continue
                var altered = heads.copy()
                altered.elems[head] = %choice
                let candidate = parseCabinetStance(decodeActions(view, altered), cabinet,
                  cabinetOut, ballLive, config.catchEnabled, defaultStance(), false)
                check candidate.validateStance(cabinet, cabinetOut, ballLive).len == 0
                inc checked
              offset += size
            engine.stances[seat] = decoded
            engine.haveStance[seat] = true
          var commands = newSeq[uint8](CabinetCount)
          for tick in 0 ..< config.turnTicks:
            for seat in 0 ..< CabinetCount:
              commands[seat] = game.paddleCommand(game.cabinetOfSeat(seat), engine.stances[seat])
            game.step(commands)
            if game.phase != Playing: break
        check game.phase == GameOver
    echo "legal numeric orders checked: ", checked
