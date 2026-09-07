import SwiftUI
import SwiftData

private let headCategoryColorChoices = [
    "#F59E0B", "#F97316", "#EF4444", "#EC4899", "#8B5CF6",
    "#6366F1", "#3B82F6", "#0EA5E9", "#14B8A6", "#10B981",
    "#84CC16", "#6B7280"
]

/// Sheet for renaming an existing HeadCategory or changing its icon/color — always
/// wrapped in its own NavigationStack by the caller, mirroring CategoryEditorView.
struct HeadCategoryEditorView: View {
    let headCategory: HeadCategory

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var icon = "square.grid.2x2.fill"
    @State private var colorHex = "#10B981"
    @State private var selectedIconGroup = IconCatalog.groups[0].title
    @State private var iconSearchText = ""
    @State private var hasLoaded = false

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var currentGroupIcons: [String] {
        IconCatalog.groups.first { $0.title == selectedIconGroup }?.icons ?? []
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Head category name", text: $name)
                    .foregroundStyle(.white)
            }
            .listRowBackground(Color.white.opacity(0.05))

            Section("Appearance") {
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
                                            selectedIconGroup == group.title ? Color(hex: colorHex) : Color.white.opacity(0.08),
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
                                icon = candidate
                            } label: {
                                Image(systemName: candidate)
                                    .font(.title3)
                                    .foregroundStyle(icon == candidate ? .black : .white)
                                    .frame(width: 38, height: 38)
                                    .background(
                                        icon == candidate ? Color(hex: colorHex) : Color.white.opacity(0.08),
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
                        // group, so show them larger than the browse grid.
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                            ForEach(results) { def in
                                Button {
                                    icon = def.symbolName
                                } label: {
                                    Image(systemName: def.symbolName)
                                        .font(.title)
                                        .foregroundStyle(icon == def.symbolName ? .black : .white)
                                        .frame(width: 52, height: 52)
                                        .background(
                                            icon == def.symbolName ? Color(hex: colorHex) : Color.white.opacity(0.08),
                                            in: Circle()
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(headCategoryColorChoices, id: \.self) { hex in
                            Button {
                                colorHex = hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        if colorHex == hex {
                                            Circle().stroke(Color.white, lineWidth: 2)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }

                        ColorPicker(
                            "Custom color",
                            selection: Binding(get: { Color(hex: colorHex) }, set: { colorHex = $0.hexString }),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                        .frame(width: 28, height: 28)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listRowBackground(Color.white.opacity(0.05))
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Edit Head Category")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!isValid)
                    .fontWeight(.semibold)
            }
        }
        .onAppear(perform: loadInitialState)
    }

    private func loadInitialState() {
        guard !hasLoaded else { return }
        hasLoaded = true
        name = headCategory.name
        icon = headCategory.icon
        colorHex = headCategory.colorHex
        if let group = IconCatalog.groups.first(where: { $0.icons.contains(icon) }) {
            selectedIconGroup = group.title
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        headCategory.name = trimmed
        headCategory.icon = icon
        headCategory.colorHex = colorHex
        dismiss()
    }
}

#Preview {
    NavigationStack {
        HeadCategoryEditorView(headCategory: HeadCategory(name: "Housing", icon: "house.fill", colorHex: "#F59E0B"))
    }
    .preferredColorScheme(.dark)
    .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
