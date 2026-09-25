import XCTest
@testable import FinanceTracker

private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
}

/// A `Goal` with a given set of contribution amounts, wired up exactly the way
/// `GoalCalculator.progress` reads them (`goal.contributions`), with no `ModelContext` involved —
/// matching `GoalCalculatorTests`' own "prefer pure tests" convention, since `GoalPresentation` is
/// itself `SwiftUI`/`ModelContext`-independent.
private func goal(
    amounts: [Decimal] = [],
    targetAmount: Decimal = 1000,
    sortOrder: Int = 0,
    isArchived: Bool = false,
    targetDate: Date? = nil
) -> Goal {
    let goal = TestSupport.makeGoal(targetAmount: targetAmount, sortOrder: sortOrder, isArchived: isArchived, targetDate: targetDate)
    let wallet = TestSupport.makeWallet()
    goal.contributions = amounts.map { amount in
        let entry = TestSupport.makeEntry(amount: abs(amount), date: .now, type: amount >= 0 ? .income : .expense, wallet: wallet)
        return TestSupport.makeGoalContribution(amount: amount, goal: goal, transaction: entry)
    }
    return goal
}

/// Identity-based array comparison — `Goal`/`GoalContribution` (`@Model` classes) are compared by
/// reference throughout this test suite via `===`, matching `GoalModelTests`' own established
/// convention, rather than `XCTAssertEqual` (no value-level `Equatable` conformance is relied on).
private func assertIdenticalGoals(_ actual: [Goal], _ expected: [Goal], file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for (a, e) in zip(actual, expected) {
        XCTAssertTrue(a === e, file: file, line: line)
    }
}

/// Focused tests for `GoalPresentation` — the pure UI-support logic behind Goals' list/detail
/// screens (Phase 2N-B). No SwiftUI, no view hierarchy: see `CLARITY_GOALS_UX_SPEC.md`.
final class GoalPresentationTests: XCTestCase {

    // MARK: - Active/Completed partitioning

    func testActiveGoalsExcludesCompletedGoals() {
        let inProgress = goal(amounts: [400], sortOrder: 0)
        let finished = goal(amounts: [1000], sortOrder: 1)
        assertIdenticalGoals(GoalPresentation.activeGoals(from: [inProgress, finished]), [inProgress])
    }

    func testCompletedGoalsExcludesActiveGoals() {
        let inProgress = goal(amounts: [400], sortOrder: 0)
        let finished = goal(amounts: [1000], sortOrder: 1)
        assertIdenticalGoals(GoalPresentation.completedGoals(from: [inProgress, finished]), [finished])
    }

    func testActiveGoalsOrderedBySortOrder() {
        let second = goal(amounts: [100], sortOrder: 1)
        let first = goal(amounts: [100], sortOrder: 0)
        assertIdenticalGoals(GoalPresentation.activeGoals(from: [second, first]), [first, second])
    }

    func testCompletedGoalsOrderedBySortOrder() {
        let second = goal(amounts: [1000], targetAmount: 1000, sortOrder: 1)
        let first = goal(amounts: [500], targetAmount: 500, sortOrder: 0)
        assertIdenticalGoals(GoalPresentation.completedGoals(from: [second, first]), [first, second])
    }

    func testGoalExceedingTargetCountsAsCompleted() {
        let overTarget = goal(amounts: [1200])
        assertIdenticalGoals(GoalPresentation.completedGoals(from: [overTarget]), [overTarget])
        XCTAssertTrue(GoalPresentation.activeGoals(from: [overTarget]).isEmpty)
    }

    // MARK: - Archived goals excluded

    func testArchivedGoalExcludedFromActiveEvenWhenNotCompleted() {
        let archived = goal(amounts: [100], isArchived: true)
        XCTAssertTrue(GoalPresentation.activeGoals(from: [archived]).isEmpty)
    }

    func testArchivedGoalExcludedFromCompletedEvenWhenTargetReached() {
        let archived = goal(amounts: [1000], isArchived: true)
        XCTAssertTrue(GoalPresentation.completedGoals(from: [archived]).isEmpty)
    }

    func testArchivedGoalExcludedFromBothAlongsideNormalGoals() {
        let archived = goal(amounts: [400], sortOrder: 0, isArchived: true)
        let normal = goal(amounts: [400], sortOrder: 1)
        assertIdenticalGoals(GoalPresentation.activeGoals(from: [archived, normal]), [normal])
        XCTAssertTrue(GoalPresentation.completedGoals(from: [archived, normal]).isEmpty)
    }

    // MARK: - Empty state condition

    func testNoGoalsAtAllProducesEmptyActiveAndCompleted() {
        XCTAssertTrue(GoalPresentation.activeGoals(from: []).isEmpty)
        XCTAssertTrue(GoalPresentation.completedGoals(from: []).isEmpty)
    }

    func testOnlyArchivedGoalsProducesEmptyActiveAndCompleted() {
        let archived = goal(amounts: [100], isArchived: true)
        XCTAssertTrue(GoalPresentation.activeGoals(from: [archived]).isEmpty)
        XCTAssertTrue(GoalPresentation.completedGoals(from: [archived]).isEmpty)
    }

    // MARK: - Progress presentation edge cases (ring clamping, percentage text)

    func testClampedRingFractionClampsBelowZero() {
        XCTAssertEqual(GoalPresentation.clampedRingFraction(-0.1), 0)
    }

    func testClampedRingFractionClampsAboveOne() {
        XCTAssertEqual(GoalPresentation.clampedRingFraction(1.2), 1)
    }

    func testClampedRingFractionPassesThroughMidRangeValue() {
        XCTAssertEqual(GoalPresentation.clampedRingFraction(0.4), 0.4)
    }

    func testClampedRingFractionIsZeroForNilFraction() {
        XCTAssertEqual(GoalPresentation.clampedRingFraction(nil), 0)
    }

    func testPercentageTextIsDashForNilFraction() {
        XCTAssertEqual(GoalPresentation.percentageText(nil), "—")
    }

    func testPercentageTextIsUnclampedForOverTarget() {
        // Locale-agnostic substring check (not an exact-format match) — the point under test is
        // that 120% survives unclamped, not the punctuation/spacing a given locale uses.
        let text = GoalPresentation.percentageText(1.2)
        XCTAssertTrue(text.contains("120"), "expected an unclamped ~120% figure, got \(text)")
    }

    func testPercentageTextIsUnclampedForNegativeFraction() {
        let text = GoalPresentation.percentageText(-0.1)
        XCTAssertTrue(text.contains("10"), "expected a ~10% magnitude, got \(text)")
        XCTAssertTrue(text.contains("-") || text.contains("\u{2212}"), "a negative fraction must render as a negative percentage, got \(text)")
    }

    // MARK: - Over-target presentation

    func testIsOverTargetFalseWhenBelowTarget() {
        XCTAssertFalse(GoalPresentation.isOverTarget(GoalCalculator.progress(targetAmount: 1000, contributions: [])))
    }

    func testIsOverTargetFalseWhenExactlyAtTarget() {
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: goal(amounts: [1000]).contributions)
        XCTAssertFalse(GoalPresentation.isOverTarget(progress), "exactly at target is complete, not 'over'")
    }

    func testIsOverTargetTrueWhenAboveTarget() {
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: goal(amounts: [1200]).contributions)
        XCTAssertTrue(GoalPresentation.isOverTarget(progress))
    }

    // MARK: - Completed presentation

    func testGoalIsCompletedDerivedFromContributions() {
        XCTAssertFalse(GoalPresentation.isCompleted(goal(amounts: [400])))
        XCTAssertTrue(GoalPresentation.isCompleted(goal(amounts: [1000])))
        XCTAssertTrue(GoalPresentation.isCompleted(goal(amounts: [1500])))
    }

    func testGoalWithNoContributionsIsNotCompletedForPositiveTarget() {
        XCTAssertFalse(GoalPresentation.isCompleted(goal(amounts: [])))
    }

    // MARK: - Target-date requirement visibility

    func testRequirementHiddenWhenNil() {
        XCTAssertFalse(GoalPresentation.shouldShowContributionRequirement(nil, isCompleted: false))
    }

    func testRequirementHiddenWhenZeroValued() {
        let zero = GoalContributionRequirement(requiredMonthly: 0, requiredWeekly: 0)
        XCTAssertFalse(GoalPresentation.shouldShowContributionRequirement(zero, isCompleted: false), "a €0/month figure reads as dead/bugged, not informative")
    }

    func testRequirementVisibleWhenNonzeroAndNotCompleted() {
        let requirement = GoalContributionRequirement(requiredMonthly: 100, requiredWeekly: 25)
        XCTAssertTrue(GoalPresentation.shouldShowContributionRequirement(requirement, isCompleted: false))
    }

    func testRequirementHiddenWhenGoalIsCompletedEvenIfNonzero() {
        // A defensive case: even a (theoretically stale) nonzero requirement must never show once
        // the goal itself is already complete.
        let requirement = GoalContributionRequirement(requiredMonthly: 100, requiredWeekly: 25)
        XCTAssertFalse(GoalPresentation.shouldShowContributionRequirement(requirement, isCompleted: true))
    }

    // MARK: - Past due

    func testIsPastDueFalseWhenNoTargetDate() {
        XCTAssertFalse(GoalPresentation.isPastDue(targetDate: nil, isCompleted: false, today: testDate(2026, 1, 1)))
    }

    func testIsPastDueTrueWhenTargetDateBeforeToday() {
        XCTAssertTrue(GoalPresentation.isPastDue(targetDate: testDate(2025, 1, 1), isCompleted: false, today: testDate(2026, 1, 1)))
    }

    func testIsPastDueFalseWhenTargetDateInFuture() {
        XCTAssertFalse(GoalPresentation.isPastDue(targetDate: testDate(2027, 1, 1), isCompleted: false, today: testDate(2026, 1, 1)))
    }

    func testIsPastDueFalseWhenGoalAlreadyCompletedEvenIfDateHasPassed() {
        XCTAssertFalse(GoalPresentation.isPastDue(targetDate: testDate(2025, 1, 1), isCompleted: true, today: testDate(2026, 1, 1)))
    }

    // MARK: - Add Money (Phase 2N-C1)

    func testSignedAmountIsPositiveForDeposit() {
        XCTAssertEqual(GoalPresentation.signedAmount(50, direction: .deposit), 50)
    }

    func testSignedAmountIsNegativeForWithdrawal() {
        XCTAssertEqual(GoalPresentation.signedAmount(50, direction: .withdrawal), -50)
    }

    func testDefaultDirectionForIncomeIsDeposit() {
        XCTAssertEqual(GoalPresentation.defaultDirection(for: .income), .deposit)
    }

    func testDefaultDirectionForExpenseIsWithdrawal() {
        XCTAssertEqual(GoalPresentation.defaultDirection(for: .expense), .withdrawal)
    }

    func testDefaultDirectionForTransferIsDeposit() {
        // Transfers have no inherent deposit/withdrawal polarity of their own — Deposit is the
        // documented, always-overridable default (GoalPresentation.swift's own doc comment).
        XCTAssertEqual(GoalPresentation.defaultDirection(for: .transfer), .deposit)
    }

    func testIsValidContributionAmountRejectsNil() {
        XCTAssertFalse(GoalPresentation.isValidContributionAmount(nil))
    }

    func testIsValidContributionAmountRejectsZero() {
        XCTAssertFalse(GoalPresentation.isValidContributionAmount(0))
    }

    func testIsValidContributionAmountRejectsNegative() {
        XCTAssertFalse(GoalPresentation.isValidContributionAmount(-10))
    }

    func testIsValidContributionAmountAcceptsPositive() {
        XCTAssertTrue(GoalPresentation.isValidContributionAmount(0.01))
    }

    func testSortedContributionsOrdersNewestFirst() {
        let goal = TestSupport.makeGoal()
        let older = TestSupport.makeGoalContribution(amount: 10, date: testDate(2026, 1, 1), goal: goal)
        let newer = TestSupport.makeGoalContribution(amount: 20, date: testDate(2026, 3, 1), goal: goal)
        let middle = TestSupport.makeGoalContribution(amount: 30, date: testDate(2026, 2, 1), goal: goal)
        goal.contributions = [older, newer, middle]

        let sorted = GoalPresentation.sortedContributions(for: goal)
        XCTAssertTrue(sorted[0] === newer)
        XCTAssertTrue(sorted[1] === middle)
        XCTAssertTrue(sorted[2] === older)
    }

    func testContributionContextLabelIsManualForUnlinkedContribution() {
        let goal = TestSupport.makeGoal()
        let contribution = TestSupport.makeGoalContribution(amount: 50, goal: goal)
        XCTAssertEqual(GoalPresentation.contributionContextLabel(contribution), "Manual")
    }

    func testContributionContextLabelIncludesManualNoteWhenPresent() {
        let goal = TestSupport.makeGoal()
        let contribution = TestSupport.makeGoalContribution(amount: 50, goal: goal, note: "birthday money")
        XCTAssertEqual(GoalPresentation.contributionContextLabel(contribution), "Manual · birthday money")
    }

    func testContributionContextLabelUsesLinkedEntryContext() {
        let wallet = TestSupport.makeWallet(name: "Checking")
        let headCategory = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(name: "Salary", isIncome: true, headCategory: headCategory)
        let goal = TestSupport.makeGoal()
        let entry = TestSupport.makeEntry(amount: 200, date: .now, type: .income, category: category, wallet: wallet)
        let contribution = TestSupport.makeGoalContribution(amount: 200, goal: goal, transaction: entry)
        XCTAssertEqual(GoalPresentation.contributionContextLabel(contribution), "Salary · Checking")
    }

    /// A contribution whose linked `Entry` was deleted (nullified) must render identically to a
    /// contribution that was manual from the start — never "orphaned"/"deleted" language
    /// (`CLARITY_GOALS_ARCHITECTURE.md`'s Phase 2N-C Pre-Work section).
    func testContributionContextLabelIsManualAfterTransactionNullified() {
        let wallet = TestSupport.makeWallet()
        let goal = TestSupport.makeGoal()
        let entry = TestSupport.makeEntry(amount: 50, date: .now, type: .income, wallet: wallet)
        let contribution = TestSupport.makeGoalContribution(amount: 50, goal: goal, transaction: entry)
        contribution.transaction = nil
        XCTAssertEqual(GoalPresentation.contributionContextLabel(contribution), "Manual")
    }

    // MARK: - Hero percentage single-line/scaling support (Phase 2N-E)

    /// `GoalDetailView.progressCard` pairs `GoalPresentation.percentageText`'s output with
    /// `.minimumScaleFactor(0.6)`/`.lineLimit(1)` (verified by direct code inspection — this
    /// project has no SwiftUI view-inspection library to assert on rendered modifiers). What *is*
    /// testable at this layer is the data-side precondition those modifiers exist to handle: the
    /// string itself must always be a single token with no embedded line breaks, for any input,
    /// including the extreme values a Dynamic-Type-scaled hero number is most likely to overflow
    /// on — an over-target or deeply negative goal can legitimately produce a much longer string
    /// than "40%".
    func testPercentageTextIsAlwaysSingleLineForExtremeValues() {
        let values: [Double?] = [nil, 0, 1, -1, 12.5, 999, -999, 123456.789]
        for value in values {
            let text = GoalPresentation.percentageText(value)
            XCTAssertFalse(text.contains("\n"), "percentageText must never embed a newline for input \(String(describing: value)), got \(text)")
            XCTAssertFalse(text.isEmpty)
        }
    }

    func testPercentageTextCanExceedTypicalWidthForALargeOverTargetGoal() {
        // A goal funded many times over its target — the exact shape of value that most needs
        // `.minimumScaleFactor` to avoid clipping in the hero card, since a 5-digit percentage is
        // materially wider than "40%". Length-based, not a specific-digits check, since locale
        // grouping/decimal separators (verified to vary in this test environment) make an exact
        // substring assertion unreliable — see the Phase 2N-B lesson on locale-agnostic checks.
        let typical = GoalPresentation.percentageText(0.4)
        let large = GoalPresentation.percentageText(123.456)
        XCTAssertGreaterThan(large.count, typical.count, "an unclamped, deeply-over-target percentage must be allowed to render wider than a typical one, got \(large) vs \(typical)")
    }
}
