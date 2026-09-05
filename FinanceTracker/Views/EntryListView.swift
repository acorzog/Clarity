import SwiftUI
import SwiftData

struct EntryListView: View {
    let month: Date
    var searchText: String = ""

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]
    @State private var editingEntry: Entry?

    private var monthEntries: [Entry] { allEntries.inMonth(month) }
    private var income: Decimal { monthEntries.totalIncome }
    private var expenses: Decimal { monthEntries.totalExpenses }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var filteredEntries: [Entry] {
        guard isSearching else { return monthEntries }
        let query = searchText.lowercased()
        return monthEntries.filter { entry in
            entry.note.lowercased().contains(query) ||
            (entry.category?.name.lowercased().contains(query) ?? false)
        }
    }

    private var groupedByDay: [(day: Date, entries: [Entry])] {
        let grouped = Dictionary(grouping: filteredEntries) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            (day, grouped[day, default: []].sorted { $0.date > $1.date })
        }
    }

    var body: some View {
        if groupedByDay.isEmpty {
            EmptyStateView(
                icon: isSearching ? "magnifyingglass" : "tray",
                title: isSearching ? "No Results" : "No Transactions",
                message: isSearching
                    ? "No transactions match “\(searchText)”."
                    : "Nothing recorded for this month yet. Tap + to add your first transaction."
            )
            .frame(maxHeight: .infinity)
        } else {
            List {
                Section {
                    MonthSummaryCard(income: income, expenses: expenses)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)

                ForEach(groupedByDay, id: \.day) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            Button {
                                editingEntry = entry
                            } label: {
                                EntryRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.white.opacity(0.05))
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    modelContext.delete(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    editingEntry = entry
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.skyBlue)
                            }
                        }
                    } header: {
                        DaySectionHeader(label: dayLabel(group.day), total: netTotal(for: group.entries))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground.ignoresSafeArea())
            .sheet(item: $editingEntry) { entry in
                AddTransactionView(entry: entry)
            }
        }
    }

    private func netTotal(for entries: [Entry]) -> Decimal {
        entries.reduce(Decimal(0)) { total, entry in
            switch entry.type {
            case .income: total + entry.amount
            case .expense: total - entry.amount
            case .transfer: total
            }
        }
    }

    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

private struct DaySectionHeader: View {
    let label: String
    let total: Decimal

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            Text(total.currencyFormatted)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(total >= 0 ? Color.emerald : Color.expenseRed)
        }
        .textCase(nil)
    }
}

private struct MonthSummaryCard: View {
    let income: Decimal
    let expenses: Decimal

    private var balance: Decimal { income - expenses }
    private var balanceColor: Color { balance >= 0 ? .skyBlue : .expenseRed }

    var body: some View {
        HStack {
            column(title: "Income", amount: income, color: .emerald)
            Spacer()
            column(title: "Expenses", amount: expenses, color: .expenseRed)
            Spacer()
            column(title: "Balance", amount: balance, color: balanceColor)
        }
        .padding(20)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func column(title: String, amount: Decimal, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
            Text(amount.currencyFormatted)
                .font(.subheadline.bold())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
