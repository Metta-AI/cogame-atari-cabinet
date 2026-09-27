# THE CABINET — wire protocol

## The player socket

`ws://<game>:8080/player?slot=<N>&token=<T>` — a bad slot or token is a **403
before the upgrade**.

A seat registers policy metadata in a Sprite v1 chat frame (`0x81`), re-sent
for the first ten seconds because admission is slot-sequential:

```json
{"type":"register","kind":"scripted","scripted":"bulwark","policy":"my-player"}
```

No prompt or inference credential is sent to the game. Registration affects
spectator attribution only. Players acknowledge binary Sprite frames with
Ready (`0x85`); raw input masks are ignored because the game compiles stances
into command bytes.

At each turn the game sends all living connected seats a Text frame from one
shared snapshot, before accepting any order:

```json
{"type":"decision","protocol":"atari-cabinet.player.v2","turn":11,
 "deadline_ms":16000,"view":{"turn":11,"you":{},"balls":[],"rivals":[]}}
```

`view` is the full observation documented below. Players respond with a Text
frame containing the complete stance:

```json
{"type":"orders","turn":11,"action":{"stance":"guard","target_ball":"any",
 "aim_at":"none","post":0,"lead_ticks":12,"aggression":0.8,"note":"","say":""}}
```

The game rejects stale or malformed replies and accepts the first valid order
per seat. All seats share one monotonic `turnBudgetMs` deadline. Disconnected
seats immediately use native bulwark fallback; missing orders use it at the
deadline. The game retains validation, repair, scoring, results, and replay.

The per-seat frame carries the **whole board**: the arena, all four mouths
(open or welded), every paddle, every brick and every ball with its trail.
The cabinet is a CRT and the physics is public. Board labels carry only the
colour aliases (`showPlayerLabels` is forced false on the player stream), so no
real policy name is ever on a seat's screen.

## The board view a policy is asked about

Every 5 s of sim time (120 ticks) the game sends this private object to the
ordinary player. All numbers are in **cabinet coordinates**
(0..100 from the bottom-left corner, x right, y up), rounded to 2 decimals,
with `along`/`depth` in the seat's own side-local frame.

```json
{"turn": 11, "of": 24,
 "clock": {"tick": 1320, "of": 2880, "left_s": 65.0},
 "rom": "warlords",
 "you": {"alias": "GREEN", "side": "NORTH", "lives": 2, "out": false,
         "paddle": {"along": -6.40, "vel": 0.80, "half": 7.00, "depth": 14.00,
                    "travel_half": 43.00},
         "far_paddle": null, "holding": null,
         "mouth": {"half": 18.00, "open": true},
         "bricks": {"left": 5, "of": 9, "cols": [false, true, "…9…"]},
         "score": 41.750},
 "balls": [{"id": "B1", "state": "live", "pos": [62.10, 71.44],
            "vel": [0.61, -0.42], "speed": 0.74, "deg": 325.4,
            "last_touch": "BLUE", "held_by": null,
            "arrive_at": "GREEN", "arrive_in_ticks": 31,
            "arrive_along": 3.20, "arrive_in_ticks_for_you": 31}, "… ballCount entries …"],
 "rivals": ["… exactly three, alias / side / lives / out / bricks_left / paddle_along / score …"],
 "neighbours": {"plus_along": "YELLOW", "minus_along": "BLUE"},
 "rules": {"starting_lives": 3, "ball_count": 2, "brick_rows": 1,
           "catch_enabled": true, "far_paddle": false,
           "points": {"per_life_kept": 20.0, "crown": 15.0, "knockout": 2.0,
                      "chip": 0.5, "save": 0.25}},
 "your_last_stance": {"…": "the stance this seat set last turn, or null"}}
```

`arrive_along` and `arrive_in_ticks_for_you` are `null` when that ball will not reach **this** seat's line
inside the prediction bound; `arrive_at` names whichever cabinet's line it
reaches first. `arrive_in_ticks_for_you` gives the arrival time on this seat's line, which
can differ from the first arrival on another cabinet. The `arrive_*` fields are computed by **the same walk the
autopilot uses**, so a policy never has to guess at a quantity the engine
already knows.

**Hidden from every seat, with no exception:** which entrant holds any other
seat; any other seat's stance, note, say, prompt, latency, policy label or
fallback state; `perm`; `config.seed`; the RNG state; every future serve
direction; every real player name; and any host or wall-clock fact.

## The stance reply

```json
{"note": "BLUE is on 1 life and its wall is down to 2; take the free shot",
 "stance": "aim", "target_ball": "B1", "aim_at": "BLUE",
 "post": 0.0, "lead_ticks": 12, "aggression": 0.8, "say": "BLUE first"}
```

| field | cap / legal values | repair when violated |
|---|---|---|
| `note` | ≤ 160 runes | truncated to 160 runes |
| `stance` | `guard, aim, camp, catch, chase` | unrecognised → last turn's, else `guard`; `catch` without `catchEnabled` → `guard` |
| `target_ball` | ≤ 4 runes, `B1`…`B<ballCount>` or `any` | an id outside the set, or a ball not currently live → `any` |
| `aim_at` | ≤ 8 runes, a colour alias or `none`; never my own, never an out cabinet | unrecognised / missing / self / out → `none` (the autopilot then behaves as `guard`) |
| `post` | finite, clamped ±43.0, quantised to µu | non-finite / missing → last turn's, else `0.0`; a value beyond ±43 is read as a percent and rescaled |
| `lead_ticks` | integer, clamped 0..48 | non-finite / missing → `12` |
| `aggression` | finite, clamped 0..1, quantised to 0..255 | a value above 1 is divided by 100; missing → `0.8` |
| `say` | ≤ 48 runes | truncated to 48 runes, then the printable-ASCII shout sanitiser (which strips a leading `{`) |

Parsing is deliberately tolerant: markdown fences are stripped, the outermost
balanced `{…}` is taken (so prose before or after the object is fine), numeric
strings are accepted, `stance`/`target_ball`/`aim_at` are matched
case-insensitively and inside prose (`"the red cabinet"`, `"ball 2"`), and the
documented synonyms (`defend`→`guard`, `shoot`/`attack`→`aim`,
`hold`/`sit`→`camp`, `grab`→`catch`, `rush`→`chase`) are accepted. Only when no
object with at least one usable field can be recovered is the order rejected; the game uses `bulwark` if no valid order arrives
before the common deadline.

**Every recorded string is truncated on RUNE boundaries**, never bytes: a
byte-truncated multi-byte character renders in a browser and then fails a
strict UTF-8 parser.

## The results document

`COGAME_RESULTS_URI` receives exactly these 22 keys — the manifest's
`results_schema` is `additionalProperties: false`, so adding or removing one
here means editing `coworld_manifest_template.json` in the same commit. Every
per-seat array is in **seat order** and has exactly 4 entries; `names` are the
real policy names, `aliases` are the in-game ones, `cabinets` is `perm`.

```json
{"names": [], "aliases": [], "cabinets": [], "policyKinds": [], "scores": [],
 "win": [], "placements": [], "rom": "warlords", "startingLives": 3,
 "livesLeft": [], "concedes": [], "knockouts": [], "chips": [], "saves": [],
 "catches": [], "bricksLeft": [], "externalTurns": [], "fallbackTurns": [],
 "finalTick": 2604, "reason": "complete", "endRule": "last_standing",
 "seed": 5140913}
```

## The `/global` spectator snapshot and the replay

`ws://<game>:8080/global` streams the same binary sprite protocol plus the
broadcast chrome JSON, which rides as the **label of a reserved never-drawn
1×1 sprite** (id 4090) — the only channel that survives a hosted replay. The
state frame keeps the starter's key names (`t, mt, ph, lob, pl, sp, mx, st, lp,
sk, ff, en, mm, bs, pov, teams, roster, events, lead, beats, lulls, over,
hold`) so the byte-identical `chrome_common.js` runs unmodified; everything
cabinet-specific lives under `cab` and `stances`.

The replay is the starter's **binary `COWLDCAB`** format:

| content | carries |
|---|---|
| header | magic `COWLDCAB`, format version, `gameName` `atari-cabinet`, `gameVersion` |
| config JSON | `seed`, `rom`, the fully resolved ROM preset, `perm`, `num_agents`, `maxTicks`, `turnTicks`, the whole geometry table, the reward constants, `players[].name` (real names), `slots[].alias`, `fastMode` |
| joins / leaves | per seat: name, slot, token |
| inputs | **the action log**: one command byte per seat per tick, written on change only |
| chats | `register` / `stance` / `fallback` / `result` control records |
| hashes | one `gameHash` per tick |

`tools/replay_summary.py` (Python 3 stdlib only) turns those bytes into one
strict-UTF-8 JSON object for forensics, and `/replay-data` serves them back
from a replay-mode server.

## Runtime contract

`COGAME_CONFIG_URI`, `COGAME_RESULTS_URI`, `COGAME_SAVE_REPLAY_URI`,
`COGAME_LOAD_REPLAY_URI`, `COGAME_PLAYER_FAILURE_URI`, `COGAME_EVENTS_URI`,
`COGAME_METRICS_URI`, `COGAME_HOST`, `COGAME_PORT` — the starter's, unchanged.
`GET /healthz` and `GET /global` keep answering for a bounded ~20 s after the
artifacts are written, because the episode runner pings `/global` with a 2 s
deadline *after* the player pods start and a short episode can already be gone.


## Numeric ordinary policies

The bundled player accepts `PLAYER_NUMERIC_URL` pointing at a Metta frozen policy `/actions` endpoint.
`PLAYER_NUMERIC_KEY` optionally authenticates that player-side request; neither setting enters the game.
`PLAYER_POLICY_SESSION` identifies the episode. Each policy service owns one seat/session.

The JSONL training bridge exposes `encode` and `decode` using the same private-view codec as the ordinary player.
`encode` returns Metta's typed `DecisionEncoding`: 115 finite observation values and six independent action heads.

| Head | Choices |
| --- | --- |
| stance | guard, aim, camp, catch, chase; catch masked when disabled |
| target_ball | any or B1–B3; absent and non-live balls masked |
| aim_at | none or four cabinet aliases; self and eliminated rivals masked |
| post | whole cabinet units from -43 through 43 |
| lead_ticks | all integers from 0 through 48 |
| aggression | all 256 engine aggression bytes, divided by 255 |

Numeric orders use empty note and speech fields. The post grid does not represent sub-unit positions.
The observation encodes public board state, private own stance, ROM rules, and ball predictions.
It excludes seeds, seat permutations, hidden policies, future serves, and inference settings.
The teacher emits the six numeric action fields; its stance parameters match the native bulwark baseline.
The game validates the decoded complete order through the existing ordinary action path.
