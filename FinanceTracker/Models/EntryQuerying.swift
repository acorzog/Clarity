import Foundation

extension Entry {
    func isIn(month: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(date, equalTo: month, toGranularity: .month)
    }
}

extension Array where Element == Entry {
    func inMonth(_ month: Date, calendar: Calendar = .current) -> [Entry] {
        filter { $0.isIn(month: month, calendar: calendar) }
    }

    /// Entries falling within the budget cycle (anchored on `month`) that starts on `startDay`
    /// of each month. `startDay` of 1 behaves exactly like `inMonth`.
    func inBudgetPeriod(_ month: Date, startDay: Int, calendar: Calendar = .current) -> [Entry] {
        let period = month.budgetPeriod(startDay: startDay, calendar: calendar)
        return filter { period.contains($0.date) }
    }

    var totalIncome: Decimal {
        filter { $0.type == .income }.reduce(Decimal(0)) { $0 + $1.amount }
    }

    var totalExpenses: Decimal {
        filter { $0.type == .expense }.reduce(Decimal(0)) { $0 + $1.amount }
    }
}

extension Date {
    static func startOfMonth(for date: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? date
    }

    /// The date interval of the budget cycle containing `self`, for a cycle that starts on
    /// `startDay` of each month (1 = an ordinary calendar month).
    func budgetPeriod(startDay: Int, calendar: Calendar = .current) -> DateInterval {
        guard startDay > 1 else {
            return calendar.dateInterval(of: .month, for: self) ?? DateInterval(start: self, duration: 0)
        }

        var components = calendar.dateComponents([.year, .month, .day], from: self)
        if let day = components.day, day < startDay {
            components.month = (components.month ?? 1) - 1
        }
        components.day = startDay

        let start = calendar.date(from: components) ?? self
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? self
        return DateInterval(start: start, end: end)
    }
}
