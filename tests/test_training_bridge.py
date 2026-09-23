"""Exercise complete Atari Cabinet games through the JSONL training protocol."""

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def request(process: subprocess.Popen[str], command: dict) -> dict:
    assert process.stdin is not None and process.stdout is not None
    process.stdin.write(json.dumps(command) + "\n")
    process.stdin.flush()
    return json.loads(process.stdout.readline())


with tempfile.TemporaryDirectory() as directory:
    binary = Path(directory) / "atari-cabinet-training-bridge"
    subprocess.run(
        ["nim", "c", "--hints:off", "--path:src", f"--out:{binary}",
         "src/cabinet/training_bridge.nim"],
        cwd=ROOT,
        check=True,
    )
    for rom in ("warlords", "quadrapong", "foozpong"):
        for seed in ("7", "19"):
            with subprocess.Popen(
                [str(binary), rom], cwd=ROOT, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, text=True,
            ) as process:
                observation = request(process, {"kind": "reset", "seed": seed, "players": 4})
                decisions = 0
                while observation["kind"] == "decision":
                    assert 0 <= observation["seat"] < 4
                    assert observation["decision_id"] == decisions
                    visible = json.loads(observation["messages"][1]["content"])
                    assert visible["rom"] == rom
                    assert visible["you"]["alias"] in {"RED", "BLUE", "GREEN", "YELLOW"}
                    assert "seed" not in visible and "perm" not in visible
                    stale = request(process, {"kind": "step", "decision_id": -1,
                                              "response": "{}"})
                    assert stale["kind"] == "rejected"
                    invalid = request(process, {"kind": "step", "decision_id": decisions,
                                                "response": "not JSON"})
                    assert invalid["kind"] == "rejected"
                    teacher = request(process, {"kind": "teacher"})["response"]
                    assert json.loads(teacher)["stance"] in {"guard", "aim", "camp", "catch", "chase"}
                    result = request(process, {"kind": "step", "decision_id": decisions,
                                               "response": teacher})
                    assert result["kind"] == "accepted"
                    assert result["action"]["stance"] == json.loads(teacher)["stance"]
                    observation = result["observation"]
                    decisions += 1
                    assert decisions <= 96
                assert observation["kind"] == "terminal"
                assert set(observation["scores"]) == {"0", "1", "2", "3"}
                assert all(score >= 0 for score in observation["scores"].values())
            assert process.returncode == 0
            print(rom, seed, decisions, observation["scores"])
