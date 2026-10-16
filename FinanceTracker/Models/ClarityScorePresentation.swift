import SwiftUI

/// Pure formatting/phrasing for `ClarityScoreResult`/`ClarityScoreFactor` — `ClarityScoreCalculator`
/// deliberately returns numbers only, never sentences; this is the one place that turns them into
/// words/colors, shared by `HomeView`'s Clarity Score card and `MonthInsightsDetailView`'s expanded
/// Clarity Score section so the two can never phrase (or color) the same score differently.
enum ClarityScorePresentation {
    static func trendBadge(for result: ClarityScoreResult) -> (delta: String, direction: DeltaIndicator.Direction, isFavorable: Bool?)? {
        switch result.trend {
        case .up: ("+\(result.pointsChange ?? 0)", .up, true)
        case .down: ("\(result.pointsChange ?? 0)", .down, false)
        case .stable: ("±0", .flat, nil)
        case .notEnoughHistory: nil
        }
    }

    /// Builds the actual phrasing for a factor from its raw data — the calculator owns the
    /// numbers, this owns the wording, matching `WhatsDifferentRow.message`'s split of data vs.
    /// phrasing.
    static func factorTitle(_ factor: ClarityScoreFactor) -> String {
        let percent = factor.magnitudeFraction.formatted(.percent.precision(.fractionLength(0)))
        return switch factor.kind {
        case .budgetPace: factor.isFavorable ? "\(percent) under your weekly budget pace" : "\(percent) over your weekly budget pace"
        case .previousWeek: factor.isFavorable ? "\(percent) lower than last week" : "\(percent) higher than last week"
        case .typicalWeek: factor.isFavorable ? "\(percent) below your typical week" : "\(percent) above your typical week"
        case .monthOverMonth: factor.isFavorable ? "\(percent) lower than this point last month" : "\(percent) higher than this point last month"
        }
    }

    /// Short (1-2 word) label for a compact factor strip/ring — the sentence-level phrasing
    /// belongs to `factorTitle`/`summary` above; this exists only for layouts that pair a percent
    /// with a short label rather than a full sentence.
    static func factorShortLabel(_ factor: ClarityScoreFactor) -> String {
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
    /// `ClarityScoreCalculator.snapshot`). False only for the plain baseline default with zero
    /// comparisons available (e.g. a brand-new user's very first days), which must not be shown as
    /// if it were an actual measure of financial health.
    static func hasSignal(_ result: ClarityScoreResult) -> Bool {
        !result.factors.isEmpty || result.trend != .notEnoughHistory
    }

    static func summary(_ result: ClarityScoreResult) -> String {
        guard result.score != nil else {
            return "Log a few expenses this week to start seeing your Clarity Score."
        }
        guard hasSignal(result) else {
            return "Your Clarity Score will get more precise as you add more transaction history."
        }
        guard let topFactor = result.factors.first else {
            return "Spending is right in line with your usual pattern."
        }
        let trendPhrase = switch result.trend {
        case .up: "Your score improved this week"
        case .down: "Your score dipped this week"
        case .stable: "Your score held steady this week"
        case .notEnoughHistory: "Here's your Clarity Score"
        }
        return "\(trendPhrase) — \(factorTitle(topFactor))."
    }

    static func accessibilityLabel(_ result: ClarityScoreResult) -> String {
        guard let score = result.score, hasSignal(result) else {
            return "Clarity Score. \(summary(result))"
        }
        return "Clarity Score: \(score) out of 100, \(tierLabel(for: result) ?? ""). \(summary(result))"
    }

    /// A coarse, presentation-only reading of the 0-100 score — same "the view owns the wording,
    /// not the calculator" split as `factorTitle` above. Deliberately simple (3 buckets); this is
    /// a glance-level label, not a new scoring system.
    static func tierLabel(for result: ClarityScoreResult) -> String? {
        guard let score = result.score, hasSignal(result) else { return nil }
        switch score {
        case 70...: return "Good"
        case 40..<70: return "Fair"
        default: return "Needs focus"
        }
    }

    static func tierColor(for result: ClarityScoreResult) -> Color {
        guard let score = result.score else { return .textSecondary }
        switch score {
        case 70...: return .income
        case 40..<70: return .warning
        default: return .expense
        }
    }
}
