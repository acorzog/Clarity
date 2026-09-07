import SwiftUI
import SwiftData

struct RemainingView: View {
    let month: Date

    @ObservedObject private var settings = BudgetSettingsStore.shared
    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]
    @Query private var allBudgets: [Budget]
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]

    private var periodEntries: [Entry] {
        allEntries.inBudgetPeriod(month, startDay: settings.cycleStartDay)
    }

    private var monthExpenses: [Entry] {
        periodEntries.filter { $0.type == .expense }
    }

    private var monthTransfers: [Entry] {
        periodEntries.filter { $0.type == .transfer }
    }

    private func entries(for category: Category) -> [Entry] {
        monthExpenses.filter { $0.category === category }
    }

    private func spent(for category: Category) -> Decimal {
        entries(for: category).reduce(Decimal(0)) { $0 + $1.amount }
    }

    private func budgeted(for category: Category) -> Decimal {
        allBudgets.amount(for: category, month: month)
    }

    private func expenseCategories(for head: HeadCategory) -> [Category] {
        head.categories.filter { !$0.isIncome && !$0.isArchived }.sorted { $0.name < $1.name }
    }

    private var headSummaries: [HeadRemainingSummary] {
        headCategories.compactMap { head in
            let categories = expenseCategories(for: head)
            guard !categories.isEmpty else { return nil }
            let budget = categories.reduce(Decimal(0)) { $0 + budgeted(for: $1) }
            let spentTotal = categories.reduce(Decimal(0)) { $0 + spent(for: $1) }
            guard budget > 0 || spentTotal > 0 else { return nil }
            return HeadRemainingSummary(id: head.id, name: head.name, colorHex: head.colorHex, budgeted: budget, spent: spentTotal)
        }
    }

    private var totalBudgeted: Decimal {
        headCategories.flatMap { expenseCategories(for: $0) }.reduce(Decimal(0)) { $0 + budgeted(for: $1) }
    }

    private var totalIncome: Decimal {
        periodEntries.filter { $0.type == .income }.reduce(Decimal(0)) { $0 + $1.amount }
    }

    /// Expenses whose category has no monthly limit set (or no category at all) — folded into
    /// an "Other Expenses" bucket when `settings.includeUnplannedAsOtherExpenses` is on.
    private var otherExpenses: [Entry] {
        monthExpenses.filter { entry in
            guard let category = entry.category else { return true }
            return budgeted(for: category) == 0
        }
    }

    private var otherExpensesTotal: Decimal {
        otherExpenses.reduce(Decimal(0)) { $0 + $1.amount }
    }

    private var savingsTransfersTotal: Decimal {
        monthTransfers.filter { $0.destinationWallet?.type == .savings }.reduce(Decimal(0)) { $0 + $1.amount }
    }

    private var debtTransfersTotal: Decimal {
        monthTransfers.filter { $0.destinationWallet?.type == .debt }.reduce(Decimal(0)) { $0 + $1.amount }
    }

    private var otherRows: [OtherSpendingRow] {
        var rows: [OtherSpendingRow] = []
        if settings.includeUnplannedAsOtherExpenses && otherExpensesTotal > 0 {
            rows.append(OtherSpendingRow(title: "Other Expenses", amount: otherExpensesTotal, icon: "questionmark.circle.fill"))
        }
        if settings.includeSavingsTransfers && savingsTransfersTotal > 0 {
            rows.append(OtherSpendingRow(title: "Savings Transfers", amount: savingsTransfersTotal, icon: "banknote.fill"))
        }
        if settings.includeDebtTransfers && debtTransfersTotal > 0 {
            rows.append(OtherSpendingRow(title: "Debt Payments", amount: debtTransfersTotal, icon: "creditcard.fill"))
        }
        return rows
    }

    private var totalSpent: Decimal {
        var total = monthExpenses.reduce(Decimal(0)) { $0 + $1.amount }
        if !settings.includeUnplannedAsOtherExpenses {
            total -= otherExpensesTotal
        }
        if settings.includeSavingsTransfers {
            total += savingsTransfersTotal
        }
        if settings.includeDebtTransfers {
            total += debtTransfersTotal
        }
        return total
    }

    /// What "Left to Spend" is measured against. A manual monthly budget goal (set in Budget
    /// Settings) takes priority when set; otherwise income actually received this period is real
    /// money available to spend, so it takes priority over the expense-category budget total —
    /// otherwise a wallet full of income shows as unavailable just because it wasn't assigned to
    /// a specific expense category. Falls back to the budgeted total for periods with no income
    /// tracked at all, so pure budget-only users see the same behavior as before.
    private var totalAvailable: Decimal {
        if settings.manualMonthlyBudget > 0 { return settings.manualMonthlyBudget }
        return totalIncome > 0 ? totalIncome : totalBudgeted
    }

    var body: some View {
        if totalAvailable == 0 && totalSpent == 0 {
            EmptyStateView(
                icon: "gauge.with.needle",
                title: "No Budget Set",
                message: "Set monthly limits in the Plan tab to see what's left to spend."
            )
        } else {
            VStack(spacing: 24) {
                RemainingGauge(totalAvailable: totalAvailable, totalSpent: totalSpent, breakdown: headSummaries)

                VStack(spacing: 16) {
                    ForEach(headCategories) { head in
                        let categories = expenseCategories(for: head)
                        if let summary = headSummaries.first(where: { $0.id == head.id }) {
                            HeadRemainingSection(
                                head: summary,
                                categories: categories,
                                spentFor: spent,
                                budgetedFor: budgeted,
                                entriesFor: entries
                            )
                        }
                    }

                    if !otherRows.isEmpty {
                        OtherSpendingCard(rows: otherRows)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }
}

private struct OtherSpendingRow: Identifiable {
    var id: String { title }
    let title: String
    let amount: Decimal
    let icon: String
}

private struct OtherSpendingCard: View {
    let rows: [OtherSpendingRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Other")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 12) {
                        Image(systemName: row.icon)
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 20)
                        Text(row.title)
                            .foregroundStyle(.white)
                        Spacer()
                        Text(row.amount.currencyFormatted)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)

                    if row.id != rows.last?.id {
                        Divider().background(Color.white.opacity(0.08)).padding(.leading, 44)
                    }
                }
            }
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

private struct HeadRemainingSummary: Identifiable {
    let id: PersistentIdentifier
    let name: String
    let colorHex: String
    let budgeted: Decimal
    let spent: Decimal
    var left: Decimal { budgeted - spent }
}

private struct RemainingGauge: View {
    let totalAvailable: Decimal
    let totalSpent: Decimal
    let breakdown: [HeadRemainingSummary]

    private let gaugeSize: CGFloat = 230
    private let labelRadius: CGFloat = 162

    private var progress: Double {
        guard totalAvailable > 0 else { return 0 }
        return min(max((totalSpent / totalAvailable).doubleValue, 0), 1)
    }

    private var totalLeft: Decimal { totalAvailable - totalSpent }

    private var arcColor: Color {
        guard totalAvailable > 0 else { return .white.opacity(0.3) }
        let fraction = (totalSpent / totalAvailable).doubleValue
        if fraction >= 1 { return .expenseRed }
        if fraction >= 0.85 { return Color(red: 0.98, green: 0.68, blue: 0.16) }
        return .emerald
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 20, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: gaugeSize, height: gaugeSize)

            Circle()
                .trim(from: 0, to: 0.75 * progress)
                .stroke(arcColor, style: StrokeStyle(lineWidth: 20, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: gaugeSize, height: gaugeSize)

            ForEach(Array(breakdown.enumerated()), id: \.element.id) { index, head in
                let angle = angleDegrees(index: index, total: breakdown.count) * .pi / 180
                HeadArcLabel(head: head)
                    .offset(x: labelRadius * cos(angle), y: labelRadius * sin(angle))
            }

            VStack(spacing: 6) {
                Text("Left to Spend")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                Text(totalLeft.currencyFormatted)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .frame(width: gaugeSize * 0.55)
        }
        .frame(height: labelRadius * 2 + 50)
        .frame(maxWidth: .infinity)
    }

    private func angleDegrees(index: Int, total: Int) -> Double {
        guard total > 0 else { return 270 }
        return 135.0 + 270.0 * (Double(index) + 0.5) / Double(total)
    }
}

private struct HeadArcLabel: View {
    let head: HeadRemainingSummary

    var body: some View {
        VStack(spacing: 1) {
            Text(head.name)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(head.left.currencyFormatted)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(hex: head.colorHex))
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: 64)
    }
}

private struct HeadRemainingSection: View {
    let head: HeadRemainingSummary
    let categories: [Category]
    let spentFor: (Category) -> Decimal
    let budgetedFor: (Category) -> Decimal
    let entriesFor: (Category) -> [Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(Color(hex: head.colorHex))
                    .frame(width: 10, height: 10)
                Text(head.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(head.left.currencyFormatted) left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(head.left >= 0 ? Color.white.opacity(0.6) : Color.expenseRed)
            }

            VStack(spacing: 0) {
                ForEach(categories) { category in
                    NavigationLink {
                        CategoryEntriesDetailView(title: category.name, entries: entriesFor(category))
                    } label: {
                        CategoryProgressRow(
                            name: category.name,
                            colorHex: category.resolvedColorHex,
                            spent: spentFor(category),
                            budgeted: budgetedFor(category)
                        )
                    }
                    .buttonStyle(.plain)
                    if category !== categories.last {
                        Divider().background(Color.white.opacity(0.08)).padding(.leading, 60)
                    }
                }
            }
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}


private struct CategoryProgressRow: View {
    let name: String
    let colorHex: String
    let spent: Decimal
    let budgeted: Decimal

    private var progress: Double {
        guard budgeted > 0 else { return spent > 0 ? 1 : 0 }
        return min((spent / budgeted).doubleValue, 1)
    }

    private var isOverBudget: Bool { budgeted > 0 && spent > budgeted }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        isOverBudget ? Color.expenseRed : Color(hex: colorHex),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 32, height: 32)

            Text(name)
                .foregroundStyle(.white)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(spent.currencyFormatted)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isOverBudget ? Color.expenseRed : Color.white)
                Text("of \(budgeted.currencyFormatted)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }
}
