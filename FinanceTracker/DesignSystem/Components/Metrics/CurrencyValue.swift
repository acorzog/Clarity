import SwiftUI

/// Which side of the ledger an amount is on — purely a presentation hint (sign + color), never
/// a recomputation of `Entry.type`. See `CLARITY_DESIGN_SYSTEM.md` §13.
enum CurrencyValueKind {
    case income
    case expense
    case transfer
    case neutral

    var color: Color {
        switch self {
        case .income: .income
        case .expense: .expense
        case .transfer: .transfer
        case .neutral: .textPrimary
        }
    }

    var sign: String {
        switch self {
        case .income: "+"
        case .expense: "−"
        case .transfer, .neutral: ""
        }
    }
}

/// A formatted, semantically-colored, signed currency amount — formalizes `EntryRow.
/// amountText`/`.amountColor`'s existing, correct logic (`Views/EntryRow.swift`) as a reusable
/// component instead of a per-screen switch statement.
///
/// Presentation-only: takes an already-formatted string (from `Decimal.currencyFormatted`/
/// `.currencyFormattedSummary`, `Theme.swift`) and a `CurrencyValueKind` the caller already
/// knows from its own `Entry.type` — this view never touches `Entry`, `Wallet`, or
/// `BudgetCalculator` itself.
///
/// Per the design system's color-independence rule (§20/§21), the sign (`+`/`−`) is always
/// shown alongside the color — color is never the only signal.
struct CurrencyValue: View {
    let amount: String
    let kind: CurrencyValueKind
    var font: Font = .body

    var body: some View {
        Text(kind.sign + amount)
            .font(font)
            .foregroundStyle(kind.color)
            .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        switch kind {
        case .income: "Income \(amount)"
        case .expense: "Expense \(amount)"
        case .transfer: "Transfer \(amount)"
        case .neutral: amount
        }
    }
}

/// A balance amount, colored by sign only (no +/- prefix — matches `WalletsView.WalletRow`'s
/// existing convention, where a raw account balance is shown as-is, not as a transaction delta).
struct BalanceIndicator: View {
    let amount: String
    let isNegative: Bool
    var font: Font = .heroAmount

    var body: some View {
        Text(amount)
            .font(font)
            .foregroundStyle(isNegative ? Color.expense : Color.textPrimary)
            .minimumScaleFactor(0.7)
            .lineLimit(1)
    }
}
