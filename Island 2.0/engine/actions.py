"""
The structured action schema an LLM's intent-parsing stage (2.0-C, not
built yet) resolves free text into. See docs/2.0-A_RULE_SCHEMA.md
section 4. rules.py never sees free text -- only these.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class ActionType(str, Enum):
    GO = "go"
    TAKE = "take"
    DROP = "drop"
    GIVE = "give"
    EAT = "eat"
    DRINK = "drink"
    RIDE = "ride"
    OPEN = "open"
    USE = "use"
    COMBINE = "combine"
    TALK = "talk"
    ATTACK = "attack"
    SEARCH = "search"
    SAY = "say"
    TOUCH = "touch"
    RUB = "rub"
    FILL = "fill"
    EXAMINE = "examine"
    WAIT = "wait"
    REST = "rest"
    INFO = "info"
    HELP = "help"
    SAVE = "save"
    LOAD = "load"
    QUIT = "quit"
    NO_ACTION = "no_action"


@dataclass(frozen=True)
class Action:
    type: ActionType
    # Free-form parameters, deliberately loose (a string item/target name
    # or an id -- rules.py resolves them against the live GameState). Not
    # every field is used by every action type.
    item: str | int | None = None
    target: str | int | None = None
    direction: str | None = None
    phrase: str | None = None
