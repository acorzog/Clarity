import SwiftUI
import SwiftData

struct WalletEditorView: View {
    var wallet: Wallet?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Wallet.sortOrder) private var allWallets: [Wallet]

    @State private var name = ""
    @State private var type: WalletType = .spending
    @State private var colorHex = "#10B981"
    @State private var icon = "wallet.pass.fill"
    @State private var currentBalanceText = ""
    @State private var includeInNetWorth = true
    @State private var isDefault = false

    @State private var showingGoalSheet = false
    @State private var showingAllTransactions = false
    @State private var showingRemoveAlert = false
    @State private var showingCannotRemoveAlert = false

    @State private var hasLoaded = false

    private let iconChoices = [
        "wallet.pass.fill", "creditcard.fill", "banknote.fill", "building.columns.fill",
        "dollarsign.circle.fill", "eurosign.circle.fill", "chart.line.uptrend.xyaxis",
        "lock.fill", "gift.fill", "briefcase.fill", "house.fill", "cart.fill"
    ]

    private let colorChoices = [
        "#F59E0B", "#F97316", "#EF4444", "#EC4899", "#8B5CF6",
        "#6366F1", "#3B82F6", "#0EA5E9", "#14B8A6", "#10B981",
        "#84CC16", "#6B7280"
    ]

    private var isEditing: Bool { wallet != nil }

    private var recentTransactions: [Entry] {
        Array((wallet?.allEntries ?? []).prefix(3))
    }

    var body: some View {
        Form {
            if let wallet, !recentTransactions.isEmpty {
                Section("Latest Transactions") {
                    ForEach(recentTransactions) { entry in
                        WalletTransactionRow(entry: entry, wallet: wallet)
                    }
                    Button {
                        showingAllTransactions = true
                    } label: {
                        HStack {
                            Text("See all \(wallet.allEntries.count) transactions")
                                .foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                }
                .listRowBackground(Color.white.opacity(0.05))
            }

            Section("Name") {
                TextField("Wallet name", text: $name)
                    .foregroundStyle(.white)
            }
            .listRowBackground(Color.white.opacity(0.05))

            Section("Type") {
                Picker("Type", selection: $type) {
                    ForEach(WalletType.allCases, id: \.self) { candidate in
                        Text(candidate.rawValue.capitalized).tag(candidate)
                    }
                }
                .pickerStyle(.menu)
                .tint(.white)
            }
            .listRowBackground(Color.white.opacity(0.05))

            Section("Appearance") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                    ForEach(iconChoices, id: \.self) { candidate in
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
            .listRowBackground(Color.white.opacity(0.05))

            Section {
                HStack {
                    Text("Current Balance")
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        toggleBalanceSign()
                    } label: {
                        Image(systemName: "plusminus")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 26, height: 26)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    TextField("0", text: $currentBalanceText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(currentBalanceText.hasPrefix("-") ? Color.expenseRed : .white)
                        .frame(width: 100)
                        .onChange(of: currentBalanceText) { _, newValue in
                            let filtered = newValue.sanitizedDecimalInput(allowNegative: true)
                            if filtered != newValue { currentBalanceText = filtered }
                        }
                }
            } footer: {
                Text("Tap the +/- button for a negative balance — useful for a credit card or other debt wallet, or when spending has taken a wallet below zero.")
                    .foregroundStyle(.white.opacity(0.4))
            }
            .listRowBackground(Color.white.opacity(0.05))

            Section {
                Button {
                    showingGoalSheet = true
                } label: {
                    HStack {
                        Text("Set Goal Amount")
                            .foregroundStyle(.white)
                        Spacer()
                        if let goal = wallet?.goalAmount, goal > 0 {
                            Text(goal.currencyFormatted)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
            }
            .listRowBackground(Color.white.opacity(0.05))

            Section {
                Toggle("Include in Net Worth", isOn: $includeInNetWorth)
                    .tint(.emerald)
                Toggle("Default Wallet", isOn: $isDefault)
                    .tint(.emerald)
            } footer: {
                Text("The default wallet is pre-selected when creating transactions.")
                    .foregroundStyle(.white.opacity(0.4))
            }
            .listRowBackground(Color.white.opacity(0.05))

            if let wallet {
                Section {
                    if wallet.isArchived {
                        Button {
                            wallet.isArchived = false
                            dismiss()
                        } label: {
                            Text("Restore Wallet")
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(Color.emerald)
                        }
                    } else {
                        Button {
                            wallet.isArchived = true
                            dismiss()
                        } label: {
                            Text("Archive Wallet")
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                } footer: {
                    Text(
                        wallet.isArchived
                            ? "Restoring brings this wallet back to the wallet list and makes it selectable for new transactions again."
                            : "Archived wallets are hidden from the wallet list and no longer selectable for new transactions — their balance and history are kept, and can be restored any time."
                    )
                    .foregroundStyle(.white.opacity(0.4))
                }
                .listRowBackground(Color.white.opacity(0.05))

                Section {
                    Button(role: .destructive) {
                        if wallet.canBeDeleted {
                            showingRemoveAlert = true
                        } else {
                            showingCannotRemoveAlert = true
                        }
                    } label: {
                        Text("Remove Wallet")
                            .frame(maxWidth: .infinity)
                    }
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle(isEditing ? "Editing Wallet" : "New Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .fontWeight(.semibold)
            }
        }
        .onAppear(perform: loadInitialState)
        .sheet(isPresented: $showingGoalSheet) {
            if let wallet {
                SetWalletGoalView(wallet: wallet)
            }
        }
        .navigationDestination(isPresented: $showingAllTransactions) {
            if let wallet {
                WalletTransactionsView(wallet: wallet)
            }
        }
        .alert("Remove this wallet?", isPresented: $showingRemoveAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let wallet {
                    modelContext.delete(wallet)
                }
                dismiss()
            }
        } message: {
            Text("This can't be undone.")
        }
        .alert("Can't Remove Wallet", isPresented: $showingCannotRemoveAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This wallet has transactions on it, or is the destination of a transfer from another wallet. Archive it instead, or remove those transactions first.")
        }
    }

    private func loadInitialState() {
        guard !hasLoaded else { return }
        hasLoaded = true

        if let wallet {
            name = wallet.name
            type = wallet.type
            colorHex = wallet.colorHex
            icon = wallet.icon
            currentBalanceText = wallet.balance.editableText()
            includeInNetWorth = wallet.includeInNetWorth
            isDefault = wallet.isDefault
        }
    }

    private func toggleBalanceSign() {
        if currentBalanceText.hasPrefix("-") {
            currentBalanceText.removeFirst()
        } else {
            currentBalanceText = "-" + currentBalanceText
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        let desiredBalance = Decimal(decimalInput: currentBalanceText) ?? 0

        if let wallet {
            // Log the difference as a real entry rather than silently reverse-deriving
            // startingBalance to match — a manual balance correction should show up in the
            // wallet's transaction history like anything else that moves its balance, not
            // disappear into an invisible starting-balance adjustment.
            let delta = desiredBalance - wallet.balance
            if delta != 0 {
                let adjustment = Entry(
                    amount: abs(delta),
                    note: "Balance adjustment",
                    type: delta > 0 ? .income : .expense,
                    wallet: wallet,
                    excludeFromBudget: true
                )
                modelContext.insert(adjustment)
            }
            wallet.name = trimmedName
            wallet.type = type
            wallet.colorHex = colorHex
            wallet.icon = icon
            wallet.includeInNetWorth = includeInNetWorth
            applyDefault(to: wallet, isDefault: isDefault)
        } else {
            let nextSortOrder = (allWallets.map(\.sortOrder).max() ?? -1) + 1
            let newWallet = Wallet(
                name: trimmedName,
                type: type,
                colorHex: colorHex,
                icon: icon,
                startingBalance: desiredBalance,
                includeInNetWorth: includeInNetWorth,
                isDefault: isDefault,
                sortOrder: nextSortOrder
            )
            modelContext.insert(newWallet)
            applyDefault(to: newWallet, isDefault: isDefault)
        }
        dismiss()
    }

    private func applyDefault(to wallet: Wallet, isDefault: Bool) {
        wallet.isDefault = isDefault
        guard isDefault else { return }
        for other in allWallets where other !== wallet {
            other.isDefault = false
        }
    }
}

#Preview {
    NavigationStack {
        WalletEditorView(wallet: nil)
    }
    .preferredColorScheme(.dark)
    .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
