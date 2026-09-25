import SwiftUI

/// A hero label + value card — see `CLARITY_DESIGN_SYSTEM.md` §12 ("Financial Metrics" /
/// "Cards"). Formalizes `WalletsView.SummaryCard`'s existing shape (gradient-filled, large
/// scaled amount, centered) as the reusable "one important number" card.
///
/// Presentation-only: takes an already-formatted string, never a raw `Decimal` or a calculation
/// — per the design system's explicit rule that these components must not perform financial
/// arithmetic (`CLARITY_DESIGN_SYSTEM.md` §13, "Correct architecture: BudgetCalculator →
/// calculated value → FinancialMetric → visual presentation").
struct MetricCard: View {
    let title: String
    let value: String
    /// When `true`, fills with `accent.gradient` (matches `WalletsView.SummaryCard` exactly) —
    /// reserve for the single most important metric on a screen. `false` uses a plain surface.
    var isHero: Bool = true
    var valueColor: Color = .textPrimary

    var body: some View {
        VStack(spacing: ClaritySpacing.sm) {
            Text(value)
                .font(.heroAmount)
                .foregroundStyle(isHero ? .white : valueColor)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(title)
                .font(.body)
                .foregroundStyle(isHero ? .white.opacity(0.85) : .textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ClaritySpacing.xxxl)
        .padding(.horizontal, ClaritySpacing.lg)
        .background(
            isHero ? AnyShapeStyle(LinearGradient.emeraldSky) : AnyShapeStyle(Color.surfacePrimary),
            in: RoundedRectangle(cornerRadius: ClarityRadius.extraLarge)
        )
        .accessibilityElement(children: .combine)
    }
}
