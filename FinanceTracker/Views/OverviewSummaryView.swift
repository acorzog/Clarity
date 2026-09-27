import SwiftUI
import SwiftData

struct OverviewSummaryView: View {
    let month: Date

    @ObservedObject private var settings = OverviewSettingsStore.shared
    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]

    // `.budgetEligible` excludes `excludeFromBudget` entries (e.g. wallet balance adjustments)
    // from these analytical totals — see `Models/BudgetEligibility.swift`. This never affects
    // Wallet.balance/Net Worth, which read every Entry unconditionally elsewhere.
    private var monthEntries: [Entry] { allEntries.inMonth(month).budgetEligible }
    private var income: Decimal { monthEntries.totalIncome }
    private var expenses: Decimal { monthEntries.totalExpenses }

    var body: some View {
        VStack(spacing: 20) {
            ForEach(settings.visibleCards) { card in
                cardView(for: card)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private func cardView(for card: OverviewCard) -> some View {
        switch card {
        case .explainMonth:
            ExplainMyMonthCardView(month: month)
        case .spendingHealth:
            SpendingHealthCardView(month: month)
        case .summary:
            SummaryMetricsRow(income: income, expenses: expenses)
        case .calendar:
            CalendarCard(month: month)
        }
    }
}

extension OverviewSummaryView {
    /// `false` only when there is literally no budget-eligible income or expense this month —
    /// distinct from a real balanced month (both nonzero, net == 0). Phase 2J, see
    /// `SummaryMetricsRow`'s doc comment and `CLARITY_V1_POLISH_REPORT.md` §4.
    static func summaryHasActivity(income: Decimal, expenses: Decimal) -> Bool {
        income != 0 || expenses != 0
    }
}

/// Tier 1 (Quick-glance) — Income/Expenses/Net, per `CLARITY_OVERVIEW_VISUAL_SPEC.md` §6/§7.
/// Deliberately borderless (no `.surface()`/card wrapper at all): three numbers with a
/// self-evident relationship don't need a bounding box, mirroring `HomeView`'s Financial
/// Snapshot treatment exactly. Formerly `SummaryCard` — renamed since it's no longer a card.
///
/// The previous version additionally rendered a small axis-hidden, label-less bar chart
/// re-coloring these same three numbers as bars — purely decorative (no information beyond what
/// the numbers already show) and incompatible with "lightweight, immediately scannable" per the
/// approved spec's explicit description of this tier's content (three numbers, nothing else).
/// Removed rather than reboxed; see the Phase 2G implementation report for this disclosed,
/// deliberate content change.
private struct SummaryMetricsRow: View {
    let income: Decimal
    let expenses: Decimal

    /// Same calculation as before (`income - expenses`), only the label changed —
    /// "Left" → "Net", approved in Phase 2G to match `HomeView`'s Financial Snapshot naming for
    /// the identical calendar-month, budget-eligible calculation (see
    /// `CLARITY_OVERVIEW_VISUAL_SPEC.md` §4/§5). Never confused with Plan → Budget's
    /// Budget-Cycle-based "Left to Spend" (`PeriodSpendingSummary.totalLeft`), which this
    /// renaming does not touch.
    private var net: Decimal { income - expenses }
    private var netColor: Color { net >= 0 ? .skyBlue : .expenseRed }

    /// `false` only when there is literally no budget-eligible income or expense this month —
    /// distinct from a real balanced month (income and expenses both nonzero, net == 0), which
    /// still renders normally. Phase 2J: avoids "€0.00 / €0.00 / €0.00" reading as real, balanced
    /// financial data for a new/inactive month — see `CLARITY_V1_POLISH_REPORT.md` §4.
    private var hasActivity: Bool { OverviewSummaryView.summaryHasActivity(income: income, expenses: expenses) }

    var body: some View {
        if hasActivity {
            HStack(spacing: 40) {
                FinancialMetric(title: "Income", value: income.currencyFormattedSummary, color: .emerald, alignment: .center)
                FinancialMetric(title: "Expenses", value: expenses.currencyFormattedSummary, color: .expenseRed, alignment: .center)
                FinancialMetric(title: "Net", value: net.currencyFormattedSummary, color: netColor, alignment: .center)
            }
            .frame(maxWidth: .infinity)
        } else {
            Text("No activity yet this month")
                .font(.caption)
                .foregroundStyle(.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Which categories are progressing well vs. approaching/over their budget this period, per
/// `OverviewCalculator.categorySpendingHealth`. Categories with no budget set are left out by the
/// calculator itself — this view only renders whatever it's handed, never decides that.
private struct SpendingHealthCardView: View {
    let month: Date

    @ObservedObject private var budgetSettings = BudgetSettingsStore.shared
    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]
    @Query private var allBudgets: [Budget]
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]

    private var rows: [CategorySpendingHealth] {
        OverviewCalculator.categorySpendingHealth(
            month: month, entries: allEntries, budgets: allBudgets, headCategories: headCategories,
            settings: BudgetCalculationSettings(from: budgetSettings)
        )
    }

    /// The budget-eligible entries behind a category's `spent` figure, for the drill-down
    /// (`CategoryEntriesDetailView`) — mirrors `RemainingView.entries(for:)` exactly, so the
    /// detail list this opens never shows an entry the total above it didn't actually count.
    private func entries(for category: Category) -> [Entry] {
        allEntries
            .inBudgetPeriod(month, startDay: budgetSettings.cycleStartDay)
            .budgetEligible
            .filter { $0.type == .expense && $0.category === category }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ClaritySpacing.md) {
            Text("Spending Health")
                .font(.sectionTitle)
                .foregroundStyle(.textSecondary)

            if rows.isEmpty {
                Text("Set category budgets in Plan to see your spending health here")
                    .font(.caption)
                    .foregroundStyle(.textTertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        NavigationLink {
                            CategoryEntriesDetailView(title: row.category.name, entries: entries(for: row.category), category: row.category, month: month)
                        } label: {
                            SpendingHealthRow(health: row)
                        }
                        .buttonStyle(.plain)

                        if row.id != rows.last?.id {
                            Divider().background(Color.white.opacity(0.08))
                        }
                    }
                }
            }
        }
        .surface(.secondary, radius: ClarityRadius.large, padding: ClaritySpacing.xl)
    }
}

private struct SpendingHealthRow: View {
    let health: CategorySpendingHealth

    private var stateColor: Color { GaugeThreshold.color(forProgress: health.progress) }
    private var percentText: String { health.progress.formatted(.percent.precision(.fractionLength(0))) }

    private var statusWord: String {
        switch health.state {
        case .overBudget: "over budget"
        case .approachingLimit: "approaching its limit"
        case .onTrack: "on track"
        }
    }

    var body: some View {
        HStack(spacing: ClaritySpacing.md) {
            BudgetProgress(
                progress: min(health.progress, 1),
                isOverBudget: health.state == .overBudget,
                diameter: 32
            )

            Text(health.category.name)
                .font(.subheadline)
                .foregroundStyle(.textPrimary)
                .lineLimit(1)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(health.spent.currencyFormatted) / \(health.budgeted.currencyFormatted)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.textPrimary)
                Text(percentText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(stateColor)
            }
        }
        .padding(.vertical, ClaritySpacing.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(health.category.name): \(health.spent.currencyFormatted) of \(health.budgeted.currencyFormatted), \(percentText) used, \(statusWord)")
        .accessibilityHint("Double tap to view transactions")
    }
}

private struct CalendarCard: View {
    let month: Date

    var body: some View {
        VStack(spacing: 12) {
            Text("Money Calendar")
                .font(.sectionTitle)
                .foregroundStyle(.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            CalendarView(month: month)
        }
        .surface(.secondary, radius: ClarityRadius.large, padding: ClaritySpacing.xl)
    }
}

