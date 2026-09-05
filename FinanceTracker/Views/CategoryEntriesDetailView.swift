import SwiftUI
import SwiftData

struct CategoryEntriesDetailView: View {
    let title: String

    @Environment(\.modelContext) private var modelContext
    @State private var entries: [Entry]
    @State private var editingEntry: Entry?

    init(title: String, entries: [Entry]) {
        self.title = title
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
        .sheet(item: $editingEntry) { entry in
            AddTransactionView(entry: entry)
        }
    }

    private func delete(_ entry: Entry) {
        entries.removeAll { $0 === entry }
        modelContext.delete(entry)
    }
}
