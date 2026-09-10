import SwiftUI
import SwiftData

/// Clarity's "Understand" surface — see `CLARITY_HOME_SPEC.md`. Composes already-computed
/// values from `BudgetCalculator`, `HomeCalculator`, and `NetWorthCalculator`; performs no
/// financial calculation of its own (`CLARITY_HOME_SPEC.md` §17/§13 — "HomeView must NOT become
/// a calculation layer").
struct HomeView: View {
    /// Lets a Home section switch tabs on tap — the closest existing navigation behavior. Home's
    /// drill-downs land on each destination tab's root, not a specific sub-tab or scroll
    /// position: that would require converting `OverviewView`/`BudgetContentView`'s sub-tab
    /// state from view-local `@State` to an externally-driven `@Binding`, which is a larger
    /// change than this phase's "small, local changes" discipline allows. Documented as a known
    /// limitation rather than silently worked around.
    @Binding var selectedTab: MainTab

    @ObservedObject private var budgetSettings = BudgetSettingsStore.shared
    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]
    @Query private var allBudgets: [Budget]
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]
    @Query(sort: \Wallet.sortOrder) private var allWallets: [Wallet]
    @Query(sort: \SharedEvent.createdAt, order: .reverse) private var sharedEvents: [SharedEvent]

    private var month: Date { Date.startOfMonth() }

    private var calculationSettings: BudgetCalculationSettings {
        BudgetCalculationSettings(from: budgetSettings)
    }

    /// The same shared calculation `RemainingView`/`InsightsView`/`BudgetGaugeWidget` use — see
    /// `BudgetCalculator.periodSpendingSummary`. Safe to Spend, in V1, is exactly `totalLeft` —
    /// see `CLARITY_HOME_SPEC.md` §5 for why a forward-looking adjustment isn't implemented yet.
    private var summary: PeriodSpendingSummary {
        BudgetCalculator.periodSpendingSummary(
            month: month, entries: allEntries, budgets: allBudgets, headCategories: headCategories,
            settings: calculationSettings, respectHiddenCategories: true
        )
    }

    private var hasBudgetData: Bool {
        summary.totalAvailable > 0 || summary.totalSpent > 0
    }

    /// Mirrors `GaugeThreshold`'s own thresholds (1.0, 0.85) so this status text can never
    /// disagree with the dot/number color it sits next to, which is colored via `GaugeThreshold`
    /// directly.
    private var safeToSpendRatio: Double {
        guard summary.totalAvailable > 0 else { return 0 }
        return (summary.totalSpent / summary.totalAvailable).doubleValue
    }

    private var safeToSpendColor: Color {
        guard summary.totalAvailable > 0 else { return .textSecondary }
        return GaugeThreshold.color(forProgress: safeToSpendRatio)
    }

    private var safeToSpendStatusText: String {
        guard summary.totalAvailable > 0 else { return "" }
        if safeToSpendRatio >= 1 { return "Over budget" }
        if safeToSpendRatio >= 0.85 { return "Getting close to budget" }
        return "On track"
    }

    private var periodRangeText: String {
        let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: summary.period.end) ?? summary.period.end
        return "Through \(lastDay.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private var whatsDifferentInsights: [WhatsDifferentInsight] {
        HomeCalculator.whatsDifferentInsights(
            month: month, entries: allEntries, budgets: allBudgets, headCategories: headCategories,
            settings: calculationSettings
        )
    }

    private var pace: [DailyPacePoint] {
        BudgetCalculator.spendingPace(
            month: month, entries: allEntries, settings: calculationSettings, totalPlanned: summary.totalBudgeted
        )
    }

    private var forecastState: ForecastPaceState {
        HomeCalculator.forecastPaceState(pace: pace)
    }

    // `.budgetEligible` matches `OverviewSummaryView`'s existing Income/Expenses card exactly —
    // see `CLARITY_HOME_SPEC.md` §8 on why Financial Snapshot is budget-eligible, not raw cash flow.
    private var monthEntries: [Entry] { allEntries.inMonth(month).budgetEligible }
    private var snapshotIncome: Decimal { monthEntries.totalIncome }
    private var snapshotExpenses: Decimal { monthEntries.totalExpenses }
    private var snapshotNet: Decimal { snapshotIncome - snapshotExpenses }

    private var activeWallets: [Wallet] { Wallet.active(in: allWallets) }
    private var netWorth: Decimal { NetWorthCalculator.netWorth(wallets: allWallets) }

    private var upcomingItems: [UpcomingSharedBalance] {
        HomeCalculator.upcomingSharedBalances(events: sharedEvents)
    }

    private var isEffectivelyEmpty: Bool {
        allEntries.isEmpty && allWallets.isEmpty && allBudgets.isEmpty && sharedEvents.isEmpty
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ClaritySpacing.xxl) {
                    header
                    safeToSpendSection
                    whatsDifferentSection
                    upcomingSection
                    financialSnapshotSection
                    netWorthSection
                    forecastSection
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .readableContentWidth()
            }
            .darkScreenBackground()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(greeting)
                .font(.body)
                .foregroundStyle(.textSecondary)
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.sectionTitle)
                .foregroundStyle(.textPrimary)

            if isEffectivelyEmpty {
                Text("Add a transaction or two, and Home will start filling in.")
                    .font(.footnote)
                    .foregroundStyle(.textTertiary)
                    .padding(.top, ClaritySpacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Safe to Spend (hero)

    private var safeToSpendSection: some View {
        Button {
            selectedTab = .plan
        } label: {
            VStack(spacing: ClaritySpacing.sm) {
                Text("Safe to Spend")
                    .font(.body)
                    .foregroundStyle(.textSecondary)

                if hasBudgetData {
                    Text(summary.totalLeft.currencyFormatted)
                        .heroAmountStyle()
                        .foregroundStyle(summary.totalLeft < 0 ? Color.expense : Color.textPrimary)

                    Text(periodRangeText)
                        .font(.caption)
                        .foregroundStyle(.textTertiary)

                    HStack(spacing: ClaritySpacing.xs) {
                        Circle().fill(safeToSpendColor).frame(width: 8, height: 8)
                        Text(safeToSpendStatusText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.textSecondary)
                    }
                    .padding(.top, ClaritySpacing.xs)

                    // A quiet, secondary caveat — see CLARITY_HOME_SPEC.md §5/§20: V1 is
                    // budget-position only, so the label must not imply forward-looking
                    // awareness (upcoming bills) it doesn't have. Never the primary message.
                    Text("Based on this period's budget")
                        .font(.footnote)
                        .foregroundStyle(.textTertiary)
                } else {
                    Text("Set a budget to see what's safe to spend")
                        .font(.subheadline)
                        .foregroundStyle(.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, ClaritySpacing.xs)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .surface(.elevated, radius: ClarityRadius.extraLarge, padding: ClaritySpacing.xxxl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(safeToSpendAccessibilityLabel)
        .accessibilityHint("Double tap to view your budget")
    }

    private var safeToSpendAccessibilityLabel: String {
        guard hasBudgetData else { return "Safe to spend: set a budget to see what's safe to spend" }
        return "Safe to spend: \(summary.totalLeft.currencyFormatted), \(safeToSpendStatusText.lowercased())"
    }

    // MARK: - What's Different?

    /// Where a tap on a given insight should land — category/over-plan/pace insights explain
    /// themselves at Plan → Budget; the income insight is a cash-flow fact, closest to Overview's
    /// Income/Expenses card.
    private func handleInsightTap(_ kind: WhatsDifferentKind) {
        selectedTab = kind == .incomeChange ? .overview : .plan
    }

    @ViewBuilder
    private var whatsDifferentSection: some View {
        if !allEntries.isEmpty {
            // `.secondary` tier — a lightweight attention surface, one step down from Safe to
            // Spend's `.elevated` hero and distinct from Net Worth's `.primary` compact card. See
            // CLARITY_HOME_VISUAL_SPEC.md §5.
            SectionCard(tier: .secondary) {
                VStack(alignment: .leading, spacing: ClaritySpacing.md) {
                    Text("What's Different?")
                        .font(.sectionTitle)
                        .foregroundStyle(.textSecondary)

                    if whatsDifferentInsights.isEmpty {
                        Text("Nothing stands out this period")
                            .font(.subheadline)
                            .foregroundStyle(.textTertiary)
                    } else {
                        VStack(alignment: .leading, spacing: ClaritySpacing.sm) {
                            ForEach(whatsDifferentInsights) { insight in
                                Button {
                                    handleInsightTap(insight.kind)
                                } label: {
                                    WhatsDifferentRow(insight: insight)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Upcoming

    @ViewBuilder
    private var upcomingSection: some View {
        if !upcomingItems.isEmpty {
            // Same `.secondary` lightweight-surface tier as What's Different — both occupy the
            // SECONDARY hierarchy tier per CLARITY_HOME_SPEC.md §2 and should share one visual
            // weight. See CLARITY_HOME_VISUAL_SPEC.md §6.
            SectionCard(tier: .secondary) {
                VStack(alignment: .leading, spacing: ClaritySpacing.md) {
                    Text("Upcoming")
                        .font(.sectionTitle)
                        .foregroundStyle(.textSecondary)

                    VStack(spacing: ClaritySpacing.sm) {
                        ForEach(Array(upcomingItems.prefix(HomeCalculator.maxUpcomingItems))) { item in
                            Button {
                                selectedTab = .shared
                            } label: {
                                UpcomingRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if upcomingItems.count > HomeCalculator.maxUpcomingItems {
                        Button("See all") {
                            selectedTab = .shared
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.emerald)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Financial Snapshot

    /// Deliberately no `SectionCard`/surface — three numbers with a self-evident relationship
    /// don't need a bounding box to read as a group; a hairline divider under the header is
    /// enough separation. See CLARITY_HOME_VISUAL_SPEC.md §7.
    @ViewBuilder
    private var financialSnapshotSection: some View {
        if !monthEntries.isEmpty {
            Button {
                selectedTab = .overview
            } label: {
                VStack(alignment: .leading, spacing: ClaritySpacing.sm) {
                    Text("Financial Snapshot")
                        .font(.sectionTitle)
                        .foregroundStyle(.textSecondary)

                    Rectangle()
                        .fill(Color.surfaceSecondary)
                        .frame(height: 1)

                    HStack {
                        FinancialMetric(title: "Income", value: snapshotIncome.currencyFormattedSummary, color: .income)
                        FinancialMetric(title: "Expenses", value: snapshotExpenses.currencyFormattedSummary, color: .expense)
                        FinancialMetric(title: "Net", value: snapshotNet.currencyFormattedSummary, color: snapshotNet >= 0 ? .textPrimary : .expense)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Net Worth

    @ViewBuilder
    private var netWorthSection: some View {
        if !activeWallets.isEmpty {
            Button {
                selectedTab = .more
            } label: {
                // `.primary` tier (the default, dimmest surface) with tighter `lg` padding — a
                // compact card, one step down from What's Different/Upcoming's `.secondary`
                // tier and well below Safe to Spend's `.elevated` hero. See
                // CLARITY_HOME_VISUAL_SPEC.md §8.
                SectionCard(padding: ClaritySpacing.lg) {
                    VStack(alignment: .leading, spacing: ClaritySpacing.sm) {
                        Text("Net Worth")
                            .font(.sectionTitle)
                            .foregroundStyle(.textSecondary)
                        Text(netWorth.currencyFormattedSummary)
                            .heroAmountStyle()
                            .foregroundStyle(netWorth < 0 ? Color.expense : Color.textPrimary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Net worth: \(netWorth.currencyFormattedSummary)")
        }
    }

    // MARK: - Forecast preview

    private var forecastText: String {
        switch forecastState {
        case .insufficientData: "Not enough data yet this period"
        case .onTrack: "Tracking close to plan this period"
        case .aheadOfPace: "Spending faster than usual this period"
        }
    }

    /// No `SectionCard`/surface — one informational sentence doesn't need a box, and a card
    /// here would overstate a same-period pace comparison as more substantial than it is. See
    /// CLARITY_HOME_VISUAL_SPEC.md §9. Not tappable — Plan → Forecast doesn't exist yet, and a
    /// chevron/tap target would be a broken affordance.
    private var forecastSection: some View {
        VStack(alignment: .leading, spacing: ClaritySpacing.xs) {
            Text("Forecast")
                .font(.sectionTitle)
                .foregroundStyle(.textSecondary)
            Text(forecastText)
                .font(.subheadline)
                .foregroundStyle(.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

}

// MARK: - Row subviews

private struct WhatsDifferentRow: View {
    let insight: WhatsDifferentInsight

    private var deltaText: String {
        if let magnitude = insight.magnitudeFraction {
            return magnitude.formatted(.percent.precision(.fractionLength(0)))
        }
        switch insight.kind {
        case .overPace: return "Ahead of pace"
        case .overPlan: return "Over plan"
        case .categoryChange, .incomeChange: return ""
        }
    }

    private var message: String {
        switch insight.kind {
        case .categoryChange:
            let comparison = insight.direction == .up ? "higher" : "lower"
            return "\(insight.subject) is \(deltaText) \(comparison) than last month"
        case .incomeChange:
            let comparison = insight.direction == .up ? "higher" : "lower"
            return "Income is \(deltaText) \(comparison) than last month"
        case .overPace:
            return "You're on pace to exceed this period's budget"
        case .overPlan:
            return "\(insight.subject) is over its planned budget this period"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: ClaritySpacing.sm) {
            DeltaIndicator(
                delta: deltaText,
                direction: insight.direction == .up ? .up : .down,
                isFavorable: insight.isFavorable
            )
            Text(message)
                .font(.body)
                .foregroundStyle(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

private struct UpcomingRow: View {
    let item: UpcomingSharedBalance

    private var color: Color { item.event.colorHex.map { Color(hex: $0) } ?? .skyBlue }

    var body: some View {
        HStack(spacing: ClaritySpacing.md) {
            ZStack {
                Circle().fill(color.opacity(0.18))
                Image(systemName: item.event.icon ?? "person.2.fill")
                    .foregroundStyle(color)
                    .font(.subheadline)
            }
            .frame(width: 32, height: 32)

            Text(item.event.title)
                .font(.body)
                .foregroundStyle(.textPrimary)
                .lineLimit(1)

            Spacer()

            CurrencyValue(
                amount: abs(item.amount).currencyFormatted,
                kind: item.amount > 0 ? .income : .expense
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(item.event.title), \(item.amount > 0 ? "you are owed" : "you owe") \(abs(item.amount).currencyFormatted)"
        )
    }
}

#Preview {
    HomeView(selectedTab: .constant(.home))
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self, Person.self, SharedEvent.self], inMemory: true)
}
