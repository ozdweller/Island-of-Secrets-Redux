"""
Island of Secrets 2.0 -- intent parsing (Phase 2.0-C).

Stage 1 of the three-stage architecture in docs/ISLAND2_PLAN.md: free
text -> a structured Action (actions.py), via a local LLM through
Ollama. This module never touches GameState directly and never decides
whether an action is *possible* -- it only decides what the player
probably *meant*. rules.py (stage 2) is what validates and applies it;
this stage can be as wrong as it likes about feasibility and the rule
engine will just reject the result, exactly the same as if the player
had typed something impossible themselves.

Design, following the two 2.0-C open questions this settles (see
docs/ISLAND2_PLAN.md's "Open questions" and 2.0-A_RULE_SCHEMA.md §9):

- **Constrained JSON output**, not the Classic app's tolerant word-scan
  (see app/IslandOfSecrets/Sources/IslandOfSecrets/CommandTranslator.swift
  for that earlier approach). The old two-word code scheme picked one
  verb code and one noun code from short, exact-match lists -- a small
  closed vocabulary a word-scan parser could reliably catch even from a
  rambling reply. This schema has five fields, and `item`/`target` are
  deliberately open strings (see actions.py's own docstring: "rules.py
  resolves them against the live GameState"), so there's no fixed list
  to scan for. What *is* worth constraining hard is `type` (must be a
  real ActionType) and `direction` (must be N/S/E/W or null) -- both
  small closed sets where a malformed value is pure noise, never a
  legitimate creative answer. Ollama's `format` field accepts a JSON
  Schema for exactly this: strict enums for the two fields that need
  them, open strings for the two that don't.
- `item`/`target` are NOT resolved or validated here. rules.py's
  `_resolve_item` already does case-insensitive substring matching
  against carried + current-room items, and several handlers already do
  their own loose substring checks on `target` (e.g. `"column" in
  target`). Re-implementing that matching here would duplicate rules.py
  and could disagree with it. This stage's only job is extracting the
  player's likely intent as a short noun phrase; the context below just
  helps the model *guess a good one*, it doesn't have to guess exactly
  the string rules.py wants.
- The actual network call sits behind the small `OllamaClient` protocol
  below so the parsing/prompt logic is unit-testable without a live
  model (this sandbox can't reach Ollama at all -- see spike_intent.py
  for the live test harness meant to run on the author's own machine).
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Protocol

from actions import Action, ActionType
from models import GameState
from rules import RuleEngine

VALID_DIRECTIONS = ["N", "S", "E", "W"]

# Short glosses for the system prompt -- not exhaustive rules.py
# semantics, just enough for the model to pick the right verb. These
# used to be dead code: built here but never actually rendered into
# SYSTEM_PROMPT below, so the model only ever saw the bare JSON-schema
# enum of type strings with no explanation of what any of them meant.
# Found via the author's live-spike of "talk to boatman" consistently
# parsing as SAY (which just falls through to "nothing happens") rather
# than TALK (which actually reaches rules.py's _handle_talk ->
# _board_boat) -- see _render_action_glosses()/SYSTEM_PROMPT below,
# which now actually include this table. TALK vs SAY's wording is
# sharpened accordingly, since that was the pair the model conflated.
#
# Each gloss's trailing "(also: ...)" list is drawn from the original
# 1983 BASIC listing's own 42-word verb vocabulary (data/vocab.json's
# 3-letter codes, spelled out in the Classic app's VocabData.swift --
# GET/TAK/PIC/CHO/CHI/BRE/FIG/STR/HIT/KIL/SWI/SCR/CAT/POL/REA/WAV and
# so on). That vocabulary was a *closed* word-scan list back then --
# type anything else and the parser flatly refused it. 2.0 doesn't
# word-scan at all (see this module's docstring), so none of these are
# hard requirements; they're here so the model recognizes an old-
# fashioned or terse phrasing ("polish the pebble", "chop the vine",
# "read the parchment") as confidently as a modern one, instead of
# only matching the single example verb each gloss used to lead with.
# The author's ask, in short: give the parser the *full* old command list
# as grounding, not just a narrower modern paraphrase of it, so a
# legitimate attempt is less likely to fall through to no_action.
_ACTION_GLOSSES = {
    ActionType.GO: "move in a direction (needs `direction`)",
    ActionType.TAKE: "pick up an item (also: get, grab, catch, pick up) (needs `item`)",
    ActionType.DROP: "put down a carried item (also: leave, put down) (needs `item`)",
    ActionType.GIVE: "hand a carried item to someone (also: offer, hand over) (needs `item` and `target`)",
    ActionType.EAT: "eat a carried food item (also: bite, taste) (needs `item`)",
    ActionType.DRINK: "drink a carried drink item (also: sip, swallow) (needs `item`)",
    ActionType.RIDE: "ride/board a creature or vehicle (also: climb into, get in, row) (needs `item` or `target`)",
    ActionType.OPEN: "open something (also: unlock, lift the lid of) (needs `target`)",
    ActionType.USE: (
        "use/strike/smash/break/chop/hit/tap/swing/light a carried item on "
        "something -- e.g. chop it with the axe, break it with the hammer, "
        "light it with the torch (also: hack, bash, cut) (needs `item`, "
        "often `target`)"
    ),
    ActionType.COMBINE: "use two items together (needs `item` and `target`)",
    ActionType.TALK: (
        "have a general conversation with a specific character, or address "
        "them without quoting exact words -- e.g. \"talk to the boatman\", "
        "\"speak with him\", \"greet the villager\", \"ask the sage for "
        "help\" -- use this (not `help`) when the player names or clearly "
        "implies who they're asking (needs `target`)"
    ),
    ActionType.ATTACK: (
        "attack/fight/strike/hit/swing at/chop at something with no "
        "specific carried item in mind -- if the player names an item to "
        "attack with, prefer `use` instead (also: kill, smash, punch) "
        "(needs `target`)"
    ),
    ActionType.SEARCH: "search the current room for hidden things (no fields needed)",
    ActionType.SAY: (
        "speak one specific, exact phrase or password aloud -- only use this "
        "when the player states or quotes the actual words to say (e.g. "
        "\"say 'stony words'\"), not just that they want to talk (needs "
        "`phrase`, sometimes `target`)"
    ),
    ActionType.TOUCH: "touch/tap/pet/wave at/scratch something (needs `target`)",
    ActionType.RUB: "rub or polish something (needs `target`)",
    ActionType.FILL: "fill a carried item with something here (needs `item`)",
    ActionType.EXAMINE: "look closely at, read, or inspect something (needs `target`)",
    ActionType.WAIT: "do nothing this turn (also: pause) (no fields needed)",
    ActionType.REST: "rest to recover strength (also: sleep) (no fields needed)",
    ActionType.INFO: "check inventory/status",
    ActionType.HELP: (
        "the player is asking the game itself what they can do, not asking "
        "a character for help within the story -- e.g. \"help\", \"what can "
        "I do\", \"list commands\", \"what are my options\", \"how do I "
        "play\" (no fields needed; use `talk` instead if the player is "
        "clearly addressing a specific character)"
    ),
    ActionType.SAVE: "save the game",
    ActionType.LOAD: "load the game",
    ActionType.QUIT: "give up the quest (also: give up, surrender)",
    ActionType.NO_ACTION: (
        "the player's input genuinely doesn't correspond to anything "
        "possible here -- reserve this for gibberish or requests wholly "
        "unrelated to the game, not just because the player's exact "
        "wording doesn't match a gloss above word-for-word"
    ),
}


def _render_action_glosses() -> str:
    """Renders _ACTION_GLOSSES as a plain-text list, one line per
    ActionType, in the enum's own declared order -- so SYSTEM_PROMPT
    can't silently drift out of sync with actions.py (a new ActionType
    with no gloss entry raises here immediately rather than shipping a
    prompt that's quietly missing an explanation)."""
    lines = []
    for action_type in ActionType:
        gloss = _ACTION_GLOSSES[action_type]  # KeyError if a type is missing its gloss -- deliberate
        lines.append(f'- "{action_type.value}": {gloss}')
    return "\n".join(lines)


_BASE_SYSTEM_PROMPT = """You are the intent parser for a text adventure game. \
Given the player's free-text input and a description of what's \
currently around them, decide which single action they most likely \
meant and respond with a JSON object matching the given schema.

Only choose "item" from things the player is carrying or that are \
visible in the room right now. Only choose "target" the same way, or \
a short word from the room's own description (e.g. a named feature \
like a door, column, or stone). Never invent an item that isn't listed. \
Use lowercase for "item", "target", and "phrase". "direction" must be \
exactly one of N, S, E, W (or null) -- never a compass word like \
"north".

This game accepts a wide range of everyday, old-fashioned, and terse \
phrasing for the same action -- the list below already includes the \
common synonyms for each one, but it isn't exhaustive, so don't require \
an exact keyword match. If the player's wording is a reasonable, \
good-faith paraphrase of one of the actions below, given what's actually \
here, choose that action type rather than falling back to "no_action". \
Reserve "no_action" for input that genuinely doesn't correspond to \
anything possible here -- gibberish, or a request wholly unrelated to \
the game -- not merely because the exact word the player used isn't \
one of the examples listed. Respond with ONLY the JSON object -- no \
explanation, no markdown, no extra text."""

SYSTEM_PROMPT = (
    _BASE_SYSTEM_PROMPT
    + "\n\nWhat each action type means and when to use it:\n"
    + _render_action_glosses()
)


def _action_schema() -> dict:
    return {
        "type": "object",
        "properties": {
            "type": {"type": "string", "enum": [t.value for t in ActionType]},
            "item": {"type": ["string", "null"]},
            "target": {"type": ["string", "null"]},
            "direction": {"type": ["string", "null"], "enum": VALID_DIRECTIONS + [None]},
            "phrase": {"type": ["string", "null"]},
        },
        "required": ["type"],
        "additionalProperties": False,
    }


class OllamaClient(Protocol):
    """Everything IntentParser needs from a model backend. Real
    implementation below talks to Ollama's HTTP API; tests supply a fake
    that returns canned JSON strings, so prompt-construction and
    response-parsing are fully covered without a live model."""

    def chat(
        self,
        *,
        model: str,
        system: str,
        user: str,
        format_schema: dict,
        temperature: float = 0.0,
        timeout: float = 20.0,
    ) -> str | None:
        """Returns the model's raw reply text (expected to be a JSON
        string matching format_schema), or None on any failure -- a
        network error, a timeout, a non-2xx response, or a response
        that isn't even parseable as the outer Ollama envelope. Never
        raises; IntentParser.parse() treats None as "couldn't parse
        this turn" and lets the caller decide what to do (e.g. ask the
        player to rephrase)."""
        ...


class HttpOllamaClient:
    """Talks to a local Ollama server's /api/chat endpoint. Uses only
    the standard library (no requests/httpx dependency) since this is
    meant to run inside the eventual SwiftUI shell's bundled Python,
    not a managed environment."""

    def __init__(self, base_url: str = "http://localhost:11434"):
        self.base_url = base_url.rstrip("/")

    def chat(
        self,
        *,
        model: str,
        system: str,
        user: str,
        format_schema: dict,
        temperature: float = 0.0,
        timeout: float = 20.0,
    ) -> str | None:
        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "format": format_schema,
            "options": {"temperature": temperature},
            "stream": False,
        }
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            self.base_url + "/api/chat",
            data=data,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = json.loads(resp.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError):
            return None
        message = body.get("message")
        if not isinstance(message, dict):
            return None
        content = message.get("content")
        return content if isinstance(content, str) else None


@dataclass
class IntentParser:
    engine: RuleEngine
    client: OllamaClient
    model: str

    def parse(self, player_input: str, state: GameState) -> Action | None:
        """Returns a best-guess Action, or None if the model couldn't be
        reached / didn't return valid JSON at all (distinct from the
        model successfully returning type="no_action", which comes back
        as a real Action the caller can narrate normally)."""
        user_prompt = self._build_context(state) + f'\n\nPlayer typed: "{player_input}"'
        raw = self.client.chat(
            model=self.model,
            system=SYSTEM_PROMPT,
            user=user_prompt,
            format_schema=_action_schema(),
            temperature=0.0,
            timeout=20.0,
        )
        if raw is None:
            return None
        return self._parse_response(raw)

    def _build_context(self, state: GameState) -> str:
        room = self.engine.rooms[state.room]
        exits = sorted(d for d, open_ in room.exits.items() if open_)

        visible_lines = [
            f"- {self.engine.items[iid].name}"
            for iid in self.engine.visible_items(state)
        ]
        inventory_lines = [f"- {self.engine.items[iid].name}" for iid in sorted(state.inventory)]

        lines = [
            f'You are in: "{room.description}"',
            f"Exits available: {', '.join(exits) if exits else 'none'}",
            "Things visible here:",
            *(visible_lines or ["- nothing in particular"]),
            "You are carrying:",
            *(inventory_lines or ["- nothing"]),
        ]
        return "\n".join(lines)

    def _parse_response(self, raw: str) -> Action | None:
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            return None
        if not isinstance(data, dict):
            return None

        type_str = data.get("type")
        try:
            action_type = ActionType(type_str)
        except (ValueError, TypeError):
            return None

        direction = data.get("direction")
        if direction is not None:
            direction = str(direction).strip().upper()[:1]
            if direction not in VALID_DIRECTIONS:
                direction = None

        def _clean_str(value) -> str | None:
            if not isinstance(value, str):
                return None
            value = value.strip()
            return value or None

        return Action(
            type=action_type,
            item=_clean_str(data.get("item")),
            target=_clean_str(data.get("target")),
            direction=direction,
            phrase=_clean_str(data.get("phrase")),
        )
