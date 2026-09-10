import SwiftUI

/// Identifies each tab so `HomeView` can switch tabs on a drill-down tap — see `HomeView.
/// selectedTab`'s doc comment for why this only switches tabs rather than deep-linking into a
/// specific sub-tab.
///
/// Only 5 cases — iOS collapses a 6th+ tab-bar item into a system-generated "More" list, which
/// would have silently demoted whichever tab landed there (discovered when Home was first added
/// as a 6th item, pushing Shared/Tools behind that system "More," contradicting
/// `CLARITY_PRODUCT_ARCHITECTURE.md`'s explicit "Shared remains first-class, primary-tab"
/// decision).
///
/// This is the Phase 2B-2.2 navigation restructure's target shape —
/// `CLARITY_PRODUCT_ARCHITECTURE.md` §3/§4: **Home / Overview / Plan / Shared / More**, replacing
/// the interim Phase 2B-2.1 shape (Home / Budget / Wallets / Shared / Tools). Overview is
/// reinstated as its own top-level tab (unchanged internally — its existing Overview/Spending/
/// List sub-tabs are preserved as-is); Budget's tab becomes Plan; Wallets is no longer a top-level
/// tab — its UI (relabeled "Accounts") moved under More; Tools' tab becomes More, now also hosting
/// Accounts; Shared is unchanged.
///
/// **Phase 2H-B revision:** Plan no longer opens a Budget/Goals/Forecast launcher
/// (`PlanContainerView`) — it opens directly into the Allocate/Remaining/Goals workspace
/// (`BudgetView`). See `BudgetView`'s doc comment.
enum MainTab: CaseIterable, Hashable {
    case home, overview, plan, shared, more

    var title: String {
        switch self {
        case .home: "Home"
        case .overview: "Overview"
        case .plan: "Plan"
        case .shared: "Shared"
        case .more: "More"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .overview: "chart.pie.fill"
        case .plan: "chart.bar.fill"
        case .shared: "person.2.fill"
        case .more: "ellipsis.circle.fill"
        }
    }
}

struct MainTabView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab: MainTab = .home

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                AdaptiveSidebarView(selectedTab: $selectedTab)
            } else {
                TabView(selection: $selectedTab) {
                    ForEach(MainTab.allCases, id: \.self) { tab in
                        destination(for: tab)
                            .tabItem { Label(tab.title, systemImage: tab.icon) }
                            .tag(tab)
                    }
                }
            }
        }
        .tint(.emerald)
        .preferredColorScheme(.dark)
    }

    /// Shared by both the compact `TabView` and the regular-width sidebar's detail column, so
    /// the two layouts can never drift into showing different content for the same tab.
    @ViewBuilder
    static func destination(for tab: MainTab, selectedTab: Binding<MainTab>) -> some View {
        switch tab {
        case .home: HomeView(selectedTab: selectedTab)
        case .overview: OverviewView()
        case .plan: BudgetView()
        case .shared: SharedHomeView()
        case .more: ToolsView()
        }
    }

    @ViewBuilder
    private func destination(for tab: MainTab) -> some View {
        Self.destination(for: tab, selectedTab: $selectedTab)
    }
}

/// The regular-width (iPad, or an iPhone landscape wide enough to qualify) sibling of
/// `MainTabView`'s `TabView` — same 5 destinations, `NavigationSplitView` sidebar navigation
/// instead of a bottom tab bar. Each destination already wraps itself in its own
/// `NavigationStack`, which nests cleanly inside a split view's detail column.
private struct AdaptiveSidebarView: View {
    @Binding var selectedTab: MainTab

    /// `List`'s non-optional `Binding<SelectionValue>` selection initializer is unavailable on
    /// iOS — only the optional-selection one is. `selectedTab` itself stays non-optional (every
    /// other call site, including the compact `TabView`, wants a guaranteed value), so this just
    /// bridges the two: a `nil` write (nothing selected) can't actually happen from a sidebar
    /// `List`'s own selection UI, but is ignored rather than force-unwrapped just in case.
    private var sidebarSelection: Binding<MainTab?> {
        Binding(get: { selectedTab }, set: { if let newValue = $0 { selectedTab = newValue } })
    }

    var body: some View {
        NavigationSplitView {
            List(MainTab.allCases, id: \.self, selection: sidebarSelection) { tab in
                Label(tab.title, systemImage: tab.icon).tag(tab)
            }
            .navigationTitle("Clarity")
            .listStyle(.sidebar)
        } detail: {
            MainTabView.destination(for: selectedTab, selectedTab: $selectedTab)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

#Preview {
    MainTabView()
}
