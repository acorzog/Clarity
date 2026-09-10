import XCTest
import SwiftData
@testable import FinanceTracker

/// Persistence/behavior tests for the Add Money flow (Phase 2N-C1) — construction, editing, and
/// deletion of `GoalContribution` exactly as `AddGoalMoneyView`/`GoalDetailView` perform them,
/// using a real `ModelContext` (matching `GoalModelTests`' own style for relationship-dependent
/// behavior). Does not re-test `GoalCalculator`'s own math — see `GoalCalculatorTests` and
/// `CLARITY_GOAL_CALCULATOR_REPORT.md` for that, already covered in Phase 2N-C0.
final class GoalContributionFlowTests: XCTestCase {

    // MARK: - Manual Add Money

    func testManualDepositCreatesAndPersistsAGoalContribution() throws {
        let context = TestSupport.makeInMemoryContext()
        let goal = TestSupport.makeGoal()
        context.insert(goal)

        let magnitude: Decimal = 50
        let signed = GoalPresentation.signedAmount(magnitude, direction: .deposit)
        let contribution = GoalContribution(amount: signed, date: .now, goal: goal, note: "birthday money")
        context.insert(contribution)
        try context.save()

        XCTAssertEqual(contribution.amount, 50)
        XCTAssertNil(contribution.transaction)
        XCTAssertEqual(contribution.note, "birthday money")
        XCTAssertTrue(contribution.goal === goal)
        XCTAssertEqual(goal.contributions.count, 1)
    }

    func testManualWithdrawalCreatesTheCorrectSignedContribution() throws {
        let context = TestSupport.makeInMemoryContext()
        let goal = TestSupport.makeGoal()
        context.insert(goal)

        let magnitude: Decimal = 30
        let signed = GoalPresentation.signedAmount(magnitude, direction: .withdrawal)
        let contribution = GoalContribution(amount: signed, date: .now, goal: goal)
        context.insert(contribution)
        try context.save()

        XCTAssertEqual(contribution.amount, -30)
        XCTAssertNil(contribution.transaction)
    }

    func testManualContributionWithoutEntryCountsTowardGoalProgress() throws {
        let context = TestSupport.makeInMemoryContext()
        let goal = TestSupport.makeGoal(targetAmount: 100)
        context.insert(goal)
        let contribution = GoalContribution(amount: 40, date: .now, goal: goal)
        context.insert(contribution)
        try context.save()

        let progress = GoalCalculator.progress(targetAmount: goal.targetAmount, contributions: goal.contributions)
        XCTAssertEqual(progress.currentAmount, 40)
        XCTAssertEqual(progress.remainingAmount, 60)
    }

    // MARK: - Linked transaction flow

    func testLinkedContributionPersistsWithItsEntryRelationship() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let goal = TestSupport.makeGoal()
        context.insert(goal)
        let entry = TestSupport.makeEntry(amount: 200, date: .now, type: .income, wallet: wallet)
        context.insert(entry)

        let contribution = GoalContribution(amount: 200, date: entry.date, goal: goal, transaction: entry)
        context.insert(contribution)
        try context.save()

        XCTAssertTrue(contribution.transaction === entry)
        XCTAssertTrue(entry.goalContribution === contribution)
    }

    func testLinkedEntryCannotReceiveASecondGoalContribution() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let goalA = TestSupport.makeGoal(name: "Vacation")
        let goalB = TestSupport.makeGoal(name: "Emergency Fund")
        context.insert(goalA)
        context.insert(goalB)
        let entry = TestSupport.makeEntry(amount: 500, date: .now, type: .income, wallet: wallet)
        context.insert(entry)

        let first = GoalContribution(amount: 500, date: .now, goal: goalA, transaction: entry)
        context.insert(first)
        try context.save()
        XCTAssertTrue(entry.goalContribution === first)

        // Selecting the same, already-linked Entry a second time (the picker filters these out in
        // the UI, `entry.goalContribution == nil`) re-points the Entry's single back-reference —
        // the structural guarantee this relies on, unchanged since Phase 2L/2N-C0.
        let second = GoalContribution(amount: 500, date: .now, goal: goalB, transaction: entry)
        context.insert(second)
        try context.save()

        XCTAssertTrue(entry.goalContribution === second)
        XCTAssertNil(first.transaction, "the superseded contribution loses its Entry link rather than silently double-counting it")
    }

    func testContributionAmountRemainsIndependentFromEntryAmount() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let goal = TestSupport.makeGoal()
        context.insert(goal)
        let entry = TestSupport.makeEntry(amount: 200, date: .now, type: .income, wallet: wallet)
        context.insert(entry)

        // Add Money prefills the amount field from the Entry but leaves it editable — a user may
        // save a different (here, partial) amount.
        let contribution = GoalContribution(amount: 75, date: entry.date, goal: goal, transaction: entry)
        context.insert(contribution)
        try context.save()

        XCTAssertEqual(contribution.amount, 75)
        XCTAssertEqual(entry.amount, 200, "the linked Entry's own amount is untouched")
    }

    // MARK: - Delete/nullify independence

    func testDeletingAGoalContributionLeavesTheEntryIntact() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let goal = TestSupport.makeGoal()
        context.insert(goal)
        let entry = TestSupport.makeEntry(amount: 100, date: .now, type: .income, wallet: wallet)
        context.insert(entry)
        let contribution = GoalContribution(amount: 100, date: .now, goal: goal, transaction: entry)
        context.insert(contribution)
        try context.save()

        context.delete(contribution)
        try context.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Entry>()), 1, "removing a contribution must never delete its linked Entry")
        XCTAssertNil(entry.goalContribution, "the Entry survives, simply no longer linked to any goal")
    }

    func testNullifyingOrDeletingAnEntryLeavesTheGoalContributionIntact() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let goal = TestSupport.makeGoal()
        context.insert(goal)
        let entry = TestSupport.makeEntry(amount: 100, date: .now, type: .income, wallet: wallet)
        context.insert(entry)
        let contribution = GoalContribution(amount: 100, date: .now, goal: goal, transaction: entry)
        context.insert(contribution)
        try context.save()

        context.delete(entry)
        try context.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<GoalContribution>()), 1, "deleting the linked Entry must never delete the contribution")
        XCTAssertNil(contribution.transaction)
        XCTAssertEqual(contribution.amount, 100, "the contribution keeps its own amount and keeps counting — Phase 2N-C0")
    }

    // MARK: - Contribution history ordering

    func testContributionHistoryOrdersNewestFirst() throws {
        let context = TestSupport.makeInMemoryContext()
        let goal = TestSupport.makeGoal()
        context.insert(goal)
        let older = GoalContribution(amount: 10, date: Date(timeIntervalSince1970: 1_000), goal: goal)
        let newer = GoalContribution(amount: 20, date: Date(timeIntervalSince1970: 3_000), goal: goal)
        let middle = GoalContribution(amount: 30, date: Date(timeIntervalSince1970: 2_000), goal: goal)
        context.insert(older)
        context.insert(newer)
        context.insert(middle)
        try context.save()

        let sorted = GoalPresentation.sortedContributions(for: goal)
        XCTAssertTrue(sorted[0] === newer)
        XCTAssertTrue(sorted[1] === middle)
        XCTAssertTrue(sorted[2] === older)
    }

    // MARK: - Edit

    func testEditingAmountAndDatePersists() throws {
        let context = TestSupport.makeInMemoryContext()
        let goal = TestSupport.makeGoal()
        context.insert(goal)
        let contribution = GoalContribution(amount: 40, date: Date(timeIntervalSince1970: 1_000), goal: goal)
        context.insert(contribution)
        try context.save()

        let newDate = Date(timeIntervalSince1970: 2_000)
        contribution.amount = GoalPresentation.signedAmount(65, direction: .deposit)
        contribution.date = newDate
        try context.save()

        XCTAssertEqual(contribution.amount, 65)
        XCTAssertEqual(contribution.date, newDate)
    }

    // MARK: - Delete

    func testDeletingAContributionRemovesItFromTheGoal() throws {
        let context = TestSupport.makeInMemoryContext()
        let goal = TestSupport.makeGoal()
        context.insert(goal)
        let contribution = GoalContribution(amount: 40, date: .now, goal: goal)
        context.insert(contribution)
        try context.save()
        XCTAssertEqual(goal.contributions.count, 1)

        context.delete(contribution)
        try context.save()

        XCTAssertEqual(goal.contributions.count, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<GoalContribution>()), 0)
    }

    // MARK: - Validation

    func testValidationRejectsZeroAndNegativeInputAmounts() {
        XCTAssertFalse(GoalPresentation.isValidContributionAmount(0))
        XCTAssertFalse(GoalPresentation.isValidContributionAmount(-5))
        XCTAssertFalse(GoalPresentation.isValidContributionAmount(Decimal(decimalInput: "")))
        XCTAssertTrue(GoalPresentation.isValidContributionAmount(0.5))
    }

    // MARK: - Progress updates after add/edit/delete

    func testGoalProgressUpdatesCorrectlyAfterAddEditAndDelete() throws {
        let context = TestSupport.makeInMemoryContext()
        let goal = TestSupport.makeGoal(targetAmount: 100)
        context.insert(goal)

        // Add
        let contribution = GoalContribution(amount: 40, date: .now, goal: goal)
        context.insert(contribution)
        try context.save()
        XCTAssertEqual(GoalCalculator.progress(targetAmount: goal.targetAmount, contributions: goal.contributions).currentAmount, 40)

        // Edit
        contribution.amount = 70
        try context.save()
        XCTAssertEqual(GoalCalculator.progress(targetAmount: goal.targetAmount, contributions: goal.contributions).currentAmount, 70)

        // Delete
        context.delete(contribution)
        try context.save()
        XCTAssertEqual(GoalCalculator.progress(targetAmount: goal.targetAmount, contributions: goal.contributions).currentAmount, 0)
    }
}
