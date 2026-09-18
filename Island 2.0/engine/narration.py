"""
Island of Secrets 2.0 -- narration (Phase 2.0-D).

Stage 3 of the three-stage architecture in docs/ISLAND2_PLAN.md: turns
the rule engine's plain facts into atmospheric prose, via a local LLM
through Ollama. Extends the Classic app's NarrationContext/
NarrationService pattern (see
app/IslandOfSecrets/Sources/IslandOfSecrets/NarrationContext.swift and
NarrationService.swift, read but never modified) with "what just
happened" alongside "what the room/characters are," per
docs/ISLAND2_PLAN.md's explicit framing for this phase.

This module never invents anything. rules.py already enforces that
discipline for game *mechanics* -- it only ever returns short,
machine-readable fact codes (e.g. "took:9", "flag:coal_lit"). Those
codes are meaningless to a player and are NOT safe to hand an LLM
directly (a model asked to "narrate flag:coal_lit" will happily
hallucinate what that means). So this module's first job,
`translate_facts()`, is a small, exhaustively-verified glossary that
turns each fact code rules.py can actually produce into one short,
factual English sentence -- still nothing more than what the fact
itself says, just in words instead of a code. Only THOSE sentences
(never the raw codes, never anything else) are handed to the LLM as
"what just happened," under the same hard rule the Classic app's
narrator already follows: use only the given facts, never invent.

Coverage of every fact string rules.py can actually produce is
verified by tests/test_narration.py's AutomatedFactExtractionCoverage,
which parses rules.py itself with `ast` and checks translate_facts()
against literally everything it finds -- not a hand-copied list. (An
earlier hand-copied list here did drift: it missed "ending:quit" until
an end-to-end smoke test of shell.py surfaced a raw fact code in a
game-over message. The AST-based test replaced it as the actual
safety net; FactGlossaryCoverage's list is now just readable
documentation of *why* each entry translates the way it does.) If
rules.py grows a new fact string, the AST-based test fails immediately
-- no one has to remember to update anything by hand.

Design choices carried over from 2.0-C's intent.py, for consistency:
- The actual network call sits behind the same small `OllamaClient`
  protocol intent.py defines (imported from there rather than
  duplicated) -- same reasoning: unit-testable without a live model,
  this sandbox can't reach Ollama at all. See spike_narration.py for
  the live-quality test harness meant to run on the author's own machine.
- Narration doesn't need the JSON-schema-constrained output intent.py
  uses (there's nothing to constrain -- the whole point is free prose),
  so `format_schema=None` is passed through unused by HttpOllamaClient's
  request body's "format" field, which Ollama treats as "no format
  constraint" when absent/null, same as the Classic app's OllamaService
  calls, which never set `format` either.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from intent import HttpOllamaClient, OllamaClient  # noqa: F401 (HttpOllamaClient re-exported)
from models import GameState
from rules import RuleEngine

# --- fact -> plain-language glossary ------------------------------------

# Fixed (non-parameterized) fact strings rules.py can return, each
# mapped to one short, factual sentence. Every entry here was found by
# reading rules.py's actual `facts.append(...)`/`TurnResult(...)` call
# sites -- see this module's docstring and test_narration.py's
# FactGlossaryCoverage for how that's kept honest.
_STATIC_FACT_GLOSSARY: dict[str, str] = {
    "omegan_confrontation_unprotected": (
        "With no protector at your side, Omegan's presence saps at your strength and wisdom."
    ),
    "shelter_reached": "You reach shelter just in time.",
    "storm_broke": "A storm breaks loose and begins to follow you.",
    "ending:time_out": "Your time runs out -- the quest ends here.",
    "ending:collapsed": "Your strength finally gives out.",
    "ending:lost_the_way": "You have lost your way for good.",
    "ending:won": "You have completed the quest.",
    "flag:beast_captured": "You capture the canyon beast.",
    "smashed:staff": "You smash the staff.",
    "flag:staff_shattered": "The staff shatters into pieces.",
    "flag:egg_hatched": "The fossilised egg hatches.",
    "omegan_removed": "Omegan is gone from here now.",
    "wisdom_up": "You feel a touch wiser.",
    "struck:flint": "You strike the flint.",
    "flag:coal_lit": "The coal catches and begins to glow.",
    "cloak_dissolved": "Omegan's cloak dissolves away to nothing.",
    "no_further_effect": "Nothing further happens.",
    "blocked:swampman": "The Swampman refuses to let you pass.",
    "blocked:castle_stones": "The stones shift and block every way forward.",
    "omegan_summoned": "The attempt fails, and it draws Omegan here to defend his property.",
    "beast_escaped": "The beast breaks free and escapes.",
    "strength_restored": "You feel your strength return.",
    "flag:beast_ridden": "You climb onto the beast and ride it.",
    "flag:boat_boarded": "You board the boat.",
    "ferried_onward": "The Boatman ferries you onward.",
    "ending:enslaved_by_boatman": (
        "The Boatman judges you unworthy and takes you on as a hand instead."
    ),
    "flag:chest_opened": "The chest creaks open.",
    "flag:parchment_readable": "A parchment inside can now be read.",
    "flag:column_cracked": "The column cracks open.",
    "flag:castle_stones_parted": "The castle stones grind apart, opening the way.",
    "flag:stone_awakened": "Something stirs within the stone.",
    "flag:jug_filled_with_liquor": "The jug is now filled with the Logmen's liquor.",
    "ending:claimed_by_omegan": "Thunder splits the sky -- Omegan claims you as his own.",
    "ending:quit": "You give up the quest.",
    "flag:sage_touched": "The Sage sighs with relief at your touch.",
    "flag:snake_uncurled": "The great snake uncurls.",
    "flag:villager_gave_staff": "The villager hands something over to you.",
    "flag:dactyl_appeased": "The dactyl seems appeased.",
    "flag:memory_restored": "A lost memory is restored.",
    "flag:pebble_purified_vats": "The pebble is carried off to purify the vats.",
    "flag:swampman_appeased": "The Swampman drinks his fill and hands back the jug.",
}

# `revealed:<name>` variants where rules.py hardcodes the item's name
# directly rather than its id (chest/column/stone/sage/villager reveal
# handlers) -- distinct from the generic `revealed:<item-id>` the
# search handler produces, handled separately below.
_REVEALED_NAME_GLOSSARY: dict[str, str] = {
    "rag": "A dirty old rag is revealed.",
    "hammer": "A geologist's hammer is revealed.",
    "chip": "A chip of marble is revealed.",
    "pebble": "A glistening pebble is revealed.",
    "lily": "A lily flower is revealed.",
    "staff": "A rugged staff is revealed.",
}

# Prefixes rules.py pairs with a numeric item id -- translated by
# looking the id up in the shared item table, never guessed.
_ITEM_VERB_GLOSSARY: dict[str, str] = {
    "took": "You take",
    "dropped": "You leave behind",
    "ate": "You eat",
    "drank": "You drink",
    "given_away": "You hand over",
}


def _translate_one(engine: RuleEngine, fact: str) -> str | None:
    """One fact code -> one short sentence, or None if this fact isn't
    meant to be narrated on its own (e.g. "moved_to:*" -- the new
    room's own canonical text already covers that; restating it here
    would risk contradicting or duplicating what NarrationContext
    separately provides)."""
    if fact in _STATIC_FACT_GLOSSARY:
        return _STATIC_FACT_GLOSSARY[fact]

    if ":" not in fact:
        return None  # unrecognised code -- dropped, never guessed at

    prefix, _, suffix = fact.partition(":")

    if prefix == "revealed":
        if suffix in _REVEALED_NAME_GLOSSARY:
            return _REVEALED_NAME_GLOSSARY[suffix]
        try:
            iid = int(suffix)
        except ValueError:
            return None
        item = engine.items.get(iid)
        return f"You find {item.name.lower()}." if item else None

    if prefix in _ITEM_VERB_GLOSSARY:
        try:
            iid = int(suffix)
        except ValueError:
            return None
        item = engine.items.get(iid)
        if item is None:
            return None
        return f"{_ITEM_VERB_GLOSSARY[prefix]} {item.name.lower()}."

    if prefix == "moved_to":
        return None  # see docstring above

    if prefix == "wraith_captured":
        return "The wraiths of the Well seize you and drag you off to another part of the island."

    if prefix == "relocated":
        return "You are chased off to another part of the island."

    return None


def translate_facts(engine: RuleEngine, facts: list[str]) -> list[str]:
    """Turns rules.py's internal fact codes into short, factual
    "what just happened" sentences, in order, de-duplicated. Never adds
    anything beyond what the facts themselves say."""
    lines: list[str] = []
    for fact in facts:
        line = _translate_one(engine, fact)
        if line is not None and line not in lines:
            lines.append(line)
    return lines


# --- narration context ---------------------------------------------------


@dataclass(frozen=True)
class NarrationContext:
    """The bounded fact set an LLM prompt is allowed to see for one
    turn's narration -- deliberately built from nothing but the shared
    data/*.json tables, the real GameState, and this turn's already-
    translated facts. Mirrors NarrationContext.swift's shape and
    plain-text prompt_body() rationale: small local models follow
    plain prose instructions more reliably than they parse structured
    data."""

    room_id: int
    canonical_room_text: str
    place_lore: str | None
    characters_here: list  # [{"name": str, "book_caption": str}, ...]
    what_just_happened: list  # already-translated sentences, this turn only
    recent_transcript: list  # last few lines, for tone continuity only
    time_remaining: int
    strength: float
    wisdom: float

    @property
    def cache_key(self) -> str:
        """Stable key for Narrator's cache: two turns that would
        produce the same context should reuse the same generated text
        rather than paying for a fresh call."""
        char_names = ",".join(sorted(c["name"] for c in self.characters_here))
        facts_key = ",".join(self.what_just_happened)
        return f"room{self.room_id}|chars:{char_names}|facts:{facts_key}"

    def prompt_body(self) -> str:
        lines = [
            "Current room (canonical, verbatim -- describe this and nothing else): "
            f"{self.canonical_room_text}"
        ]
        if self.place_lore:
            lines.append(f"Book lore for this room: {self.place_lore}")
        if self.characters_here:
            lines.append("Characters present in this room right now:")
            for c in self.characters_here:
                lines.append(f"- {c['name']}: {c['book_caption']}")
        if self.what_just_happened:
            lines.append("What just happened this turn -- weave this in naturally:")
            for line in self.what_just_happened:
                lines.append(f"- {line}")
        if self.recent_transcript:
            lines.append("Recent game transcript, for continuity of tone only (do not restate it):")
            lines.append("\n".join(self.recent_transcript))
        lines.append(
            "Player status (for your own pacing/tone calibration ONLY -- "
            "e.g. write a wearier scene if strength is low. Never state "
            "these numbers, never mention 'wisdom' or 'strength' as an "
            "in-world force, sensation, or thing the player or scene can "
            "feel/see/flicker with -- they are meta-game stats, not part "
            "of the island): "
            f"time remaining: {self.time_remaining}, "
            f"strength: {int(self.strength)}, wisdom: {int(self.wisdom)}."
        )
        return "\n".join(lines)


def build_context(
    engine: RuleEngine,
    state: GameState,
    characters: list,
    lore: dict,
    facts: list | None = None,
    recent_transcript: list | None = None,
) -> NarrationContext:
    """Assembles a NarrationContext for the player's *current* room and
    status, plus this turn's translated facts. `characters` is
    data_loader.load_characters()'s list; `lore` is
    data_loader.load_lore()'s dict -- both loaded once by the caller and
    passed in, same spirit as intent.py's IntentParser taking a
    pre-built RuleEngine rather than loading data itself.

    Character presence is decided the same way NarrationContext.swift's
    assemble() does: a character with an `object_id` is here if that
    object is currently visible in this room (via engine.visible_items,
    which already excludes anything not yet revealed -- a hidden
    villager must not be narrated before the player has found them); a
    character with a `room_id` instead (room-bound features like the
    speaking-stone or the dactyl) is here whenever the player is in
    that exact room.
    """
    room = engine.rooms[state.room]
    visible_ids = set(engine.visible_items(state))

    characters_here = []
    for char in characters:
        object_id = char.get("object_id")
        room_id = char.get("room_id")
        present = (object_id is not None and object_id in visible_ids) or (
            room_id is not None and room_id == state.room
        )
        if present:
            characters_here.append(
                {"name": char.get("name", char.get("id", "")), "book_caption": char.get("book_caption", "")}
            )

    place_lore = lore.get("places", {}).get(str(state.room))

    return NarrationContext(
        room_id=state.room,
        canonical_room_text=room.description,
        place_lore=place_lore,
        characters_here=characters_here,
        what_just_happened=translate_facts(engine, facts or []),
        recent_transcript=list((recent_transcript or [])[-3:]),
        time_remaining=state.time_remaining,
        strength=state.strength,
        wisdom=state.wisdom,
    )


# --- narration generation --------------------------------------------------

# The house style is lifted from NarrationService.swift's own
# systemPrompt -- narration prose should read as one consistent world
# whichever surface (SwiftUI shell or this engine) generated it. One
# hard rule below (the player-status one) is new here, not in the
# Swift version: live-spiking against a real model (qwen2.5vl:7b)
# turned up prose that personified the player's wisdom stat as an
# in-world sensation ("The wisdom of the player seems to flicker
# faintly in the dimming light..."), because the status line at the
# end of the prompt body just read like more scene detail to weave in.
# See prompt_body()'s player-status line, which now also spells this
# out inline, and tests/test_narration.py's SystemPromptClarity /
# StatusLineIsLabeledMetaOnly for the regression coverage.
SYSTEM_PROMPT = """You are the narrator for "Island of Secrets," a 1983 text adventure \
being lightly re-illustrated in prose. You will be given a fixed set \
of facts about the player's current situation. Write one short, \
atmospheric paragraph (3-5 sentences) describing the scene.

Hard rules, no exceptions:
- Use ONLY the facts you are given. Never invent an exit, item, \
character, sound, smell, or plot detail that isn't stated.
- Never contradict the canonical room text you're given -- expand \
on it, don't replace or reinterpret it.
- Never state or hint at a puzzle solution.
- Do not address the player as "you" doing game-UI things (no \
"you can go north" style text) -- this is scene-setting prose, \
not instructions.
- The player's time/strength/wisdom numbers are meta-game stats for \
your own tone calibration only -- e.g. a low-strength scene can read \
a little wearier. Never state these numbers, and never personify \
"wisdom" or "strength" as something in the world itself (not a light, \
not a feeling in the air, not a force that flickers or glows) -- \
they are not part of the island.

Style: watercolour-and-ink illustrated storybook tone. Warm, \
slightly desaturated palette in forest/canyon areas (ochre, \
rust-orange, dusty green); cooler slate-blue and violet for \
castle/pyramid/night scenes. Lighting is moody, end-of-day or \
overcast, with dramatic skies. Nothing clean or heroic-fantasy -- \
weathered and a little uncanny, matching a children's adventure \
book from the early 1980s."""


@dataclass
class Narrator:
    """Python analog of NarrationService.swift, minus the SwiftUI/
    @Published/Task plumbing that's meaningless outside a view layer:
    given a context, ask the model for one paragraph, additively --
    any failure (model unreachable, bad response) just returns None,
    exactly like NarrationService leaving its panel empty. Caches by
    "{model}|{context.cache_key}" in memory; the caller decides whether
    and how to persist that dict (e.g. to data/narration_cache.json,
    same file NarrationService.swift already reads/writes, so both
    surfaces can eventually share one cache if desired)."""

    client: OllamaClient
    model: str
    cache: dict = field(default_factory=dict)
    temperature: float = 0.7  # more creative than 2.0-C's 0.0 -- this is prose, not extraction

    def narrate(self, context: NarrationContext) -> str | None:
        key = f"{self.model}|{context.cache_key}"
        if key in self.cache:
            return self.cache[key]

        text = self.client.chat(
            model=self.model,
            system=SYSTEM_PROMPT,
            user=context.prompt_body(),
            format_schema=None,
            temperature=self.temperature,
            timeout=30.0,
        )
        if text is None:
            return None
        self.cache[key] = text
        return text
