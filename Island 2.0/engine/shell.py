"""
Island of Secrets 2.0 -- the terminal shell (Phase 2.0-E, stage 1).

Wires all three stages into one real, playable game loop: free text
-> a candidate action (2.0-C's `intent.py`) -> a validated state change
(2.0-B's `rules.py`) -> narrated prose (2.0-D's `narration.py`). This
is the first actually-playable form of 2.0. Per `docs/ISLAND2_PLAN.md`,
2.0-E's other half is a SwiftUI shell -- that can follow once this loop
is proven, most naturally by wrapping the same `Shell.take_turn()`
logic below behind `ipc.py`'s line-delimited JSON protocol instead of
a terminal REPL, the same way the Classic app's `GameEngine.swift`
drives `io_ipc.py` as a subprocess today.

Design decisions this module makes, on top of the three stages it
wires together:

- **Meta-commands (save/load/quit/inventory/help) bypass the LLM intent
  parser entirely** when typed as one of a small set of exact aliases
  (see `_META_ALIASES`) -- these need to always work, instantly, even
  if Ollama is slow or down, and none of them benefit from the free-
  text flexibility that in-fiction actions do. Anything not matching
  an alias still reaches the LLM normally, which can also legitimately
  return SAVE/LOAD/INFO/HELP/QUIT from a phrased request like "let's
  save here" or "what can I do?" -- both paths converge on the same
  `Action`-type handling, so there is exactly one save/load/info/help/
  quit implementation, not two.
- **HELP is a pure UI query, like INFO** -- a fixed, deterministic
  `HELP_TEXT` (never LLM-generated, never touching `rules.py`) telling
  the player they can phrase things freely, plus the recognized action
  categories and the meta commands. This is 2.0-C's actual answer to
  "how does a player learn the command list" now that there ISN'T a
  fixed word list the way the original BASIC engine had one (see
  intent.py's own module docstring on that design choice) -- the
  player needs a different kind of guidance than "here are the exact
  words", namely "here's the shape of what you can try, phrase it
  however feels natural."
- **`rules.py` deliberately never does file I/O** for SAVE/LOAD (see
  its `_handle_save`/`_handle_load` -- both no-ops by design, since the
  rule engine is a pure state machine, not an I/O layer). This module
  is what actually implements save/load, via `save_load.py`.
- **Not every turn calls the narrator.** Calling an LLM to re-describe
  an unchanged room after a flatly rejected action (e.g. "take the
  crown" when there's no crown here) burns latency for zero new
  information, and a genuinely unmappable input (NO_ACTION) deserves a
  distinct "I don't understand" response rather than blending into
  either bucket -- see `docs/2.0-A_RULE_SCHEMA.md`'s own note that
  this is exactly where a no_action response belongs. So:
    - the parser returns NO_ACTION -> a small fixed pool of "that
      doesn't seem to map to anything" lines, no LLM call.
    - the rule engine flatly rejects the action AND reports no facts
      at all (`ok=False, facts=[]` -- e.g. "you're not carrying that")
      -> a small fixed pool of neutral denial lines, no LLM call.
    - anything else (facts were produced, even on a mechanical
      "failure" like being blocked by the Swampman -- `blocked:*` in
      rules.py is `ok=False` but a real, narratable event; or `ok=True`
      with no facts, e.g. WAIT/EXAMINE -- a legitimate "nothing
      changed, describe the moment" beat) -> real LLM narration via
      `narration.py`, grounded only in the given facts, same
      never-invent discipline as every other stage in this project.
- **If the intent parser itself is unreachable** (Ollama down, not
  just declining to map the input), the player is told plainly rather
  than silently treated as NO_ACTION -- those are different failure
  modes and deserve different messages.
- **If the narrator is unreachable**, play is never blocked (same
  discipline as the Classic app's `NarrationService` leaving its panel
  empty rather than blocking gameplay) -- the plain room text plus the
  same translated facts narration.py would have handed the model are
  shown instead, as unstyled lines rather than prose.
- **Every narrated or fallback line is prefixed with a deterministic
  room-location header** (`_room_label()`, e.g. "[Room 33: A LOG PIER,
  JUTTING OUT OVER THE CREEK]") via `_narrate_or_fallback()`. narration.py
  deliberately never guarantees the model states the room by name in
  every reply -- that's the right call for prose (it's scene-setting,
  not a status line), but on its own it makes the map hard to track
  turn to turn, especially in the SwiftUI app's scrolling transcript.
  The header is read straight from `rooms.json`, the same text already
  given to the LLM as ground truth, so it can never contradict the
  narration and needs no LLM reliability. Because it lives in this one
  choke point, both the terminal shell and (via `shell_ipc.py`) the
  SwiftUI app get it automatically.
"""

from __future__ import annotations

import argparse
import random

from actions import Action, ActionType
from data_loader import load_characters, load_items, load_lore, load_rooms
from intent import HttpOllamaClient, IntentParser
from narration import Narrator, build_context, translate_facts
from rules import RuleEngine, new_game
from save_load import load_game, save_game

DEFAULT_SAVE_PATH = "island2_save.json"

# Exact-match aliases (lowercased, whitespace-stripped) that bypass the
# LLM intent parser entirely -- see the module docstring.
_META_ALIASES = {
    "quit": Action(type=ActionType.QUIT),
    "exit": Action(type=ActionType.QUIT),
    "save": Action(type=ActionType.SAVE),
    "load": Action(type=ActionType.LOAD),
    "inventory": Action(type=ActionType.INFO),
    "inv": Action(type=ActionType.INFO),
    "status": Action(type=ActionType.INFO),
    "i": Action(type=ActionType.INFO),
    "help": Action(type=ActionType.HELP),
    "commands": Action(type=ActionType.HELP),
    "options": Action(type=ActionType.HELP),
    "?": Action(type=ActionType.HELP),
}

# The HELP action's response -- plain, deterministic, never LLM-
# generated, same reasoning as describe_status() below. 2.0 has no
# fixed word list to print (see intent.py's module docstring: this is
# a free-text-to-JSON parser, not the Classic app's closed-vocabulary
# word-scan), so rather than a literal command list this explains the
# *shape* of what's possible -- the action categories intent.py's own
# _ACTION_GLOSSES recognizes, grouped the way a player thinks about
# them rather than intent.py's internal type names.
HELP_TEXT = """\
You don't need to type exact commands -- just say what you want to do \
in plain English, e.g. "pick up the rope", "give the jug to the \
villager", "go north", "ask the boatman for help".

Things you can generally try:
  - Move: go/walk in a direction (north, south, east, west)
  - Take, drop, or give items; eat or drink something; fill a container
  - Open something; use, strike, break, or light one item with another
  - Ride or board a creature or vehicle
  - Talk to a character, or say an exact phrase/password aloud
  - Touch, rub, or examine something closely
  - Attack something; search the room for hidden things
  - Wait or rest

Meta commands (these always work instantly, even if the language \
model is slow or down):
  - help / commands / ? -- show this message
  - inventory / inv / status / i -- show what you're carrying and your stats
  - save -- save your progress
  - load -- reload your last save
  - quit / exit -- give up the quest"""

# Shown instead of calling the narrator when the parser found no
# mapping at all -- distinct from _DENIAL_LINES below, which is for a
# real, understood attempt that the rule engine rejected.
_NO_ACTION_LINES = [
    "You're not sure what you mean by that.",
    "That doesn't seem to mean anything here.",
    "You can't work out how to do that.",
]

# Shown instead of calling the narrator when the rule engine flatly
# rejects an understood action with nothing to report.
_DENIAL_LINES = [
    "Nothing happens.",
    "That doesn't seem possible right now.",
    "It doesn't work.",
]

# Shown when the intent parser itself is unreachable -- a network/
# model problem, not the model declining to map the input.
_PARSER_UNREACHABLE_MESSAGE = (
    "(The language model isn't responding right now -- is Ollama running? "
    "Your last input wasn't understood; try again.)"
)

_NARRATOR_UNREACHABLE_NOTE = "(narration unavailable -- plain facts only)"


def describe_status(engine: RuleEngine, state) -> str:
    """The INFO action's response -- plain, deterministic, never
    LLM-generated, since this is a UI/meta query about game state, not
    in-fiction prose."""
    room = engine.rooms[state.room]
    visible = [engine.items[i].name for i in engine.visible_items(state)]
    carried = [engine.items[i].name for i in sorted(state.inventory)]
    lines = [
        f"Room {state.room}: {room.description}",
        "You see: " + (", ".join(visible) if visible else "nothing in particular"),
        "You are carrying: " + (", ".join(carried) if carried else "nothing"),
        f"Time remaining: {state.time_remaining}   "
        f"Strength: {int(state.strength)}   Wisdom: {int(state.wisdom)}",
    ]
    return "\n".join(lines)


def _room_label(engine: RuleEngine, state) -> str:
    """A deterministic, never-LLM-generated location header, e.g.
    "[Room 33: A LOG PIER, JUTTING OUT OVER THE CREEK]". narration.py's
    own hard rules deliberately never *guarantee* the model states the
    room in every reply (it's scene-setting prose, not a status line),
    which is right for prose quality but leaves the player with no
    reliable way to track position on the map. This closes that gap the
    same way `describe_status()` already does for the INFO command --
    reading straight from `rooms.json`'s own canonical `description`
    field (the exact text already handed to the LLM as ground truth),
    so it can never contradict the narration and needs no LLM
    reliability at all."""
    room = engine.rooms[state.room]
    return f"[Room {state.room}: {room.description}]"


def _plain_fallback_text(engine: RuleEngine, state, facts: list) -> str:
    """Used when the narrator is unreachable -- the same translated
    facts narration.py would have handed an LLM, just printed as plain
    lines instead of prose. Doesn't repeat the room description itself
    (`_narrate_or_fallback()` already prepends `_room_label()`, which
    contains that same text) -- just the facts."""
    return "\n".join(translate_facts(engine, facts))


class Shell:
    """Holds the wiring (engine/parser/narrator/data) for one running
    game. `take_turn()` is the entry point for a single piece of
    player input, kept free of real stdin/stdout so it's testable
    against a fake Ollama client the same way test_intent.py and
    test_narration.py test their own modules -- `main()`'s loop below
    is the only part that actually touches a terminal."""

    def __init__(self, engine, parser, narrator, characters, lore, rng=None):
        self.engine = engine
        self.parser = parser
        self.narrator = narrator
        self.characters = characters
        self.lore = lore
        self.rng = rng or random.Random()
        self.transcript: list = []

    def take_turn(self, state, text: str, save_path: str = DEFAULT_SAVE_PATH):
        """Returns `(display_text, new_state)`. `new_state` is `state`
        itself (mutated in place) for every action except a successful
        LOAD, which returns a freshly reconstructed GameState the
        caller must start using instead of the old one."""
        key = text.strip().lower()
        action = _META_ALIASES.get(key)
        if action is None:
            action = self.parser.parse(text, state)
            if action is None:
                return _PARSER_UNREACHABLE_MESSAGE, state

        if action.type == ActionType.SAVE:
            save_game(state, save_path)
            return f"(game saved to {save_path})", state

        if action.type == ActionType.LOAD:
            try:
                loaded = load_game(save_path)
            except (OSError, ValueError, KeyError):
                return f"(no save found at {save_path})", state
            self.transcript = []  # a fresh scene, not a continuation of the old one
            return "(game loaded)\n\n" + self._narrate_or_fallback(loaded, []), loaded

        if action.type == ActionType.INFO:
            return describe_status(self.engine, state), state

        if action.type == ActionType.HELP:
            return HELP_TEXT, state

        if action.type == ActionType.NO_ACTION:
            self.engine.apply(state, action)  # bookkeeping only -- never ticks, see rules.py
            self.transcript.append(f"> {text}")
            line = self.rng.choice(_NO_ACTION_LINES)
            self.transcript.append(line)
            return line, state

        result = self.engine.apply(state, action)
        self.transcript.append(f"> {text}")

        if result.facts or result.ok:
            text_out = self._narrate_or_fallback(state, result.facts)
        else:
            text_out = self.rng.choice(_DENIAL_LINES)

        self.transcript.append(text_out)
        return text_out, state

    def _narrate_or_fallback(self, state, facts: list) -> str:
        """Always prefixed with `_room_label(state)` -- a deterministic
        location header the LLM narration itself never reliably
        includes (by design; see `_room_label`'s own docstring). This
        is the single choke point both `main()`'s terminal loop and
        `shell_ipc.py`'s JSON backend go through for every narrated or
        fallback line, so the label reaches both the terminal shell and
        the SwiftUI app with no separate change needed on either side."""
        label = _room_label(self.engine, state)
        context = build_context(
            self.engine,
            state,
            self.characters,
            self.lore,
            facts=facts,
            recent_transcript=self.transcript,
        )
        text = self.narrator.narrate(context)
        if text is not None:
            return f"{label}\n{text}"
        fallback = _plain_fallback_text(self.engine, state, facts)
        body = f"{fallback}\n{_NARRATOR_UNREACHABLE_NOTE}" if fallback else _NARRATOR_UNREACHABLE_NOTE
        return f"{label}\n{body}"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True, help="Ollama model used for both intent parsing and narration")
    ap.add_argument("--intent-model", default=None, help="override the model used for intent parsing")
    ap.add_argument("--narration-model", default=None, help="override the model used for narration")
    ap.add_argument("--base-url", default="http://localhost:11434")
    ap.add_argument("--save-path", default=DEFAULT_SAVE_PATH)
    args = ap.parse_args()

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
    print(shell._narrate_or_fallback(state, []))
    print(
        "\n(type 'quit' to leave, 'save'/'load' to persist, 'inventory' for "
        "status, 'help' for what you can do)"
    )

    while not state.game_over:
        try:
            text = input("\n> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not text:
            continue

        display_text, state = shell.take_turn(state, text, save_path=args.save_path)
        print(f"\n{display_text}")

    if state.game_over and state.ending:
        print(f"\n*** THE END: {state.ending} ***")


if __name__ == "__main__":
    main()
