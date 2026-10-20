# Train on Atari Cabinet

The bridge uses the real hosted seat view, stance parser, bulwark teacher,
autopilot, and simulator across `warlords`, `quadrapong`, and `foozpong`.
Every active seat chooses before each 120-tick turn. Seeded seat assignments
remain hidden; all four cabinets share the physical board.

```bash
nimby sync nimby.lock
nim c -d:release --parallelBuild:1 --path:src --out:/tmp/atari-cabinet-training-bridge \
  src/cabinet/training_bridge.nim
python3 tests/test_training_bridge.py
```

The default numeric mode preserves its prompt, teacher quantization, 115 values,
and six action heads of sizes 5, 4, 5, 87, 49, and 256. Append `--language`
after the ROM for text training with the full hosted rules and full stance.
Use a timestep limit for every reinforcement-learning run.

From a `Metta-AI/posttraining-research` checkout, use the public collector and
exporter to build a matched
teacher corpus. Run from a clean, committed game checkout and retain the private
trajectory alongside the exported examples:

```bash
uv run --package metta-posttraining python - <<'PYTHON'
from pathlib import Path
import subprocess

from metta_training.language.dataset import export_dataset
from metta_training.language.private_io import write_private
from metta_training.language.rollout import collect
from metta_training.prompt_selection import PromptSelection

game_repo = Path("/path/to/cogame-atari-cabinet")
assert not subprocess.check_output(
    ["git", "-C", str(game_repo), "status", "--porcelain"], text=True
).strip()
revision = subprocess.check_output(
    ["git", "-C", str(game_repo), "rev-parse", "HEAD"], text=True
).strip()
bridge = Path("/tmp/atari-cabinet-training-bridge")
output = Path("train_dir/atari-cabinet/warlords")
output.mkdir(parents=True, mode=0o700)
trajectories = []
for prompt_seed in range(5):
    trajectory = output / f"wording-{prompt_seed}.jsonl"
    episodes = collect(
        bridge, trajectory, [str(seed) for seed in range(16)], revision,
        game="atari-cabinet", action_schema_revision="atari-cabinet-stance-v1",
        teacher_policy="atari-cabinet-bulwark", players=4, max_decisions=700,
        bridge_command=[str(bridge), "warlords", "--language"],
        prompt_selection=PromptSelection(
            bank="atari-cabinet-rules-v2", variant="mixed", seed=prompt_seed
        ),
    )
    assert len(episodes) == 16 and all(episode.status == "completed" for episode in episodes)
    trajectories.append(trajectory)
combined = output / "trajectories.jsonl"
write_private(combined, "".join(path.read_text() for path in trajectories))
export_dataset(combined, output / "dataset")
PYTHON
```

For `quadrapong` or `foozpong`, change the bridge's ROM argument and output path.
The five collections cover every training wording for each of the 16 scenario
seeds. Export splitting depends only on the scenario seed, so related wordings
cannot cross splits. The scripted `bulwark` supplies labels; this does not
establish strong play. The text bridge preserves the full stance and private view.

## Rules wording

The explicit `--language` bridge uses the same full rules bank as hosted players.
It supplies full rules instead of the abbreviated numeric-bridge instructions. The numeric interface keeps its
existing prompt, 115 features, and six action heads (406 total choices).

Reset accepts `promptVariant` and `promptSeed`. Training variants are `canonical`,
`plain`, `numbered`, `questions`, and `reordered`. `mixed` requires a nonnegative
integer seed and selects one of those five by seed modulo five. Selection stays
fixed for the episode and consumes no simulation randomness. Hosted evaluation
also accepts `heldout-briefing` and `heldout-reference`; the bridge permits
these only with `split=validation`. Keep scenario seeds and prompt seeds independent.

Each text decision exposes `semantic_view.prompt_template`: bank `atari-cabinet-rules-v2`,
requested selection, resolved variant, prompt seed, and SHA-256 hashes of the exact
system and user messages. Metadata stays outside the model's observation text.
Role, visibility and control-loop explanations vary. Numerical rules, action
schema and scoring stay verbatim.
Keep the original private trajectory alongside exported examples: its source and
selection records are tied to the export through the manifest trajectory hash.

For a matched study, collect the same scenario seeds with all five training
wordings. Keep all versions of a scenario in the same train/validation split.
Evaluate fixed policies on paired canonical and held-out panels with identical
scenario seeds, seats, budgets and opponents. Report invalid actions, fallback,
incomplete episodes and scores. Scripted parity does not establish improved learning.

Local complete-game check, after building the bridge:

```bash
python tools/test_prompt_variants.py /tmp/atari-cabinet-training-bridge
```

The check covers all seven wordings and all three ROMs, verifies prompt hashes
and stable selection, and compares complete scripted outcomes. Existing ordinary
player, native, Docker and browser checks continue to cover runtime and replay.
