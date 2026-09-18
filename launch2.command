#!/bin/bash
# Island of Secrets 2.0 -- launch script.
#
# Double-click this file in Finder (it'll open in Terminal automatically),
# or run `./launch2.command` from a terminal in this folder. Unlike
# launch.command (the Classic app, which offers a Classic/Cyber choice),
# 2.0 has no non-LLM mode to fall back to -- the LLM-narrated experience
# IS the app -- so there's no dialog here, just: check prerequisites,
# make sure Ollama is reachable if we can manage it, then run. Which
# model to use is picked from the app's own in-window dropdown once it's
# up, the same "Cyber" model list the Classic app offers.
#
# Deliberately no `set -e` here: `swift run` exits with a non-zero status
# whenever the app is closed via the window's Close/red-dot button (or
# Cmd+Q) rather than returning 0, since macOS tears the process down via a
# signal rather than a clean return -- that's a normal quit, not a script
# failure, and this may be invoked directly by an Automator "Run Shell
# Script" action, so treating it as fatal surfaces a scary error dialog
# on every ordinary exit. Only the explicit checks below (python3/swift
# missing, or the project directory itself missing) are treated as real
# errors.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! cd "$DIR/Island 2.0/app/IslandOfSecrets2" 2>/dev/null; then
    echo "Couldn't find \"Island 2.0/app/IslandOfSecrets2\" next to this script."
    echo "Make sure launch2.command hasn't been moved out of the Island folder."
    read -n 1 -s -r -p "Press any key to close this window..."
    echo
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found on your PATH."
    echo "Install Python 3 (macOS usually ships one, or via Homebrew: brew install python3) and try again."
    read -n 1 -s -r -p "Press any key to close this window..."
    echo
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "swift not found on your PATH."
    echo "Install Xcode or the Xcode Command Line Tools (xcode-select --install) and try again."
    read -n 1 -s -r -p "Press any key to close this window..."
    echo
    exit 1
fi

DEFAULT_NARRATION_MODEL="llama3.1:8b"
OLLAMA_HOST_URL="${OLLAMA_HOST:-http://localhost:11434}"
case "$OLLAMA_HOST_URL" in
    http*) : ;;
    *) OLLAMA_HOST_URL="http://$OLLAMA_HOST_URL" ;;
esac
STARTED_OLLAMA=0

# A double-clicked .command file gets launched by Finder/Automator with a
# minimal PATH (from /etc/paths, not your shell rc files) -- Homebrew's
# /opt/homebrew/bin (Apple Silicon) or /usr/local/bin (Intel), where the
# `ollama` CLI usually lives, is often missing from it even though the
# Ollama server itself is already running fine as a background/menu-bar
# process. So `command -v ollama` failing does NOT mean Ollama isn't
# installed or running -- only ollama_is_up (an actual request to the
# server) tells us that. We still widen PATH here so the CLI is usable
# below (e.g. to start the server ourselves) when it's genuinely needed.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/Applications/Ollama.app/Contents/Resources"

ollama_is_up() {
    curl -s -m 2 "$OLLAMA_HOST_URL/api/version" >/dev/null 2>&1
}

# --- Make sure a local Ollama is actually reachable -------------------
# 2.0's intent parser and narrator both need it every turn (see engine/
# intent.py and engine/narration.py) -- unlike the Classic app, there's
# no Classic-mode fallback that skips the LLM. The app itself still
# degrades gracefully turn-by-turn if Ollama drops mid-session (shell.py
# shows a plain "language model isn't responding" message rather than
# crashing), so a failure here is a warning, not a hard stop -- you can
# still launch and start Ollama yourself afterward.
if ollama_is_up; then
    echo "Ollama is already running at $OLLAMA_HOST_URL."
elif ! command -v ollama >/dev/null 2>&1; then
    osascript <<'APPLESCRIPT' >/dev/null 2>&1
display dialog "Island of Secrets 2.0 needs Ollama, but nothing's answering at localhost:11434 and the ollama command isn't on this script's PATH." & return & return & ¬
    "If Ollama is already running elsewhere, set OLLAMA_HOST before launching, or install it from https://ollama.com." & return & return & ¬
    "Launching anyway -- the app will tell you if it can't reach a model." ¬
    buttons {"OK"} default button "OK" with title "Island of Secrets 2.0" with icon caution
APPLESCRIPT
    echo "No server at $OLLAMA_HOST_URL, and ollama not found on PATH -- launching anyway."
else
    echo "Starting Ollama..."
    nohup ollama serve >/tmp/island2-ollama.log 2>&1 &
    STARTED_OLLAMA=1
    for i in $(seq 1 20); do
        if ollama_is_up; then
            break
        fi
        sleep 1
    done
    if ollama_is_up; then
        echo "Ollama is up at $OLLAMA_HOST_URL."
    else
        echo "Ollama didn't come up in time -- launching anyway. See /tmp/island2-ollama.log."
    fi
fi

if ollama_is_up; then
    HAS_DEFAULT=$(curl -s -m 3 "$OLLAMA_HOST_URL/api/tags" 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    names = {m.get('name', '') for m in data.get('models', [])}
    print('yes' if '$DEFAULT_NARRATION_MODEL' in names else 'no')
except Exception:
    print('unknown')
" 2>/dev/null)
    if [ "$HAS_DEFAULT" = "no" ]; then
        echo "Note: the default model ($DEFAULT_NARRATION_MODEL) isn't pulled yet."
        echo "Pick a model you already have from the in-app dropdown, or run:"
        echo "  ollama pull $DEFAULT_NARRATION_MODEL"
    fi
fi
echo

echo "Building Island of Secrets 2.0 (the first run may take a minute)..."
echo
swift run
run_status=$?

echo
if [ "$run_status" -ne 0 ]; then
    echo "Island of Secrets 2.0 has exited (quitting the app window normally shows up here as a non-zero status -- that's expected, not a build problem)."
else
    echo "Island of Secrets 2.0 has exited."
fi
if [ "$STARTED_OLLAMA" = "1" ]; then
    echo "(Ollama was started by this script and is still running in the background --"
    echo " that's normal, other apps can use it too. \`killall ollama\` if you want to stop it.)"
fi
read -n 1 -s -r -p "Press any key to close this window..."
echo
