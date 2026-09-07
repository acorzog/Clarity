import SwiftUI
import SwiftData

private enum IconMode: String, CaseIterable {
    case icon = "Icon"
    case emoji = "Emoji"
}

/// Always sheet-presented (from CategoriesView or PlanView's income "Add Category"
/// row), wrapped in its own NavigationStack by the caller — `showsCancelButton`
/// controls whether a Cancel button appears alongside Save.
struct CategoryEditorView: View {
    let category: Category?
    var defaultHeadCategory: HeadCategory?
    var defaultIsIncome = false
    var showsCancelButton = false
    /// Called with the created/edited category right before this view dismisses itself — lets
    /// a caller like `CategoryPickerView` auto-select a category created inline instead of
    /// requiring a second tap to find and pick it after the sheet closes.
    var onSave: ((Category) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]

    @State private var name = ""
    @State private var selectedHeadCategory: HeadCategory?
    @State private var iconMode: IconMode = .icon
    @State private var selectedIcon = "cart.fill"
    @State private var selectedIconGroup = IconCatalog.groups[0].title
    @State private var iconSearchText = ""
    @State private var emojiText = ""
    @State private var selectedEmojiGroup = EmojiCatalog.groups[0].title
    @State private var emojiSearchText = ""
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
        IconCatalog.groups.first { $0.title == selectedIconGroup }?.icons ?? []
    }

    private var currentGroupEmoji: [String] {
        EmojiCatalog.groups.first { $0.title == selectedEmojiGroup }?.emoji ?? []
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
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.white.opacity(0.4))
                        TextField("Search icons (e.g. \"coffee\")", text: $iconSearchText)
                            .foregroundStyle(.white)
                        if !iconSearchText.isEmpty {
                            Button {
                                iconSearchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.vertical, 4)

                    if iconSearchText.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(IconCatalog.groups, id: \.title) { group in
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
                        let results = IconCatalog.search(iconSearchText)
                        if results.isEmpty {
                            Text("No icons match “\(iconSearchText)”.")
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.vertical, 8)
                        } else {
                            // Search results are usually a handful of icons rather than a full
                            // group, so show them larger than the browse grid — no need to
                            // conserve space the way the 6-column group grid does.
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                                ForEach(results) { def in
                                    Button {
                                        selectedIcon = def.symbolName
                                    } label: {
                                        Image(systemName: def.symbolName)
                                            .font(.title)
                                            .foregroundStyle(selectedIcon == def.symbolName ? .black : .white)
                                            .frame(width: 52, height: 52)
                                            .background(
                                                selectedIcon == def.symbolName ? previewColor : Color.white.opacity(0.08),
                                                in: Circle()
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.white.opacity(0.4))
                        TextField("Search emoji (e.g. \"party\")", text: $emojiSearchText)
                            .foregroundStyle(.white)
                        if !emojiSearchText.isEmpty {
                            Button {
                                emojiSearchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.vertical, 4)

                    if emojiSearchText.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(EmojiCatalog.groups, id: \.title) { group in
                                    Button {
                                        selectedEmojiGroup = group.title
                                    } label: {
                                        Text(group.title)
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(
                                                selectedEmojiGroup == group.title ? previewColor : Color.white.opacity(0.08),
                                                in: Capsule()
                                            )
                                            .foregroundStyle(selectedEmojiGroup == group.title ? .black : .white)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                            ForEach(currentGroupEmoji, id: \.self) { candidate in
                                Button {
                                    emojiText = candidate
                                } label: {
                                    Text(candidate)
                                        .font(.title2)
                                        .frame(width: 38, height: 38)
                                        .background(
                                            emojiText == candidate ? previewColor : Color.white.opacity(0.08),
                                            in: Circle()
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        let results = EmojiCatalog.search(emojiSearchText)
                        if results.isEmpty {
                            Text("No emoji match “\(emojiSearchText)”.")
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.vertical, 8)
                        } else {
                            // Same reasoning as the icon search grid above: fewer results, so
                            // give them more room than the browse-by-group grid does.
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                                ForEach(results) { def in
                                    Button {
                                        emojiText = def.emoji
                                    } label: {
                                        Text(def.emoji)
                                            .font(.title)
                                            .frame(width: 52, height: 52)
                                            .background(
                                                emojiText == def.emoji ? previewColor : Color.white.opacity(0.08),
                                                in: Circle()
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
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
        ScrollView(.horizontal, showsIndicators: false) {
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

                ColorPicker("Custom color", selection: customColorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 28, height: 28)
            }
            .padding(.vertical, 4)
        }
    }

    /// Bridges the swatch model's `#RRGGBB` storage to `ColorPicker`'s `Color`, so a shade
    /// outside the 12 presets can still be picked and round-trips back to hex on save.
    private var customColorBinding: Binding<Color> {
        Binding(
            get: { previewColor },
            set: { selectedColorHex = $0.hexString }
        )
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
                if let group = EmojiCatalog.groups.first(where: { $0.emoji.contains(emojiText) }) {
                    selectedEmojiGroup = group.title
                }
            } else if let icon = category.customIcon {
                selectedIcon = icon
                if let group = IconCatalog.groups.first(where: { $0.icons.contains(icon) }) {
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
            onSave?(category)
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
            onSave?(newCategory)
        }
        dismiss()
    }
}
