import SwiftUI

/// Semantic color tokens — see `CLARITY_DESIGN_SYSTEM.md` §5-6.
///
/// These formalize colors already in use across the app (`Views/Theme.swift`'s `Color.
/// appBackground`/`.emerald`/`.skyBlue`/`.expenseRed`, plus the raw `Color.white.opacity(...)`
/// literals repeated at dozens of call sites) under names that describe *meaning* rather than
/// *hue* — e.g. `Color.textSecondary` reads as "the second-most-prominent text color" wherever
/// it's used, instead of every call site independently deciding that `0.6` opacity means that.
///
/// Deliberately does not introduce parallel names for `.emerald`/`.skyBlue`/`.appBackground`
/// themselves (`Theme.swift`'s existing names already serve that purpose and are used
/// pervasively) — only for values that were previously raw literals with no shared name.
extension Color {

    // MARK: - Surfaces (formalizes the two dominant existing opacities — 103 and 33 call sites
    // respectively, per the Phase 2A-1 audit — plus the existing minor "elevated" tier)

    /// The default card/section background — `Color.white.opacity(0.05)`, the single most-used
    /// surface value in the app.
    static let surfacePrimary = Color.white.opacity(0.05)
    /// List rows, icon-button backgrounds, secondary containers — `Color.white.opacity(0.08)`.
    static let surfaceSecondary = Color.white.opacity(0.08)
    /// Gauge track rings, selected/active backgrounds — the existing `0.10-0.15` tier.
    static let surfaceElevated = Color.white.opacity(0.12)

    // MARK: - Text (formalizes the existing three-tier white-opacity convention)

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.6)
    static let textTertiary = Color.white.opacity(0.4)
    static let textDisabled = Color.white.opacity(0.3)

    // MARK: - Financial semantics (formalizes `EntryRow.amountColor`'s existing, correct
    // convention as reusable, named tokens — see `Views/EntryRow.swift`)

    static let income = Color.emerald
    static let expense = Color.expenseRed
    static let transfer = Color.white.opacity(0.7)
    static let success = Color.emerald
    /// The 85%-of-budget gauge warning threshold — previously an unnamed literal duplicated
    /// identically in `RemainingView.swift` (`arcColor`) and `BudgetGaugeWidget.swift`
    /// (`ringColor`). Consolidated here as the one place that value is defined; see
    /// `GaugeThreshold.color(forProgress:)` for the shared branching logic that uses it.
    static let warning = Color(red: 0.98, green: 0.68, blue: 0.16)
    static let destructive = Color.expenseRed
    static let info = Color.skyBlue
}

/// Mirrors each token above as a `ShapeStyle`-constrained static var, so `.foregroundStyle(
/// .textSecondary)`/`.background(.surfacePrimary)`-style dot-shorthand resolves the same way it
/// already does for SwiftUI's own built-in colors (`.foregroundStyle(.red)`) — without this,
/// Swift's generic inference for `some ShapeStyle`-accepting APIs only finds members declared
/// directly on `ShapeStyle`, not arbitrary `Color` extension members, even though `Color`
/// conforms to `ShapeStyle`.
extension ShapeStyle where Self == Color {
    static var surfacePrimary: Color { .surfacePrimary }
    static var surfaceSecondary: Color { .surfaceSecondary }
    static var surfaceElevated: Color { .surfaceElevated }
    static var textPrimary: Color { .textPrimary }
    static var textSecondary: Color { .textSecondary }
    static var textTertiary: Color { .textTertiary }
    static var textDisabled: Color { .textDisabled }
    static var income: Color { .income }
    static var expense: Color { .expense }
    static var transfer: Color { .transfer }
    static var success: Color { .success }
    static var warning: Color { .warning }
    static var destructive: Color { .destructive }
    static var info: Color { .info }
}
