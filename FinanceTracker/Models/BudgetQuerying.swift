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

    func amount(for category: Category, month: Date) -> Decimal {
        budget(for: category, month: month)?.monthlyLimit ?? 0
    }

    func isHidden(for category: Category, month: Date) -> Bool {
        budget(for: category, month: month)?.isHidden ?? false
    }
}
