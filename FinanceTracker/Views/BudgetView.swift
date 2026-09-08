import SwiftUI
import SwiftData

private enum BudgetSubTab: String, CaseIterable {
    case plan = "Plan"
    case remaining = "Remaining"
    case insights = "Insights"
}

struct BudgetView: View {
    @ObservedObject private var settings = BudgetSettingsStore.shared
    @State private var subTab: BudgetSubTab = .plan
    @State private var selectedMonth = Date.startOfMonth()
    @State private var showingSettings = false
    @State private var remainingLayout: RemainingLayout = .list

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: settings.icon.rawValue)
                        .font(.title2)
                        .foregroundStyle(LinearGradient.emeraldSky)
                    GradientHeader(title: settings.name)
                }
                .padding(.top, 8)

                MonthSelector(month: $selectedMonth)
                    .padding(.horizontal)

                Picker("View", selection: $subTab) {
                    ForEach(BudgetSubTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .tint(.emerald)
                .padding(.horizontal)

                ScrollView {
                    switch subTab {
                    case .plan:
                        PlanView(month: selectedMonth)
                    case .remaining:
                        RemainingView(month: selectedMonth, layout: remainingLayout)
                    case .insights:
                        InsightsView(month: selectedMonth)
                    }
                }
                // Lets a scroll gesture drag the keyboard down interactively instead of
                // requiring the user to leave the screen just to type in another field.
                .scrollDismissesKeyboard(.interactively)
            }
            .darkScreenBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .foregroundStyle(LinearGradient.emeraldSky)
                    }
                }
                if subTab == .remaining {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                remainingLayout = remainingLayout.other
                            }
                        } label: {
                            Image(systemName: remainingLayout.other.icon)
                                .font(.title2)
                                .foregroundStyle(LinearGradient.emeraldSky)
                        }
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                BudgetSettingsView()
            }
        }
    }
}

#Preview {
    BudgetView()
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
