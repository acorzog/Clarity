import SwiftUI
import SwiftData

struct CategoryPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]
    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]
    @Binding var selection: Category?
    var isIncome = false

    @State private var searchText = ""
    @State private var expandedHeadIDs: Set<PersistentIdentifier> = []
    @State private var showingNewCategory = false

    private func categories(for headCategory: HeadCategory) -> [Category] {
        headCategory.categories
            .filter { !$0.isArchived && $0.isIncome == isIncome }
            .sorted { $0.name < $1.name }
    }

    private var hasAnyCategories: Bool {
        headCategories.contains { !categories(for: $0).isEmpty }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func matchesSearch(_ category: Category) -> Bool {
        guard isSearching else { return true }
        return category.name.localizedCaseInsensitiveContains(searchText)
    }

    /// The 8 categories used most across all of history — a quick-pick shortcut so the common
    /// case doesn't require expanding a head category section at all.
    private var mostUsedCategories: [Category] {
        var counts: [PersistentIdentifier: Int] = [:]
        var lookup: [PersistentIdentifier: Category] = [:]

        for entry in allEntries {
            guard let category = entry.category, !category.isArchived, category.isIncome == isIncome else { continue }
            let id = category.persistentModelID
            counts[id, default: 0] += 1
            lookup[id] = category
        }

        return counts
            .sorted { $0.value > $1.value }
            .prefix(8)
            .compactMap { lookup[$0.key] }
    }

    private func toggleExpanded(_ id: PersistentIdentifier) {
        if expandedHeadIDs.contains(id) {
            expandedHeadIDs.remove(id)
        } else {
            expandedHeadIDs.insert(id)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !hasAnyCategories {
                    EmptyStateView(
                        icon: "square.grid.2x2",
                        title: isIncome ? "No Income Categories" : "No Categories",
                        message: "Create one from Tools > Categories first."
                    )
                } else {
                    List {
                        if !isSearching && !mostUsedCategories.isEmpty {
                            Section("Most Used") {
                                ForEach(mostUsedCategories) { category in
                                    categoryRow(category)
                                }
                            }
                        }

                        ForEach(headCategories) { headCategory in
                            let categoriesInHead = categories(for: headCategory).filter(matchesSearch)
                            if !categoriesInHead.isEmpty {
                                let isExpanded = isSearching || expandedHeadIDs.contains(headCategory.persistentModelID)
                                Section {
                                    if isExpanded {
                                        ForEach(categoriesInHead) { category in
                                            categoryRow(category)
                                        }
                                    }
                                } header: {
                                    // Collapsed by default so picking a category doesn't require
                                    // scrolling past every head category — tap to expand one, or
                                    // search to reveal matches across all of them at once.
                                    Button {
                                        toggleExpanded(headCategory.persistentModelID)
                                    } label: {
                                        HStack {
                                            Text(headCategory.name)
                                            Spacer()
                                            Text("\(categoriesInHead.count)")
                                                .foregroundStyle(.white.opacity(0.3))
                                            Image(systemName: "chevron.right")
                                                .font(.caption2)
                                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isSearching)
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search categories")
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showingNewCategory = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showingNewCategory) {
            NavigationStack {
                CategoryEditorView(
                    category: nil,
                    defaultHeadCategory: nil,
                    defaultIsIncome: isIncome,
                    showsCancelButton: true,
                    onSave: { newCategory in
                        // The new category is already visible to the @Query above (same
                        // context, same process) — select it immediately instead of leaving
                        // the user to find and tap it again in the list they just left.
                        selection = newCategory
                        dismiss()
                    }
                )
            }
            .preferredColorScheme(.dark)
        }
    }

    private func categoryRow(_ category: Category) -> some View {
        Button {
            selection = category
            dismiss()
        } label: {
            HStack {
                CategoryIconView(category: category, size: 28)
                Text(category.name)
                    .foregroundStyle(.white)
                Spacer()
                if selection === category {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.emerald)
                }
            }
        }
        .listRowBackground(Color.white.opacity(0.05))
    }
}
