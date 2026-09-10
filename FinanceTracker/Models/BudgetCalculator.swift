import Foundation
import SwiftData

/// One expense category's planned vs. actual amount for a period — see `BudgetCalculator`.
struct CategoryActual: Identifiable {
    let category: Category
    let planned: Decimal
    let actual: Decimal
    var remaining: Decimal { planned - actual }
    var id: PersistentIdentifier { category.persistentModelID }
}

/// One head category's planned vs. actual amount for a period — see `BudgetCalculator`.
struct HeadCategoryActual: Identifiable {
    let headCategory: HeadCategory
    let planned: Decimal
    let actual: Decimal
    var remaining: Decimal { planned - actual }
    var id: PersistentIdentifier { headCategory.persistentModelID }
}

/// Everything Remaining's gauge and the budget widget need to describe "Left to Spend" for one
/// period — see `BudgetCalculator.periodSpendingSummary`.
struct PeriodSpendingSummary {
    /// The actual budget-cycle window (see `Date.budgetPeriod(startDay:)`) entries were scoped
    /// to — not necessarily a calendar month once `cycleStartDay > 1`.
    let period: DateInterval
    let totalAvailable: Decimal
    let totalSpent: Decimal
    /// Sum of every expense category's planned amount (calendar-month `Budget` rows), optionally
    /// excluding hidden categories — see `periodSpendingSummary`'s `respectHiddenCategories`.
    let totalBudgeted: Decimal
    /// Budget-eligible income entries within `period`.
    let totalIncome: Decimal
    let otherExpensesTotal: Decimal
    let savingsTransfersTotal: Decimal
    let debtTransfersTotal: Decimal
    let byHeadCategory: [HeadCategoryActual]
    let byCategory: [CategoryActual]

    var totalLeft: Decimal { totalAvailable - totalSpent }
}

/// Planning-time totals — see `BudgetCalculator.plannedBudgetTotals`. Deliberately distinct from
/// `PeriodSpendingSummary`: this never reads `Entry`, and `leftToBudget` (planned income minus
/// planned expenses) is a different concept from `PeriodSpendingSummary.totalLeft` (available
/// money minus *actual* spending) even though both are colloquially "what's left."
struct PlannedBudgetTotals {
    let totalPlannedIncome: Decimal
    let totalPlannedExpenses: Decimal
    var leftToBudget: Decimal { totalPlannedIncome - totalPlannedExpenses }
}

/// One day's cumulative actual spend vs. its straight-line "on pace" projection — see
/// `BudgetCalculator.spendingPace`. `day` is 1-based, counted from the start of the budget
/// period (identical to "day of the calendar month" when `cycleStartDay == 1`).
struct DailyPacePoint: Identifiable {
    var id: Int { day }
    let day: Int
    /// `nil` for a day that hasn't happened yet relative to today — matches the existing
    /// "no line drawn past today" behavior.
    let actual: Decimal?
    let onPace: Decimal
}

/// The single shared calculation layer for budget/spending metrics — see
/// `CLARITY_PHASE_1_CALCULATION_PROPOSAL.md`. Pure, deterministic, and independent of SwiftUI,
/// `UserDefaults`, and CloudKit: every function takes already-fetched model arrays and plain
/// value types, and returns plain value types, so it is equally usable from the app, the widget
/// extension, unit tests, and any future background calculation.
///
/// Reuses `EntryQuerying`/`BudgetQuerying` for period filtering and budget lookup rather than
/// re-deriving that logic — this type only adds the calculation semantics layered on top.
enum BudgetCalculator {

    // MARK: - Period spending (Remaining / the budget widget)

    /// The shared "Left to Spend" calculation. Powers `RemainingView`'s gauge and
    /// `BudgetGaugeWidget` identically, so the two can no longer disagree about what "Left to
    /// Spend" means for the same underlying data.
    ///
    /// - `month` anchors the budget period via `Date.budgetPeriod(startDay:)` —
    ///   `settings.cycleStartDay` determines how far that period extends into the adjacent
    ///   calendar month. **Budget limits stay calendar-month-based regardless**
    ///   (`Budget.month`/`.year`, looked up via `BudgetQuerying`) — this is an intentional,
    ///   preserved seam: a category's single monthly limit is compared against spend drawn from
    ///   a period that can straddle two calendar months when `cycleStartDay > 1`.
    /// - Only budget-eligible entries (`!excludeFromBudget`) ever contribute, on both the income
    ///   and expense sides — see `Models/BudgetEligibility.swift`.
    /// - `respectHiddenCategories`: when `true`, a category hidden this month
    ///   (`BudgetQuerying.isHidden(for:month:)`) contributes `0` to planned totals — which also
    ///   means any of its actual spend falls into the "Other" bucket, exactly as an unbudgeted
    ///   category's spend already does. When `false`, hidden categories are treated exactly like
    ///   any other category.
    static func periodSpendingSummary(
        month: Date,
        entries: [Entry],
        budgets: [Budget],
        headCategories: [HeadCategory],
        settings: BudgetCalculationSettings,
        respectHiddenCategories: Bool,
        calendar: Calendar = .current
    ) -> PeriodSpendingSummary {
        let period = month.budgetPeriod(startDay: settings.cycleStartDay, calendar: calendar)

        // Budget eligibility is applied once, up front, to income/expense/transfer alike — an
        // excluded entry contributes to nothing below, regardless of its type.
        let periodEntries = entries
            .inBudgetPeriod(month, startDay: settings.cycleStartDay, calendar: calendar)
            .budgetEligible

        let periodExpenses = periodEntries.filter { $0.type == .expense }
        let periodTransfers = periodEntries.filter { $0.type == .transfer }
        let totalIncome = periodEntries.filter { $0.type == .income }.reduce(Decimal(0)) { $0 + $1.amount }

        func plannedAmount(for category: Category) -> Decimal {
            if respectHiddenCategories && budgets.isHidden(for: category, month: month) {
                return 0
            }
            return budgets.amount(for: category, month: month)
        }

        func expenseCategories(for head: HeadCategory) -> [Category] {
            head.categories.filter { !$0.isIncome && !$0.isArchived }
        }

        func actualSpend(for category: Category) -> Decimal {
            periodExpenses.filter { $0.category === category }.reduce(Decimal(0)) { $0 + $1.amount }
        }

        let allExpenseCategories = headCategories.flatMap(expenseCategories)

        let byCategory = allExpenseCategories.map { category in
            CategoryActual(category: category, planned: plannedAmount(for: category), actual: actualSpend(for: category))
        }

        let byHeadCategory = headCategories.compactMap { head -> HeadCategoryActual? in
            let categories = expenseCategories(for: head)
            guard !categories.isEmpty else { return nil }
            let planned = categories.reduce(Decimal(0)) { $0 + plannedAmount(for: $1) }
            let actual = categories.reduce(Decimal(0)) { $0 + actualSpend(for: $1) }
            guard planned > 0 || actual > 0 else { return nil }
            return HeadCategoryActual(headCategory: head, planned: planned, actual: actual)
        }

        let totalBudgeted = allExpenseCategories.reduce(Decimal(0)) { $0 + plannedAmount(for: $1) }

        // "Other" = no category, or a category whose planned amount is 0 this period (either
        // genuinely unbudgeted, or hidden with respectHiddenCategories == true).
        let otherExpensesTotal = periodExpenses
            .filter { entry in
                guard let category = entry.category else { return true }
                return plannedAmount(for: category) == 0
            }
            .reduce(Decimal(0)) { $0 + $1.amount }

        let savingsTransfersTotal = periodTransfers
            .filter { $0.destinationWallet?.type == .savings }
            .reduce(Decimal(0)) { $0 + $1.amount }
        let debtTransfersTotal = periodTransfers
            .filter { $0.destinationWallet?.type == .debt }
            .reduce(Decimal(0)) { $0 + $1.amount }

        var totalSpent = periodExpenses.reduce(Decimal(0)) { $0 + $1.amount }
        if !settings.includeUnplannedAsOtherExpenses {
            totalSpent -= otherExpensesTotal
        }
        if settings.includeSavingsTransfers {
            totalSpent += savingsTransfersTotal
        }
        if settings.includeDebtTransfers {
            totalSpent += debtTransfersTotal
        }

        // Available money: a manual override always wins; otherwise money actually received
        // this period is real spendable money, so it takes priority over the planned-expense
        // total; falls back to the planned total for periods with no income tracked at all.
        let totalAvailable: Decimal
        if settings.manualMonthlyBudget > 0 {
            totalAvailable = settings.manualMonthlyBudget
        } else if totalIncome > 0 {
            totalAvailable = totalIncome
        } else {
            totalAvailable = totalBudgeted
        }

        return PeriodSpendingSummary(
            period: period,
            totalAvailable: totalAvailable,
            totalSpent: totalSpent,
            totalBudgeted: totalBudgeted,
            totalIncome: totalIncome,
            otherExpensesTotal: otherExpensesTotal,
            savingsTransfersTotal: savingsTransfersTotal,
            debtTransfersTotal: debtTransfersTotal,
            byHeadCategory: byHeadCategory,
            byCategory: byCategory
        )
    }

    // MARK: - Planned budget (Plan)

    /// Planning-time totals, matching `PlanView`'s existing visible-only behavior exactly: never
    /// reads `Entry`, always excludes hidden categories, and is anchored purely to the calendar
    /// month (`Budget.month`/`.year`) — the budget cycle never applies here (see
    /// `periodSpendingSummary`'s doc comment on the calendar-month-vs-cycle seam).
    static func plannedBudgetTotals(
        month: Date,
        budgets: [Budget],
        headCategories: [HeadCategory],
        calendar: Calendar = .current
    ) -> PlannedBudgetTotals {
        func visibleAmount(for category: Category) -> Decimal {
            guard !budgets.isHidden(for: category, month: month) else { return 0 }
            return budgets.amount(for: category, month: month)
        }

        let incomeHeadCategory = headCategories.first { $0.name == "Income" }
            ?? headCategories.first { head in head.categories.contains { $0.isIncome } }

        let incomeCategories = (incomeHeadCategory?.categories ?? []).filter { $0.isIncome && !$0.isArchived }
        let totalPlannedIncome = incomeCategories.reduce(Decimal(0)) { $0 + visibleAmount(for: $1) }

        let expenseHeadCategories = headCategories.filter { $0 !== incomeHeadCategory }
        let totalPlannedExpenses = expenseHeadCategories
            .flatMap { $0.categories.filter { !$0.isIncome && !$0.isArchived } }
            .reduce(Decimal(0)) { $0 + visibleAmount(for: $1) }

        return PlannedBudgetTotals(totalPlannedIncome: totalPlannedIncome, totalPlannedExpenses: totalPlannedExpenses)
    }

    // MARK: - Spending pace (Insights)

    /// The existing linear "on pace" projection, generalized to the configurable budget period
    /// rather than a fixed calendar month (see `periodSpendingSummary`'s doc comment). `day` is
    /// 1-based from the start of the period; for the ordinary `cycleStartDay == 1` case this is
    /// identical to "day of the calendar month," preserving today's behavior exactly.
    ///
    /// Not a statistical forecast — `onPace` is simply `totalPlanned` divided evenly across the
    /// period's days and multiplied by the day index, matching `InsightsView`'s existing formula.
    /// Only budget-eligible expense entries contribute to the actual (cumulative) line.
    ///
    /// Takes `settings` (rather than the narrower `cycleStartDay: Int`) so callers that already
    /// hold a `BudgetCalculationSettings` for `periodSpendingSummary` can reuse it directly.
    static func spendingPace(
        month: Date,
        entries: [Entry],
        settings: BudgetCalculationSettings,
        totalPlanned: Decimal,
        calendar: Calendar = .current,
        today: Date = .now
    ) -> [DailyPacePoint] {
        let period = month.budgetPeriod(startDay: settings.cycleStartDay, calendar: calendar)
        guard
            let daysInPeriod = calendar.dateComponents([.day], from: period.start, to: period.end).day,
            daysInPeriod > 0
        else { return [] }

        let periodExpenses = entries
            .inBudgetPeriod(month, startDay: settings.cycleStartDay, calendar: calendar)
            .budgetEligible
            .filter { $0.type == .expense }

        let perDayPace = totalPlanned / Decimal(daysInPeriod)

        func dayIndex(for date: Date) -> Int {
            (calendar.dateComponents([.day], from: period.start, to: date).day ?? 0) + 1
        }

        let lastDataDay: Int
        if period.contains(today) {
            lastDataDay = dayIndex(for: today)
        } else if today >= period.end {
            lastDataDay = daysInPeriod
        } else {
            lastDataDay = 0
        }

        var cumulative: Decimal = 0
        return (1...daysInPeriod).map { day in
            var actual: Decimal?
            if day <= lastDataDay {
                let dayTotal = periodExpenses
                    .filter { dayIndex(for: $0.date) == day }
                    .reduce(Decimal(0)) { $0 + $1.amount }
                cumulative += dayTotal
                actual = cumulative
            }
            return DailyPacePoint(day: day, actual: actual, onPace: perDayPace * Decimal(day))
        }
    }
}
