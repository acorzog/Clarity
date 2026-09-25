import Foundation

/// Pure, value-type mirror of the calculation-relevant fields of `BudgetSettingsStore`.
///
/// The calculation layer (`BudgetCalculator`) depends on this type, never on the live
/// `BudgetSettingsStore` singleton directly, so it stays usable from the widget extension, unit
/// tests, and any future background/Intelligence Engine context without needing `UserDefaults`,
/// `ObservableObject`, or a SwiftUI environment. Bridging from the live store happens only at the
/// app/widget call site, via `init(from:)`.
struct BudgetCalculationSettings: Equatable {
    /// Day of month (1-28) the budget period starts on. 1 = an ordinary calendar month.
    var cycleStartDay: Int
    /// Manual "Left to Spend" ceiling. Takes priority over income when > 0.
    var manualMonthlyBudget: Decimal
    var includeUnplannedAsOtherExpenses: Bool
    var includeSavingsTransfers: Bool
    var includeDebtTransfers: Bool

    init(
        cycleStartDay: Int,
        manualMonthlyBudget: Decimal,
        includeUnplannedAsOtherExpenses: Bool,
        includeSavingsTransfers: Bool,
        includeDebtTransfers: Bool
    ) {
        self.cycleStartDay = cycleStartDay
        self.manualMonthlyBudget = manualMonthlyBudget
        self.includeUnplannedAsOtherExpenses = includeUnplannedAsOtherExpenses
        self.includeSavingsTransfers = includeSavingsTransfers
        self.includeDebtTransfers = includeDebtTransfers
    }

    /// The one bridging point to the live, `UserDefaults`-backed store — app/widget call sites
    /// only. The calculation layer itself never references `BudgetSettingsStore`.
    init(from store: BudgetSettingsStore) {
        self.init(
            cycleStartDay: store.cycleStartDay,
            manualMonthlyBudget: store.manualMonthlyBudget,
            includeUnplannedAsOtherExpenses: store.includeUnplannedAsOtherExpenses,
            includeSavingsTransfers: store.includeSavingsTransfers,
            includeDebtTransfers: store.includeDebtTransfers
        )
    }
}
