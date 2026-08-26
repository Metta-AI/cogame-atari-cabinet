#!/usr/bin/env python3
"""Summarise a `COWLDCAB` replay as one strict-UTF-8 JSON object.

Python 3 standard library ONLY — no Nim, no Docker, no browser. This is the
forensic view of a hosted episode: given the bytes a spectator can download
from S3, it prints who played, which ROM ran, what every seat's stance was on
every turn, how many turns fell back, and the results document the game wrote.

    python3 tools/replay_summary.py /tmp/episode.replay | jq .

The phase-60 substitute for SPEC §Definition of done check 4:

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null                       # strict UTF-8 JSON
    jq -r '.protocol, .rom, .results.reason, .results.endRule' /tmp/ep.json
    jq -r '[.stances[]|select(.source=="llm")]|length, .fallbacks' /tmp/ep.json
    jq -r '[.stances[]|select(.source=="llm")|.aim_at]|unique' /tmp/ep.json

Require `protocol == "atari-cabinet/v1"`, `results.reason == "complete"` (or
the declared-acceptable `deadline`), `results.saves` summing above 0, and the
champion seats' stances `source == "llm"` with VARYING stance / aim_at values —
not all fallbacks, and not a constant stance.
"""

from __future__ import annotations

import json
import sys
import zlib

MAGIC = b"COWLDCAB"
PROTOCOL = "atari-cabinet/v1"

HASH_RECORD = 0x01
INPUT_RECORD = 0x02
JOIN_RECORD = 0x03
LEAVE_RECORD = 0x04
CHAT_RECORD = 0x05
DEBUG_SPRITE_RECORD = 0x06


class Reader:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.at = 0

    def take(self, count: int) -> bytes:
        if self.at + count > len(self.data):
            raise ValueError("replay is truncated at byte %d" % self.at)
        chunk = self.data[self.at:self.at + count]
        self.at += count
        return chunk

    def u8(self) -> int:
        return self.take(1)[0]

    def u16(self) -> int:
        return int.from_bytes(self.take(2), "little")

    def i16(self) -> int:
        return int.from_bytes(self.take(2), "little", signed=True)

    def u32(self) -> int:
        return int.from_bytes(self.take(4), "little")

    def u64(self) -> int:
        return int.from_bytes(self.take(8), "little")

    def text(self) -> str:
        length = self.u16()
        raw = self.take(length)
        # STRICT: a byte-truncated multi-byte character is a defect we want to
        # see, not paper over. Every recorded string is cut on a RUNE boundary
        # precisely so this never raises.
        return raw.decode("utf-8")

    def blob(self) -> bytes:
        return self.take(self.u32())

    def done(self) -> bool:
        return self.at >= len(self.data)


def payload(raw: bytes) -> bytes:
    if raw.startswith(MAGIC):
        return raw
    # hosted artifacts may arrive gzip/zlib compressed
    for wbits in (47, 15, -15):
        try:
            out = zlib.decompress(raw, wbits)
        except Exception:
            continue
        if out.startswith(MAGIC):
            return out
    raise ValueError("not a %s replay" % MAGIC.decode())


def brace_match(text: str, start: int) -> str:
    """The balanced {...} beginning at `start` — the technique the starter's
    AGENTS.md documents for prod forensics."""
    depth = 0
    in_string = False
    escaped = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    raise ValueError("unbalanced config JSON")


def summarise(raw: bytes) -> dict:
    reader = Reader(payload(raw))
    if reader.take(len(MAGIC)) != MAGIC:
        raise ValueError("bad magic")
    format_version = reader.u16()
    game_name = reader.text()
    game_version = reader.text()
    reader.u64()                      # recorded-at, milliseconds
    config_text = reader.text()
    config = json.loads(brace_match(config_text, config_text.index("{")))

    joins: list[dict] = []
    stances: list[dict] = []
    fallbacks: list[dict] = []
    registers: list[dict] = []
    guards: list[dict] = []
    results: dict = {}
    inputs = 0
    tick_count = 0
    command_changes: dict[int, int] = {}

    while not reader.done():
        kind = reader.u8()
        if kind == HASH_RECORD:
            tick = reader.u32()
            reader.u64()
            tick_count = max(tick_count, tick)
        elif kind == INPUT_RECORD:
            reader.u32()
            player = reader.u8()
            reader.u8()
            inputs += 1
            command_changes[player] = command_changes.get(player, 0) + 1
        elif kind == JOIN_RECORD:
            reader.u32()
            player = reader.u8()
            name = reader.text()
            slot = reader.i16()
            reader.text()             # token: never reported
            joins.append({"player": player, "name": name, "slot": slot})
        elif kind == LEAVE_RECORD:
            reader.u32()
            reader.u8()
        elif kind == CHAT_RECORD:
            reader.u32()
            reader.u8()
            message = reader.text()
            if not message.startswith("{"):
                continue
            try:
                record = json.loads(message)
            except ValueError:
                continue
            kindName = record.get("k")
            if kindName == "stance":
                stances.append(record)
            elif kindName == "fallback":
                fallbacks.append(record)
            elif kindName == "register":
                registers.append(record)
            elif kindName == "budget_guard":
                guards.append(record)
            elif kindName == "result":
                results = record.get("results", {})
        elif kind == DEBUG_SPRITE_RECORD:
            reader.u32()
            reader.u8()
            reader.blob()
        else:
            raise ValueError("unknown record type 0x%02x at byte %d"
                             % (kind, reader.at - 1))

    perm = config.get("perm") or []
    names = [join["name"] for join in sorted(joins, key=lambda j: j["slot"])]
    aliases = ["RED", "BLUE", "GREEN", "YELLOW"]
    return {
        "protocol": PROTOCOL,
        "formatVersion": format_version,
        "gameName": game_name,
        "gameVersion": game_version,
        "rom": config.get("rom"),
        "seed": config.get("seed"),
        "names": names,
        "aliases": [aliases[perm[i]] if i < len(perm) else None
                    for i in range(len(perm))],
        "cabinets": perm,
        "policyKinds": [r.get("kind") for r in
                        sorted(registers, key=lambda r: r.get("seat", 0))],
        "tickCount": tick_count,
        "inputRecords": inputs,
        "commandChangesBySeat": command_changes,
        "turns": len({s.get("turn") for s in stances}),
        "stances": [
            {
                "turn": s.get("turn"),
                "seat": s.get("seat"),
                "alias": s.get("alias"),
                "source": s.get("source"),
                "stance": s.get("stance"),
                "target_ball": s.get("target_ball"),
                "aim_at": s.get("aim_at"),
                "post": s.get("post"),
                "lead_ticks": s.get("lead_ticks"),
                "aggression": s.get("aggression"),
                "latency_ms": s.get("latency_ms"),
                "note": s.get("note"),
                "say": s.get("say"),
            }
            for s in stances
        ],
        "fallbacks": len(fallbacks),
        "fallbackCauses": sorted({f.get("cause") for f in fallbacks
                                  if f.get("cause")}),
        "budgetGuards": guards,
        "results": results,
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    with open(argv[1], "rb") as handle:
        raw = handle.read()
    document = summarise(raw)
    # ensure_ascii=False keeps the real UTF-8 bytes: the point of this tool is
    # that the replay's strings survive a STRICT parser end to end.
    sys.stdout.write(json.dumps(document, ensure_ascii=False, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
