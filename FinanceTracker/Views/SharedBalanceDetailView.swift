import SwiftUI

/// Per-participant breakdown behind "View Balance" — the detailed accounting that section 16
/// of the spec keeps off the main SharedEvent screen in favor of plain-language summaries.
struct SharedBalanceDetailView: View {
    let event: SharedEvent

    private var net: Decimal { event.outstandingNetBalance }

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    Text(headline)
                        .font(.title2.bold())
                        .foregroundStyle(net == 0 ? .white : (net > 0 ? Color.emerald : Color.expenseRed))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .listRowBackground(Color.clear)

            Section("By Person") {
                ForEach(event.balances) { balance in
                    HStack {
                        PersonAvatar(person: balance.person)
                        Text(balance.person.displayName)
                            .foregroundStyle(.white)
                        Spacer()
                        Text(personLine(for: balance.amount))
                            .foregroundStyle(balance.amount == 0 ? .white.opacity(0.5) : (balance.amount > 0 ? Color.emerald : Color.expenseRed))
                    }
                }
            }
            .listRowBackground(Color.white.opacity(0.05))
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Balance")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    private var headline: String {
        if net == 0 { return "All settled up" }
        return net > 0 ? "You are owed \(net.currencyFormatted)" : "You owe \((-net).currencyFormatted)"
    }

    private func personLine(for amount: Decimal) -> String {
        if amount == 0 { return "Settled" }
        return amount > 0 ? "\(amount.currencyFormatted) owed" : "\((-amount).currencyFormatted) owed by you"
    }
}
