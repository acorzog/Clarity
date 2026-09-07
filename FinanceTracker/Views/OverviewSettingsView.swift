import SwiftUI
import SwiftData

struct OverviewSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = OverviewSettingsStore.shared
    @ObservedObject private var preferences = AppPreferencesStore.shared
    @Query(sort: \Category.name) private var allCategories: [Category]

    @State private var showingExpenseDefaultPicker = false
    @State private var showingIncomeDefaultPicker = false

    private var defaultExpenseCategory: Category? {
        guard let name = preferences.defaultExpenseCategoryName else { return nil }
        return allCategories.first { $0.name == name && !$0.isIncome }
    }

    private var defaultIncomeCategory: Category? {
        guard let name = preferences.defaultIncomeCategoryName else { return nil }
        return allCategories.first { $0.name == name && $0.isIncome }
    }

    /// `CategoryPickerView` binds to a `Category?`, but the preference itself is stored as a
    /// name — these bridge one to the other so picking a category writes its name back.
    private var expenseDefaultBinding: Binding<Category?> {
        Binding(
            get: { defaultExpenseCategory },
            set: { preferences.defaultExpenseCategoryName = $0?.name }
        )
    }

    private var incomeDefaultBinding: Binding<Category?> {
        Binding(
            get: { defaultIncomeCategory },
            set: { preferences.defaultIncomeCategoryName = $0?.name }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Currency", selection: $preferences.currency) {
                        ForEach(SupportedCurrency.allCases) { currency in
                            Text("\(currency.flag) \(currency.displayName) (\(currency.rawValue))").tag(currency)
                        }
                    }
                    .tint(.white.opacity(0.7))
                    .listRowBackground(Color.white.opacity(0.05))
                } header: {
                    SectionHeader(title: "Currency")
                }

                Section {
                    Toggle("Show double decimals", isOn: $preferences.showDoubleDecimals)
                        .tint(.emerald)
                        .listRowBackground(Color.white.opacity(0.05))
                    Toggle("Round decimals in summaries", isOn: $preferences.roundDecimalsInSummaries)
                        .tint(.emerald)
                        .listRowBackground(Color.white.opacity(0.05))
                } header: {
                    SectionHeader(title: "Decimals")
                } footer: {
                    Text("Rounding applies to headline totals like Income/Expenses/Left and Net Worth — individual transactions always show their exact amount.")
                        .foregroundStyle(.white.opacity(0.4))
                }

                Section {
                    DefaultCategoryRow(
                        title: "Expense category",
                        category: defaultExpenseCategory,
                        onTap: { showingExpenseDefaultPicker = true },
                        onClear: { preferences.defaultExpenseCategoryName = nil }
                    )
                    .listRowBackground(Color.white.opacity(0.05))
                    DefaultCategoryRow(
                        title: "Income category",
                        category: defaultIncomeCategory,
                        onTap: { showingIncomeDefaultPicker = true },
                        onClear: { preferences.defaultIncomeCategoryName = nil }
                    )
                    .listRowBackground(Color.white.opacity(0.05))
                } header: {
                    SectionHeader(title: "Default Categories")
                } footer: {
                    Text("Pre-fills the category when starting a new transaction. Swipe left to clear.")
                        .foregroundStyle(.white.opacity(0.4))
                }

                Section {
                    ForEach(settings.cardOrder) { card in
                        SettingsVisibilityRow(
                            icon: card.icon,
                            title: card.title,
                            isVisible: settings.isVisible(card),
                            onToggle: { settings.toggleVisibility(card) }
                        )
                    }
                    .onMove { settings.moveCards(fromOffsets: $0, toOffset: $1) }
                    .listRowBackground(Color.white.opacity(0.05))
                } header: {
                    SectionHeader(title: "Overview")
                }
                // Pinned active only for this section's reorder handles — scoped here (rather
                // than on the whole List) so it can't interfere with the Picker/Button rows in
                // the sections above.
                .environment(\.editMode, .constant(.active))

                Section {
                    SettingsVisibilityRow(
                        icon: "chart.pie.fill",
                        title: "Spending Breakdown",
                        isVisible: settings.showSpendingBreakdown,
                        onToggle: { settings.showSpendingBreakdown.toggle() }
                    )
                    .listRowBackground(Color.white.opacity(0.05))
                } header: {
                    SectionHeader(title: "Spending")
                }

                Section {
                    SettingsVisibilityRow(
                        icon: "list.bullet.rectangle",
                        title: "Month Summary",
                        isVisible: settings.showListSummary,
                        onToggle: { settings.showListSummary.toggle() }
                    )
                    .listRowBackground(Color.white.opacity(0.05))
                } header: {
                    SectionHeader(title: "List")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Overview Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        .sheet(isPresented: $showingExpenseDefaultPicker) {
            CategoryPickerView(selection: expenseDefaultBinding, isIncome: false)
        }
        .sheet(isPresented: $showingIncomeDefaultPicker) {
            CategoryPickerView(selection: incomeDefaultBinding, isIncome: true)
        }
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
            .textCase(nil)
            .padding(.bottom, 4)
    }
}

private struct SettingsVisibilityRow: View {
    let icon: String
    let title: String
    let isVisible: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 20)

            Text(title)
                .foregroundStyle(.white.opacity(isVisible ? 1 : 0.4))

            Spacer()

            Button(action: onToggle) {
                Image(systemName: isVisible ? "eye.fill" : "eye.slash.fill")
                    .font(.subheadline)
                    .foregroundStyle(isVisible ? .white : .white.opacity(0.3))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

private struct DefaultCategoryRow: View {
    let title: String
    let category: Category?
    let onTap: () -> Void
    let onClear: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Text(title)
                    .foregroundStyle(.white)
                Spacer()
                if let category {
                    CategoryIconView(category: category, size: 22)
                    Text(category.name)
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    Text("None")
                        .foregroundStyle(.white.opacity(0.4))
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            if category != nil {
                Button(role: .destructive, action: onClear) {
                    Label("Clear", systemImage: "xmark")
                }
            }
        }
    }
}

#Preview {
    OverviewSettingsView()
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
