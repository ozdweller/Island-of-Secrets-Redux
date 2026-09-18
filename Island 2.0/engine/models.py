"""
Island of Secrets 2.0 -- core data models (Phase 2.0-B).

Deliberately small and dependency-free: this module holds the shapes of
the world, not the rules. See rules.py for the deterministic rule
engine that actually decides what a turn does, and
docs/2.0-A_RULE_SCHEMA.md for the design this implements.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum


class ItemCategory(str, Enum):
    GENERAL = "object"  # matches data/items.json's own category string
    FOOD = "food"
    DRINK = "drink"
    SCENERY_OR_CHARACTER = "scenery_or_character"


@dataclass(frozen=True)
class Room:
    id: int
    description: str
    exits: dict  # {"N": bool, "S": bool, "E": bool, "W": bool}


@dataclass(frozen=True)
class Item:
    id: int
    name: str
    category: ItemCategory


# Room-id deltas on the original's conceptual 10-wide grid (N=-10, S=+10,
# E=+1, W=-1) -- reused directly, this is just the room graph, not game
# logic. See docs/semantics.md for the original source of this scheme.
DIRECTION_DELTA = {"N": -10, "S": 10, "E": 1, "W": -1}


@dataclass
class GameState:
    """Everything that can change over the course of a playthrough.

    All world *content* (room text, item names, exits) lives in the
    read-only Room/Item tables loaded from the shared data/ folder.
    GameState only carries what's mutable: where things and the player
    are, what's been picked up, and the flag set from
    docs/2.0-A_RULE_SCHEMA.md.
    """

    room: int = 23  # "A Leafy Path" -- the original's hardcoded start
    turn: int = 0

    # Resources (kept per the 2.0-A scope decision)
    time_remaining: int = 1000
    strength: float = 100.0
    wisdom: float = 25.0

    # Inventory: item ids the player is currently carrying. 2.0 is not a
    # literal port -- food/drink are tracked as discrete carried items
    # consumed on eat()/drink(), rather than the original's abstract
    # F/G unit counters. Documented deliberate simplification.
    inventory: set = field(default_factory=set)

    # Where every non-carried item currently sits: item_id -> room_id,
    # or None if it has been consumed/given away/otherwise removed from
    # the physical world. Initialized from INITIAL_ITEM_LOCATIONS below.
    item_room: dict = field(default_factory=dict)

    # Items that exist in their room but are not yet found by casual
    # looking -- a search()/examine() of the room is needed first, same
    # spirit as the original's F(I)>=1 "hidden" state.
    item_hidden: dict = field(default_factory=dict)

    # Items that have been handed to a character and are gone from both
    # the player's inventory and the physical world -- same spirit as
    # the original's L(item)=81 "given/accepted" sentinel, tracked
    # separately from `item_room` (which uses None for "consumed" more
    # generally, e.g. eaten food).
    given_away: set = field(default_factory=set)

    # Whether the jug has been filled at the Logmen's still (room 41,
    # FILL JUG -- confirmed-code: listing.bas sets F(4)=-1 on the jug
    # itself, distinct from the abstract drink counter). Needed because
    # the Swampman only accepts a jug in this specific state, not any
    # generic carried drink -- see rules.py's _give_to_swampman.
    jug_filled_with_liquor: bool = False

    # Flags -- see docs/2.0-A_RULE_SCHEMA.md section 3 for the full
    # documented list and evidence for each.
    flags: dict = field(default_factory=dict)

    # Free-running counters not important enough to be named "flags"
    # but still worth keeping: how many turns the storm has been active,
    # etc.
    counters: dict = field(default_factory=dict)

    game_over: bool = False
    ending: str | None = None  # "won" | "time_out" | "collapsed" |
    # "enslaved_by_boatman" | "claimed_by_omegan" | "drowned" | None

    def is_carrying(self, item_id: int) -> bool:
        return item_id in self.inventory

    def item_location(self, item_id: int) -> int | None:
        return self.item_room.get(item_id)
