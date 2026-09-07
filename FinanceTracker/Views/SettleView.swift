import SwiftUI

/// Entry point into the shared↔personal bridge. Shows the calculated balance and lets the
/// user pick a participant to settle with — recording the payment is handled by
/// `RecordPaymentView`, which is the only place a personal Transaction can be created from here.
struct SettleView: View {
    let event: SharedEvent

    @Environment(\.dismiss) private var dismiss
    @State private var settlingWith: Person?

    private var net: Decimal { event.outstandingNetBalance }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 6) {
                        Text("Your current shared balance")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                        Text(net == 0 ? "Settled" : net.currencyFormatted)
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(net == 0 ? .white : (net > 0 ? Color.emerald : Color.expenseRed))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .listRowBackground(Color.clear)

                if event.balances.contains(where: { $0.amount != 0 }) {
                    Section("Settle With") {
                        ForEach(event.balances.filter { $0.amount != 0 }) { balance in
                            Button {
                                settlingWith = balance.person
                            } label: {
                                HStack {
                                    PersonAvatar(person: balance.person)
                                    Text(balance.person.displayName)
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Text(balance.amount > 0 ? "Owes you \(balance.amount.currencyFormatted)" : "You owe \((-balance.amount).currencyFormatted)")
                                        .foregroundStyle(balance.amount > 0 ? Color.emerald : Color.expenseRed)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.3))
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                } else {
                    Section {
                        Text("Everyone is settled up.")
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Settle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $settlingWith) { person in
            RecordPaymentView(event: event, person: person)
        }
    }
}
