import Foundation
import SwiftData

/// Total spending vs. the previous calendar month — see `ExplainMyMonthCalculator.explain`.
/// Only ever constructed when the previous month had actual budget-eligible spend to compare
/// against (never a comparison against zero, which would read as a meaningless "+∞%").
struct MonthSpendingComparison: Equatable {
    let previousTotal: Decimal
    let currentTotal: Decimal
    var difference: Decimal { currentTotal - previousTotal }
    /// `(current - previous) / previous`. Always finite — guarded by `previousTotal > 0` at the
    /// call site.
    let fraction: Double
    let direction: InsightDirection
}

/// This month's budget-vs-actual totals, reusing `BudgetCalculator.periodSpendingSummary`'s
/// existing totals and `OverviewCalculator.categorySpendingHealth`'s existing ranking — never a
/// new spend/budget calculation. `nil` at the call site when nothing is budgeted this month at
/// all, matching every other budget-aware card's "nothing to compare against" convention.
struct MonthBudgetPerformance {
    let spent: Decimal
    let budgeted: Decimal
    var remaining: Decimal { budgeted - spent }
    /// `spent / budgeted`, unclamped — matches `CategorySpendingHealth.progress`'s convention.
    let progress: Double
    let state: BudgetHealthState
    /// Over-budget categories only, most-over-first — `OverviewCalculator.categorySpendingHealth`'s
    /// own filter and ranking, not re-derived here.
    let overBudgetCategories: [CategorySpendingHealth]
}

/// What kind of deterministic observation a highlight is — lets the view phrase it without
/// re-deriving that from its other fields, matching `WhatsDifferentKind`'s role.
enum ExplainMyMonthHighlightKind: Equatable {
    case totalSpendingDown
    case categoryDecrease
    case withinBudget
    case categoryIncrease
    case overBudgetCategory
    case aheadOfPace
}

/// One deterministic "positive behavior" or "needs attention" observation for the month. Every
/// field is pre-computed; the view only formats/phrases it — matching `WhatsDifferentInsight`'s
/// existing split of data vs. presentation (`Models/HomeCalculator.swift`).
struct ExplainMyMonthHighlight: Equatable {
    let kind: ExplainMyMonthHighlightKind
    /// A category name, or "" for a highlight about the month as a whole (total spend, overall
    /// budget, pace).
    let subject: String
    let magnitudeFraction: Double?
    let amount: Decimal?
}

/// The full deterministic "Explain My Month" narrative for one calendar month — every field is
/// already-computed data; `ExplainMyMonthCardView` only formats/phrases it. See
/// `ExplainMyMonthCalculator.explain`.
struct MonthExplanation {
    let month: Date
    /// `false` when there's no budget-eligible expense activity at all this month — the
    /// first-month/new-user state. Every other field is empty/nil when this is `false`.
    let hasActivity: Bool
    let totalSpending: Decimal
    /// `nil` unless the previous calendar month itself had budget-eligible expense spend to
    /// compare against — never invents a comparison against a silent/empty prior month.
    let previousMonthComparison: MonthSpendingComparison?
    /// Categories whose spend moved meaningfully vs. the previous month, most-meaningful-first,
    /// capped to `ExplainMyMonthCalculator.maxNotableCategoryChanges`. Always empty when
    /// `previousMonthComparison` is `nil` — there is nothing to compare per-category either.
    let notableCategoryChanges: [WhatsDifferentInsight]
    /// `nil` when nothing is budgeted this month at all.
    let budgetPerformance: MonthBudgetPerformance?
    /// The single most relevant piece of good news in this month's data, if the data supports one.
    let positiveHighlight: ExplainMyMonthHighlight?
    /// The single most relevant thing that may need attention this month, if the data supports one.
    let attentionArea: ExplainMyMonthHighlight?
}

/// Computes the deterministic "Explain My Month" narrative: a short explanation of what happened
/// in a month's actual data, built entirely from existing calculation layers —
/// `BudgetCalculator.periodSpendingSummary`/`.spendingPace`, `OverviewCalculator.
/// categorySpendingHealth`, and `HomeCalculator`'s "meaningful change" threshold and `Category`/
/// `WhatsDifferentInsight` shapes. Pure, deterministic, SwiftUI-independent — matching every other
/// calculator in this file group.
///
/// Deliberately never calls `SpendingInsightsService` (the AI-generated free-text summary): every
/// number and phrase this narrative can produce must be explainable by pointing at the exact
/// comparison that produced it, which an LLM call cannot guarantee. See `ClarityScoreCalculator`'s
/// identical rationale.
enum ExplainMyMonthCalculator {
    /// How many per-category "notable change" rows the narrative surfaces at once — matches
    /// `HomeCalculator.maxWhatsDifferentInsights`'s density convention.
    static let maxNotableCategoryChanges = 3

    /// The period-over-period change a category must clear to count as "meaningful" — reuses
    /// `HomeCalculator.whatsDifferentThreshold` rather than defining a second, potentially
    /// diverging threshold for what "meaningful" means.
    static let meaningfulChangeThreshold = HomeCalculator.whatsDifferentThreshold

    static func explain(
        month: Date,
        entries: [Entry],
        budgets: [Budget],
        headCategories: [HeadCategory],
        settings: BudgetCalculationSettings,
        calendar: Calendar = .current,
        today: Date = .now
    ) -> MonthExplanation {
        let current = BudgetCalculator.periodSpendingSummary(
            month: month, entries: entries, budgets: budgets, headCategories: headCategories,
            settings: settings, respectHiddenCategories: true, calendar: calendar
        )

        guard current.totalSpent > 0 else {
            return MonthExplanation(
                month: month, hasActivity: false, totalSpending: 0, previousMonthComparison: nil,
                notableCategoryChanges: [], budgetPerformance: nil, positiveHighlight: nil, attentionArea: nil
            )
        }

        let previous = calendar.date(byAdding: .month, value: -1, to: month).map {
            BudgetCalculator.periodSpendingSummary(
                month: $0, entries: entries, budgets: budgets, headCategories: headCategories,
                settings: settings, respectHiddenCategories: true, calendar: calendar
            )
        }

        let comparison = monthComparison(current: current, previous: previous)
        let notableChanges = notableCategoryChanges(current: current, previous: previous)
        let budgetPerformance = budgetPerformance(
            current: current, month: month, entries: entries, budgets: budgets,
            headCategories: headCategories, settings: settings, calendar: calendar
        )
        let aheadOfPace = isAheadOfPace(
            current: current, month: month, entries: entries, settings: settings, calendar: calendar, today: today
        )

        return MonthExplanation(
            month: month,
            hasActivity: true,
            totalSpending: current.totalSpent,
            previousMonthComparison: comparison,
            notableCategoryChanges: notableChanges,
            budgetPerformance: budgetPerformance,
            positiveHighlight: positiveHighlight(comparison: comparison, notableChanges: notableChanges, budgetPerformance: budgetPerformance),
            attentionArea: attentionArea(budgetPerformance: budgetPerformance, aheadOfPace: aheadOfPace, notableChanges: notableChanges)
        )
    }

    // MARK: - Total spending comparison

    private static func monthComparison(
        current: PeriodSpendingSummary, previous: PeriodSpendingSummary?
    ) -> MonthSpendingComparison? {
        guard let previous, previous.totalSpent > 0 else { return nil }
        let fraction = ((current.totalSpent - previous.totalSpent) / previous.totalSpent).doubleValue
        return MonthSpendingComparison(
            previousTotal: previous.totalSpent, currentTotal: current.totalSpent,
            fraction: fraction, direction: fraction >= 0 ? .up : .down
        )
    }

    // MARK: - Notable category changes

    /// Category-level (not `HeadCategory`-level) "what changed" rows — more specific than Home's
    /// glance list, which suits a monthly narrative. Reuses `PeriodSpendingSummary.byCategory`
    /// (so budget eligibility/hidden-category handling is inherited automatically) and
    /// `WhatsDifferentInsight`'s existing shape rather than inventing a parallel type.
    private static func notableCategoryChanges(
        current: PeriodSpendingSummary, previous: PeriodSpendingSummary?
    ) -> [WhatsDifferentInsight] {
        guard let previous else { return [] }

        let changes: [WhatsDifferentInsight] = current.byCategory.compactMap { currentCategory in
            guard
                let previousCategory = previous.byCategory.first(where: { $0.category === currentCategory.category }),
                previousCategory.actual > 0
            else { return nil }

            let fraction = ((currentCategory.actual - previousCategory.actual) / previousCategory.actual).doubleValue
            guard abs(fraction) >= meaningfulChangeThreshold else { return nil }

            return WhatsDifferentInsight(
                id: "explain-category-\(currentCategory.category.persistentModelID)",
                kind: .categoryChange,
                subject: currentCategory.category.name,
                direction: fraction > 0 ? .up : .down,
                magnitudeFraction: abs(fraction),
                severity: .informational,
                isFavorable: fraction > 0 ? false : true
            )
        }

        return Array(
            changes
                .sorted { ($0.magnitudeFraction ?? 0) > ($1.magnitudeFraction ?? 0) }
                .prefix(maxNotableCategoryChanges)
        )
    }

    // MARK: - Budget performance

    private static func budgetPerformance(
        current: PeriodSpendingSummary,
        month: Date,
        entries: [Entry],
        budgets: [Budget],
        headCategories: [HeadCategory],
        settings: BudgetCalculationSettings,
        calendar: Calendar
    ) -> MonthBudgetPerformance? {
        guard current.totalBudgeted > 0 else { return nil }

        let progress = (current.totalSpent / current.totalBudgeted).doubleValue
        let overBudgetCategories = OverviewCalculator.categorySpendingHealth(
            month: month, entries: entries, budgets: budgets, headCategories: headCategories,
            settings: settings, calendar: calendar
        ).filter { $0.state == .overBudget }

        return MonthBudgetPerformance(
            spent: current.totalSpent, budgeted: current.totalBudgeted, progress: progress,
            state: .forProgress(progress), overBudgetCategories: overBudgetCategories
        )
    }

    /// Whether this month's cumulative spend is currently running ahead of its straight-line
    /// budget pace — reuses `BudgetCalculator.spendingPace`/`HomeCalculator.forecastPaceState`'s
    /// exact same pace comparison rather than a second one.
    private static func isAheadOfPace(
        current: PeriodSpendingSummary,
        month: Date,
        entries: [Entry],
        settings: BudgetCalculationSettings,
        calendar: Calendar,
        today: Date
    ) -> Bool {
        guard current.totalBudgeted > 0 else { return false }
        let pace = BudgetCalculator.spendingPace(
            month: month, entries: entries, settings: settings,
            totalPlanned: current.totalBudgeted, calendar: calendar, today: today
        )
        return HomeCalculator.forecastPaceState(pace: pace) == .aheadOfPace
    }

    // MARK: - Highlights

    /// The single most relevant piece of good news, checked in order of how strong/specific a
    /// signal it is: total spend meaningfully down, then the single biggest category decrease,
    /// then simply finishing the month with no category over its budget.
    private static func positiveHighlight(
        comparison: MonthSpendingComparison?,
        notableChanges: [WhatsDifferentInsight],
        budgetPerformance: MonthBudgetPerformance?
    ) -> ExplainMyMonthHighlight? {
        if let comparison, comparison.direction == .down, abs(comparison.fraction) >= meaningfulChangeThreshold {
            return ExplainMyMonthHighlight(kind: .totalSpendingDown, subject: "", magnitudeFraction: abs(comparison.fraction), amount: abs(comparison.difference))
        }

        // A category that's down from last month but still over *its own* budget this month
        // isn't good news yet — celebrating it here while `attentionArea` simultaneously flags
        // the same category as over budget would read as the narrative contradicting itself.
        let overBudgetCategoryNames = Set((budgetPerformance?.overBudgetCategories ?? []).map(\.category.name))
        if let biggestDecrease = notableChanges
            .filter({ $0.isFavorable == true && !overBudgetCategoryNames.contains($0.subject) })
            .max(by: { ($0.magnitudeFraction ?? 0) < ($1.magnitudeFraction ?? 0) }) {
            return ExplainMyMonthHighlight(kind: .categoryDecrease, subject: biggestDecrease.subject, magnitudeFraction: biggestDecrease.magnitudeFraction, amount: nil)
        }

        if let budgetPerformance, budgetPerformance.overBudgetCategories.isEmpty {
            return ExplainMyMonthHighlight(kind: .withinBudget, subject: "", magnitudeFraction: nil, amount: budgetPerformance.remaining)
        }

        return nil
    }

    /// The single most relevant thing that may need attention, checked most-actionable-first: a
    /// category that's actually over its budget, then running ahead of pace with no single
    /// category to blame yet, then simply the biggest category spend increase.
    private static func attentionArea(
        budgetPerformance: MonthBudgetPerformance?,
        aheadOfPace: Bool,
        notableChanges: [WhatsDifferentInsight]
    ) -> ExplainMyMonthHighlight? {
        if let worst = budgetPerformance?.overBudgetCategories.first {
            return ExplainMyMonthHighlight(kind: .overBudgetCategory, subject: worst.category.name, magnitudeFraction: worst.progress - 1, amount: worst.spent - worst.budgeted)
        }

        if aheadOfPace {
            return ExplainMyMonthHighlight(kind: .aheadOfPace, subject: "", magnitudeFraction: nil, amount: nil)
        }

        if let biggestIncrease = notableChanges.filter({ $0.isFavorable == false }).max(by: { ($0.magnitudeFraction ?? 0) < ($1.magnitudeFraction ?? 0) }) {
            return ExplainMyMonthHighlight(kind: .categoryIncrease, subject: biggestIncrease.subject, magnitudeFraction: biggestIncrease.magnitudeFraction, amount: nil)
        }

        return nil
    }
}
