import SwiftUI
import SwiftData
import Charts

/// The expanded "Explain My Month" screen — reachable from Overview's entry banner and Home's
/// Clarity Score card alike. Always opens on the real current month (never a month-selection
/// screen first); tapping a bar in the Total Spending trend chart changes the month from right
/// there, and every section below reacts to that `@State`. Nothing here is a new calculation — every section reuses
/// the exact same calculator (`ExplainMyMonthCalculator`, `OverviewCalculator`) and, where
/// possible, the exact same row/card views the summary cards already render, so this can never
/// disagree with either of them. The Clarity Score breakdown itself lives only on Home's own card
/// now (not duplicated here). The "Ask AI" section at the bottom reuses the existing Ask Clarity
/// engine/Anthropic provider (`MonthAskClarityController`) rather than a second AI integration.
struct MonthInsightsDetailView: View {
    @State private var selectedMonth: Date
    @StateObject private var askController = MonthAskClarityController()

    /// The trend chart's own x-axis position — set once (to show the most recent months) and never
    /// written to again by anything in this view. Deliberately decoupled from `selectedMonth`: the
    /// chart's visible window must never jump/re-center itself just because a bar was tapped, only
    /// in response to the person's own manual scroll gesture on the chart itself.
    @State private var chartScrollPosition: Date
    /// `.chartXSelection`'s own binding — a raw tapped x-value, immediately resolved to the actual
    /// `MonthlySpendPoint` it landed on and applied to `selectedMonth` below; never read elsewhere.
    @State private var tappedMonth: Date?
    /// `true` for the brief window between picking a new month and that month's figures actually
    /// being on screen — every section below (`explanation`) re-runs its
    /// calculator over the full local dataset synchronously, so this isn't cosmetic: for someone
    /// with years of transactions
    /// that recompute is real, main-thread work, and this is what keeps the tap feeling
    /// acknowledged instead of frozen while it runs. See `changeMonth(to:)`.
    @State private var isChangingMonth = false
    @State private var monthChangeTask: Task<Void, Never>?
    /// Drives `exploreCategoryInsightsButton`'s push — see that property's doc comment for why
    /// this isn't a closure-based `NavigationLink` instead.
    @State private var showCategoryInsights = false

    @ObservedObject private var budgetSettings = BudgetSettingsStore.shared
    @Query(filter: #Predicate<Entry> { !$0.isSoftDeleted }, sort: \Entry.date, order: .reverse) private var allEntries: [Entry]
    @Query private var allBudgets: [Budget]
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]

    /// Defaults to the real current month — the one initial-state rule this screen enforces
    /// regardless of caller (per its own design: no separate month-selection screen, always opens
    /// "now"). A caller may still pass a different starting point (used by the `#Preview` below,
    /// and available to tests), but every production call site (`ExplainMyMonthCardView`,
    /// `HomeView`'s Clarity Score card) intentionally omits it.
    init(month: Date = .startOfMonth()) {
        _selectedMonth = State(initialValue: month)
        // The chart's visible window is exactly as wide as `trend` itself (the latest 6 months —
        // see `chartXVisibleDomain` below), so every bar `trend` produces is on screen at once,
        // left-aligned at the oldest one. Matching the two ranges exactly means there's never
        // anything to scroll past in normal use — the "future disappears" problem a *narrower*
        // scrollable window created (an earlier version let scrolling left to an older month push
        // the current month's bar off the right edge) can't happen here, with no auto-recentering
        // needed either (which would itself violate "never scroll except by the person's own
        // gesture").
        let defaultScrollStart = Calendar.current.date(byAdding: .month, value: -5, to: .startOfMonth()) ?? .startOfMonth()
        _chartScrollPosition = State(initialValue: defaultScrollStart)
    }

    private var calculationSettings: BudgetCalculationSettings {
        BudgetCalculationSettings(from: budgetSettings)
    }

    private var explanation: MonthExplanation {
        ExplainMyMonthCalculator.explain(
            month: selectedMonth, entries: allEntries, budgets: allBudgets, headCategories: headCategories,
            settings: calculationSettings
        )
    }

    /// The budget-eligible entries behind a category's spend this month — mirrors
    /// `RemainingView.entries(for:)` exactly, so a drill-down from a notable-change row never
    /// shows an entry the total above it didn't actually count.
    private func entries(for category: Category) -> [Entry] {
        allEntries
            .inBudgetPeriod(selectedMonth, startDay: budgetSettings.cycleStartDay)
            .budgetEligible
            .filter { $0.type == .expense && $0.category === category }
    }

    /// The last 6 calendar months' totals, oldest first, anchored to the real current month — NOT
    /// to `selectedMonth`. Each total is the same `periodSpendingSummary` figure every other spend
    /// number in the app already uses, not a separate aggregation. Anchoring to the real "now"
    /// (rather than sliding the window to end at whatever's selected) is what keeps the chart's own
    /// bars in the exact same place no matter which one is tapped — see `chartScrollPosition`'s doc
    /// comment for why that stability matters here.
    private var trend: [MonthlySpendPoint] {
        let anchor = Date.startOfMonth()
        return (0..<6).reversed().compactMap { offset in
            guard let pointMonth = Calendar.current.date(byAdding: .month, value: -offset, to: anchor) else { return nil }
            let total = BudgetCalculator.periodSpendingSummary(
                month: pointMonth, entries: allEntries, budgets: allBudgets, headCategories: headCategories,
                settings: calculationSettings, respectHiddenCategories: true
            ).totalSpent
            return MonthlySpendPoint(month: Date.startOfMonth(for: pointMonth), total: total)
        }
    }

    /// A given `trend`'s real calendar-day span, oldest bar's month start to one month past the
    /// newest — used as `trendChart`'s `chartXVisibleDomain` instead of a fixed "30 days × 6"
    /// constant. Real calendar months are 28–31 days each, so that fixed approximation never
    /// exactly matched `trend`'s actual bar positions; the tiny mismatch made Swift Charts
    /// perpetually "correct" `chartScrollPosition` (a two-way `@State` binding) by a few seconds
    /// every single frame, each correction re-triggering `body` → recomputing `trend` →
    /// re-rendering the chart → a new slightly-different "correct" position, forever. Invisible
    /// with a handful of entries (each loop iteration too cheap to notice); with a real account's
    /// data (~100+ entries) that became a genuine, measured, perpetual main-thread loop —
    /// reproduced directly, not a symptom of any specific button, screen, or sync activity.
    /// Computing the exact span removes the mismatch this fed on, not just the speed of resolving
    /// it. Takes `trend` as a parameter (rather than reading the computed property again) so
    /// `trendChart` only ever computes `trend` itself once per render.
    private func trendDomainSeconds(for trend: [MonthlySpendPoint]) -> TimeInterval {
        guard let first = trend.first?.month, let last = trend.last?.month,
              let domainEnd = Calendar.current.date(byAdding: .month, value: 1, to: last)
        else { return 3600 * 24 * 30 * 6 }
        return domainEnd.timeIntervalSince(first)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ClaritySpacing.lg) {
            totalSpendingCard

            if isChangingMonth {
                monthLoadingPlaceholder
            } else {
                if explanation.hasActivity {
                    highlightsCard
                    exploreCategoryInsightsButton
                }

                askAICard
            }
        }
        .padding(.horizontal)
        .padding(.vertical, ClaritySpacing.lg)
        .animation(.default, value: selectedMonth)
        .animation(.easeInOut(duration: 0.15), value: isChangingMonth)
        .onChange(of: tappedMonth) { _, newValue in
            guard let newValue, let matched = trend.first(where: { Calendar.current.isDate($0.month, equalTo: newValue, toGranularity: .month) }) else { return }
            changeMonth(to: matched.month)
        }
        // Attached here (the one always-present root), not on `exploreCategoryInsightsButton`
        // itself — that button only exists `if explanation.hasActivity`, and `explanation` is
        // `@Query`-backed (re-evaluates on every background sync save). A sync pass landing in
        // the same instant as the tap could flip `hasActivity` and unmount the button — and the
        // `.navigationDestination` modifier riding on it — while `showCategoryInsights` was still
        // true, which is exactly the state SwiftUI's navigation system can hang on.
        .navigationDestination(isPresented: $showCategoryInsights) {
            ScrollView {
                InsightsView(month: selectedMonth, allEntries: allEntries, allBudgets: allBudgets, headCategories: headCategories)
            }
            .darkScreenBackground()
            .navigationTitle("Insights")
        }
    }

    /// Switches `selectedMonth` in two steps rather than one direct assignment, so the loading
    /// state actually gets a chance to reach the screen first: setting `isChangingMonth = true`
    /// alone (cheap — nothing month-dependent below is even evaluated while it's true) commits on
    /// its own render pass, *then* `Task.yield()` hands control back to the run loop so SwiftUI
    /// draws that frame, and only after that does `selectedMonth` actually change, triggering the
    /// real (synchronous, but now off the critical path of "did my tap register") recompute.
    /// Re-tapping a different bar mid-transition cancels the still-pending change rather than
    /// stacking two, so the screen always ends up showing whichever month was tapped last.
    private func changeMonth(to newMonth: Date) {
        guard !Calendar.current.isDate(newMonth, equalTo: selectedMonth, toGranularity: .month) else { return }
        monthChangeTask?.cancel()
        isChangingMonth = true
        monthChangeTask = Task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            // A month change invalidates any answer the Ask AI box is showing — it was about the
            // *previous* selected month and would otherwise sit there looking like it still applies.
            askController.reset()
            selectedMonth = newMonth
            isChangingMonth = false
        }
    }

    private var monthLoadingPlaceholder: some View {
        HStack(spacing: ClaritySpacing.sm) {
            ProgressView()
                .tint(.white)
            Text("Updating \(selectedMonth.formatted(.dateTime.month(.wide)))…")
                .font(.subheadline)
                .foregroundStyle(.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ClaritySpacing.xxxl)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Total Spending

    private var totalSpendingCard: some View {
        VStack(alignment: .leading, spacing: ClaritySpacing.md) {
            HStack(spacing: ClaritySpacing.sm) {
                ZStack {
                    Circle().fill(Color.skyBlue.opacity(0.18))
                    Image(systemName: "chart.bar.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.skyBlue)
                }
                .frame(width: 32, height: 32)

                Text("TOTAL SPENDING")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.textSecondary)

                Spacer()

                // Replaces the old prev/next `MonthSelector` row — the selected month is now
                // changed by tapping a bar in the chart below, so this is a plain label, not a
                // control.
                Text(selectedMonth.formatted(.dateTime.month(.wide).year()))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.textSecondary)
            }

            if explanation.hasActivity {
                Text(explanation.totalSpending.currencyFormatted)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.textPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                if let comparison = explanation.previousMonthComparison {
                    TrendIndicator(
                        delta: abs(comparison.fraction).formatted(.percent.precision(.fractionLength(0))),
                        direction: comparison.direction == .up ? .up : .down,
                        isFavorable: comparison.direction == .down,
                        context: "vs. last month (\(comparison.previousTotal.currencyFormatted))"
                    )
                } else {
                    Text("Not enough history yet to compare to last month")
                        .font(.caption)
                        .foregroundStyle(.textTertiary)
                }
            } else {
                // No-data state — distinct from "0,00 €", which would otherwise read as a real,
                // unusually frugal month rather than simply no transactions logged yet.
                Text("No spending logged yet")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.textPrimary)
                Text("Once you log a few transactions for \(selectedMonth.formatted(.dateTime.month(.wide))), your summary will appear here.")
                    .font(.caption)
                    .foregroundStyle(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Always shown (not gated on `explanation.hasActivity`/any spend existing) — this is
            // now the *only* way to change the selected month, so hiding it whenever the selected
            // month itself happens to have no spend would strand the person unable to navigate away
            // from an empty month.
            trendChart
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .claritySurface(tint: .skyBlue, radius: ClarityRadius.large, padding: ClaritySpacing.xl)
    }

    /// Tap a bar to select that month (`chartXSelection`, resolved in `body`'s own `onChange`) —
    /// all 6 months `trend` produces are visible at once, so picking an older month never scrolls
    /// the current month's bar out of view. Deliberately never auto-scrolls/re-centers itself when
    /// the selection changes — `chartScrollPosition` is bound to its own `@State` that nothing here
    /// ever writes to after init, so the bars stay exactly where the person left them.
    private var trendChart: some View {
        let trend = trend
        return Chart(trend) { point in
            let isSelected = Calendar.current.isDate(point.month, equalTo: selectedMonth, toGranularity: .month)
            BarMark(
                x: .value("Month", point.month, unit: .month),
                y: .value("Spent", point.total.doubleValue)
            )
            .foregroundStyle(isSelected ? Color.skyBlue : Color.skyBlue.opacity(0.35))
            .cornerRadius(4)
            // Per-mark (not one combined chart-level) accessibility — gives VoiceOver a distinct,
            // swipeable element per month with its own name/value, and (not incidentally) gives
            // UI tests a reliable, non-coordinate-based way to target a specific bar. `isSelected`
            // is read into the label itself since there's no visible focus ring for VoiceOver to
            // otherwise convey which month tapping here would mean "currently showing."
            .accessibilityLabel("\(point.month.formatted(.dateTime.month(.wide).year()))\(isSelected ? ", selected" : "")")
            .accessibilityValue(point.total.currencyFormatted)
        }
        .frame(height: 90)
        .padding(.top, ClaritySpacing.xs)
        .chartXSelection(value: $tappedMonth)
        .chartScrollableAxes(.horizontal)
        // Matches `trend`'s own real calendar-day span exactly (see `trendDomainSeconds`'s own
        // doc comment for why this must be the exact span, not an approximation) — every bar fits
        // on screen with nothing to scroll past in normal use; `chartScrollableAxes` stays on
        // purely so this keeps working if `trend` ever grows beyond 6 months.
        .chartXVisibleDomain(length: trendDomainSeconds(for: trend))
        .chartScrollPosition(x: $chartScrollPosition)
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.narrow))
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .chartYAxis(.hidden)
        .accessibilityHint("Swipe to scroll through months")
    }

    // MARK: - Highlights

    private var highlightsCard: some View {
        VStack(alignment: .leading, spacing: ClaritySpacing.md) {
            Text("Highlights")
                .font(.sectionTitle)
                .foregroundStyle(.textSecondary)

            ExplainMyMonthContent(explanation: explanation, month: selectedMonth, entriesFor: entries(for:))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .claritySurface(tint: .indigo, radius: ClarityRadius.large, padding: ClaritySpacing.xl)
    }

    private var exploreCategoryInsightsButton: some View {
        // A plain `Button` setting `@State` rather than a closure-based `NavigationLink { } label:
        // { }` — this view's `@Query`-backed properties (`allEntries`, `allBudgets`,
        // `headCategories`) can re-evaluate `body` mid-tap while a sync pass lands in the
        // background (see `SyncCoordinator`), which can tear down and rebuild a closure-based
        // `NavigationLink` during its own gesture recognition and silently drop the push. The
        // matching `.navigationDestination(isPresented:)` lives on `body`'s root `VStack`, not
        // here — see that modifier's own comment for why.
        Button {
            showCategoryInsights = true
        } label: {
            HStack {
                Text("Explore category insights")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.black)
            .padding(.vertical, ClaritySpacing.md)
            .padding(.horizontal, ClaritySpacing.lg)
            .frame(maxWidth: .infinity)
            .background(LinearGradient.emeraldSky, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Ask AI

    private var askAICard: some View {
        MonthAskAIView(
            month: selectedMonth,
            controller: askController,
            entries: allEntries,
            budgets: allBudgets,
            headCategories: headCategories,
            settings: calculationSettings
        )
    }
}

private struct MonthlySpendPoint: Identifiable {
    let month: Date
    let total: Decimal
    var id: Date { month }
}

/// "Ask AI" — a compact Q&A box scoped to one month, built on `MonthAskClarityController`, which
/// itself only orchestrates the existing Ask Clarity engine/Anthropic provider (see that type's own
/// doc comment). A separate type (not inlined in `MonthInsightsDetailView`) purely to keep this
/// screen's body readable; all the actual AI/state logic lives in the controller, not here.
private struct MonthAskAIView: View {
    let month: Date
    @ObservedObject var controller: MonthAskClarityController
    let entries: [Entry]
    let budgets: [Budget]
    let headCategories: [HeadCategory]
    let settings: BudgetCalculationSettings

    @State private var questionText = ""
    @FocusState private var isComposerFocused: Bool

    private var suggestedQuestions: [String] {
        [
            "Why did I spend more this month?",
            "What's my biggest expense category?",
            "Am I on track with my budget?",
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ClaritySpacing.md) {
            HStack(spacing: ClaritySpacing.sm) {
                ZStack {
                    Circle().fill(Color.indigo.opacity(0.18))
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(Color.indigo)
                }
                .frame(width: 32, height: 32)

                Text("ASK AI")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.textSecondary)

                Spacer()
            }

            Text("Ask a question about \(month.formatted(.dateTime.month(.wide))) — numbers always come straight from your own transactions; AI only ever helps understand the question.")
                .font(.caption)
                .foregroundStyle(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let answered = controller.answered {
                answerCard(answered)
            }

            if controller.isAsking {
                HStack(spacing: ClaritySpacing.xs) {
                    ProgressView()
                        .tint(.white)
                    Text("Thinking…")
                        .font(.caption)
                        .foregroundStyle(.textTertiary)
                }
            }

            if controller.answered == nil && !controller.isAsking {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ClaritySpacing.sm) {
                        ForEach(suggestedQuestions, id: \.self) { suggestion in
                            Button {
                                ask(suggestion)
                            } label: {
                                Text(suggestion)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.textPrimary)
                                    .padding(.horizontal, ClaritySpacing.md)
                                    .padding(.vertical, ClaritySpacing.sm)
                                    .background(Color.surfaceSecondary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            composer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .claritySurface(tint: .indigo, radius: ClarityRadius.large, padding: ClaritySpacing.xl)
    }

    private var composer: some View {
        HStack(spacing: ClaritySpacing.sm) {
            TextField("Ask about this month…", text: $questionText)
                .textFieldStyle(.plain)
                .focused($isComposerFocused)
                .foregroundStyle(.textPrimary)
                .submitLabel(.send)
                .onSubmit { ask(questionText) }
                .disabled(controller.isAsking)

            Button {
                ask(questionText)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(
                        questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.textTertiary
                            : Color.indigo
                    )
            }
            .disabled(questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.isAsking)
        }
        .padding(.horizontal, ClaritySpacing.md)
        .padding(.vertical, ClaritySpacing.sm)
        .background(Color.surfaceSecondary, in: Capsule())
    }

    private func answerCard(_ answered: MonthAskClarityController.AnsweredQuestion) -> some View {
        VStack(alignment: .leading, spacing: ClaritySpacing.xs) {
            Text(answered.question)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.textSecondary)

            Text(answered.answer.headline)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if !answered.answer.supportingDetail.isEmpty {
                Text(answered.answer.supportingDetail)
                    .font(.caption)
                    .foregroundStyle(
                        answered.answer.comparisonIsFavorable == true ? Color.success
                            : answered.answer.comparisonIsFavorable == false ? Color.warning
                            : Color.textSecondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The distinction the feature spec asks for: this label only ever marks that Claude
            // helped *interpret which question was being asked* — the headline/supportingDetail
            // above are always calculator output either way (see `MonthAskClarityController`'s own
            // doc comment). Never shown when the answer came from the fully local, deterministic
            // pass alone.
            if answered.wasAIAssisted {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                    Text("Interpreted with AI — figures calculated directly from your data")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.indigo)
            }

            if !answered.answer.followUpSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ClaritySpacing.sm) {
                        ForEach(answered.answer.followUpSuggestions, id: \.self) { suggestion in
                            Button {
                                ask(suggestion)
                            } label: {
                                Text(suggestion)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.textPrimary)
                                    .padding(.horizontal, ClaritySpacing.sm)
                                    .padding(.vertical, 6)
                                    .background(Color.surfacePrimary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(ClaritySpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceSecondary.opacity(0.6), in: RoundedRectangle(cornerRadius: ClarityRadius.medium))
        .accessibilityElement(children: .combine)
    }

    private func ask(_ text: String) {
        let question = text
        questionText = ""
        isComposerFocused = false
        Task {
            await controller.ask(
                question, month: month, entries: entries, budgets: budgets,
                headCategories: headCategories, settings: settings
            )
        }
    }
}

#Preview {
    NavigationStack {
        ScrollView {
            MonthInsightsDetailView()
        }
        .darkScreenBackground()
        .navigationTitle("Explain My Month")
    }
    .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
