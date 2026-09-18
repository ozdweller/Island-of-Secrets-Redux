#!/usr/bin/env python3
"""
Island of Secrets -- native port.

Runs the verified BASIC listing (source/listing.bas) through a small
purpose-built interpreter (basic_interpreter.py), so the game logic is the
original logic, not a hand re-derivation of it. See docs/semantics.md for
how the listing's cryptic variables/subroutines were reverse-engineered,
and BUILD_PLAN.md for where this sits in the overall project.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

from basic_interpreter import Interpreter, BasicError
from io_cli import CliIO

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(HERE)
LISTING_PATH = os.path.join(PROJECT_ROOT, 'listing.bas')
SAVE_PATH = os.path.join(PROJECT_ROOT, 'data', 'savegame.json')


def main():
    with open(LISTING_PATH, encoding='utf-8') as f:
        source = f.read()

    io = CliIO(SAVE_PATH)
    interp = Interpreter(source, io)

    try:
        interp.run_from(10)
    except BasicError as e:
        print(f"\n[engine error] {e}", file=sys.stderr)
        print(f"  at line {interp.pc}, statement #{interp.stmt_i}", file=sys.stderr)
        raise
    except KeyboardInterrupt:
        print("\n(interrupted)")


if __name__ == '__main__':
    main()
