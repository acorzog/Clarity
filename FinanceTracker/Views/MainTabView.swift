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
enum MainTab: Hashable {
    case home, overview, plan, shared, more
}

struct MainTabView: View {
    @State private var selectedTab: MainTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(selectedTab: $selectedTab)
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(MainTab.home)

            OverviewView()
                .tabItem { Label("Overview", systemImage: "chart.pie.fill") }
                .tag(MainTab.overview)

            BudgetView()
                .tabItem { Label("Plan", systemImage: "chart.bar.fill") }
                .tag(MainTab.plan)

            SharedHomeView()
                .tabItem { Label("Shared", systemImage: "person.2.fill") }
                .tag(MainTab.shared)

            ToolsView()
                .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
                .tag(MainTab.more)
        }
        .tint(.emerald)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    MainTabView()
}
