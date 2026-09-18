import Foundation

/// Phase 7.6 -- on-demand, opt-in hints. Deliberately built from the same
/// bounded fact set as narration (NarrationContext) and nothing else --
/// it never sees basic_interpreter.py's internals, DATA tables, or
/// solution logic, so it's structurally incapable of being a walkthrough
/// lookup. It reasons the same way a human re-reading the book would:
/// from the room, what's visibly here, and the book's own captions/lore.
///
/// Rate-limited from the UI side (see ContentView's hint cooldown) so
/// this stays a nudge rather than a crutch, matching the book's own
/// design philosophy (p.4: "the computer will not tell you all you need
/// to know... you will need to look at the pictures too").
@MainActor
final class HintService: ObservableObject {
    @Published private(set) var isLoading = false
    @Published var currentHint: String?
    @Published private(set) var lastError: String?

    private static let systemPrompt = """
        You give a single, gentle hint for a player stuck in "Island of \
        Secrets," a 1983 text adventure. You will be given only the \
        player's current room, what's visible there, and background lore \
        they've already been told. You do NOT know the actual puzzle \
        solutions or the game's internal logic -- reason only from the \
        facts given, the way a player re-reading their guidebook would.

        Hard rules:
        - One or two sentences, no more.
        - Suggest a direction to think in (an object to look at more \
          closely, a character's stated motive worth acting on) -- never \
          a flat command to type, and never a definitive "the answer is X."
        - Never invent facts, items, or characters not given to you.
        - If you don't have enough information to say anything useful, \
          say so plainly rather than guessing at a mechanic.
        """

    func requestHint(context: NarrationContext, model: String) {
        isLoading = true
        lastError = nil
        currentHint = nil
        let body = context.promptBody() + "\n\nThe player is stuck and asked for a hint. Give one."

        Task {
            do {
                let text = try await OllamaService.chat(model: model, system: Self.systemPrompt, user: body, timeout: 30)
                self.currentHint = text
            } catch {
                self.lastError = "Local model unavailable (\(error.localizedDescription))."
            }
            self.isLoading = false
        }
    }
}
