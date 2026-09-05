import SwiftUI

/// A transaction row shown from a specific wallet's point of view — the amount and its
/// color reflect that wallet's `effect(of:)`, so a transfer reads as "+" when this wallet
/// is the destination and "-" when it's the source, unlike the type-centric `EntryRow`.
struct WalletTransactionRow: View {
    let entry: Entry
    let wallet: Wallet
    var runningBalance: Decimal?

    private var effect: Decimal { wallet.effect(of: entry) }

    private var title: String {
        switch entry.type {
        case .expense, .income:
            return entry.category?.name ?? "Uncategorized"
        case .transfer:
            return entry.wallet === wallet
                ? "To \(entry.destinationWallet?.name ?? "?")"
                : "From \(entry.wallet.name)"
        }
    }

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

            VStack(alignment: .trailing, spacing: 2) {
                Text(effect.currencyFormatted)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(effect >= 0 ? Color.emerald : Color.expenseRed)
                if let runningBalance {
                    Text(runningBalance.currencyFormatted)
                        .font(.caption2)
                        .foregroundStyle(runningBalance < 0 ? Color.expenseRed.opacity(0.8) : .white.opacity(0.4))
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if entry.type != .transfer, let category = entry.category {
            CategoryIconView(category: category, size: 34)
        } else {
            Image(systemName: "arrow.left.arrow.right")
                .font(.callout)
                .foregroundStyle(Color.skyBlue)
                .frame(width: 34, height: 34)
                .background(Color.skyBlue.opacity(0.15), in: Circle())
        }
    }
}
