import Foundation

/// Direction the Clarity Score moved compared to the same calculation exactly one week ago — see
/// `ClarityScoreCalculator`. `.notEnoughHistory` is distinct from `.stable`: it means there is no
/// comparable score from a week ago to compare against at all, so the UI never claims "stayed
/// stable" when it doesn't actually know that.
enum ClarityScoreTrend: Equatable {
    case up
    case down
    case stable
    case notEnoughHistory
}

/// Which comparison produced a `ClarityScoreFactor` — lets the view phrase each factor itself
/// rather than the calculator building user-facing strings, matching `WhatsDifferentInsight`'s
/// separation of raw data from phrasing (`Models/HomeCalculator.swift`).
enum ClarityScoreFactorKind: Equatable {
    /// This week's spend vs. this month's budget, pro-rated to a 7-day share.
    case budgetPace
    /// This week's spend vs. the 7 days immediately before it.
    case previousWeek
    /// This week's spend vs. the trailing 30-day average week (a "typical week this month").
    case typicalWeek
    /// This month's spend-so-far vs. spend through the same number of days last month — a
    /// day-count-matched comparison, fair no matter where in the month `anchor` falls.
    case monthOverMonth
}

/// One deterministic driver behind a Clarity Score. Every field is pre-computed data, never a
/// formatted sentence — the view builds the actual phrasing, and tests assert on the numbers
/// directly rather than matching strings.
struct ClarityScoreFactor: Identifiable, Equatable {
    let id: String
    let kind: ClarityScoreFactorKind
    /// Fractional change vs. this factor's comparison baseline, clamped to
    /// `ClarityScoreCalculator`'s clamp range. Always >= 0 — `isFavorable` carries the direction.
    let magnitudeFraction: Double
    let isFavorable: Bool
    /// Signed score points this factor contributed toward the final score — used only to rank
    /// factors by relevance, never shown to the user as a raw number.
    let impact: Int
}

/// A computed Clarity Score plus what's behind it. `score` is `nil` when there's too little
/// last-7-day data to say anything at all — callers must handle that case explicitly rather than
/// treating a missing score as zero.
struct ClarityScoreResult: Equatable {
    let score: Int?
    let trend: ClarityScoreTrend
    /// `current score - score from a week ago`; `nil` whenever `trend == .notEnoughHistory`.
    let pointsChange: Int?
    /// The most relevant factors behind the current score, most-impactful first, capped at
    /// `ClarityScoreCalculator.maxFactors`.
    let factors: [ClarityScoreFactor]
}

/// Computes the Clarity Score: a 0-100 deterministic read on recent spending behavior, weighted
/// toward the last 7 days. Pure, SwiftUI-independent, reuses `BudgetCalculator`/
/// `BudgetEligibility` rather than re-deriving spend or budget totals — matching
/// `HomeCalculator`'s own architecture. Deliberately never calls `SpendingInsightsService` (the
/// AI-generated monthly summary): that service is non-deterministic and network-dependent, the
/// opposite of what a score that must be explainable and unit-testable needs.
///
/// Score model: starts from a neutral `baselineScore` and applies up to four independent,
/// additive adjustments — three weekly comparisons of this week's actual spend (against this
/// month's budget, last week, and a trailing "typical week this month" average) plus one monthly
/// comparison of this month's spend-so-far against the same number of days last month. An
/// adjustment is skipped entirely, not zero-filled, when its own baseline has no data yet (the
/// same "never invent a comparison" guard `HomeCalculator.whatsDifferentInsights` already applies
/// via its `previousHead.actual > 0` check). The trend (up/down/stable) is derived by running the
/// exact same calculation again anchored one week earlier and comparing the two scores — no
/// separate persisted score history is needed.
enum ClarityScoreCalculator {
    static let baselineScore = 70
    static let maxFactors = 3

    private static let budgetPaceWeight = 25.0
    private static let previousWeekWeight = 20.0
    private static let typicalWeekWeight = 15.0
    /// Kept lower than the weekly factors so the last-7-days signal stays dominant overall — see
    /// the class doc comment.
    private static let monthOverMonthWeight = 15.0
    /// Caps how much a single comparison can move the score — one unusually large purchase
    /// shouldn't be able to single-handedly tank the score.
    private static let fractionClamp = 0.6
    /// A points-change smaller than this reads as "stayed stable" rather than a genuine up/down
    /// move, so 1-point rounding noise can't flip the displayed trend.
    private static let stableDeadZone = 2

    static func clarityScore(
        entries: [Entry],
        budgets: [Budget],
        headCategories: [HeadCategory],
        today: Date = .now,
        calendar: Calendar = .current
    ) -> ClarityScoreResult {
        let expenses = entries.budgetEligible.filter { $0.type == .expense }

        guard
            let current = snapshot(expenses: expenses, budgets: budgets, headCategories: headCategories, anchor: today, calendar: calendar)
        else {
            return ClarityScoreResult(score: nil, trend: .notEnoughHistory, pointsChange: nil, factors: [])
        }

        guard
            let weekAgo = calendar.date(byAdding: .day, value: -7, to: today),
            let previous = snapshot(expenses: expenses, budgets: budgets, headCategories: headCategories, anchor: weekAgo, calendar: calendar)
        else {
            return ClarityScoreResult(score: current.score, trend: .notEnoughHistory, pointsChange: nil, factors: current.factors)
        }

        let diff = current.score - previous.score
        let trend: ClarityScoreTrend = diff > stableDeadZone ? .up : (diff < -stableDeadZone ? .down : .stable)
        return ClarityScoreResult(score: current.score, trend: trend, pointsChange: diff, factors: current.factors)
    }

    // MARK: - Snapshot (score for a single anchor date)

    private struct Snapshot {
        let score: Int
        let factors: [ClarityScoreFactor]
    }

    /// One anchor date's score + factors. Called twice by `clarityScore(...)` — once for today,
    /// once for a week before today — so the trend comparison reuses the exact same logic rather
    /// than a second, differently-shaped calculation. Returns `nil` when `anchor`'s trailing 7
    /// days have no actual spend logged — a week with zero entries isn't evidence of anything
    /// (frugality or otherwise) on its own, it's usually just an absence of data, e.g. before the
    /// user started tracking or before a budget existed. A budget alone is not sufficient to
    /// treat an anchor as comparable: without this guard, a budget-only, zero-spend week would
    /// always score as "fully under budget" purely from missing history, which could manufacture
    /// a misleading trend against a week that was never actually tracked (see
    /// `testNoPhantomTrendFromBudgetOnlyPreviousWeekWithNoActualHistory`).
    private static func snapshot(
        expenses: [Entry],
        budgets: [Budget],
        headCategories: [HeadCategory],
        anchor: Date,
        calendar: Calendar
    ) -> Snapshot? {
        func total(from start: Date, to end: Date) -> Decimal {
            expenses.filter { $0.date >= start && $0.date < end }.reduce(Decimal(0)) { $0 + $1.amount }
        }

        guard
            let weekStart = calendar.date(byAdding: .day, value: -7, to: anchor),
            let twoWeeksStart = calendar.date(byAdding: .day, value: -14, to: anchor),
            let typicalWindowStart = calendar.date(byAdding: .day, value: -44, to: anchor)
        else { return nil }

        let recentWeekTotal = total(from: weekStart, to: anchor)
        let previousWeekTotal = total(from: twoWeeksStart, to: weekStart)
        // A 30-day window immediately preceding the previous-week window, so all three
        // comparisons look at non-overlapping spans.
        let typicalWindowTotal = total(from: typicalWindowStart, to: twoWeeksStart)

        let (month, year) = anchor.monthYearComponents
        let monthDate = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? anchor
        let plannedExpenses = BudgetCalculator.plannedBudgetTotals(
            month: monthDate, budgets: budgets, headCategories: headCategories
        ).totalPlannedExpenses
        let daysInMonth = calendar.range(of: .day, in: .month, for: monthDate)?.count ?? 30
        let weeklyBudgetShare: Decimal? = plannedExpenses > 0 ? plannedExpenses / Decimal(daysInMonth) * 7 : nil

        // Month-to-date vs. the same number of elapsed days last month — never the two months'
        // full totals, which would always favor the current (incomplete) month early on.
        let daysElapsedInMonth = calendar.dateComponents([.day], from: monthDate, to: anchor).day ?? 0
        let monthToDateTotal = total(from: monthDate, to: anchor)
        let previousMonthToDateTotal: Decimal? = {
            guard
                let previousMonthStart = calendar.date(byAdding: .month, value: -1, to: monthDate),
                let previousMonthToDateEnd = calendar.date(byAdding: .day, value: daysElapsedInMonth, to: previousMonthStart)
            else { return nil }
            return total(from: previousMonthStart, to: previousMonthToDateEnd)
        }()

        guard recentWeekTotal > 0 else { return nil }

        var factors: [ClarityScoreFactor] = []

        if let weeklyBudgetShare, weeklyBudgetShare > 0 {
            let fraction = clampedFraction((recentWeekTotal - weeklyBudgetShare) / weeklyBudgetShare)
            let impact = Int((-fraction * budgetPaceWeight).rounded())
            if impact != 0 {
                factors.append(ClarityScoreFactor(
                    id: "budgetPace", kind: .budgetPace, magnitudeFraction: abs(fraction), isFavorable: fraction <= 0, impact: impact
                ))
            }
        }

        if previousWeekTotal > 0 {
            let fraction = clampedFraction((recentWeekTotal - previousWeekTotal) / previousWeekTotal)
            let impact = Int((-fraction * previousWeekWeight).rounded())
            if impact != 0 {
                factors.append(ClarityScoreFactor(
                    id: "previousWeek", kind: .previousWeek, magnitudeFraction: abs(fraction), isFavorable: fraction <= 0, impact: impact
                ))
            }
        }

        if typicalWindowTotal > 0 {
            let typicalWeekAverage = typicalWindowTotal / 30 * 7
            let fraction = clampedFraction((recentWeekTotal - typicalWeekAverage) / typicalWeekAverage)
            let impact = Int((-fraction * typicalWeekWeight).rounded())
            if impact != 0 {
                factors.append(ClarityScoreFactor(
                    id: "typicalWeek", kind: .typicalWeek, magnitudeFraction: abs(fraction), isFavorable: fraction <= 0, impact: impact
                ))
            }
        }

        if let previousMonthToDateTotal, previousMonthToDateTotal > 0 {
            let fraction = clampedFraction((monthToDateTotal - previousMonthToDateTotal) / previousMonthToDateTotal)
            let impact = Int((-fraction * monthOverMonthWeight).rounded())
            if impact != 0 {
                factors.append(ClarityScoreFactor(
                    id: "monthOverMonth", kind: .monthOverMonth, magnitudeFraction: abs(fraction), isFavorable: fraction <= 0, impact: impact
                ))
            }
        }

        let totalImpact = factors.reduce(0) { $0 + $1.impact }
        let score = min(100, max(0, baselineScore + totalImpact))
        let rankedFactors = Array(factors.sorted { abs($0.impact) > abs($1.impact) }.prefix(maxFactors))

        return Snapshot(score: score, factors: rankedFactors)
    }

    private static func clampedFraction(_ value: Decimal) -> Double {
        let raw = value.doubleValue
        return min(fractionClamp, max(-fractionClamp, raw))
    }
}
