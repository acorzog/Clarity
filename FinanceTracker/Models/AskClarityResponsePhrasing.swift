import Foundation

// MARK: - Response phrasing
//
// An optional, LLM-backed *wording* layer for "Ask Clarity" — consulted only after
// `AskClarityPlanner`/`AskClarityExecutor` have already produced a fully verified `AskClarityAnswer`
// (see `AskClarityEngine.phrasedNaturally`). This layer never computes anything: it takes the
// answer's own already-correct text and asks a provider to say the same thing more naturally, then
// mechanically verifies (`AskClarityPhrasingFidelity`) that every number, and every category-like
// proper noun, in the original is still present in the rephrasing before ever using it — any
// mismatch, and the original deterministic wording is used instead. Nothing here can change *what*
// the answer is, only *how it reads*.

/// What a phrasing provider needs to reword one already-verified answer — literally just that
/// answer's own text fields plus the user's original question. Never a transaction, `Category`
/// object, budget, or any other raw financial data; never even the underlying `AskClarityPlan` —
/// only the two strings a user would already see on screen, which is all a wording pass needs.
struct AskClarityPhrasingContext: Equatable {
    let question: String
    let headline: String
    let supportingDetail: String
    let hasSufficientData: Bool
}

/// A candidate rephrasing before it's been checked for fidelity — mirrors the two text fields of
/// `AskClarityAnswer` it would replace. Never used directly; always passed through
/// `AskClarityPhrasingFidelity.preservesFacts` first.
struct AskClarityPhrasedResponse: Equatable {
    let headline: String
    let supportingDetail: String
}

/// Abstraction over "reword an already-verified answer more naturally" — kept as a protocol for the
/// same reason `AskClaritySemanticProviding` is: the concrete provider (Anthropic, see
/// `AnthropicClaritySemanticProvider`) can be swapped or stubbed in tests without touching
/// `AskClarityEngine`. Implementations must never throw past this boundary (fail safe: return
/// `nil`) and must never retry internally.
protocol AskClarityPhrasingProviding {
    func phrase(context: AskClarityPhrasingContext) async -> AskClarityPhrasedResponse?
}

// MARK: - Fidelity validation

/// The actual guarantee behind "the LLM can never change a financial value": every numeric token
/// (amount, percentage, plain count) present in the verified source text must be present, unchanged,
/// in the candidate rephrasing — and the candidate must introduce no numeric token the source didn't
/// already have. A category/head-category name (or month, or any other capitalized word the
/// deterministic wording already used) must also survive into the candidate — dropping or renaming
/// one fails the check exactly like dropping or altering a number does. Nothing here is a matter of
/// LLM trust: this is ordinary string comparison run on every candidate before it is ever shown to
/// a user, and any provider — Anthropic or otherwise — is held to the identical rule.
enum AskClarityPhrasingFidelity {
    /// Words a candidate is always allowed to add that happen to be capitalized (sentence-initial
    /// pronouns, common conversational openers) — excluded from the "must-preserve" proper-noun set
    /// so ordinary rephrasing isn't penalized for capitalizing "You" or starting a new sentence.
    /// This is a stoplist for what counts as "the source's own proper nouns," not for what a
    /// candidate is allowed to contain.
    private static let properNounStopWords: Set<String> = [
        "You", "Your", "Yours", "I", "No", "Yes", "That", "This", "It", "Its", "Today", "Yesterday",
        "The", "A", "An", "So", "But", "And", "Looks", "Here", "There", "What", "How", "Data"
    ]

    static func preservesFacts(context: AskClarityPhrasingContext, candidate: AskClarityPhrasedResponse) -> Bool {
        let trimmedHeadline = candidate.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHeadline.isEmpty else { return false }

        let sourceText = context.headline + " " + context.supportingDetail
        let candidateText = candidate.headline + " " + candidate.supportingDetail

        // Every number must survive, unchanged, and no new one may appear — this is the hard
        // guarantee "preserve every factual value exactly" maps to in code.
        guard numericTokens(in: sourceText) == numericTokens(in: candidateText) else { return false }

        // An "insufficient data" answer must never gain a number — the fidelity check enforces
        // this explicitly rather than relying on it as an accident of the set-equality rule above
        // (both sets happen to already be empty in every real case, but this states the invariant
        // directly: the limitation must be preserved, never quietly filled in).
        if !context.hasSufficientData {
            guard numericTokens(in: candidateText).isEmpty else { return false }
        }

        // Every category-like proper noun the deterministic wording used must still be present —
        // catches a dropped or renamed category exactly like the numeric check catches a changed
        // amount. One-directional on purpose: the candidate may add its *own* capitalized words
        // (a sentence-initial "You", etc.) without being penalized for it.
        let sourceProperNouns = properNounTokens(in: sourceText)
        let candidateWords = wordTokens(in: candidateText)
        guard sourceProperNouns.isSubset(of: candidateWords) else { return false }

        // Conciseness — a rephrasing that's ballooned far past the original isn't "concise."
        // Generous enough that short answers ("No spending logged this weekend.") aren't penalized
        // for a normal one-sentence expansion, but still catches a genuinely runaway reply.
        guard candidateText.count <= max(400, sourceText.count * 3) else { return false }

        return true
    }

    /// Extracts every run of digits (allowing embedded `.`/`,` thousands/decimal separators, but
    /// never a leading/trailing one) as its own token — "165,00" and "38" from "165,00 €" and "38%"
    /// stay distinct, glued-together European-style figures like "1.234,56" stay one token, and
    /// surrounding punctuation/currency symbols never leak into the comparison.
    static func numericTokens(in text: String) -> Set<String> {
        var tokens = Set<String>()
        var current = ""
        for char in text {
            if char.isNumber {
                current.append(char)
            } else if (char == "." || char == ","), !current.isEmpty, current.last?.isNumber == true {
                current.append(char)
            } else {
                if let last = current.last, last.isNumber {
                    tokens.insert(current)
                }
                current = ""
            }
        }
        if let last = current.last, last.isNumber {
            tokens.insert(current)
        }
        return tokens
    }

    static func wordTokens(in text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !$0.isLetter && $0 != "&" }).map(String.init))
    }

    static func properNounTokens(in text: String) -> Set<String> {
        wordTokens(in: text).filter { word in
            guard let first = word.first, first.isUppercase, word.count >= 3 else { return false }
            return !properNounStopWords.contains(word)
        }
    }
}
