import Foundation

/// Whether an `Entry` counts toward budget/spending analysis — the single gate every
/// budget-related calculation (Remaining, Insights, Spending Breakdown, the budget widget, and
/// Overview's analytical summaries) applies before summing amounts.
///
/// `excludeFromBudget` never affects `Wallet.balance`, Net Worth, Activity/transaction history,
/// or CSV export — those read every `Entry` unconditionally by design (see `Wallet.effect(of:)`,
/// `CSVExporter.makeCSV`). This filter exists specifically for budget/spending analysis, and
/// nowhere else.
///
/// Applied symmetrically to both expense and income entries: an excluded income entry (e.g. a
/// positive wallet balance-adjustment — see `WalletEditorView.save()`) must not inflate
/// budget-eligible income any more than an excluded expense entry should inflate budget-eligible
/// spending.
extension Entry {
    var isBudgetEligible: Bool {
        !excludeFromBudget
    }
}

extension Array where Element == Entry {
    /// This array restricted to budget-eligible entries. Apply before any budget/spending
    /// aggregation; never apply before computing a wallet balance, Net Worth, an Activity list,
    /// or a CSV export.
    var budgetEligible: [Entry] {
        filter(\.isBudgetEligible)
    }
}
