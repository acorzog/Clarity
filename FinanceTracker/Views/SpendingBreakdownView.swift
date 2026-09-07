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
    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]
    @Query(sort: \Category.name) private var categories: [Category]
    @State private var grouping: SpendingGrouping = .headCategories
    @State private var expandedHeadCategoryIDs: Set<PersistentIdentifier> = []

    private var monthExpenses: [Entry] {
        allEntries.inMonth(month).filter { $0.type == .expense }
    }

    private var donutSlices: [CategorySlice] {
        headCategories.compactMap { head in
            let total = monthExpenses
                .filter { $0.category?.headCategory === head }
                .reduce(Decimal(0)) { $0 + $1.amount }
            guard total > 0 else { return nil }
            return CategorySlice(id: head.id, name: head.name, icon: head.icon, colorHex: head.colorHex, amount: total)
        }
        .sorted { $0.amount > $1.amount }
    }

    private var headCategoryRows: [SpendingRowData] {
        headCategories.compactMap { head in
            let entries = monthExpenses.filter { $0.category?.headCategory === head }
            let total = entries.reduce(Decimal(0)) { $0 + $1.amount }
            guard total > 0 else { return nil }
            return SpendingRowData(id: head.id, name: head.name, colorHex: head.colorHex, total: total, entries: entries)
        }
        .sorted { $0.total > $1.total }
    }

    private var categoryRows: [SpendingRowData] {
        categories.filter { !$0.isArchived }.compactMap { category in
            let entries = monthExpenses.filter { $0.category === category }
            let total = entries.reduce(Decimal(0)) { $0 + $1.amount }
            guard total > 0 else { return nil }
            return SpendingRowData(
                id: category.id,
                name: category.name,
                colorHex: category.resolvedColorHex,
                total: total,
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
        return categories.filter { !$0.isArchived && $0.headCategory === head }.compactMap { category in
            let entries = monthExpenses.filter { $0.category === category }
            let total = entries.reduce(Decimal(0)) { $0 + $1.amount }
            guard total > 0 else { return nil }
            return SpendingRowData(
                id: category.id,
                name: category.name,
                colorHex: category.resolvedColorHex,
                total: total,
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
                DonutBreakdownCard(slices: donutSlices)
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

private struct CategorySlice: Identifiable {
    let id: PersistentIdentifier
    let name: String
    let icon: String
    let colorHex: String
    let amount: Decimal
}

private struct DonutBreakdownCard: View {
    let slices: [CategorySlice]

    /// Position within the cumulative "Amount" domain that the chart reports back on tap —
    /// e.g. for three slices of 10/20/30, tapping the second slice reports somewhere in 10...30.
    @State private var tappedAmount: Double?

    private var totalAmount: Double {
        slices.reduce(0) { $0 + $1.amount.doubleValue }
    }

    /// The slice a tap landed in, resolved by walking the same cumulative order the chart
    /// stacks its sectors in. Falls back to the largest slice (already first, since `slices`
    /// is sorted descending) when nothing has been tapped yet.
    private var highlightedSlice: CategorySlice? {
        guard let tappedAmount else { return slices.first }
        var cumulative: Double = 0
        for slice in slices {
            cumulative += slice.amount.doubleValue
            if tappedAmount <= cumulative {
                return slice
            }
        }
        return slices.last
    }

    /// The angle (from 12 o'clock, clockwise) of a slice's midpoint, for placing its icon —
    /// mirrors the cumulative order Swift Charts stacks `SectorMark`s in from `slices`.
    private func midAngle(for slice: CategorySlice) -> Angle {
        var cumulative: Double = 0
        for candidate in slices {
            if candidate.id == slice.id {
                let mid = cumulative + candidate.amount.doubleValue / 2
                return .degrees(totalAmount > 0 ? mid / totalAmount * 360 - 90 : 0)
            }
            cumulative += candidate.amount.doubleValue
        }
        return .degrees(0)
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
                ZStack {
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
                    // Reports back which point in the cumulative "Amount" domain a tap landed
                    // on, so touching any wedge — not just the biggest — updates the center label.
                    .chartAngleSelection(value: $tappedAmount)
                    .frame(height: 220)
                    .chartLegend(.hidden)

                    sliceIcons
                        .allowsHitTesting(false)
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
    }

    private var sliceIcons: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            // Midway between the donut's inner (0.62) and outer (1.0) radius.
            let radius = side / 2 * 0.81
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)

            ForEach(slices) { slice in
                let angle = midAngle(for: slice)
                Image(systemName: slice.icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.black.opacity(0.28), in: Circle())
                    .position(
                        x: center.x + radius * CGFloat(cos(angle.radians)),
                        y: center.y + radius * CGFloat(sin(angle.radians))
                    )
            }
        }
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
