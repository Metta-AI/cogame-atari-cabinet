## The manifest, held to the platform's contract AND to the design note's pins.
## The certifier rejects an unknown results field and an unbounded config
## array, and it schedules ZERO episodes without num_agents — so every one of
## these is a release blocker caught here instead of two phases later.

import std/[json, os, sets, strutils, tables, unittest]
import cabinet/[sim, roster, stances]
import helpers

let document = parseJson(sourceText("coworld_manifest_template.json"))

proc compose(): string = sourceText("compose.yaml")

suite "manifest":
  test "num_agents is 4 in EVERY variant and in the certification fixture":
    check document["variants"].len == 3
    for variant in document["variants"]:
      check variant["game_config"]["num_agents"].getInt == CabinetCount
      check variant["game_config"]["minPlayers"].getInt == CabinetCount
      check variant["game_config"]["players"].len == CabinetCount
      check variant["game_config"]["slots"].len == CabinetCount
      check variant.hasKey("description")
      check variant["description"].getStr.len > 0
      check variant["name"].getStr.len > 0
    let cert = document["certification"]
    check cert["game_config"]["num_agents"].getInt == CabinetCount
    check cert["players"].len == CabinetCount
    check cert["game_config"]["players"].len == CabinetCount

  test "every declared player occupies a slot and carries limits.cpu 1":
    var declared: HashSet[string]
    for player in document["player"]:
      declared.incl(player["id"].getStr)
      # anything below "1" is a 400 at upload (pistonball 0.1.1)
      check player["resources"]["limits"]["cpu"].getStr == "1"
      check player["resources"]["requests"]["cpu"].getStr.len > 0
      check player["type"].getStr == "player"
      check player["name"].getStr.len > 0
      check player["description"].getStr.len > 0
      check player["run"][0].getStr == "/bin/atari-cabinet-player"
    var seated: HashSet[string]
    for entry in document["certification"]["players"]:
      seated.incl(entry["player_id"].getStr)
    for id in declared:
      check id in seated

  test "results_schema keys are EXACTLY playerResultsJson's keys, seat arrays bounded":
    let properties = document["game"]["results_schema"]["properties"]
    check document["game"]["results_schema"]["additionalProperties"].getBool ==
      false
    var schemaKeys: HashSet[string]
    for key in properties.keys:
      schemaKeys.incl(key)
    var emittedKeys: HashSet[string]
    let config = episodeConfig(1, maxTicks = 240)
    let episode = runEpisode(config)
    for key in episode.results.keys:
      emittedKeys.incl(key)
    check schemaKeys == emittedKeys
    check schemaKeys.len == 22
    for key in resultsKeys():
      check key in schemaKeys
    for key in ["names", "aliases", "cabinets", "policyKinds", "scores", "win",
                "placements", "livesLeft", "concedes", "knockouts", "chips",
                "saves", "catches", "bricksLeft", "llmTurns",
                "fallbackTurns"]:
      check properties[key]["minItems"].getInt == CabinetCount
      check properties[key]["maxItems"].getInt == CabinetCount
      check episode.results[key].len == CabinetCount
    for key in ["names", "scores", "win", "placements", "rom", "reason",
                "endRule"]:
      check key in document["game"]["results_schema"]["required"].to(seq[string])
    check properties["reason"]["enum"].to(seq[string]) ==
      @[ReasonComplete, ReasonDeadline, ReasonFault]
    check properties["endRule"]["enum"].to(seq[string]) ==
      @[EndRuleLastStanding, EndRuleFullTime, EndRuleWallClock,
        EndRuleSimFault, EndRuleHostError]
    check properties["rom"]["enum"].to(seq[string]) == @RomNames

  test "every ARRAY in config_schema declares minItems and maxItems":
    let properties = document["game"]["config_schema"]["properties"]
    check document["game"]["config_schema"]["additionalProperties"].getBool ==
      false
    var arrays = 0
    for key, property in properties:
      if property{"type"}.getStr == "array":
        inc arrays
        checkpoint("array property " & key)
        check property.hasKey("minItems")
        check property.hasKey("maxItems")
        check property["minItems"].getInt <= property["maxItems"].getInt
    check arrays >= 3
    check "tokens" in document["game"]["config_schema"]["required"].to(seq[string])
    check properties["tokens"]["maxItems"].getInt == CabinetCount
    check properties["num_agents"]["maximum"].getInt == CabinetCount

  test "config_schema covers every field sim_config.update reads":
    let properties = document["game"]["config_schema"]["properties"]
    let body = sourceText("src/cabinet/sim_config.nim")
    var missing: seq[string]
    for line in body.splitLines():
      let trimmed = line.strip()
      if not trimmed.startsWith("node.readConfig"):
        continue
      let open = trimmed.find("\"")
      let close = trimmed.find("\"", open + 1)
      if open < 0 or close < 0:
        continue
      let key = trimmed[open + 1 ..< close]
      # `numAgents` is the camelCase alias of the manifest's `num_agents`, and
      # `rom` is read out of band (the preset resolves before every other key).
      if key in ["numAgents"]:
        continue
      if not properties.hasKey(key):
        missing.add(key)
    if missing.len > 0:
      checkpoint("config_schema is missing: " & missing.join(", "))
    check missing.len == 0

  test "game.protocols carries BOTH player and global as text objects":
    let protocols = document["game"]["protocols"]
    for key in ["player", "global"]:
      check protocols.hasKey(key)
      check protocols[key]["type"].getStr == "text"
      check protocols[key]["value"].getStr.len > 400

  test "game.docs.readme and all three pages are non-empty text":
    let docs = document["game"]["docs"]
    check docs["readme"]["type"].getStr == "text"
    check docs["readme"]["value"].getStr.len > 400
    check docs["pages"].len == 3
    var ids: seq[string]
    for page in docs["pages"]:
      ids.add(page["id"].getStr)
      check page["title"].getStr.len > 0
      check page["content"]["type"].getStr == "text"
      check page["content"]["value"].getStr.len > 400
    check ids == @["rules.md", "protocol.md", "stances.md"]

  test "game.description present, game.tags ABSENT, top-level tags >= 3":
    check document["game"]["description"].getStr.len > 40
    check not document["game"].hasKey("tags")
    check document["tags"].len >= 3
    check document["game"]["owner"].getStr.len > 0
    check document.hasKey("$schema")
    check document["episode_timeout_minutes"].getInt == 20

  test "the replay viewer is a STATIC BUNDLE nested under game":
    check document["game"]["replay_viewer"]["bundle"].getStr ==
      "static-replay-viewer"
    check not document.hasKey("replay_viewer")
    check not document.hasKey("version")
    check not document["game"].hasKey("version")
    check not document["game"].hasKey("display_name")
    # and the hook that produces it is committed EXECUTABLE
    let hook = repoPath("tools/build_replay_viewer.sh")
    check fileExists(hook)
    check fpUserExec in hook.getFilePermissions()

  test "every variant shares the clock, the cadence and the budget":
    var first: JsonNode = nil
    for variant in document["variants"]:
      let config = variant["game_config"]
      if first == nil:
        first = config
      for key in ["maxTicks", "turnTicks", "turnSpacingMs", "turnBudgetMs",
                  "wallClockBudgetSeconds", "lobbyJoinTimeoutTicks",
                  "attempt1Ms", "retryMs"]:
        check config[key].getInt == first[key].getInt
      # DEGRADE, NEVER HANG: play inside 60 % of episodeTimeoutSeconds (1200).
      check config["wallClockBudgetSeconds"].getInt <= 720
      check config["attempt1Ms"].getInt + config["retryMs"].getInt <=
        config["turnBudgetMs"].getInt
      check config["maxTicks"].getInt mod config["turnTicks"].getInt == 0
      check config["fastMode"].getBool

  test "the image placeholder is derived from the compose SERVICE name":
    let text = compose()
    var service = ""
    var image = ""
    for line in text.splitLines():
      let trimmed = line.strip()
      if trimmed.endsWith(":") and not trimmed.startsWith("services") and
          service.len == 0 and trimmed.len > 1:
        service = trimmed[0 ..< trimmed.len - 1]
      if trimmed.startsWith("image:"):
        image = trimmed.split(":")[1].strip()
    check service == "atari-cabinet"
    check image == "coworld-atari-cabinet"
    let placeholder = "{{" & service.toUpperAscii().replace("-", "_") &
      "_IMAGE}}"
    check placeholder == "{{ATARI_CABINET_IMAGE}}"
    check document["game"]["runnable"]["image"].getStr == placeholder
    for player in document["player"]:
      check player["image"].getStr == placeholder
    check "platform: linux/amd64" in text
    check "network: host" in text

  test "the secret namespace equals game.name exactly":
    let name = document["game"]["name"].getStr
    check name == GameName
    check document["game"]["runnable"]["env"]["ANTHROPIC_API_KEY_URI"].getStr ==
      "secret://coworld/" & name & "/anthropic_api_key"
    check document["game"]["runnable"]["type"].getStr == "game"
    check document["game"]["runnable"]["run"][0].getStr == "/bin/atari-cabinet"
    check document["game"]["runnable"]["source_url"].getStr.startsWith(
      "https://github.com/Metta-AI/cogame-atari-cabinet")

  test "the policy set is two LLM champions plus two scripted fillers, one image":
    let policies = parseJson(sourceText("tools/ci/policies.json"))
    check policies.len == 4
    var prompts, scripted, owned = 0
    for policy in policies:
      check policy["run"].getStr == "/bin/atari-cabinet-player"
      check policy["env"].hasKey("PLAYER_POLICY_LABEL")
      check policy["name"].getStr.startsWith("atari-cabinet-")
      if policy["env"].hasKey("PLAYER_PROMPT"):
        inc prompts
        check policy["env"]["PLAYER_PROMPT"].getStr.len > 200
      if policy["env"].hasKey("PLAYER_SCRIPTED"):
        inc scripted
        check policy["env"]["PLAYER_SCRIPTED"].getStr in ["bulwark", "spinner"]
      if policy.hasKey("player"):
        inc owned
        check policy["player"].getStr == "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
    check prompts == 2
    check scripted == 2
    check owned == 1

  test "the cert fixture is sized for certify's clock and the viewer's soak":
    let config = document["certification"]["game_config"]
    # 1440 ticks at 24 fps = 60 s of playback: a replay shorter than the
    # viewer smoke's soak reads as "frozen" (ecos, 2026-08-23).
    check config["maxTicks"].getInt >= 720
    check config["maxTicks"].getInt div TargetFps >= 30
    # no batch spacing offline, and a short lobby budget
    check config["turnSpacingMs"].getInt == 0
    check config["lobbyJoinTimeoutTicks"].getInt <= 1440
    check config["wallClockBudgetSeconds"].getInt <= 240
    # the release workflow gives certify room for the shutdown grace
    check "--timeout-seconds" in sourceText(".github/workflows/coworld-release.yml")
