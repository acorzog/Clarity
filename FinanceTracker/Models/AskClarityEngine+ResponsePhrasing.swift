import Foundation

// Kept in its own file, out of the `FinanceTrackerWidgets` target, for the same reason as
// `AskClarityEngine+SemanticFallback.swift`: this is a network-reaching piece of Ask Clarity, and a
// widget extension has no chat UI to call it from in the first place.

extension AskClarityEngine {
    /// Optionally rewords an already-fully-verified `Result` (from `respond(to:...)` or
    /// `respondWithSemanticFallback`, it doesn't matter which produced it) into more natural
    /// wording — purely a presentation pass. `Planner`/`Executor`/the calculators have already run
    /// and finished by the time this is ever called; this function cannot add, remove, or recompute
    /// a single figure, because `AskClarityPhrasingProviding` is never given anything to compute
    /// from in the first place (see `AskClarityPhrasingContext` — just the answer's own display
    /// text and the user's question, never a transaction or `Category` object).
    ///
    /// Every candidate rephrasing is checked by `AskClarityPhrasingFidelity.preservesFacts` before
    /// it is ever used — a provider failure (network/timeout/malformed reply) *or* a candidate that
    /// fails that check for any reason (a changed number, a dropped category name, an
    /// "insufficient data" answer that gained a figure) falls back to `result` completely
    /// unchanged. `followUpSuggestions`, `hasSufficientData`, and `comparisonIsFavorable` are never
    /// sent to the provider and are always carried over from `result` verbatim — the wording layer
    /// has no way to invent a capability Clarity doesn't have.
    ///
    /// `callBudget`, if supplied, is consulted and incremented exactly like it is for
    /// `respondWithSemanticFallback` — the same session-wide cap on Claude usage applies regardless
    /// of which of the two purposes (interpretation or phrasing) is spending it, so callers that
    /// want a single combined budget across both should pass the same instance to each.
    static func phrasedNaturally(
        _ result: Result,
        question: String,
        phrasingProvider: AskClarityPhrasingProviding,
        callBudget: AskClaritySemanticCallBudget? = nil
    ) async -> Result {
        guard callBudget?.hasRemainingCalls ?? true else { return result }
        callBudget?.recordCall()

        let context = AskClarityPhrasingContext(
            question: question,
            headline: result.answer.headline,
            supportingDetail: result.answer.supportingDetail,
            hasSufficientData: result.answer.hasSufficientData
        )

        guard let candidate = await phrasingProvider.phrase(context: context) else { return result }
        guard AskClarityPhrasingFidelity.preservesFacts(context: context, candidate: candidate) else { return result }

        let rephrasedAnswer = AskClarityAnswer(
            headline: candidate.headline,
            supportingDetail: candidate.supportingDetail,
            hasSufficientData: result.answer.hasSufficientData,
            followUpSuggestions: result.answer.followUpSuggestions,
            comparisonIsFavorable: result.answer.comparisonIsFavorable
        )
        return Result(answer: rephrasedAnswer, updatedContext: result.updatedContext)
    }
}
