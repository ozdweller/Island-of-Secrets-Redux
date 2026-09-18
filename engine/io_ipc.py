"""IPC I/O adapter for the BASIC interpreter -- speaks line-delimited JSON
on stdout and reads line-delimited JSON (or plain text) commands on stdin,
so a native front end (the SwiftUI app) can drive the engine as a
subprocess without scraping ANSI terminal text.

Protocol (one JSON object per line):

  Engine -> UI, emitted right before every INPUT prompt:
    {"type": "turn", "text": "<everything printed since the last turn>",
     "room": <int>, "time": <int>, "strength": <float>, "wisdom": <float>,
     "food": <int>, "drink": <int>, "inventory": [<item id>, ...],
     "room_objects": [<item/character id currently in this room>, ...]}

  Engine -> UI, emitted once at startup/shutdown/error:
    {"type": "error", "message": "..."}

  UI -> Engine, one per line on stdin:
    {"cmd": "TAKE APPLE"}
  (a bare plain-text line with no JSON is also accepted, for quick manual
  testing with `nc`/`echo` -- it's treated as the command verbatim)
"""

import json
import os
import sys


class IpcIO:
    def __init__(self, save_path, interp_ref):
        self.col = 0
        self.save_path = save_path
        self._interp = interp_ref  # set after Interpreter() construction
        self.output_buf = []

    def print(self, text):
        self.output_buf.append(text)
        self.col += len(text) if '\n' not in text else 0

    def println(self, text=''):
        self.print(text)
        self.print('\n')
        self.col = 0

    def tab(self, col):
        if col <= self.col:
            self.println('')
        self.print(' ' * max(0, col - self.col))

    def cursor_col(self):
        return self.col

    def cls(self):
        if self.col != 0:
            self.println('')

    def _emit_turn(self):
        text = ''.join(self.output_buf)
        self.output_buf = []
        interp = self._interp[0]
        # L(I) = current location of object I; 81 is the "carried by the
        # player" sentinel (see docs/semantics.md). Index 0 is unused
        # (BASIC arrays here are 1-indexed).
        locations = interp.num_arrays.get('L', [])
        inventory = [i for i, loc in enumerate(locations) if i > 0 and loc == 81]
        room = interp.num_vars.get('R')
        # Phase 7.1: objects/characters (indices 1-43) currently located in
        # this room -- same technique as `inventory` above (L(I) is the
        # object's location; 81 means carried), just filtered to "here"
        # instead of "carried". Read-only addition to this IO adapter only;
        # basic_interpreter.py itself is untouched, so this can't change
        # game logic, only what the UI is told about state it already has.
        room_objects = [i for i, loc in enumerate(locations) if i > 0 and loc == room]
        msg = {
            "type": "turn",
            "text": text,
            "room": room,
            "time": interp.num_vars.get('L'),
            "strength": interp.num_vars.get('Y'),
            "wisdom": interp.num_vars.get('X'),
            "food": interp.num_vars.get('F'),
            "drink": interp.num_vars.get('G'),
            "inventory": inventory,
            "room_objects": room_objects,
        }
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()

    def input(self, prompt=''):
        self._emit_turn()
        line = sys.stdin.readline()
        if line == '':
            # stdin closed -- treat as QUIT so the game exits its own way
            return "QUIT"
        line = line.strip()
        if not line:
            return ""
        try:
            obj = json.loads(line)
            if isinstance(obj, dict) and 'cmd' in obj:
                return str(obj['cmd']).strip().upper()
        except (json.JSONDecodeError, TypeError):
            pass
        return line.upper()

    def save(self, records):
        with open(self.save_path, 'w') as f:
            json.dump(records, f)
        self.println("(saved)")

    def load(self):
        if not os.path.exists(self.save_path):
            return []
        with open(self.save_path) as f:
            return json.load(f)
