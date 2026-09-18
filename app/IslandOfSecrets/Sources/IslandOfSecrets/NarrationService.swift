import Foundation

/// Phase 7.3 -- turns a NarrationContext into a richer paragraph via a
/// local Ollama model, additively: GameEngine's classic transcript text is
/// never touched or replaced, this only ever supplies a second, optional
/// block of prose the UI can choose to show alongside it (see
/// ContentView.swift's narrationPanel). Any failure -- Ollama not running,
/// timeout, bad response -- just leaves the panel empty; gameplay is never
/// blocked on this.
@MainActor
final class NarrationService: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var currentText: String?
    @Published private(set) var currentRoomID: Int?
    @Published private(set) var lastError: String?

    private var cache: [String: String]
    private var activeTask: Task<Void, Never>?
    private let cacheURL: URL?

    /// The house style, lifted straight from docs/ART_BRIEF.md's own notes
    /// for the room paintings, so narration prose and illustrations read
    /// as one consistent world rather than two different tones.
    private static let systemPrompt = """
        You are the narrator for "Island of Secrets," a 1983 text adventure \
        being lightly re-illustrated in prose. You will be given a fixed set \
        of facts about the player's current situation. Write one short, \
        atmospheric paragraph (3-5 sentences) describing the scene.

        Hard rules, no exceptions:
        - Use ONLY the facts you are given. Never invent an exit, item, \
          character, sound, smell, or plot detail that isn't stated.
        - Never contradict the canonical room text you're given -- expand \
          on it, don't replace or reinterpret it.
        - Never state or hint at a puzzle solution.
        - Do not address the player as "you" doing game-UI things (no \
          "you can go north" style text) -- this is scene-setting prose, \
          not instructions.

        Style: watercolour-and-ink illustrated storybook tone. Warm, \
        slightly desaturated palette in forest/canyon areas (ochre, \
        rust-orange, dusty green); cooler slate-blue and violet for \
        castle/pyramid/night scenes. Lighting is moody, end-of-day or \
        overcast, with dramatic skies. Nothing clean or heroic-fantasy --
        weathered and a little uncanny, matching a children's adventure \
        book from the early 1980s.
        """

    init() {
        if let root = ProjectPaths.findProjectRoot() {
            cacheURL = root.appendingPathComponent("data/narration_cache.json")
        } else {
            cacheURL = nil
        }
        if let url = cacheURL, let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode([String: String].self, from: data) {
            cache = loaded
        } else {
            cache = [:]
        }
    }

    /// Kicks off narration for this context, cancelling any still-running
    /// request for a previous room first. Cache hits resolve instantly
    /// with no network call.
    func narrate(context: NarrationContext, model: String) {
        activeTask?.cancel()
        currentRoomID = context.roomID
        lastError = nil

        // Model is part of the cache key -- different models produce
        // different prose, so switching models in the picker shouldn't
        // silently serve stale text from a previous model.
        let key = "\(model)|\(context.cacheKey)"

        if let cached = cache[key] {
            currentText = cached
            isLoading = false
            return
        }

        currentText = nil
        isLoading = true
        let body = context.promptBody()
        let roomID = context.roomID

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await OllamaService.chat(model: model, system: Self.systemPrompt, user: body)
                if Task.isCancelled { return }
                await MainActor.run {
                    self.cache[key] = text
                    self.saveCache()
                    // Only apply if we're still looking at the same room --
                    // avoids a slow response from an earlier room clobbering
                    // the current one if the player moved on quickly.
                    if self.currentRoomID == roomID {
                        self.currentText = text
                        self.isLoading = false
                    }
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    if self.currentRoomID == roomID {
                        self.isLoading = false
                        self.lastError = "Local model unavailable (\(error.localizedDescription)). Showing classic text only."
                    }
                }
            }
        }
    }

    private func saveCache() {
        guard let url = cacheURL, let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url)
    }
}
