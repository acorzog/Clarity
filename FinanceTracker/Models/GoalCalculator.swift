import Foundation

/// A `Goal`'s progress for a given `targetAmount` and set of `GoalContribution`s — see
/// `GoalCalculator.progress`. Presentation-only concerns (clamping for a progress bar, color,
/// "behind/ahead" labels) are deliberately not this type's job — see `CLARITY_GOALS_ARCHITECTURE.md`
/// §7/§19: this layer reports mathematical truth, unclamped, and lets the view decide how to
/// render an over-target or negative state.
struct GoalProgress: Equatable {
    let currentAmount: Decimal
    let remainingAmount: Decimal
    /// `nil` when `targetAmount == 0` — a degenerate goal configuration with no meaningful
    /// fraction, never reported as `0` or `1` (`CLARITY_GOALS_ARCHITECTURE.md` §19's explicit
    /// edge case).
    let progressFraction: Double?
}

/// Deterministic, non-predictive planning math for a `Goal` with a target date — see
/// `GoalCalculator.contributionRequirement`. **Not a forecast** (§7 of the Phase 2M brief,
/// `CLARITY_GOALS_ARCHITECTURE.md` §10): both figures are plain division of an already-known gap
/// by an already-known remaining duration, never an extrapolation of past contribution behavior.
struct GoalContributionRequirement: Equatable {
    let requiredMonthly: Decimal
    let requiredWeekly: Decimal
}

/// The single deterministic calculation layer for Goal math — see
/// `CLARITY_GOALS_ARCHITECTURE.md` §19. Pure, stateless, `SwiftUI`/`UserDefaults`/CloudKit/
/// `ModelContext`-independent, following `BudgetCalculator`'s exact architecture: every function
/// takes already-fetched value types in and returns plain value types out, so it's equally usable
/// from the app, the widget extension, unit tests, or any future background calculation.
///
/// **Deliberately independent of `BudgetCalculator`/`BudgetEligibility`/`BudgetCalculationSettings`**
/// — Goals and Budget are separate concerns in V1 (`CLARITY_GOALS_ARCHITECTURE.md` §12). This type
/// never imports or reuses anything from that layer, and never reads `Wallet.balance`,
/// `.includeInNetWorth`, `.isArchived`, `.type`, or `Entry.excludeFromBudget` — the explicit
/// `GoalContribution` relationship is already the complete eligibility gate (§5/§13).
enum GoalCalculator {

    // MARK: - Progress

    /// Sums every supplied contribution's `amount` — positive and negative alike — with **no**
    /// eligibility rule based on `transaction` (Phase 2N-C0, `CLARITY_GOALS_ARCHITECTURE.md`'s
    /// Phase 2N-C Pre-Work section). Phase 2M-B briefly excluded a contribution whose `transaction`
    /// had been nullified, reasoning it was a "residual, invalidated record" — that reasoning
    /// depended on every contribution being required to link to an `Entry`, a requirement that has
    /// since been reopened and reversed: a manual (unlinked) contribution is now just as legitimate
    /// as a linked one, so a nullified `transaction` means nothing more than "this contribution is
    /// no longer linked," not "this contribution stopped counting." No other filtering exists here
    /// either — not by date, sign, amount, or any property of a still-linked `transaction`:
    /// `contributions` is already the explicit, user-confirmed source of truth
    /// (`CLARITY_GOALS_ARCHITECTURE.md` §5/§9).
    static func progress(targetAmount: Decimal, contributions: [GoalContribution]) -> GoalProgress {
        let currentAmount = contributions.reduce(Decimal(0)) { $0 + $1.amount }
        let remainingAmount = targetAmount - currentAmount
        let progressFraction: Double? = targetAmount > 0 ? (currentAmount / targetAmount).doubleValue : nil
        return GoalProgress(currentAmount: currentAmount, remainingAmount: remainingAmount, progressFraction: progressFraction)
    }

    /// Derived, never stored (`CLARITY_GOALS_ARCHITECTURE.md` §8/§18) — `remainingAmount <= 0` is
    /// algebraically identical to `currentAmount >= targetAmount`. Provided as a small, named
    /// convenience so callers don't each re-derive the comparison; skip it entirely at the call
    /// site if `progress.remainingAmount <= 0` already reads clearly enough there.
    static func isCompleted(_ progress: GoalProgress) -> Bool {
        progress.remainingAmount <= 0
    }

    // MARK: - Target-date planning (not a forecast — see this type's own doc comment)

    /// "Given the known target, current amount, and target date, how much would be required per
    /// month/week to close the known gap?" — plain arithmetic, never an extrapolation of past
    /// contribution behavior, never a prediction of whether the goal will actually be reached.
    ///
    /// `remainingAmount <= 0` (goal already met or exceeded) always yields zero for both figures,
    /// regardless of the target date. Otherwise, the remaining duration is floored at 1 (month and
    /// week alike) — including for a `targetDate` that has already passed, which still produces a
    /// large-but-finite, honest requirement rather than a nonsensical or hidden one
    /// (`CLARITY_GOALS_ARCHITECTURE.md` §10).
    static func contributionRequirement(
        remainingAmount: Decimal,
        targetDate: Date,
        today: Date = .now,
        calendar: Calendar = .current
    ) -> GoalContributionRequirement? {
        guard remainingAmount > 0 else {
            return GoalContributionRequirement(requiredMonthly: 0, requiredWeekly: 0)
        }

        let monthsRemaining = max(1, calendarMonthsBetween(today, targetDate, calendar: calendar))
        let weeksRemaining = max(1, calendarWeeksBetween(today, targetDate, calendar: calendar))

        return GoalContributionRequirement(
            requiredMonthly: remainingAmount / Decimal(monthsRemaining),
            requiredWeekly: remainingAmount / Decimal(weeksRemaining)
        )
    }

    /// Convenience overload for a `Goal` whose `targetDate` may be `nil` — no target date means
    /// there is nothing to plan a required contribution against at all
    /// (`CLARITY_GOALS_ARCHITECTURE.md` §10: target dates are optional, never mandatory).
    static func contributionRequirement(
        remainingAmount: Decimal,
        targetDate: Date?,
        today: Date = .now,
        calendar: Calendar = .current
    ) -> GoalContributionRequirement? {
        guard let targetDate else { return nil }
        return contributionRequirement(remainingAmount: remainingAmount, targetDate: targetDate, today: today, calendar: calendar)
    }

    /// Whole calendar months from `start` to `end`, negative when `end` precedes `start` (a
    /// past-due target date) — `contributionRequirement` floors this at 1 before dividing.
    private static func calendarMonthsBetween(_ start: Date, _ end: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.month], from: start, to: end).month ?? 0
    }

    /// Whole 7-day weeks from `start` to `end`, via day-count integer division rather than
    /// `Calendar`'s `.weekOfYear` component — deliberately avoids ISO-calendar week-boundary
    /// quirks (a week "remaining" should mean "how many 7-day spans are left," not "how many
    /// calendar week-boundaries are crossed"). Negative when `end` precedes `start`.
    private static func calendarWeeksBetween(_ start: Date, _ end: Date, calendar: Calendar) -> Int {
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return days / 7
    }
}
