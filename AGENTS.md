# Agent operating guide — cogame-atari-cabinet

Orientation for coding agents working in this repo. The GAME's rules live in
[docs/RULES.md](docs/RULES.md), the wire in [docs/PROTOCOL.md](docs/PROTOCOL.md)
and the policy interface in [docs/STANCES.md](docs/STANCES.md). The design note
this repo implements — every constant, every decision and its reason — is
[docs/plans/2026-08-26-atari-cabinet-design.md](docs/plans/2026-08-26-atari-cabinet-design.md).
This file covers the things that are easy to get wrong.

## Layout

- `src/atari_cabinet.nim` — the game server entrypoint. **Seed randomisation
  happens HERE, before `config.update`**, because the seat→cabinet permutation
  is the FIRST draw of the seeded stream and the replay's config JSON echoes
  it: a seed injected after the parse would publish a permutation the sim never
  played.
- `src/atari_cabinet_player.nim` — the thin seat registrar (`/bin/atari-cabinet-player`).
  It sends ONE registration chat frame, re-sends it for ~10 s, answers every
  frame with the Ready packet, and **exits 0 on a dead socket**.
- `src/cabinet/` — the sim. `sim.nim` imports and RE-EXPORTS every module, so
  `import cabinet/sim` sees everything.

  | module | what it owns |
  |---|---|
  | `sim_types.nim` | consts (incl. `GameVersion`), types, the flatty wire shape — **field order is sacred** |
  | `trig.nim` | the committed 64-entry `DirQ64` table: the whole of this game's trigonometry |
  | `arena.nim` | the fixed square geometry, the side-local frames, the brick lattice, the swept box contacts, the seeded stream |
  | `rom.nim` | the three ROM presets and the `defaults → preset → explicit` order |
  | `sim_config.nim` | `GameConfig` lifecycle, validation and the replay's config echo |
  | `sim_state.nim` | `SimServer`, the lobby, the event sink, the stance feed and **`gameHash`** |
  | `sim.nim` | the gameplay core and the step loop |
  | `roster.nim` | join/auth and the 22-key results document |
  | `stances.nim` | the reply schema, the tolerant parser and the RUNE discipline |
  | `control.nim` | the autopilot: one command byte per cabinet per tick |
  | `baselines.nim` | `bulwark`, `spinner` and the three tunables |
  | `llm.nim` / `decide.nim` | the Bedrock/Anthropic transport and the per-turn PARALLEL batch |
  | `global.nim` | the pixie board bake and the Sprite v1 packet |
  | `broadcast.nim` | state deltas → events, and the one state JSON the chrome reads |
  | `server.nim` | mummy HTTP/websockets, the `COGAME_*` contract, the artifact writes |

## The determinism boundary — the one rule that outranks the others

The replay viewer is a **wasm32** build of the SAME `sim.nim` the **amd64**
server ran, and their per-tick `gameHash` chains must match bit-for-bit.

- **NO FLOATING POINT** in `sim.nim`, `arena.nim`, `rom.nim`, `trig.nim`,
  `sim_types.nim`, `sim_config.nim`, `sim_state.nim`. No `sin`, `cos`,
  `arctan2`, `sqrt`, `pow`, `float`. `tests/test_determinism.nim` greps for
  them, comment-stripped, and fails the build on a hit.
- Every stored sim field is explicitly `int32` / `int64` / `uint8` / `bool` /
  an enum. **No bare `int` in a hashed field**: Nim's `int` is 64-bit natively
  and 32-bit under `--cpu:wasm32`.
- Every product or quotient of two sim quantities goes through `int64` and is
  narrowed with an explicit truncating `div`.
- Randomness is ONE seeded stream, every draw through `drawInt`, and the draw
  COUNT (`rngDraws`) is hashed — so a divergence in how many draws a build took
  is caught at the tick it happens.
- The autopilot (`control.nim`), the renderer (`global.nim`) and the parser's
  numeric handling sit OUTSIDE the boundary and may use floats: only the
  recorded BYTES cross it.

If `tests/test_determinism.nim` fails, the physics or a build flag changed.
**Fix the code, never the test.**

## GameVersion

`GameVersion` in `src/cabinet/sim_types.nim` gates replay compatibility and
carries a **prepend-only** changelog comment in the shape
`GVn (short rule name): HEADLINE`. Bump it in the same commit as any rule
change, and regenerate the golden fixture:

```bash
nim r -d:release --path:src --path:tests tools/gen_golden_hashes.nim
```

`tests/data/golden_hashes.json` pins every 48th tick of a four-bulwark episode
in each of the three ROMs. If it has to change, the RULES changed.

## Tuning the baselines

`tools/tune_baselines.nim` sweeps the THREE `BaselineParams` numbers
(`reactTicks`, `campPostCu`, `aggressionMilli`) and `tools/ci/baseline_tuning.json`
records the pick; `tests/test_tuning.nim` re-asserts it.

**The physics constants and the ROM presets are not in that grid and must not
be added to it.** If the baselines cannot hold a rally, those three numbers are
wrong — the sim is not.

```bash
nim r -d:release --path:src --path:tests tools/tune_baselines.nim --write
```

## The chrome

- `client/chrome_common.js` is **byte-for-byte** the starter's
  (`Metta-AI/coworld-ctf`). Zero edits, ever. `tests/test_viewer.nim` pins its
  length and its structure. It reads `window.CTF_WIRE`, which
  `src/cabinet/wire_constants.nim` publishes as an ALIAS of
  `window.CABINET_WIRE` — that alias is the ONLY place the old name may appear.
- `client/replay_broadcast.html` is the starter's page **plus an appended game
  block** under the `ATARI-CABINET additions` banner. Everything above the
  banner is the starter's, edited only behind `CAB_MODE`. A page written from
  scratch that reuses the starter's ids is a rewrite and fails review.
- Every name the game block publishes is `cab`-prefixed, because the page's
  chrome alias block declares the shared helpers with a hoisted `var` and would
  silently swallow a colliding definition.
- `#viewpanel` (zoom + minimap), `#fpv` and `#povBadge` are REMOVED: the arena
  is fixed and always fits the frame, and the board is perfect-information.
- Every scrubber beat is a **labelled, clickable `<button>`** with CSS for
  every kind the sim emits.

## CI is the harness

The sandbox that authored this repo has no Docker, no emsdk and no browser.
`.github/workflows/ci.yml` runs every `tests/*.nim` twice (debug AND
`-d:release`), builds the image and plays a real raw-Docker episode
(`tools/ci/docker_smoke.sh`), then BUILDS AND EXECUTES the wasm bundle in
headless chromium against the replay that episode produced
(`tools/ci/viewer_smoke.mjs`), plus the worst-case text fixture
(`tools/ci/renderer_fixture.html`) at 360 / 620 / 1280 px.

Repo variables: `NIM_TESTS_RELEASE_ONLY` lists `tests/test_perf.nim` and
`tests/test_baselines.nim`.

Two files are load-bearing and must stay committed **executable**:
`tools/ci/docker_smoke.sh` and `tools/build_replay_viewer.sh` (`coworld build`
hard-requires `os.X_OK` on the latter). Set the bit with
`git update-index --chmod=+x <path>`.

## The manifest is GENERATED

`coworld_manifest_template.json` inlines this repo's own README and docs, so it
is generated and committed:

```bash
python3 tools/build_manifest.py          # regenerate
python3 tools/build_manifest.py --check  # fail if stale
```

Edit `tools/build_manifest.py` (or the docs it inlines), never the JSON. The
platform's own validator is the final word and can be run offline:

```bash
pip install 'coworld[auth]==0.1.42'
python3 - <<'PY'
import json
from coworld.bundle import _load_template_manifest
from coworld.manifest_validation import validate_coworld_manifest_game_configs
raw = json.load(open("coworld_manifest_template.json"))
m = _load_template_manifest(raw, "0.1.0",
    {"{{ATARI_CABINET_IMAGE}}": "coworld-atari-cabinet:0.1.0"})
validate_coworld_manifest_game_configs(m)
print("manifest OK")
PY
```

## Things that have already cost somebody a day

- **Truncate every recorded string on RUNE boundaries.** A byte-truncated
  multi-byte character renders in a browser and then fails a strict UTF-8
  parser. `stances.nim` is the only place strings are shortened.
- **One parallel LLM batch per turn.** The cabinet is a simultaneous-decision
  game; seats queried one after another blow the wall-clock budget.
  `decide.turnBatch` builds it and `tests/test_engine.nim` asserts every alive
  seat is in it.
- **`num_agents` in every variant AND the certification fixture**, or the
  ladder schedules zero episodes.
- **The secret namespace must equal `game.name`** exactly, and the game
  runnable's `env` must carry `ANTHROPIC_API_KEY_URI`, or every league episode
  plays scripted while local certify passes.
- **Bundled player `resources.limits.cpu` is `"1"`.** Anything lower is a 400
  at upload.
- **A replay shorter than the viewer smoke's soak reads as "frozen".** The cert
  fixture is 1440 ticks = 60 s of playback for exactly that reason; do not
  shrink it.
