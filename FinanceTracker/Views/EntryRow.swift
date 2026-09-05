import SwiftUI

struct EntryRow: View {
    let entry: Entry

    var body: some View {
        HStack(spacing: 12) {
            leadingIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.white)
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(amountText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(amountColor)
        }
    }

    private var title: String {
        switch entry.type {
        case .expense, .income:
            return entry.category?.name ?? "Uncategorized"
        case .transfer:
            return "\(entry.wallet.name) → \(entry.destinationWallet?.name ?? "?")"
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if entry.type != .transfer, let category = entry.category {
            CategoryIconView(category: category, size: 34)
        } else {
            let color: Color = entry.type == .transfer ? .skyBlue : .white
            let icon = entry.type == .transfer ? "arrow.left.arrow.right" : "questionmark.circle"
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.15), in: Circle())
        }
    }

    private var amountText: String {
        switch entry.type {
        case .expense: return "-" + entry.amount.currencyFormatted
        case .income: return "+" + entry.amount.currencyFormatted
        case .transfer: return entry.amount.currencyFormatted
        }
    }

    private var amountColor: Color {
        switch entry.type {
        case .expense: return .expenseRed
        case .income: return .emerald
        case .transfer: return .white.opacity(0.7)
        }
    }
}
