import AppKit
import SwiftUI

/// Looks up room and character illustrations from the shared `art/`
/// folder at the repo root -- the same folder and the same PNGs the
/// Classic app's own `RoomArt.swift` already reads (see that file's
/// docstring: "a swappable folder that lives alongside the game data,
/// entirely separate from the app itself"). 2.0 deliberately does not
/// copy or fork these images into `Island 2.0/`: `data/rooms.json` is
/// already shared as-is between the two apps per the project's
/// standing rule, and the art (generated for Phase 5 of the Classic
/// app, closely inspired by the original book's Patrick Lynch
/// paintings) is exactly the same kind of shared, reused-unchanged
/// asset -- one file on disk, one place to redraw a piece that needs
/// fixing, both apps pick it up automatically. `ProjectPaths2.
/// findProjectRoot()` resolves to the same repo root `RoomArt.swift`
/// uses, so `root/art/rooms/<id>.png` here is the exact same file
/// `root/art/rooms/<id>.png` is there.
///
/// Every room and character portrait was reviewed against `docs/
/// ART_CLUES.md` and the original book references before this was
/// wired in (see that doc and `docs/2.0-A_RULE_SCHEMA.md` for the
/// findings) -- a handful of rooms and two character portraits are
/// flagged there as needing a redraw. Nothing here excludes them:
/// the whole point of reading straight from the shared folder by a
/// fixed filename is that a corrected `art/rooms/44.png` (say) shows
/// up automatically the next time this app runs, no code change
/// needed, exactly like the Classic app's own Phase 5 workflow.
enum RoomArt2 {
    static func roomImage(for room: Int) -> NSImage? {
        guard let root = ProjectPaths2.findProjectRoot() else { return nil }
        return loadImage(root, "art/rooms/\(room)")
    }

    static func characterImage(slug: String) -> NSImage? {
        guard let root = ProjectPaths2.findProjectRoot() else { return nil }
        return loadImage(root, "art/characters/\(slug)")
    }

    /// Grandpa's map -- read from the same shared `art/` folder as the
    /// Classic app's RoomArt.mapImage(); see this file's own header
    /// comment for why 2.0 reads that folder directly rather than
    /// copying assets into its own tree.
    static func mapImage() -> NSImage? {
        guard let root = ProjectPaths2.findProjectRoot() else { return nil }
        return loadImage(root, "art/Grandpa's map")
    }

    /// Tries `<base>.jpg` first (the shipped, compressed art) then
    /// `<base>.png` (for anyone dropping in their own lossless art).
    private static func loadImage(_ root: URL, _ base: String) -> NSImage? {
        for ext in ["jpg", "png"] {
            let url = root.appendingPathComponent("\(base).\(ext)")
            if let img = NSImage(contentsOf: url) { return img }
        }
        return nil
    }
}

/// Mirrors `data/characters.json`'s `id`/`name`/`object_id`/`room_id`
/// fields (kept as a small static table rather than parsed from JSON
/// at runtime, since this is display-only lookup data, not game
/// state -- the rule engine's own copy of that file remains the
/// single source of truth for anything that affects gameplay). Two
/// entries (`speaking-stone`, `dactyl`) have no `object_id` -- they
/// are room features, not objects in the noun table -- so presence is
/// keyed on `roomID` instead, exactly as `data/characters.json`'s own
/// comment describes.
struct CharacterArt2 {
    let slug: String
    let name: String
    let objectID: Int?
    let roomID: Int?

    static let all: [CharacterArt2] = [
        CharacterArt2(slug: "boatman", name: "The Boatman", objectID: 25, roomID: nil),
        CharacterArt2(slug: "omegan", name: "Omegan", objectID: 39, roomID: nil),
        CharacterArt2(slug: "speaking-stone", name: "Speaking Stone", objectID: nil, roomID: 15),
        CharacterArt2(slug: "swampman", name: "Swampman", objectID: 32, roomID: nil),
        CharacterArt2(slug: "logmen", name: "The Logmen", objectID: 41, roomID: nil),
        CharacterArt2(slug: "median", name: "Median", objectID: 43, roomID: nil),
        CharacterArt2(slug: "scavenger", name: "The Scavenger", objectID: 42, roomID: nil),
        CharacterArt2(slug: "sage-of-the-lilies", name: "Sage of the Lilies", objectID: 33, roomID: nil),
        CharacterArt2(slug: "dactyl", name: "Dactyl", objectID: nil, roomID: 46),
        CharacterArt2(slug: "canyon-beast", name: "Canyon Beast", objectID: 16, roomID: nil),
    ]

    /// Characters visibly present this turn -- either their object id
    /// is among `roomObjects` (the items/characters `shell_ipc.py`
    /// reports as here right now) or, for the two room-bound entries,
    /// the player is simply in their room.
    static func present(roomObjects: [Int], room: Int) -> [CharacterArt2] {
        all.filter { character in
            if let objectID = character.objectID {
                return roomObjects.contains(objectID)
            }
            if let roomID = character.roomID {
                return room == roomID
            }
            return false
        }
    }
}
