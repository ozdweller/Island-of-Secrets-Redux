import Foundation

/// Phase 7.5 -- optional natural-language input assist. Only ever invoked
/// after the *real* two-word parser has already rejected the player's
/// exact input (see ContentView's miss detection, which matches the three
/// literal reject messages the listing itself produces: "MOST ACTIONS
/// NEED TWO WORDS", "WHAT!", and "YOU CAN'T ..." -- see listing.bas lines
/// 290/300/310). The fast path -- anything that already matches
/// vocab.json -- never touches this at all, so a player who already knows
/// the two-word syntax sees zero added latency.
///
/// Deliberately constrained to choose only from the *exact* verb/noun
/// codes it's given (visible objects in the current room + inventory,
/// plus the 8 direction words) -- never asked to invent a word, so the
/// worst case for a bad translation is just another "YOU CAN'T", exactly
/// as if the player had mistyped it themselves. This can't corrupt game
/// state; it can only occasionally under- or over-translate a phrase.
enum CommandTranslator {
    struct Translation {
        let verbCode: String
        let nounCode: String
        /// Friendly reconstruction for display in the transcript, e.g.
        /// "TAKE APPLE" -- cosmetic only. The actual command sent to the
        /// engine is the raw codes, which is all that has to be correct.
        var displayCommand: String
        var engineCommand: String { "\(verbCode) \(nounCode)" }
    }

    /// Few-shot examples matter a lot here: small local models frequently
    /// ignore a bare "respond with only X" instruction and answer in a
    /// full sentence instead (e.g. "You should TAKE THE APPLE" instead of
    /// "TAK APP"). Showing the exact shape a couple of times measurably
    /// improves format-following for 7-8B class models. Paired with
    /// temperature 0 below and the tolerant word-scan parser (rather than
    /// a strict "first two tokens" split), this is meant to degrade
    /// gracefully even when a model doesn't comply perfectly.
    private static let systemPrompt = """
        You translate a player's free-text adventure-game command into the \
        exact two-word code the game's parser understands. You will be \
        given a list of valid VERB codes and a list of valid NOUN codes \
        (only objects/characters actually present right now, plus \
        directions). Respond with ONLY the two codes separated by a \
        single space -- nothing else, no explanation, no punctuation, no \
        restating the player's input.

        Examples:
        Player typed: "pick up the apple" -> TAK APP
        Player typed: "head north" -> GO? NOR
        Player typed: "eat the loaf of bread" -> EAT LOA

        Choose codes EXACTLY from the lists given -- never invent one. If \
        nothing in the lists reasonably matches what the player meant, \
        respond with exactly: NOMATCH
        """

    static func translate(playerInput: String, visibleItemIDs: [Int], model: String) async -> Translation? {
        let verbLines = VocabData.verbCodes
            .map { "\($0) = \(VocabData.verbGloss[$0] ?? $0)" }
            .joined(separator: "\n")

        var nounEntries: [(code: String, gloss: String)] = visibleItemIDs.compactMap { id in
            guard let code = VocabData.nounCode(forItemID: id) else { return nil }
            return (code, VocabData.nounGloss(forItemID: id))
        }
        for (code, gloss) in VocabData.directionNounGloss {
            nounEntries.append((code, gloss))
        }
        guard !nounEntries.isEmpty else { return nil }
        let nounLines = nounEntries.map { "\($0.code) = \($0.gloss)" }.joined(separator: "\n")

        let userPrompt = """
            Player typed: "\(playerInput)"

            Valid VERB codes:
            \(verbLines)

            Valid NOUN codes (only what's actually here right now):
            \(nounLines)

            Respond with the two codes, e.g. "TAK APP", or NOMATCH.
            """

        guard let raw = try? await OllamaService.chat(
            model: model, system: systemPrompt, user: userPrompt, timeout: 20, temperature: 0
        ) else {
            return nil
        }

        guard !raw.uppercased().contains("NOMATCH") else { return nil }

        // Tolerant parse: scan every "word" in the response in order
        // (after stripping surrounding punctuation models love to add --
        // quotes, backticks, trailing periods) for the first one whose
        // first 3 letters match a valid verb code, then continue scanning
        // *after* that word for the first match against a visible noun
        // code. This copes with a model answering in a full sentence
        // ("I think you should TAKE the APPLE.") as well as the terse
        // format actually asked for.
        // Deliberately does NOT include "?" -- five of our own valid codes
        // (N??, S??, E??, W??, GO?, UP?, IN?) use it as a literal padding
        // character from the original BASIC's fixed-3-char scheme (see
        // listing.bas line 230), so stripping it would break exactly the
        // codes the few-shot examples above teach the model to produce.
        let punctuation = CharacterSet(charactersIn: "\"'`.,!():;")
        let words = raw.uppercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: punctuation) }
            .filter { !$0.isEmpty }

        var verbCode: String?
        var verbWordIndex = -1
        for (i, word) in words.enumerated() {
            let prefix = String(word.prefix(3))
            if VocabData.verbCodes.contains(prefix) {
                verbCode = prefix
                verbWordIndex = i
                break
            }
        }
        guard let matchedVerb = verbCode else { return nil }

        var nounCode: String?
        if verbWordIndex + 1 <= words.count {
            for word in words[(verbWordIndex + 1)...] {
                let prefix = String(word.prefix(3))
                if nounEntries.contains(where: { $0.code == prefix }) {
                    nounCode = prefix
                    break
                }
            }
        }
        guard let matchedNoun = nounCode else { return nil }

        let verbWord = VocabData.verbGloss[matchedVerb] ?? matchedVerb
        let nounWord = nounEntries.first(where: { $0.code == matchedNoun })?.gloss ?? matchedNoun
        return Translation(verbCode: matchedVerb, nounCode: matchedNoun, displayCommand: "\(verbWord) \(nounWord)")
    }

    /// The three literal reject strings the listing itself produces for
    /// "parser didn't understand this at all" (as opposed to "understood
    /// but that object isn't here," which is a different, legitimate
    /// response -- see listing.bas line 1080 -- and shouldn't trigger a
    /// translation attempt, since translating won't fix that).
    static func looksLikeParserMiss(_ text: String) -> Bool {
        let upper = text.uppercased()
        return upper.contains("MOST ACTIONS NEED TWO WORDS")
            || upper.contains("WHAT!")
            || upper.contains("YOU CAN'T ")
    }
}
