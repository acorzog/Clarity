import SwiftUI
import SwiftData

enum RemainingLayout: String, CaseIterable {
    case list
    case compact

    /// The layout a toolbar toggle switches *to* — used to pick that button's icon.
    var other: RemainingLayout { self == .list ? .compact : .list }
    var icon: String {
        switch self {
        case .list: "list.bullet"
        case .compact: "square.grid.2x2.fill"
        }
    }
}

struct RemainingView: View {
    let month: Date
    var layout: RemainingLayout = .list

    @ObservedObject private var settings = BudgetSettingsStore.shared
    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]
    @Query private var allBudgets: [Budget]
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]

    /// The shared "Available to Spend" calculation — see `BudgetCalculator.periodSpendingSummary`.
    /// Single source of truth also consumed by `BudgetGaugeWidget`, so the two can no longer
    /// disagree. `respectHiddenCategories: true` matches Plan's existing visible-only behavior.
    private var summary: PeriodSpendingSummary {
        BudgetCalculator.periodSpendingSummary(
            month: month,
            entries: allEntries,
            budgets: allBudgets,
            headCategories: headCategories,
            settings: BudgetCalculationSettings(from: settings),
            respectHiddenCategories: true
        )
    }

    private func expenseCategories(for head: HeadCategory) -> [Category] {
        head.categories.filter { !$0.isIncome && !$0.isArchived }.sorted { $0.name < $1.name }
    }

    private func headSummary(for head: HeadCategory, in summary: PeriodSpendingSummary) -> HeadRemainingSummary? {
        summary.byHeadCategory.first { $0.headCategory === head }
            .map { HeadRemainingSummary(id: head.id, name: head.name, colorHex: head.colorHex, budgeted: $0.planned, spent: $0.actual) }
    }

    /// The budget-eligible entries behind a category's `spent` figure, for the drill-down
    /// (`CategoryEntriesDetailView`) — kept consistent with the total it explains, so the detail
    /// list never shows an entry the total above it didn't actually count.
    private func entries(for category: Category) -> [Entry] {
        allEntries
            .inBudgetPeriod(month, startDay: settings.cycleStartDay)
            .budgetEligible
            .filter { $0.type == .expense && $0.category === category }
    }

    private func otherRows(for summary: PeriodSpendingSummary) -> [OtherSpendingRow] {
        var rows: [OtherSpendingRow] = []
        if settings.includeUnplannedAsOtherExpenses && summary.otherExpensesTotal > 0 {
            rows.append(OtherSpendingRow(title: "Other Expenses", amount: summary.otherExpensesTotal, icon: "questionmark.circle.fill"))
        }
        if settings.includeSavingsTransfers && summary.savingsTransfersTotal > 0 {
            rows.append(OtherSpendingRow(title: "Savings Transfers", amount: summary.savingsTransfersTotal, icon: "banknote.fill"))
        }
        if settings.includeDebtTransfers && summary.debtTransfersTotal > 0 {
            rows.append(OtherSpendingRow(title: "Debt Payments", amount: summary.debtTransfersTotal, icon: "creditcard.fill"))
        }
        return rows
    }

    var body: some View {
        // Computed once per body evaluation (rather than re-read as a computed property from
        // every row) since it aggregates every entry/budget/category in a single pass.
        let summary = summary
        let spent: (Category) -> Decimal = { category in
            summary.byCategory.first { $0.category === category }?.actual ?? 0
        }
        let budgeted: (Category) -> Decimal = { category in
            summary.byCategory.first { $0.category === category }?.planned ?? 0
        }

        if summary.totalAvailable == 0 && summary.totalSpent == 0 {
            EmptyStateView(
                icon: "gauge.with.needle",
                title: "No Budget Set",
                message: "Set monthly limits in Allocate to see what's available to spend."
            )
        } else {
            VStack(spacing: 24) {
                RemainingGauge(
                    totalAvailable: summary.totalAvailable,
                    totalSpent: summary.totalSpent,
                    breakdown: headCategories.compactMap { headSummary(for: $0, in: summary) }
                )

                VStack(spacing: 16) {
                    ForEach(headCategories) { head in
                        let categories = expenseCategories(for: head)
                        if let headSummary = headSummary(for: head, in: summary) {
                            switch layout {
                            case .list:
                                HeadRemainingSection(
                                    head: headSummary,
                                    categories: categories,
                                    spentFor: spent,
                                    budgetedFor: budgeted,
                                    entriesFor: entries
                                )
                            case .compact:
                                HeadRemainingGridSection(
                                    head: headSummary,
                                    categories: categories,
                                    spentFor: spent,
                                    budgetedFor: budgeted,
                                    entriesFor: entries
                                )
                            }
                        }
                    }

                    let otherRows = otherRows(for: summary)
                    if !otherRows.isEmpty {
                        OtherSpendingCard(rows: otherRows)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }
}

extension RemainingView {
    /// Combined VoiceOver summary for `RemainingGauge` — overall status first, then each head
    /// category's remaining amount, in the same order the gauge's `breakdown` is given (matching
    /// the reading-order convention already established for the donut/trend charts). `breakdown`
    /// is already-computed `left` values (`budgeted - spent`), never recalculated here.
    static func gaugeAccessibilitySummary(
        totalAvailable: Decimal,
        totalSpent: Decimal,
        breakdown: [(name: String, left: Decimal)]
    ) -> String {
        let totalLeft = totalAvailable - totalSpent
        let headline = totalLeft >= 0
            ? "\(totalLeft.currencyFormatted) available to spend."
            : "\(abs(totalLeft).currencyFormatted) over available."
        guard !breakdown.isEmpty else { return headline }
        let lines = breakdown.map { "\($0.name): \($0.left.currencyFormatted) left." }
        return ([headline] + lines).joined(separator: " ")
    }
}

private struct OtherSpendingRow: Identifiable {
    var id: String { title }
    let title: String
    let amount: Decimal
    let icon: String
}

private struct OtherSpendingCard: View {
    let rows: [OtherSpendingRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Other")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 12) {
                        Image(systemName: row.icon)
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 20)
                        Text(row.title)
                            .foregroundStyle(.white)
                        Spacer()
                        Text(row.amount.currencyFormatted)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)

                    if row.id != rows.last?.id {
                        Divider().background(Color.white.opacity(0.08)).padding(.leading, 44)
                    }
                }
            }
            .surface(.primary, radius: ClarityRadius.medium, padding: 0)
        }
    }
}

private struct HeadRemainingSummary: Identifiable {
    let id: PersistentIdentifier
    let name: String
    let colorHex: String
    let budgeted: Decimal
    let spent: Decimal
    var left: Decimal { budgeted - spent }
}

private struct RemainingGauge: View {
    let totalAvailable: Decimal
    let totalSpent: Decimal
    let breakdown: [HeadRemainingSummary]

    private let gaugeSize: CGFloat = 230
    private let labelRadius: CGFloat = 162

    private var progress: Double {
        guard totalAvailable > 0 else { return 0 }
        return min(max((totalSpent / totalAvailable).doubleValue, 0), 1)
    }

    private var totalLeft: Decimal { totalAvailable - totalSpent }

    private var arcColor: Color {
        guard totalAvailable > 0 else { return .white.opacity(0.3) }
        return GaugeThreshold.color(forProgress: (totalSpent / totalAvailable).doubleValue)
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 20, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: gaugeSize, height: gaugeSize)

            Circle()
                .trim(from: 0, to: 0.75 * progress)
                .stroke(arcColor, style: StrokeStyle(lineWidth: 20, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: gaugeSize, height: gaugeSize)

            ForEach(Array(breakdown.enumerated()), id: \.element.id) { index, head in
                let angle = angleDegrees(index: index, total: breakdown.count) * .pi / 180
                HeadArcLabel(head: head)
                    .offset(x: labelRadius * cos(angle), y: labelRadius * sin(angle))
            }

            VStack(spacing: 6) {
                Text("Available to Spend")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                Text(totalLeft.currencyFormatted)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .frame(width: gaugeSize * 0.55)
        }
        .frame(height: labelRadius * 2 + 50)
        .frame(maxWidth: .infinity)
        // The ring itself, the center text, and every `HeadArcLabel` floating around it are all
        // individually silent/confusing to VoiceOver (an untitled arc; absolutely-positioned
        // labels with no reading order) — matches the exact gap Phase 2F already fixed for the
        // donut chart. One composed summary replaces all of it, read in a sensible order (overall
        // status, then each head category), rather than exposing the drawing itself.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            RemainingView.gaugeAccessibilitySummary(
                totalAvailable: totalAvailable,
                totalSpent: totalSpent,
                breakdown: breakdown.map { (name: $0.name, left: $0.left) }
            )
        )
    }

    private func angleDegrees(index: Int, total: Int) -> Double {
        guard total > 0 else { return 270 }
        return 135.0 + 270.0 * (Double(index) + 0.5) / Double(total)
    }
}

private struct HeadArcLabel: View {
    let head: HeadRemainingSummary

    var body: some View {
        VStack(spacing: 1) {
            Text(head.name)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(head.left.currencyFormatted)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(hex: head.colorHex))
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: 64)
    }
}

private struct HeadRemainingSection: View {
    let head: HeadRemainingSummary
    let categories: [Category]
    let spentFor: (Category) -> Decimal
    let budgetedFor: (Category) -> Decimal
    let entriesFor: (Category) -> [Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(Color(hex: head.colorHex))
                    .frame(width: 10, height: 10)
                Text(head.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(head.left.currencyFormatted) left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(head.left >= 0 ? Color.white.opacity(0.6) : Color.expenseRed)
            }

            VStack(spacing: 0) {
                ForEach(categories) { category in
                    NavigationLink {
                        CategoryEntriesDetailView(title: category.name, entries: entriesFor(category))
                    } label: {
                        CategoryProgressRow(
                            name: category.name,
                            colorHex: category.resolvedColorHex,
                            spent: spentFor(category),
                            budgeted: budgetedFor(category)
                        )
                    }
                    .buttonStyle(.plain)
                    if category !== categories.last {
                        Divider().background(Color.white.opacity(0.08)).padding(.leading, 60)
                    }
                }
            }
            .surface(.primary, radius: ClarityRadius.medium, padding: 0)
        }
    }
}

/// The compact alternative to `HeadRemainingSection` — a grid of icon tiles instead of full-width
/// rows, so a whole head category's categories can be scanned at a glance.
private struct HeadRemainingGridSection: View {
    let head: HeadRemainingSummary
    let categories: [Category]
    let spentFor: (Category) -> Decimal
    let budgetedFor: (Category) -> Decimal
    let entriesFor: (Category) -> [Entry]

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(Color(hex: head.colorHex))
                    .frame(width: 10, height: 10)
                Text(head.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(head.left.currencyFormatted) left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(head.left >= 0 ? Color.white.opacity(0.6) : Color.expenseRed)
            }

            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(categories) { category in
                    NavigationLink {
                        CategoryEntriesDetailView(title: category.name, entries: entriesFor(category))
                    } label: {
                        CategoryGridCell(
                            category: category,
                            spent: spentFor(category),
                            budgeted: budgetedFor(category)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .surface(.primary, radius: ClarityRadius.medium, padding: ClaritySpacing.lg)
        }
    }
}

private struct CategoryGridCell: View {
    let category: Category
    let spent: Decimal
    let budgeted: Decimal

    private var progress: Double {
        guard budgeted > 0 else { return spent > 0 ? 1 : 0 }
        return min((spent / budgeted).doubleValue, 1)
    }

    private var isOverBudget: Bool { budgeted > 0 && spent > budgeted }
    private var ringColor: Color { isOverBudget ? .expenseRed : Color(hex: category.resolvedColorHex) }
    private var left: Decimal { budgeted - spent }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                CategoryIconView(category: category, size: 50)
            }
            .frame(width: 64, height: 64)

            Text(category.name)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text("\(left.currencyFormatted) left")
                .font(.caption2)
                .foregroundStyle(isOverBudget ? Color.expenseRed : .white.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CategoryProgressRow: View {
    let name: String
    let colorHex: String
    let spent: Decimal
    let budgeted: Decimal

    private var progress: Double {
        guard budgeted > 0 else { return spent > 0 ? 1 : 0 }
        return min((spent / budgeted).doubleValue, 1)
    }

    private var isOverBudget: Bool { budgeted > 0 && spent > budgeted }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        isOverBudget ? Color.expenseRed : Color(hex: colorHex),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 32, height: 32)

            Text(name)
                .foregroundStyle(.white)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(spent.currencyFormatted)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isOverBudget ? Color.expenseRed : Color.white)
                Text("of \(budgeted.currencyFormatted)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }
}
