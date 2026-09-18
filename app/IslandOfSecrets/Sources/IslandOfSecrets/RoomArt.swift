import AppKit
import SwiftUI

/// Looks up room/item illustrations by ID from a swappable folder that
/// lives alongside the game data, entirely separate from the app itself --
/// so the art can be swapped or replaced without touching code. Drop
/// `<id>.jpg` or `<id>.png` files into these folders.
enum RoomArt {
    static func roomImage(for room: Int) -> NSImage? {
        guard let root = ProjectPaths.findProjectRoot() else { return nil }
        return loadImage(root, "art/rooms/\(room)")
    }

    static func itemImage(for item: Int) -> NSImage? {
        guard let root = ProjectPaths.findProjectRoot() else { return nil }
        return loadImage(root, "art/items/\(item)")
    }

    /// Grandpa's map -- a single reference image (not per-room/per-item
    /// art), kept directly under `art/` rather than in `art/rooms` or
    /// `art/items`. Summoned into its own window by the "Map" button in
    /// the status bar; see MapWindowController.
    static func mapImage() -> NSImage? {
        guard let root = ProjectPaths.findProjectRoot() else { return nil }
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
