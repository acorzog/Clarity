import SwiftUI
import SwiftData

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
        allEntries.inMonth(month).filter { $0.type == .expense }
    }

    private var previousMonthExpenses: [Entry] {
        allEntries.inMonth(previousMonth).filter { $0.type == .expense }
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
        let expenseCategories = headCategories.flatMap { head in
            head.categories.filter { !$0.isIncome && !$0.isArchived }
        }
        let total = expenseCategories.reduce(Decimal(0)) { $0 + allBudgets.amount(for: $1, month: month) }
        return total > 0 ? total : nil
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
        .padding(20)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24))
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
