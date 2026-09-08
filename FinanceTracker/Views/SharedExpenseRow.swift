import SwiftUI

/// One row in a SharedEvent's expense list — reuses `CategoryIconView` since shared expenses
/// draw from the same Category catalog as personal transactions.
struct SharedExpenseRow: View {
    let expense: SharedExpense
    /// This device's resolved CloudKit identity for the containing event, if known — supplied by
    /// the parent (`SharedEventDetailView`, already resolved once via its own identity check).
    /// Never resolved here: this view must not call `CKContainer.userRecordID()` itself, on this
    /// or any other render. `nil` for a local-only event, or before identity has resolved yet.
    var currentUserRecordID: String? = nil

    private var title: String {
        !expense.note.isEmpty ? expense.note : (expense.category?.name ?? expense.remoteCategoryName ?? "Expense")
    }

    private var subtitle: String {
        let payer = expense.paidBy.map { payerDisplayName(for: $0) } ?? "?"
        let count = expense.participants.count
        return "Paid by \(payer) · \(count) \(count == 1 ? "person" : "people")"
    }

    private func payerDisplayName(for person: Person) -> String {
        expense.event?.displayName(for: person, currentUserRecordID: currentUserRecordID) ?? person.displayName
    }

    var body: some View {
        HStack(spacing: 12) {
            if let category = expense.category {
                CategoryIconView(category: category, size: 34)
            } else if let remoteIcon = expense.remoteCategoryIcon {
                // A snapshot from whoever created this expense — never resolved back to this
                // device's own Category table (see SharedExpense.remoteCategoryName's doc).
                Image(systemName: remoteIcon)
                    .font(.callout)
                    .foregroundStyle(expense.remoteCategoryColorHex.map { Color(hex: $0) } ?? .white)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.15), in: Circle())
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
