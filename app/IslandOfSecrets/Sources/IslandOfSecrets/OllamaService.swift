import Foundation

/// Minimal client for a local Ollama server's /api/chat endpoint
/// (https://localhost:11434 by default -- Ollama's own default bind).
/// Deliberately just this one method: send system+user, get back the
/// assistant's text. Model name is passed in per-call rather than fixed,
/// so the UI's model picker (see ContentView.swift) can switch between
/// the author's installed models without any code change here.
enum OllamaError: Error {
    case badResponse
    case emptyContent
}

enum OllamaService {
    private struct ChatMessage: Encodable {
        let role: String
        let content: String
    }
    private struct ChatOptions: Encodable {
        let temperature: Double
    }
    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
        let options: ChatOptions?
    }
    private struct ChatResponseMessage: Decodable {
        let content: String
    }
    private struct ChatResponse: Decodable {
        let message: ChatResponseMessage
    }

    /// Base URL for the local Ollama server. Overridable via the
    /// OLLAMA_HOST environment variable (matches Ollama's own convention)
    /// for the rare case it's not running on the default port.
    static var baseURL: URL {
        if let override = ProcessInfo.processInfo.environment["OLLAMA_HOST"],
           let url = URL(string: override.hasPrefix("http") ? override : "http://\(override)") {
            return url
        }
        return URL(string: "http://localhost:11434")!
    }

    /// `temperature`: nil uses the model's own default (good for narration
    /// and hints, where some variety is welcome); pass 0 for tasks that
    /// need strict, repeatable format-following -- e.g. CommandTranslator
    /// asking for exactly two codes and nothing else -- since a lower
    /// temperature makes small local models noticeably more likely to
    /// actually follow that instruction instead of answering in prose.
    static func chat(model: String, system: String, user: String, timeout: TimeInterval = 45, temperature: Double? = nil) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        let body = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: system),
                ChatMessage(role: "user", content: user),
            ],
            stream: false,
            options: temperature.map { ChatOptions(temperature: $0) }
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OllamaError.badResponse
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let text = decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OllamaError.emptyContent }
        return text
    }
}
