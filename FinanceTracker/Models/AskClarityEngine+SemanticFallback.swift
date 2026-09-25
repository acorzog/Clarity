import Foundation

// Kept in its own file, out of the `FinanceTrackerWidgets` target (unlike every other Ask
// Clarity file, which the widget's spending-summary calculations already share) — this is the
// one part of Ask Clarity that reaches for the network, and a widget extension has no chat UI to
// call it from in the first place. `AskClarityEngine.swift` itself stays exactly as
// widget-compatible as it always was; this extension only adds to it.

extension AskClarityEngine {
    /// Augments the fully local, deterministic `respond(to:...)` with a semantic (LLM) fallback
    /// for the one case that pipeline can't answer at all — a question with no recognizable
    /// financial signal in it whatsoever (`isUnrecognizedLocally`). The deterministic interpreter
    /// always runs first, synchronously, at zero API cost; `semanticProvider` is only ever
    /// consulted when that produces literally nothing to work with, and at most once — this
    /// function contains no retry loop of its own. `callBudget`, if supplied, additionally caps
    /// how many semantic calls a whole session (not just this one question) is allowed to make.
    ///
    /// Every other local outcome — a real answer, "insufficient data," "no such category," a
    /// clarification request, an unsupported period — is left completely untouched: those are the
    /// local interpreter *understanding* the question and answering it honestly, not a failure to
    /// understand, so they're never second-guessed by an LLM. `semanticProvider` itself never
    /// computes a financial figure — it only ever returns a small, fully-validated
    /// `AskClaritySemanticInterpretation`, which `AskClaritySemanticQueryBuilder` turns into the
    /// exact same kind of `AskClarityQuery` the deterministic interpreter produces, then routes
    /// through the *unchanged* `respond(toQuery:...)` — the same `AskClarityPlanner`,
    /// `AskClarityExecutor`, and calculators answer it either way, regardless of which
    /// interpreter recognized the question.
    ///
    /// Not wired into `AskClarityView` in this phase — adding it there (starting a `Task` around
    /// this call) is a deliberately separate, later change; this method is additive only.
    static func respondWithSemanticFallback(
        to text: String,
        context: AskClaritySessionContext,
        entries: [Entry],
        budgets: [Budget],
        headCategories: [HeadCategory],
        settings: BudgetCalculationSettings,
        calendar: Calendar = .current,
        today: Date = .now,
        semanticProvider: AskClaritySemanticProviding,
        callBudget: AskClaritySemanticCallBudget? = nil
    ) async -> Result {
        let localResult = respond(
            to: text, context: context, entries: entries, budgets: budgets, headCategories: headCategories,
            settings: settings, calendar: calendar, today: today
        )
        guard isUnrecognizedLocally(localResult.answer) else { return localResult }
        guard callBudget?.hasRemainingCalls ?? true else { return localResult }
        callBudget?.recordCall()

        let categories = headCategories.flatMap { $0.categories.filter { !$0.isArchived } }
        let semanticContext = AskClaritySemanticContext(question: text, today: today, availableCategoryNames: categories.map(\.name))

        guard let interpretation = await semanticProvider.interpret(context: semanticContext) else {
            return localResult
        }
        guard let query = AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, categories: categories, today: today, calendar: calendar) else {
            return localResult
        }
        return respond(
            toQuery: query, context: context, entries: entries, budgets: budgets, headCategories: headCategories,
            settings: settings, calendar: calendar, today: today
        )
    }
}
