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
/// This is the Phase 2B-2.2 navigation restructure's target shape, since revised: **Home /
/// Overview / Plan / Wallets / More**. Overview is reinstated as its own top-level tab (unchanged
/// internally — its existing Overview/Spending/List sub-tabs are preserved as-is); Budget's tab
/// becomes Plan; Tools' tab becomes More. Wallets (formerly "Accounts", relabeled back per this
/// revision) returns to being a top-level tab instead of living under More; Shared — not yet
/// fully developed — moved under More in its place.
///
/// **Phase 2H-B revision:** Plan no longer opens a Budget/Goals/Forecast launcher
/// (`PlanContainerView`) — it opens directly into the Allocate/Remaining/Goals workspace
/// (`BudgetView`). See `BudgetView`'s doc comment.
enum MainTab: CaseIterable, Hashable {
    case home, overview, plan, wallets, more

    var title: String {
        switch self {
        case .home: "Home"
        case .overview: "Overview"
        case .plan: "Plan"
        case .wallets: "Wallets"
        case .more: "More"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .overview: "chart.pie.fill"
        case .plan: "chart.bar.fill"
        case .wallets: "wallet.bifold.fill"
        case .more: "ellipsis.circle.fill"
        }
    }
}

struct MainTabView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: MainTab = .home
    /// Bumped whenever the calendar day changes — see the `.id(currentDay)` calls below. Several
    /// screens (`OverviewView`/`BudgetView`'s `selectedMonth`) default to "today"/"this month" in
    /// a plain `@State` initializer, which SwiftUI only evaluates once; without something forcing
    /// a fresh view identity, they'd keep showing the day the app happened to launch on for as
    /// long as it stays running, silently filtering out anything dated "today" once the real day
    /// (or month) moves on. `HomeView.month` already avoids this by being a computed property
    /// instead of `@State` — this fixes the same class of bug for every other screen at once,
    /// rather than tracking down and patching each frozen `@State` individually.
    @State private var currentDay = Calendar.current.startOfDay(for: .now)

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                AdaptiveSidebarView(selectedTab: $selectedTab, currentDay: currentDay)
            } else {
                TabView(selection: $selectedTab) {
                    ForEach(MainTab.allCases, id: \.self) { tab in
                        destination(for: tab)
                            .id(currentDay)
                            .tabItem { Label(tab.title, systemImage: tab.icon) }
                            .tag(tab)
                    }
                }
            }
        }
        .tint(.emerald)
        .preferredColorScheme(.dark)
        // The system posts this at midnight (and on timezone/manual date changes) while the app
        // is actually running — the common case, since the day usually rolls over overnight while
        // the app sits foregrounded or suspended-in-recents rather than fully backgrounded.
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            refreshCurrentDay()
        }
        // Fallback for when the app was backgrounded across midnight and the notification above
        // never reached it: re-check on every return to foreground.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { refreshCurrentDay() }
        }
    }

    private func refreshCurrentDay() {
        let today = Calendar.current.startOfDay(for: .now)
        if today != currentDay { currentDay = today }
    }

    /// Shared by both the compact `TabView` and the regular-width sidebar's detail column, so
    /// the two layouts can never drift into showing different content for the same tab.
    @ViewBuilder
    static func destination(for tab: MainTab, selectedTab: Binding<MainTab>) -> some View {
        switch tab {
        case .home: HomeView(selectedTab: selectedTab)
        case .overview: OverviewView()
        case .plan: BudgetView()
        case .wallets: WalletsView()
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
    let currentDay: Date

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
                .id(currentDay)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

#Preview {
    MainTabView()
}
