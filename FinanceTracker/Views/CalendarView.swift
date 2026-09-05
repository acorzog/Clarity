import SwiftUI
import SwiftData

struct CalendarView: View {
    let month: Date

    @Query(sort: \Entry.date) private var allEntries: [Entry]
    @State private var selectedDay: DaySelection?

    private var monthEntries: [Entry] {
        allEntries.inMonth(month)
    }

    /// Net per day (income − expense; transfers are internal movement and don't count),
    /// keyed by start-of-day — matches the keys produced by `monthGrid`.
    private var dailyTotals: [Date: Decimal] {
        var totals: [Date: Decimal] = [:]
        for entry in monthEntries {
            let day = Calendar.current.startOfDay(for: entry.date)
            let delta: Decimal
            switch entry.type {
            case .income: delta = entry.amount
            case .expense: delta = -entry.amount
            case .transfer: delta = 0
            }
            totals[day, default: 0] += delta
        }
        return totals
    }

    private var entriesByDay: [Date: [Entry]] {
        Dictionary(grouping: monthEntries) { Calendar.current.startOfDay(for: $0.date) }
    }

    /// Largest single-day magnitude this month, used to scale tint intensity so a bigger
    /// income/spend day reads visibly stronger than a small one.
    private var maxMagnitude: Decimal {
        dailyTotals.values.map { abs($0) }.max() ?? 0
    }

    private var weeks: [[Date?]] {
        monthGrid(for: month).chunked(into: 7)
    }

    var body: some View {
        VStack(spacing: 16) {
            weekdayHeader

            VStack(spacing: 6) {
                ForEach(weeks.indices, id: \.self) { weekIndex in
                    HStack(spacing: 6) {
                        ForEach(weeks[weekIndex].indices, id: \.self) { dayIndex in
                            DayCell(
                                day: weeks[weekIndex][dayIndex],
                                net: weeks[weekIndex][dayIndex].flatMap { dailyTotals[$0] },
                                intensity: intensity(for: weeks[weekIndex][dayIndex]),
                                isToday: weeks[weekIndex][dayIndex].map { Calendar.current.isDateInToday($0) } ?? false
                            ) { day in
                                selectedDay = DaySelection(date: day)
                            }
                        }
                    }
                }
            }

            legend
        }
        .sheet(item: $selectedDay) { selection in
            DayEntriesView(day: selection.date, entries: entriesByDay[selection.date] ?? [])
        }
    }

    private func intensity(for day: Date?) -> Double {
        guard let day, let net = dailyTotals[day], maxMagnitude > 0 else { return 0 }
        return min((abs(net) / maxMagnitude).doubleValue, 1)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 6) {
            ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) { label in
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 18) {
            legendItem(color: .emerald, label: "Net income")
            legendItem(color: .expenseRed, label: "Net spend")
            legendItem(color: Color.white.opacity(0.15), label: "No activity")
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    /// Monday-first grid for the given month, padded with nil leading/trailing cells so
    /// full weeks line up under the Mon–Sun header.
    private func monthGrid(for month: Date) -> [Date?] {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday

        guard let monthInterval = calendar.dateInterval(of: .month, for: month) else { return [] }

        let weekdayOfFirst = calendar.component(.weekday, from: monthInterval.start) // 1=Sun...7=Sat
        let mondayIndex = (weekdayOfFirst + 5) % 7 // 0=Mon...6=Sun

        var days: [Date?] = Array(repeating: nil, count: mondayIndex)

        var current = monthInterval.start
        while current < monthInterval.end {
            days.append(current)
            current = calendar.date(byAdding: .day, value: 1, to: current) ?? monthInterval.end
        }

        while days.count % 7 != 0 {
            days.append(nil)
        }

        return days
    }
}

private struct DaySelection: Identifiable {
    let date: Date
    var id: Date { date }
}

private struct DayCell: View {
    let day: Date?
    let net: Decimal?
    let intensity: Double
    let isToday: Bool
    let onTap: (Date) -> Void

    var body: some View {
        if let day {
            Button {
                onTap(day)
            } label: {
                VStack(spacing: 4) {
                    Text("\(Calendar.current.component(.day, from: day))")
                        .font(.system(size: 14, weight: isToday ? .bold : .medium))
                        .foregroundStyle(.white)

                    if let net, net != 0 {
                        Text(compactAmount(net))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(net > 0 ? Color.emerald : Color.expenseRed)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    } else {
                        Text(" ").font(.system(size: 9))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    if isToday {
                        RoundedRectangle(cornerRadius: 10).stroke(Color.skyBlue, lineWidth: 1.5)
                    }
                }
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(maxWidth: .infinity).frame(height: 52)
        }
    }

    private var backgroundColor: Color {
        guard let net, net != 0 else { return Color.white.opacity(0.05) }
        let opacity = 0.12 + 0.28 * intensity
        return net > 0 ? Color.emerald.opacity(opacity) : Color.expenseRed.opacity(opacity)
    }

    private func compactAmount(_ value: Decimal) -> String {
        let rounded = value.doubleValue
        let sign = rounded > 0 ? "+" : ""
        if abs(rounded) >= 1000 {
            return String(format: "%@%.1fK", sign, rounded / 1000)
        }
        return String(format: "%@%.0f", sign, rounded)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
