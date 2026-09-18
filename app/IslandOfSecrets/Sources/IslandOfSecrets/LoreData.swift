import Foundation

/// A reveal condition from data/characters.json or data/lore.json's
/// "reveal_after" field. Three shapes, matched against whichever key is
/// present: {"always": true}, {"any_room_visited": [ids]}, or
/// {"seen_object": true | <id>} -- true means "this entry's own object_id",
/// an explicit id means "this specific object_id" (used by story panels,
/// which have no object_id of their own). See docs/BOOK_LORE.md and
/// data/lore.json's top comment for the full reasoning.
struct RevealCondition: Decodable {
    var always: Bool?
    var anyRoomVisited: [Int]?
    var seenOwnObject: Bool?
    var seenObjectID: Int?

    private enum CodingKeys: String, CodingKey {
        case always
        case anyRoomVisited = "any_room_visited"
        case seenObject = "seen_object"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        always = try c.decodeIfPresent(Bool.self, forKey: .always)
        anyRoomVisited = try c.decodeIfPresent([Int].self, forKey: .anyRoomVisited)
        if let asInt = try? c.decodeIfPresent(Int.self, forKey: .seenObject) {
            seenObjectID = asInt
        } else if let asBool = try? c.decodeIfPresent(Bool.self, forKey: .seenObject) {
            seenOwnObject = asBool
        }
    }

    /// Evaluate against the player's accumulated history so far.
    /// `ownObjectID` is the character's own object_id, if any (used only
    /// when this condition is {"seen_object": true}).
    func isSatisfied(ownObjectID: Int?, ownRoomID: Int?, visitedRooms: Set<Int>, seenObjects: Set<Int>) -> Bool {
        if always == true { return true }
        if let rooms = anyRoomVisited, rooms.contains(where: visitedRooms.contains) { return true }
        if let roomID = ownRoomID, visitedRooms.contains(roomID) { return true }
        if seenOwnObject == true, let oid = ownObjectID, seenObjects.contains(oid) { return true }
        if let sid = seenObjectID, seenObjects.contains(sid) { return true }
        return false
    }
}

struct LoreCharacter: Decodable, Identifiable {
    let id: String
    let name: String
    let objectID: Int?
    let roomID: Int?
    let portrait: String
    let bookCaption: String
    let storyRole: String
    let revealAfter: RevealCondition

    private enum CodingKeys: String, CodingKey {
        case id, name, portrait
        case objectID = "object_id"
        case roomID = "room_id"
        case bookCaption = "book_caption"
        case storyRole = "story_role"
        case revealAfter = "reveal_after"
    }
}

struct StoryPanel: Decodable, Identifiable {
    var id: Int { panel }
    let panel: Int
    let text: String
    let revealAfter: RevealCondition

    private enum CodingKeys: String, CodingKey {
        case panel, text
        case revealAfter = "reveal_after"
    }
}

/// Loads data/characters.json and data/lore.json once, alongside the same
/// project-root-relative pattern ItemsData.swift already uses for
/// data/items.json. Falls back to empty collections if either file is
/// missing or fails to parse -- the Lore codex just shows nothing extra in
/// that case, same "never crash, degrade gracefully" posture as the rest
/// of this app's data loaders.
enum LoreData {
    private struct CharactersFile: Decodable { let characters: [LoreCharacter] }
    private struct LoreFile: Decodable {
        let story: [StoryPanel]
        let places: [String: String]
    }

    static let characters: [LoreCharacter] = {
        guard let root = ProjectPaths.findProjectRoot() else { return [] }
        let url = root.appendingPathComponent("data/characters.json")
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CharactersFile.self, from: data) else {
            return []
        }
        return file.characters
    }()

    static let story: [StoryPanel] = {
        guard let root = ProjectPaths.findProjectRoot() else { return [] }
        let url = root.appendingPathComponent("data/lore.json")
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(LoreFile.self, from: data) else {
            return []
        }
        return file.story.sorted { $0.panel < $1.panel }
    }()

    /// Room-keyed book prose (e.g. "Grandpa's Shack: Alphan's grandfather
    /// built this shack..."). Shown as a small caption under the
    /// illustration when the player is standing in a room the book had
    /// something to say about -- no network call, no gating needed, since
    /// it's just as safe to show as the room's own description text.
    static let places: [Int: String] = {
        guard let root = ProjectPaths.findProjectRoot() else { return [:] }
        let url = root.appendingPathComponent("data/lore.json")
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(LoreFile.self, from: data) else {
            return [:]
        }
        var result: [Int: String] = [:]
        for (key, value) in file.places {
            if let roomID = Int(key) { result[roomID] = value }
        }
        return result
    }()

    static func portraitImage(for character: LoreCharacter) -> Data? {
        guard let root = ProjectPaths.findProjectRoot() else { return nil }
        let url = root.appendingPathComponent(character.portrait)
        return try? Data(contentsOf: url)
    }
}
