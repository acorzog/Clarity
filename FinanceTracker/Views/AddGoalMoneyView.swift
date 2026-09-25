import SwiftUI
import SwiftData

/// Goal "Add Money" — `CLARITY_GOALS_UX_SPEC.md` §12 (revised, Phase 2N-C). Manual entry (no
/// `Entry` required) is the primary path, mirroring `SetWalletGoalView`'s simple amount-entry
/// shape; linking an existing or newly-created transaction is a clearly secondary, optional
/// action, reached via "Link a transaction instead."
///
/// `nil = create, non-nil = edit` (the app's consistent editor convention, matching
/// `CategoryEditorView`/`WalletEditorView`/`GoalEditorView`). Editing only exposes Amount/
/// Direction/Date, per this phase's brief — the linked `Entry`, if any, can never be reassigned
/// from here (remove-and-re-add is the only path, §16), and Note is create-only.
struct AddGoalMoneyView: View {
    let goal: Goal
    var contribution: GoalContribution?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var direction: GoalPresentation.GoalContributionDirection = .deposit
    @State private var date = Date.now
    @State private var note = ""
    @State private var linkedEntry: Entry?

    @State private var showingLinkOptions = false
    @State private var showingEntryPicker = false
    @State private var showingNewTransaction = false
    @State private var hasLoaded = false
    @FocusState private var amountFieldFocused: Bool

    private var isEditing: Bool { contribution != nil }

    private var parsedAmount: Decimal? { Decimal(decimalInput: amountText) }
    private var isValid: Bool { GoalPresentation.isValidContributionAmount(parsedAmount) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Amount") {
                    AmountField(text: $amountText, style: .compact, focus: $amountFieldFocused)
                }
                .listRowBackground(Color.surfacePrimary)

                Section {
                    Picker("Direction", selection: $direction) {
                        ForEach(GoalPresentation.GoalContributionDirection.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(.emerald)
                }
                .listRowBackground(Color.surfacePrimary)

                Section("Date") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .tint(.emerald)
                }
                .listRowBackground(Color.surfacePrimary)

                if !isEditing {
                    Section("Note") {
                        TextField("Optional", text: $note)
                            .foregroundStyle(.textPrimary)
                    }
                    .listRowBackground(Color.surfacePrimary)

                    Section {
                        if let linkedEntry {
                            linkedEntryRow(linkedEntry)
                        } else {
                            Button {
                                showingLinkOptions = true
                            } label: {
                                Text("Link a transaction instead")
                                    .foregroundStyle(.textSecondary)
                            }
                        }
                    } footer: {
                        Text("Optional — most goals don't need this. A manual amount is enough.")
                            .foregroundStyle(.textTertiary)
                    }
                    .listRowBackground(Color.surfacePrimary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle(isEditing ? "Edit Contribution" : "Add Money")
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
            .confirmationDialog("Link a Transaction", isPresented: $showingLinkOptions, titleVisibility: .visible) {
                Button("Select Existing Transaction") { showingEntryPicker = true }
                Button("Create New Transaction") { showingNewTransaction = true }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showingEntryPicker) {
                ContributionEntryPickerView(onSelect: applyLinkedEntry)
            }
            .sheet(isPresented: $showingNewTransaction) {
                AddTransactionView(
                    initialType: direction == .withdrawal ? .expense : .income,
                    onSave: applyLinkedEntry
                )
            }
        }
        .preferredColorScheme(.dark)
    }

    private func linkedEntryRow(_ entry: Entry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Linked Transaction")
                    .font(.caption)
                    .foregroundStyle(.textTertiary)
                Text(entry.note.isEmpty ? (entry.category?.name ?? entry.wallet.name) : entry.note)
                    .foregroundStyle(.textPrimary)
            }
            Spacer()
            Button {
                linkedEntry = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.textTertiary)
            }
            .accessibilityLabel("Remove link")
        }
    }

    private func applyLinkedEntry(_ entry: Entry) {
        linkedEntry = entry
        amountText = entry.amount.editableText()
        direction = GoalPresentation.defaultDirection(for: entry.type)
        date = entry.date
    }

    private func loadInitialState() {
        guard !hasLoaded else { return }
        hasLoaded = true

        if let contribution {
            amountText = abs(contribution.amount).editableText()
            direction = contribution.amount < 0 ? .withdrawal : .deposit
            date = contribution.date
        } else {
            amountFieldFocused = true
        }
    }

    private func save() {
        guard let magnitude = parsedAmount, GoalPresentation.isValidContributionAmount(magnitude) else { return }
        let signedAmount = GoalPresentation.signedAmount(magnitude, direction: direction)

        if let contribution {
            contribution.amount = signedAmount
            contribution.date = date
        } else {
            let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            let newContribution = GoalContribution(
                amount: signedAmount,
                date: date,
                goal: goal,
                transaction: linkedEntry,
                note: trimmedNote.isEmpty ? nil : trimmedNote
            )
            modelContext.insert(newContribution)
        }
        dismiss()
    }
}
