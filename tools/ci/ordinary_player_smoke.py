#!/usr/bin/env python3
"""Exercise ordinary scripted/prompt players on the same credential-free game."""

import argparse
import json
import math
import os
import socket
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--game", required=True)
parser.add_argument("--player", required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument(
    "--mode",
    choices=["mixed", "no-credentials", "disconnect", "numeric", "sidecar"],
    default="mixed",
)
parser.add_argument(
    "--capture",
    action="store_true",
    help="Verify the private canonical trajectory using the Coworld SDK",
)
args = parser.parse_args()
args.output = args.output.resolve()
args.output.mkdir(parents=True, exist_ok=False)
repo = Path(__file__).resolve().parents[2]
requests = []
receipts = []


class Provider(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    disable_nagle_algorithm = True

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append(body)
        if args.mode == "numeric":
            assert self.path == "/actions"
            assert body["seat"] in (0, 1)
            assert len(body["values"]) == 115
            assert all(math.isfinite(value) for value in body["values"])
            assert len(body["action_mask"]) == 406
            heads = [2, 0, 0, 60, 3, 51]
            offset = 0
            for choice, size in zip(heads, (5, 4, 5, 87, 49, 256), strict=True):
                assert body["action_mask"][offset + choice]
                offset += size
            reply = json.dumps({"actions": heads}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(reply)))
            self.end_headers()
            self.wfile.write(reply)
            return
        if args.mode == "sidecar":
            assert self.path == "/v1/messages"
            assert self.headers["X-Coworld-Player-Slot"] in ("0", "1")
            assert body["model"] == "fixture/model"
            assert "anthropic_version" not in body
            assert self.headers.get("x-api-key") is None
        action = {
            "stance": "camp",
            "target_ball": "any",
            "aim_at": "none",
            "post": 17,
            "lead_ticks": 3,
            "aggression": 0.2,
            "note": "stub-selected complete orders",
            "say": "player owns this",
        }
        failed = args.mode == "disconnect" and len(requests) > 2
        reply = json.dumps(
            {"error": "deliberate transport failure"}
            if failed
            else {"content": [{"type": "text", "text": json.dumps(action)}]}
        )
        call_id = str(uuid.uuid4())
        receipts.append({"call_id": call_id, "request": body, "response": reply})
        self.send_response(503 if failed else 200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply.encode())))
        self.send_header("X-Softmax-Llm-Call-Id", call_id)
        self.end_headers()
        self.wfile.write(reply.encode())

    def log_message(self, format, *arguments):
        pass


provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
thread = threading.Thread(target=provider.serve_forever, daemon=True)
thread.start()
with socket.socket() as reserved:
    reserved.bind(("127.0.0.1", 0))
    port = reserved.getsockname()[1]
config = {
    "seed": 7,
    "rom": "warlords",
    "num_agents": 4,
    "minPlayers": 4,
    "promptVariant": "mixed",
    "promptSeed": 4,
    "maxTicks": 240,
    "turnTicks": 24,
    "turnBudgetMs": 2000,
    "fastMode": True,
    "startWaitTicks": 1,
    "gameOverTicks": 1,
    "lobbyJoinTimeoutTicks": 240,
    "wallClockBudgetSeconds": 90,
    "players": [{"name": f"P{i + 1}"} for i in range(4)],
    "tokens": [f"token-{i}" for i in range(4)],
}
(args.output / "config.json").write_text(json.dumps(config))
base_env = {
    k: v
    for k, v in os.environ.items()
    if not k.startswith(
        ("ANTHROPIC_", "AWS_", "BEDROCK_", "PLAYER_", "COGAME_", "COWORLD_")
    )
}
game_env = dict(
    base_env,
    COGAME_CONFIG_URI=(args.output / "config.json").as_uri(),
    COGAME_RESULTS_URI=(args.output / "results.json").as_uri(),
    COGAME_SAVE_REPLAY_URI=(args.output / "replay.bin").as_uri(),
    COGAME_HOST="127.0.0.1",
    COGAME_PORT=str(port),
)
if args.capture:
    game_env.update(
        COGAME_SAVE_TRAJECTORY_URI=(args.output / "trajectory.jsonl").as_uri(),
        COWORLD_EPISODE_ID=f"local-cabinet-{args.mode}",
        COWORLD_GAME_VERSION="local-proof",
        COWORLD_SOURCE_REVISION=subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=repo, text=True
        ).strip(),
    )
processes = []
logs = []
started = time.monotonic()
try:
    game_log = (args.output / "game.log").open("w")
    logs.append(game_log)
    game = subprocess.Popen(
        [args.game], cwd=repo, env=game_env, stdout=game_log, stderr=subprocess.STDOUT
    )
    processes.append(game)
    for seat in range(4):
        log = (args.output / f"player-{seat}.log").open("w")
        logs.append(log)
        env = dict(
            base_env,
            COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{port}/player?slot={seat}&token=token-{seat}",
        )
        if seat < 2 and args.mode == "numeric":
            env["PLAYER_NUMERIC_URL"] = (
                f"http://127.0.0.1:{provider.server_port}/actions"
            )
        elif seat < 2:
            env["PLAYER_PROMPT"] = "Choose a complete stance from my private view."
            if args.mode == "sidecar":
                env["COWORLD_LLM_ENDPOINT"] = f"http://127.0.0.1:{provider.server_port}"
                env["COWORLD_LLM_MODEL"] = "fixture/model"
            elif args.mode != "no-credentials":
                env["AWS_ENDPOINT_URL_BEDROCK_RUNTIME"] = (
                    f"http://127.0.0.1:{provider.server_port}"
                )
                env["AWS_BEARER_TOKEN_BEDROCK"] = "local-stub-only"
        else:
            env["PLAYER_SCRIPTED"] = "bulwark" if seat == 2 else "spinner"
        processes.append(
            subprocess.Popen(
                [args.player], cwd=repo, env=env, stdout=log, stderr=subprocess.STDOUT
            )
        )
    if args.mode == "disconnect":
        deadline = time.monotonic() + 20
        while len(requests) < 3 and game.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        assert len(requests) >= 3, "no second-turn request before disconnect"
        processes[1].terminate()
    exits = [
        process.wait(timeout=max(1, 100 - (time.monotonic() - started)))
        for process in processes
    ]
    expected = [0, -15, 0, 0, 0] if args.mode == "disconnect" else [0] * 5
    assert exits == expected, exits
    results = json.loads((args.output / "results.json").read_text())
    assert results["reason"] == "complete", results
    assert results["policyKinds"] == (
        ["external", "external", "scripted", "scripted"]
        if args.mode == "numeric"
        else ["prompt", "prompt", "scripted", "scripted"]
    ), results
    assert sum(results["externalTurns"]) > 0, results
    if args.mode == "disconnect":
        assert results["fallbackTurns"][0] > 0, results
        assert results["fallbackTurns"][1] > 0, results
        assert sum(results["fallbackTurns"][2:]) == 0, results
    elif args.mode == "no-credentials":
        assert results["fallbackTurns"] == [10, 10, 0, 0], results
    else:
        assert sum(results["fallbackTurns"]) == 0, results
        assert results["externalTurns"] == [10] * 4, results
    summary = json.loads(
        subprocess.check_output(
            [
                "python3",
                str(repo / "tools/replay_summary.py"),
                str(args.output / "replay.bin"),
            ]
        )
    )
    selected = [
        stance
        for stance in summary["stances"]
        if stance["note"] == "stub-selected complete orders"
    ]
    if args.mode == "numeric":
        selected = [
            stance
            for stance in summary["stances"]
            if stance["seat"] in (0, 1)
            and stance["stance"] == "camp"
            and stance["post"] == 17.0
            and stance["lead_ticks"] == 3
            and stance["aggression"] == 0.2
        ]
        assert len(requests) == 20 and len(selected) == 20, (
            len(requests),
            len(selected),
        )
    elif args.mode in ("mixed", "sidecar"):
        assert len(requests) == 20 and len(selected) == 20, (
            len(requests),
            len(selected),
        )
        assert all(
            request["system"].startswith("You operate one of four arcade cabinets")
            for request in requests
        )
    elif args.mode == "no-credentials":
        assert len(requests) == 0 and len(selected) == 0
    assert "cabinet llm:" not in (args.output / "game.log").read_text()
    proof = {
        "mode": args.mode,
        "exit_codes": exits,
        "provider_calls": len(requests),
        "stub_selected_replay_orders": len(selected),
        "results": results,
        "replay_bytes": (args.output / "replay.bin").stat().st_size,
    }
    if args.capture:
        from coworld.decision_trajectory import complete_episodes, read_trajectory_jsonl

        episodes = list(
            complete_episodes(read_trajectory_jsonl(args.output / "trajectory.jsonl"))
        )
        assert len(episodes) == 1
        episode = episodes[0]
        model = [
            attempt
            for decision in episode.decisions
            for attempt in decision.attempts
            if attempt.origin == "model"
        ]
        assert len(model) == len(receipts), (len(model), len(receipts))
        by_id = {receipt["call_id"]: receipt for receipt in receipts}
        for attempt in model:
            receipt = by_id[str(attempt.platform_call_id)]
            assert (
                attempt.request == receipt["request"]
                and attempt.raw_response == receipt["response"]
            )
        assert not any(
            attempt.origin == "teacher"
            for decision in episode.decisions
            for attempt in decision.attempts
        )
        public = (args.output / "replay.bin").read_bytes()
        assert all(receipt["call_id"].encode() not in public for receipt in receipts)
        assert (args.output / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
        proof["private_decisions"] = len(episode.decisions)
        proof["private_model_attempts"] = len(model)
        proof["private_rejected_attempts"] = sum(
            not attempt.accepted for attempt in model
        )
    (args.output / "proof.json").write_text(json.dumps(proof, indent=2))
    (args.output / "provider_requests.json").write_text(json.dumps(requests, indent=2))
    print(json.dumps(proof))
finally:
    for process in processes:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
    for log in logs:
        log.close()
    provider.shutdown()
    provider.server_close()
    thread.join(timeout=5)
