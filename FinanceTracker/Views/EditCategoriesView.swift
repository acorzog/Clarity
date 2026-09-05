import SwiftUI
import SwiftData

private enum TileBadge {
    case remove
    case restore
}

struct CategoriesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]
    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]

    @State private var isRemoving = false
    @State private var showingNewCategory = false
    @State private var editingCategory: Category?
    @State private var headsShowingArchived: Set<PersistentIdentifier> = []

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    private var mostFrequentCategories: [Category] {
        let monthEntries = allEntries.inMonth(.startOfMonth())
        var counts: [PersistentIdentifier: Int] = [:]
        var lookup: [PersistentIdentifier: Category] = [:]

        for entry in monthEntries {
            guard let category = entry.category, !category.isArchived else { continue }
            let id = category.persistentModelID
            counts[id, default: 0] += 1
            lookup[id] = category
        }

        return counts
            .sorted { $0.value > $1.value }
            .prefix(8)
            .compactMap { lookup[$0.key] }
    }

    private func activeCategories(for head: HeadCategory) -> [Category] {
        head.categories.filter { !$0.isArchived }.sorted { $0.name < $1.name }
    }

    private func archivedCategories(for head: HeadCategory) -> [Category] {
        head.categories.filter { $0.isArchived }.sorted { $0.name < $1.name }
    }

    private func archive(_ category: Category) {
        category.isArchived = true
    }

    private func restore(_ category: Category) {
        category.isArchived = false
    }

    private func toggleArchivedVisibility(for head: HeadCategory) {
        let id = head.persistentModelID
        if headsShowingArchived.contains(id) {
            headsShowingArchived.remove(id)
        } else {
            headsShowingArchived.insert(id)
        }
    }

    var body: some View {
        Group {
            if headCategories.isEmpty {
                EmptyStateView(
                    icon: "square.grid.2x2",
                    title: "No Categories",
                    message: "Tap + above to add your first category."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !mostFrequentCategories.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Most Frequent")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.6))

                                LazyVGrid(columns: gridColumns, spacing: 16) {
                                    ForEach(mostFrequentCategories) { category in
                                        CategoryTile(category: category, badge: isRemoving ? .remove : nil) {
                                            if isRemoving {
                                                archive(category)
                                            } else {
                                                editingCategory = category
                                            }
                                        }
                                    }
                                }
                            }
                            .categoryCardStyle()
                        }

                        ForEach(headCategories) { head in
                            if !activeCategories(for: head).isEmpty || !archivedCategories(for: head).isEmpty {
                                HeadCategorySection(
                                    head: head,
                                    activeCategories: activeCategories(for: head),
                                    archivedCategories: archivedCategories(for: head),
                                    isRemoving: isRemoving,
                                    showsArchived: headsShowingArchived.contains(head.persistentModelID),
                                    gridColumns: gridColumns,
                                    onToggleArchived: { toggleArchivedVisibility(for: head) },
                                    onTapCategory: { editingCategory = $0 },
                                    onArchive: archive,
                                    onRestore: restore
                                )
                                .categoryCardStyle()
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                    .padding(.top, 4)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isRemoving.toggle()
                } label: {
                    Image(systemName: isRemoving ? "checkmark" : "pencil")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewCategory = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewCategory) {
            NavigationStack {
                CategoryEditorView(category: nil, defaultHeadCategory: nil, showsCancelButton: true)
            }
            .preferredColorScheme(.dark)
        }
        .sheet(item: $editingCategory) { category in
            NavigationStack {
                CategoryEditorView(category: category, defaultHeadCategory: nil, showsCancelButton: true)
            }
            .preferredColorScheme(.dark)
        }
    }
}

private struct HeadCategorySection: View {
    let head: HeadCategory
    let activeCategories: [Category]
    let archivedCategories: [Category]
    let isRemoving: Bool
    let showsArchived: Bool
    let gridColumns: [GridItem]
    let onToggleArchived: () -> Void
    let onTapCategory: (Category) -> Void
    let onArchive: (Category) -> Void
    let onRestore: (Category) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(head.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                if !archivedCategories.isEmpty {
                    Button(action: onToggleArchived) {
                        Image(systemName: showsArchived ? "eye.fill" : "eye.slash")
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(activeCategories) { category in
                    CategoryTile(category: category, badge: isRemoving ? .remove : nil) {
                        if isRemoving {
                            onArchive(category)
                        } else {
                            onTapCategory(category)
                        }
                    }
                }

                if showsArchived {
                    ForEach(archivedCategories) { category in
                        CategoryTile(category: category, badge: .restore, dimmed: true) {
                            onRestore(category)
                        }
                    }
                }
            }
        }
    }
}

private struct CategoryTile: View {
    let category: Category
    var badge: TileBadge?
    var dimmed = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    CategoryIconView(category: category, size: 56)
                        .opacity(dimmed ? 0.45 : 1)

                    if let badge {
                        Image(systemName: badge == .remove ? "minus.circle.fill" : "arrow.uturn.backward.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, badge == .remove ? Color.expenseRed : Color.emerald)
                            .font(.system(size: 18))
                            .background(Circle().fill(Color.appBackground))
                            .offset(x: 6, y: -6)
                    }
                }

                Text(category.name)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(dimmed ? 0.5 : 1))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func categoryCardStyle() -> some View {
        padding(16)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
    }
}

#Preview {
    NavigationStack {
        CategoriesView()
    }
    .preferredColorScheme(.dark)
    .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
