import SwiftUI
import SwiftData

struct WalletTransactionsView: View {
    let wallet: Wallet

    @Environment(\.modelContext) private var modelContext
    @State private var editingEntry: Entry?

    /// Each entry touching this wallet paired with the wallet's balance immediately after it,
    /// walking backward from the current balance through the (already newest-first) entries.
    private var rows: [(entry: Entry, balance: Decimal)] {
        var running = wallet.balance
        var result: [(entry: Entry, balance: Decimal)] = []
        for entry in wallet.allEntries {
            result.append((entry, running))
            running -= wallet.effect(of: entry)
        }
        return result
    }

    private var groupedByDay: [(day: Date, rows: [(entry: Entry, balance: Decimal)])] {
        let grouped = Dictionary(grouping: rows) { Calendar.current.startOfDay(for: $0.entry.date) }
        return grouped.keys.sorted(by: >).map { day in
            (day, grouped[day, default: []].sorted { $0.entry.date > $1.entry.date })
        }
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                EmptyStateView(
                    icon: "tray",
                    title: "No Transactions",
                    message: "Transactions touching this wallet will show up here."
                )
            } else {
                List {
                    ForEach(groupedByDay, id: \.day) { group in
                        Section {
                            ForEach(group.rows, id: \.entry.id) { row in
                                Button {
                                    editingEntry = row.entry
                                } label: {
                                    WalletTransactionRow(entry: row.entry, wallet: wallet, runningBalance: row.balance)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.white.opacity(0.05))
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        modelContext.delete(row.entry)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        editingEntry = row.entry
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(.skyBlue)
                                }
                            }
                        } header: {
                            DayTotalHeader(label: dayLabel(group.day), total: netEffect(for: group.rows))
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle(wallet.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingEntry) { entry in
            AddTransactionView(entry: entry)
        }
    }

    private func netEffect(for rows: [(entry: Entry, balance: Decimal)]) -> Decimal {
        rows.reduce(Decimal(0)) { $0 + wallet.effect(of: $1.entry) }
    }

    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

private struct DayTotalHeader: View {
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
