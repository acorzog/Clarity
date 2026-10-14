import SwiftUI
import SwiftData

struct OverviewSummaryView: View {
    let month: Date

    @ObservedObject private var settings = OverviewSettingsStore.shared
    @Query(filter: #Predicate<Entry> { !$0.isSoftDeleted }, sort: \Entry.date, order: .reverse) private var allEntries: [Entry]

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
            ExplainMyMonthCardView()
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
        .claritySurface(tint: .skyBlue, radius: ClarityRadius.large, padding: ClaritySpacing.xl)
    }
}

