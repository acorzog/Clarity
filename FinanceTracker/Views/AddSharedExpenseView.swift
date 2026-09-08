import SwiftUI
import SwiftData

/// Add/edit a SharedExpense inside a SharedEvent. This never touches the personal ledger —
/// no Entry, Wallet balance, or Budget is created here. The expense and its per-participant
/// shares live entirely inside the SharedEvent until an explicit Settlement says otherwise.
struct AddSharedExpenseView: View {
    let event: SharedEvent
    /// Pass an existing SharedExpense to edit it in place; nil creates a new one.
    var expense: SharedExpense?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var note = ""
    @State private var selectedCategory: Category?
    @State private var date = Date.now
    @State private var paidBy: Person?
    @State private var splitMethod: SharedSplitMethod = .equal
    @State private var selectedParticipants: Set<Person> = []
    @State private var partsByPerson: [Person: Int] = [:]
    @State private var exactAmountText: [Person: String] = [:]

    @State private var showingCategoryPicker = false
    @State private var showingPaidByPicker = false
    @State private var showingDatePicker = false
    @State private var showingDeleteAlert = false
    @State private var hasLoaded = false
    /// This device's resolved CloudKit identity for `event`, once known — resolved once (the
    /// same call `resolveDefaultPayerIfNeeded()` already makes) and reused for every "You" label
    /// on this screen, so nothing here calls `CKContainer.userRecordID()` more than once.
    @State private var currentUserRecordID: String?

    @FocusState private var amountFieldFocused: Bool

    private var isEditing: Bool { expense != nil }

    /// The candidate people for payer/participant selection. For a collaborative event this is
    /// sourced from `event.eventParticipants` (never `event.participants` directly, and never
    /// any global Person list — rule 25), filtered to active (non-removed) participants; for a
    /// local-only event it's the existing, unchanged `event.participants`. The underlying
    /// selection state below stays `Person`-keyed either way — only the list of *candidates*
    /// changes, since `SharedExpense.paidBy`/`SharedExpenseParticipant.person` are (deliberately,
    /// per the Phase 5 architecture) still local `Person` references; the CloudKit layer is what
    /// resolves identity through `EventParticipant`, not this local domain model.
    private var displayParticipants: [Person] {
        guard event.isCollaborationEnabled else { return event.participants }
        return event.eventParticipants.filter { !$0.isRemoved }.compactMap(\.person)
    }

    private var selectedParticipantsInOrder: [Person] {
        displayParticipants.filter { selectedParticipants.contains($0) }
    }

    private var amountValue: Decimal? {
        guard let value = Decimal(decimalInput: amountText), value > 0 else { return nil }
        return value
    }

    private var computedShares: [Person: Decimal] {
        guard let amountValue else { return [:] }
        let people = selectedParticipantsInOrder
        guard !people.isEmpty else { return [:] }

        switch splitMethod {
        case .equal:
            let shares = SharedSplitCalculator.equalSplit(total: amountValue, count: people.count)
            return Dictionary(uniqueKeysWithValues: zip(people, shares))
        case .byParts:
            let parts = people.map { partsByPerson[$0] ?? 1 }
            let shares = SharedSplitCalculator.partsSplit(total: amountValue, parts: parts)
            return Dictionary(uniqueKeysWithValues: zip(people, shares))
        case .exactAmounts:
            return Dictionary(uniqueKeysWithValues: people.map {
                ($0, Decimal(decimalInput: exactAmountText[$0] ?? "") ?? 0)
            })
        }
    }

    private var assignedTotal: Decimal {
        computedShares.values.reduce(0, +)
    }

    private var remaining: Decimal {
        (amountValue ?? 0) - assignedTotal
    }

    private var isValid: Bool {
        guard amountValue != nil, selectedCategory != nil, paidBy != nil,
              !selectedParticipantsInOrder.isEmpty else { return false }
        if splitMethod == .exactAmounts {
            return remaining == 0
        }
        return true
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                amountField

                Form {
                    Section {
                        SelectionRow(
                            title: "Category",
                            iconName: selectedCategory?.customIcon ?? selectedCategory?.headCategory.icon,
                            iconColorHex: selectedCategory?.headCategory.colorHex,
                            valueName: selectedCategory?.name
                        ) {
                            showingCategoryPicker = true
                        }

                        SelectionRow(
                            title: "Paid By",
                            iconName: nil,
                            iconColorHex: nil,
                            valueName: paidBy.map { displayName(for: $0) }
                        ) {
                            showingPaidByPicker = true
                        }

                        HStack {
                            Text("Description")
                                .foregroundStyle(.white)
                            Spacer()
                            TextField("Optional", text: $note)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.white.opacity(0.8))
                        }

                        dateRow
                    }
                    .listRowBackground(Color.white.opacity(0.05))

                    Section("Split") {
                        Picker("Split Method", selection: $splitMethod) {
                            Text("Equal").tag(SharedSplitMethod.equal)
                            Text("By Parts").tag(SharedSplitMethod.byParts)
                            Text("Exact").tag(SharedSplitMethod.exactAmounts)
                        }
                        .pickerStyle(.segmented)
                    }
                    .listRowBackground(Color.white.opacity(0.05))

                    Section {
                        ForEach(displayParticipants, id: \.persistentModelID) { person in
                            participantRow(person)
                        }
                    } header: {
                        Text("Participants")
                    } footer: {
                        if splitMethod == .exactAmounts {
                            HStack {
                                Text("Assigned: \(assignedTotal.currencyFormatted)")
                                Spacer()
                                Text("Remaining: \(remaining.currencyFormatted)")
                                    .foregroundStyle(remaining == 0 ? Color.emerald : Color.expenseRed)
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.05))

                    if isEditing {
                        Section {
                            Button(role: .destructive) {
                                showingDeleteAlert = true
                            } label: {
                                Text("Delete Expense")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .listRowBackground(Color.white.opacity(0.05))
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .foregroundStyle(.white)
            .navigationTitle(isEditing ? "Edit Expense" : "Add Expense")
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
        .task {
            await resolveDefaultPayerIfNeeded()
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(selection: $selectedCategory, isIncome: false)
        }
        .sheet(isPresented: $showingPaidByPicker) {
            SharedPersonPickerView(candidates: displayParticipants, selection: $paidBy, title: "Paid By", event: event, currentUserRecordID: currentUserRecordID)
        }
        .sheet(isPresented: $showingDatePicker) {
            DatePickerSheet(date: $date)
        }
        .alert("Delete this expense?", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let expense {
                    if event.isCollaborationEnabled {
                        CollaborationSyncService.shared?.queueDeletion(of: expense, from: event)
                    }
                    modelContext.delete(expense)
                }
                dismiss()
            }
        } message: {
            Text("This can't be undone.")
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
                    let filtered = newValue.sanitizedDecimalInput()
                    if filtered != newValue { amountText = filtered }
                }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var dateRow: some View {
        Button {
            showingDatePicker = true
        } label: {
            HStack {
                Text("Date")
                    .foregroundStyle(.white)
                Spacer()
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    @ViewBuilder
    private func participantRow(_ person: Person) -> some View {
        let isSelected = selectedParticipants.contains(person)
        HStack {
            Button {
                toggle(person)
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.emerald : .white.opacity(0.3))
            }
            .buttonStyle(.plain)

            PersonAvatar(person: person, size: 24)
            Text(displayName(for: person))
                .foregroundStyle(.white)

            Spacer()

            if isSelected {
                switch splitMethod {
                case .equal:
                    Text((computedShares[person] ?? 0).currencyFormatted)
                        .foregroundStyle(.white.opacity(0.6))
                case .byParts:
                    Stepper(
                        value: Binding(
                            get: { partsByPerson[person] ?? 1 },
                            set: { partsByPerson[person] = max(1, $0) }
                        ),
                        in: 1...20
                    ) {
                        Text("\(partsByPerson[person] ?? 1) · \((computedShares[person] ?? 0).currencyFormatted)")
                            .foregroundStyle(.white.opacity(0.6))
                            .font(.caption)
                    }
                    .fixedSize()
                case .exactAmounts:
                    TextField(
                        "0",
                        text: Binding(
                            get: { exactAmountText[person] ?? "" },
                            set: { exactAmountText[person] = $0.sanitizedDecimalInput() }
                        )
                    )
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.white)
                    .frame(width: 70)
                }
            }
        }
    }

    private func toggle(_ person: Person) {
        if selectedParticipants.contains(person) {
            selectedParticipants.remove(person)
        } else {
            selectedParticipants.insert(person)
        }
    }

    private func loadInitialState() {
        guard !hasLoaded else { return }
        hasLoaded = true

        if event.isCollaborationEnabled {
            // Guarantees event.eventParticipants is populated before displayParticipants (and
            // the pickers/default-selection below) ever read it — see that property's doc.
            CollaborationSyncService.shared?.ensureEventParticipants(for: event)
        }

        if let expense {
            amountText = "\(expense.amount)"
            note = expense.note
            selectedCategory = expense.category
            date = expense.date
            paidBy = expense.paidBy
            splitMethod = expense.splitMethod
            for participant in expense.participants {
                guard let person = participant.person else { continue }
                selectedParticipants.insert(person)
                if let parts = participant.parts {
                    partsByPerson[person] = parts
                }
                exactAmountText[person] = participant.amount.editableText()
            }
        } else {
            selectedParticipants = Set(displayParticipants)
            // A reasonable synchronous first guess; resolveDefaultPayerIfNeeded() overrides this
            // with the event-scoped identity for a collaborative event once it resolves (rule 3).
            paidBy = event.currentUser
            amountFieldFocused = true
        }
    }

    /// For a NEW collaborative expense, overrides the synchronous `event.currentUser` guess above
    /// with the authoritative event-scoped default payer once the current CloudKit identity
    /// resolves (rule 3: never `Person.isCurrentUser` as the collaborative source of truth). A
    /// no-op for a local-only event, an edit, or when this device hasn't identified itself in
    /// this event yet — in every one of those cases the existing behavior/selection stands.
    private func resolveDefaultPayerIfNeeded() async {
        guard event.isCollaborationEnabled, let service = CollaborationSyncService.shared else { return }
        guard let userRecordID = await service.currentUserRecordID() else { return }
        // Resolved once here and reused for every "You" label on this screen (below), whether
        // this is a new expense or an edit — only the default-payer override is new-expense-only.
        currentUserRecordID = userRecordID
        guard !isEditing, let identifiedPerson = event.currentParticipant(for: userRecordID)?.person else { return }
        paidBy = identifiedPerson
    }

    private func displayName(for person: Person) -> String {
        event.displayName(for: person, currentUserRecordID: currentUserRecordID)
    }

    private func save() {
        guard let amountValue, let selectedCategory, let paidBy, isValid else { return }
        let shares = computedShares

        let targetExpense: SharedExpense
        // Captured before the old SharedExpenseParticipant rows are deleted below: this existing
        // flow always deletes and recreates every share on an edit (even unchanged ones), which
        // mints fresh remoteIDs for the recreated rows — without explicitly queuing the OLD ones
        // for CloudKit deletion, their previous CKRecords would be orphaned as stale shares on
        // the server rather than replaced (rule 13).
        var obsoleteParticipantRemoteIDs: [UUID] = []
        if let expense {
            obsoleteParticipantRemoteIDs = expense.participants.compactMap(\.remoteID)
            for participant in expense.participants {
                modelContext.delete(participant)
            }
            expense.amount = amountValue
            expense.note = note
            expense.date = date
            expense.category = selectedCategory
            expense.paidBy = paidBy
            expense.splitMethod = splitMethod
            expense.updatedAt = .now
            targetExpense = expense
        } else {
            let newExpense = SharedExpense(
                amount: amountValue,
                currency: Locale.current.currency?.identifier ?? "USD",
                note: note,
                date: date,
                category: selectedCategory,
                paidBy: paidBy,
                splitMethod: splitMethod,
                event: event
            )
            modelContext.insert(newExpense)
            event.expenses.append(newExpense)
            targetExpense = newExpense
        }

        for person in selectedParticipantsInOrder {
            let participant = SharedExpenseParticipant(
                person: person,
                amount: shares[person] ?? 0,
                parts: splitMethod == .byParts ? (partsByPerson[person] ?? 1) : nil,
                expense: targetExpense
            )
            modelContext.insert(participant)
            targetExpense.participants.append(participant)
        }

        event.updatedAt = .now

        if event.isCollaborationEnabled, let service = CollaborationSyncService.shared {
            service.queueRemovalOfExpenseParticipants(obsoleteParticipantRemoteIDs, for: event)
            service.queueUpload(of: event)
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
