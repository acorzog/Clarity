import SwiftUI
import SwiftData
import Charts

private enum SpendingGrouping: String, CaseIterable {
    case headCategories = "Head Categories"
    case categories = "Categories"
}

struct SpendingBreakdownView: View {
    let month: Date

    @ObservedObject private var settings = OverviewSettingsStore.shared
    @ObservedObject private var budgetSettings = BudgetSettingsStore.shared
    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]
    @Query private var allBudgets: [Budget]
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]
    @State private var grouping: SpendingGrouping = .headCategories
    @State private var expandedHeadCategoryIDs: Set<PersistentIdentifier> = []

    /// Spending is explicitly calendar-month, never Budget Cycle — see
    /// `CLARITY_OVERVIEW_ACTIVITY_SPEC.md` §13/§23/§28. Every other field mirrors the live
    /// store; only `cycleStartDay` is forced to 1 so `BudgetCalculator.periodSpendingSummary`
    /// resolves the plain calendar month (`Date.budgetPeriod(startDay: 1)` — see
    /// `Models/EntryQuerying.swift`) regardless of the user's configured Budget Cycle. This is
    /// the one deliberate override; nothing else here re-derives calculation semantics.
    private var calculationSettings: BudgetCalculationSettings {
        var settings = BudgetCalculationSettings(from: budgetSettings)
        settings.cycleStartDay = 1
        return settings
    }

    /// The single source of truth for this month's category/head-category actual spend —
    /// `Models/BudgetCalculator.swift`, the same centralized calculation layer Plan → Budget's
    /// Remaining/Insights already consume. Spending never re-derives this total itself; see
    /// `CLARITY_OVERVIEW_ACTIVITY_SPEC.md` §17 for why that used to be true and no longer is.
    private var summary: PeriodSpendingSummary {
        BudgetCalculator.periodSpendingSummary(
            month: month, entries: allEntries, budgets: allBudgets, headCategories: headCategories,
            settings: calculationSettings, respectHiddenCategories: true
        )
    }

    /// Budget-eligible expense entries this calendar month — the same population `summary`'s
    /// totals are drawn from. Used only to populate each row's drill-down entry list
    /// (`CategoryEntriesDetailView`); the totals themselves always come from `summary`, never
    /// from reducing this array.
    private var monthExpenses: [Entry] {
        allEntries.inMonth(month).budgetEligible.filter { $0.type == .expense }
    }

    private var donutSlices: [CategorySlice] {
        summary.byHeadCategory.compactMap { headActual in
            guard headActual.actual > 0 else { return nil }
            let head = headActual.headCategory
            return CategorySlice(id: head.id, name: head.name, icon: head.icon, colorHex: head.colorHex, amount: headActual.actual)
        }
        .sorted { $0.amount > $1.amount }
    }

    /// Combined VoiceOver summary for the donut chart, built from the same `donutSlices` the
    /// chart itself renders — see `SpendingBreakdownView.donutAccessibilitySummary(month:
    /// categories:)` for the pure, testable formatting logic.
    private var donutAccessibilitySummary: String {
        SpendingBreakdownView.donutAccessibilitySummary(
            month: month,
            categories: donutSlices.map { (name: $0.name, amount: $0.amount) }
        )
    }

    private var headCategoryRows: [SpendingRowData] {
        summary.byHeadCategory.compactMap { headActual -> SpendingRowData? in
            guard headActual.actual > 0 else { return nil }
            let head = headActual.headCategory
            let entries = monthExpenses.filter { $0.category?.headCategory === head }
            return SpendingRowData(id: head.id, name: head.name, colorHex: head.colorHex, total: headActual.actual, entries: entries)
        }
        .sorted { $0.total > $1.total }
    }

    private var categoryRows: [SpendingRowData] {
        summary.byCategory.compactMap { categoryActual -> SpendingRowData? in
            guard categoryActual.actual > 0 else { return nil }
            let category = categoryActual.category
            let entries = monthExpenses.filter { $0.category === category }
            return SpendingRowData(
                id: category.id,
                name: category.name,
                colorHex: category.resolvedColorHex,
                total: categoryActual.actual,
                entries: entries
            )
        }
        .sorted { $0.total > $1.total }
    }

    private var rows: [SpendingRowData] {
        grouping == .headCategories ? headCategoryRows : categoryRows
    }

    /// The categories nested under one head category, for the expand/collapse row —
    /// same shape as `categoryRows` but scoped to a single head.
    private func subRows(forHeadID id: PersistentIdentifier) -> [SpendingRowData] {
        guard let head = headCategories.first(where: { $0.id == id }) else { return [] }
        return summary.byCategory
            .filter { $0.category.headCategory === head }
            .compactMap { categoryActual -> SpendingRowData? in
                guard categoryActual.actual > 0 else { return nil }
                let category = categoryActual.category
                let entries = monthExpenses.filter { $0.category === category }
                return SpendingRowData(
                    id: category.id,
                    name: category.name,
                    colorHex: category.resolvedColorHex,
                    total: categoryActual.actual,
                    entries: entries
                )
            }
            .sorted { $0.total > $1.total }
    }

    private func toggleExpanded(_ id: PersistentIdentifier) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedHeadCategoryIDs.contains(id) {
                expandedHeadCategoryIDs.remove(id)
            } else {
                expandedHeadCategoryIDs.insert(id)
            }
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            if settings.showSpendingBreakdown {
                DonutBreakdownCard(slices: donutSlices, accessibilitySummary: donutAccessibilitySummary)
            }

            VStack(spacing: 16) {
                Picker("Grouping", selection: $grouping) {
                    ForEach(SpendingGrouping.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .tint(.emerald)

                if rows.isEmpty {
                    EmptyStateView(
                        icon: "chart.pie",
                        title: "No Expenses",
                        message: "Nothing spent this month yet — add a transaction to see it here."
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            if grouping == .headCategories {
                                ExpandableHeadRow(
                                    row: row,
                                    isExpanded: expandedHeadCategoryIDs.contains(row.id),
                                    subRows: subRows(forHeadID: row.id),
                                    onToggle: { toggleExpanded(row.id) }
                                )
                            } else {
                                NavigationLink {
                                    CategoryEntriesDetailView(title: row.name, entries: row.entries)
                                } label: {
                                    SpendingRow(row: row)
                                }
                            }

                            if row.id != rows.last?.id {
                                Divider()
                                    .background(Color.white.opacity(0.08))
                                    .padding(.leading, 42)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 24)
    }
}

extension SpendingBreakdownView {
    /// Pure, presentation-only formatter for the donut chart's combined VoiceOver summary: the
    /// selected month, then each category's name, amount, and share of the total — in the same
    /// descending-by-amount order the chart itself renders. Share is a simple derivation
    /// (`amount / total`) from the same amounts already displayed on the chart, not a new
    /// financial calculation — the totals themselves still come only from `donutSlices`
    /// (`summary.byHeadCategory`, i.e. `BudgetCalculator`). See
    /// `CLARITY_OVERVIEW_ACTIVITY_UX_SPEC.md` §14/§16.
    static func donutAccessibilitySummary(month: Date, categories: [(name: String, amount: Decimal)]) -> String {
        let periodText = month.formatted(.dateTime.month(.wide).year())

        guard !categories.isEmpty else {
            return "Spending breakdown for \(periodText). No expenses this month."
        }

        let total = categories.reduce(Decimal(0)) { $0 + $1.amount }
        let categoryLines = categories.map { category -> String in
            let amountText = category.amount.currencyFormatted
            guard total > 0 else { return "\(category.name), \(amountText)." }
            let percent = Int(((category.amount / total) * 100).doubleValue.rounded())
            return "\(category.name), \(amountText), \(percent) percent."
        }

        return (["Spending breakdown for \(periodText)."] + categoryLines).joined(separator: " ")
    }
}

private struct CategorySlice: Identifiable {
    let id: PersistentIdentifier
    let name: String
    let icon: String
    let colorHex: String
    let amount: Decimal
}

private struct DonutBreakdownCard: View {
    let slices: [CategorySlice]
    let accessibilitySummary: String

    /// The slice currently shown in the center label. Defaults to the largest (already first,
    /// since `slices` is sorted descending) until the user taps a different wedge.
    @State private var selectedSliceID: PersistentIdentifier?

    private var totalAmount: Double {
        slices.reduce(0) { $0 + $1.amount.doubleValue }
    }

    private var highlightedSlice: CategorySlice? {
        slices.first { $0.id == selectedSliceID } ?? slices.first
    }

    /// Each slice's start/end angle (from 12 o'clock, clockwise, in degrees), in the same
    /// cumulative order Swift Charts stacks `SectorMark`s in from `slices`. Computed once per
    /// body evaluation and reused for icon placement, icon visibility, and tap hit-testing so
    /// all three agree on exactly the same geometry.
    private var sliceRanges: [(slice: CategorySlice, start: Double, end: Double)] {
        guard totalAmount > 0 else { return [] }
        var cumulative: Double = 0
        return slices.map { slice in
            let start = cumulative / totalAmount * 360
            cumulative += slice.amount.doubleValue
            let end = cumulative / totalAmount * 360
            return (slice, start, end)
        }
    }

    private func midAngle(for slice: CategorySlice) -> Angle {
        guard let range = sliceRanges.first(where: { $0.slice.id == slice.id }) else { return .degrees(0) }
        return .degrees((range.start + range.end) / 2 - 90)
    }

    /// Hides the icon on wedges too narrow to fit a 22pt badge without touching its neighbor,
    /// rather than letting adjacent icons overlap on thin slices.
    private func showsIcon(for slice: CategorySlice) -> Bool {
        guard let range = sliceRanges.first(where: { $0.slice.id == slice.id }) else { return false }
        return (range.end - range.start) >= 20
    }

    /// Resolves a tap point (in the chart's plot-area coordinate space) to the slice whose
    /// angular range contains it — a deterministic replacement for Swift Charts'
    /// `chartAngleSelection`, which was unreliable here and kept resolving taps back to the
    /// largest wedge instead of the one actually tapped.
    private func slice(at point: CGPoint, in rect: CGRect) -> CategorySlice? {
        let outerRadius = min(rect.width, rect.height) / 2
        guard outerRadius > 0 else { return nil }
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance >= outerRadius * 0.62, distance <= outerRadius else { return nil }

        var degrees = atan2(dy, dx) * 180 / .pi + 90
        if degrees < 0 { degrees += 360 }
        return sliceRanges.first { degrees >= $0.start && degrees < $0.end }?.slice
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Spending by Category")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)

            if slices.isEmpty {
                Text("No expenses this month")
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(height: 220)
            } else {
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("Amount", slice.amount.doubleValue),
                        innerRadius: .ratio(0.62),
                        angularInset: 2
                    )
                    // Sectors need a discrete "by" channel for Charts to treat each one as
                    // its own stacked wedge — a constant .foregroundStyle() here collapses
                    // them all into a single full-circle mark showing only the largest value.
                    .foregroundStyle(by: .value("Head Category", slice.name))
                    .cornerRadius(6)
                    .opacity(highlightedSlice == nil || highlightedSlice?.id == slice.id ? 1 : 0.35)
                }
                .chartForegroundStyleScale(
                    domain: slices.map(\.name),
                    range: slices.map { Color(hex: $0.colorHex) }
                )
                .frame(height: 220)
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        if let plotFrame = proxy.plotFrame {
                            let rect = geometry[plotFrame]
                            let radius = min(rect.width, rect.height) / 2 * 0.81

                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { location in
                                    guard let tapped = slice(at: location, in: rect) else { return }
                                    withAnimation(.easeOut(duration: 0.15)) { selectedSliceID = tapped.id }
                                }

                            ForEach(slices.filter(showsIcon)) { slice in
                                let angle = midAngle(for: slice)
                                Image(systemName: slice.icon)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(Color.black.opacity(0.28), in: Circle())
                                    .position(
                                        x: rect.midX + radius * CGFloat(cos(angle.radians)),
                                        y: rect.midY + radius * CGFloat(sin(angle.radians))
                                    )
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .overlay {
                    if let highlightedSlice {
                        VStack(spacing: 4) {
                            Text(highlightedSlice.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.6))
                            Text(highlightedSlice.amount.currencyFormatted)
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                        }
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24))
        // The chart's own tap-to-highlight interaction (`chartOverlay`'s `onTapGesture`) is
        // preserved untouched below — this only adds a spoken summary VoiceOver users can reach
        // without needing to interpret wedge geometry/color; it doesn't gate or replace the
        // visual interaction. `.ignore` prevents VoiceOver from also exposing each `SectorMark`
        // and the decorative per-slice icon badges as separate, context-free stops.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }
}

private struct SpendingRowData: Identifiable {
    let id: PersistentIdentifier
    let name: String
    let colorHex: String
    let total: Decimal
    let entries: [Entry]
}

private struct SpendingRow: View {
    let row: SpendingRowData
    var isExpanded: Bool?

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: row.colorHex))
                .frame(width: 14, height: 14)
            Text(row.name)
                .foregroundStyle(.white)
            Spacer()
            Text(row.total.currencyFormatted)
                .foregroundStyle(.white.opacity(0.7))
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.3))
                .rotationEffect(.degrees(isExpanded == true ? 90 : 0))
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// A head-category row that expands in place to reveal the categories under it,
/// each of which navigates on to its own entries — rather than jumping straight
/// to a flat list of every entry across the whole head category.
private struct ExpandableHeadRow: View {
    let row: SpendingRowData
    let isExpanded: Bool
    let subRows: [SpendingRowData]
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                SpendingRow(row: row, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(subRows) { sub in
                        NavigationLink {
                            CategoryEntriesDetailView(title: sub.name, entries: sub.entries)
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color(hex: sub.colorHex))
                                    .frame(width: 8, height: 8)
                                Text(sub.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.85))
                                Spacer()
                                Text(sub.total.currencyFormatted)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.6))
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.25))
                            }
                            .padding(.leading, 42)
                            .padding(.trailing)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color.white.opacity(0.03))
            }
        }
    }
}
