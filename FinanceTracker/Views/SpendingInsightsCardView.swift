import SwiftUI
import SwiftData

/// `SpendingInsightsCardView`'s financial inputs — pulled out as pure, non-private functions
/// (Phase 2N-G) so they're independently testable and so the card can no longer compute an
/// expense/budget figure that disagrees with `BudgetCalculator`/`BudgetEligibility`, the single
/// source every other budget/spending surface already goes through. Deliberately thin: this
/// applies the existing `.budgetEligible` gate and reuses `BudgetCalculator.plannedBudgetTotals`
/// rather than re-deriving either concern independently.
enum SpendingInsightsAggregation {
    /// Budget-eligible expense entries for `month` — matching every other budget/spending surface
    /// on the Overview screen (`SummaryMetricsRow`). An `excludeFromBudget` entry must not appear
    /// in an insight the deterministic summary above it doesn't count
    /// (`Models/BudgetEligibility.swift`). Calendar-month-anchored, matching this card's own
    /// existing period semantics — never Budget Cycle, which is unrelated to this fix.
    static func eligibleExpenses(from entries: [Entry], in month: Date) -> [Entry] {
        entries.inMonth(month).budgetEligible.filter { $0.type == .expense }
    }

    /// The planned-expense total for `month`, respecting hidden categories — reuses
    /// `BudgetCalculator.plannedBudgetTotals` (already calendar-month-anchored, already
    /// hidden-category-aware) instead of re-deriving category iteration independently. `nil`
    /// when nothing is budgeted, matching this card's existing "omit the budget line" behavior.
    static func budgetTotal(budgets: [Budget], headCategories: [HeadCategory], month: Date) -> Decimal? {
        let total = BudgetCalculator.plannedBudgetTotals(month: month, budgets: budgets, headCategories: headCategories).totalPlannedExpenses
        return total > 0 ? total : nil
    }
}

/// AI-generated natural-language summary of a month's spending, shown at the top of the
/// Overview sub-tab. Loads the cached summary for `month` if one exists; otherwise generates
/// one. Supports pull-to-refresh (bubbles up to the enclosing ScrollView) and a manual refresh
/// button, both of which always regenerate — bypassing the cache — via `SpendingInsightsService`.
struct SpendingInsightsCardView: View {
    let month: Date

    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]
    @Query private var allBudgets: [Budget]
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]

    @State private var summary: String?
    @State private var isLoading = false
    @State private var hasFailed = false

    private var previousMonth: Date {
        Calendar.current.date(byAdding: .month, value: -1, to: month) ?? month
    }

    private var monthExpenses: [Entry] {
        SpendingInsightsAggregation.eligibleExpenses(from: allEntries, in: month)
    }

    private var previousMonthExpenses: [Entry] {
        SpendingInsightsAggregation.eligibleExpenses(from: allEntries, in: previousMonth)
    }

    private var topCategories: [SpendingInsightsService.CategoryAmount] {
        var currentSums: [PersistentIdentifier: Decimal] = [:]
        var lookup: [PersistentIdentifier: Category] = [:]
        for entry in monthExpenses {
            guard let category = entry.category else { continue }
            let id = category.persistentModelID
            currentSums[id, default: 0] += entry.amount
            lookup[id] = category
        }

        var previousSums: [PersistentIdentifier: Decimal] = [:]
        for entry in previousMonthExpenses {
            guard let category = entry.category else { continue }
            previousSums[category.persistentModelID, default: 0] += entry.amount
        }

        return currentSums
            .sorted { $0.value > $1.value }
            .prefix(5)
            .compactMap { id, amount in
                lookup[id].map {
                    SpendingInsightsService.CategoryAmount(
                        name: $0.name,
                        currentTotal: amount,
                        previousTotal: previousSums[id]
                    )
                }
            }
    }

    private var topTransactions: [SpendingInsightsService.TransactionAmount] {
        monthExpenses
            .sorted { $0.amount > $1.amount }
            .prefix(5)
            .map {
                SpendingInsightsService.TransactionAmount(
                    category: $0.category?.name ?? "Uncategorized",
                    amount: $0.amount
                )
            }
    }

    private var budgetTotal: Decimal? {
        SpendingInsightsAggregation.budgetTotal(budgets: allBudgets, headCategories: headCategories, month: month)
    }

    private var aggregates: SpendingInsightsService.MonthlyAggregates {
        .init(
            month: month,
            topCategories: topCategories,
            topTransactions: topTransactions,
            currentMonthTotal: monthExpenses.totalExpenses,
            previousMonthTotal: previousMonthExpenses.isEmpty ? nil : previousMonthExpenses.totalExpenses,
            budgetTotal: budgetTotal
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spending Insights")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                }
                .foregroundStyle(.white.opacity(0.6))
                .disabled(isLoading)
            }

            if isLoading && summary == nil {
                Text("Generating insights…")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
            } else if let summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
            } else if hasFailed {
                Text("Couldn't generate insights right now. Tap refresh to try again.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                Text("No spending yet this month.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .surface(.primary, radius: ClarityRadius.large, padding: ClaritySpacing.xl)
        .refreshable { await refresh() }
        .task(id: month) { await loadOrGenerate() }
    }

    private func loadOrGenerate() async {
        hasFailed = false
        if let cached = SpendingInsightsService.cachedSummary(for: month) {
            summary = cached
            return
        }
        guard !monthExpenses.isEmpty else { return }
        await refresh()
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        hasFailed = false

        guard let text = await SpendingInsightsService.generateSummary(for: aggregates) else {
            hasFailed = true
            return
        }
        summary = text
    }
}

#Preview {
    SpendingInsightsCardView(month: .startOfMonth())
        .padding()
        .darkScreenBackground()
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self, SpendingInsight.self], inMemory: true)
}
