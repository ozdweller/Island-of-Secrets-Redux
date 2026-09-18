import Foundation

/// Loads `data/vocab.json`'s verb/noun prefix-code tables and glosses them
/// with human-readable words, for Phase 7.5's natural-language input
/// assist. The parser (listing.bas line ~240-260) matches on the first 3
/// characters of a typed word against these codes -- so as long as
/// whatever we send starts with the right 3 letters, spelling out the
/// rest doesn't matter. `verbGloss`/directionNounGloss below are Claude's
/// best-effort reconstruction of the full words from
/// docs/semantics.md's subroutine index and the book's own captions
/// (e.g. SCR -> SCRATCH lines up exactly with the Sage of the Lilies'
/// "irritation on her back" hint) -- confident, but not verified against
/// the listing's actual PRINT strings the way the noun table below is.
/// That's fine: correctness only depends on the 3-letter *code* being
/// sent to the engine, never on the gloss being exactly right -- a wrong
/// gloss is a cosmetic risk, not a game-logic one.
enum VocabData {
    private struct VocabFile: Decodable {
        let verbs: [String]
        let nouns: [String]
    }

    private static let file: VocabFile = {
        guard let root = ProjectPaths.findProjectRoot() else {
            return VocabFile(verbs: [], nouns: [])
        }
        let url = root.appendingPathComponent("data/vocab.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(VocabFile.self, from: data) else {
            return VocabFile(verbs: [], nouns: [])
        }
        return decoded
    }()

    /// code -> best-guess full verb word, in listing order (verb index
    /// 1-42). N??/S??/E??/W?? are the bare single-word direction verbs;
    /// GO? takes a direction noun as its second word.
    static let verbGloss: [String: String] = [
        "N??": "NORTH", "S??": "SOUTH", "E??": "EAST", "W??": "WEST",
        "GO?": "GO", "GET": "GET", "TAK": "TAKE", "GIV": "GIVE",
        "DRO": "DROP", "LEA": "LEAVE", "EAT": "EAT", "DRI": "DRINK",
        "RID": "RIDE", "OPE": "OPEN", "PIC": "PICK", "CHO": "CHOP",
        "CHI": "CHIP", "TAP": "TAP", "BRE": "BREAK", "FIG": "FIGHT",
        "STR": "STRIKE", "ATT": "ATTACK", "HIT": "HIT", "KIL": "KILL",
        "SWI": "SWIM", "SHE": "SHELTER", "HEL": "HELP", "SCR": "SCRATCH",
        "CAT": "CATCH", "RUB": "RUB", "POL": "POLISH", "REA": "READ",
        "EXA": "EXAMINE", "FIL": "FILL", "SAY": "SAY", "WAI": "WAIT",
        "RES": "REST", "WAV": "WAVE", "INF": "INFO", "XLO": "XLOAD",
        "XSA": "XSAVE", "QUI": "QUIT",
    ]

    /// The 8 direction words at the end of the noun table (positions
    /// 44-51, after the 43 item-indexed nouns).
    static let directionNounGloss: [String: String] = [
        "NOR": "NORTH", "SOU": "SOUTH", "EAS": "EAST", "WES": "WEST",
        "UP?": "UP", "DOW": "DOWN", "IN?": "IN", "OUT": "OUT",
    ]

    static var verbCodes: [String] { file.verbs }

    /// Confirmed by direct position cross-check against data/items.json:
    /// vocab.json's noun list is items 1-43 in order, then the 8
    /// direction words, then a "???" sentinel -- so noun code at array
    /// index i (0-based) is item id i+1's code.
    static func nounCode(forItemID id: Int) -> String? {
        guard id >= 1, id <= file.nouns.count else { return nil }
        return file.nouns[id - 1]
    }

    /// A human-readable gloss for a noun code -- item name (via
    /// ItemsData) if it's one of the 43 objects/characters, else a
    /// direction word, else the raw code as a last resort.
    static func nounGloss(forItemID id: Int) -> String {
        ItemsData.name(for: id)
    }
}
