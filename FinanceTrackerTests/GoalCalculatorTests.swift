import XCTest
@testable import FinanceTracker

private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
}

/// Builds a `GoalContribution` with no `ModelContext` involved at all — `GoalCalculator.progress`
/// only ever reads `.amount`, a plain stored property, so these pure, unpersisted objects are
/// sufficient (matching this phase's "prefer pure tests" instruction over the persistence-test
/// pattern `GoalModelTests`/`BudgetCalculatorTests` use for relationship-dependent behavior).
private func contribution(_ amount: Decimal, wallet: Wallet? = nil, goal: Goal? = nil) -> GoalContribution {
    let wallet = wallet ?? TestSupport.makeWallet()
    let goal = goal ?? TestSupport.makeGoal()
    let entry = TestSupport.makeEntry(amount: abs(amount), date: .now, type: amount >= 0 ? .income : .expense, wallet: wallet)
    return TestSupport.makeGoalContribution(amount: amount, goal: goal, transaction: entry)
}

/// A manual contribution — no `Entry` at all, never linked (Phase 2N-C0,
/// `CLARITY_GOALS_ARCHITECTURE.md`'s Phase 2N-C Pre-Work section). First-class and permanent, not
/// a placeholder awaiting a link.
private func manualContribution(_ amount: Decimal, goal: Goal? = nil) -> GoalContribution {
    TestSupport.makeGoalContribution(amount: amount, goal: goal ?? TestSupport.makeGoal())
}

/// Builds a real `GoalContribution` exactly like `contribution(_:)`, then nils its `transaction` —
/// reproducing, without any `ModelContext`, the exact state `GoalModelTests` already proves
/// SwiftData itself produces when a linked `Entry` is deleted (`.nullify`). As of Phase 2N-C0 this
/// is *not* a residual/invalidated state — a contribution left this way becomes indistinguishable
/// from `manualContribution(_:)` and keeps counting toward progress exactly as before.
private func contributionWithNullifiedTransaction(_ amount: Decimal, wallet: Wallet? = nil, goal: Goal? = nil) -> GoalContribution {
    let goalContribution = contribution(amount, wallet: wallet, goal: goal)
    goalContribution.transaction = nil
    return goalContribution
}

/// Focused tests for `GoalCalculator` — the pure, deterministic Goal math layer (Phase 2M). No UI,
/// no `BudgetCalculator` coupling, no Wallet-balance dependency, no forecasting: see
/// `CLARITY_GOAL_CALCULATOR_REPORT.md`.
final class GoalCalculatorTests: XCTestCase {

    // MARK: - Progress (1-12)

    func testEmptyContributions() {
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: [])
        XCTAssertEqual(progress.currentAmount, 0)
        XCTAssertEqual(progress.remainingAmount, 1000)
        XCTAssertEqual(progress.progressFraction, 0)
    }

    func testOnePositiveContribution() {
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: [contribution(400)])
        XCTAssertEqual(progress.currentAmount, 400)
        XCTAssertEqual(progress.remainingAmount, 600)
        XCTAssertEqual(progress.progressFraction, 0.4)
    }

    func testMultiplePositiveContributions() {
        let contributions = [contribution(100), contribution(150), contribution(50)]
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: contributions)
        XCTAssertEqual(progress.currentAmount, 300)
    }

    func testMultipleContributionsSumCorrectly() {
        let contributions = (1...5).map { contribution(Decimal($0) * 20) } // 20+40+60+80+100 = 300
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: contributions)
        XCTAssertEqual(progress.currentAmount, 300)
        XCTAssertEqual(progress.remainingAmount, 700)
    }

    func testNegativeContribution() {
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: [contribution(-100)])
        XCTAssertEqual(progress.currentAmount, -100)
        XCTAssertEqual(progress.remainingAmount, 1100)
    }

    func testPositiveAndNegativeContributions() {
        let contributions = [contribution(500), contribution(-200), contribution(100)]
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: contributions)
        XCTAssertEqual(progress.currentAmount, 400)
        XCTAssertEqual(progress.remainingAmount, 600)
    }

    func testTargetExactlyReached() {
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: [contribution(1000)])
        XCTAssertEqual(progress.remainingAmount, 0)
        XCTAssertEqual(progress.progressFraction, 1.0)
    }

    func testTargetExceeded() {
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: [contribution(1200)])
        XCTAssertEqual(progress.remainingAmount, -200)
        XCTAssertEqual(progress.progressFraction, 1.2)
        // Explicitly not clamped — CLARITY_GOALS_ARCHITECTURE.md §7/§19.
    }

    func testNegativeCurrentAmount() {
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: [contribution(-100)])
        XCTAssertEqual(progress.remainingAmount, 1100)
        XCTAssertEqual(progress.progressFraction, -0.1)
        // Explicitly not clamped to zero — a negative fraction is a meaningful, honest signal.
    }

    func testZeroTargetProducesNilFraction() {
        let progress = GoalCalculator.progress(targetAmount: 0, contributions: [contribution(50)])
        XCTAssertNil(progress.progressFraction, "a zero target must never be silently reported as 0 or 1")
        XCTAssertEqual(progress.currentAmount, 50)
        XCTAssertEqual(progress.remainingAmount, -50)
    }

    func testDecimalPrecisionIsPreserved() {
        // Constructed via `Decimal(string:)` rather than float literals — Decimal's
        // `ExpressibleByFloatLiteral` conformance can round-trip through a binary floating-point
        // intermediate, which would make this test about Swift's literal parsing rather than
        // `GoalCalculator`'s own summation. `Decimal(string:)` is exact.
        let amounts = ["33.33", "33.33", "33.34"].map { Decimal(string: $0)! }
        let contributions = amounts.map { contribution($0) }
        let progress = GoalCalculator.progress(targetAmount: 100, contributions: contributions)
        XCTAssertEqual(progress.currentAmount, Decimal(string: "100.00")!)
        XCTAssertEqual(progress.remainingAmount, 0)
    }

    func testMultipleGoalsAreIsolatedWhenSeparateContributionArraysAreSupplied() {
        let goalA = TestSupport.makeGoal(name: "Vacation")
        let goalB = TestSupport.makeGoal(name: "Emergency Fund")
        let progressA = GoalCalculator.progress(targetAmount: 1000, contributions: [contribution(200, goal: goalA)])
        let progressB = GoalCalculator.progress(targetAmount: 500, contributions: [contribution(500, goal: goalB)])

        XCTAssertEqual(progressA.currentAmount, 200)
        XCTAssertEqual(progressB.currentAmount, 500)
        XCTAssertNotEqual(progressA.remainingAmount, progressB.remainingAmount)
    }

    // MARK: - Manual contributions (Phase 2N-C0 — reverses Phase 2M-B, CLARITY_GOALS_ARCHITECTURE.md's Phase 2N-C Pre-Work)

    /// A manual contribution (no `Entry` at all) counts toward progress exactly like a linked one.
    func testManualContributionCounts() {
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: [manualContribution(400)])
        XCTAssertEqual(progress.currentAmount, 400)
        XCTAssertEqual(progress.remainingAmount, 600)
        XCTAssertEqual(progress.progressFraction, 0.4)
    }

    /// A linked contribution still counts — restated explicitly alongside the manual case above,
    /// rather than relying solely on the pre-existing Progress tests, so this section reads as a
    /// complete, self-contained proof that both forms are treated identically.
    func testLinkedContributionCounts() {
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: [contribution(400)])
        XCTAssertEqual(progress.currentAmount, 400)
    }

    /// Mixed manual + linked contributions sum together with no distinction.
    func testMixedManualAndLinkedContributionsSumTogether() {
        let contributions = [contribution(300), manualContribution(500), contribution(100)]
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: contributions)
        XCTAssertEqual(progress.currentAmount, 900) // 300 + 500 + 100 — every contribution counts
        XCTAssertEqual(progress.remainingAmount, 100)
    }

    /// Deleting/nullifying a linked `Entry` (reproduced here via `contributionWithNullifiedTransaction`,
    /// matching exactly what `GoalModelTests` proves SwiftData's `.nullify` rule does) leaves the
    /// contribution counting — the core reversal this phase implements.
    func testNullifiedTransactionContributionStillCounts() {
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: [contributionWithNullifiedTransaction(400)])
        XCTAssertEqual(progress.currentAmount, 400, "a contribution whose linked Entry was deleted must keep counting, not be excluded")
        XCTAssertEqual(progress.remainingAmount, 600)
    }

    /// A negative *manual* contribution reduces progress exactly like a negative linked one.
    func testNegativeManualContributionAffectsProgressNormally() {
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: [contribution(500), manualContribution(-200)])
        XCTAssertEqual(progress.currentAmount, 300)
        XCTAssertEqual(progress.remainingAmount, 700)
    }

    /// Zero-target behavior is unchanged with a manual contribution present — `nil` fraction,
    /// current amount still summed unconditionally.
    func testZeroTargetStillProducesNilFractionWithManualContributionPresent() {
        let progress = GoalCalculator.progress(targetAmount: 0, contributions: [contribution(50), manualContribution(999)])
        XCTAssertNil(progress.progressFraction)
        XCTAssertEqual(progress.currentAmount, 1049, "both contributions count — no eligibility filter exists")
    }

    /// Over-target behavior (unclamped, negative `remainingAmount`) is unchanged — a manual
    /// contribution can push a goal over target exactly like a linked one.
    func testOverTargetStillUnclampedWithManualContributionIncluded() {
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: [contribution(900), manualContribution(900)])
        XCTAssertEqual(progress.currentAmount, 1800)
        XCTAssertEqual(progress.remainingAmount, -800)
        XCTAssertEqual(progress.progressFraction, 1.8)
    }

    // MARK: - Completion (13-15)

    func testIsCompletedFalseWhenBelowTarget() {
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: [contribution(400)])
        XCTAssertFalse(GoalCalculator.isCompleted(progress))
    }

    func testIsCompletedTrueWhenExactlyAtTarget() {
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: [contribution(1000)])
        XCTAssertTrue(GoalCalculator.isCompleted(progress))
    }

    func testIsCompletedTrueWhenAboveTarget() {
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: [contribution(1500)])
        XCTAssertTrue(GoalCalculator.isCompleted(progress))
    }

    // MARK: - Contribution requirement (16-25)

    func testNilTargetDateReturnsNilRequirement() {
        let requirement = GoalCalculator.contributionRequirement(remainingAmount: 500, targetDate: nil, today: testDate(2026, 1, 1))
        XCTAssertNil(requirement, "a Goal with no target date has nothing to plan a required contribution against")
    }

    func testFutureTargetDateProducesPositiveRequirement() {
        let requirement = GoalCalculator.contributionRequirement(
            remainingAmount: 600,
            targetDate: testDate(2026, 7, 1),
            today: testDate(2026, 1, 1)
        )
        XCTAssertNotNil(requirement)
        XCTAssertEqual(requirement?.requiredMonthly, 100) // 600 / 6 months
    }

    func testSameDayTargetDateFloorsToOneMonthAndOneWeek() {
        let sameDay = testDate(2026, 3, 15)
        let requirement = GoalCalculator.contributionRequirement(remainingAmount: 200, targetDate: sameDay, today: sameDay)
        XCTAssertEqual(requirement?.requiredMonthly, 200) // 200 / max(1, 0) = 200 / 1
        XCTAssertEqual(requirement?.requiredWeekly, 200)
    }

    func testPastTargetDateStillComputesUsingFloorOfOne() {
        let requirement = GoalCalculator.contributionRequirement(
            remainingAmount: 300,
            targetDate: testDate(2025, 1, 1),
            today: testDate(2026, 1, 1)
        )
        XCTAssertNotNil(requirement, "a past-due goal's requirement must still be computed, never hidden")
        XCTAssertEqual(requirement?.requiredMonthly, 300) // floored at 1 month despite being ~12 months overdue
        XCTAssertEqual(requirement?.requiredWeekly, 300)
    }

    func testRemainingAmountExactlyZeroProducesZeroRequirement() {
        let requirement = GoalCalculator.contributionRequirement(
            remainingAmount: 0,
            targetDate: testDate(2026, 12, 1),
            today: testDate(2026, 1, 1)
        )
        XCTAssertEqual(requirement, GoalContributionRequirement(requiredMonthly: 0, requiredWeekly: 0))
    }

    func testRemainingAmountNegativeProducesZeroRequirement() {
        let requirement = GoalCalculator.contributionRequirement(
            remainingAmount: -50,
            targetDate: testDate(2026, 12, 1),
            today: testDate(2026, 1, 1)
        )
        XCTAssertEqual(requirement, GoalContributionRequirement(requiredMonthly: 0, requiredWeekly: 0), "an already-exceeded goal requires nothing further")
        XCTAssertNotNil(requirement)
    }

    func testOneMonthBoundary() {
        let requirement = GoalCalculator.contributionRequirement(
            remainingAmount: 100,
            targetDate: testDate(2026, 2, 1),
            today: testDate(2026, 1, 1)
        )
        XCTAssertEqual(requirement?.requiredMonthly, 100) // exactly 1 month away
    }

    func testMultipleMonthBoundary() {
        let requirement = GoalCalculator.contributionRequirement(
            remainingAmount: 1200,
            targetDate: testDate(2027, 1, 1),
            today: testDate(2026, 1, 1)
        )
        XCTAssertEqual(requirement?.requiredMonthly, 100) // 1200 / 12 months
    }

    func testWeekCalculation() {
        // 2026-01-01 to 2026-01-29 is exactly 28 days = 4 whole weeks.
        let requirement = GoalCalculator.contributionRequirement(
            remainingAmount: 400,
            targetDate: testDate(2026, 1, 29),
            today: testDate(2026, 1, 1)
        )
        XCTAssertEqual(requirement?.requiredWeekly, 100) // 400 / 4 weeks
    }

    func testDecimalDivisionPrecision() {
        let requirement = GoalCalculator.contributionRequirement(
            remainingAmount: 100,
            targetDate: testDate(2026, 4, 1),
            today: testDate(2026, 1, 1)
        )
        // 100 / 3 months — Decimal division retains full precision, not rounded/truncated.
        XCTAssertEqual(requirement?.requiredMonthly, 100 / Decimal(3))
    }

    /// `contributionRequirement` itself takes `remainingAmount`/`targetDate`/`today`, never a
    /// contribution array — it has no eligibility rule of its own, and this phase's `progress`
    /// change doesn't touch it at all, so every pre-existing `contributionRequirement` test above
    /// is untouched and still passes unmodified. This test additionally proves the two functions
    /// still compose correctly end-to-end with a manual contribution included upstream.
    func testContributionRequirementUnchangedWhenComposedWithManualContributions() {
        let progress = GoalCalculator.progress(targetAmount: 1000, contributions: [contribution(400), manualContribution(600)])
        XCTAssertEqual(progress.remainingAmount, 0, "both contributions count — 1000 - (400 + 600) = 0")
        let requirement = GoalCalculator.contributionRequirement(
            remainingAmount: progress.remainingAmount,
            targetDate: testDate(2026, 7, 1),
            today: testDate(2026, 1, 1)
        )
        XCTAssertEqual(requirement, GoalContributionRequirement(requiredMonthly: 0, requiredWeekly: 0), "the goal is already complete, so nothing further is required")
    }

    // MARK: - Not a forecast (guards against accidental scope creep)

    /// `contributionRequirement` must depend only on `remainingAmount`/`targetDate`/`today` — never
    /// on contribution history — since it is planning math, not a prediction. Two calls with
    /// identical `remainingAmount`/dates but (conceptually) different contribution histories
    /// behind them must produce identical results, because history never enters this function's
    /// signature at all.
    func testRequirementDependsOnlyOnRemainingAmountAndDatesNeverOnHistory() {
        let requirementA = GoalCalculator.contributionRequirement(remainingAmount: 300, targetDate: testDate(2026, 4, 1), today: testDate(2026, 1, 1))
        let requirementB = GoalCalculator.contributionRequirement(remainingAmount: 300, targetDate: testDate(2026, 4, 1), today: testDate(2026, 1, 1))
        XCTAssertEqual(requirementA, requirementB)
    }
}
