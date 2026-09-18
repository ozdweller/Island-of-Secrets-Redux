import Foundation

/// Phase 7.7 -- "immersive rejects." Fires only as the last of three
/// tiers on a rejected command: (1) the real two-word parser already
/// failed, (2) CommandTranslator (7.5) also failed to find any real
/// engine action the input could plausibly mean -- so there is genuinely
/// no in-game effect for whatever the player typed. Rather than leaving
/// the engine's blunt "WHAT!"/"YOU CAN'T ..." text on screen, ask the
/// model for a short in-world reaction instead. See BUILD_PLAN.md's
/// Phase 7.7 note and the "ground, don't generate" principle in
/// docs/LLM_ENRICHMENT_PLAN.md.
///
/// Safety property this whole feature leans on: by the time this runs,
/// the *engine* has already decided nothing happens -- this only asks
/// the model to narrate that "nothing" more gracefully, never to decide
/// whether something happens. The prompt is written to make that
/// non-negotiable: describe the attempt, but never claim a new item, a
/// new exit, a revealed secret, or any state change, since the actual
/// game state genuinely has not moved and next turn's real engine
/// response would immediately contradict a reply that implied otherwise.
///
/// If this call fails or times out, ContentView leaves the engine's
/// original reject text on screen rather than retrying or blocking --
/// that's the agreed fallback (see BUILD_PLAN.md), not a bug.
enum ImprovService {
    private static let systemPrompt = """
        You are narrating a text adventure. The player just attempted an \
        action that the game does not model in any way -- nothing about \
        the world, their inventory, or their status has changed because \
        of it, and nothing will. Your only job is to write ONE short, \
        in-world reaction to what they tried (1-2 sentences, same voice \
        as the room narration you're given for context).

        Hard rules, because the next turn's real game state will \
        immediately contradict anything you invent here:
        - Never say or imply that anything was found, revealed, opened, \
          given, taken, learned, or changed. The world is exactly as it \
          was before the player tried this.
        - Never introduce a new object, exit, character, or fact that \
          isn't already in the context you're given.
        - Don't just flatly say "nothing happens" or "you can't do \
          that" either -- describe the attempt itself briefly and let \
          the reader infer nothing came of it.
        - Don't restate the room description you're given as context --\
          it's for tone and grounding only.
        - Keep it brief. This is a beat, not a scene.
        """

    static func respond(playerInput: String, context: NarrationContext, model: String) async -> String? {
        let userPrompt = """
            \(context.promptBody())

            The player just typed: "\(playerInput)"

            This has no effect on the game in any way. Write the short \
            in-world reaction described above.
            """
        guard let raw = try? await OllamaService.chat(
            model: model, system: systemPrompt, user: userPrompt, timeout: 20
        ) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
