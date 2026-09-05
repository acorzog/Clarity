import SwiftUI
import SwiftData

private enum IconMode: String, CaseIterable {
    case icon = "Icon"
    case emoji = "Emoji"
}

private struct IconGroup {
    let title: String
    let icons: [String]
}

private let iconGroups: [IconGroup] = [
    IconGroup(title: "Shopping", icons: [
        "cart.fill", "bag.fill", "basket.fill", "tag.fill", "gift.fill", "shippingbox.fill"
    ]),
    IconGroup(title: "Food & Drink", icons: [
        "fork.knife", "cup.and.saucer.fill", "wineglass.fill", "birthday.cake.fill",
        "takeoutbag.and.cup.and.straw.fill", "mug.fill"
    ]),
    IconGroup(title: "Transport", icons: [
        "car.fill", "bus.fill", "tram.fill", "bicycle", "fuelpump.fill", "parkingsign.circle.fill"
    ]),
    IconGroup(title: "Health", icons: [
        "cross.case.fill", "heart.fill", "pills.fill", "figure.walk", "bandage.fill", "waveform.path.ecg"
    ]),
    IconGroup(title: "Home & Utilities", icons: [
        "house.fill", "bolt.fill", "wifi", "wrench.and.screwdriver.fill", "lightbulb.fill", "flame.fill"
    ]),
    IconGroup(title: "Entertainment", icons: [
        "gamecontroller.fill", "film.fill", "music.note", "ticket.fill", "tv.fill", "headphones"
    ]),
    IconGroup(title: "Finance", icons: [
        "banknote.fill", "creditcard.fill", "chart.line.uptrend.xyaxis", "dollarsign.circle.fill",
        "building.columns.fill", "chart.pie.fill"
    ]),
    IconGroup(title: "Travel", icons: [
        "airplane", "suitcase.fill", "map.fill", "globe", "beach.umbrella.fill", "camera.fill"
    ]),
    IconGroup(title: "Family & Pets", icons: [
        "pawprint.fill", "person.2.fill", "person.3.fill", "figure.and.child.holdinghands",
        "dog.fill", "cat.fill"
    ])
]

/// Always sheet-presented (from CategoriesView or PlanView's income "Add Category"
/// row), wrapped in its own NavigationStack by the caller — `showsCancelButton`
/// controls whether a Cancel button appears alongside Save.
struct CategoryEditorView: View {
    let category: Category?
    var defaultHeadCategory: HeadCategory?
    var defaultIsIncome = false
    var showsCancelButton = false

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]

    @State private var name = ""
    @State private var selectedHeadCategory: HeadCategory?
    @State private var iconMode: IconMode = .icon
    @State private var selectedIcon = "cart.fill"
    @State private var selectedIconGroup = iconGroups[0].title
    @State private var emojiText = ""
    @State private var selectedColorHex: String?
    @State private var isSavings = false
    @State private var hasLoaded = false
    @State private var isPickingHeadCategory = false

    private let colorChoices = [
        "#F59E0B", "#F97316", "#EF4444", "#EC4899", "#8B5CF6",
        "#6366F1", "#3B82F6", "#0EA5E9", "#14B8A6", "#10B981",
        "#84CC16", "#6B7280"
    ]

    private var isEditing: Bool { category != nil }

    private var previewColor: Color {
        Color(hex: selectedColorHex ?? selectedHeadCategory?.colorHex ?? "#10B981")
    }

    private var currentGroupIcons: [String] {
        iconGroups.first { $0.title == selectedIconGroup }?.icons ?? []
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Category name", text: $name)
                    .foregroundStyle(.white)
            }
            .listRowBackground(Color.white.opacity(0.05))

            Section("Head Category") {
                Button {
                    isPickingHeadCategory = true
                } label: {
                    HStack {
                        Text(selectedHeadCategory?.name ?? "Select")
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(Color.white.opacity(0.05))

            Section("Appearance") {
                Picker("Appearance", selection: $iconMode) {
                    ForEach(IconMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .tint(.emerald)
                .padding(.vertical, 4)

                if iconMode == .icon {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(iconGroups, id: \.title) { group in
                                Button {
                                    selectedIconGroup = group.title
                                } label: {
                                    Text(group.title)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(
                                            selectedIconGroup == group.title ? previewColor : Color.white.opacity(0.08),
                                            in: Capsule()
                                        )
                                        .foregroundStyle(selectedIconGroup == group.title ? .black : .white)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(currentGroupIcons, id: \.self) { candidate in
                            Button {
                                selectedIcon = candidate
                            } label: {
                                Image(systemName: candidate)
                                    .font(.title3)
                                    .foregroundStyle(selectedIcon == candidate ? .black : .white)
                                    .frame(width: 38, height: 38)
                                    .background(
                                        selectedIcon == candidate ? previewColor : Color.white.opacity(0.08),
                                        in: Circle()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    TextField("Tap to pick an emoji", text: $emojiText)
                        .font(.system(size: 32))
                        .multilineTextAlignment(.center)
                        .onChange(of: emojiText) { _, newValue in
                            if let last = newValue.last {
                                emojiText = String(last)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }

                colorSwatchRow
            }
            .listRowBackground(Color.white.opacity(0.05))

            Section {
                Toggle("Savings Category", isOn: $isSavings)
                    .tint(.emerald)
            } footer: {
                Text("Savings categories represent money set aside rather than spent.")
                    .foregroundStyle(.white.opacity(0.4))
            }
            .listRowBackground(Color.white.opacity(0.05))
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle(isEditing ? "Edit Category" : "New Category")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCancelButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!isValid)
                    .fontWeight(.semibold)
            }
        }
        .onAppear(perform: loadInitialState)
        .sheet(isPresented: $isPickingHeadCategory) {
            HeadCategoryPickerView(selection: $selectedHeadCategory)
        }
    }

    private var colorSwatchRow: some View {
        HStack(spacing: 10) {
            ForEach(colorChoices, id: \.self) { hex in
                Button {
                    selectedColorHex = hex
                } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 28, height: 28)
                        .overlay {
                            if selectedColorHex == hex {
                                Circle().stroke(Color.white, lineWidth: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && selectedHeadCategory != nil
    }

    private func loadInitialState() {
        guard !hasLoaded else { return }
        hasLoaded = true

        if let category {
            name = category.name
            selectedHeadCategory = category.headCategory
            iconMode = category.iconIsEmoji ? .emoji : .icon
            if category.iconIsEmoji {
                emojiText = category.customIcon ?? ""
            } else if let icon = category.customIcon {
                selectedIcon = icon
                if let group = iconGroups.first(where: { $0.icons.contains(icon) }) {
                    selectedIconGroup = group.title
                }
            }
            selectedColorHex = category.customColorHex
            isSavings = category.isSavings
        } else {
            selectedHeadCategory = defaultHeadCategory ?? headCategories.first
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, let head = selectedHeadCategory else { return }

        let icon: String?
        let usesEmoji: Bool
        if iconMode == .emoji && !emojiText.isEmpty {
            icon = emojiText
            usesEmoji = true
        } else {
            icon = selectedIcon
            usesEmoji = false
        }

        if let category {
            category.name = trimmedName
            category.headCategory = head
            category.customIcon = icon
            category.iconIsEmoji = usesEmoji
            category.customColorHex = selectedColorHex
            category.isSavings = isSavings
        } else {
            let newCategory = Category(
                name: trimmedName,
                customIcon: icon,
                iconIsEmoji: usesEmoji,
                customColorHex: selectedColorHex,
                isSavings: isSavings,
                isIncome: defaultIsIncome,
                headCategory: head
            )
            modelContext.insert(newCategory)
        }
        dismiss()
    }
}
