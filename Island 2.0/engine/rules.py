"""
Island of Secrets 2.0 -- the rule engine (Phase 2.0-B).

This is stage 2 of the three-stage architecture in docs/ISLAND2_PLAN.md:
"Rule evaluation (plain code, no LLM)." It never invents anything and
is never asked to be creative -- given a structured Action and the
current GameState, it decides whether the action is even possible right
now, and if so, updates state and returns the *facts* of what changed.
Stage 3 (narration, not built yet) is the only thing allowed to turn
those facts into prose, and it is never allowed to invent facts this
stage didn't produce.

Every puzzle rule below is implemented exactly as documented and
evidenced in docs/2.0-A_RULE_SCHEMA.md -- comments reference the
relevant section. Where 2.0 knowingly deviates from a literal port
(see that document's "confirmed" vs "design choice" tags), it's called
out inline.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field

from actions import Action, ActionType
from models import DIRECTION_DELTA, GameState, ItemCategory
import flags as F
from world_seed import INITIAL_ITEM_LOCATIONS

# --- Item id constants (data/items.json order) -----------------------
APPLE, EGG, LILY, JUG, RAG, PARCHMENT, TORCH, PEBBLE, AXE, ROPE = range(1, 11)
STAFF, CHIP, COAL, FLINT, HAMMER, BEAST, LOAF, MELON, BISCUITS, MUSHROOMS = range(11, 21)
WATER, WINE, SAP, SPRING, BOATMAN, CHEST, FRACTURE, MOUTH_OPENING, TRAPDOOR, VILLAGER = range(21, 31)
LIQUOR, SWAMPMAN, SAGE, BOOKS, ROOTS, STORM, WRAITHS, CLOAK, OMEGAN, SNAKE = range(31, 41)
LOGMEN, SCAVENGER, MEDIAN = 41, 42, 43

FOOD_ITEMS = {LOAF, MELON, BISCUITS, MUSHROOMS}
DRINK_ITEMS = {WATER, WINE, SAP, SPRING}
GENERAL_ITEMS = set(range(1, 17))  # 1-16, matches C1 boundary in the original

# --- Room id constants used by name in the rules below -----------------
ROOM_SHACK_CLEARING = 45   # snake + apple
ROOM_SHACK = 44            # the chest, rag, hammer, loaf, water
ROOM_SNELM_LAIR = 11
ROOM_SNELM_INNER = 21      # the parchment
ROOM_CLASHING_STONES = 14  # the inscription
ROOM_SPEAKING_STONE = 15   # where you actually say the words
ROOM_MARBLE_COLUMN = 58
ROOM_PETRIFIED_VILLAGE = 75  # the villager, the (hidden) staff
ROOM_DACTYL_NEST = 46
ROOM_SCAVENGER = 38        # Scavenger/Median
ROOM_SANCTUM = 10          # Omegan's Sanctum -- staff/coal smashed here
ROOM_SPLIT_LOG_TABLE = 42  # stolen goods end up here
ROOM_LOG_PIER = 33         # the Boatman
ROOM_WELL_EDGE = 19
ROOM_WELL_APPROACH = 29
ROOM_VATS = 8              # Sludge Fermentation Vats (Median runs the pebble here)
ROOM_CORRAL = 5            # canyon beast
ROOM_BROKEN_CHAIRS = 62    # the rope
ROOM_PYRAMID_SPLIT = 67    # the flint
ROOM_STUMPS_VILLAGE = 78   # the Swampman
ROOM_HOLLOW_CHAMBER = 80   # the coal, past the Swampman
ROOM_LOG_SETTLEMENT_STILL = 41  # FILL JUG here, confirmed-code (F(4)=-1)
ROOM_CASTLE_STONES = 47    # "beneath the Castle of Dark Secrets, by two huge stones"

SHELTER_ROOMS = {ROOM_SHACK, ROOM_SNELM_LAIR, 52}  # Grandpa's Shack / Snelm's Lair / Log Cabin (Logmen's Hall)

# The reckless-tap trap -- rule #14, confirmed-code: tapping/testing a
# dangerous target while carrying the axe is an instant losing ending,
# not a strength check.
DANGEROUS_TAP_TARGETS = {"omegan", "beast", "wraith"}


@dataclass
class TurnResult:
    ok: bool
    facts: list = field(default_factory=list)  # short machine-readable fact strings
    message: str = ""  # a plain internal note for logging/tests; NOT narration prose


def new_game() -> GameState:
    state = GameState()
    state.flags = F.initial_flags()
    state.item_room = {iid: room for iid, (room, _hidden) in INITIAL_ITEM_LOCATIONS.items()}
    state.item_hidden = {iid: hidden for iid, (_room, hidden) in INITIAL_ITEM_LOCATIONS.items()}
    return state


class RuleEngine:
    def __init__(self, rooms: dict, items: dict, rng: random.Random | None = None):
        self.rooms = rooms
        self.items = items
        self.rng = rng or random.Random()

    # -- top level ------------------------------------------------------

    def apply(self, state: GameState, action: Action) -> TurnResult:
        if state.game_over:
            return TurnResult(False, [], "the quest has already ended")

        handler = getattr(self, f"_handle_{action.type.value}", None)
        if handler is None:
            return TurnResult(False, [], f"no handler for {action.type}")

        result = handler(state, action)
        state.turn += 1

        if not action.type in (ActionType.INFO, ActionType.SAVE, ActionType.LOAD,
                                ActionType.QUIT, ActionType.NO_ACTION):
            self._tick(state, result)

        self._update_win_condition(state)
        self._check_ending(state, result)
        return result

    def _update_win_condition(self, state: GameState) -> None:
        # rule #20 / listing.bas line 530, confirmed-code exactly:
        # F(pebble)+F(staff)+F(coal) = -3, i.e. all three activated.
        if (state.flags[F.PEBBLE_PURIFIED_VATS]
                and state.flags[F.STAFF_SHATTERED]
                and state.flags[F.COAL_LIT]):
            state.flags[F.QUEST_WON] = True

    # -- per-turn upkeep --------------------------------------------------

    def _tick(self, state: GameState, result: TurnResult) -> None:
        state.time_remaining -= 1

        # Median follows the player -- confirmed-code + walkthrough
        # ("from now on he follows you"): listing.bas line 470,
        # `IF F(43)=0 THEN LET L(43)=R`, updates Median's own room to
        # the player's current room every turn once he's revealed.
        # Without this, _give_pebble_to_median could never succeed
        # anywhere except the exact room he was revealed in.
        if state.flags[F.MEMORY_RESTORED]:
            state.item_room[MEDIAN] = state.room

        # Confronting Omegan without Median at your side, before the
        # coal is lit, costs strength and wisdom every turn --
        # confirmed-code, listing.bas line 400: `IF R=L(39) AND
        # R<>L(43) AND F(13)>-1 THEN LET Y=Y-2:LET X=X-2` (Y=strength,
        # X=wisdom). Only applies while Omegan is still "in play"
        # (not yet removed by the egg-hatch bonus).
        if (state.item_room.get(OMEGAN) == state.room
                and state.item_room.get(MEDIAN) != state.room
                and not state.flags[F.COAL_LIT]):
            state.strength -= 2.0
            state.wisdom -= 2.0
            result.facts.append("omegan_confrontation_unprotected")

        # Strength drains a little every turn, faster the more of the
        # designated "objects of power" the player is carrying -- the
        # original's FNS burden mechanic (docs/2.0-A_RULE_SCHEMA.md
        # section 6), simplified to a flat formula.
        power_items_carried = len(state.inventory & {PEBBLE, STAFF, CHIP, COAL, FLINT})
        state.strength -= 0.5 + 0.3 * power_items_carried

        # Storm ticking: once active, a small chance per turn it forces a
        # shelter choice; strength keeps draining faster while unresolved.
        if state.flags[F.STORM_ACTIVE] and not state.flags[F.SHELTER_REACHED]:
            state.strength -= 1.0
            if state.room in SHELTER_ROOMS:
                state.flags[F.SHELTER_REACHED] = True
                state.flags[F.STORM_ACTIVE] = False
                result.facts.append("shelter_reached")
        elif not state.flags[F.STORM_ACTIVE] and self.rng.random() < 0.01:
            state.flags[F.STORM_ACTIVE] = True
            state.flags[F.SHELTER_REACHED] = False
            result.facts.append("storm_broke")

    def _check_ending(self, state: GameState, result: TurnResult) -> None:
        if state.game_over:
            return
        if state.time_remaining < 1:
            state.game_over = True
            state.ending = "time_out"
            result.facts.append("ending:time_out")
        elif state.strength < 1:
            state.game_over = True
            state.ending = "collapsed"
            result.facts.append("ending:collapsed")
        elif state.wisdom < 1:
            state.game_over = True
            state.ending = "lost_the_way"
            result.facts.append("ending:lost_the_way")
        elif state.flags[F.QUEST_WON]:
            state.game_over = True
            state.ending = "won"
            result.facts.append("ending:won")

    # -- helpers ----------------------------------------------------------

    def _visible_items(self, state: GameState, room: int) -> list:
        return [
            iid for iid, r in state.item_room.items()
            if r == room and not state.item_hidden.get(iid, False)
        ]

    def visible_items(self, state: GameState) -> list:
        """Public wrapper for 2.0-C's intent parser: item ids currently
        visible (not hidden) in the player's own room, for building the
        per-turn context an LLM needs -- same spirit as the Classic app's
        CommandTranslator scoping its noun list to what's actually here."""
        return self._visible_items(state, state.room)

    def _all_items_in_room(self, state: GameState, room: int) -> list:
        return [iid for iid, r in state.item_room.items() if r == room]

    def _resolve_item(self, state: GameState, ref, room_only: bool = False) -> int | None:
        """Resolve an item name/id reference against carried + current-room
        items (case-insensitive substring match against data/items.json
        names) or a plain id. Returns None if not found/not here."""
        if ref is None:
            return None
        if isinstance(ref, int):
            return ref
        ref_low = str(ref).lower()
        candidates = list(state.inventory) if not room_only else []
        candidates += self._all_items_in_room(state, state.room)
        for iid in candidates:
            if ref_low in self.items[iid].name.lower():
                return iid
        return None

    # -- movement -----------------------------------------------------------

    def _handle_go(self, state: GameState, action: Action) -> TurnResult:
        direction = (action.direction or "").upper()[:1]
        if direction not in DIRECTION_DELTA:
            return TurnResult(False, [], "not a direction")

        room = self.rooms[state.room]
        if not room.exits.get(direction, False):
            return TurnResult(False, [], "blocked")

        # Swampman blockade: rule #18 in docs/2.0-A_RULE_SCHEMA.md --
        # confirmed-code, blocks the path east out of the Stumps village
        # until he's been given the Logmen's liquor.
        if state.room == ROOM_STUMPS_VILLAGE and direction == "E" and not state.flags[F.SWAMPMAN_APPEASED]:
            return TurnResult(False, ["blocked:swampman"], "he will not let you past")

        # Castle Stones blockade -- confirmed-code, listing.bas line 910:
        # `IF R=47 AND F(44)=0 THEN "THE ROCKS MOVE TO PREVENT YOU"`,
        # unconditional on direction -- every exit from room 47 is
        # blocked until SAY STONY WORDS has parted the stones there
        # (see _handle_say).
        if state.room == ROOM_CASTLE_STONES and not state.flags[F.CASTLE_STONES_PARTED]:
            return TurnResult(False, ["blocked:castle_stones"], "the rocks move to prevent you")

        dest = state.room + DIRECTION_DELTA[direction]
        if dest not in self.rooms:
            return TurnResult(False, [], "nowhere that way")

        state.room = dest
        result = TurnResult(True, [f"moved_to:{dest}"], "moved")

        # Well of Despair wraiths -- rule #17, confirmed-code:
        # strength<70 near the Well risks a random relocation.
        if dest in (ROOM_WELL_EDGE, ROOM_WELL_APPROACH) and state.strength < 70:
            if self.rng.random() < 0.5:
                new_room = self.rng.choice(list(self.rooms.keys()))
                state.room = new_room
                state.flags[F.WRAITH_CAPTURED] = True
                result.facts.append(f"wraith_captured:{new_room}")

        return result

    # -- inventory ---------------------------------------------------------

    def _handle_take(self, state: GameState, action: Action) -> TurnResult:
        iid = self._resolve_item(state, action.item, room_only=True)

        # TAKE CLOAK at the Sanctum, with Omegan not there -- confirmed-
        # code + walkthrough ("try to TAKE CLOAK; you will fail, but
        # Omegan will appear to defend his property"): listing.bas line
        # 1380, `LET L(39)=R:LET Y=Y-3:LET X=X-2`, summons Omegan to the
        # player's room at a strength/wisdom cost, without ever letting
        # the cloak itself be taken (it's non-takeable scenery). 2.0
        # doesn't otherwise move Omegan out of the Sanctum (a documented
        # simplification -- see README), so this mainly matters as a
        # safety net / for fidelity, not as a required step.
        if iid == CLOAK and state.room == ROOM_SANCTUM and state.item_room.get(OMEGAN) != state.room:
            state.item_room[OMEGAN] = state.room
            state.strength -= 3.0
            state.wisdom -= 2.0
            return TurnResult(False, ["omegan_summoned"], "you fail, but Omegan appears to defend his property")

        if iid is None or state.item_room.get(iid) != state.room:
            return TurnResult(False, [], "not here")
        if state.item_hidden.get(iid):
            return TurnResult(False, [], "not found yet -- try searching")
        item = self.items[iid]
        if item.category == ItemCategory.SCENERY_OR_CHARACTER:
            return TurnResult(False, [], "can't take that")

        # Canyon Beast taming -- rule #7, confirmed-code: only sticks if
        # the player is carrying the rope at the moment of capture.
        if iid == BEAST and ROPE not in state.inventory:
            return TurnResult(False, ["beast_escaped"], "it escapes")

        state.item_room[iid] = None
        state.inventory.add(iid)
        result = TurnResult(True, [f"took:{iid}"], "taken")
        if iid == BEAST:
            state.flags[F.BEAST_CAPTURED] = True
            result.facts.append("flag:beast_captured")
        return result

    def _handle_drop(self, state: GameState, action: Action) -> TurnResult:
        iid = self._resolve_item(state, action.item)
        if iid is None or iid not in state.inventory:
            return TurnResult(False, [], "not carrying that")
        state.inventory.discard(iid)
        state.item_room[iid] = state.room
        return TurnResult(True, [f"dropped:{iid}"], "dropped")

    def _handle_eat(self, state: GameState, action: Action) -> TurnResult:
        iid = self._resolve_item(state, action.item)
        if iid is None or iid not in state.inventory or iid not in FOOD_ITEMS:
            return TurnResult(False, [], "can't eat that")
        state.inventory.discard(iid)
        state.item_room[iid] = None
        state.strength = min(100.0, state.strength + 10)
        return TurnResult(True, [f"ate:{iid}", "strength_restored"], "ok")

    def _handle_drink(self, state: GameState, action: Action) -> TurnResult:
        iid = self._resolve_item(state, action.item)
        if iid is None or iid not in state.inventory or iid not in DRINK_ITEMS:
            return TurnResult(False, [], "can't drink that")
        state.inventory.discard(iid)
        state.item_room[iid] = None
        state.strength = min(100.0, state.strength + 5)
        return TurnResult(True, [f"drank:{iid}", "strength_restored"], "ok")

    def _handle_ride(self, state: GameState, action: Action) -> TurnResult:
        iid = self._resolve_item(state, action.item) or BEAST
        if iid == BEAST and state.flags[F.BEAST_CAPTURED]:
            state.flags[F.BEAST_RIDDEN] = True
            return TurnResult(True, ["flag:beast_ridden"], "you ride the beast")
        if iid == BOATMAN:
            return self._board_boat(state)
        return TurnResult(False, [], "can't ride that")

    def _board_boat(self, state: GameState) -> TurnResult:
        if state.item_room.get(BOATMAN) != state.room:
            return TurnResult(False, [], "the boatman is not here")
        if state.wisdom >= 60:
            state.flags[F.BOAT_BOARDED] = True
            return TurnResult(True, ["flag:boat_boarded", "ferried_onward"], "he ferries you onward")
        state.game_over = True
        state.ending = "enslaved_by_boatman"
        return TurnResult(True, ["ending:enslaved_by_boatman"], "not wise enough; he takes you as a hand instead")

    # -- open / use / say / touch -------------------------------------------

    def _handle_open(self, state: GameState, action: Action) -> TurnResult:
        target = str(action.target or "").lower()
        if "chest" in target and state.room == ROOM_SHACK:
            if state.flags[F.CHEST_OPENED]:
                return TurnResult(False, [], "already open")
            state.flags[F.CHEST_OPENED] = True
            state.flags[F.PARCHMENT_READABLE] = True
            for iid in (RAG, HAMMER):
                state.item_hidden[iid] = False
            return TurnResult(True, ["flag:chest_opened", "flag:parchment_readable",
                                      "revealed:rag", "revealed:hammer"], "the chest creaks open")
        return TurnResult(False, [], "can't open that")

    def _handle_use(self, state: GameState, action: Action) -> TurnResult:
        iid = self._resolve_item(state, action.item)
        target = str(action.target or "").lower()

        # Marble Column -- rule #4, confirmed-code: hammer or chip
        # cracks it open, revealing the chip + the fracture (NOT the
        # coal -- see world_seed.py's note on that correction).
        if "column" in target and state.room == ROOM_MARBLE_COLUMN and iid in (HAMMER, CHIP):
            if state.flags[F.COLUMN_CRACKED]:
                return TurnResult(False, [], "already cracked")
            state.flags[F.COLUMN_CRACKED] = True
            state.item_hidden[CHIP] = False
            state.item_hidden[FRACTURE] = False
            return TurnResult(True, ["flag:column_cracked", "revealed:chip"], "crack!")

        # Smashing the staff or striking the flint at Omegan's Sanctum
        # -- rules #12/#13. Corrected, walkthrough audit + deeper
        # tracing of listing.bas's own dispatch: only STAFF and FLINT
        # are actually reachable here (`IF LEFT$(B$,4)="1100" AND R=10`
        # for the staff, `IF LEFT$(B$,4)="1400" AND R=L(39)` for the
        # flint) -- CHIP and COAL never get a matching literal
        # anywhere in the listing, so "use chip/coal" at the Sanctum is
        # dead code in the original, same family as the other
        # transcription bugs already documented. The two reachable
        # items also aren't interchangeable: STAFF is what the
        # win-condition's own flag watches (and only works literally
        # at room 10); FLINT is what lights the coal (and, in the
        # original, has to be struck wherever Omegan currently is --
        # 2.0 doesn't model Omegan wandering the map, see README, so
        # in practice that's also just the Sanctum, unless Omegan's
        # been summoned elsewhere via TAKE CLOAK, see _handle_take).
        if iid == STAFF and state.room == ROOM_SANCTUM:
            return self._smash_staff(state)
        if iid == FLINT and state.item_room.get(OMEGAN) == state.room:
            return self._strike_flint(state)

        return TurnResult(False, [], "nothing happens")

    def _smash_staff(self, state: GameState) -> TurnResult:
        if STAFF not in state.inventory:
            return TurnResult(False, [], "you don't have that")
        state.inventory.discard(STAFF)
        state.flags[F.STAFF_SHATTERED] = True
        facts = ["smashed:staff", "flag:staff_shattered"]

        # Egg-hatch bonus -- corrected: gated on the egg being
        # physically DROPPED in the Sanctum at the moment of smashing,
        # not carried (listing.bas subroutine 2010's `IF L(2)<>R THEN
        # RETURN`, only true for a dropped item since a carried one has
        # L=0) -- confirmed by the walkthrough's explicit "DROP EGG,
        # DROP COAL" step before striking anything.
        if not state.flags[F.EGG_HATCHED] and state.item_room.get(EGG) == state.room:
            state.item_room[EGG] = None
            state.flags[F.EGG_HATCHED] = True
            state.wisdom = min(100.0, state.wisdom + 40)
            state.item_room[OMEGAN] = None  # removed from play
            facts += ["flag:egg_hatched", "omegan_removed", "wisdom_up"]

        return TurnResult(True, facts, "it shatters, releasing a dazzling rainbow of colours")

    def _strike_flint(self, state: GameState) -> TurnResult:
        if FLINT not in state.inventory:
            return TurnResult(False, [], "you don't have that")
        state.inventory.discard(FLINT)
        facts = ["struck:flint"]

        # Coal-lit bonus -- corrected: gated on the coal being
        # physically DROPPED in this room (listing.bas subroutine
        # 2060's `IF L(13)<>R THEN RETURN`, same drop-not-carry logic
        # as the egg above). (The interpreter can't itself execute the
        # exact `ON O-10 GOSUB 2010,2060,2060,2060` dispatch line to
        # confirm every wiring detail at runtime -- a tooling gap, not
        # fixable here, see docs/2.0-A_RULE_SCHEMA.md section 8 -- so
        # this rests on strong static-code + walkthrough corroboration
        # rather than full runtime confirmation.)
        if not state.flags[F.COAL_LIT] and state.item_room.get(COAL) == state.room:
            state.item_room[COAL] = None
            state.flags[F.COAL_LIT] = True
            facts.append("flag:coal_lit")
            if state.item_room.get(OMEGAN) == state.room:
                facts.append("cloak_dissolved")  # flavor only, not gating
        else:
            facts.append("no_further_effect")

        return TurnResult(True, facts, "it strikes true")

    def _handle_say(self, state: GameState, action: Action) -> TurnResult:
        phrase = (action.phrase or "").lower()

        scavenger_result = self._handle_say_to_scavenger(state, phrase)
        if scavenger_result is not None:
            return scavenger_result

        # Corrected -- rule #4/#8 in docs/2.0-A_RULE_SCHEMA.md: "SAY
        # STONY WORDS" is not what wakes the Speaking Stone (that's
        # RUB STONE at room 15, see _handle_rub). It is instead a
        # separate, later action at room 47 ("beneath the Castle of
        # Dark Secrets, by two huge stones") that parts the rocks
        # blocking every exit there -- confirmed-code, listing.bas
        # line 2350, and empirically verified against
        # basic_interpreter.py: requires the pebble already rubbed
        # free (STONE_AWAKENED) and sets F(44), which line 910 checks
        # to gate movement out of room 47.
        if state.room == ROOM_CASTLE_STONES and "stony" in phrase:
            if not state.flags[F.STONE_AWAKENED]:
                return TurnResult(False, [], "nothing happens")
            if state.flags[F.CASTLE_STONES_PARTED]:
                return TurnResult(False, [], "the rocks have already moved")
            state.flags[F.CASTLE_STONES_PARTED] = True
            return TurnResult(True, ["flag:castle_stones_parted"], "the stones are fixed... then grind apart")
        return TurnResult(False, [], "nothing happens")

    def _handle_rub(self, state: GameState, action: Action) -> TurnResult:
        target = str(action.target or "").lower()

        # Speaking Stone / pebble -- corrected, confirmed-code +
        # empirically verified: RUB STONE at room 15, while carrying
        # the rag, is what actually reveals the pebble
        # ("REFLECTIONS STIR WITHIN"), not SAY STONY WORDS as the
        # schema originally guessed (listing.bas subroutine 2500-2520,
        # gated on L(rag)=0 i.e. carried).
        if "stone" in target and state.room == ROOM_SPEAKING_STONE:
            if state.flags[F.STONE_AWAKENED]:
                return TurnResult(False, [], "you can't rub stone")
            if RAG not in state.inventory:
                return TurnResult(False, [], "nothing happens")
            state.flags[F.STONE_AWAKENED] = True
            state.item_hidden[PEBBLE] = False
            return TurnResult(True, ["flag:stone_awakened", "revealed:pebble"], "reflections stir within")
        return TurnResult(False, [], "nothing happens")

    def _handle_fill(self, state: GameState, action: Action) -> TurnResult:
        iid = self._resolve_item(state, action.item)

        # Filling the jug at the Logmen's still -- confirmed-code +
        # empirically verified: FILL JUG at room 41 sets the jug's own
        # "filled with liquor" state (listing.bas F(4)=-1), distinct
        # from the abstract drink counter used elsewhere. This is what
        # the Swampman actually wants -- see _give_to_swampman.
        if iid == JUG and state.room == ROOM_LOG_SETTLEMENT_STILL and JUG in state.inventory:
            state.jug_filled_with_liquor = True
            return TurnResult(True, ["flag:jug_filled_with_liquor"], "filled")
        return TurnResult(False, [], "nothing to fill it with here")

    def _handle_touch(self, state: GameState, action: Action) -> TurnResult:
        target = str(action.target or "").lower()

        # The reckless-tap trap -- rule #14, confirmed-code: tapping/
        # testing a dangerous target while carrying the axe is an
        # instant losing ending, not a strength check. Checked before
        # anything else touch() might otherwise do.
        if AXE in state.inventory and any(t in target for t in DANGEROUS_TAP_TARGETS):
            state.flags[F.RECKLESS_TAP_TRAP] = True
            state.game_over = True
            state.ending = "claimed_by_omegan"
            return TurnResult(True, ["ending:claimed_by_omegan"],
                               "thunder splits the sky -- I claim you as my own!")

        if "sage" in target and state.item_room.get(SAGE) == state.room:
            if state.flags[F.SAGE_TOUCHED]:
                return TurnResult(False, [], "already done")
            state.flags[F.SAGE_TOUCHED] = True
            state.item_hidden[LILY] = False
            state.wisdom = min(100.0, state.wisdom + 5)
            return TurnResult(True, ["flag:sage_touched", "revealed:lily", "wisdom_up"], "she sighs with relief")
        return TurnResult(False, [], "nothing happens")

    # -- give ------------------------------------------------------------

    def _handle_give(self, state: GameState, action: Action) -> TurnResult:
        iid = self._resolve_item(state, action.item)
        if iid is None or iid not in state.inventory:
            return TurnResult(False, [], "you don't have that")
        recipient = str(action.target or "").lower()

        if "snake" in recipient and iid == APPLE:
            return self._give_to_snake(state)
        if "villager" in recipient and iid in DRINK_ITEMS:
            return self._give_to_villager(state, iid)
        if "scavenger" in recipient and iid in (LILY, CHIP) and self._scavenger_here(state):
            return self._offer_to_scavenger(state, iid)
        if "median" in recipient and iid == PEBBLE:
            return self._give_pebble_to_median(state)
        if "swampman" in recipient and iid == JUG:
            return self._give_to_swampman(state)
        return TurnResult(False, [], "it is refused")

    def _give_to_snake(self, state: GameState) -> TurnResult:
        if state.room != ROOM_SHACK_CLEARING or state.item_room.get(SNAKE) != ROOM_SHACK_CLEARING:
            return TurnResult(False, [], "the snake is not here")
        state.inventory.discard(APPLE)
        state.item_room[APPLE] = None
        state.flags[F.SNAKE_UNCURLED] = True
        state.item_room[SNAKE] = None
        return TurnResult(True, ["flag:snake_uncurled"], "the snake uncurls")

    def _give_to_villager(self, state: GameState, iid: int) -> TurnResult:
        # Corrected -- confirmed-code + empirically verified: the
        # original accepts giving any carried drink item (matched by
        # its own noun, e.g. "WATER") and decrements the abstract
        # drink counter, not a specific "jug filled with a drink"
        # combo. Neither the jug (item 4) nor the bottle (item 21) is
        # itself consumed in the shipped code -- the drink item given
        # is what's consumed. 2.0 keeps drink items as discrete
        # carried items (see GameState docstring), so the given drink
        # item itself is what's removed here.
        if state.room != ROOM_PETRIFIED_VILLAGE or state.item_room.get(VILLAGER) != ROOM_PETRIFIED_VILLAGE:
            return TurnResult(False, [], "the villager is not here")
        state.inventory.discard(iid)
        state.item_room[iid] = None
        state.flags[F.VILLAGER_GAVE_STAFF] = True
        state.item_hidden[STAFF] = False

        # Design-choice restoration of the book's Dactyl's-nest gate
        # (docs/2.0-A_RULE_SCHEMA.md section 3/8): visiting the
        # Petrified Village first is what "proves you're serious"
        # before Dactyl will let the egg be taken peacefully.
        state.flags[F.DACTYL_APPEASED] = True

        return TurnResult(True, ["flag:villager_gave_staff", "revealed:staff", "flag:dactyl_appeased"],
                           "he offers his staff")

    def _scavenger_here(self, state: GameState) -> bool:
        loc = state.item_room.get(SCAVENGER)
        return loc == state.room and not state.flags[F.MEMORY_RESTORED]

    def _offer_to_scavenger(self, state: GameState, iid: int) -> TurnResult:
        # rule #9, three separate steps -- give(chip), give(flower),
        # then say(phrase). Traced empirically by actually running the
        # verified engine/basic_interpreter.py (not just reading the
        # listing -- see docs/2.0-A_RULE_SCHEMA.md section 8): the
        # original's own GIVE-to-Scavenger branches (recipient index 42)
        # never actually match for any real room number, which looks
        # like a further undiscovered transcription bug in the same
        # family PLAYTEST_NOTES.md already documents elsewhere -- so
        # this is a fresh 2.0 implementation of the *intent*, not a
        # literal port of that specific path. The final check that
        # completes the transformation (both items marked "given away",
        # then the right word spoken in his room) is exactly what the
        # shipped code does check reliably, so that part is
        # confirmed-code.
        if iid in state.given_away:
            return TurnResult(False, [], "already offered")
        state.inventory.discard(iid)
        state.item_room[iid] = None
        state.given_away.add(iid)
        return TurnResult(True, [f"given_away:{iid}"], "he stares blankly, but keeps it")

    def _handle_say_to_scavenger(self, state: GameState, phrase: str) -> TurnResult | None:
        if not self._scavenger_here(state):
            return None
        if LILY not in state.given_away or CHIP not in state.given_away:
            return TurnResult(False, [], "give him two things first")
        # rule #9 / confirmed-book: "Remember Old Times" -- the phrase
        # matches the Marble Column's own inscription (see
        # docs/ART_CLUES.md and docs/2.0-A_RULE_SCHEMA.md section 8,
        # now resolved).
        if "remember" not in phrase and "old times" not in phrase:
            return TurnResult(False, [], "say something")
        state.flags[F.MEMORY_RESTORED] = True
        state.item_room[SCAVENGER] = None
        state.item_room[MEDIAN] = state.room
        state.item_hidden[MEDIAN] = False
        return TurnResult(True, ["flag:memory_restored"], "he eats the flowers -- and changes")

    def _give_pebble_to_median(self, state: GameState) -> TurnResult:
        if not state.flags[F.MEMORY_RESTORED] or state.item_room.get(MEDIAN) != state.room:
            return TurnResult(False, [], "median is not here")
        state.inventory.discard(PEBBLE)
        state.item_room[PEBBLE] = None
        state.flags[F.PEBBLE_PURIFIED_VATS] = True
        return TurnResult(True, ["flag:pebble_purified_vats"], "he runs it to the vats")

    def _give_to_swampman(self, state: GameState) -> TurnResult:
        # Corrected: the original's own GIVE-to-Swampman branch
        # (listing.bas line 1480, `IF B$="40-" AND N=32`) is dead code
        # in the same family as the Scavenger bug -- B$ is always
        # "40-"+room-number-digits for the filled jug, never exactly
        # "40-", so it can never match (confirmed empirically). LIQUOR
        # (item 31) itself is non-takeable scenery and can never be in
        # inventory either, so a literal "give the liquor" is
        # impossible. This is a fresh 2.0 implementation of the
        # story's clear intent (he wants the still's liquor to restore
        # the bluewood trees -- data/characters.json) rather than a
        # literal port of a path that never worked: give him the jug
        # once it's been filled at the still (see _handle_fill). He
        # drinks the liquor and hands the empty jug back.
        if state.item_room.get(SWAMPMAN) != state.room:
            return TurnResult(False, [], "the swampman is not here")
        if not state.jug_filled_with_liquor:
            return TurnResult(False, [], "it is refused -- empty")
        state.jug_filled_with_liquor = False
        state.flags[F.SWAMPMAN_APPEASED] = True
        return TurnResult(True, ["flag:swampman_appeased"], "he drinks it and hands back the jug")

    # -- search / examine --------------------------------------------------

    def _handle_search(self, state: GameState, action: Action) -> TurnResult:
        revealed = []
        for iid in self._all_items_in_room(state, state.room):
            if state.item_hidden.get(iid):
                state.item_hidden[iid] = False
                revealed.append(iid)
        if not revealed:
            return TurnResult(True, [], "nothing more to find")
        return TurnResult(True, [f"revealed:{i}" for i in revealed], "you find something")

    def _handle_examine(self, state: GameState, action: Action) -> TurnResult:
        return TurnResult(True, [], "examined")

    # -- danger / traps ------------------------------------------------------

    def _handle_attack(self, state: GameState, action: Action) -> TurnResult:
        target = str(action.target or "").lower()
        if "dactyl" in target or state.room == ROOM_DACTYL_NEST:
            new_room = self.rng.choice(list(self.rooms.keys()))
            state.room = new_room
            state.strength -= 4
            state.wisdom -= 4
            return TurnResult(True, [f"relocated:{new_room}"], "you are chased off")
        state.strength -= 2
        state.wisdom -= 2
        return TurnResult(True, [], "that accomplishes nothing")

    def _handle_combine(self, state: GameState, action: Action) -> TurnResult:
        return self._handle_use(state, action)

    def _handle_talk(self, state: GameState, action: Action) -> TurnResult:
        target = str(action.target or "").lower()
        if "boatman" in target:
            return self._board_boat(state)
        return TurnResult(True, [], "no response")

    def _handle_wait(self, state: GameState, action: Action) -> TurnResult:
        return TurnResult(True, [], "time passes")

    def _handle_rest(self, state: GameState, action: Action) -> TurnResult:
        state.strength = min(100.0, state.strength + 3)
        return TurnResult(True, ["strength_restored"], "you rest")

    def _handle_info(self, state: GameState, action: Action) -> TurnResult:
        return TurnResult(True, [], "info")

    def _handle_save(self, state: GameState, action: Action) -> TurnResult:
        return TurnResult(True, [], "saved")

    def _handle_load(self, state: GameState, action: Action) -> TurnResult:
        return TurnResult(True, [], "loaded")

    def _handle_quit(self, state: GameState, action: Action) -> TurnResult:
        state.game_over = True
        state.ending = "quit"
        return TurnResult(True, ["ending:quit"], "you give up the quest")

    def _handle_no_action(self, state: GameState, action: Action) -> TurnResult:
        return TurnResult(True, [], "")
