import Foundation

/// A lightweight pre-flight check against the local Ollama server.
///
/// `launch.command` used to do this checking (and offer to start Ollama
/// itself) before the app ever opened -- see its own comments for why.
/// A downloaded, double-clicked .app skips that wrapper entirely, so
/// without this, Enriched narration would just silently show nothing
/// if Ollama isn't running or the chosen model isn't pulled, which is
/// fine for the author watching Console output but no help at all to
/// someone who downloaded a .dmg. ContentView.swift surfaces the result
/// as a plain-language alert instead.
enum OllamaCheckResult: Equatable {
    case ok
    /// Nothing answered at all -- Ollama isn't installed, or isn't running.
    case notRunning
    /// Ollama answered, but the requested model isn't in its pulled list.
    case modelMissing
}

enum OllamaStatus {
    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    static func check(model: String, timeout: TimeInterval = 3) async -> OllamaCheckResult {
        let url = OllamaService.baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return .notRunning
            }
            let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
            let names = Set(decoded.models.map { $0.name })
            if names.contains(model) { return .ok }
            // Ollama's own tag list often carries an explicit ":latest" (or
            // other tag) a player's own `ollama pull <name>` may not have
            // specified -- match on the base name too rather than
            // reporting "missing" over a tag-only mismatch.
            let base = model.split(separator: ":").first.map(String.init) ?? model
            if names.contains(where: { $0 == base || $0.hasPrefix("\(base):") }) { return .ok }
            return .modelMissing
        } catch {
            return .notRunning
        }
    }
}
