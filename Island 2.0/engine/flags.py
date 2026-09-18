"""
The 2.0-A flag set -- see docs/2.0-A_RULE_SCHEMA.md section 3 for the
full documented meaning and evidence for each. Kept as plain string
constants (not an Enum) so `state.flags` can stay a simple dict, easy
to serialize for the IPC protocol and easy to inspect in tests.
"""

SNAKE_UNCURLED = "snake_uncurled"
CHEST_OPENED = "chest_opened"
PARCHMENT_READABLE = "parchment_readable"
BEAST_CAPTURED = "beast_captured"
BEAST_RIDDEN = "beast_ridden"
VILLAGER_GAVE_STAFF = "villager_gave_staff"
COLUMN_CRACKED = "column_cracked"
# Confirmed-code, corrected: this is set by RUB STONE at the Speaking
# Stone's room (15), not SAY, and grants/reveals the pebble -- see
# rules.py's _handle_rub. Not to be confused with CASTLE_STONES_PARTED
# below, a separate later gate.
STONE_AWAKENED = "stone_awakened"
# Confirmed-code: SAY STONY WORDS at room 47 ("beneath the Castle of
# Dark Secrets, by two huge stones"), once the pebble has been rubbed
# free (STONE_AWAKENED), parts the rocks blocking every exit from that
# room (listing.bas lines 910/2350 -- traced and empirically verified
# against basic_interpreter.py; see docs/2.0-A_RULE_SCHEMA.md section 8).
CASTLE_STONES_PARTED = "castle_stones_parted"
SAGE_TOUCHED = "sage_touched"
MEMORY_RESTORED = "memory_restored"
MEDIAN_HINT_ACTIVE = "median_hint_active"
DACTYL_APPEASED = "dactyl_appeased"
PEBBLE_PURIFIED_VATS = "pebble_purified_vats"
STAFF_SHATTERED = "staff_shattered"
EGG_HATCHED = "egg_hatched"
COAL_LIT = "coal_lit"
RECKLESS_TAP_TRAP = "reckless_tap_trap"
STORM_ACTIVE = "storm_active"
SHELTER_REACHED = "shelter_reached"
BOAT_BOARDED = "boat_boarded"
WRAITH_CAPTURED = "wraith_captured"
SWAMPMAN_APPEASED = "swampman_appeased"
QUEST_WON = "quest_won"

ALL_FLAGS = [
    SNAKE_UNCURLED, CHEST_OPENED, PARCHMENT_READABLE, BEAST_CAPTURED,
    BEAST_RIDDEN, VILLAGER_GAVE_STAFF, COLUMN_CRACKED, STONE_AWAKENED,
    CASTLE_STONES_PARTED, SAGE_TOUCHED, MEMORY_RESTORED, MEDIAN_HINT_ACTIVE, DACTYL_APPEASED,
    PEBBLE_PURIFIED_VATS, STAFF_SHATTERED, EGG_HATCHED, COAL_LIT,
    RECKLESS_TAP_TRAP, STORM_ACTIVE, SHELTER_REACHED, BOAT_BOARDED,
    WRAITH_CAPTURED, SWAMPMAN_APPEASED, QUEST_WON,
]


def initial_flags() -> dict:
    return {name: False for name in ALL_FLAGS}
