import Foundation

/// Combines exactly two validated semantic interpretations — produced from two parallel tool
/// calls in one Anthropic response (see `AnthropicClaritySemanticProvider`,
/// `AskClaritySemanticOutcome.composed`) — into one answer: a single period's amount versus the
/// average of its own trend chain. This is the only two-step composition Phase 1 recognizes;
/// anything else (different subjects, two trend requests, two plain amounts, …) is rejected
/// rather than guessed into a shape — `respond` returns `nil` and the caller falls back to the
/// existing deterministic/local answer.
///
/// Every number here comes from `AskClarityPlanner`/`AskClarityExecutor` — the exact same
/// deterministic calculators every other Ask Clarity answer already uses. Claude never supplies,
/// sees, or influences a figure: it only chose *which two existing operations* to run, during
/// `interpret` (itself before this type is ever called); the comparison itself — the averaging,
/// the deviation, the wording — is plain Swift arithmetic over two already-computed `Decimal`
/// values, composed here and nowhere else.
enum AskClaritySemanticComposition {
    /// A fixed, documented deviation threshold for calling a period's figure unusual relative to
    /// its own trailing average — not a statistical model, just a simple, auditable cutoff in
    /// keeping with how `AskClarityEngine`'s wording elsewhere favors plain comparisons over
    /// inference. Deliberately not shared with `ExplainMyMonthCalculator.notableCategoryChanges`
    /// (a different comparison: single-previous-period, not a multi-period average) — two
    /// independent, equally simple percentage cutoffs, not one calculator duplicating the other.
    private static let anomalyThresholdPercent: Double = 25
    /// Need at least this many historical points for "average" to mean anything.
    private static let minimumHistoricalPoints = 2

    static func respond(
        first: AskClaritySemanticInterpretation,
        second: AskClaritySemanticInterpretation,
        question: String,
        context: AskClaritySessionContext,
        entries: [Entry],
        budgets: [Budget],
        headCategories: [HeadCategory],
        settings: BudgetCalculationSettings,
        calendar: Calendar,
        today: Date
    ) -> AskClarityEngine.Result? {
        // Exactly one of the two calls must be the trend/average side; the other is the single
        // period being asked about. Both-or-neither is never guessed at — see the tool
        // description in `AskClarityToolUseRequestBuilder` for the one shape this expects.
        let candidates = [first, second]
        let trendCandidates = candidates.filter { $0.wantsTrend && ($0.trendSpan ?? 0) >= minimumHistoricalPoints }
        let currentCandidates = candidates.filter { !($0.wantsTrend && ($0.trendSpan ?? 0) >= minimumHistoricalPoints) }
        guard trendCandidates.count == 1, currentCandidates.count == 1 else { return nil }
        let trendInterpretation = trendCandidates[0]
        let currentInterpretation = currentCandidates[0]

        let categories = headCategories.flatMap { $0.categories.filter { !$0.isArchived } }
        guard
            let currentQuery = AskClaritySemanticQueryBuilder.buildQuery(from: currentInterpretation, question: question, categories: categories, today: today, calendar: calendar),
            let trendQuery = AskClaritySemanticQueryBuilder.buildQuery(from: trendInterpretation, question: question, categories: categories, today: today, calendar: calendar)
        else { return nil }

        guard
            case .plan(let currentPlan) = AskClarityPlanner.plan(for: currentQuery, context: context, today: today, calendar: calendar),
            case .plan(let trendPlan) = AskClarityPlanner.plan(for: trendQuery, context: context, today: today, calendar: calendar)
        else { return nil }

        // Phase 1 only recognizes this composition for a named category/head-category subject
        // (the canonical "this month's X vs its own trailing average" question) — a plain,
        // categoryless metric total falls back to the local/single-call answer instead of
        // guessing at generic wording for it. Subjects are compared by the real `Category`
        // objects they resolve to (never by name alone) — two categories could coincidentally
        // share a display name, and this must never silently average one against the other's
        // trend. The trend chain must also be anchored at exactly the same period `currentPlan`
        // asks about (not just "some trend of the same subject") — otherwise its chain's own
        // "current" point (the one excluded below so the baseline never includes itself) would
        // be the wrong period, and the remaining points would silently shift by one period from
        // what the headline claims they are.
        guard
            currentPlan.operation == .amount,
            trendPlan.operation == .trend,
            currentPlan.metric == trendPlan.metric,
            currentPlan.period.kind == trendPlan.period.kind,
            let subject = currentPlan.subjects.first,
            let trendSubject = trendPlan.subjects.first,
            Set(subject.categories.map(ObjectIdentifier.init)) == Set(trendSubject.categories.map(ObjectIdentifier.init))
        else { return nil }

        let currentExecution = AskClarityExecutor.execute(plan: currentPlan, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
        let trendExecution = AskClarityExecutor.execute(plan: trendPlan, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)

        guard case .amount(let currentAmount, _, _, let hasData) = currentExecution, hasData else { return nil }
        guard case .trend(let points) = trendExecution else { return nil }

        // The averaging/deviation arithmetic itself is shared with the deterministic path's own
        // "compared to my average" answer (`AskClarityEngine.respondToTrendAverageComparison`) —
        // never two independent copies of "average the history, then compare." `points` is passed
        // unfiltered; `compute` excludes the current period's own point internally. The minimum
        // required history is derived from the trend call's own requested span (same rule the
        // deterministic path applies) — never a fixed constant unrelated to what was actually
        // asked for; `minimumHistoricalPoints` above is a separate concept (the *role-detection*
        // threshold that decided this interpretation counted as the trend side at all).
        let requiredHistoricalPeriods = max((trendInterpretation.trendSpan ?? 3) - 1, 1)
        guard let comparison = AskClarityTrendAverageComparison.compute(
            currentAmount: currentAmount, currentPeriodLabel: currentPlan.period.label, historicalPoints: points, minimumPeriods: requiredHistoricalPeriods
        ) else { return nil }
        // `average == 0` falls back to the local answer here (unlike the deterministic path's own
        // explicit "nothing to compare to" message) — preserves this composition's existing,
        // already-tested behavior exactly; see its own file's doc comment for why this phase
        // leaves that behavior untouched.
        guard let percent = comparison.percentDifference else { return nil }

        let isAnomaly = abs(percent) * 100 >= anomalyThresholdPercent
        let magnitude = abs(percent).formatted(.percent.precision(.fractionLength(0)))

        let headline = "You spent \(currentAmount.currencyFormatted) on \(subject.name) \(currentPlan.period.label), versus a \(comparison.average.currencyFormatted) average over the \(comparison.periodsAveraged) periods before that."
        let detail = isAnomaly
            ? "That's \(magnitude) \(comparison.isHigher ? "higher" : "lower") than usual — worth a look."
            : "That's within \(magnitude) of your usual pace."
        // Spending: higher-than-usual is unfavorable. Income: higher-than-usual is favorable.
        // `.remainingBudget`/`.savings` never reach here — `.trend` is spending/income only in
        // `AskClarityPlanner` step 7a's own `metric` resolution.
        let comparisonIsFavorable: Bool? = currentPlan.metric == .spending ? !comparison.isHigher : (currentPlan.metric == .income ? comparison.isHigher : nil)

        let answer = AskClarityAnswer(headline: headline, supportingDetail: detail, hasSufficientData: true, comparisonIsFavorable: comparisonIsFavorable)
        // Matches the rest of the semantic path's own convention — a semantic interpretation
        // never participates in the deterministic pronoun/follow-up context inheritance.
        return AskClarityEngine.Result(answer: answer, updatedContext: context)
    }
}
