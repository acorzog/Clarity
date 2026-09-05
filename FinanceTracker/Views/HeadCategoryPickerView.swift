import SwiftUI
import SwiftData

/// Sheet used everywhere a HeadCategory needs to be picked (new/edit category
/// forms). Lets the user select an existing head category or create one
/// inline via the "Create new" field without leaving the sheet.
struct HeadCategoryPickerView: View {
    @Binding var selection: HeadCategory?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]
    @State private var newName = ""

    private static let defaultIcon = "square.grid.2x2.fill"
    private static let defaultColorChoices = [
        "#F59E0B", "#F97316", "#EF4444", "#EC4899", "#8B5CF6",
        "#6366F1", "#3B82F6", "#0EA5E9", "#14B8A6", "#10B981"
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Text("Create new:")
                            .foregroundStyle(.white)
                        TextField("e.g. Office costs", text: $newName)
                            .foregroundStyle(.white)
                            .submitLabel(.done)
                            .onSubmit(confirm)
                    }
                }
                .listRowBackground(Color.white.opacity(0.05))

                Section {
                    ForEach(headCategories) { head in
                        Button {
                            selection = head
                            dismiss()
                        } label: {
                            HStack {
                                Text(head.name)
                                    .foregroundStyle(head == selection ? .black : .white)
                                Spacer()
                            }
                            .padding(.horizontal, head == selection ? 12 : 0)
                            .padding(.vertical, head == selection ? 4 : 0)
                            .background(
                                head == selection ? Color.white.opacity(0.9) : Color.clear,
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Head Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        confirm()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func confirm() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            dismiss()
            return
        }

        let nextSortOrder = (headCategories.map(\.sortOrder).max() ?? -1) + 1
        let colorHex = Self.defaultColorChoices[headCategories.count % Self.defaultColorChoices.count]
        let newHead = HeadCategory(name: trimmed, icon: Self.defaultIcon, colorHex: colorHex, sortOrder: nextSortOrder)
        modelContext.insert(newHead)
        selection = newHead
        dismiss()
    }
}
