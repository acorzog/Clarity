import Foundation

/// Drives the embedded "Ask AI" box inside `MonthInsightsDetailView` — orchestrates the *existing*
/// Ask Clarity pipeline (`AskClarityEngine`/`AskClarityEngine+SemanticFallback`), scoped to one
/// specific month, rather than a second AI integration. No new prompt, no new network call shape,
/// no new API key handling: `AnthropicClaritySemanticProvider` (and its key-reading, via
/// `CategorizationService.sanitizedAPIKey`) is reused exactly as `AskClarityView` already uses it.
///
/// A plain `@MainActor` class (not inline `@State` in the view) so this orchestration — including
/// the "was this AI-assisted" distinction below — is unit-testable without SwiftUI, matching how
/// `AskClarityFullPipelineTests` already tests the engine directly with stub providers.
@MainActor
final class MonthAskClarityController: ObservableObject {
    /// One answered question — `answer`'s headline/supportingDetail are always calculator output
    /// (`BudgetCalculator`/`ExplainMyMonthCalculator`/`OverviewCalculator` etc., via
    /// `AskClarityExecutor`); Claude is never in the path that produces a number. `wasAIAssisted`
    /// is `true` only when the fully-local, deterministic interpreter found no signal at all in
    /// the question and Claude's semantic fallback classified it instead — see
    /// `AskClarityEngine+SemanticFallback.swift`'s own doc comment. Surfaced in the UI so an
    /// AI-assisted *interpretation* of the question is never presented as indistinguishable from a
    /// purely local one, even though both ultimately answer with the same kind of calculated fact.
    struct AnsweredQuestion: Identifiable, Equatable {
        let id = UUID()
        let question: String
        let answer: AskClarityAnswer
        let wasAIAssisted: Bool
    }

    @Published private(set) var answered: AnsweredQuestion?
    @Published private(set) var isAsking = false

    private let semanticProvider: AskClaritySemanticProviding
    private let callBudget: AskClaritySemanticCallBudget
    private var sessionContext = AskClaritySessionContext.empty

    init(
        semanticProvider: AskClaritySemanticProviding = AnthropicClaritySemanticProvider(),
        callBudget: AskClaritySemanticCallBudget = AskClaritySemanticCallBudget()
    ) {
        self.semanticProvider = semanticProvider
        self.callBudget = callBudget
    }

    /// Resolves "this month"/"today"/"last week" and every other date-relative Ask Clarity phrase
    /// against `month` instead of the device's real current date — reusing the `today: Date`
    /// parameter every Ask Clarity entry point already accepts for exactly this purpose, rather
    /// than mutating a parsed `AskClarityQuery` after the fact (which would need its own copy of
    /// the interpreter/semantic-fallback dispatch to apply consistently to both paths). Anchored to
    /// the real `.now` whenever `month` already *is* the real current month, so "today"/"yesterday"
    /// keep their ordinary meaning while browsing the live month — only overridden for a past month
    /// someone navigated back to from this screen's own month selector.
    static func anchorDate(for month: Date, now: Date = .now, calendar: Calendar = .current) -> Date {
        guard !calendar.isDate(month, equalTo: now, toGranularity: .month) else { return now }
        let start = Date.startOfMonth(for: month, calendar: calendar)
        return calendar.date(byAdding: .day, value: 14, to: start) ?? start
    }

    /// Ignored while a question is already in flight or the trimmed text is empty — a single
    /// explicit submit is the only thing that ever triggers a call here, never a view re-render, so
    /// this can't become a "re-ask on every layout pass" cost center.
    func ask(
        _ text: String,
        month: Date,
        entries: [Entry],
        budgets: [Budget],
        headCategories: [HeadCategory],
        settings: BudgetCalculationSettings
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAsking else { return }

        isAsking = true
        defer { isAsking = false }

        let today = Self.anchorDate(for: month)

        // Computed first, synchronously and at zero cost (pure local arithmetic over data already
        // in memory) — purely to know, after the real call below, whether the final answer needed
        // Claude at all. Mirrors exactly what `respondWithSemanticFallback` already checks
        // internally (`isUnrecognizedLocally`); this doesn't duplicate *how* that's decided, only
        // reads the same public predicate against a second, otherwise-identical local pass.
        let localOnly = AskClarityEngine.respond(
            to: trimmed, context: sessionContext, entries: entries, budgets: budgets,
            headCategories: headCategories, settings: settings, today: today
        )
        let localFoundNothing = AskClarityEngine.isUnrecognizedLocally(localOnly.answer)

        let result = await AskClarityEngine.respondWithSemanticFallback(
            to: trimmed, context: sessionContext, entries: entries, budgets: budgets,
            headCategories: headCategories, settings: settings, today: today,
            semanticProvider: semanticProvider, callBudget: callBudget
        )

        sessionContext = result.updatedContext
        answered = AnsweredQuestion(
            question: trimmed,
            answer: result.answer,
            // Only "AI-assisted" if Claude's fallback actually changed the outcome — a provider
            // failure, missing API key, or exhausted call budget all silently return the exact same
            // local answer (see `respondWithSemanticFallback`), which must not be mislabeled as
            // AI-assisted just because the local pass alone came up empty.
            wasAIAssisted: localFoundNothing && result.answer != localOnly.answer
        )
    }

    func reset() {
        answered = nil
        sessionContext = .empty
    }
}
