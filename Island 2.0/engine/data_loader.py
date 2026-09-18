"""
Loads the shared, reused-unchanged world data: rooms, items, characters,
lore. These are the repo's existing `data/*.json` files -- 2.0-B reads
them at runtime and never copies or modifies them, per the project's
"the current app stays exactly as it is" rule (docs/ISLAND2_PLAN.md).

Layout on disk: <repo-root>/Island 2.0/engine/data_loader.py, and the
shared data lives at <repo-root>/data/*.json -- two directories up from
this file's `Island 2.0/` folder.
"""

from __future__ import annotations

import json
import os

from models import Item, ItemCategory, Room

# Island 2.0/engine/ -> Island 2.0/ -> <repo root>
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_REPO_ROOT = os.path.abspath(os.path.join(_THIS_DIR, "..", ".."))


def _data_dir(repo_root: str | None) -> str:
    return os.path.join(repo_root or DEFAULT_REPO_ROOT, "data")


def load_rooms(repo_root: str | None = None) -> dict:
    path = os.path.join(_data_dir(repo_root), "rooms.json")
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
    return {r["id"]: Room(id=r["id"], description=r["description"], exits=r["exits"]) for r in raw}


def load_items(repo_root: str | None = None) -> dict:
    path = os.path.join(_data_dir(repo_root), "items.json")
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
    return {
        i["id"]: Item(id=i["id"], name=i["name"], category=ItemCategory(i["category"]))
        for i in raw
    }


def load_characters(repo_root: str | None = None) -> list:
    path = os.path.join(_data_dir(repo_root), "characters.json")
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
    return raw.get("characters", [])


def load_lore(repo_root: str | None = None) -> dict:
    path = os.path.join(_data_dir(repo_root), "lore.json")
    with open(path, encoding="utf-8") as f:
        return json.load(f)
