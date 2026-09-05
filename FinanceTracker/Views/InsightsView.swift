import SwiftUI
import SwiftData
import Charts

struct InsightsView: View {
    let month: Date

    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]
    @Query private var allBudgets: [Budget]
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]

    private var monthExpenses: [Entry] {
        allEntries.inMonth(month).filter { $0.type == .expense }
    }

    private var totalPlannedExpenses: Decimal {
        let (m, y) = month.monthYearComponents
        return allBudgets
            .filter { $0.month == m && $0.year == y && !$0.category.isIncome }
            .reduce(Decimal(0)) { $0 + $1.monthlyLimit }
    }

    private var headComparisons: [HeadComparison] {
        let (m, y) = month.monthYearComponents

        return headCategories.compactMap { head in
            let categoryIDs = Set(head.categories.filter { !$0.isIncome && !$0.isArchived }.map(\.id))
            guard !categoryIDs.isEmpty else { return nil }

            let planned = allBudgets
                .filter { $0.month == m && $0.year == y && categoryIDs.contains($0.category.id) }
                .reduce(Decimal(0)) { $0 + $1.monthlyLimit }
            let actual = monthExpenses
                .filter { $0.category.map { categoryIDs.contains($0.id) } == true }
                .reduce(Decimal(0)) { $0 + $1.amount }

            guard planned > 0 || actual > 0 else { return nil }
            return HeadComparison(id: head.id, name: head.name, planned: planned, actual: actual)
        }
    }

    private var dailySpend: [DailySpend] {
        let calendar = Calendar.current
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let daysInMonth = range.count
        let perDayPace = daysInMonth > 0 ? totalPlannedExpenses / Decimal(daysInMonth) : 0

        let lastDataDay: Int
        if calendar.isDate(month, equalTo: .now, toGranularity: .month) {
            lastDataDay = calendar.component(.day, from: .now)
        } else if month < .startOfMonth() {
            lastDataDay = daysInMonth
        } else {
            lastDataDay = 0
        }

        var cumulative: Decimal = 0
        return (1...daysInMonth).map { day in
            var actual: Decimal?
            if day <= lastDataDay {
                let dayTotal = monthExpenses
                    .filter { calendar.component(.day, from: $0.date) == day }
                    .reduce(Decimal(0)) { $0 + $1.amount }
                cumulative += dayTotal
                actual = cumulative
            }
            return DailySpend(day: day, actual: actual, onPace: perDayPace * Decimal(day))
        }
    }

    private var hasData: Bool {
        !headComparisons.isEmpty || totalPlannedExpenses > 0 || !monthExpenses.isEmpty
    }

    var body: some View {
        VStack(spacing: 20) {
            if !hasData {
                EmptyStateView(
                    icon: "chart.bar",
                    title: "No Budget History",
                    message: "Set budgets and log a few transactions to see planned-vs-actual insights here."
                )
            } else {
                PlannedVsActualCard(data: headComparisons)
                SpendPaceCard(data: dailySpend, totalBudget: totalPlannedExpenses)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 24)
    }
}

private struct HeadComparison: Identifiable {
    let id: PersistentIdentifier
    let name: String
    let planned: Decimal
    let actual: Decimal
}

private struct DailySpend: Identifiable {
    var id: Int { day }
    let day: Int
    let actual: Decimal?
    let onPace: Decimal
}

private struct PlannedVsActualCard: View {
    let data: [HeadComparison]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Planned vs. Actual")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            if data.isEmpty {
                Text("No budgeted or spent categories this month yet.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Chart(data) { item in
                        BarMark(
                            x: .value("Category", item.name),
                            y: .value("Amount", item.planned.doubleValue)
                        )
                        .foregroundStyle(by: .value("Type", "Planned"))
                        .position(by: .value("Type", "Planned"))

                        BarMark(
                            x: .value("Category", item.name),
                            y: .value("Amount", item.actual.doubleValue)
                        )
                        .foregroundStyle(by: .value("Type", "Actual"))
                        .position(by: .value("Type", "Actual"))
                    }
                    .chartForegroundStyleScale([
                        "Planned": Color.skyBlue,
                        "Actual": Color.emerald
                    ])
                    .chartXAxis {
                        AxisMarks { _ in
                            AxisValueLabel()
                                .foregroundStyle(Color.white.opacity(0.5))
                        }
                    }
                    .chartYAxis {
                        AxisMarks { _ in
                            AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                        }
                    }
                    .chartLegend(position: .bottom, spacing: 8)
                    .frame(width: max(300, CGFloat(data.count) * 90), height: 200)
                }
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct SpendPaceCard: View {
    let data: [DailySpend]
    let totalBudget: Decimal

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spending Pace")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("Budget \(totalBudget.currencyFormatted)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
            }

            if totalBudget == 0 {
                Text("Set a budget in the Plan tab to see your pace against it.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            } else {
                Chart {
                    ForEach(data) { point in
                        LineMark(
                            x: .value("Day", point.day),
                            y: .value("On Pace", point.onPace.doubleValue)
                        )
                        .foregroundStyle(by: .value("Series", "On Pace"))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                        .interpolationMethod(.linear)
                    }

                    ForEach(data.filter { $0.actual != nil }) { point in
                        LineMark(
                            x: .value("Day", point.day),
                            y: .value("Spent", (point.actual ?? 0).doubleValue)
                        )
                        .foregroundStyle(by: .value("Series", "Spent"))
                        .interpolationMethod(.catmullRom)
                    }
                }
                .chartForegroundStyleScale([
                    "On Pace": Color.white.opacity(0.4),
                    "Spent": Color.emerald
                ])
                .chartXAxis {
                    AxisMarks(values: .stride(by: 7)) { _ in
                        AxisValueLabel()
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                    }
                }
                .chartLegend(position: .bottom, spacing: 8)
                .frame(height: 200)
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
    }
}
