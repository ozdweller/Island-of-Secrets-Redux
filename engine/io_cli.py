"""Terminal I/O adapter for the BASIC interpreter -- keeps the interpreter
itself free of any actual console/file concerns."""

import json
import os


class CliIO:
    def __init__(self, save_path):
        self.col = 0
        self.save_path = save_path

    def print(self, text):
        # emulate a screen ~40 cols wide (matches the era) for TAB/POS math,
        # but don't actually wrap terminal output -- just track column.
        import sys
        sys.stdout.write(text)
        sys.stdout.flush()
        if '\n' in text:
            self.col = len(text) - text.rfind('\n') - 1
        else:
            self.col += len(text)

    def println(self, text=''):
        self.print(text)
        self.print('\n')
        self.col = 0

    def tab(self, col):
        # Standard classic-BASIC TAB() behaviour: if the target column is at
        # or behind the current cursor position, wrap to a new line first,
        # then pad out to that column.
        if col <= self.col:
            self.println('')
        self.print(' ' * (col - self.col))

    def cursor_col(self):
        return self.col

    def cls(self):
        # keep scrollback in a terminal rather than actually clearing --
        # the game prints its own dashed divider (G$) right after most CLS
        # calls, so just make sure we're at a fresh line and let that be
        # the visual separator (avoids doubling up on dashes).
        if self.col != 0:
            self.println('')

    def input(self, prompt=''):
        if prompt:
            self.print(prompt)
        try:
            line = input()
        except EOFError:
            line = "QUIT"
        self.col = 0
        return line.strip().upper()

    def save(self, records):
        with open(self.save_path, 'w') as f:
            json.dump(records, f)
        self.println("(saved)")

    def load(self):
        if not os.path.exists(self.save_path):
            return []
        with open(self.save_path) as f:
            return json.load(f)
