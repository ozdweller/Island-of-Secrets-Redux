import Foundation
import Combine

/// Tracks what the player has actually encountered -- rooms visited and
/// objects/characters seen in them -- and, from that, which story panels
/// and character bios have "unlocked". This is the in-app replacement for
/// "keep the book alongside you as you play" (book p.4): a digital codex
/// that reveals itself at the same pace the printed book's illustrations
/// would have, rather than dumping all 43 objects' worth of lore on turn
/// one.
///
/// Deliberately reads nothing from the Python interpreter beyond what
/// GameEngine already publishes (room + roomObjects + inventory, all from
/// io_ipc.py's per-turn JSON) -- this is a pure UI-side accumulator, no
/// engine access, no new game logic. See docs/LLM_ENRICHMENT_PLAN.md
/// Phase 7.4.
final class LoreStore: ObservableObject {
    @Published private(set) var visitedRooms: Set<Int> = []
    @Published private(set) var seenObjects: Set<Int> = []

    @Published private(set) var unlockedStory: [StoryPanel] = []
    @Published private(set) var metCharacters: [LoreCharacter] = []

    private let allStory = LoreData.story
    private let allCharacters = LoreData.characters

    /// Call this whenever GameEngine's room/roomObjects/inventory change.
    /// Cheap and idempotent -- safe to call every turn.
    func record(room: Int, roomObjects: [Int], inventory: [Int]) {
        guard room != 0 else { return }
        var changed = visitedRooms.insert(room).inserted
        for id in roomObjects where seenObjects.insert(id).inserted { changed = true }
        for id in inventory where seenObjects.insert(id).inserted { changed = true }
        guard changed else { return }
        recompute()
    }

    private func recompute() {
        unlockedStory = allStory.filter {
            $0.revealAfter.isSatisfied(ownObjectID: nil, ownRoomID: nil, visitedRooms: visitedRooms, seenObjects: seenObjects)
        }
        metCharacters = allCharacters.filter {
            $0.revealAfter.isSatisfied(ownObjectID: $0.objectID, ownRoomID: $0.roomID, visitedRooms: visitedRooms, seenObjects: seenObjects)
        }
    }

    var lockedStoryCount: Int { allStory.count - unlockedStory.count }
    var lockedCharacterCount: Int { allCharacters.count - metCharacters.count }
}
