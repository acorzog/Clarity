import SwiftUI
import SwiftData

/// A smaller hero-number style for Home's cards specifically — Home packs more cards on screen
/// than any other tab, so it uses this instead of the shared `heroAmountStyle()` (34pt, used by
/// Net Worth here and elsewhere in the app) to keep everything visible without scrolling on
/// smaller phones. Not a Design System token change — just a Home-local compactness choice.
private struct CompactHeroAmountStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 32, weight: .bold))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
    }
}

/// A `SectionCard`-equivalent surface with a low-opacity color wash layered over the standard
/// `surfaceSecondary` tier, so each Home card can carry its own accent identity (emerald for Safe
/// to Spend, sky blue for Clarity Score, mint for What's Different — all within the app's
/// existing green/blue accent range) while still sitting on the same flat, no-shadow surface
/// treatment (`CLARITY_DESIGN_SYSTEM.md` §10) as every other card in the app — the wash is a
/// translucent overlay, not a replacement color system.
private struct TintedSurfaceModifier: ViewModifier {
    var tint: Color
    var radius: CGFloat
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.surfaceSecondary)
                    .overlay(RoundedRectangle(cornerRadius: radius).fill(tint.opacity(0.08)))
            )
    }
}

private extension View {
    func compactHeroAmountStyle() -> some View {
        modifier(CompactHeroAmountStyle())
    }

    func claritySurface(tint: Color, radius: CGFloat = ClarityRadius.large, padding: CGFloat = ClaritySpacing.lg) -> some View {
        modifier(TintedSurfaceModifier(tint: tint, radius: radius, padding: padding))
    }
}

/// Clarity's "Understand" surface — see `CLARITY_HOME_SPEC.md`. Composes already-computed
/// values from `BudgetCalculator`, `HomeCalculator`, `NetWorthCalculator`, and
/// `ClarityScoreCalculator`; performs no financial calculation of its own (`CLARITY_HOME_SPEC.md`
/// §17/§13 — "HomeView must NOT become a calculation layer").
struct HomeView: View {
    /// Lets a Home section switch tabs on tap — the closest existing navigation behavior. Home's
    /// drill-downs land on each destination tab's root, not a specific sub-tab or scroll
    /// position: that would require converting `OverviewView`/`BudgetContentView`'s sub-tab
    /// state from view-local `@State` to an externally-driven `@Binding`, which is a larger
    /// change than this phase's "small, local changes" discipline allows. Documented as a known
    /// limitation rather than silently worked around.
    @Binding var selectedTab: MainTab

    @Environment(\.modelContext) private var modelContext
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
        if safeToSpendRatio > 1 { return "Over budget" }
        if safeToSpendRatio >= 0.85 { return "Getting close to budget" }
        return "On track"
    }

    private var periodRangeText: String {
        let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: summary.period.end) ?? summary.period.end
        return "Through \(lastDay.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private var clarityScoreResult: ClarityScoreResult {
        ClarityScoreCalculator.clarityScore(entries: allEntries, budgets: allBudgets, headCategories: headCategories)
    }

    private var whatsDifferentInsights: [WhatsDifferentInsight] {
        HomeCalculator.whatsDifferentInsights(
            month: month, entries: allEntries, budgets: allBudgets, headCategories: headCategories,
            settings: calculationSettings
        )
    }

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
                VStack(alignment: .leading, spacing: ClaritySpacing.lg) {
                    header
                        .padding(.bottom, ClaritySpacing.xs)
                    safeToSpendSection
                    clarityScoreSection
                    whatsDifferentSection
                    upcomingSection
                }
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .readableContentWidth()
            }
            .refreshable { await DataSyncService.refresh(modelContext) }
            .darkScreenBackground()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: ClaritySpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.subheadline)
                    .foregroundStyle(.textSecondary)
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.textPrimary)

                if isEffectivelyEmpty {
                    Text("Add a transaction or two, and Home will start filling in.")
                        .font(.footnote)
                        .foregroundStyle(.textTertiary)
                        .padding(.top, ClaritySpacing.xs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            NavigationLink {
                AskClarityView()
            } label: {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.title3)
                    .foregroundStyle(LinearGradient.emeraldSky)
                    .frame(width: 44, height: 44)
                    .background(Color.surfaceSecondary, in: Circle())
            }
            .accessibilityLabel("Ask Clarity")
            .accessibilityHint("Double tap to start a conversation about your finances")
        }
    }

    // MARK: - Safe to Spend (hero)

    /// Fraction of `totalAvailable` spent, clamped to `0...1` for the progress bar's fill width —
    /// `safeToSpendRatio` itself is allowed to exceed 1 (over budget), but a bar can't render past
    /// its own track.
    private var safeToSpendProgress: Double {
        min(max(safeToSpendRatio, 0), 1)
    }

    private var spentPercentText: String {
        guard summary.totalAvailable > 0 else { return "0%" }
        return safeToSpendRatio.formatted(.percent.precision(.fractionLength(0)))
    }

    private var leftPercentText: String {
        guard summary.totalAvailable > 0 else { return "0%" }
        return max(1 - safeToSpendRatio, 0).formatted(.percent.precision(.fractionLength(0)))
    }

    private var safeToSpendPerDay: Decimal? {
        HomeCalculator.averageDailyAllowance(totalLeft: summary.totalLeft, periodEnd: summary.period.end)
    }

    private var safeToSpendSection: some View {
        Button {
            selectedTab = .plan
        } label: {
            VStack(alignment: .leading, spacing: ClaritySpacing.md) {
                HStack(spacing: ClaritySpacing.sm) {
                    ZStack {
                        Circle().fill(Color.income.opacity(0.18))
                        Image(systemName: "wallet.bifold.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color.income)
                    }
                    .frame(width: 28, height: 28)

                    Text("SAFE TO SPEND")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.5)
                        .foregroundStyle(.textSecondary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.textTertiary)
                }

                if hasBudgetData {
                    HStack(alignment: .top, spacing: ClaritySpacing.sm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.totalLeft.currencyFormatted)
                                .compactHeroAmountStyle()
                                .foregroundStyle(summary.totalLeft < 0 ? Color.expense : Color.textPrimary)

                            Text(periodRangeText)
                                .font(.caption2)
                                .foregroundStyle(.textTertiary)
                        }

                        Spacer(minLength: ClaritySpacing.sm)

                        if let safeToSpendPerDay {
                            VStack(spacing: 2) {
                                HStack(spacing: 4) {
                                    Image(systemName: "calendar")
                                        .font(.caption2)
                                    Text("≈ \(safeToSpendPerDay.currencyFormattedSummary)")
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(.textPrimary)
                                Text("per day")
                                    .font(.caption2)
                                    .foregroundStyle(.textTertiary)
                            }
                            .padding(.horizontal, ClaritySpacing.sm)
                            .padding(.vertical, ClaritySpacing.sm)
                            .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: ClarityRadius.medium))
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("About \(safeToSpendPerDay.currencyFormattedSummary) available per day")
                        }
                    }

                    HStack(spacing: ClaritySpacing.xs) {
                        Circle().fill(safeToSpendColor).frame(width: 7, height: 7)
                        Text(safeToSpendStatusText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.textSecondary)
                        // A quiet, secondary caveat — see CLARITY_HOME_SPEC.md §5/§20: V1 is
                        // budget-position only, so this must not imply forward-looking awareness
                        // (upcoming bills) it doesn't have. Never the primary message; kept on the
                        // same line as the status dot to stay out of the way visually.
                        Text("· Based on this period's budget")
                            .font(.caption2)
                            .foregroundStyle(.textTertiary)
                            .lineLimit(1)
                    }

                    ClarityProgressBar(progress: safeToSpendProgress, color: safeToSpendColor)
                        .padding(.top, 2)

                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(summary.totalSpent.currencyFormattedSummary) spent")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.textPrimary)
                            Text("\(spentPercentText) of \(summary.totalAvailable.currencyFormattedSummary)")
                                .font(.caption2)
                                .foregroundStyle(.textTertiary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(summary.totalLeft.currencyFormattedSummary) left")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.textPrimary)
                            Text("\(leftPercentText) remaining")
                                .font(.caption2)
                                .foregroundStyle(.textTertiary)
                        }
                    }
                } else {
                    Text("Set a budget to see what's safe to spend")
                        .font(.subheadline)
                        .foregroundStyle(.textSecondary)
                        .padding(.top, ClaritySpacing.xs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .claritySurface(tint: .income, radius: ClarityRadius.large, padding: ClaritySpacing.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(safeToSpendAccessibilityLabel)
        .accessibilityHint("Double tap to view your budget")
    }

    private var safeToSpendAccessibilityLabel: String {
        guard hasBudgetData else { return "Safe to spend: set a budget to see what's safe to spend" }
        return "Safe to spend: \(summary.totalLeft.currencyFormatted), \(safeToSpendStatusText.lowercased())"
    }

    // MARK: - Clarity Score

    private var clarityScoreTrendBadge: (delta: String, direction: DeltaIndicator.Direction, isFavorable: Bool?)? {
        switch clarityScoreResult.trend {
        case .up: ("+\(clarityScoreResult.pointsChange ?? 0)", .up, true)
        case .down: ("\(clarityScoreResult.pointsChange ?? 0)", .down, false)
        case .stable: ("±0", .flat, nil)
        case .notEnoughHistory: nil
        }
    }

    /// Builds the actual phrasing for a factor from its raw data — `ClarityScoreCalculator`
    /// deliberately returns numbers, not sentences, so this (and not the calculator) owns the
    /// wording, matching `WhatsDifferentRow.message`'s split of data vs. phrasing.
    private func clarityScoreFactorTitle(_ factor: ClarityScoreFactor) -> String {
        let percent = factor.magnitudeFraction.formatted(.percent.precision(.fractionLength(0)))
        return switch factor.kind {
        case .budgetPace: factor.isFavorable ? "\(percent) under your weekly budget pace" : "\(percent) over your weekly budget pace"
        case .previousWeek: factor.isFavorable ? "\(percent) lower than last week" : "\(percent) higher than last week"
        case .typicalWeek: factor.isFavorable ? "\(percent) below your typical week" : "\(percent) above your typical week"
        case .monthOverMonth: factor.isFavorable ? "\(percent) lower than this point last month" : "\(percent) higher than this point last month"
        }
    }

    /// Short (1-2 word) label for the compact factor strip beneath the score — the sentence-level
    /// phrasing belongs to `clarityScoreFactorTitle`/`clarityScoreSummary` above; this exists only
    /// so `clarityScoreFactorsStrip` can lay out a percent + label pair per factor without
    /// truncating a full sentence.
    private func clarityScoreFactorShortLabel(_ factor: ClarityScoreFactor) -> String {
        switch factor.kind {
        case .budgetPace: "budget pace"
        case .previousWeek: "last week"
        case .typicalWeek: "typical week"
        case .monthOverMonth: "last month"
        }
    }

    /// True once the score reflects at least one real comparison — either a factor that actually
    /// contributed this week, or a genuine week-ago score to compare against (which itself
    /// requires real spend data at that anchor, not just a budget's existence — see
    /// `ClarityScoreCalculator.snapshot`). False only for the plain `baselineScore` default with
    /// zero comparisons available (e.g. a brand-new user's very first days), which must not be
    /// shown as if it were an actual measure of financial health.
    private var clarityScoreHasSignal: Bool {
        !clarityScoreResult.factors.isEmpty || clarityScoreResult.trend != .notEnoughHistory
    }

    private var clarityScoreSummary: String {
        guard clarityScoreResult.score != nil else {
            return "Log a few expenses this week to start seeing your Clarity Score."
        }
        guard clarityScoreHasSignal else {
            return "Your Clarity Score will get more precise as you add more transaction history."
        }
        guard let topFactor = clarityScoreResult.factors.first else {
            return "Spending is right in line with your usual pattern."
        }
        let trendPhrase = switch clarityScoreResult.trend {
        case .up: "Your score improved this week"
        case .down: "Your score dipped this week"
        case .stable: "Your score held steady this week"
        case .notEnoughHistory: "Here's your Clarity Score"
        }
        return "\(trendPhrase) — \(clarityScoreFactorTitle(topFactor))."
    }

    private var clarityScoreAccessibilityLabel: String {
        guard let score = clarityScoreResult.score, clarityScoreHasSignal else {
            return "Clarity Score. \(clarityScoreSummary)"
        }
        return "Clarity Score: \(score) out of 100, \(clarityScoreTierLabel ?? ""). \(clarityScoreSummary)"
    }

    /// A coarse, presentation-only reading of the 0-100 score — same "the view owns the wording,
    /// not the calculator" split as `clarityScoreFactorTitle` above. Deliberately simple (3
    /// buckets); this is a glance-level label, not a new scoring system.
    private var clarityScoreTierLabel: String? {
        guard let score = clarityScoreResult.score, clarityScoreHasSignal else { return nil }
        switch score {
        case 70...: return "Good"
        case 40..<70: return "Fair"
        default: return "Needs focus"
        }
    }

    private var clarityScoreTierColor: Color {
        guard let score = clarityScoreResult.score else { return .textSecondary }
        switch score {
        case 70...: return .income
        case 40..<70: return .warning
        default: return .expense
        }
    }

    private var clarityScoreSection: some View {
        VStack(alignment: .leading, spacing: ClaritySpacing.md) {
            HStack(spacing: ClaritySpacing.sm) {
                ZStack {
                    Circle().fill(Color.skyBlue.opacity(0.18))
                    Image(systemName: "chart.bar.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.skyBlue)
                }
                .frame(width: 32, height: 32)

                Text("CLARITY SCORE")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.textSecondary)

                Spacer()

                if let badge = clarityScoreTrendBadge {
                    DeltaIndicator(delta: badge.delta, direction: badge.direction, isFavorable: badge.isFavorable)
                }
            }

            if let score = clarityScoreResult.score, clarityScoreHasSignal {
                HStack(alignment: .center, spacing: ClaritySpacing.sm) {
                    Text("\(score)")
                        .compactHeroAmountStyle()
                        .foregroundStyle(.textPrimary)

                    if let clarityScoreTierLabel {
                        Text(clarityScoreTierLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(clarityScoreTierColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(clarityScoreTierColor.opacity(0.16), in: Capsule())
                    }
                }
            }

            Text(clarityScoreSummary)
                .font(.caption)
                .foregroundStyle(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !clarityScoreResult.factors.isEmpty {
                Rectangle()
                    .fill(Color.surfaceSecondary)
                    .frame(height: 1)

                HStack(alignment: .top, spacing: ClaritySpacing.md) {
                    ForEach(clarityScoreResult.factors) { factor in
                        VStack(alignment: .leading, spacing: 1) {
                            DeltaIndicator(
                                delta: factor.magnitudeFraction.formatted(.percent.precision(.fractionLength(0))),
                                direction: factor.isFavorable ? .down : .up,
                                isFavorable: factor.isFavorable
                            )
                            Text(clarityScoreFactorShortLabel(factor))
                                .font(.caption2)
                                .foregroundStyle(.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(clarityScoreFactorTitle(factor))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .claritySurface(tint: .skyBlue, padding: ClaritySpacing.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(clarityScoreAccessibilityLabel)
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
            VStack(alignment: .leading, spacing: ClaritySpacing.md) {
                HStack(spacing: ClaritySpacing.sm) {
                    ZStack {
                        Circle().fill(Color.indigo.opacity(0.18))
                        Image(systemName: "questionmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color.indigo)
                    }
                    .frame(width: 32, height: 32)

                    Text("WHAT'S DIFFERENT?")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.5)
                        .foregroundStyle(.textSecondary)

                    Spacer()

                    if !whatsDifferentInsights.isEmpty {
                        NavigationLink {
                            // `InsightsView`'s own body is a bare `VStack` — it expects to sit
                            // inside a scrolling container, matching every other pushed detail
                            // screen in the app (e.g. `GoalDetailView`). Pushing it bare here
                            // previously froze the screen: `.darkScreenBackground()`'s
                            // `.ignoresSafeArea()` + fixed frame with no `ScrollView` above it
                            // left content stuck with no way to reach what scrolled off-screen.
                            ScrollView {
                                InsightsView(month: month)
                            }
                            .darkScreenBackground()
                            .navigationTitle("Insights")
                        } label: {
                            HStack(spacing: 2) {
                                Text("See all")
                                Image(systemName: "chevron.right")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.emerald)
                        }
                    }
                }

                if whatsDifferentInsights.isEmpty {
                    Text("Nothing stands out this period")
                        .font(.subheadline)
                        .foregroundStyle(.textTertiary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(whatsDifferentInsights.enumerated()), id: \.element.id) { index, insight in
                            if index > 0 {
                                Rectangle()
                                    .fill(Color.surfaceSecondary)
                                    .frame(height: 1)
                                    .padding(.leading, 44)
                            }
                            Button {
                                handleInsightTap(insight.kind)
                            } label: {
                                WhatsDifferentRow(insight: insight)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, ClaritySpacing.xs)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .claritySurface(tint: .indigo, padding: ClaritySpacing.md)
        }
    }

    // MARK: - Upcoming

    @ViewBuilder
    private var upcomingSection: some View {
        if !upcomingItems.isEmpty {
            // Same `.secondary` lightweight-surface tier as What's Different — both occupy the
            // SECONDARY hierarchy tier per CLARITY_HOME_SPEC.md §2 and should share one visual
            // weight. See CLARITY_HOME_VISUAL_SPEC.md §6.
            SectionCard(tier: .secondary, padding: ClaritySpacing.lg) {
                VStack(alignment: .leading, spacing: ClaritySpacing.sm) {
                    Text("Upcoming")
                        .font(.sectionTitle)
                        .foregroundStyle(.textSecondary)

                    VStack(spacing: ClaritySpacing.sm) {
                        ForEach(Array(upcomingItems.prefix(HomeCalculator.maxUpcomingItems))) { item in
                            Button {
                                selectedTab = .more
                            } label: {
                                UpcomingRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if upcomingItems.count > HomeCalculator.maxUpcomingItems {
                        Button("See all") {
                            selectedTab = .more
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.emerald)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }


}

// MARK: - Row subviews

/// The linear budget-progress track shown inside Safe to Spend — a thin, flat capsule (no
/// shadow/glow, matching `CLARITY_DESIGN_SYSTEM.md` §10's "no `.shadow(...)` calls" rule).
/// Presentation-only: takes an already-clamped `0...1` fraction and a color the caller derives
/// from `GaugeThreshold`, so it can never disagree with the status dot/text next to it.
private struct ClarityProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.surfaceElevated)
                Capsule().fill(color)
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 8)
    }
}

private struct WhatsDifferentRow: View {
    let insight: WhatsDifferentInsight

    /// Falls back to `.info` (the shared "neutral highlight" token) for `.incomeChange`/
    /// `.overPace`, which aren't tied to a single category and so have no category color.
    private var color: Color {
        insight.headCategory.map { Color(hex: $0.colorHex) } ?? .info
    }

    private var iconName: String {
        insight.headCategory?.icon ?? (insight.kind == .incomeChange ? "banknote.fill" : "gauge.with.needle.fill")
    }

    private var title: String {
        insight.subject.isEmpty ? "Budget pace" : insight.subject
    }

    private var statusText: String {
        switch insight.kind {
        case .categoryChange, .incomeChange:
            return insight.direction == .up ? "Higher than last month" : "Lower than last month"
        case .overPlan:
            return "Over plan"
        case .overPace:
            return "You're on pace to exceed this period's budget"
        }
    }

    private var amountText: String? {
        guard let amount = insight.amountDifference else { return nil }
        return "\(amount >= 0 ? "+" : "-")\(abs(amount).currencyFormattedSummary)"
    }

    private var percentText: String? {
        insight.magnitudeFraction.map { $0.formatted(.percent.precision(.fractionLength(0))) }
    }

    private var accessibilityLabel: String {
        [title, statusText, amountText, percentText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: ClaritySpacing.md) {
            ZStack {
                Circle().fill(color.opacity(0.18))
                Image(systemName: iconName)
                    .foregroundStyle(color)
                    .font(.caption)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.textPrimary)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: ClaritySpacing.sm)

            VStack(alignment: .trailing, spacing: 2) {
                if let amountText {
                    Text(amountText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(insight.isFavorable == true ? Color.income : Color.expense)
                }
                if let percentText {
                    DeltaIndicator(
                        delta: percentText,
                        direction: insight.direction == .up ? .up : .down,
                        isFavorable: insight.isFavorable
                    )
                } else if insight.kind == .overPace {
                    Text("Ahead of pace")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.warning)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
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
