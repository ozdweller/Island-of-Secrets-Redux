"""
Initial item placement for a fresh 2.0 game.

Source: not guessed. Derived by actually running the repo's verified
`engine/basic_interpreter.py` against `listing.bas` up through its own
init routine (GOSUB 2820) and dumping the resulting L()/F() arrays --
see the design-conversation notes in docs/2.0-A_RULE_SCHEMA.md. Two
corrections vs. that document's earlier prose (the doc guessed from
captions before this trace existed; this table is the ground truth):

- The snake (item 40) and the apple (item 1) both start in room 45
  ("A Clearing In The Trees By A Rickety Shack"), not room 44
  (Grandpa's Shack itself). Room 45 is the approach to the shack; you
  meet the snake there, before you can reach the chest at 44.
- The polished coal (item 13) starts already placed in room 80 ("A
  Hollow Chamber Many Metres In Diameter"), at the far end of the
  Bluewood Stumps -- behind the Swampman's blockade, not revealed by
  cracking the marble column. Cracking the column (see rules.py) only
  reveals the marble chip (item 12) and the fracture itself (item 27).

`hidden=True` means a search()/examine() of the room is needed before
the item shows up in a plain look -- same spirit as the original's
F(I)>=1 "not yet noticed" state, collapsed to a plain boolean since the
distinction between the original's several >=1 values (1 vs 9) was a
BASIC-internal implementation detail, not a meaningful design signal.
"""

from __future__ import annotations

# item_id -> (room_id, hidden)
INITIAL_ITEM_LOCATIONS: dict[int, tuple[int, bool]] = {
    1: (45, True),    # A Shiny Apple -- with the snake
    2: (46, False),   # A Fossilised Egg -- Dactyl's nest
    3: (71, True),    # A Lily Flower -- Heart of the Lilies
    4: (41, False),   # An Earthenware Jug
    5: (44, True),    # A Dirty Old Rag -- in Grandpa's Shack, needs the chest
    6: (21, True),    # A Ragged Parchment -- Snelm's Inner Chamber
    7: (27, True),    # A Flickering Torch
    8: (15, True),    # A Glistening Pebble -- at the Speaking Stone's room.
                       # Revealed by RUB STONE (not SAY), while carrying
                       # the rag -- confirmed-code + empirically verified,
                       # see rules.py's _handle_rub.
    9: (53, False),   # A Woodman's Axe
    10: (62, False),  # A Coil Of Rope
    11: (75, True),   # A Rugged Staff -- Petrified Village, needs the villager
    12: (58, True),   # A Chip Of Marble -- Marble Column, needs cracking open
    13: (80, False),  # A Polished Coal -- Bluewood Stumps, past the Swampman
    14: (67, True),   # A Piece Of Flint -- the Pyramid
    15: (44, True),   # A Geologist's Hammer -- Grandpa's Shack, needs the chest
    16: (5, False),   # A Wild Canyon Beast -- the corral
    17: (44, True),   # A Grain Loaf
    18: (42, False),  # A Juicy Melon -- the split-log table
    19: (60, False),  # Some Biscuits -- Adobe Hut
    20: (21, False),  # A Growth Of Mushrooms -- Snelm's Inner Chamber
    21: (44, True),   # A Bottle Of Water
    22: (42, False),  # A Flagon Of Wine -- the split-log table
    23: (77, True),   # A Flowing Sap
    24: (13, False),  # A Sparkling Freshwater Spring
    25: (33, False),  # The Boatman -- the log pier
    26: (44, False),  # A Strapped Oak Chest -- Grandpa's Shack
    27: (58, True),   # A Fracture In The Column -- revealed by cracking it
    28: (15, True),   # A Mouth-Like Opening -- the Speaking Stone's own room
    29: (51, True),   # An Open Trapdoor -- refuse storeroom
    30: (75, False),  # A Parched, Dessicated Villager -- Petrified Village
    31: (41, False),  # A Still Of Bubbling Green Liquor -- Log settlement
    32: (78, False),  # A Tough Skinned Swampman -- Village of Hollow Stumps
    33: (71, False),  # The Sage Of The Lilies -- Heart of the Lilies
    34: (50, False),  # Wall After Wall Of Evil Books -- the Library
    35: (77, False),  # A Number Of Softer Roots
    36: (23, True),   # the living storm -- starts near the player
    37: (19, False),  # Malevolent Wraiths -- Edge of the Well
    38: (10, False),  # His Dreaded Cloak Of Entropy -- Omegan's Sanctum
    39: (10, False),  # Omegan The Evil One -- Omegan's Sanctum
    40: (45, False),  # An Immense Snake -- with the apple
    41: (42, False),  # A Group Of Aggressive Logmen -- the split-log table
    42: (38, False),  # The Ancient Scavenger -- "A Chamber Inches Deep With Dust"
    43: (38, True),   # Median -- same room as the Scavenger, hidden until revealed
}
