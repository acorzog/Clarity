import SwiftUI

/// Semantic typography tokens — see `CLARITY_DESIGN_SYSTEM.md` §7.
///
/// 100% system font, matching the existing app exactly — no custom typeface is introduced.
/// Named levels formalize the sizes/weights already dominant in the codebase (verified by
/// repo-wide grep during the Phase 2A-1 audit) rather than inventing a new scale.
extension Font {
    /// The amount-entry keypad field — `.system(size: 52, weight: .bold)`, matches
    /// `AddTransactionView`/`AddSharedExpenseView`'s existing hero amount field exactly.
    static let display = Font.system(size: 52, weight: .bold)
    /// Hero financial numbers — Safe to Spend, Net Worth, gauge center, summary totals.
    /// `.system(size: 34, weight: .bold)`, the most common existing hero-number size (5 sites).
    static let heroAmount = Font.system(size: 34, weight: .bold)
    /// Tab-root titles, rendered via `GradientHeader` — `.largeTitle.bold()`.
    static let pageTitle = Font.largeTitle.bold()
    /// Card/section headers — `.subheadline.weight(.semibold)`, the single most-used style in
    /// the app (34 existing call sites).
    static let sectionTitle = Font.subheadline.weight(.semibold)
    static let body = Font.subheadline
    static let secondaryBody = Font.subheadline
    static let caption = Font.caption
    static let footnote = Font.caption2
    /// Primary CTA button label — `.headline`, matches existing hand-rolled primary buttons
    /// (e.g. `SetWalletGoalView`'s Save).
    static let buttonLabel = Font.headline
}

/// Bundles the hero-amount font with the scale/line-limit behavior every existing hero number
/// already pairs it with, so a new large financial number can't accidentally ship without them —
/// see `CLARITY_DESIGN_SYSTEM.md` §7's explicit rule on this.
struct HeroAmountStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.heroAmount)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
    }
}

extension View {
    func heroAmountStyle() -> some View {
        modifier(HeroAmountStyle())
    }
}
