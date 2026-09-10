import SwiftUI

/// A small ▲/▼ + amount indicator for "did this change since last period" contexts (Home's
/// eventual What's Different?, per `CLARITY_DESIGN_SYSTEM.md` §12/§22). No existing UI shows
/// this today — `SpendingInsightsService.CategoryAmount.previousTotal` already computes the
/// comparison this visualizes, but nothing currently displays it as a dedicated component.
///
/// Direction-aware, not color-literal: an increase is not automatically "good" (more spending in
/// a category is unfavorable; more income is favorable) — the caller passes `isFavorable`
/// alongside the raw direction, rather than this component inferring meaning from sign alone.
/// Presentation-only — takes an already-computed delta string and direction.
struct DeltaIndicator: View {
    enum Direction {
        case up
        case down
        case flat
    }

    let delta: String
    let direction: Direction
    /// Whether this change is good news, bad news, or neutral — decided by the caller (e.g. an
    /// expense category increasing is unfavorable; income increasing is favorable).
    let isFavorable: Bool?

    private var color: Color {
        guard let isFavorable else { return .textSecondary }
        return isFavorable ? .success : .warning
    }

    private var symbolName: String {
        switch direction {
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .flat: "arrow.right"
        }
    }

    var body: some View {
        HStack(spacing: ClaritySpacing.xs) {
            Image(systemName: symbolName)
                .font(.caption.weight(.bold))
            Text(delta)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        let directionWord = switch direction {
        case .up: "Increased"
        case .down: "Decreased"
        case .flat: "Unchanged"
        }
        return "\(directionWord) by \(delta)"
    }
}

/// A compact trend label pairing a direction with context (e.g. "vs. last month") — a thin
/// wrapper around `DeltaIndicator` for the common case of a period-over-period comparison.
struct TrendIndicator: View {
    let delta: String
    let direction: DeltaIndicator.Direction
    let isFavorable: Bool?
    var context: String? = nil

    var body: some View {
        HStack(spacing: ClaritySpacing.xs) {
            DeltaIndicator(delta: delta, direction: direction, isFavorable: isFavorable)
            if let context {
                Text(context)
                    .font(.footnote)
                    .foregroundStyle(.textTertiary)
            }
        }
    }
}
