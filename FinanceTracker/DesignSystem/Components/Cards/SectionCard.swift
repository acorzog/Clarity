import SwiftUI

/// The default card container — see `CLARITY_DESIGN_SYSTEM.md` §12 ("Cards"). Consolidates the
/// `VStack(...).padding(20).background(Color.white.opacity(0.05), in: RoundedRectangle(
/// cornerRadius: 20))` pattern hand-rolled at 15+ existing call sites into one component.
///
/// Deliberately just a thin wrapper around `View.surface(_:radius:padding:)` — content, layout,
/// and behavior are entirely the caller's; this only owns the container chrome.
struct SectionCard<Content: View>: View {
    var tier: SurfaceTier = .primary
    var radius: CGFloat = ClarityRadius.large
    var padding: CGFloat? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .surface(tier, radius: radius, padding: padding)
    }
}
