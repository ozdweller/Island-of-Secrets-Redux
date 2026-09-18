"""
Island of Secrets 2.0 -- line-delimited JSON IPC for the full stack
(Phase 2.0-E, stage 2: the SwiftUI shell's backend).

Where `shell.py` is a terminal REPL around `Shell.take_turn()`, this
module is a subprocess-friendly wrapper around the exact same
`Shell.take_turn()` -- same intent-parsing/rule-engine/narration
wiring, same meta-command aliases, same denial/no-action/unreachable-
model fallbacks (see `shell.py`'s module docstring for all of that;
this file adds no new gameplay behavior of its own). The only thing
this module does that `shell.py` doesn't is speak the Classic app's
`io_ipc.py` protocol shape on stdin/stdout instead of a human-facing
REPL, so `GameEngine.swift`'s existing process-management pattern
(spawn, pipe stdin, line-buffer stdout, decode JSON, dispatch to
`@Published` properties on the main thread) carries over with minimal
changes for a new SwiftUI shell to use -- see `docs/ISLAND2_PLAN.md`'s
"Reused engineering patterns" and `Island 2.0/app/`'s `GameEngine2.swift`.

Protocol (one JSON object per line, deliberately close to but not
identical to `engine/io_ipc.py`'s -- 2.0 is not a port, and this
protocol has no BASIC engine underneath it to stay compatible with):

  Engine -> UI, one per turn (including the very first line, emitted
  at startup before any input, so the UI has something to show
  immediately):
    {"type": "turn", "text": "<narrated prose or a fallback/meta
     message for this turn>", "room": <int>, "room_description":
     "<canonical text>", "time": <int>, "strength": <float>,
     "wisdom": <float>, "inventory": [<item id>, ...],
     "room_objects": [<item/character id currently in this room,
     hidden or not>, ...], "game_over": <bool>, "ending": <string or
     null>}

  Engine -> UI, only if the engine can't even start (bad --model,
  missing data files, etc.):
    {"type": "error", "message": "..."}

  UI -> Engine, one per line on stdin:
    {"cmd": "take the rope"}
  (a bare plain-text line with no JSON is also accepted, same as
  `io_ipc.py`, for quick manual testing with `nc`/`echo`)
"""

from __future__ import annotations

import argparse
import json
import sys

from data_loader import load_characters, load_items, load_lore, load_rooms
from intent import HttpOllamaClient, IntentParser
from narration import Narrator
from rules import RuleEngine, new_game
from shell import Shell, DEFAULT_SAVE_PATH


def turn_payload(shell: Shell, state, text: str) -> dict:
    """One `GameState` + this turn's already-decided display text ->
    the JSON object described in this module's docstring. `room_objects`
    intentionally includes hidden items/characters too (matches
    `io_ipc.py`'s own `room_objects`, which reads straight off the
    original's L() array with no hidden-flag filtering) -- unlike
    `shell.py`'s player-facing `describe_status()`, this field feeds a
    future lore-codex-style UI concept where "has the player *reached*
    this character's room yet" matters even before they've spotted
    them, same as the Classic app's Phase 7.1 addition to `io_ipc.py`."""
    room = shell.engine.rooms[state.room]
    room_objects = [iid for iid, loc in state.item_room.items() if loc == state.room]
    return {
        "type": "turn",
        "text": text,
        "room": state.room,
        "room_description": room.description,
        "time": state.time_remaining,
        "strength": round(state.strength, 1),
        "wisdom": round(state.wisdom, 1),
        "inventory": sorted(state.inventory),
        "room_objects": sorted(room_objects),
        "game_over": state.game_over,
        "ending": state.ending,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True, help="Ollama model used for both intent parsing and narration")
    ap.add_argument("--intent-model", default=None, help="override the model used for intent parsing")
    ap.add_argument("--narration-model", default=None, help="override the model used for narration")
    ap.add_argument("--base-url", default="http://localhost:11434")
    ap.add_argument("--save-path", default=DEFAULT_SAVE_PATH)
    args = ap.parse_args()

    try:
        rooms = load_rooms()
        items = load_items()
        characters = load_characters()
        lore = load_lore()
        engine = RuleEngine(rooms, items)
        client = HttpOllamaClient(base_url=args.base_url)
        parser = IntentParser(engine=engine, client=client, model=args.intent_model or args.model)
        narrator = Narrator(client=client, model=args.narration_model or args.model)
        shell = Shell(engine, parser, narrator, characters, lore)
        state = new_game()
    except Exception as e:  # noqa: BLE001 -- startup failure of any kind must reach the UI, not a silent exit
        sys.stdout.write(json.dumps({"type": "error", "message": str(e)}) + "\n")
        sys.stdout.flush()
        return

    intro_text = shell._narrate_or_fallback(state, [])
    sys.stdout.write(json.dumps(turn_payload(shell, state, intro_text)) + "\n")
    sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        text = line
        try:
            obj = json.loads(line)
            if isinstance(obj, dict) and "cmd" in obj:
                text = str(obj["cmd"])
        except (json.JSONDecodeError, TypeError):
            pass  # a bare plain-text line -- treated as the command verbatim, same as io_ipc.py

        if not text.strip():
            continue

        display_text, state = shell.take_turn(state, text, save_path=args.save_path)
        sys.stdout.write(json.dumps(turn_payload(shell, state, display_text)) + "\n")
        sys.stdout.flush()

        if state.game_over:
            break


if __name__ == "__main__":
    main()
