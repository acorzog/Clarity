import SwiftUI

/// A ring progress indicator for "how much of this budget has been used" — formalizes the ring
/// geometry already duplicated across `RemainingView.CategoryProgressRow`/`CategoryGridCell`
/// (list and grid variants of the same primitive) and shares its over/near/under-threshold
/// coloring with the two gauges via `GaugeThreshold` (see `Tokens/GaugeThreshold.swift`).
///
/// Presentation-only: takes an already-computed `progress` (0...1, clamped by the caller exactly
/// as the existing call sites already do — `min((spent / budgeted).doubleValue, 1)`) — never
/// reads `Entry`/`Budget`/`BudgetCalculator` itself.
///
/// Not yet adopted at `RemainingView`'s existing call sites in this phase — see the Phase 2A-2
/// implementation report for why (kept as an available, tested primitive rather than expanding
/// this phase's screen-migration footprint beyond the required 1-2 screens).
struct BudgetProgress: View {
    /// 0...1 — the caller is responsible for clamping, matching existing behavior.
    let progress: Double
    var isOverBudget: Bool = false
    var lineWidth: CGFloat = 4
    var diameter: CGFloat = 32
    var tintColor: Color? = nil

    private var ringColor: Color {
        if isOverBudget { return .expense }
        if let tintColor { return tintColor }
        return GaugeThreshold.color(forProgress: progress)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.surfaceElevated, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Budget progress")
        .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
    }
}
