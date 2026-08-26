#!/usr/bin/env python3
"""Generate coworld_manifest_template.json.

The manifest INLINES the repo's own docs (`game.docs`) and its two protocol
documents (`game.protocols`), so a hand-maintained copy would drift from the
files it claims to be. It is generated here and COMMITTED: the release workflow
reads the committed file, and tests/test_manifest.nim asserts everything about
it that the platform validator checks plus everything the design note pins.

The image placeholder is derived from the COMPOSE SERVICE NAME, uppercased with
`-` -> `_`. `{{GAME_IMAGE}}` is not a thing (lantern 0.1.0): `coworld build`
matches placeholders against compose services.

Usage:  python3 tools/build_manifest.py [--check]
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "coworld_manifest_template.json"

SEATS = 4
SLUG = "atari-cabinet"
GAME_NAME = "atari-cabinet"
OWNER = "daveey"
DESCRIPTION = (
    "Four arcade cabinets ring a square CRT, each defending a gap in its own "
    "wall with a paddle that is also a gun; the last cabinet with lives "
    "standing wins, and the ROM rotates."
)


def compose_service() -> str:
    text = (ROOT / "compose.yaml").read_text()
    match = re.search(r"^services:\s*\n\s+([A-Za-z0-9_-]+):", text, re.M)
    if not match:
        raise SystemExit("compose.yaml has no service")
    return match.group(1)


def compose_image() -> str:
    text = (ROOT / "compose.yaml").read_text()
    match = re.search(r"^\s+image:\s*([^\s:]+):latest\s*$", text, re.M)
    if not match:
        raise SystemExit("compose.yaml has no image")
    return match.group(1)


def placeholder(service: str) -> str:
    return "{{" + service.upper().replace("-", "_") + "_IMAGE}}"


def text_value(body: str) -> dict:
    # game.docs.readme, every docs page and BOTH game.protocols entries must be
    # {"type":"text","value":…} objects, not bare strings (garble v0.1.0).
    return {"type": "text", "value": body}


def read(name: str) -> str:
    return (ROOT / name).read_text()


def int_prop(minimum, maximum, default=None, description=""):
    prop = {"type": "integer", "minimum": minimum, "maximum": maximum}
    if default is not None:
        prop["default"] = default
    if description:
        prop["description"] = description
    return prop


def config_schema() -> dict:
    # Every ARRAY property carries minItems/maxItems (tandem 0.1.0): the
    # certifier rejects an unbounded array outright.
    return {
        "type": "object",
        "additionalProperties": False,
        "required": ["tokens", "players"],
        "properties": {
            "tokens": {
                "type": "array", "minItems": 1, "maxItems": SEATS,
                "items": {"type": "string"},
                "description": "per-slot join tokens, one per seat",
            },
            "players": {
                "type": "array", "minItems": 1, "maxItems": SEATS,
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "required": ["name"],
                    "properties": {"name": {"type": "string"}},
                },
            },
            "slots": {
                "type": "array", "minItems": 0, "maxItems": SEATS,
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "properties": {
                        "alias": {"type": "string"},
                        "token": {"type": "string"},
                    },
                },
                "description": "cosmetic slot aliases; the alias a seat plays "
                               "under is perm-dealt at t = 0",
            },
            "closedRoster": {"type": "boolean", "default": False},
            "seed": {"type": "integer", "minimum": 0, "maximum": 2147483647},
            "num_agents": int_prop(1, SEATS, SEATS,
                                   "seats, and cabinets: always 4"),
            "minPlayers": int_prop(1, SEATS, SEATS),
            "maxTicks": int_prop(120, 20000, 2880,
                                 "a multiple of turnTicks"),
            "maxGames": int_prop(1, 4, 1),
            "turnTicks": int_prop(24, 600, 120,
                                  "the LLM decision cadence, in ticks"),
            "turnBudgetMs": int_prop(2000, 60000, 16000),
            "attempt1Ms": int_prop(1000, 30000, 9000),
            "retryMs": int_prop(1000, 30000, 5000),
            "turnSpacingMs": int_prop(0, 60000, 12000,
                                      "inter-batch wall floor: 4 requests per "
                                      "12 s keeps the episode under the "
                                      "sidecar's 30 rpm cap"),
            "wallClockBudgetSeconds": int_prop(30, 720, 660),
            "lobbyJoinTimeoutTicks": int_prop(0, 7200, 2880),
            "startWaitTicks": int_prop(0, 240, 24),
            "gameOverTicks": int_prop(0, 480, 48),
            "fastMode": {"type": "boolean", "default": True},
            "showPlayerLabels": {"type": "boolean", "default": False},
            "speed": int_prop(1, 16, 1),
            "model": {"type": "string"},
            "maxOutputTokens": int_prop(200, 4000, 900),
            "rom": {
                "type": "string",
                "enum": ["warlords", "quadrapong", "foozpong"],
                "default": "warlords",
            },
            "startingLives": int_prop(1, 12, 3),
            "ballCount": int_prop(1, 3, 2),
            "brickRows": int_prop(0, 3, 1),
            "catchEnabled": {"type": "boolean", "default": True},
            "farPaddle": {"type": "boolean", "default": False},
            "goalHalfCu": int_prop(8, 30, 18),
            "paddleHalfCu": int_prop(3, 12, 7),
            "farPaddleHalfCu": int_prop(3, 12, 5),
            "ballSpeed0Milli": int_prop(300, 900, 550),
            "ballSpeedStepMilli": int_prop(0, 120, 35),
            "ballSpeedMaxMilli": int_prop(500, 1600, 1300),
            "holdTicksMax": int_prop(0, 96, 48),
            "serveDelayTicks": int_prop(0, 120, 24),
        },
    }


def seat_array(item: dict) -> dict:
    return {"type": "array", "minItems": SEATS, "maxItems": SEATS,
            "items": item}


def results_schema() -> dict:
    number = {"type": "number"}
    integer = {"type": "integer"}
    return {
        "type": "object",
        "additionalProperties": False,
        "required": ["names", "scores", "win", "placements", "rom", "reason",
                     "endRule"],
        "properties": {
            "names": seat_array({"type": "string"}),
            "aliases": seat_array({"type": "string"}),
            "cabinets": seat_array(integer),
            "policyKinds": seat_array({"type": "string",
                                       "enum": ["llm", "scripted"]}),
            "scores": seat_array(number),
            "win": seat_array({"type": "boolean"}),
            "placements": seat_array({"type": "integer", "minimum": 1,
                                      "maximum": SEATS}),
            "rom": {"type": "string",
                    "enum": ["warlords", "quadrapong", "foozpong"]},
            "startingLives": integer,
            "livesLeft": seat_array(integer),
            "concedes": seat_array(integer),
            "knockouts": seat_array(integer),
            "chips": seat_array(integer),
            "saves": seat_array(integer),
            "catches": seat_array(integer),
            "bricksLeft": seat_array(integer),
            "llmTurns": seat_array(integer),
            "fallbackTurns": seat_array(integer),
            "finalTick": integer,
            "reason": {"type": "string",
                       "enum": ["complete", "deadline", "fault"]},
            "endRule": {"type": "string",
                        "enum": ["last_standing", "full_time", "wall_clock",
                                 "sim_fault", "host_error"]},
            "seed": integer,
        },
    }


VARIANTS = [
    {
        "id": "warlords",
        "name": "ROM 1 — Warlords (4 castles)",
        "description": "Four brick castles, two balls, catch-and-throw "
                       "enabled, three lives each. Last castle standing.",
        "rom": "warlords", "startingLives": 3, "ballCount": 2, "brickRows": 1,
        "catchEnabled": True, "farPaddle": False, "goalHalfCu": 18,
        "paddleHalfCu": 7, "ballSpeed0Milli": 550,
    },
    {
        "id": "quadrapong",
        "name": "ROM 2 — Quadrapong (four goals)",
        "description": "No bricks, no catching, wide mouths, a faster ball "
                       "and five lives. Pure four-way pong.",
        "rom": "quadrapong", "startingLives": 5, "ballCount": 2,
        "brickRows": 0, "catchEnabled": False, "farPaddle": False,
        "goalHalfCu": 22, "paddleHalfCu": 6, "ballSpeed0Milli": 650,
    },
    {
        "id": "foozpong",
        "name": "ROM 3 — Foozpong (two rows)",
        "description": "Every cabinet gets a second paddle row 34 units out, "
                       "like a foosball table. No bricks, three lives.",
        "rom": "foozpong", "startingLives": 3, "ballCount": 2, "brickRows": 0,
        "catchEnabled": False, "farPaddle": True, "goalHalfCu": 18,
        "paddleHalfCu": 6, "ballSpeed0Milli": 600,
    },
]

SLOT_ALIASES = [{"alias": "RED"}, {"alias": "BLUE"}, {"alias": "GREEN"},
                {"alias": "YELLOW"}]


def variant_game_config(variant: dict) -> dict:
    # A variant changes ONLY the ROM preset — never the seat count, never the
    # clock, never the decision cadence, never the wall-clock budget. That is
    # what makes one budget arithmetic and one score scale correct for all
    # three.
    return {
        "players": [{"name": "P%d" % (i + 1)} for i in range(SEATS)],
        "slots": list(SLOT_ALIASES),
        "num_agents": SEATS,
        "minPlayers": SEATS,
        "rom": variant["rom"],
        "startingLives": variant["startingLives"],
        "ballCount": variant["ballCount"],
        "brickRows": variant["brickRows"],
        "catchEnabled": variant["catchEnabled"],
        "farPaddle": variant["farPaddle"],
        "goalHalfCu": variant["goalHalfCu"],
        "paddleHalfCu": variant["paddleHalfCu"],
        "ballSpeed0Milli": variant["ballSpeed0Milli"],
        "maxTicks": 2880,
        "maxGames": 1,
        "turnTicks": 120,
        "turnBudgetMs": 16000,
        "attempt1Ms": 9000,
        "retryMs": 5000,
        "turnSpacingMs": 12000,
        "wallClockBudgetSeconds": 660,
        "lobbyJoinTimeoutTicks": 2880,
        "fastMode": True,
    }


def build() -> dict:
    service = compose_service()
    image = placeholder(service)
    source_url = "https://github.com/Metta-AI/cogame-%s/tree/main" % SLUG
    player_resources = {
        # The bundled-player limits.cpu minimum is "1"; anything lower is a 400
        # at upload (pistonball 0.1.1).
        "requests": {"cpu": "100m", "memory": "64Mi"},
        "limits": {"cpu": "1"},
    }
    manifest = {
        "$schema": "https://softmax.com/schemas/coworld-manifest.json",
        "episode_timeout_minutes": 20,
        "tags": ["retro", "arcade", "free-for-all", "real-time", "llm"],
        "game": {
            "name": GAME_NAME,
            "description": DESCRIPTION,
            "owner": OWNER,
            "runnable": {
                "type": "game",
                "image": image,
                "run": ["/bin/atari-cabinet"],
                "env": {
                    # Without this the hosted container never receives the
                    # secret and every league episode plays scripted while
                    # local certify still passes (hive, 2026-08-23). The
                    # namespace must equal game.name exactly
                    # (cooperative-hunting, 2026-08-25).
                    "ANTHROPIC_API_KEY_URI":
                        "secret://coworld/%s/anthropic_api_key" % GAME_NAME
                },
                "source_url": source_url,
            },
            # Nested under `game`, not top-level; no top-level version and no
            # game.display_name (collab-cooking, 2026-08-25).
            "replay_viewer": {"bundle": "static-replay-viewer"},
            "config_schema": config_schema(),
            "results_schema": results_schema(),
            "protocols": {
                "player": text_value(read("docs/PROTOCOL.md")),
                "global": text_value(
                    read("docs/PROTOCOL.md") + "\n\n---\n\n" +
                    read("docs/RULES.md")),
            },
            "docs": {
                "readme": text_value(read("README.md")),
                "pages": [
                    {"id": "rules.md", "title": "Rules",
                     "content": text_value(read("docs/RULES.md"))},
                    {"id": "protocol.md", "title": "Wire protocol",
                     "content": text_value(read("docs/PROTOCOL.md"))},
                    {"id": "stances.md", "title": "Writing a cabinet stance",
                     "content": text_value(read("docs/STANCES.md"))},
                ],
            },
        },
        "player": [
            {
                "id": "baseline",
                "type": "player",
                "name": "Cabinet Bulwark Baseline",
                "description": "Scripted arcade paddle: intercept the soonest "
                               "ball, aim returns at the weakest rival, camp "
                               "the middle when nothing is inbound. No LLM.",
                "image": image,
                "run": ["/bin/atari-cabinet-player"],
                "env": {"PLAYER_SCRIPTED": "bulwark"},
                "source_url": source_url,
                "resources": player_resources,
            }
        ],
        # A variant carries EXACTLY id / name / description / game_config: the
        # 0.1.42 CoworldVariant model is additionalProperties:false, so
        # `num_agents` rides inside game_config (where the config_schema
        # validates it) and nowhere else.
        "variants": [
            {
                "id": variant["id"],
                "name": variant["name"],
                "description": variant["description"],
                "game_config": variant_game_config(variant),
            }
            for variant in VARIANTS
        ],
        "certification": {
            # Every declared player entry must occupy at least one slot or cert
            # fails players_missing (raid 0.1.2 -> 0.1.3).
            "players": [{"player_id": "baseline"} for _ in range(SEATS)],
            "game_config": {
                "players": [{"name": "P%d" % (i + 1)} for i in range(SEATS)],
                "slots": list(SLOT_ALIASES),
                "num_agents": SEATS,
                "minPlayers": SEATS,
                "seed": 5140913,
                "rom": "warlords",
                # startingLives 9 overrides the warlords preset's 3 PRECISELY
                # so the fixture cannot end early and the replay length is
                # deterministic — and it exercises the
                # defaults -> preset -> explicit order tests/test_rom.nim pins.
                "startingLives": 9,
                "maxTicks": 1440,
                "maxGames": 1,
                "turnTicks": 120,
                "turnBudgetMs": 16000,
                "turnSpacingMs": 0,
                "wallClockBudgetSeconds": 180,
                "lobbyJoinTimeoutTicks": 720,
                "fastMode": True,
            },
        },
    }
    assert compose_image() == "coworld-" + SLUG, compose_image()
    return manifest


def main() -> int:
    manifest = build()
    body = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    if "--check" in sys.argv:
        if not OUT.exists() or OUT.read_text() != body:
            print("coworld_manifest_template.json is stale: re-run "
                  "python3 tools/build_manifest.py", file=sys.stderr)
            return 1
        print("coworld_manifest_template.json is up to date")
        return 0
    OUT.write_text(body)
    print("wrote %s (%d bytes)" % (OUT.name, len(body)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
