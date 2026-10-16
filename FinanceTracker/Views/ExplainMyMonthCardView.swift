import SwiftUI
import SwiftData

/// The Overview entry point into `MonthInsightsDetailView` — a plain promotional banner (icon,
/// title, one-line description, decorative illustration), not a rendering of any computed
/// `MonthExplanation` itself. Every number this feature produces — total spend, the comparison to
/// last month, notable category changes, budget performance, highlights — lives in the destination
/// screen (`MonthInsightsDetailView`, which embeds `ExplainMyMonthContent` below for that), not
/// here; this card's only job is inviting the tap.
struct ExplainMyMonthCardView: View {
    @Query(filter: #Predicate<Entry> { !$0.isSoftDeleted }, sort: \Entry.date, order: .reverse) private var allEntries: [Entry]
    @Query private var allBudgets: [Budget]
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]

    /// The Clarity Score shown in the card's ring is always "as of today" — same reasoning as
    /// `MonthInsightsDetailView` only ever showing its own Clarity Score section for the current
    /// month: the score has no meaning for a past month, so this entry banner always reflects the
    /// live score regardless of which month Overview itself is currently browsing.
    private var clarityScoreResult: ClarityScoreResult {
        ClarityScoreCalculator.clarityScore(entries: allEntries, budgets: allBudgets, headCategories: headCategories)
    }

    /// Shown unconditionally, including for a month with no spend data yet: the destination
    /// already degrades gracefully there (its own empty-state total), so there's no reason to hide
    /// the invitation to open it.
    var body: some View {
        NavigationLink {
            ScrollView {
                // Always opens on the real current month, regardless of whatever month Overview
                // itself happens to be browsing — `MonthInsightsDetailView` owns its own month
                // navigation from here on (see its own doc comment).
                MonthInsightsDetailView()
            }
            .darkScreenBackground()
            .navigationTitle("Explain My Month")
        } label: {
            bannerContent
        }
        .buttonStyle(ExplainMyMonthCardButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Get a clear, personalised summary of your spending, trends and insights.")
    }

    private var accessibilityLabel: String {
        guard let score = clarityScoreResult.score, ClarityScorePresentation.hasSignal(clarityScoreResult) else {
            return "Explain My Month"
        }
        return "Explain My Month. Clarity Score: \(score) out of 100."
    }

    private var bannerContent: some View {
        HStack(spacing: ClaritySpacing.md) {
            iconBadge

            VStack(alignment: .leading, spacing: 4) {
                Text("Explain My Month")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)

                Text("Get a clear, personalised summary of your spending, trends and insights.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }

            Spacer(minLength: ClaritySpacing.sm)

            ClarityScoreRing(result: clarityScoreResult)
        }
        .padding(ClaritySpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Same hero fill `MetricCard`/`WalletsView`'s Net Worth card uses, so the two premium,
            // most-important-number cards in the app share one gradient identity.
            RoundedRectangle(cornerRadius: ClarityRadius.large, style: .continuous)
                .fill(LinearGradient.emeraldSky)
        )
        .overlay(
            // The "subtle luminous border" — a thin, low-opacity white stroke rather than a
            // `.shadow(...)` glow, matching the app's existing flat/no-shadow surface convention
            // (`Surface.swift`'s own doc comment) while still reading as premium against the
            // gradient fill.
            RoundedRectangle(cornerRadius: ClarityRadius.large, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        )
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.18))
            Image(systemName: "wallet.pass.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}

/// The Clarity Score as a small filling ring, in place of a decorative illustration — animates
/// from empty up to `result.score`/100 once, on appear. White (not `ClarityScorePresentation
/// .tierColor`) because the ring sits on the same saturated emerald/sky gradient fill a tier color
/// could easily low-contrast against; the score number/tier reads clearly in white regardless of
/// which tier it is.
private struct ClarityScoreRing: View {
    let result: ClarityScoreResult

    @State private var animatedProgress: Double = 0

    private var progress: Double { Double(result.score ?? 0) / 100 }
    private var hasScore: Bool { result.score != nil && ClarityScorePresentation.hasSignal(result) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.22), lineWidth: 5)
            Circle()
                .trim(from: 0, to: animatedProgress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))

            if hasScore {
                Text("\(result.score ?? 0)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: 62, height: 62)
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) {
                animatedProgress = hasScore ? progress : 0
            }
        }
        .accessibilityHidden(true)
    }
}

/// Visual press feedback for the banner — a slight scale-down + dim, since the banner's own
/// gradient fill already replaces `claritySurface`'s flat tier background, so `.buttonStyle(.plain)`
/// alone (as every other card-tap uses) would give no feedback at all here.
private struct ExplainMyMonthCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Internal (not `private`) so `MonthInsightsDetailView` can embed the exact same highlight rows.
/// `entriesFor` lets a notable-category-change row drill into that category's actual transactions
/// (`CategoryEntriesDetailView`) — mirrors `RemainingView`'s identical
/// `entriesFor: (Category) -> [Entry]` threading rather than recomputing that filter here.
struct ExplainMyMonthContent: View {
    let explanation: MonthExplanation
    let month: Date
    let entriesFor: (Category) -> [Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: ClaritySpacing.md) {
            headline

            if !explanation.notableCategoryChanges.isEmpty {
                VStack(alignment: .leading, spacing: ClaritySpacing.sm) {
                    ForEach(explanation.notableCategoryChanges) { change in
                        NotableChangeRow(insight: change, month: month, entriesFor: entriesFor)
                    }
                }
            }

            if let performance = explanation.budgetPerformance {
                BudgetPerformanceRow(performance: performance)
            }

            if let positive = explanation.positiveHighlight {
                HighlightRow(highlight: positive, tint: .success, symbol: "checkmark.circle.fill", text: Self.positiveText(for: positive))
            }

            if let attention = explanation.attentionArea {
                HighlightRow(highlight: attention, tint: .warning, symbol: "exclamationmark.triangle.fill", text: Self.attentionText(for: attention))
            }
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: ClaritySpacing.xs) {
            Text(explanation.totalSpending.currencyFormatted)
                .font(.title2.weight(.bold))
                .foregroundStyle(.textPrimary)

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
        }
    }

    static func positiveText(for highlight: ExplainMyMonthHighlight) -> String {
        switch highlight.kind {
        case .totalSpendingDown:
            let percent = (highlight.magnitudeFraction ?? 0).formatted(.percent.precision(.fractionLength(0)))
            let amount = highlight.amount?.currencyFormatted ?? ""
            return "You spent \(percent) less than last month, \(amount) saved."
        case .categoryDecrease:
            let percent = (highlight.magnitudeFraction ?? 0).formatted(.percent.precision(.fractionLength(0)))
            return "\(highlight.subject) is down \(percent) from last month."
        case .withinBudget:
            return "You stayed within budget this month."
        default:
            return ""
        }
    }

    static func attentionText(for highlight: ExplainMyMonthHighlight) -> String {
        switch highlight.kind {
        case .overBudgetCategory:
            let amount = highlight.amount?.currencyFormatted ?? ""
            return "\(highlight.subject) went \(amount) over its budget."
        case .aheadOfPace:
            return "You're spending faster than a steady pace for this month's budget."
        case .categoryIncrease:
            let percent = (highlight.magnitudeFraction ?? 0).formatted(.percent.precision(.fractionLength(0)))
            return "\(highlight.subject) is up \(percent) from last month."
        default:
            return ""
        }
    }
}

private struct NotableChangeRow: View {
    let insight: WhatsDifferentInsight
    let month: Date
    let entriesFor: (Category) -> [Entry]

    private var percentText: String {
        (insight.magnitudeFraction ?? 0).formatted(.percent.precision(.fractionLength(0)))
    }

    private var message: String {
        let comparison = insight.direction == .up ? "higher" : "lower"
        return "\(insight.subject) is \(percentText) \(comparison) than last month"
    }

    /// `insight` only carries the *parent* head category plus the specific category's name as
    /// plain text (`subject`) — never guesses past a name match, matching every other "resolve a
    /// typed/derived name back to a real category" site in the app (e.g. `AskClarityInterpreter`'s
    /// own category matching): `nil` here just means the row stays non-interactive instead of
    /// risking a wrong drill-down target.
    private var resolvedCategory: Category? {
        insight.headCategory?.categories.first { $0.name == insight.subject }
    }

    var body: some View {
        if let category = resolvedCategory {
            NavigationLink {
                CategoryEntriesDetailView(title: category.name, entries: entriesFor(category), category: category, month: month)
            } label: {
                rowLabel
            }
            .buttonStyle(.plain)
        } else {
            rowLabel
        }
    }

    private var rowLabel: some View {
        HStack(alignment: .top, spacing: ClaritySpacing.sm) {
            DeltaIndicator(delta: percentText, direction: insight.direction == .up ? .up : .down, isFavorable: insight.isFavorable)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if resolvedCategory != nil {
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

private struct BudgetPerformanceRow: View {
    let performance: MonthBudgetPerformance

    private var stateColor: Color { GaugeThreshold.color(forProgress: performance.progress) }
    private var percentText: String { performance.progress.formatted(.percent.precision(.fractionLength(0))) }

    private var statusText: String {
        switch performance.state {
        case .overBudget: "over your \(performance.budgeted.currencyFormatted) budget"
        case .approachingLimit: "close to your \(performance.budgeted.currencyFormatted) budget"
        case .onTrack: "within your \(performance.budgeted.currencyFormatted) budget"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: ClaritySpacing.sm) {
            Image(systemName: "gauge.with.needle.fill")
                .font(.subheadline)
                .foregroundStyle(stateColor)
            Text("You're \(percentText) \(statusText) this month.")
                .font(.subheadline)
                .foregroundStyle(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HighlightRow: View {
    let highlight: ExplainMyMonthHighlight
    let tint: Color
    let symbol: String
    let text: String

    var body: some View {
        if !text.isEmpty {
            HStack(alignment: .top, spacing: ClaritySpacing.sm) {
                Image(systemName: symbol)
                    .font(.subheadline)
                    .foregroundStyle(tint)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(text)
        }
    }
}

#Preview {
    ExplainMyMonthCardView()
        .padding()
        .darkScreenBackground()
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
