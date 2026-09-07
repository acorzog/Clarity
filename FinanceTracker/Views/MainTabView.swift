import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            OverviewView()
                .tabItem { Label("Overview", systemImage: "chart.pie.fill") }

            BudgetView()
                .tabItem { Label("Budget", systemImage: "chart.bar.fill") }

            WalletsView()
                .tabItem { Label("Wallets", systemImage: "wallet.pass.fill") }

            SharedHomeView()
                .tabItem { Label("Shared", systemImage: "person.2.fill") }

            ToolsView()
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver.fill") }
        }
        .tint(.emerald)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    MainTabView()
}
