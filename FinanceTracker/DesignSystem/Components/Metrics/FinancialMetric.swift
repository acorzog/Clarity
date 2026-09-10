import SwiftUI

/// A small labeled stat — formalizes `OverviewSummaryView.StatColumn`'s existing shape (label
/// above/below a colored amount) as a reusable component for "several metrics in a row"
/// contexts (Income/Expenses/Left-style summaries). Distinct from `MetricCard`, which is for one
/// hero number filling a whole card.
///
/// Presentation-only — takes an already-formatted value string.
struct FinancialMetric: View {
    let title: String
    let value: String
    var color: Color = .textPrimary
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: ClaritySpacing.xs) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.textSecondary)
            Text(value)
                .font(.body.bold())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: alignment == .leading ? .infinity : nil, alignment: Alignment(horizontal: alignment, vertical: .center))
        .accessibilityElement(children: .combine)
    }
}

/// A formatted percentage value — no existing UI precedent (percentages aren't shown anywhere
/// today), introduced ahead of Goals/Forecast per `CLARITY_DESIGN_SYSTEM.md` §21. Takes an
/// already-computed fraction (e.g. progress toward a goal); never computes one itself.
struct PercentageValue: View {
    /// 0...1 (or beyond, for an over-target state) — already computed by the caller.
    let fraction: Double
    var font: Font = .body
    var color: Color = .textPrimary

    var body: some View {
        Text(fraction, format: .percent.precision(.fractionLength(0)))
            .font(font)
            .foregroundStyle(color)
    }
}
