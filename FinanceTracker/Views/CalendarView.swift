import SwiftUI
import SwiftData

/// Clarity's "Money Calendar" — a month grid focused on daily spending, with income still visible
/// on a day that had it: spending is always the primary read for a day (its own red tint and
/// figure) since that's what this card exists to surface, but a day with income and no spending
/// gets its own emerald tint and figure instead of reading as blank/no-activity, and a day with
/// both keeps its spending figure with a small emerald dot marking that income happened too.
/// Tapping a day sets it as the persistent selection (shown via `selectionSummary` and a distinct
/// highlight even after the detail sheet closes) and opens `DayEntriesView` for that day's full
/// transaction list. Reuses `EntryQuerying`'s `.inMonth`/`.budgetEligible`/`.totalExpenses`/
/// `.totalIncome` exactly as every other spending/income calculation in the app does — this view
/// derives no financial rule of its own, and month navigation is inherited from whatever
/// `MonthSelector` already drives `month` (see `OverviewView`), not duplicated here.
struct CalendarView: View {
    let month: Date

    @Query(sort: \Entry.date) private var allEntries: [Entry]
    @State private var selectedDay: Date?
    @State private var showingDayDetail = false

    init(month: Date) {
        self.month = month
        // Defaults to today when the displayed month is the current one, so the calendar opens
        // with something meaningful already selected and today/selected have something to
        // visually agree on; a past/future month starts with nothing selected rather than
        // defaulting to an unrelated day.
        _selectedDay = State(initialValue: Self.defaultSelectedDay(for: month))
    }

    /// Same rule `init` uses, factored out so `onChange(of: month)` below can re-apply it without
    /// duplicating the logic. `CalendarView`'s caller (`CalendarCard`) re-renders this same view
    /// instance with a new `month` on every month-navigation tap rather than constructing a fresh
    /// one — `@State` set in `init` only runs once per view identity, so without this, `selectedDay`
    /// would silently keep pointing at a day from whatever month was displayed when the user first
    /// tapped one, disagreeing with the now-different month grid underneath `selectionSummary`.
    private static func defaultSelectedDay(for month: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: .now)
        let isCurrentMonth = calendar.isDate(today, equalTo: month, toGranularity: .month)
        return isCurrentMonth ? today : nil
    }

    private var monthEntries: [Entry] { allEntries.inMonth(month) }

    /// Total budget-eligible expenses per day, keyed by start-of-day — matches the keys produced
    /// by `monthGrid`. A day with no (budget-eligible) expenses is simply absent from this
    /// dictionary — including a day that only had income or transfers — rather than stored as
    /// zero, so "no spending" stays a single, unambiguous case throughout this view. Excluded
    /// entries (`excludeFromBudget`) never count here, matching every other spending total in the
    /// app (`Models/BudgetEligibility.swift`).
    private var dailySpending: [Date: Decimal] {
        Dictionary(grouping: monthEntries.budgetEligible.filter { $0.type == .expense }) {
            Calendar.current.startOfDay(for: $0.date)
        }
        .compactMapValues { entries in
            let total = entries.totalExpenses
            return total > 0 ? total : nil
        }
    }

    /// Total budget-eligible income per day, same shape as `dailySpending` — restored so a day
    /// with income (and no budget-eligible expense) still reads as an active day instead of being
    /// indistinguishable from a day with nothing at all, and a day with both shows an income
    /// indicator alongside its (still primary) spending tint. Excluded entries never count here,
    /// same rule as `dailySpending` (`Models/BudgetEligibility.swift`).
    private var dailyIncome: [Date: Decimal] {
        Dictionary(grouping: monthEntries.budgetEligible.filter { $0.type == .income }) {
            Calendar.current.startOfDay(for: $0.date)
        }
        .compactMapValues { entries in
            let total = entries.totalIncome
            return total > 0 ? total : nil
        }
    }

    /// Every entry for a day, unfiltered — an activity/transaction list reads every entry
    /// unconditionally, the same rule `Models/BudgetEligibility.swift` documents for Activity and
    /// CSV export. Only `dailySpending` above is budget-eligible-filtered; the day's own
    /// transaction list is not.
    private var entriesByDay: [Date: [Entry]] {
        Dictionary(grouping: monthEntries) { Calendar.current.startOfDay(for: $0.date) }
    }

    /// Largest single day's spend this month, used to scale tint intensity so a bigger spending
    /// day reads visibly (but still subtly) stronger than a small one.
    private var maxDailySpending: Decimal {
        dailySpending.values.max() ?? 0
    }

    /// Largest single day's income this month — mirrors `maxDailySpending`, scaling income-only
    /// day tint intensity the same way spending days already scale.
    private var maxDailyIncome: Decimal {
        dailyIncome.values.max() ?? 0
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
                            let day = weeks[weekIndex][dayIndex]
                            DayCell(
                                day: day,
                                spent: day.flatMap { dailySpending[$0] },
                                income: day.flatMap { dailyIncome[$0] },
                                intensity: intensity(for: day),
                                incomeIntensity: incomeIntensity(for: day),
                                isToday: day.map { Calendar.current.isDateInToday($0) } ?? false,
                                isSelected: day != nil && day == selectedDay
                            ) { tapped in
                                selectedDay = tapped
                                showingDayDetail = true
                            }
                        }
                    }
                }
            }

            selectionSummary

            legend
        }
        .sheet(isPresented: $showingDayDetail) {
            if let selectedDay {
                DayEntriesView(day: selectedDay, entries: entriesByDay[selectedDay] ?? [])
            }
        }
        // Re-applies `init`'s same default whenever the displayed month changes under this same
        // view instance — see `defaultSelectedDay`'s doc comment for why this can't be left to
        // `init` alone.
        .onChange(of: month) { _, newMonth in
            selectedDay = Self.defaultSelectedDay(for: newMonth)
            showingDayDetail = false
        }
    }

    /// A one-line "what did this day cost me" readout that updates the instant a different day is
    /// tapped, so the total is visible without needing to open (or re-open) the detail sheet.
    @ViewBuilder
    private var selectionSummary: some View {
        if let selectedDay {
            let spent = dailySpending[selectedDay]
            let income = dailyIncome[selectedDay]
            HStack {
                Text(selectionDateText(for: selectedDay))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                if let income, income > 0 {
                    Text("+\(income.currencyFormatted)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.emerald)
                }
                Text((spent ?? 0).currencyFormatted)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(spent != nil ? Color.expenseRed : Color.white.opacity(0.4))
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func selectionDateText(for day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private func intensity(for day: Date?) -> Double {
        guard let day, let spent = dailySpending[day], maxDailySpending > 0 else { return 0 }
        return min((spent / maxDailySpending).doubleValue, 1)
    }

    private func incomeIntensity(for day: Date?) -> Double {
        guard let day, let income = dailyIncome[day], maxDailyIncome > 0 else { return 0 }
        return min((income / maxDailyIncome).doubleValue, 1)
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
            legendItem(color: .expenseRed, label: "Spending")
            legendItem(color: .emerald, label: "Income")
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
    /// Combined VoiceOver label for one day cell — date + spending + income, never relying on
    /// color. `spent`/`income == nil` (or `0`) means no budget-eligible expenses/income that day.
    /// `income` defaults to `nil` so every existing call site that only ever tracked spending
    /// keeps reading exactly as before ("no spending" when nothing was spent, regardless of income).
    static func dayAccessibilityLabel(for day: Date, spent: Decimal?, income: Decimal? = nil, calendar: Calendar = .current) -> String {
        let dateText = day.formatted(.dateTime.month(.wide).day())
        let hasSpending = (spent ?? 0) > 0
        let hasIncome = (income ?? 0) > 0
        switch (hasSpending, hasIncome) {
        case (true, true):
            return "\(dateText), \(spent!.currencyFormatted) spent, \(income!.currencyFormatted) received"
        case (true, false):
            return "\(dateText), \(spent!.currencyFormatted) spent"
        case (false, true):
            return "\(dateText), \(income!.currencyFormatted) received"
        case (false, false):
            return "\(dateText), no spending"
        }
    }
}

private struct DayCell: View {
    let day: Date?
    let spent: Decimal?
    let income: Decimal?
    let intensity: Double
    let incomeIntensity: Double
    let isToday: Bool
    let isSelected: Bool
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

                    if let spent, spent > 0 {
                        Text(compactAmount(spent))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.expenseRed)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    } else if let income, income > 0 {
                        Text("+\(compactAmount(income))")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.emerald)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    } else {
                        Text(" ").font(.footnote)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(cellTintColor)
                        .overlay {
                            // A brighter wash distinguishes "selected" from a plain spend tint —
                            // fill, not another ring, so it never gets confused with `isToday`'s
                            // outline even when the same day is both today and selected.
                            if isSelected {
                                RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.14))
                            }
                        }
                }
                .overlay(alignment: .topTrailing) {
                    // A day with both spending and income still leads with the spending tint and
                    // number — this card's primary read is "what did this day cost me" — but a
                    // small dot keeps that day's income from disappearing entirely, matching this
                    // view's original (pre-regression) income awareness without displacing spending
                    // as the headline figure.
                    if let spent, spent > 0, let income, income > 0 {
                        Circle()
                            .fill(Color.emerald)
                            .frame(width: 6, height: 6)
                            .padding(4)
                    }
                }
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
            .accessibilityLabel(CalendarView.dayAccessibilityLabel(for: day, spent: spent, income: income))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint("Double tap to view this day's transactions")
        } else {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .accessibilityHidden(true)
        }
    }

    /// Spending leads whenever it's present (this card's primary read), income tints the day only
    /// when there was no spending at all, and a day with neither falls back to the neutral gray —
    /// the same three-way precedence `compactAmount`'s sibling text logic above uses.
    private var cellTintColor: Color {
        if let spent, spent > 0 {
            let opacity = 0.12 + 0.28 * intensity
            return Color.expenseRed.opacity(opacity)
        }
        if let income, income > 0 {
            let opacity = 0.12 + 0.28 * incomeIntensity
            return Color.emerald.opacity(opacity)
        }
        return Color.white.opacity(0.05)
    }

    private func compactAmount(_ value: Decimal) -> String {
        let amount = value.doubleValue
        if amount >= 1000 {
            return String(format: "%.1fK", amount / 1000)
        }
        return String(format: "%.0f", amount)
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
