import SwiftUI
import SwiftData

struct CategoryPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]
    @Binding var selection: Category?
    var isIncome = false

    private func categories(for headCategory: HeadCategory) -> [Category] {
        headCategory.categories
            .filter { !$0.isArchived && $0.isIncome == isIncome }
            .sorted { $0.name < $1.name }
    }

    private var hasAnyCategories: Bool {
        headCategories.contains { !categories(for: $0).isEmpty }
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
                        ForEach(headCategories) { headCategory in
                            let categories = categories(for: headCategory)
                            if !categories.isEmpty {
                                Section(headCategory.name) {
                                    ForEach(categories) { category in
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
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
