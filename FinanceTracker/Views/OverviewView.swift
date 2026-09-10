import SwiftUI
import SwiftData

private enum OverviewSubTab: String, CaseIterable {
    case overview = "Overview"
    case spending = "Spending"
    case list = "List"
}

struct OverviewView: View {
    @State private var showingAddTransaction = false
    @State private var showingSettings = false
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

                if isSearchPresented {
                    searchField
                        .padding(.horizontal)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                switch subTab {
                case .overview:
                    ScrollView { OverviewSummaryView(month: selectedMonth).readableContentWidth() }
                case .spending:
                    ScrollView { SpendingBreakdownView(month: selectedMonth).readableContentWidth() }
                case .list:
                    // Owns its own List/scrolling for swipe actions — not wrapped in ScrollView.
                    EntryListView(month: selectedMonth, searchText: searchText)
                        .readableContentWidth()
                }
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        subTab = .list
                        withAnimation { isSearchPresented.toggle() }
                        if !isSearchPresented { searchText = "" }
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
            .onChange(of: subTab) { _, newValue in
                if newValue != .list {
                    isSearchPresented = false
                }
            }
            .sheet(isPresented: $showingSettings) {
                OverviewSettingsView()
            }
        }
        .sheet(isPresented: $showingAddTransaction) {
            AddTransactionView()
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.5))
            TextField("Search transactions", text: $searchText)
                .foregroundStyle(.white)
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    OverviewView()
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
