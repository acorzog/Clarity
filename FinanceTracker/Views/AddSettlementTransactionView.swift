import SwiftUI
import SwiftData

/// Retroactively links an already-recorded Settlement to a personal Transaction — the
/// "[ Add to Transactions ]" action offered next to a settlement that wasn't recorded at the
/// time (see section 33 of the shared-expenses spec).
struct AddSettlementTransactionView: View {
    let settlement: Settlement

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Wallet.sortOrder) private var allWallets: [Wallet]
    @Query private var allCategories: [Category]

    @State private var selectedWallet: Wallet?
    @State private var selectedCategory: Category?
    @State private var showingWalletPicker = false
    @State private var showingCategoryPicker = false
    /// Guards against a fast double-tap on Confirm linking two Entries to the same Settlement
    /// before the sheet finishes dismissing.
    @State private var isSubmitting = false

    private var isIncome: Bool {
        settlement.toPerson?.isCurrentUser ?? true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Amount")
                            .foregroundStyle(.white)
                        Spacer()
                        Text(settlement.amount.currencyFormatted)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .listRowBackground(Color.white.opacity(0.05))

                Section {
                    SelectionRow(
                        title: "Wallet",
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
                .listRowBackground(Color.white.opacity(0.05))
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Add to Transactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm", action: confirm)
                        .disabled(selectedWallet == nil || selectedCategory == nil || isSubmitting)
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            selectedWallet = Wallet.preferredFallback(among: allWallets)
            // Only pre-fill for money coming in — an outgoing settlement has no single obviously
            // correct expense category, so that case is left for the user to choose explicitly.
            if isIncome {
                selectedCategory = Category.reimburse(in: allCategories)
            }
        }
        .sheet(isPresented: $showingWalletPicker) {
            WalletPickerView(selection: $selectedWallet)
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(selection: $selectedCategory, isIncome: isIncome)
        }
    }

    private func confirm() {
        guard !isSubmitting, let selectedWallet, let selectedCategory else { return }
        isSubmitting = true
        let event = settlement.event
        let otherPerson = isIncome ? settlement.fromPerson : settlement.toPerson
        let entry = Entry(
            amount: settlement.amount,
            note: [event?.title, otherPerson?.displayName].compactMap { $0 }.joined(separator: " · "),
            type: isIncome ? .income : .expense,
            category: selectedCategory,
            wallet: selectedWallet
        )
        modelContext.insert(entry)
        entry.sharedSettlement = settlement
        settlement.transaction = entry
        dismiss()
    }
}

private struct SelectionRow: View {
    let title: String
    let iconName: String?
    let iconColorHex: String?
    let valueName: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.white)
                Spacer()
                if let valueName {
                    if let iconName {
                        Image(systemName: iconName)
                            .foregroundStyle(iconColorHex.map { Color(hex: $0) } ?? .white)
                    }
                    Text(valueName)
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    Text("Select")
                        .foregroundStyle(.white.opacity(0.4))
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }
}
