import SwiftUI
import SwiftData

struct CategoryEntriesDetailView: View {
    let title: String
    /// The category and month this list is scoped to — when both are supplied, the toolbar
    /// gains "edit planned amount" and "add transaction" actions (Remaining's drill-down, per
    /// `RemainingView`). Optional so other callers (e.g. Overview's Spending Breakdown) that
    /// don't have both on hand can keep reusing this view as a read-only entry list.
    var category: Category?
    var month: Date?

    @Environment(\.modelContext) private var modelContext
    @Query private var allBudgets: [Budget]
    @State private var entries: [Entry]
    @State private var editingEntry: Entry?
    @State private var showingAmountEntry = false
    @State private var showingAddTransaction = false

    init(title: String, entries: [Entry], category: Category? = nil, month: Date? = nil) {
        self.title = title
        self.category = category
        self.month = month
        _entries = State(initialValue: entries)
    }

    private var sortedEntries: [Entry] {
        entries.sorted { $0.date > $1.date }
    }

    var body: some View {
        Group {
            if sortedEntries.isEmpty {
                EmptyStateView(
                    icon: "tray",
                    title: "No Entries",
                    message: "No transactions here yet."
                )
            } else {
                List {
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
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let category, month != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 20) {
                        Button {
                            showingAmountEntry = true
                        } label: {
                            Image(systemName: "pencil.circle")
                        }
                        .accessibilityLabel("Edit planned amount")

                        Button {
                            showingAddTransaction = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .accessibilityLabel("Add \(category.name) transaction")
                    }
                }
            }
        }
        .sheet(item: $editingEntry) { entry in
            AddTransactionView(entry: entry)
        }
        .sheet(isPresented: $showingAmountEntry) {
            if let category, let month {
                AmountEntrySheet(
                    category: category,
                    currentAmount: allBudgets.amount(for: category, month: month),
                    onSave: { setPlannedAmount($0, for: category, month: month) }
                )
            }
        }
        .sheet(isPresented: $showingAddTransaction) {
            if let category {
                AddTransactionView(initialType: .expense, initialCategory: category, onSave: { entries.append($0) })
            }
        }
    }

    private func delete(_ entry: Entry) {
        entries.removeAll { $0 === entry }
        modelContext.delete(entry)
    }

    /// Writes straight to the same `Budget` rows Plan → Allocate reads/writes (`PlanView.
    /// setAmount`), so a change made here shows up there immediately via SwiftData's live
    /// `@Query` — no separate sync step needed.
    private func setPlannedAmount(_ amount: Decimal, for category: Category, month: Date) {
        if let existing = allBudgets.budget(for: category, month: month) {
            existing.monthlyLimit = amount
        } else {
            let (m, y) = month.monthYearComponents
            modelContext.insert(Budget(category: category, monthlyLimit: amount, month: m, year: y))
        }
        // Explicit save rather than relying on SwiftData's lazy autosave — see `PlanView.
        // setAmount`'s identical comment: `RootView` calls `modelContext.rollback()` on every
        // foreground transition and cross-process store change, which would otherwise silently
        // discard this edit before it ever reaches Allocate.
        try? modelContext.save()
    }
}
