# THE CABINET (`cogame-atari-cabinet`)

**Four arcade cabinets ring a square CRT, each defending a gap in its own wall
with a paddle that is also a gun; the last cabinet with lives standing wins,
and the ROM rotates.**

Four cabinets sit on the four sides of a 100 × 100 box. Each one owns a
**mouth** in its own wall, a **paddle** that slides in front of it, and (ROM
permitting) a **brick castle** in between. Two balls rip around the box at
rising speed. Every ball that gets through your mouth costs you a life; run out
and your mouth is welded shut. Which of the three ROMs is loaded —
`warlords`, `quadrapong`, `foozpong` — is a manifest variant, announced before
the round, stamped into the replay and printed on the scorebug.

Where the ball leaves your paddle depends on **where on the bar it landed** and
**which way the bar was moving**: thirteen outgoing angles, 11.25° apart. That
is the whole strategy. A paddle is not only a shield, it is a gun, and every
rally is a choice about whom to shoot at.

* Rules and every constant: [docs/RULES.md](docs/RULES.md)
* Wire protocol, the board view and the results document:
  [docs/PROTOCOL.md](docs/PROTOCOL.md)
* Writing a policy: [docs/STANCES.md](docs/STANCES.md)
* The design note this repo implements:
  [docs/plans/2026-08-26-atari-cabinet-design.md](docs/plans/2026-08-26-atari-cabinet-design.md)

## Ordinary player policies

Every five seconds of simulation time, the game sends each living cabinet a
private observation. The player returns a complete stance over
`atari-cabinet.player.v2`. Scripted, prompt, and trained policies use this same
interface. Prompts and inference credentials stay in the player process.

The game validates orders and uses a native bulwark fallback on invalid,
missing, or disconnected players. A deterministic autopilot compiles accepted
stances into recorded command bytes at 24 Hz. The replay needs no model calls.

```bash
coworld upload-policy coworld-atari-cabinet:latest \
  --name my-cabinet --run /bin/atari-cabinet-player \
  --secret-env PLAYER_PROMPT="Defend first: if any ball reaches your line
inside 48 ticks, guard it. Otherwise aim at the alive rival with the fewest
lives. Never post wider than +/-12."
```

The same image also ships two scripted baselines, selected by env var, so an
prompt policy and a scripted policy use the same observation and order protocol:

| env | seat |
|---|---|
| `PLAYER_PROMPT=<strategy>` | an LLM seat |
| `PLAYER_SCRIPTED=bulwark` | the certification player, the per-turn fallback and the default |
| `PLAYER_SCRIPTED=spinner` | the chaotic filler: chases everything, never camps |

## Watching it

The replay is a **static file plus a browser wasm viewer** — never a pod. The
same `src/cabinet/sim.nim` the server ran is compiled to wasm32 and re-steps
the episode from the recorded command bytes, re-checking the recorded
`gameHash` **every tick**; one divergent bit is surfaced as a mismatch tick in
the chrome. The board is a CRT: scanlines, four tinted walls, chunky bricks,
thick bars with a bright leading edge, balls with motion trails, and a dashed
**aim ray** from each cabinet toward whatever it told the autopilot to shoot
at — which is where you see the LLM playing.

```bash
tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
node tools/ci/viewer_smoke.mjs --bundle dist/static-replay-viewer \
  --replay dist/smoke/replay.json --strict-text-bounds
python3 tools/replay_summary.py episode.replay | jq .
```

## Layout

```
src/atari_cabinet.nim         the game server entrypoint (seed randomised BEFORE config.update)
src/atari_cabinet_player.nim  the ordinary policy player -> /bin/atari-cabinet-player
src/cabinet/                  sim_types, trig, arena, rom, sim_config, sim_state, sim,
                              roster, stances, control, baselines, decide, events,
                              labels, global, broadcast, wire_constants, replays,
                              replay_runtime, server
replay-viewer/                the wasm entry + the emscripten link flags + the shell JS
client/                       the broadcast chrome (chrome_common.js is byte-identical
                              to coworld-ctf's; replay_broadcast.html is its page plus
                              an appended ATARI-CABINET block)
tests/                        16 suites; ci.yml runs every one in debug AND release
tools/                        the replay-viewer build hook, the baseline tuner, the
                              replay summariser and the CI scaffold
```

## Building and testing

The sandbox that authored this repo has no Docker, no Nim and no emsdk: **CI is
the only harness**, and `.github/workflows/ci.yml` is the verdict.

```bash
nim r --path:src tests/test_physics.nim      # any suite, debug
nim r -d:release --path:src tests/test_determinism.nim
docker build -t coworld-atari-cabinet:ci . && ./tools/ci/docker_smoke.sh coworld-atari-cabinet:ci
```

## Determinism

The whole sim runs in **integers** — micro-units (1 cu = 10 000 µu), a
committed 64-entry direction table, and box-vs-box contacts resolved by integer
cross-multiplication in `int64`. There is no square root, no trigonometry and
**no floating point at all** under
`src/cabinet/{sim,arena,rom,trig,sim_types,sim_config,sim_state}.nim`
(grep-enforced by `tests/test_determinism.nim`), because the replay viewer is a
**wasm32** build of the same module the **amd64** server ran and their per-tick
hash chains must match bit-for-bit. The autopilot and the renderer sit outside
that boundary and may use floats: only the recorded bytes cross it.

Prompt players need `ANTHROPIC_API_KEY` or their hosted inference sidecar in
the player environment. Optional settings are `PLAYER_MODEL` and
`PLAYER_MAX_OUTPUT_TOKENS`. The game receives no inference credentials.

### Ordinary-player smoke

`tools/ci/ordinary_player_smoke.py` runs four native player processes against
one game, with a local model stub or explicitly absent credentials. The
`disconnect` mode terminates one owned player and makes the remaining model
transport fail. It checks game completion, accepted orders, fallback, results,
and replay. CI runs all three modes. Stub choices prove routing, not strength.
