import SwiftUI
import SwiftData

/// Sheet listing a single day's Entries, with that day's total spend at the top.
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

    /// Budget-eligible expense total for this day — matches `CalendarView.dailySpending`'s own
    /// calculation exactly (`.budgetEligible.totalExpenses`), so the figure shown here can never
    /// disagree with the total the calendar cell/selection summary showed for the same day. The
    /// transaction list below is still every entry, unfiltered — only this total excludes
    /// `excludeFromBudget` entries.
    private var daySpent: Decimal {
        entries.budgetEligible.totalExpenses
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
                                Text("Spent")
                                    .foregroundStyle(.white.opacity(0.6))
                                Spacer()
                                Text(daySpent.currencyFormatted)
                                    .font(.title3.bold())
                                    .foregroundStyle(daySpent > 0 ? Color.expenseRed : Color.white.opacity(0.6))
                            }
                        }
                        .listRowBackground(Color.white.opacity(0.05))

                        Section {
                            ForEach(sortedEntries) { entry in
                                Button {
                                    editingEntry = entry
                                } label: {
                                    DayEntryRow(entry: entry)
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
            .sheet(item: $editingEntry, onDismiss: refreshEntries) { entry in
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

    /// Re-syncs the local snapshot with SwiftData after the Add or Edit sheet closes. A newly
    /// created Entry isn't part of `entries` until explicitly picked up; an edited one already is
    /// (same live `@Model` reference, so in-place field changes like amount/category/
    /// `excludeFromBudget` already show up without this) — but if the edit moved the entry's
    /// `date` to a different day, only this re-fetch drops it from `entries`/`daySpent`, which
    /// otherwise would keep counting an entry that no longer belongs to `day` at all.
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

/// Wraps the shared `EntryRow` with a caption for `excludeFromBudget` entries — local to this
/// view rather than added to `EntryRow` itself (which several other screens also use, none of
/// which mix excluded and counted entries side by side the way this list deliberately does).
/// Without this, an entry visible here but missing from `daySpent` above it would look like an
/// unexplained mismatch rather than the intentional "visible and editable, just not counted"
/// behavior this list is designed to have.
private struct DayEntryRow: View {
    let entry: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            EntryRow(entry: entry)
            if entry.excludeFromBudget {
                Text("Excluded from Spent total")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }
}
