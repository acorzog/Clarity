import Foundation

/// Pure, `SwiftUI`-independent presentation-support logic for the Goals screens (Phase 2N-B) —
/// sits between `GoalCalculator` (financial truth, never touched here) and the actual views
/// (`GoalsListView`/`GoalDetailView`), so list partitioning, ring clamping, and "should this row
/// show" decisions are testable without a view hierarchy. See `CLARITY_GOALS_UX_SPEC.md`.
enum GoalPresentation {

    /// `GoalCalculator.progress` applied to a `Goal`'s own `targetAmount`/`contributions` — the
    /// one place every other function below gets its `GoalProgress` from, so every screen reads
    /// the same derived value (`CLARITY_GOALS_UX_SPEC.md` §4: completion is derived, never stored).
    static func progress(for goal: Goal) -> GoalProgress {
        GoalCalculator.progress(targetAmount: goal.targetAmount, contributions: goal.contributions)
    }

    static func isCompleted(_ goal: Goal) -> Bool {
        GoalCalculator.isCompleted(progress(for: goal))
    }

    /// Active goals — not archived, not completed — ordered by `sortOrder`
    /// (`CLARITY_GOALS_UX_SPEC.md` §4).
    static func activeGoals(from goals: [Goal]) -> [Goal] {
        goals
            .filter { !$0.isArchived && !isCompleted($0) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Completed goals — not archived — ordered by `sortOrder` (§4). Archived goals are excluded
    /// from both this and `activeGoals`, regardless of completion state (§4: "excluded from both
    /// sections by default").
    static func completedGoals(from goals: [Goal]) -> [Goal] {
        goals
            .filter { !$0.isArchived && isCompleted($0) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// A ring's fill fraction, clamped to `[0, 1]` — presentation-only clamping for a bounded
    /// shape. `GoalCalculator.progress`'s own `progressFraction` stays unclamped; this never
    /// changes that value, only what a ring draws from it (§5/§9: "clamping for a progress bar's
    /// visual range is a presentation concern"). `nil` (zero target) renders an empty ring.
    static func clampedRingFraction(_ progressFraction: Double?) -> Double {
        guard let progressFraction else { return 0 }
        return min(max(progressFraction, 0), 1)
    }

    /// Whether progress has gone past the target (`remainingAmount < 0`) — used to choose
    /// "over"/success-colored copy instead of "left"/neutral copy (§5/§9: over-target is good
    /// news for a savings goal, never `semantic.expense`/red).
    static func isOverTarget(_ progress: GoalProgress) -> Bool {
        progress.remainingAmount < 0
    }

    /// Percentage text for a detail screen — "—" (never "0%") for a zero-target goal's `nil`
    /// fraction (§9), unclamped otherwise (a detail screen's text label may honestly read "120%"
    /// or "−10%", unlike a ring's bounded fill).
    static func percentageText(_ progressFraction: Double?) -> String {
        guard let progressFraction else { return "—" }
        return progressFraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Whether the "You need €X/month" row should show at all (§11): never for a goal with no
    /// target date (`requirement == nil`), and never once the goal is complete — a `0`-valued
    /// requirement is technically correct but reads as a dead/bugged figure once there's nothing
    /// left to contribute, so the row is omitted entirely rather than shown as "€0/month."
    static func shouldShowContributionRequirement(_ requirement: GoalContributionRequirement?, isCompleted: Bool) -> Bool {
        guard let requirement, !isCompleted else { return false }
        return !(requirement.requiredMonthly == 0 && requirement.requiredWeekly == 0)
    }

    /// Whether a set target date has already passed for a goal that isn't complete yet (§10) —
    /// `today`/`isCompleted` are both explicit parameters so this stays deterministic and
    /// testable, matching `GoalCalculator`'s own injectable-`today` convention.
    static func isPastDue(targetDate: Date?, isCompleted: Bool, today: Date = .now) -> Bool {
        guard let targetDate, !isCompleted else { return false }
        return targetDate < today
    }

    // MARK: - Add Money (Phase 2N-C1)

    /// A contribution's sign is set by direction, never typed directly by the user as a negative
    /// number — `CLARITY_GOALS_UX_SPEC.md` §12's "Deposit/Withdrawal" segmented control.
    enum GoalContributionDirection: String, CaseIterable, Identifiable {
        case deposit
        case withdrawal

        var id: String { rawValue }
        var label: String { self == .deposit ? "Deposit" : "Withdrawal" }
    }

    /// Converts a user-entered, always-positive magnitude into the signed amount
    /// `GoalCalculator` expects — positive for a deposit, negative for a withdrawal
    /// (`CLARITY_GOALS_ARCHITECTURE.md` §18).
    static func signedAmount(_ magnitude: Decimal, direction: GoalContributionDirection) -> Decimal {
        direction == .withdrawal ? -magnitude : magnitude
    }

    /// The direction a linked `Entry` suggests by default — a convenience only, always
    /// user-overridable (`CLARITY_GOALS_UX_SPEC.md` §12). A transfer has no inherent
    /// deposit/withdrawal polarity of its own, so it defaults to Deposit like income does,
    /// rather than guessing from source/destination wallet context.
    static func defaultDirection(for entryType: EntryType) -> GoalContributionDirection {
        entryType == .expense ? .withdrawal : .deposit
    }

    /// Validation rule for the Add Money amount field (§12): must parse and be strictly positive.
    /// The *sign* comes from `direction`/`signedAmount`, never from the field itself.
    static func isValidContributionAmount(_ amount: Decimal?) -> Bool {
        guard let amount else { return false }
        return amount > 0
    }

    /// Contribution history, newest first (§15) — matches `CategoryEntriesDetailView`'s own
    /// `sorted { $0.date > $1.date }` convention.
    static func sortedContributions(for goal: Goal) -> [GoalContribution] {
        goal.contributions.sorted { $0.date > $1.date }
    }

    /// A contribution history row's context label (§15): "Manual" (+ optional note) for an
    /// unlinked contribution, or the linked `Entry`'s own note/category/wallet when one exists.
    /// Deliberately never says "orphaned"/"deleted" — a contribution whose `Entry` was removed is
    /// indistinguishable from one that was manual from the start (`CLARITY_GOALS_ARCHITECTURE.md`'s
    /// Phase 2N-C Pre-Work section).
    static func contributionContextLabel(_ contribution: GoalContribution) -> String {
        guard let entry = contribution.transaction else {
            if let note = contribution.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                return "Manual · \(note)"
            }
            return "Manual"
        }
        var parts: [String] = []
        if let categoryName = entry.category?.name {
            parts.append(categoryName)
        }
        parts.append(entry.wallet.name)
        let entryNote = entry.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entryNote.isEmpty {
            parts.append(entryNote)
        }
        return parts.joined(separator: " · ")
    }
}
