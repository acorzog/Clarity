import Foundation

/// The raw numbers `AskClarityPlanner` decided are needed, computed but not yet worded into an
/// answer — that's `AskClarityEngine`'s job. `.unresolvable` covers a period `AskClarityEngine`'s
/// own calculators couldn't resolve (should be rare, since `AskClarityInterpreter` already rejects
/// unsupported periods before a `Plan` is ever built).
enum AskClarityExecutionResult {
    /// `secondary` is the second subject's amount for a `.betweenSubjects` comparison plan;
    /// `previousPeriod` is the previous-equivalent-period amount for a `.previousPeriod` one.
    /// Never both at once — a plan carries at most one `AskClarityPlanComparison`. `hasData` is
    /// only meaningful for a plain `.remainingBudget` total (no category, no spend/income figure
    /// of its own to gate on) — always `true` everywhere else, where the amount's own sign/zero
    /// check already tells `AskClarityEngine` whether there's anything to report.
    case amount(primary: Decimal, secondary: Decimal?, previousPeriod: (amount: Decimal, label: String)?, hasData: Bool)
    /// Reused for both `.rankCategories` (every category, `AskClarityPlan.subjects.isEmpty`) and
    /// `.categoryBreakdown` (optionally scoped to `subjects.first?.categories`) — identical
    /// per-category totals either way, just presented differently by `AskClarityEngine`.
    case categoryRanking(rows: [(category: Category, amount: Decimal)])
    case transactionRanking(entries: [Entry])
    /// `categoryRow` is set for a single-category budget-state question ("is Restaurants over
    /// budget"); `health` is the global ranked list ("which categories are over budget") — never
    /// both, matching `AskClarityPlan.subjects.first?.singleCategory`'s presence.
    case budgetState(categoryRow: CategoryActual?, health: [CategorySpendingHealth])
    /// One point per consecutive equivalent period the trend chain could resolve, oldest first —
    /// shorter than the plan's requested `trendSpan` whenever the period kind can't chain back
    /// that far (see `AskClarityPeriodKind.previousEquivalent`).
    case trend(points: [(period: AskClarityPeriod, amount: Decimal)])
    case unresolvable
}

/// Computes an `AskClarityPlan` into an `AskClarityExecutionResult` — the **execute** stage
/// between **plan** (`AskClarityPlanner`) and **respond** (`AskClarityEngine`). Reuses exactly the
/// same calculators/helpers the rest of "Ask Clarity" already uses (`BudgetCalculator.
/// periodSpendingSummary`, `OverviewCalculator.categorySpendingHealth`, `AskClarityRangeCalculator`,
/// and `AskClarityEngine`'s own period-bounds/metric-total helpers) — never a new financial
/// calculation.
enum AskClarityExecutor {
    static func execute(
        plan: AskClarityPlan,
        entries: [Entry],
        budgets: [Budget],
        headCategories: [HeadCategory],
        settings: BudgetCalculationSettings,
        calendar: Calendar,
        today: Date
    ) -> AskClarityExecutionResult {
        switch plan.operation {
        case .amount:
            return executeAmount(plan: plan, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
        case .rankCategories:
            return executeCategoryRanking(plan: plan, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
        case .rankTransactions:
            return executeTransactionRanking(plan: plan, entries: entries, calendar: calendar, today: today)
        case .budgetState:
            return executeBudgetState(plan: plan, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
        case .categoryBreakdown:
            return executeCategoryBreakdown(plan: plan, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
        case .trend:
            return executeTrend(plan: plan, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
        }
    }

    // MARK: - Amount (category, comparison, and plain metric)

    private static func executeAmount(
        plan: AskClarityPlan, entries: [Entry], budgets: [Budget], headCategories: [HeadCategory], settings: BudgetCalculationSettings, calendar: Calendar, today: Date
    ) -> AskClarityExecutionResult {
        guard let primarySubject = plan.subjects.first else {
            return executePlainMetricAmount(plan: plan, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
        }
        guard let primary = AskClarityEngine.categoriesSpending(
            categories: primarySubject.categories, period: plan.period, entries: entries, budgets: budgets,
            headCategories: headCategories, settings: settings, calendar: calendar, today: today
        ) else { return .unresolvable }

        if plan.comparison == .betweenSubjects, plan.subjects.count == 2 {
            guard let secondary = AskClarityEngine.categoriesSpending(
                categories: plan.subjects[1].categories, period: plan.period, entries: entries, budgets: budgets,
                headCategories: headCategories, settings: settings, calendar: calendar, today: today
            ) else { return .unresolvable }
            return .amount(primary: primary, secondary: secondary, previousPeriod: nil, hasData: true)
        }

        var previousPeriod: (amount: Decimal, label: String)?
        if plan.comparison == .previousPeriod {
            previousPeriod = AskClarityEngine.previousPeriodAmount(
                categories: primarySubject.categories, period: plan.period, entries: entries, budgets: budgets,
                headCategories: headCategories, settings: settings, calendar: calendar, today: today
            )
        }
        return .amount(primary: primary, secondary: nil, previousPeriod: previousPeriod, hasData: true)
    }

    /// A total with no category named — spending, income, remaining budget, or savings.
    /// Remaining budget is the one case that needs more than just its own figure to tell whether
    /// there's anything to report (its total can legitimately be exactly `0`), so it's computed
    /// directly here rather than through `AskClarityEngine.metricTotal` — matching how
    /// `executeCategoryRanking` below already calls `BudgetCalculator` directly rather than only
    /// ever going through `AskClarityEngine`.
    private static func executePlainMetricAmount(
        plan: AskClarityPlan, entries: [Entry], budgets: [Budget], headCategories: [HeadCategory], settings: BudgetCalculationSettings, calendar: Calendar, today: Date
    ) -> AskClarityExecutionResult {
        switch plan.metric {
        case .spending, .income:
            guard let amount = AskClarityEngine.metricTotal(
                metric: plan.metric, period: plan.period, entries: entries, budgets: budgets,
                headCategories: headCategories, settings: settings, calendar: calendar, today: today
            ) else { return .unresolvable }
            var previousPeriod: (amount: Decimal, label: String)?
            if plan.comparison == .previousPeriod {
                previousPeriod = AskClarityEngine.previousMetricPeriodTotal(
                    metric: plan.metric, period: plan.period, entries: entries, budgets: budgets,
                    headCategories: headCategories, settings: settings, calendar: calendar, today: today
                )
            }
            return .amount(primary: amount, secondary: nil, previousPeriod: previousPeriod, hasData: true)

        case .remainingBudget:
            guard plan.period.kind.isMonthBased, let month = AskClarityEngine.monthDate(for: plan.period.kind, today: today, calendar: calendar) else { return .unresolvable }
            let summary = BudgetCalculator.periodSpendingSummary(month: month, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, respectHiddenCategories: true, calendar: calendar)
            let hasData = summary.totalAvailable > 0 || summary.totalSpent > 0
            return .amount(primary: summary.totalLeft, secondary: nil, previousPeriod: nil, hasData: hasData)

        case .savings:
            guard plan.period.kind.isMonthBased, let month = AskClarityEngine.monthDate(for: plan.period.kind, today: today, calendar: calendar) else { return .unresolvable }
            let summary = BudgetCalculator.periodSpendingSummary(month: month, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, respectHiddenCategories: true, calendar: calendar)
            return .amount(primary: summary.savingsTransfersTotal, secondary: nil, previousPeriod: nil, hasData: true)
        }
    }

    // MARK: - Category ranking / breakdown

    /// Every category's amount for `period`, optionally restricted to `onlyCategories` (a head
    /// category's own children, for a scoped breakdown) — the shared row computation behind both
    /// `.rankCategories` (unfiltered, `AskClarityEngine.respondToCategoryRanking` truncates to the
    /// top few) and `.categoryBreakdown` (filtered, kept in full).
    private static func categoryAmounts(
        period: AskClarityPeriod, onlyCategories: [Category]?, entries: [Entry], budgets: [Budget], headCategories: [HeadCategory], settings: BudgetCalculationSettings, calendar: Calendar, today: Date
    ) -> [(category: Category, amount: Decimal)] {
        var rows: [(category: Category, amount: Decimal)]
        if period.kind.isMonthBased, let month = AskClarityEngine.monthDate(for: period.kind, today: today, calendar: calendar) {
            let summary = BudgetCalculator.periodSpendingSummary(month: month, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, respectHiddenCategories: true, calendar: calendar)
            rows = summary.byCategory.filter { $0.actual > 0 }.map { (category: $0.category, amount: $0.actual) }.sorted { $0.amount > $1.amount }
        } else if let (start, end) = AskClarityEngine.dateBounds(for: period.kind, today: today, calendar: calendar) {
            rows = AskClarityRangeCalculator.categoryTotals(from: start, to: end, entries: entries)
        } else {
            rows = []
        }
        if let onlyCategories {
            let ids = Set(onlyCategories.map(ObjectIdentifier.init))
            rows = rows.filter { ids.contains(ObjectIdentifier($0.category)) }
        }
        return rows
    }

    private static func executeCategoryRanking(
        plan: AskClarityPlan, entries: [Entry], budgets: [Budget], headCategories: [HeadCategory], settings: BudgetCalculationSettings, calendar: Calendar, today: Date
    ) -> AskClarityExecutionResult {
        let rows = categoryAmounts(period: plan.period, onlyCategories: nil, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
        return .categoryRanking(rows: rows)
    }

    private static func executeCategoryBreakdown(
        plan: AskClarityPlan, entries: [Entry], budgets: [Budget], headCategories: [HeadCategory], settings: BudgetCalculationSettings, calendar: Calendar, today: Date
    ) -> AskClarityExecutionResult {
        let onlyCategories = plan.subjects.first?.categories
        let rows = categoryAmounts(period: plan.period, onlyCategories: onlyCategories, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
        return .categoryRanking(rows: rows)
    }

    private static func executeTransactionRanking(plan: AskClarityPlan, entries: [Entry], calendar: Calendar, today: Date) -> AskClarityExecutionResult {
        guard let (start, end) = AskClarityEngine.calendarBounds(for: plan.period.kind, today: today, calendar: calendar) else { return .unresolvable }
        let smallest = plan.ranking?.direction == .lowest

        if plan.ranking?.wantsList == true {
            let list = AskClarityRangeCalculator.topExpenses(from: start, to: end, entries: entries, limit: 3, smallest: smallest)
            return .transactionRanking(entries: list)
        }
        // Kept on `topExpense` (not `topExpenses(limit: 1)`) for the single-winner case so a tie
        // resolves exactly as it always has — `topExpenses`' stable sort and `topExpense`'s
        // `max(by:)`/`min(by:)` don't necessarily pick the same element among equal amounts.
        guard let top = AskClarityRangeCalculator.topExpense(from: start, to: end, entries: entries, smallest: smallest) else {
            return .transactionRanking(entries: [])
        }
        return .transactionRanking(entries: [top])
    }

    // MARK: - Budget state

    private static func executeBudgetState(
        plan: AskClarityPlan, entries: [Entry], budgets: [Budget], headCategories: [HeadCategory], settings: BudgetCalculationSettings, calendar: Calendar, today: Date
    ) -> AskClarityExecutionResult {
        guard plan.period.kind.isMonthBased, let month = AskClarityEngine.monthDate(for: plan.period.kind, today: today, calendar: calendar) else {
            return .unresolvable
        }
        if let category = plan.subjects.first?.singleCategory {
            let summary = BudgetCalculator.periodSpendingSummary(month: month, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, respectHiddenCategories: true, calendar: calendar)
            let row = summary.byCategory.first { $0.category === category }
            return .budgetState(categoryRow: row, health: [])
        }
        let health = OverviewCalculator.categorySpendingHealth(month: month, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar)
        return .budgetState(categoryRow: nil, health: health)
    }

    // MARK: - Trend

    /// Walks `AskClarityPeriodKind.previousEquivalent` backward from `plan.period`, up to
    /// `plan.trendSpan` (defaulting to 3, capped/floored to at least 2) times, stopping early
    /// wherever the chain runs out (e.g. a week-based period only ever chains back one step) —
    /// never fabricating a period further back than this architecture actually supports.
    ///
    /// `.lastMonth` is the one exception: `previousEquivalent(.lastMonth)` deliberately returns
    /// `nil` (see its doc comment — "the month before last" is out of scope for a plain *single-
    /// step* comparison), but `.specificMonth` already supports chaining indefinitely, and
    /// `.lastMonth` denotes the exact same calendar month as `.specificMonth(thatMonth's Date)`.
    /// So once the chain reaches `.lastMonth`, it bridges to that `.specificMonth` form and keeps
    /// walking — a trend needs however many months it needs, unlike a one-off comparison — without
    /// changing `previousEquivalent`'s contract for anything else that calls it.
    private static func executeTrend(
        plan: AskClarityPlan, entries: [Entry], budgets: [Budget], headCategories: [HeadCategory], settings: BudgetCalculationSettings, calendar: Calendar, today: Date
    ) -> AskClarityExecutionResult {
        let span = max(plan.trendSpan ?? 3, 2)
        var chain = [plan.period]
        var currentKind = plan.period.kind
        while chain.count < span {
            if let (previousKind, label) = currentKind.previousEquivalent(today: today, calendar: calendar) {
                chain.append(AskClarityPeriod(kind: previousKind, label: label))
                currentKind = previousKind
                continue
            }
            if currentKind == .lastMonth,
               let lastMonthDate = AskClarityEngine.monthDate(for: .lastMonth, today: today, calendar: calendar),
               let (previousKind, label) = AskClarityPeriodKind.specificMonth(lastMonthDate).previousEquivalent(today: today, calendar: calendar) {
                chain.append(AskClarityPeriod(kind: previousKind, label: label))
                currentKind = previousKind
                continue
            }
            break
        }

        func amount(for period: AskClarityPeriod) -> Decimal? {
            if let subject = plan.subjects.first {
                return AskClarityEngine.categoriesSpending(
                    categories: subject.categories, period: period, entries: entries, budgets: budgets,
                    headCategories: headCategories, settings: settings, calendar: calendar, today: today
                )
            }
            return AskClarityEngine.metricTotal(
                metric: plan.metric, period: period, entries: entries, budgets: budgets,
                headCategories: headCategories, settings: settings, calendar: calendar, today: today
            )
        }

        let points: [(period: AskClarityPeriod, amount: Decimal)] = chain.reversed().compactMap { period in
            amount(for: period).map { (period: period, amount: $0) }
        }
        return .trend(points: points)
    }
}
