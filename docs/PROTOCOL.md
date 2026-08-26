# THE CABINET — wire protocol

## The player socket

`ws://<game>:8080/player?slot=<N>&token=<T>` — a bad slot or token is a **403
before the upgrade**.

A seat sends exactly **one kind of message it authors**: its registration, as a
Sprite v1 chat frame (`0x81`), re-sent on the first ~10 s of frames because
joins are slot-sequential and the lobby streams frames to a socket before it is
admitted (the server holds an unappliable registration rather than dropping
it):

```json
{"type":"register","prompt":"<strategy text or empty>",
 "scripted":"bulwark"|"spinner"|null,"policy":"<free label>"}
```

`prompt` is capped at 4000 runes at the transport (over-long is truncated,
never rejected) and is **never** written to the replay or the results. A seat
that never registers, or registers with neither field, is `bulwark`.

After that the seat only **receives**: one binary Sprite v1 frame per tick, and
it answers each with the Ready packet (`0x85`). **SEATS SEND NO INPUTS.** The
server computes every command byte, so any input mask arriving on a player
socket is discarded — which is also why the Ready packet is legitimate here in
a way it is not for an ordinary client: there is no dead-reckoned input to
corrupt.

The per-seat frame carries the **whole board**: the arena, all four mouths
(open or welded), every paddle, every brick and every ball with its trail.
The cabinet is a CRT and the physics is public. Board labels carry only the
colour aliases (`showPlayerLabels` is forced false on the player stream), so no
real policy name is ever on a seat's screen.

## The board view a policy is asked about

Every 5 s of sim time (120 ticks) the server composes this object, appends it
to the seat's `PLAYER_PROMPT` under a "GUIDANCE FROM YOUR OPERATOR" heading,
and asks Claude for a stance. All numbers are in **cabinet coordinates**
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
            "arrive_along": 3.20}, "… ballCount entries …"],
 "rivals": ["… exactly three, alias / side / lives / out / bricks_left / paddle_along / score …"],
 "neighbours": {"plus_along": "YELLOW", "minus_along": "BLUE"},
 "rules": {"starting_lives": 3, "ball_count": 2, "brick_rows": 1,
           "catch_enabled": true, "far_paddle": false,
           "points": {"per_life_kept": 20.0, "crown": 15.0, "knockout": 2.0,
                      "chip": 0.5, "save": 0.25}},
 "your_last_stance": {"…": "the stance this seat set last turn, or null"}}
```

`arrive_along` is `null` when that ball will not reach **this** seat's line
inside the prediction bound; `arrive_at` names whichever cabinet's line it
reaches first. The `arrive_*` triple is computed by **the same walk the
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
object with at least one usable field can be recovered does the single retry
fire, and then the `bulwark` fallback.

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
 "catches": [], "bricksLeft": [], "llmTurns": [], "fallbackTurns": [],
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
| chats | `register` / `stance` / `fallback` / `budget_guard` / `result` control records |
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
