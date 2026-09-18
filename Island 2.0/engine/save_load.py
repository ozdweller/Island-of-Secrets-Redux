"""
Island of Secrets 2.0 -- save/load (Phase 2.0-E).

rules.py's SAVE/LOAD action handlers are deliberately no-ops (see
`_handle_save`/`_handle_load`'s own comments) -- the rule engine is a
pure state machine, not an I/O layer, same separation of concerns as
`narration.py` never touching `GameState` and `intent.py` never
deciding whether an action is possible. This module is what actually
persists a `GameState` to disk and reconstructs one from it, for
`shell.py` (and, later, a SwiftUI shell reusing the same functions) to
call.

`GameState` isn't directly JSON-serializable as-is: two fields are
sets (`inventory`, `given_away`), and two are dicts with integer keys
(`item_room`, `item_hidden`) -- JSON object keys are always strings,
so a naive round trip through `json.dumps`/`json.loads` would silently
turn those into string keys and (for the sets) lists that don't
compare equal to the originals. `serialize()`/`deserialize()` below
convert deliberately in both directions, so `save_game()`/`load_game()`
round-trip a `GameState` exactly -- see `tests/test_save_load.py`.
"""

from __future__ import annotations

import json

from models import GameState


def serialize(state: GameState) -> dict:
    """GameState -> a plain, JSON-safe dict. Every field is listed
    explicitly (rather than looping over __dict__) so a future field
    added to GameState without updating this function fails loudly in
    tests/test_save_load.py's round-trip check, instead of silently
    being dropped from every save file."""
    return {
        "room": state.room,
        "turn": state.turn,
        "time_remaining": state.time_remaining,
        "strength": state.strength,
        "wisdom": state.wisdom,
        "inventory": sorted(state.inventory),
        "item_room": {str(k): v for k, v in state.item_room.items()},
        "item_hidden": {str(k): v for k, v in state.item_hidden.items()},
        "given_away": sorted(state.given_away),
        "jug_filled_with_liquor": state.jug_filled_with_liquor,
        "flags": dict(state.flags),
        "counters": dict(state.counters),
        "game_over": state.game_over,
        "ending": state.ending,
    }


def deserialize(data: dict) -> GameState:
    """The inverse of serialize() -- reconstructs a real GameState,
    converting item_room/item_hidden's string keys back to the item
    ids they actually are, and inventory/given_away back to sets."""
    return GameState(
        room=data["room"],
        turn=data["turn"],
        time_remaining=data["time_remaining"],
        strength=data["strength"],
        wisdom=data["wisdom"],
        inventory=set(data["inventory"]),
        item_room={int(k): v for k, v in data["item_room"].items()},
        item_hidden={int(k): v for k, v in data["item_hidden"].items()},
        given_away=set(data["given_away"]),
        jug_filled_with_liquor=data["jug_filled_with_liquor"],
        flags=dict(data["flags"]),
        counters=dict(data["counters"]),
        game_over=data["game_over"],
        ending=data["ending"],
    )


def save_game(state: GameState, path: str) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(serialize(state), f, indent=2, sort_keys=True)


def load_game(path: str) -> GameState:
    with open(path, encoding="utf-8") as f:
        return deserialize(json.load(f))
