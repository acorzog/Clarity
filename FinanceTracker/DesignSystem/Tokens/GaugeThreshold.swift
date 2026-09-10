import SwiftUI

/// The shared "how alarmed should this progress ring look" rule — extracted from
/// `RemainingView.RemainingGauge.arcColor` and `BudgetGaugeWidget.BudgetGaugeWidgetView.
/// ringColor`, which independently duplicated this exact branching logic (and the warning-color
/// literal it used) byte-for-byte.
///
/// `RemainingGauge` (in-app) and `BudgetGaugeWidgetView` (WidgetKit) are not merged into one
/// component — a widget's rendering constraints and the in-app gauge's per-category radial
/// labels make them genuinely different views, not the same primitive wearing two skins (see
/// `CLARITY_DESIGN_SYSTEM.md` §16's explicit "don't force abstraction" guidance for this exact
/// case). This is the narrower, safe consolidation: the *rule* for what counts as "on track,"
/// "approaching the limit," and "over," expressed once, so both can never silently disagree
/// about where the amber/red thresholds fall.
///
/// Pure presentation logic — does not read or derive any financial figure itself; callers pass
/// in an already-calculated progress fraction (e.g. `totalSpent / totalAvailable`, from
/// `BudgetCalculator.periodSpendingSummary`).
enum GaugeThreshold {
    /// - Parameter progress: spent/available, expected in `0...1+` (values above 1 mean over
    ///   budget and are treated the same as exactly 1).
    static func color(forProgress progress: Double) -> Color {
        if progress >= 1 { return .expense }
        if progress >= 0.85 { return .warning }
        return .income
    }
}
