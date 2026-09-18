import Foundation

/// Loads `data/rooms.json` once and exposes the canonical room description
/// text by id -- same pattern as ItemsData.swift. This is the *only*
/// ground-truth room text NarrationService is allowed to treat as fact;
/// see NarrationContext.swift.
enum RoomsData {
    private struct Room: Decodable {
        let id: Int
        let description: String
    }

    static let descriptions: [Int: String] = {
        guard let root = ProjectPaths.findProjectRoot() else { return [:] }
        let url = root.appendingPathComponent("data/rooms.json")
        guard let data = try? Data(contentsOf: url),
              let rooms = try? JSONDecoder().decode([Room].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: rooms.map { ($0.id, $0.description) })
    }()

    static func description(for id: Int) -> String {
        descriptions[id] ?? "an unknown place"
    }
}
