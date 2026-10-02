import SwiftUI
import SwiftData

/// A single global list of every archived category across all Head Categories, so restoring one
/// doesn't require first finding and opening its specific Head Category section in `CategoriesView`
/// (the per-head eye-toggle reveal there still works too — this is an additional, faster path to
/// the same `isArchived = false` restore, not a replacement). Reached from `CategoriesView`'s
/// toolbar.
struct RemovedCategoriesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    // Queries `Category` directly, not `HeadCategory` — a `@Query` only re-runs its view update
    // when a change touches the type it's actually watching. A `@Query<HeadCategory>` does not
    // reliably re-render when a related `Category.isArchived` flips (a different model type),
    // which left this screen showing a just-restored category as still "removed" until something
    // else happened to force a refresh. Watching `Category` itself means a restore here is seen
    // immediately.
    @Query(sort: \Category.name) private var allCategories: [Category]

    private struct Section: Identifiable {
        let head: HeadCategory
        let categories: [Category]
        var id: PersistentIdentifier { head.persistentModelID }
    }

    private var sections: [Section] {
        let archived = allCategories.filter(\.isArchived)
        let grouped = Dictionary(grouping: archived) { $0.headCategory.persistentModelID }
        return grouped.compactMap { _, categories in
            guard let head = categories.first?.headCategory else { return nil }
            return Section(head: head, categories: categories.sorted { $0.name < $1.name })
        }
        .sorted { $0.head.sortOrder < $1.head.sortOrder }
    }

    private func restore(_ category: Category) {
        category.isArchived = false
        // `@Query` reliably re-renders on an explicit context save, not just the in-memory
        // property mutation above — see the doc comment on `allCategories`.
        try? modelContext.save()
    }

    var body: some View {
        NavigationStack {
            Group {
                if sections.isEmpty {
                    EmptyStateView(
                        icon: "arrow.uturn.backward.circle",
                        title: "No Removed Categories",
                        message: "Categories you remove show up here so you can bring them back instead of starting over."
                    )
                } else {
                    List {
                        ForEach(sections) { section in
                            SwiftUI.Section(section.head.name) {
                                ForEach(section.categories) { category in
                                    RemovedCategoryRow(category: category, onRestore: { restore(category) })
                                        .listRowBackground(Color.white.opacity(0.05))
                                }
                            }
                            .listRowSeparatorTint(.white.opacity(0.1))
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Removed Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct RemovedCategoryRow: View {
    let category: Category
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CategoryIconView(category: category, size: 36)
                .opacity(0.5)
            Text(category.name)
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            restoreButton
        }
    }

    private var restoreButton: some View {
        Button(action: onRestore) {
            Label("Restore", systemImage: "arrow.uturn.backward.circle.fill")
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(Color.emerald)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Restore \(category.name)")
    }
}

#Preview {
    RemovedCategoriesView()
        .preferredColorScheme(.dark)
        .modelContainer(for: [HeadCategory.self, Category.self], inMemory: true)
}
