#!/usr/bin/env python3
"""
Island of Secrets -- IPC entry point for the SwiftUI shell (Phase 4).

Identical game logic to play.py (same interpreter, same verified listing);
the only difference is the I/O adapter. This one speaks line-delimited
JSON on stdout/stdin (see io_ipc.py's docstring for the protocol) instead
of raw terminal text, so a native app can drive it as a subprocess.
"""

import argparse
import os
import sys
import json

sys.path.insert(0, os.path.dirname(__file__))

from basic_interpreter import Interpreter, BasicError
from io_ipc import IpcIO

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(HERE)
LISTING_PATH = os.path.join(PROJECT_ROOT, 'listing.bas')
SAVE_PATH = os.path.join(PROJECT_ROOT, 'data', 'savegame.json')


def main():
    # --save-path lets the SwiftUI shell redirect saves outside the app
    # bundle (e.g. to ~/Library/Application Support) when running from a
    # packaged .app -- Contents/Resources isn't a sensible place to write
    # a running app's state. Defaults to the original in-repo location so
    # `swift run`/dev usage is unchanged.
    parser = argparse.ArgumentParser()
    parser.add_argument('--save-path', default=SAVE_PATH)
    args = parser.parse_args()
    save_path = args.save_path
    os.makedirs(os.path.dirname(os.path.abspath(save_path)), exist_ok=True)

    with open(LISTING_PATH, encoding='utf-8') as f:
        source = f.read()

    interp_holder = [None]
    io = IpcIO(save_path, interp_holder)
    interp = Interpreter(source, io)
    interp_holder[0] = interp

    try:
        interp.run_from(10)
    except BasicError as e:
        sys.stdout.write(json.dumps({
            "type": "error",
            "message": f"[engine error] {e} at line {interp.pc}, statement #{interp.stmt_i}",
        }) + "\n")
        sys.stdout.flush()
        raise
    except KeyboardInterrupt:
        pass
    finally:
        sys.stdout.write(json.dumps({"type": "gameover"}) + "\n")
        sys.stdout.flush()


if __name__ == '__main__':
    main()
