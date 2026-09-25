import Foundation

/// Semantic corner-radius scale — see `CLARITY_DESIGN_SYSTEM.md` §9.
///
/// Formalizes the values already dominant in the codebase (verified by repo-wide grep:
/// `cornerRadius: 20` ×15, `24` ×12, `16` ×11 are the three real clusters; `10`/`14`/`12` are
/// minor variants) rather than introducing a new radius. `large` (20) is the default for a new
/// card per the design system's governance rule (§9); `extraLarge` (24) is reserved for hero/
/// summary cards.
enum ClarityRadius {
    static let small: CGFloat = 12
    static let medium: CGFloat = 16
    static let large: CGFloat = 20
    static let extraLarge: CGFloat = 24
    /// A radius large enough to fully round any reasonably-sized control — for pill/capsule-style
    /// elements. Prefer `Capsule()` directly where the shape (not just the radius) matters.
    static let pill: CGFloat = 999
}
