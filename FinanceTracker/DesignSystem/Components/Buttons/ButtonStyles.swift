import SwiftUI

/// The Clarity button system — see `CLARITY_DESIGN_SYSTEM.md` §12 ("Buttons"). Formalizes the
/// hand-rolled gradient-pill primary button, tinted secondary button, and destructive-red
/// pattern already used ad hoc across editor screens (e.g. `SetWalletGoalView`'s Save button,
/// `SharedEventDetailView`'s Settle button) — no custom `ButtonStyle` existed anywhere before
/// this file (confirmed by repo-wide search during the Phase 2A-1 audit).
///
/// All three enforce a minimum 44pt tap-target height, per the design system's accessibility
/// requirement, and dim + reduce opacity on press for tactile feedback (no existing button had
/// an explicit pressed state — every current CTA relies on SwiftUI's default `Button` behavior,
/// which gives no visual press feedback for a custom-background button).
/// Shared by all three styles below — `nil` (an instant, un-animated change) when Reduce Motion
/// is on, matching `CLARITY_DESIGN_SYSTEM.md` §19/§22's explicit Reduce Motion requirement.
private func pressAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.15)
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.buttonLabel)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                isEnabled ? AnyShapeStyle(LinearGradient.emeraldSky) : AnyShapeStyle(Color.surfaceSecondary),
                in: RoundedRectangle(cornerRadius: ClarityRadius.medium)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(pressAnimation(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.buttonLabel)
            .foregroundStyle(isEnabled ? .textPrimary : .textDisabled)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClarityRadius.medium))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(pressAnimation(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

struct DestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.buttonLabel)
            .foregroundStyle(isEnabled ? .destructive : .textDisabled)
            .frame(maxWidth: .infinity, minHeight: 44)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(pressAnimation(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var clarityPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}
extension ButtonStyle where Self == SecondaryButtonStyle {
    static var claritySecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}
extension ButtonStyle where Self == DestructiveButtonStyle {
    static var clarityDestructive: DestructiveButtonStyle { DestructiveButtonStyle() }
}

/// A standalone icon-only button — formalizes the existing toolbar-icon pattern (gradient or
/// tinted-white `Image(systemName:)`, no background) and the circular-background variant (e.g.
/// `WalletEditorView`'s balance +/- toggle) as two documented variants of one component, both
/// guaranteed a 44x44 minimum tap target regardless of the icon's own visual size.
struct IconButton: View {
    enum Style {
        /// Bare tinted icon, no background — the existing toolbar-icon pattern.
        case plain
        /// Icon on a filled circular background — the existing standalone-control pattern.
        case filled
    }

    let systemName: String
    var style: Style = .plain
    var tint: Color = .textPrimary
    var accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(style == .filled ? Color.textPrimary : tint)
                .frame(width: 44, height: 44)
                .background {
                    if style == .filled {
                        Circle().fill(Color.surfaceSecondary)
                    }
                }
                .contentShape(Rectangle())
        }
        .accessibilityLabel(accessibilityLabel)
    }
}
