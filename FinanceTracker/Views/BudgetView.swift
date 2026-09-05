import SwiftUI
import SwiftData

private enum BudgetSubTab: String, CaseIterable {
    case plan = "Plan"
    case remaining = "Remaining"
    case insights = "Insights"
}

struct BudgetView: View {
    @State private var subTab: BudgetSubTab = .plan
    @State private var selectedMonth = Date.startOfMonth()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GradientHeader(title: "Budget")
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
                        RemainingView(month: selectedMonth)
                    case .insights:
                        InsightsView(month: selectedMonth)
                    }
                }
            }
            .darkScreenBackground()
        }
    }
}

#Preview {
    BudgetView()
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
