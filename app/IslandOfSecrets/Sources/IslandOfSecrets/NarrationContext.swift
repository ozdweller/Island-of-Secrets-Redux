import Foundation

/// Phase 7.2 -- the bounded fact set an LLM prompt is allowed to see for
/// one room's narration. Deliberately built from nothing but what
/// GameEngine already publishes (itself sourced only from io_ipc.py's
/// per-turn JSON) plus the transcribed book lore -- never anything from
/// basic_interpreter.py's internals, DATA tables, or solution logic. See
/// docs/LLM_ENRICHMENT_PLAN.md Phase 7.2/7.3.
///
/// Pure and synchronous by design so it's cheaply testable without any
/// network access: given a fixed room/roomObjects/inventory/history, the
/// assembled context is deterministic.
struct NarrationContext {
    let roomID: Int
    let canonicalRoomText: String
    let placeLore: String?
    let charactersHere: [LoreCharacter]
    let newlyUnlockedStory: [StoryPanel]
    let recentTranscript: [String]
    let time: Int
    let strength: Double
    let wisdom: Double

    /// Stable key for NarrationService's cache: two turns that would
    /// produce the same context should reuse the same generated text
    /// rather than paying for a fresh call.
    var cacheKey: String {
        let charIDs = charactersHere.map(\.id).sorted().joined(separator: ",")
        let panelIDs = newlyUnlockedStory.map { String($0.panel) }.sorted().joined(separator: ",")
        return "room\(roomID)|chars:\(charIDs)|panels:\(panelIDs)"
    }

    static func assemble(
        room: Int,
        roomObjects: [Int],
        recentTranscript: [String],
        time: Int,
        strength: Double,
        wisdom: Double,
        lore: LoreStore,
        previouslyUnlockedStoryPanelIDs: Set<Int>
    ) -> NarrationContext {
        let charactersHere = LoreData.characters.filter { character in
            if let oid = character.objectID { return roomObjects.contains(oid) }
            if let rid = character.roomID { return rid == room }
            return false
        }
        let newlyUnlocked = lore.unlockedStory.filter { !previouslyUnlockedStoryPanelIDs.contains($0.panel) }

        return NarrationContext(
            roomID: room,
            canonicalRoomText: RoomsData.description(for: room),
            placeLore: LoreData.places[room],
            charactersHere: charactersHere,
            newlyUnlockedStory: newlyUnlocked,
            recentTranscript: Array(recentTranscript.suffix(3)),
            time: time,
            strength: strength,
            wisdom: wisdom
        )
    }

    /// Renders this context as the plain-text user-message body for the
    /// narration prompt. Kept as simple labelled lines rather than JSON --
    /// small local models follow plain prose instructions more reliably
    /// than they parse structured data.
    func promptBody() -> String {
        var lines: [String] = []
        lines.append("Current room (canonical, verbatim -- describe this and nothing else): \(canonicalRoomText)")
        if let lore = placeLore {
            lines.append("Book lore for this room: \(lore)")
        }
        if !charactersHere.isEmpty {
            lines.append("Characters present in this room right now:")
            for c in charactersHere {
                lines.append("- \(c.name): \(c.bookCaption)")
            }
        }
        if !newlyUnlockedStory.isEmpty {
            lines.append("The player just learned this piece of the backstory for the first time -- you may weave it in briefly if natural, but don't over-explain it:")
            for panel in newlyUnlockedStory {
                lines.append("- \(panel.text)")
            }
        }
        if !recentTranscript.isEmpty {
            lines.append("Recent game transcript, for continuity of tone only (do not restate it):")
            lines.append(recentTranscript.joined(separator: "\n"))
        }
        lines.append("Player status -- time remaining: \(time), strength: \(Int(strength)), wisdom: \(Int(wisdom)).")
        return lines.joined(separator: "\n")
    }
}
