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
}
