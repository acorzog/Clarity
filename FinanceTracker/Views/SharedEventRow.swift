import SwiftUI

/// One row on the Shared home screen — mirrors the card language used by `WalletsView`'s rows.
struct SharedEventRow: View {
    let event: SharedEvent

    private var color: Color { event.colorHex.map { Color(hex: $0) } ?? .skyBlue }

    private var subtitle: String {
        let peopleCount = event.participants.count
        let expenseCount = event.expenses.count
        let people = peopleCount == 1 ? "1 person" : "\(peopleCount) people"
        let expensesText = expenseCount == 1 ? "1 expense" : "\(expenseCount) expenses"
        return "\(people) · \(expensesText)"
    }

    @ViewBuilder
    private var balanceLine: some View {
        if event.status == .completed {
            Label("Settled", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.emerald)
        } else {
            let net = event.outstandingNetBalance
            if net == 0 {
                Text("Settled")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
            } else if net > 0 {
                Text("You are owed \(net.currencyFormatted)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.emerald)
            } else {
                Text("You owe \((-net).currencyFormatted)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.expenseRed)
            }
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(color.opacity(0.18))
                Image(systemName: event.icon ?? "person.2.fill")
                    .foregroundStyle(color)
                    .font(.title3)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                balanceLine
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
    }
}
