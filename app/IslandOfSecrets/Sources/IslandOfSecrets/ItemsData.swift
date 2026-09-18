import Foundation

/// Loads `data/items.json` once and exposes a simple id -> display name
/// lookup, so the inventory panel can show something nicer than a bare
/// number. Falls back gracefully (an empty dictionary) if the file can't
/// be found or parsed -- the inventory panel just shows icons without
/// labels in that case, nothing crashes.
enum ItemsData {
    private struct Item: Decodable {
        let id: Int
        let name: String
    }

    static let names: [Int: String] = {
        guard let root = ProjectPaths.findProjectRoot() else { return [:] }
        let url = root.appendingPathComponent("data/items.json")
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([Item].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.name) })
    }()

    static func name(for id: Int) -> String {
        names[id] ?? "Item \(id)"
    }
}
