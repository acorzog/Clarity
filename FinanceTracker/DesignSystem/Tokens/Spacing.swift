import Foundation

/// Semantic spacing scale — see `CLARITY_DESIGN_SYSTEM.md` §8.
///
/// Formalizes the values already dominant in the codebase (verified by repo-wide grep: `20` is
/// the single most-used explicit card padding, `24` the near-universal screen-bottom padding,
/// `12` the near-universal `HStack`/`VStack` icon-to-text spacing) rather than introducing new
/// values. Existing component-local constants with a genuine geometric reason (e.g.
/// `SwipeToDeleteRow`'s 72pt reveal width, `CalendarView`'s 6pt grid gaps) are intentionally left
/// as-is — this scale is for reusable layout rhythm, not every numeric literal in the app.
enum ClaritySpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}
