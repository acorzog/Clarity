import SwiftUI

/// The one reusable card-surface treatment — see `CLARITY_DESIGN_SYSTEM.md` §10.
///
/// Formalizes the pattern hand-rolled at 15+ existing call sites: a flat, opaque-background
/// screen with `surfacePrimary`/`surfaceSecondary`-tinted rounded rectangles for cards, no blur,
/// no border, no shadow (the app has zero `.shadow(...)` calls today — a deliberate, existing
/// aesthetic this modifier preserves rather than "improves"). Deliberately not a class hierarchy
/// or a generic "everything is a Surface" protocol — just a `ViewModifier`, matching how simply
/// the existing pattern already works.
enum SurfaceTier {
    case primary
    case secondary
    case elevated

    var color: Color {
        switch self {
        case .primary: .surfacePrimary
        case .secondary: .surfaceSecondary
        case .elevated: .surfaceElevated
        }
    }
}

private struct SurfaceModifier: ViewModifier {
    var tier: SurfaceTier
    var radius: CGFloat
    var padding: CGFloat?

    func body(content: Content) -> some View {
        content
            .padding(padding ?? ClaritySpacing.xl)
            .background(tier.color, in: RoundedRectangle(cornerRadius: radius))
    }
}

extension View {
    /// Wraps content in the standard Clarity card surface. `padding` defaults to
    /// `ClaritySpacing.xl` (20pt), matching the dominant existing card padding.
    func surface(_ tier: SurfaceTier = .primary, radius: CGFloat = ClarityRadius.large, padding: CGFloat? = nil) -> some View {
        modifier(SurfaceModifier(tier: tier, radius: radius, padding: padding))
    }
}
