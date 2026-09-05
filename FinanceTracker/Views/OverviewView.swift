import SwiftUI
import SwiftData

private enum OverviewSubTab: String, CaseIterable {
    case overview = "Overview"
    case spending = "Spending"
    case list = "List"
}

struct OverviewView: View {
    @State private var showingAddTransaction = false
    @State private var subTab: OverviewSubTab = .overview
    @State private var selectedMonth = Date.startOfMonth()
    @State private var searchText = ""
    @State private var isSearchPresented = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GradientHeader(title: "Overview")
                    .padding(.top, 8)

                MonthSelector(month: $selectedMonth)
                    .padding(.horizontal)

                Picker("View", selection: $subTab) {
                    ForEach(OverviewSubTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .tint(.emerald)
                .padding(.horizontal)

                switch subTab {
                case .overview:
                    ScrollView { OverviewSummaryView(month: selectedMonth) }
                case .spending:
                    ScrollView { SpendingBreakdownView(month: selectedMonth) }
                case .list:
                    // Owns its own List/scrolling for swipe actions — not wrapped in ScrollView.
                    EntryListView(month: selectedMonth, searchText: searchText)
                }
            }
            .darkScreenBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        subTab = .list
                        isSearchPresented = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(LinearGradient.emeraldSky)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddTransaction = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(LinearGradient.emeraldSky)
                    }
                }
            }
            .searchable(
                text: $searchText,
                isPresented: $isSearchPresented,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search transactions"
            )
        }
        .sheet(isPresented: $showingAddTransaction) {
            AddTransactionView()
        }
    }
}

#Preview {
    OverviewView()
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
