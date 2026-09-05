import SwiftUI
import SwiftData

/// Sheet listing a single day's Entries, with a running total for that day at the top.
struct DayEntriesView: View {
    let day: Date

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Entry]
    @State private var editingEntry: Entry?
    @State private var showingAddTransaction = false

    init(day: Date, entries: [Entry]) {
        self.day = day
        _entries = State(initialValue: entries)
    }

    private var sortedEntries: [Entry] {
        entries.sorted { $0.date > $1.date }
    }

    private var dayTotal: Decimal {
        entries.reduce(Decimal(0)) { total, entry in
            switch entry.type {
            case .income: total + entry.amount
            case .expense: total - entry.amount
            case .transfer: total
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sortedEntries.isEmpty {
                    EmptyStateView(icon: "tray", title: "No Entries", message: "Nothing recorded on this day.")
                } else {
                    List {
                        Section {
                            HStack {
                                Text("Total")
                                    .foregroundStyle(.white.opacity(0.6))
                                Spacer()
                                Text(dayTotal.currencyFormatted)
                                    .font(.title3.bold())
                                    .foregroundStyle(dayTotal >= 0 ? Color.emerald : Color.expenseRed)
                            }
                        }
                        .listRowBackground(Color.white.opacity(0.05))

                        Section {
                            ForEach(sortedEntries) { entry in
                                Button {
                                    editingEntry = entry
                                } label: {
                                    EntryRow(entry: entry)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.white.opacity(0.05))
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        delete(entry)
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
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle(dayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showingAddTransaction = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(LinearGradient.emeraldSky)
                    }
                }
            }
            .sheet(item: $editingEntry) { entry in
                AddTransactionView(entry: entry)
            }
            .sheet(isPresented: $showingAddTransaction, onDismiss: refreshEntries) {
                AddTransactionView(initialDate: day)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var dayTitle: String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func delete(_ entry: Entry) {
        entries.removeAll { $0 === entry }
        modelContext.delete(entry)
    }

    /// Re-syncs the local snapshot with SwiftData after the Add sheet closes, since a newly
    /// created Entry isn't part of `entries` until we explicitly pick it up.
    private func refreshEntries() {
        guard let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: day) else { return }
        let dayStart = day
        let predicate = #Predicate<Entry> { $0.date >= dayStart && $0.date < dayEnd }
        let descriptor = FetchDescriptor<Entry>(predicate: predicate)
        if let fresh = try? modelContext.fetch(descriptor) {
            entries = fresh
        }
    }
}
