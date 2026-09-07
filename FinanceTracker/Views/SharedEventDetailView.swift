import SwiftUI
import SwiftData

/// A SharedEvent's full view — totals, expenses, participants, and the Settle entry point.
/// Everything here reads the shared domain only; nothing on this screen touches personal
/// Wallets/Budgets/Entries by itself (see CRITICAL rule in the shared-expenses spec).
struct SharedEventDetailView: View {
    let event: SharedEvent

    @Environment(\.modelContext) private var modelContext

    @State private var showingAddExpense = false
    @State private var editingExpense: SharedExpense?
    @State private var showingBalanceDetail = false
    @State private var showingSettle = false
    @State private var showingParticipantsPicker = false
    @State private var viewingTransaction: Entry?
    @State private var linkingSettlement: Settlement?

    private var net: Decimal { event.outstandingNetBalance }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if event.status == .completed {
                    Label("Settled", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.emerald)
                }

                totalsCard

                expensesSection

                participantsSection

                if !event.settlements.isEmpty {
                    settlementsSection
                }

                actionButtons
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .darkScreenBackground()
        .navigationTitle(event.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddExpense = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(LinearGradient.emeraldSky)
                }
            }
        }
        .sheet(isPresented: $showingAddExpense) {
            AddSharedExpenseView(event: event)
        }
        .sheet(item: $editingExpense) { expense in
            AddSharedExpenseView(event: event, expense: expense)
        }
        .sheet(isPresented: $showingSettle) {
            SettleView(event: event)
        }
        .sheet(isPresented: $showingParticipantsPicker) {
            SharedParticipantsPickerView(selection: participantsBinding)
        }
        .sheet(item: $viewingTransaction) { entry in
            AddTransactionView(entry: entry)
        }
        .sheet(item: $linkingSettlement) { settlement in
            AddSettlementTransactionView(settlement: settlement)
        }
        .navigationDestination(isPresented: $showingBalanceDetail) {
            SharedBalanceDetailView(event: event)
        }
    }

    /// Exposes the event's non-current-user participants as an editable binding for the
    /// participants picker, which never includes or removes "You".
    private var participantsBinding: Binding<[Person]> {
        Binding(
            get: { event.otherParticipants },
            set: { newValue in
                let you = event.currentUser
                event.participants = (you.map { [$0] } ?? []) + newValue
            }
        )
    }

    private var totalsCard: some View {
        VStack(spacing: 16) {
            HStack {
                totalItem(title: "Total", value: event.totalAmount)
                Spacer()
                totalItem(title: "Your Share", value: event.yourShare)
            }
            HStack {
                totalItem(title: "You Paid", value: event.youPaid)
                Spacer()
                totalItem(
                    title: net >= 0 ? "You Are Owed" : "You Owe",
                    value: abs(net),
                    color: net == 0 ? .white : (net > 0 ? Color.emerald : Color.expenseRed)
                )
            }

            Button {
                showingBalanceDetail = true
            } label: {
                Text("View Balance Details")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.skyBlue)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
    }

    private func totalItem(title: String, value: Decimal, color: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))
            Text(value.currencyFormatted)
                .font(.title3.bold())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var expensesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EXPENSES")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))

            if event.expenses.isEmpty {
                Text("No expenses yet.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                VStack(spacing: 0) {
                    ForEach(event.expenses.sorted { $0.date > $1.date }) { expense in
                        SwipeToDeleteRow(canDelete: true, onDelete: { modelContext.delete(expense) }) {
                            Button {
                                editingExpense = expense
                            } label: {
                                SharedExpenseRow(expense: expense)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PARTICIPANTS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button {
                    showingParticipantsPicker = true
                } label: {
                    Text("Edit")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.skyBlue)
                }
            }

            VStack(spacing: 0) {
                ForEach(event.participants, id: \.persistentModelID) { person in
                    HStack {
                        PersonAvatar(person: person)
                        Text(person.isCurrentUser ? "You" : person.displayName)
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private var settlementsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SETTLEMENTS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))

            VStack(spacing: 0) {
                ForEach(event.settlements.sorted { $0.date > $1.date }) { settlement in
                    settlementRow(settlement)
                        .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 16)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func settlementRow(_ settlement: Settlement) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(settlement.fromPerson?.displayName ?? "?") → \(settlement.toPerson?.displayName ?? "?")")
                    .foregroundStyle(.white)
                Spacer()
                Text(settlement.amount.currencyFormatted)
                    .foregroundStyle(.white.opacity(0.8))
            }

            if let transaction = settlement.transaction {
                Button {
                    viewingTransaction = transaction
                } label: {
                    Label("Recorded in Transactions", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.emerald)
                }
            } else {
                Button {
                    linkingSettlement = settlement
                } label: {
                    Label("Not recorded — Add to Transactions", systemImage: "circle.dashed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                showingSettle = true
            } label: {
                Text("Settle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .background(LinearGradient.emeraldSky, in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(.white)

            if event.status == .active, event.isFullySettled, !event.expenses.isEmpty {
                Button {
                    event.status = .completed
                    event.updatedAt = .now
                } label: {
                    Text("Close Event")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .foregroundStyle(.white.opacity(0.7))
            } else if event.status == .completed {
                Button {
                    event.status = .active
                    event.updatedAt = .now
                } label: {
                    Text("Reopen Event")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.top, 8)
    }
}
