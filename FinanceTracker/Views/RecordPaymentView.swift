import SwiftUI
import SwiftData

/// The bridge from the shared domain into personal finance. Recording a Settlement here never
/// by itself creates a personal Entry — that only happens if the user leaves "Add to
/// Transactions" on and confirms. The amount recorded can differ from (and be less than) the
/// calculated outstanding balance, which supports partial settlement.
struct RecordPaymentView: View {
    let event: SharedEvent
    let person: Person

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Wallet.sortOrder) private var allWallets: [Wallet]
    @Query private var allCategories: [Category]

    @State private var amountText = ""
    @State private var paymentMethod: SettlementPaymentMethod = .cash
    @State private var addToTransactions = true
    @State private var selectedWallet: Wallet?
    @State private var selectedCategory: Category?
    @State private var showingCategoryPicker = false
    @State private var showingWalletPicker = false
    @State private var hasLoaded = false
    /// Guards against a fast double-tap on Confirm creating two Settlements (and two linked
    /// Entries) for the same payment before the sheet finishes dismissing.
    @State private var isSubmitting = false
    /// This device's own event-scoped Person for a collaborative event, resolved via
    /// `EventParticipant.userRecordID` (never `Person.isCurrentUser` — see rule: collaborative
    /// identity must resolve through EventParticipant). `nil` for a local-only event, or before
    /// resolution completes, in which case `event.currentUser` is used exactly as before.
    @State private var identifiedYou: Person?

    /// The Person representing "you" for constructing this settlement — event-scoped identity
    /// when known, falling back to the existing local-only behavior otherwise.
    private var you: Person? { identifiedYou ?? event.currentUser }

    private var calculatedOutstanding: Decimal {
        abs(event.outstandingBalance(for: person))
    }

    /// True when `person` owes the current user (so this records a payment received);
    /// false when the current user owes `person` (so this records a payment made).
    private var personOwesYou: Bool {
        event.outstandingBalance(for: person) >= 0
    }

    private var amountValue: Decimal? {
        guard let value = Decimal(decimalInput: amountText), value > 0 else { return nil }
        return value
    }

    private var remaining: Decimal {
        calculatedOutstanding - (amountValue ?? 0)
    }

    /// True once the entered amount exceeds what's actually outstanding — never silently
    /// clamped, this instead disables Confirm and shows `amountValidationMessage`.
    private var exceedsOutstanding: Bool {
        guard let amountValue else { return false }
        return amountValue > calculatedOutstanding
    }

    private var amountValidationMessage: String? {
        guard exceedsOutstanding else { return nil }
        return "Can't exceed the outstanding balance of \(calculatedOutstanding.currencyFormatted)."
    }

    private var isValid: Bool {
        guard let amountValue, amountValue <= calculatedOutstanding else { return false }
        guard addToTransactions else { return true }
        return selectedWallet != nil && selectedCategory != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(personOwesYou ? "\(person.displayName) paid you" : "You paid \(person.displayName)")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("Shared balance: \(calculatedOutstanding.currencyFormatted)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .listRowBackground(Color.white.opacity(0.05))

                Section("Amount") {
                    AmountField(text: $amountText, style: .compact)
                    if let amountValidationMessage {
                        Text(amountValidationMessage)
                            .font(.caption)
                            .foregroundStyle(Color.expenseRed)
                    }
                    HStack {
                        Text("Remaining after this")
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        Text(remaining.currencyFormatted)
                            .foregroundStyle(remaining <= 0 ? Color.emerald : .white.opacity(0.8))
                    }
                    .font(.caption)
                }
                .listRowBackground(Color.white.opacity(0.05))

                Section("Payment Method") {
                    Picker("Payment Method", selection: $paymentMethod) {
                        ForEach(SettlementPaymentMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.white.opacity(0.05))

                Section {
                    Toggle("Add to Transactions", isOn: $addToTransactions)
                        .tint(.emerald)

                    if addToTransactions {
                        SelectionRow(
                            title: "Account",
                            iconName: selectedWallet?.icon,
                            iconColorHex: selectedWallet?.colorHex,
                            valueName: selectedWallet?.name
                        ) {
                            showingWalletPicker = true
                        }
                        SelectionRow(
                            title: "Category",
                            iconName: selectedCategory?.customIcon ?? selectedCategory?.headCategory.icon,
                            iconColorHex: selectedCategory?.headCategory.colorHex,
                            valueName: selectedCategory?.name
                        ) {
                            showingCategoryPicker = true
                        }
                    }
                } footer: {
                    Text(
                        addToTransactions
                            ? "Creates a personal \(personOwesYou ? "income" : "expense") transaction for this amount, linked back to \(event.title)."
                            : "This payment stays inside Shared Expenses only — your personal transactions won't change."
                    )
                    .foregroundStyle(.white.opacity(0.4))
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle(personOwesYou ? "Record Payment" : "Mark as Paid")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm", action: confirm)
                        .disabled(!isValid || isSubmitting)
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: loadInitialState)
        .task {
            await resolveIdentifiedYouIfNeeded()
        }
        .sheet(isPresented: $showingWalletPicker) {
            WalletPickerView(selection: $selectedWallet)
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(selection: $selectedCategory, isIncome: personOwesYou)
        }
    }

    private func loadInitialState() {
        guard !hasLoaded else { return }
        hasLoaded = true
        amountText = calculatedOutstanding.editableText()
        selectedWallet = Wallet.preferredFallback(among: allWallets)
        // Only pre-fill for money coming in — an outgoing settlement has no single obviously
        // correct expense category, so that case is left for the user to choose explicitly.
        if personOwesYou {
            selectedCategory = Category.reimburse(in: allCategories)
        }
    }

    /// For a collaborative event, resolves this device's own event-scoped Person once via
    /// `EventParticipant.userRecordID` (rule: never `Person.isCurrentUser` as the collaborative
    /// identity source). A no-op for a local-only event or when this device hasn't identified
    /// itself in this event yet — `event.currentUser` (existing behavior) is used in that case.
    private func resolveIdentifiedYouIfNeeded() async {
        guard event.isCollaborationEnabled, let service = CollaborationSyncService.shared else { return }
        guard let userRecordID = await service.currentUserRecordID() else { return }
        identifiedYou = event.currentParticipant(for: userRecordID)?.person
    }

    private func confirm() {
        guard !isSubmitting, let amountValue, amountValue <= calculatedOutstanding else { return }
        isSubmitting = true

        let fromPerson = personOwesYou ? person : you
        let toPerson = personOwesYou ? you : person

        let settlement = Settlement(
            fromPerson: fromPerson,
            toPerson: toPerson,
            amount: amountValue,
            paymentMethod: paymentMethod,
            event: event
        )
        modelContext.insert(settlement)
        event.settlements.append(settlement)

        if addToTransactions, let selectedWallet, let selectedCategory {
            let entry = Entry(
                amount: amountValue,
                note: "\(event.title) · \(person.displayName)",
                type: personOwesYou ? .income : .expense,
                category: selectedCategory,
                wallet: selectedWallet
            )
            modelContext.insert(entry)
            entry.sharedSettlement = settlement
            settlement.transaction = entry
            // entry/settlement.transaction is never uploaded — see CloudKitSharedEventMapper and
            // the invariant this phase preserves: Personal Finance never crosses the CloudKit
            // boundary, only the Settlement record itself does (queued below).
        }

        event.updatedAt = .now

        if event.isCollaborationEnabled {
            CollaborationSyncService.shared?.queueUpload(of: event)
        }

        dismiss()
    }
}

