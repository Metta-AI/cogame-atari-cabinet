## An END-TO-END episode writing a real replay, in every ROM, and the two
## things that make the bytes self-sufficient: they re-simulate to the same
## hashes, and tools/replay_summary.py reads them under a STRICT UTF-8 parser.

import std/[json, os, osproc, strutils, unicode, unittest]
import cabinet/[sim, stances, replays, replay_runtime, broadcast, decide]
import helpers

suite "replay":
  test "a full four-seat episode in each ROM writes a replay that re-simulates exactly":
    for romName in ["warlords", "quadrapong", "foozpong"]:
      let path = getTempDir() / ("cabinet-test-" & romName & ".replay")
      removeFile(path)
      let config = episodeConfig(
        5140913, rom = romName, startingLives = 3, maxTicks = 960)
      let episode = runEpisode(config, replayPath = path)
      check fileExists(path)
      check getFileSize(path) > 1000
      let data = parseReplayBytes(readFile(path))
      check data.gameName == GameName
      check data.gameVersion == GameVersion
      check data.hashes.len == episode.hashes.len
      # the embedded config JSON decodes STRICTLY and carries what the viewer
      # needs to rebuild this exact episode
      let embedded = parseJson(data.configJson)
      check embedded["rom"].getStr == romName
      check embedded["seed"].getInt == 5140913
      check embedded["startingLives"].getInt == 3
      check embedded["perm"].len == CabinetCount
      check embedded["geometry"]["arenaSideUu"].getInt == int(ArenaSide)
      check embedded["geometry"]["bricksPerRow"].getInt == BricksPerRow
      check embedded["num_agents"].getInt == CabinetCount
      # re-simulating from the config + the RECORDED BYTES reproduces every hash
      var runtime = initReplayRuntime(data, mismatchQuit = true)
      check runtime.player.hashMismatchTick == -1
      # the whole-match precompute walk (keyframes, the lead series, the story
      # beats, the lull spans) runs from a FRESH sim at tick 0
      block:
        var scanned = initReplayPlayer(data)
        scanned.mismatchQuit = true
        var fresh = initSimServer(runtime.config)
        fresh.gameEventLoggingEnabled = false
        scanned.buildReplayKeyframes(fresh)
        check scanned.scanComplete()
        check scanned.hashMismatchTick == -1
        check scanned.keyframes.len > 4
        check scanned.leadSeries.len > 1
        # a seek lands on a keyframe and converges
        var seekSim = initSimServer(runtime.config)
        seekSim.gameEventLoggingEnabled = false
        scanned.beginSeek(seekSim, scanned.replayMaxTick() div 2)
        while scanned.convergeSeek(seekSim):
          discard
        check seekSim.tickCount >= scanned.replayMaxTick() div 2
        check scanned.hashMismatchTick == -1
      var walked = initSimServer(runtime.config)
      walked.gameEventLoggingEnabled = false
      var replayed = initReplayPlayer(data)
      var seen = 0
      while replayed.playing and walked.tickCount < replayed.replayMaxTick():
        replayed.stepReplay(walked)
        inc seen
      check replayed.hashMismatchTick == -1
      check seen > 900
      # records: 4 registers, one stance per seat per turn, one result
      var registers, stanceRecords, results = 0
      for chat in data.chats:
        if chat.message.len == 0 or chat.message[0] != '{':
          continue
        let record = parseJson(chat.message)
        case record["k"].getStr
        of "register": inc registers
        of "stance":
          inc stanceRecords
          check chat.message.runeLen <= MaxStanceRecordRunes
          check chat.message.validateUtf8() == -1
        of "result":
          inc results
          let document = record["results"]
          check document["rom"].getStr == romName
          check document["reason"].getStr in
            [ReasonComplete, ReasonDeadline, ReasonFault]
          check document["endRule"].getStr in
            [EndRuleLastStanding, EndRuleFullTime, EndRuleWallClock,
             EndRuleSimFault, EndRuleHostError]
        else: discard
      check registers == CabinetCount
      check results == 1
      check stanceRecords >= CabinetCount * 4
      check episode.saves > 0
      removeFile(path)

  test "the episode really produced saves and concedes, not an empty board":
    let config = episodeConfig(4242, rom = "quadrapong", maxTicks = 2880)
    let episode = runEpisode(config)
    check episode.saves > 20
    check episode.concedes >= 1

  test "tools/replay_summary.py parses the bytes under a STRICT UTF-8 parser":
    # The fixture is forced to carry a non-ASCII `say` and a non-ASCII policy
    # label, so the UTF-8 path is REAL rather than incidental.
    let path = getTempDir() / "cabinet-utf8.replay"
    removeFile(path)
    let config = episodeConfig(7, startingLives = 3, maxTicks = 240)
    block:
      var game = initSimServer(config)
      game.gameEventLoggingEnabled = false
      for seat in 0 ..< CabinetCount:
        discard game.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
      var writer = openReplayWriter(path, config.configJson())
      for seat in 0 ..< CabinetCount:
        writer.lastMasks.add(NeutralCommand)
        writer.writeJoin(tickTime(0), seat, "P" & $(seat + 1), seat, "")
        writer.writeChat(tickTime(0), seat, registerRecord(
          seat, game.cabinetOfSeat(seat), "castellan-\u{1F3AF}", "llm",
          "bulwark"))
      var commands = newSeq[uint8](CabinetCount)
      for seat in 0 ..< CabinetCount:
        commands[seat] = NeutralCommand
      for tick in 0 ..< 240:
        if game.phase == Playing and game.gameTicksElapsed() mod 120 == 0:
          for seat in 0 ..< CabinetCount:
            var stance = defaultStance()
            stance.stance = stAim
            stance.aimAt = (game.cabinetOfSeat(seat) + 1) mod CabinetCount
            stance.source = ssLlm
            stance.note = "aiming \u{1F3AF} at the wounded cabinet"
            stance.say = "\u{1F3AF} next"
            let record = boundedStanceRecord(
              stance, game.gameTicksElapsed() div 120, seat,
              game.cabinetOfSeat(seat))
            writer.writeChat(tickTime(game.tickCount), seat, record)
        game.step(commands)
        writer.writeHash(uint32(game.tickCount), game.gameHash())
      writer.writeChat(tickTime(game.tickCount), 0, resultRecord(game))
      writer.closeReplayWriter()
    let summary = execCmdEx(
      "python3 " & repoPath("tools/replay_summary.py") & " " & path)
    check summary.exitCode == 0
    # strict: json.loads(out.decode("utf-8")) on the Python side, and a strict
    # parse plus a UTF-8 validation here.
    check summary.output.validateUtf8() == -1
    let document = parseJson(summary.output)
    check document["protocol"].getStr == "atari-cabinet/v1"
    check document["gameVersion"].getStr == GameVersion
    check document["rom"].getStr == "warlords"
    check document["seed"].getInt == 7
    check document["cabinets"].len == CabinetCount
    check document["stances"].len >= CabinetCount
    check document["results"]["rom"].getStr == "warlords"
    var sawEmoji = false
    for stance in document["stances"]:
      check stance["source"].getStr == "llm"
      if "\u{1F3AF}" in stance["say"].getStr:
        sawEmoji = true
    check sawEmoji
    removeFile(path)

  test "the broadcast state JSON keeps the starter's keys and the cab block":
    let config = episodeConfig(11, maxTicks = 480)
    let episode = runEpisode(config)
    var game = episode.sim
    let text = game.buildStateJson(
      newJArray(), true, 1, 480, true, true, -1, 0, 0, false, false, @[], @[],
      nil)
    check text.validateUtf8() == -1
    let state = parseJson(text)
    for key in ["t", "mt", "ph", "lob", "pl", "sp", "mx", "st", "lp", "sk",
                "ff", "en", "mm", "bs", "pov", "teams", "roster", "events",
                "cab", "stances", "hold"]:
      check state.hasKey(key)
    # EXACTLY four teams keys, and they are the four chrome_common knows
    var teamKeys: seq[string]
    for key in state["teams"].keys:
      teamKeys.add(key)
    check teamKeys.len == CabinetCount
    for key in ["red", "blue", "green", "yellow"]:
      check key in teamKeys
    check state["cab"]["rom"].getStr == "warlords"
    check state["cab"]["cabinets"].len == CabinetCount
    check state["cab"]["balls"].len == config.ballCount
    check state["roster"].len == CabinetCount
    # the roster is the ONE place a real policy name appears
    check state["roster"][0]["name"].getStr.len > 0
    check state["over"]["endRule"].getStr.len > 0

  test "half speed is a replay-only crawl":
    # The fleet-wide 1/2x replay speed: command '5' selects
    # ReplayHalfSpeedIndex, the chrome shows 0.5, and the step budget spends
    # one tick every OTHER frame (halfPhase parity) outside lulls.
    var replay = ReplayPlayer()
    replay.speedIndex = 0
    applySpeedCommand(replay.speedIndex, '5')
    check replay.speedIndex == ReplayHalfSpeedIndex
    check replay.replayDisplaySpeed() == 0.5
    # the integer speed clamps to 1x at 1/2x (live loop safety)
    check replay.replaySpeed() == 1
    replay.skipLulls = false
    replay.halfPhase = false
    check replay.replayStepBudget(0) == 0  # even frame spends no tick
    replay.halfPhase = true
    check replay.replayStepBudget(0) == 1  # odd frame spends one tick
    applySpeedCommand(replay.speedIndex, '+')
    check replay.speedIndex == 0           # '+' from 1/2x lands on 1x
    applySpeedCommand(replay.speedIndex, '-')
    check replay.speedIndex == ReplayHalfSpeedIndex  # '-' from 1x lands on 1/2x
    applySpeedCommand(replay.speedIndex, '-')
    check replay.speedIndex == ReplayHalfSpeedIndex  # 1/2x is the floor
