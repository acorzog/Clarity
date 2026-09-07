import SwiftUI
import SwiftData
import Charts

struct OverviewSummaryView: View {
    let month: Date

    @ObservedObject private var settings = OverviewSettingsStore.shared
    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]

    private var monthEntries: [Entry] { allEntries.inMonth(month) }
    private var income: Decimal { monthEntries.totalIncome }
    private var expenses: Decimal { monthEntries.totalExpenses }

    private var trend: [MonthlyTotal] {
        (0..<6).reversed().compactMap { offset -> MonthlyTotal? in
            guard let monthDate = Calendar.current.date(byAdding: .month, value: -offset, to: month) else {
                return nil
            }
            return MonthlyTotal(month: monthDate, total: allEntries.inMonth(monthDate).totalExpenses)
        }
    }

    private var topCategories: [TopCategory] {
        var sums: [PersistentIdentifier: Decimal] = [:]
        var lookup: [PersistentIdentifier: Category] = [:]

        for entry in monthEntries where entry.type == .expense {
            guard let category = entry.category else { continue }
            let id = category.persistentModelID
            sums[id, default: 0] += entry.amount
            lookup[id] = category
        }

        return sums
            .sorted { $0.value > $1.value }
            .prefix(5)
            .compactMap { id, amount in
                lookup[id].map { TopCategory(name: $0.name, amount: amount, colorHex: $0.resolvedColorHex) }
            }
    }

    var body: some View {
        VStack(spacing: 20) {
            ForEach(settings.visibleCards) { card in
                cardView(for: card)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private func cardView(for card: OverviewCard) -> some View {
        switch card {
        case .insights:
            SpendingInsightsCardView(month: month)
        case .summary:
            SummaryCard(income: income, expenses: expenses)
        case .trends:
            InsightsSummaryCard(trend: trend, topCategories: topCategories)
        case .calendar:
            CalendarCard(month: month)
        }
    }
}

private struct MonthlyTotal: Identifiable {
    var id: Date { month }
    let month: Date
    let total: Decimal
}

private struct TopCategory: Identifiable {
    var id: String { name }
    let name: String
    let amount: Decimal
    let colorHex: String
}

private struct InsightsSummaryCard: View {
    let trend: [MonthlyTotal]
    let topCategories: [TopCategory]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Insights")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))

            VStack(alignment: .leading, spacing: 8) {
                Text("6-Month Trend")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))

                Chart(trend) { item in
                    LineMark(
                        x: .value("Month", item.month, unit: .month),
                        y: .value("Spent", item.total.doubleValue)
                    )
                    .foregroundStyle(Color.emerald)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Month", item.month, unit: .month),
                        y: .value("Spent", item.total.doubleValue)
                    )
                    .foregroundStyle(Color.emerald)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                    }
                }
                .frame(height: 120)
            }

            if !topCategories.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Top Categories")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))

                    Chart(topCategories) { item in
                        BarMark(
                            x: .value("Amount", item.amount.doubleValue),
                            y: .value("Category", item.name)
                        )
                        .foregroundStyle(Color(hex: item.colorHex))
                        .annotation(position: .trailing) {
                            Text(item.amount.currencyFormatted)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks { _ in
                            AxisValueLabel()
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .frame(height: CGFloat(topCategories.count) * 36 + 20)
                }
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct SummaryCard: View {
    let income: Decimal
    let expenses: Decimal

    private var left: Decimal { income - expenses }
    private var leftColor: Color { left >= 0 ? .skyBlue : .expenseRed }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                StatColumn(title: "Income", amount: income, color: .emerald)
                Spacer()
                StatColumn(title: "Expenses", amount: expenses, color: .expenseRed)
                Spacer()
                StatColumn(title: "Left", amount: left, color: leftColor)
            }

            Chart {
                BarMark(x: .value("Type", "Income"), y: .value("Amount", income.doubleValue))
                    .foregroundStyle(Color.emerald)
                BarMark(x: .value("Type", "Expenses"), y: .value("Amount", expenses.doubleValue))
                    .foregroundStyle(Color.expenseRed)
                BarMark(x: .value("Type", "Left"), y: .value("Amount", left.doubleValue))
                    .foregroundStyle(leftColor)
            }
            .frame(height: 64)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        }
        .padding(20)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct StatColumn: View {
    let title: String
    let amount: Decimal
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
            Text(amount.currencyFormattedSummary)
                .font(.subheadline.bold())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CalendarCard: View {
    let month: Date

    var body: some View {
        VStack(spacing: 12) {
            Text("Calendar")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)

            CalendarView(month: month)
        }
        .padding(20)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24))
    }
}

