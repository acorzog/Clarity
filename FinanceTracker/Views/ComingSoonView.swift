import SwiftUI

struct ComingSoonView: View {
    let title: String
    var icon: String = "hourglass"
    /// `true` (default): behaves as a full standalone screen — own nav title, fills the screen
    /// with the app background. Matches every pre-existing call site (`PlanContainerView`'s
    /// Forecast tile, `ToolsView`'s Reminders/Bank Connections stubs), each reached via
    /// `NavigationLink` push, unchanged.
    ///
    /// Pass `false` when embedding this inline as sub-tab content instead of a pushed screen —
    /// Plan's Goals sub-tab (Phase 2H-C) — where the enclosing screen already owns its own
    /// header/background, and this view setting its own `navigationTitle` would incorrectly
    /// override the (blank) nav-bar title shown for Plan's other sub-tabs.
    var isStandaloneScreen: Bool = true

    private var content: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(LinearGradient.emeraldSky)
                // Purely decorative — the two texts below already fully describe the state, so a
                // VoiceOver user shouldn't get an unlabeled-symbol stop before them (Phase 2J).
                .accessibilityHidden(true)

            Text("Coming Soon")
                .font(.title3.bold())
                .foregroundStyle(.white)

            Text("\(title) isn't available yet, but it's on the way.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    var body: some View {
        if isStandaloneScreen {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground.ignoresSafeArea())
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content
                .frame(maxWidth: .infinity)
                .padding(.vertical, ClaritySpacing.xxxl)
        }
    }
}
