import Foundation

extension Date {
    var monthYearComponents: (month: Int, year: Int) {
        let components = Calendar.current.dateComponents([.month, .year], from: self)
        return (components.month ?? 1, components.year ?? 2000)
    }
}

extension Array where Element == Budget {
    func budget(for category: Category, month: Date) -> Budget? {
        let (targetMonth, targetYear) = month.monthYearComponents
        return first { $0.category === category && $0.month == targetMonth && $0.year == targetYear }
    }

    /// The effective planned amount for `category` in `month`: this month's own entry if one
    /// exists, otherwise inherited from the closest *earlier* month's entry IF that one was
    /// marked `isFixed` — carrying a fixed expense (rent, a subscription) forward automatically
    /// so it doesn't need re-entering every month. It's specifically the closest earlier entry's
    /// own setting that decides this, not merely "the closest Fixed one somewhere further back":
    /// an explicit Variable entry stops an older Fixed one from reaching any further forward, the
    /// same way setting an amount at all already overrides whatever came before it. With no entry
    /// of any kind, the amount is 0 — unchanged from before `isFixed` existed. Used everywhere a
    /// planned amount is read (Plan/Allocate, `BudgetCalculator`'s totals, Insights) so they can
    /// never disagree about which months a fixed amount applies to.
    func amount(for category: Category, month: Date) -> Decimal {
        if let existing = budget(for: category, month: month) {
            return existing.monthlyLimit
        }
        guard let previous = mostRecentBudget(for: category, before: month), previous.isFixed else { return 0 }
        return previous.monthlyLimit
    }

    /// The closest earlier month's `Budget` for `category`, regardless of its own Fixed/Variable
    /// setting — read-only fallback for `amount(for:month:)`/`isFixed(for:month:)`, which each
    /// decide separately whether its value actually carries forward. Never used for the row an
    /// edit actually mutates, which always targets `month` exactly via `budget(for:month:)`.
    private func mostRecentBudget(for category: Category, before month: Date) -> Budget? {
        let (targetMonth, targetYear) = month.monthYearComponents
        let targetOrdinal = targetYear * 12 + targetMonth
        return filter { $0.category === category && ($0.year * 12 + $0.month) < targetOrdinal }
            .max { ($0.year * 12 + $0.month) < ($1.year * 12 + $1.month) }
    }

    func isHidden(for category: Category, month: Date) -> Bool {
        budget(for: category, month: month)?.isHidden ?? false
    }

    /// Whether `category` is currently configured as Fixed — this month's own entry if one
    /// exists, otherwise inherited from the same closest-earlier-entry `amount(for:month:)` would
    /// use, so the two never disagree about "is this month's shown amount a fixed one."
    func isFixed(for category: Category, month: Date) -> Bool {
        if let existing = budget(for: category, month: month) {
            return existing.isFixed
        }
        return mostRecentBudget(for: category, before: month)?.isFixed ?? false
    }
}
