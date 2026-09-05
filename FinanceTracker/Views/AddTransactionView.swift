import SwiftUI
import SwiftData

struct AddTransactionView: View {
    /// Pass an existing Entry to edit it in place; nil creates a new one.
    var entry: Entry?
    /// Date a new entry defaults to (ignored when editing an existing entry). Lets callers
    /// like the Calendar day sheet pre-fill the day the user tapped instead of today.
    var initialDate: Date = .now
    /// Entry type a new entry defaults to (ignored when editing). Lets callers like the
    /// Wallets screen's transfer shortcut open straight into Transfer mode.
    var initialType: EntryType = .expense
    /// Wallet a new entry defaults to (ignored when editing). Falls back to the user's
    /// default wallet, then the first available one, when nil.
    var initialWallet: Wallet?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Wallet.name) private var allWallets: [Wallet]

    private var wallets: [Wallet] { allWallets.filter { !$0.isArchived } }

    @State private var amountText = ""
    @State private var entryType: EntryType = .expense
    @State private var selectedCategory: Category?
    @State private var selectedWallet: Wallet?
    @State private var destinationWallet: Wallet?
    @State private var note = ""
    @State private var date = Date.now
    @State private var recurrence: RecurrenceRule = .none
    @State private var excludeFromBudget = false

    @State private var showingCategoryPicker = false
    @State private var showingSourceWalletPicker = false
    @State private var showingDestinationWalletPicker = false
    @State private var showingDatePicker = false

    @State private var hasLoaded = false
    /// The note text as loaded — auto-categorization only fires once this diverges,
    /// so opening an existing entry for editing doesn't immediately re-suggest/spend an API call.
    @State private var noteAtLoad = ""

    @FocusState private var amountFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                amountField

                Picker("Type", selection: $entryType) {
                    Text("Expense").tag(EntryType.expense)
                    Text("Income").tag(EntryType.income)
                    Text("Transfer").tag(EntryType.transfer)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 12)

                Form {
                    Section {
                        if entryType == .transfer {
                            SelectionRow(
                                title: "From Wallet",
                                iconName: selectedWallet?.icon,
                                iconColorHex: selectedWallet?.colorHex,
                                valueName: selectedWallet?.name
                            ) {
                                showingSourceWalletPicker = true
                            }
                            SelectionRow(
                                title: "To Wallet",
                                iconName: destinationWallet?.icon,
                                iconColorHex: destinationWallet?.colorHex,
                                valueName: destinationWallet?.name
                            ) {
                                showingDestinationWalletPicker = true
                            }
                        } else {
                            SelectionRow(
                                title: "Category",
                                iconName: selectedCategory?.customIcon ?? selectedCategory?.headCategory.icon,
                                iconColorHex: selectedCategory?.headCategory.colorHex,
                                valueName: selectedCategory?.name
                            ) {
                                showingCategoryPicker = true
                            }
                            SelectionRow(
                                title: "Wallet",
                                iconName: selectedWallet?.icon,
                                iconColorHex: selectedWallet?.colorHex,
                                valueName: selectedWallet?.name
                            ) {
                                showingSourceWalletPicker = true
                            }
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.05))

                    Section {
                        TextField("Note", text: $note)
                            .foregroundStyle(.white)
                    }
                    .listRowBackground(Color.white.opacity(0.05))

                    Section {
                        dateRow
                    }
                    .listRowBackground(Color.white.opacity(0.05))

                    Section {
                        Picker("Repeat", selection: $recurrence) {
                            Text("None").tag(RecurrenceRule.none)
                            Text("Weekly").tag(RecurrenceRule.weekly)
                            Text("Monthly").tag(RecurrenceRule.monthly)
                            Text("Yearly").tag(RecurrenceRule.yearly)
                        }
                        .tint(.white.opacity(0.7))
                    }
                    .listRowBackground(Color.white.opacity(0.05))

                    Section {
                        Toggle("Exclude from Budget", isOn: $excludeFromBudget)
                            .tint(.emerald)
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                }
                .scrollContentBackground(.hidden)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .foregroundStyle(.white)
            .navigationTitle(entry == nil ? "New Transaction" : "Edit Transaction")
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
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: loadInitialState)
        .onChange(of: entryType) { _, newValue in
            // Expense/income draw from disjoint category lists, and transfers have none at all.
            selectedCategory = nil
            if newValue != .transfer {
                destinationWallet = nil
            }
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(selection: $selectedCategory, isIncome: entryType == .income)
        }
        .sheet(isPresented: $showingSourceWalletPicker) {
            WalletPickerView(selection: $selectedWallet, excluding: destinationWallet)
        }
        .sheet(isPresented: $showingDestinationWalletPicker) {
            WalletPickerView(selection: $destinationWallet, excluding: selectedWallet)
        }
        .sheet(isPresented: $showingDatePicker) {
            DatePickerSheet(date: $date)
        }
        .task(id: note) {
            guard entryType != .transfer else { return }
            guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // Skip the fire-on-appear call when editing: the note hasn't actually changed yet.
            guard note != noteAtLoad else { return }

            // Debounce: restarts (cancelling the previous sleep) every time `note` changes.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }

            if let suggestion = await CategorizationService.suggestCategory(for: note) {
                selectedCategory = suggestion
            }
        }
    }

    private var amountField: some View {
        HStack(spacing: 4) {
            Text(Locale.current.currencySymbol ?? "$")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            TextField("0", text: $amountText)
                .keyboardType(.decimalPad)
                .font(.system(size: 52, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize()
                .focused($amountFieldFocused)
                .onChange(of: amountText) { _, newValue in
                    let filtered = newValue.filter { $0.isNumber || $0 == "." }
                    if filtered != newValue {
                        amountText = filtered
                    }
                }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var dateRow: some View {
        HStack {
            Button {
                date = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))

            Spacer()

            Button {
                showingDatePicker = true
            } label: {
                Text(dateLabel)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var dateLabel: String {
        if Calendar.current.isDateInToday(date) {
            return "Today"
        } else if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        } else if Calendar.current.isDateInTomorrow(date) {
            return "Tomorrow"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var amountValue: Decimal? {
        guard let value = Decimal(string: amountText), value > 0 else { return nil }
        return value
    }

    private var isValid: Bool {
        guard amountValue != nil, let selectedWallet else { return false }
        switch entryType {
        case .expense, .income:
            return selectedCategory != nil
        case .transfer:
            guard let destinationWallet else { return false }
            return destinationWallet !== selectedWallet
        }
    }

    private func loadInitialState() {
        guard !hasLoaded else { return }
        hasLoaded = true

        if let entry {
            amountText = "\(entry.amount)"
            entryType = entry.type
            selectedCategory = entry.category
            selectedWallet = entry.wallet
            destinationWallet = entry.destinationWallet
            note = entry.note
            noteAtLoad = entry.note
            date = entry.date
            recurrence = entry.recurrence
            excludeFromBudget = entry.excludeFromBudget
        } else {
            selectedWallet = initialWallet ?? wallets.first(where: \.isDefault) ?? wallets.first
            entryType = initialType
            date = initialDate
            amountFieldFocused = true
        }
    }

    private func save() {
        guard let amountValue, let selectedWallet, isValid else { return }

        if let entry {
            entry.amount = amountValue
            entry.date = date
            entry.note = note
            entry.type = entryType
            entry.category = entryType == .transfer ? nil : selectedCategory
            entry.wallet = selectedWallet
            entry.destinationWallet = entryType == .transfer ? destinationWallet : nil
            entry.recurrence = recurrence
            entry.excludeFromBudget = excludeFromBudget
        } else {
            let newEntry = Entry(
                amount: amountValue,
                date: date,
                note: note,
                type: entryType,
                category: entryType == .transfer ? nil : selectedCategory,
                wallet: selectedWallet,
                destinationWallet: entryType == .transfer ? destinationWallet : nil,
                recurrence: recurrence,
                excludeFromBudget: excludeFromBudget
            )
            modelContext.insert(newEntry)
        }
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

#Preview {
    AddTransactionView()
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
