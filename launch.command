#!/bin/bash
# Island of Secrets -- launch script.
#
# Double-click this file in Finder (it'll open in Terminal automatically),
# or run `./launch.command` from a terminal in this folder. Pops up a
# native "Classic" / "Cyber" choice; Cyber starts (or confirms) a local
# Ollama server before launching the app with LLM enrichment switched on.
#
# Deliberately no `set -e` here: `swift run` exits with a non-zero status
# whenever the app is closed via the window's Close/red-dot button (or
# Cmd+Q) rather than returning 0, since macOS tears the process down via a
# signal rather than a clean return -- that's a normal quit, not a script
# failure, and this is invoked directly by an Automator "Run Shell Script"
# action, so treating it as fatal surfaces a scary error dialog on every
# ordinary exit. Only the explicit checks below (python3/swift missing,
# or the project directory itself missing) are treated as real errors.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! cd "$DIR/app/IslandOfSecrets" 2>/dev/null; then
    echo "Couldn't find app/IslandOfSecrets next to this script."
    echo "Make sure launch.command hasn't been moved out of the Island folder."
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

# --- Mode picker -----------------------------------------------------
# A native dialog, not a Terminal prompt, since this is normally launched
# by double-clicking in Finder with no terminal the person is already
# looking at. "Quit" is the cancel button, so dismissing the dialog (or
# pressing Esc/Cmd+.) exits cleanly instead of falling through.
CHOICE=$(osascript <<'APPLESCRIPT' 2>/dev/null
display dialog "How would you like to play Island of Secrets?" ¬
    buttons {"Quit", "Classic", "Cyber (LLM Enriched)"} ¬
    default button "Cyber (LLM Enriched)" ¬
    cancel button "Quit" ¬
    with title "Island of Secrets" ¬
    with icon note
return button returned of result
APPLESCRIPT
)

if [ -z "$CHOICE" ]; then
    # osascript unavailable, or the dialog was cancelled/closed -- treat
    # either as "just quit" rather than guessing a mode for them.
    echo "No mode selected -- exiting."
    exit 0
fi

case "$CHOICE" in
    Classic)
        MODE="classic"
        ;;
    "Cyber (LLM Enriched)")
        MODE="cyber"
        ;;
    *)
        echo "No mode selected -- exiting."
        exit 0
        ;;
esac

echo "Mode: $MODE"
echo

# --- Cyber mode: make sure a local Ollama is actually reachable ------
# Checked in order of what actually matters: is the server already
# answering requests? That's the only thing Cyber mode needs, regardless
# of whether the `ollama` CLI happens to be on this script's PATH. Only
# fall back to "is the CLI available to start it ourselves" if the server
# isn't already up, and only report "not installed" if neither is true.
if [ "$MODE" = "cyber" ]; then
    if ollama_is_up; then
        echo "Ollama is already running at $OLLAMA_HOST_URL."
    elif ! command -v ollama >/dev/null 2>&1; then
        osascript <<'APPLESCRIPT' >/dev/null 2>&1
display dialog "Cyber mode needs Ollama, but nothing's answering at localhost:11434 and the ollama command isn't on this script's PATH." & return & return & ¬
    "If Ollama is already running elsewhere, set OLLAMA_HOST before launching, or install it from https://ollama.com." & return & return & ¬
    "Continuing in Classic mode for now." ¬
    buttons {"OK"} default button "OK" with title "Island of Secrets" with icon caution
APPLESCRIPT
        echo "No server at $OLLAMA_HOST_URL, and ollama not found on PATH -- continuing in Classic mode."
        MODE="classic"
    else
        echo "Starting Ollama..."
        nohup ollama serve >/tmp/island-ollama.log 2>&1 &
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
            osascript <<'APPLESCRIPT' >/dev/null 2>&1
display dialog "Ollama didn't start within 20 seconds." & return & return & ¬
    "Check /tmp/island-ollama.log, or start it yourself with \"ollama serve\" and relaunch." & return & return & ¬
    "Continuing in Classic mode for now." ¬
    buttons {"OK"} default button "OK" with title "Island of Secrets" with icon caution
APPLESCRIPT
            echo "Ollama didn't come up in time -- continuing in Classic mode. See /tmp/island-ollama.log."
            MODE="classic"
        fi
    fi

    if [ "$MODE" = "cyber" ]; then
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
fi
echo

export ISLAND_MODE="$MODE"

echo "Building Island of Secrets (the first run may take a minute)..."
echo
swift run
run_status=$?

echo
if [ "$run_status" -ne 0 ]; then
    echo "Island of Secrets has exited (quitting the app window normally shows up here as a non-zero status -- that's expected, not a build problem)."
else
    echo "Island of Secrets has exited."
fi
if [ "$STARTED_OLLAMA" = "1" ]; then
    echo "(Ollama was started by this script for Cyber mode and is still running in the"
    echo " background -- that's normal, other apps can use it too. \`killall ollama\`"
    echo " if you want to stop it.)"
fi
read -n 1 -s -r -p "Press any key to close this window..."
echo
