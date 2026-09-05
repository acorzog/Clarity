import SwiftUI
import SwiftData
import Charts

private enum SpendingGrouping: String, CaseIterable {
    case headCategories = "Head Categories"
    case categories = "Categories"
}

struct SpendingBreakdownView: View {
    let month: Date

    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]
    @Query(sort: \Category.name) private var categories: [Category]
    @State private var grouping: SpendingGrouping = .headCategories

    private var monthExpenses: [Entry] {
        allEntries.inMonth(month).filter { $0.type == .expense }
    }

    private var donutSlices: [CategorySlice] {
        headCategories.compactMap { head in
            let total = monthExpenses
                .filter { $0.category?.headCategory === head }
                .reduce(Decimal(0)) { $0 + $1.amount }
            guard total > 0 else { return nil }
            return CategorySlice(id: head.id, name: head.name, colorHex: head.colorHex, amount: total)
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

    var body: some View {
        VStack(spacing: 20) {
            DonutBreakdownCard(slices: donutSlices)

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
                            NavigationLink {
                                CategoryEntriesDetailView(title: row.name, entries: row.entries)
                            } label: {
                                SpendingRow(row: row)
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
    let colorHex: String
    let amount: Decimal
}

private struct DonutBreakdownCard: View {
    let slices: [CategorySlice]

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
                    .foregroundStyle(Color(hex: slice.colorHex))
                    .cornerRadius(6)
                }
                .frame(height: 220)
                .chartLegend(.hidden)
                .overlay {
                    if let top = slices.first {
                        VStack(spacing: 4) {
                            Text(top.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.6))
                            Text(top.amount.currencyFormatted)
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24))
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
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
