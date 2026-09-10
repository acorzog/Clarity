import SwiftUI
import SwiftData

/// Create/edit a Goal — `CLARITY_GOALS_UX_SPEC.md` §8. Sheet-presented, `nil = create, non-nil =
/// edit` (the app's consistent editor convention, matching `CategoryEditorView`/`WalletEditorView`).
/// Appearance (icon grid + color swatch row) mirrors `WalletEditorView`'s exact structure — a
/// curated icon array + `ClarityColorPalette`, rather than `CategoryEditorView`'s larger
/// search/group/emoji picker, since a Goal's customization needs (icon + color only, no emoji)
/// match Wallet's shape, not Category's. This is a deliberate deviation from
/// `CLARITY_GOALS_UX_SPEC.md` §8's Open Decision #3 recommendation to reuse `IconCatalog`
/// verbatim — see the Phase 2N-B final report for why.
struct GoalEditorView: View {
    let goal: Goal?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Goal.sortOrder) private var allGoals: [Goal]

    @State private var name = ""
    @State private var amountText = ""
    @State private var hasTargetDate = false
    @State private var targetDate = Date.now
    @State private var icon = "target"
    @State private var colorHex = "#10B981"
    @State private var contextWallet: Wallet?

    @State private var showingDatePicker = false
    @State private var showingWalletPicker = false
    @State private var hasLoaded = false
    @FocusState private var nameFieldFocused: Bool

    private let iconChoices = [
        "target", "airplane", "house.fill", "car.fill", "graduationcap.fill", "gift.fill",
        "heart.fill", "star.fill", "banknote.fill", "sparkles", "camera.fill", "briefcase.fill"
    ]
    private let colorChoices = ClarityColorPalette.hexValues

    private var isEditing: Bool { goal != nil }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (Decimal(decimalInput: amountText) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Goal name", text: $name)
                        .foregroundStyle(.textPrimary)
                        .focused($nameFieldFocused)
                }
                .listRowBackground(Color.surfacePrimary)

                Section("Target Amount") {
                    AmountField(text: $amountText, style: .compact)
                }
                .listRowBackground(Color.surfacePrimary)

                Section {
                    Toggle("Set a target date", isOn: $hasTargetDate.animation())
                        .tint(.emerald)
                    if hasTargetDate {
                        SelectionRow(
                            title: "Target Date",
                            iconName: nil,
                            iconColorHex: nil,
                            valueName: targetDate.formatted(date: .abbreviated, time: .omitted)
                        ) {
                            showingDatePicker = true
                        }
                    }
                } footer: {
                    Text("Optional — a goal without a deadline is perfectly valid.")
                        .foregroundStyle(.textTertiary)
                }
                .listRowBackground(Color.surfacePrimary)

                Section("Appearance") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(iconChoices, id: \.self) { candidate in
                            Button {
                                icon = candidate
                            } label: {
                                Image(systemName: candidate)
                                    .font(.title3)
                                    .foregroundStyle(icon == candidate ? .black : .textPrimary)
                                    .frame(width: 38, height: 38)
                                    .background(
                                        icon == candidate ? Color(hex: colorHex) : Color.surfaceSecondary,
                                        in: Circle()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(colorChoices, id: \.self) { hex in
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
                .listRowBackground(Color.surfacePrimary)

                Section {
                    SelectionRow(
                        title: "Context Account",
                        iconName: contextWallet?.icon,
                        iconColorHex: contextWallet?.colorHex,
                        valueName: contextWallet?.name
                    ) {
                        showingWalletPicker = true
                    }
                } footer: {
                    Text("Optional — for your reference only. It never affects this goal's progress.")
                        .foregroundStyle(.textTertiary)
                }
                .listRowBackground(Color.surfacePrimary)
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle(isEditing ? "Edit Goal" : "New Goal")
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
            .sheet(isPresented: $showingDatePicker) {
                DatePickerSheet(date: $targetDate)
            }
            .sheet(isPresented: $showingWalletPicker) {
                WalletPickerView(selection: $contextWallet)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func loadInitialState() {
        guard !hasLoaded else { return }
        hasLoaded = true

        if let goal {
            name = goal.name
            amountText = goal.targetAmount.editableText()
            if let targetDate = goal.targetDate {
                hasTargetDate = true
                self.targetDate = targetDate
            }
            icon = goal.icon
            colorHex = goal.colorHex
            contextWallet = goal.contextWallet
        } else {
            nameFieldFocused = true
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, let amount = Decimal(decimalInput: amountText), amount > 0 else { return }

        if let goal {
            goal.name = trimmedName
            goal.targetAmount = amount
            goal.targetDate = hasTargetDate ? targetDate : nil
            goal.icon = icon
            goal.colorHex = colorHex
            goal.contextWallet = contextWallet
        } else {
            let newGoal = Goal(
                name: trimmedName,
                icon: icon,
                colorHex: colorHex,
                targetAmount: amount,
                sortOrder: (allGoals.map(\.sortOrder).max() ?? -1) + 1,
                targetDate: hasTargetDate ? targetDate : nil,
                contextWallet: contextWallet
            )
            modelContext.insert(newGoal)
        }
        dismiss()
    }
}
