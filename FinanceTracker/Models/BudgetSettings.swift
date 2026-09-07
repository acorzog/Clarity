import Foundation

/// SF Symbol choices offered in the Budget tab's Appearance icon picker.
enum BudgetIcon: String, CaseIterable, Identifiable, Codable {
    case house = "house.fill"
    case heart = "heart.fill"
    case people = "person.2.fill"
    case cash = "banknote.fill"
    case car = "car.fill"
    case trophy = "trophy.fill"

    var id: String { rawValue }
}

/// Persists customization + calculation preferences for the Budget tab ("Editing Budget" sheet).
final class BudgetSettingsStore: ObservableObject {
    static let shared = BudgetSettingsStore()

    @Published var name: String {
        didSet { defaults.set(name, forKey: Keys.name) }
    }
    @Published var icon: BudgetIcon {
        didSet { defaults.set(icon.rawValue, forKey: Keys.icon) }
    }
    /// Day of month (1-28) the budget period starts on for Remaining. 1 = ordinary calendar month.
    @Published var cycleStartDay: Int {
        didSet { defaults.set(cycleStartDay, forKey: Keys.cycleStartDay) }
    }
    /// Manual "Left to Spend" ceiling. Takes priority over income when > 0.
    @Published var manualMonthlyBudget: Decimal {
        didSet { defaults.set(NSDecimalNumber(decimal: manualMonthlyBudget).doubleValue, forKey: Keys.manualMonthlyBudget) }
    }
    @Published var includeUnplannedAsOtherExpenses: Bool {
        didSet { defaults.set(includeUnplannedAsOtherExpenses, forKey: Keys.includeUnplanned) }
    }
    @Published var includeSavingsTransfers: Bool {
        didSet { defaults.set(includeSavingsTransfers, forKey: Keys.includeSavings) }
    }
    @Published var includeDebtTransfers: Bool {
        didSet { defaults.set(includeDebtTransfers, forKey: Keys.includeDebt) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let name = "budgetName"
        static let icon = "budgetIcon"
        static let cycleStartDay = "budgetCycleStartDay"
        static let manualMonthlyBudget = "budgetManualMonthlyBudget"
        static let includeUnplanned = "budgetIncludeUnplanned"
        static let includeSavings = "budgetIncludeSavingsTransfers"
        static let includeDebt = "budgetIncludeDebtTransfers"
    }

    private init() {
        let defaults = UserDefaults.standard
        name = defaults.string(forKey: Keys.name) ?? "Budget"
        icon = BudgetIcon(rawValue: defaults.string(forKey: Keys.icon) ?? "") ?? .house

        let savedDay = defaults.object(forKey: Keys.cycleStartDay) as? Int ?? 1
        cycleStartDay = min(max(savedDay, 1), 28)

        manualMonthlyBudget = Decimal(defaults.double(forKey: Keys.manualMonthlyBudget))

        includeUnplannedAsOtherExpenses = defaults.object(forKey: Keys.includeUnplanned) as? Bool ?? true
        includeSavingsTransfers = defaults.object(forKey: Keys.includeSavings) as? Bool ?? false
        includeDebtTransfers = defaults.object(forKey: Keys.includeDebt) as? Bool ?? true
    }
}
