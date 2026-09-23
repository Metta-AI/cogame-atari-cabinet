# Train on Atari Cabinet

The headless bridge uses the hosted seat view, stance parser, `bulwark`
baseline, autopilot, and simulator. Every active seat chooses a stance before
the next 120-tick turn. Seat-to-cabinet assignments follow the seeded game
permutation and stay hidden from the player view. The bridge supports the
`warlords`, `quadrapong`, and `foozpong` ROMs.

Build and test from this repository root:

```bash
nimby sync nimby.lock
nim c -d:release --path:src --out:/tmp/atari-cabinet-training-bridge \
  src/cabinet/training_bridge.nim
python3 tests/test_training_bridge.py
```

From a Metta checkout containing the generic Coworld bridge, collect and
export seed-separated teacher trajectories:

```bash
uv run --package metta-posttrain metta-posttrain collect-teacher \
  --bridge /tmp/atari-cabinet-training-bridge \
  --bridge-command /tmp/atari-cabinet-training-bridge \
  --output train_dir/atari-cabinet/warlords.jsonl \
  --source-revision "$(git -C /path/to/cogame-atari-cabinet rev-parse HEAD)" \
  --episodes 16 --max-decisions 128 --players 4 \
  --game atari-cabinet --action-schema-revision cabinet-stance-v1 \
  --teacher-policy cabinet-bulwark
uv run --package metta-posttrain metta-posttrain export \
  --trajectory train_dir/atari-cabinet/warlords.jsonl \
  --output train_dir/atari-cabinet/warlords-dataset
```

For `quadrapong` or `foozpong`, pass the ROM as a second `--bridge-command`
argument and use separate trajectory and dataset paths. The scripted
`bulwark` teacher supplies protocol-valid labels; these labels do not prove
strong play. PufferLib and Metta RL need a fixed numeric observation codec
before their current generic bridge can train this game.
