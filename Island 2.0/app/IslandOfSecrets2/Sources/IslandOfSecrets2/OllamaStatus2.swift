import Foundation

/// A lightweight pre-flight check against the local Ollama server,
/// run before Start actually launches `shell_ipc.py` (which is the
/// thing that really talks to Ollama -- 2.0's Swift side never calls
/// it directly, unlike the Classic app's OllamaService.swift). Own
/// copy of the Classic app's OllamaStatus.swift, same reasoning as
/// ProjectPaths2.swift for why it isn't shared code.
///
/// Since 2.0 *requires* Ollama (it's not an optional add-on the way
/// Classic's Enriched narration is), a downloaded .app with no
/// `launch.command` wrapper to pre-flight this would otherwise let a
/// player press Start and just watch nothing happen. ContentView2.swift
/// surfaces the result as a plain-language alert instead, with a
/// "Start Anyway" escape hatch in case this check itself is wrong (a
/// custom OLLAMA_HOST reachable from Python but not from here, say).
enum OllamaCheckResult2: Equatable {
    case ok
    /// Nothing answered at all -- Ollama isn't installed, or isn't running.
    case notRunning
    /// Ollama answered, but the requested model isn't in its pulled list.
    case modelMissing
}

enum OllamaStatus2 {
    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    /// Matches Ollama's own OLLAMA_HOST convention -- same override
    /// `shell_ipc.py`/Ollama itself would respect, so this checks the
    /// same server the subprocess is actually about to talk to.
    private static var baseURL: URL {
        if let override = ProcessInfo.processInfo.environment["OLLAMA_HOST"],
           let url = URL(string: override.hasPrefix("http") ? override : "http://\(override)") {
            return url
        }
        return URL(string: "http://localhost:11434")!
    }

    static func check(model: String, timeout: TimeInterval = 3) async -> OllamaCheckResult2 {
        let url = baseURL.appendingPathComponent("api/tags")
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
            let base = model.split(separator: ":").first.map(String.init) ?? model
            if names.contains(where: { $0 == base || $0.hasPrefix("\(base):") }) { return .ok }
            return .modelMissing
        } catch {
            return .notRunning
        }
    }
}
