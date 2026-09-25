import SwiftUI
import SwiftData
import Charts

struct InsightsView: View {
    let month: Date

    @ObservedObject private var settings = BudgetSettingsStore.shared
    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]
    @Query private var allBudgets: [Budget]
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]

    /// The same shared calculation Remaining uses — see `BudgetCalculator.periodSpendingSummary`.
    /// Per the Phase 1 product decision, "actual" here is scoped to the configurable budget
    /// cycle (not the plain calendar month this view used before), so Insights and Remaining can
    /// no longer disagree about which entries count as "this period."
    private var summary: PeriodSpendingSummary {
        BudgetCalculator.periodSpendingSummary(
            month: month,
            entries: allEntries,
            budgets: allBudgets,
            headCategories: headCategories,
            settings: BudgetCalculationSettings(from: settings),
            respectHiddenCategories: true
        )
    }

    /// Most-planned-first so the categories most worth a glance land in the initially visible
    /// area of the horizontally-scrolling chart, instead of in whatever order `HeadCategory.
    /// sortOrder` happens to put them — with many categories, that order could bury a
    /// heavily-planned one off the right edge, behind a lightly-planned or unplanned one.
    private var headComparisons: [HeadComparison] {
        summary.byHeadCategory
            .map { HeadComparison(id: $0.headCategory.id, name: $0.headCategory.name, planned: $0.planned, actual: $0.actual) }
            .sorted { $0.planned > $1.planned }
    }

    private var dailySpend: [DailyPacePoint] {
        BudgetCalculator.spendingPace(
            month: month,
            entries: allEntries,
            settings: BudgetCalculationSettings(from: settings),
            totalPlanned: summary.totalBudgeted
        )
    }

    private var hasData: Bool {
        !headComparisons.isEmpty || summary.totalBudgeted > 0 || summary.totalSpent > 0
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
                SpendPaceCard(data: dailySpend, totalBudget: summary.totalBudgeted)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 24)
    }
}

extension InsightsView {
    /// Combined VoiceOver summary for the Planned vs. Actual grouped-bar chart — previously
    /// silent to VoiceOver, matching the exact gap Phase 2F/2F-B already fixed for the donut/trend
    /// charts elsewhere in the app (Phase 2J). Reads already-computed `planned`/`actual` values,
    /// never recalculates them.
    static func plannedVsActualAccessibilitySummary(data: [(name: String, planned: Decimal, actual: Decimal)]) -> String {
        guard !data.isEmpty else {
            return "Planned versus actual spending. No budgeted or spent categories this month yet."
        }
        let lines = data.map { "\($0.name): planned \($0.planned.currencyFormatted), actual \($0.actual.currencyFormatted)." }
        return (["Planned versus actual spending, by category."] + lines).joined(separator: " ")
    }

    /// Combined VoiceOver summary for the Spending Pace dual-line chart — same rationale as
    /// above. Reports only the latest data point (today's position), matching what the chart's
    /// two lines visually converge on; the full daily series isn't read point-by-point since
    /// `onPace`'s straight-line values carry no individual meaning outside that comparison.
    static func spendPaceAccessibilitySummary(totalBudget: Decimal, data: [DailyPacePoint]) -> String {
        guard totalBudget > 0 else {
            return "Spending pace. No budget set for this period."
        }
        let headline = "Spending pace against a budget of \(totalBudget.currencyFormatted)."
        guard let latest = data.last(where: { $0.actual != nil }), let actual = latest.actual else {
            return "\(headline) No spending recorded yet."
        }
        let comparison = actual > latest.onPace ? "ahead of pace" : "on pace or under"
        return "\(headline) Day \(latest.day): spent \(actual.currencyFormatted), \(comparison)."
    }
}

private struct HeadComparison: Identifiable {
    let id: PersistentIdentifier
    let name: String
    let planned: Decimal
    let actual: Decimal
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
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        InsightsView.plannedVsActualAccessibilitySummary(
                            data: data.map { (name: $0.name, planned: $0.planned, actual: $0.actual) }
                        )
                    )
                }
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct SpendPaceCard: View {
    let data: [DailyPacePoint]
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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(InsightsView.spendPaceAccessibilitySummary(totalBudget: totalBudget, data: data))
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
    }
}
