import SwiftUI

/// One row in a SharedEvent's expense list — reuses `CategoryIconView` since shared expenses
/// draw from the same Category catalog as personal transactions.
struct SharedExpenseRow: View {
    let expense: SharedExpense

    private var title: String {
        !expense.note.isEmpty ? expense.note : (expense.category?.name ?? "Expense")
    }

    private var subtitle: String {
        let payer = expense.paidBy.map { $0.isCurrentUser ? "You" : $0.displayName } ?? "?"
        let count = expense.participants.count
        return "Paid by \(payer) · \(count) \(count == 1 ? "person" : "people")"
    }

    var body: some View {
        HStack(spacing: 12) {
            if let category = expense.category {
                CategoryIconView(category: category, size: 34)
            } else {
                Image(systemName: "questionmark.circle")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.15), in: Circle())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            Text(expense.amount.currencyFormatted)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
    }
}
