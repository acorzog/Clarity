import Foundation
import SwiftData

/// One expense category's budget-health snapshot — see `OverviewCalculator.categorySpendingHealth`.
/// Every field is pre-computed; the view only formats/phrases it, matching `WhatsDifferentInsight`
/// (`Models/HomeCalculator.swift`)'s existing split of data vs. presentation.
struct CategorySpendingHealth: Identifiable {
    let category: Category
    let spent: Decimal
    let budgeted: Decimal
    /// `spent / budgeted`, unclamped — can exceed `1` when over budget. The view clamps it to
    /// `0...1` itself wherever it needs a bounded value (e.g. a progress ring).
    let progress: Double
    let state: BudgetHealthState
    var id: PersistentIdentifier { category.persistentModelID }
}

/// Overview-specific deterministic calculations layered on top of `BudgetCalculator`'s existing
/// output types — never re-derives budget/spending math itself, matching `HomeCalculator`'s own
/// architecture (`Models/HomeCalculator.swift`).
enum OverviewCalculator {
    /// Categories shown at once in Overview's Spending Health card — mirrors `HomeCalculator`'s
    /// own capping convention (`maxWhatsDifferentInsights`/`maxUpcomingItems`) so the card stays
    /// compact regardless of how many budgeted categories exist.
    static let maxSpendingHealthCategories = 5

    /// Budget-vs-actual health for this period's expense categories, reusing `BudgetCalculator.
    /// periodSpendingSummary`'s existing per-category totals rather than re-deriving spend from
    /// `Entry` directly. A category with no budget set (`planned == 0`) is left out entirely —
    /// there's no meaningful "healthy/approaching/over" state to show without a limit to compare
    /// against, so it's omitted rather than shown with an invented state.
    ///
    /// Ranked over-budget first, then approaching-limit, then on-track, and within each tier by
    /// how far over/close to the limit it is — so the categories most needing attention lead, and
    /// the result is capped to `maxSpendingHealthCategories`.
    static func categorySpendingHealth(
        month: Date,
        entries: [Entry],
        budgets: [Budget],
        headCategories: [HeadCategory],
        settings: BudgetCalculationSettings,
        calendar: Calendar = .current
    ) -> [CategorySpendingHealth] {
        let summary = BudgetCalculator.periodSpendingSummary(
            month: month, entries: entries, budgets: budgets, headCategories: headCategories,
            settings: settings, respectHiddenCategories: true, calendar: calendar
        )

        let rows = summary.byCategory.compactMap { actual -> CategorySpendingHealth? in
            guard actual.planned > 0 else { return nil }
            let progress = (actual.actual / actual.planned).doubleValue
            return CategorySpendingHealth(
                category: actual.category, spent: actual.actual, budgeted: actual.planned,
                progress: progress, state: .forProgress(progress)
            )
        }

        return Array(
            rows
                .sorted { lhs, rhs in
                    lhs.state != rhs.state ? lhs.state > rhs.state : lhs.progress > rhs.progress
                }
                .prefix(maxSpendingHealthCategories)
        )
    }
}
