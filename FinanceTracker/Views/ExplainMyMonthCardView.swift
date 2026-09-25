import SwiftUI
import SwiftData

/// A short, deterministic explanation of a month's spending — total spend, the comparison to last
/// month when one exists, categories that moved meaningfully, budget performance, one positive
/// highlight, and one area that may need attention. Every number and phrase here traces back to
/// `ExplainMyMonthCalculator.explain`'s already-computed `MonthExplanation`; this view only
/// formats/phrases it, exactly like `SpendingHealthCardView` does for `CategorySpendingHealth`.
///
/// Deliberately separate from `SpendingInsightsCardView` (the AI-generated free-text summary):
/// that card can fail, needs an API key, and isn't reproducible from the same data twice — this
/// one always renders from local data alone and never varies for the same inputs.
struct ExplainMyMonthCardView: View {
    let month: Date

    @ObservedObject private var budgetSettings = BudgetSettingsStore.shared
    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]
    @Query private var allBudgets: [Budget]
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]

    private var explanation: MonthExplanation {
        ExplainMyMonthCalculator.explain(
            month: month, entries: allEntries, budgets: allBudgets, headCategories: headCategories,
            settings: BudgetCalculationSettings(from: budgetSettings)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ClaritySpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Explain My Month")
                    .font(.sectionTitle)
                    .foregroundStyle(.textSecondary)
                // Sits right above the similarly-scoped "Spending Insights" card by default — this
                // is the one line telling them apart: exact figures here vs. an AI-written take
                // there, which can fail, need an API key, or phrase the same numbers differently
                // each time (see this file's own header doc comment).
                Text("Calculated directly from your transactions")
                    .font(.caption2)
                    .foregroundStyle(.textTertiary)
            }

            if !explanation.hasActivity {
                Text("No spending logged yet this month — check back once you've added a few transactions.")
                    .font(.subheadline)
                    .foregroundStyle(.textTertiary)
            } else {
                ExplainMyMonthContent(explanation: explanation)
            }
        }
        .surface(.secondary, radius: ClarityRadius.large, padding: ClaritySpacing.xl)
    }
}

private struct ExplainMyMonthContent: View {
    let explanation: MonthExplanation

    var body: some View {
        VStack(alignment: .leading, spacing: ClaritySpacing.md) {
            headline

            if !explanation.notableCategoryChanges.isEmpty {
                VStack(alignment: .leading, spacing: ClaritySpacing.sm) {
                    ForEach(explanation.notableCategoryChanges) { change in
                        NotableChangeRow(insight: change)
                    }
                }
            }

            if let performance = explanation.budgetPerformance {
                BudgetPerformanceRow(performance: performance)
            }

            if let positive = explanation.positiveHighlight {
                HighlightRow(highlight: positive, tint: .success, symbol: "checkmark.circle.fill", text: Self.positiveText(for: positive))
            }

            if let attention = explanation.attentionArea {
                HighlightRow(highlight: attention, tint: .warning, symbol: "exclamationmark.triangle.fill", text: Self.attentionText(for: attention))
            }
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: ClaritySpacing.xs) {
            Text(explanation.totalSpending.currencyFormatted)
                .font(.title2.weight(.bold))
                .foregroundStyle(.textPrimary)

            if let comparison = explanation.previousMonthComparison {
                TrendIndicator(
                    delta: abs(comparison.fraction).formatted(.percent.precision(.fractionLength(0))),
                    direction: comparison.direction == .up ? .up : .down,
                    isFavorable: comparison.direction == .down,
                    context: "vs. last month (\(comparison.previousTotal.currencyFormatted))"
                )
            } else {
                Text("Not enough history yet to compare to last month")
                    .font(.caption)
                    .foregroundStyle(.textTertiary)
            }
        }
    }

    static func positiveText(for highlight: ExplainMyMonthHighlight) -> String {
        switch highlight.kind {
        case .totalSpendingDown:
            let percent = (highlight.magnitudeFraction ?? 0).formatted(.percent.precision(.fractionLength(0)))
            let amount = highlight.amount?.currencyFormatted ?? ""
            return "You spent \(percent) less than last month, \(amount) saved."
        case .categoryDecrease:
            let percent = (highlight.magnitudeFraction ?? 0).formatted(.percent.precision(.fractionLength(0)))
            return "\(highlight.subject) is down \(percent) from last month."
        case .withinBudget:
            return "You stayed within budget this month."
        default:
            return ""
        }
    }

    static func attentionText(for highlight: ExplainMyMonthHighlight) -> String {
        switch highlight.kind {
        case .overBudgetCategory:
            let amount = highlight.amount?.currencyFormatted ?? ""
            return "\(highlight.subject) went \(amount) over its budget."
        case .aheadOfPace:
            return "You're spending faster than a steady pace for this month's budget."
        case .categoryIncrease:
            let percent = (highlight.magnitudeFraction ?? 0).formatted(.percent.precision(.fractionLength(0)))
            return "\(highlight.subject) is up \(percent) from last month."
        default:
            return ""
        }
    }
}

private struct NotableChangeRow: View {
    let insight: WhatsDifferentInsight

    private var percentText: String {
        (insight.magnitudeFraction ?? 0).formatted(.percent.precision(.fractionLength(0)))
    }

    private var message: String {
        let comparison = insight.direction == .up ? "higher" : "lower"
        return "\(insight.subject) is \(percentText) \(comparison) than last month"
    }

    var body: some View {
        HStack(alignment: .top, spacing: ClaritySpacing.sm) {
            DeltaIndicator(delta: percentText, direction: insight.direction == .up ? .up : .down, isFavorable: insight.isFavorable)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

private struct BudgetPerformanceRow: View {
    let performance: MonthBudgetPerformance

    private var stateColor: Color { GaugeThreshold.color(forProgress: performance.progress) }
    private var percentText: String { performance.progress.formatted(.percent.precision(.fractionLength(0))) }

    private var statusText: String {
        switch performance.state {
        case .overBudget: "over your \(performance.budgeted.currencyFormatted) budget"
        case .approachingLimit: "close to your \(performance.budgeted.currencyFormatted) budget"
        case .onTrack: "within your \(performance.budgeted.currencyFormatted) budget"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: ClaritySpacing.sm) {
            Image(systemName: "gauge.with.needle.fill")
                .font(.subheadline)
                .foregroundStyle(stateColor)
            Text("You're \(percentText) \(statusText) this month.")
                .font(.subheadline)
                .foregroundStyle(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HighlightRow: View {
    let highlight: ExplainMyMonthHighlight
    let tint: Color
    let symbol: String
    let text: String

    var body: some View {
        if !text.isEmpty {
            HStack(alignment: .top, spacing: ClaritySpacing.sm) {
                Image(systemName: symbol)
                    .font(.subheadline)
                    .foregroundStyle(tint)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(text)
        }
    }
}

#Preview {
    ExplainMyMonthCardView(month: .startOfMonth())
        .padding()
        .darkScreenBackground()
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
