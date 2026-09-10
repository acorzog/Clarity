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

extension CalendarView {
    /// Combined VoiceOver label for one day cell — date + financial meaning, never relying on
    /// color. `net == nil` means no entries at all that day; `net == 0` (non-nil) means entries
    /// existed (e.g. a transfer-only day, or income/expense that canceled out exactly) but their
    /// net is zero. These two cases render visually identically today (the known, deliberately
    /// deferred zero-net-day finding — `CLARITY_OVERVIEW_ACTIVITY_UX_SPEC.md` §8/§13) but must
    /// read differently to a VoiceOver user, which this label already has enough information to
    /// do without any new calculation.
    static func dayAccessibilityLabel(for day: Date, net: Decimal?, calendar: Calendar = .current) -> String {
        let dateText = day.formatted(.dateTime.month(.wide).day())
        guard let net else { return "\(dateText), no activity" }
        if net == 0 { return "\(dateText), activity, net zero" }
        if net > 0 { return "\(dateText), net income \(net.currencyFormatted)" }
        return "\(dateText), net expense \(abs(net).currencyFormatted)"
    }

    /// Whether a day had transactions that netted to exactly zero (offsetting income/expense, or
    /// a transfer-only day) — as opposed to no transactions at all. Both cases pass `net != 0 ==
    /// false` and previously rendered visually identically (blank cell); this distinguishes them
    /// so a small, non-color-only indicator (`DayCell`) can show "something happened here" without
    /// implying an amount. Pure passthrough of the same `net` the cell already has — no new
    /// calculation, no change to `dailyTotals`.
    static func hasOffsettingActivity(net: Decimal?) -> Bool {
        net == 0
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
                        .font(.caption.weight(isToday ? .bold : .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if let net, net != 0 {
                        Text(compactAmount(net))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(net > 0 ? Color.emerald : Color.expenseRed)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    } else if CalendarView.hasOffsettingActivity(net: net) {
                        // Distinguishes "transactions occurred but netted to zero" from "no
                        // activity" — both previously rendered as an identical blank cell. A
                        // shape/presence cue (not a color), matching this file's "no fake data,
                        // no color-only meaning" convention; see `hasOffsettingActivity`'s doc.
                        Circle()
                            .fill(Color.white.opacity(0.35))
                            .frame(width: 4, height: 4)
                    } else {
                        Text(" ").font(.footnote)
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
            // Caps Dynamic Type scaling for this fixed-height grid cell at the largest
            // non-accessibility size — real Dynamic Type support through the normal range,
            // without letting an accessibility text size (AX1-AX5) overflow a 52pt cell that
            // this phase is explicitly not redesigning. See `CLARITY_OVERVIEW_ACTIVITY_UX_SPEC.md`
            // §14/§16.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(CalendarView.dayAccessibilityLabel(for: day, net: net))
            .accessibilityHint("Double tap to view this day's transactions")
        } else {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .accessibilityHidden(true)
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
