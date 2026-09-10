import XCTest
import SwiftData
@testable import FinanceTracker

/// Persistence/relationship tests for `Goal`/`GoalContribution` — Phase 2L, model and
/// persistence only. No `GoalCalculator` exists yet (Phase 2M); nothing here tests progress,
/// completion, or contribution-requirement math — see `CLARITY_GOALS_ARCHITECTURE.md` §19/§20 for
/// that future scope.
final class GoalModelTests: XCTestCase {

    // MARK: - Goal creation

    func testGoalPersistsRequiredFields() throws {
        let context = TestSupport.makeInMemoryContext()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let goal = TestSupport.makeGoal(name: "Vacation Fund", icon: "airplane", colorHex: "#33AAFF", targetAmount: 2500, createdAt: created)
        context.insert(goal)
        try context.save()

        XCTAssertEqual(goal.name, "Vacation Fund")
        XCTAssertEqual(goal.icon, "airplane")
        XCTAssertEqual(goal.colorHex, "#33AAFF")
        XCTAssertEqual(goal.targetAmount, 2500)
        XCTAssertEqual(goal.createdAt, created)
    }

    func testGoalDefaultsAreCorrect() throws {
        let context = TestSupport.makeInMemoryContext()
        let goal = Goal(name: "Emergency Fund", icon: "shield", colorHex: "#FFFFFF", targetAmount: 1000)
        context.insert(goal)
        try context.save()

        XCTAssertEqual(goal.sortOrder, 0)
        XCTAssertFalse(goal.isArchived)
        XCTAssertNil(goal.targetDate)
        XCTAssertNil(goal.contextWallet)
        XCTAssertTrue(goal.contributions.isEmpty)
    }

    func testOptionalTargetDatePersists() throws {
        let context = TestSupport.makeInMemoryContext()
        let deadline = Date(timeIntervalSince1970: 1_800_000_000)
        let goal = TestSupport.makeGoal(targetDate: deadline)
        context.insert(goal)
        try context.save()

        XCTAssertEqual(goal.targetDate, deadline)
    }

    func testOptionalContextWalletPersists() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet(name: "Emergency Fund Account")
        context.insert(wallet)
        let goal = TestSupport.makeGoal(contextWallet: wallet)
        context.insert(goal)
        try context.save()

        XCTAssertTrue(goal.contextWallet === wallet)
    }

    func testIsArchivedDefaultsToFalseAndPersistsWhenSetTrue() throws {
        let context = TestSupport.makeInMemoryContext()
        let goal = TestSupport.makeGoal(isArchived: true)
        context.insert(goal)
        try context.save()

        XCTAssertTrue(goal.isArchived)
    }

    func testSortOrderPersists() throws {
        let context = TestSupport.makeInMemoryContext()
        let goal = TestSupport.makeGoal(sortOrder: 3)
        context.insert(goal)
        try context.save()

        XCTAssertEqual(goal.sortOrder, 3)
    }

    // MARK: - GoalContribution

    func testContributionLinksToGoal() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let goal = TestSupport.makeGoal()
        context.insert(goal)
        let entry = TestSupport.makeEntry(amount: 100, date: .now, type: .income, wallet: wallet)
        context.insert(entry)
        let contribution = TestSupport.makeGoalContribution(amount: 100, goal: goal, transaction: entry)
        context.insert(contribution)
        try context.save()

        XCTAssertTrue(contribution.goal === goal)
        XCTAssertEqual(goal.contributions.count, 1)
        XCTAssertTrue(goal.contributions.first === contribution)
    }

    func testContributionLinksToEntry() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let goal = TestSupport.makeGoal()
        context.insert(goal)
        let entry = TestSupport.makeEntry(amount: 100, date: .now, type: .income, wallet: wallet)
        context.insert(entry)
        let contribution = TestSupport.makeGoalContribution(amount: 100, goal: goal, transaction: entry)
        context.insert(contribution)
        try context.save()

        XCTAssertTrue(contribution.transaction === entry)
        XCTAssertTrue(entry.goalContribution === contribution)
    }

    func testContributionAmountAndDatePersist() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let goal = TestSupport.makeGoal()
        context.insert(goal)
        let entry = TestSupport.makeEntry(amount: 200, date: .now, type: .income, wallet: wallet)
        context.insert(entry)
        let contributionDate = Date(timeIntervalSince1970: 1_750_000_000)
        // Deliberately different from the Entry's own amount — a contribution may only
        // partially fund a goal (CLARITY_GOALS_ARCHITECTURE.md §7).
        let contribution = TestSupport.makeGoalContribution(amount: 75, date: contributionDate, goal: goal, transaction: entry)
        context.insert(contribution)
        try context.save()

        XCTAssertEqual(contribution.amount, 75)
        XCTAssertEqual(contribution.date, contributionDate)
        XCTAssertEqual(entry.amount, 200, "the linked Entry's own amount is untouched by the (smaller) contribution amount")
    }

    /// Phase 2N-C0: a `GoalContribution` may be constructed with no `Entry` at all — a manual
    /// deposit, first-class and permanent, not a placeholder awaiting a link
    /// (`CLARITY_GOALS_ARCHITECTURE.md`'s Phase 2N-C Pre-Work section).
    func testManualContributionCanBeCreatedWithoutAnEntry() throws {
        let context = TestSupport.makeInMemoryContext()
        let goal = TestSupport.makeGoal()
        context.insert(goal)
        let contribution = TestSupport.makeGoalContribution(amount: 50, goal: goal)
        context.insert(contribution)
        try context.save()

        XCTAssertNil(contribution.transaction)
        XCTAssertTrue(contribution.goal === goal)
        XCTAssertEqual(goal.contributions.count, 1)
        XCTAssertEqual(goal.contributions.first?.amount, 50)
    }

    /// `init`'s `transaction` parameter defaults to `nil` — confirms the default itself, not just
    /// that omitting it compiles.
    func testGoalContributionInitDefaultsTransactionToNil() {
        let goal = TestSupport.makeGoal()
        let contribution = GoalContribution(amount: 25, goal: goal)
        XCTAssertNil(contribution.transaction)
    }

    func testOneEntryHasAtMostOneContributionAtCreation() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let goal = TestSupport.makeGoal()
        context.insert(goal)
        let entry = TestSupport.makeEntry(amount: 100, date: .now, type: .income, wallet: wallet)
        context.insert(entry)
        let contribution = TestSupport.makeGoalContribution(amount: 100, goal: goal, transaction: entry)
        context.insert(contribution)
        try context.save()

        XCTAssertTrue(entry.goalContribution === contribution)
    }

    // MARK: - Relationship integrity

    func testGoalCanHaveMultipleContributions() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let goal = TestSupport.makeGoal()
        context.insert(goal)

        let entryA = TestSupport.makeEntry(amount: 50, date: .now, type: .income, wallet: wallet)
        let entryB = TestSupport.makeEntry(amount: 30, date: .now, type: .income, wallet: wallet)
        context.insert(entryA)
        context.insert(entryB)

        let contributionA = TestSupport.makeGoalContribution(amount: 50, goal: goal, transaction: entryA)
        let contributionB = TestSupport.makeGoalContribution(amount: 30, goal: goal, transaction: entryB)
        context.insert(contributionA)
        context.insert(contributionB)
        try context.save()

        XCTAssertEqual(goal.contributions.count, 2)
        XCTAssertEqual(Set(goal.contributions.map { $0.amount }), [50, 30])
    }

    func testDifferentEntriesCanContributeToTheSameGoal() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let goal = TestSupport.makeGoal()
        context.insert(goal)

        let entryA = TestSupport.makeEntry(amount: 10, date: .now, type: .income, wallet: wallet)
        let entryB = TestSupport.makeEntry(amount: 20, date: .now, type: .income, wallet: wallet)
        context.insert(entryA)
        context.insert(entryB)
        context.insert(TestSupport.makeGoalContribution(amount: 10, goal: goal, transaction: entryA))
        context.insert(TestSupport.makeGoalContribution(amount: 20, goal: goal, transaction: entryB))
        try context.save()

        XCTAssertEqual(goal.contributions.count, 2)
        XCTAssertTrue(entryA.goalContribution !== entryB.goalContribution)
    }

    func testDifferentGoalsHaveIndependentContributions() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let goalA = TestSupport.makeGoal(name: "Vacation")
        let goalB = TestSupport.makeGoal(name: "Emergency Fund")
        context.insert(goalA)
        context.insert(goalB)

        let entryA = TestSupport.makeEntry(amount: 40, date: .now, type: .income, wallet: wallet)
        let entryB = TestSupport.makeEntry(amount: 60, date: .now, type: .income, wallet: wallet)
        context.insert(entryA)
        context.insert(entryB)
        context.insert(TestSupport.makeGoalContribution(amount: 40, goal: goalA, transaction: entryA))
        context.insert(TestSupport.makeGoalContribution(amount: 60, goal: goalB, transaction: entryB))
        try context.save()

        XCTAssertEqual(goalA.contributions.count, 1)
        XCTAssertEqual(goalB.contributions.count, 1)
        XCTAssertEqual(goalA.contributions.first?.amount, 40)
        XCTAssertEqual(goalB.contributions.first?.amount, 60)
    }

    /// The structural double-counting guard (`CLARITY_GOALS_ARCHITECTURE.md` §6): `Entry.
    /// goalContribution` is a to-one relationship, so linking a second `GoalContribution` to an
    /// already-linked `Entry` re-points the Entry's single back-reference to the new contribution
    /// — the old contribution's `transaction` is automatically nullified by SwiftData's
    /// bidirectional relationship maintenance. At no point can two `GoalContribution`s
    /// simultaneously reference the same `Entry`.
    func testSameEntryCannotBackTwoContributionsSimultaneously() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let goalA = TestSupport.makeGoal(name: "Vacation")
        let goalB = TestSupport.makeGoal(name: "Emergency Fund")
        context.insert(goalA)
        context.insert(goalB)
        let entry = TestSupport.makeEntry(amount: 500, date: .now, type: .income, wallet: wallet)
        context.insert(entry)

        let firstContribution = TestSupport.makeGoalContribution(amount: 500, goal: goalA, transaction: entry)
        context.insert(firstContribution)
        try context.save()
        XCTAssertTrue(entry.goalContribution === firstContribution)

        let secondContribution = TestSupport.makeGoalContribution(amount: 500, goal: goalB, transaction: entry)
        context.insert(secondContribution)
        try context.save()

        XCTAssertTrue(entry.goalContribution === secondContribution, "the entry's single back-reference now points at the newer contribution")
        XCTAssertNil(firstContribution.transaction, "the superseded contribution must lose its Entry link rather than silently keep double-counting it")
    }

    func testDeletingEntryDoesNotDeleteUnrelatedGoalData() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let goal = TestSupport.makeGoal()
        context.insert(goal)
        let entry = TestSupport.makeEntry(amount: 100, date: .now, type: .income, wallet: wallet)
        context.insert(entry)
        let contribution = TestSupport.makeGoalContribution(amount: 100, goal: goal, transaction: entry)
        context.insert(contribution)
        try context.save()

        context.delete(entry)
        try context.save()

        XCTAssertEqual((try context.fetchCount(FetchDescriptor<Goal>())), 1, "deleting the Entry must not delete the Goal")
        XCTAssertEqual((try context.fetchCount(FetchDescriptor<GoalContribution>())), 1, "the nullify delete rule must keep the GoalContribution row alive")
        XCTAssertNil(contribution.transaction, "the now-deleted Entry's back-reference must be nullified, not left dangling")
        XCTAssertEqual(goal.contributions.count, 1, "the Goal still sees its contribution row — it is now unlinked, not invalidated, and GoalCalculator continues to count it (Phase 2N-C0)")
    }

    func testDeletingGoalDoesNotDeleteUnderlyingEntries() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let goal = TestSupport.makeGoal()
        context.insert(goal)
        let entry = TestSupport.makeEntry(amount: 100, date: .now, type: .income, wallet: wallet)
        context.insert(entry)
        let contribution = TestSupport.makeGoalContribution(amount: 100, goal: goal, transaction: entry)
        context.insert(contribution)
        try context.save()

        context.delete(goal)
        try context.save()

        XCTAssertEqual((try context.fetchCount(FetchDescriptor<Entry>())), 1, "deleting the Goal must never delete the underlying financial transaction")
        XCTAssertEqual((try context.fetchCount(FetchDescriptor<GoalContribution>())), 0, "the cascade delete rule removes the now-meaningless contribution row, which is metadata, not a transaction")
        XCTAssertNil(entry.goalContribution, "the Entry survives, simply no longer linked to any goal")
    }

    func testArchivingGoalDoesNotDeleteContributionsOrEntries() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let goal = TestSupport.makeGoal(isArchived: false)
        context.insert(goal)
        let entry = TestSupport.makeEntry(amount: 100, date: .now, type: .income, wallet: wallet)
        context.insert(entry)
        let contribution = TestSupport.makeGoalContribution(amount: 100, goal: goal, transaction: entry)
        context.insert(contribution)
        try context.save()

        goal.isArchived = true
        try context.save()

        XCTAssertTrue(goal.isArchived)
        XCTAssertEqual(goal.contributions.count, 1, "archiving is a flag flip, never a deletion")
        XCTAssertTrue(contribution.transaction === entry)
    }

    func testDeletingWalletNullifiesContextWalletSafely() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet(name: "Emergency Fund Account")
        context.insert(wallet)
        let goal = TestSupport.makeGoal(contextWallet: wallet)
        context.insert(goal)
        try context.save()
        XCTAssertTrue(goal.contextWallet === wallet)

        // The wallet has no entries/incoming transfers, so Wallet's own `.deny`/`.nullify` rules
        // (Models/Wallet.swift) don't block this deletion — only the new contextWallet
        // relationship is under test here.
        context.delete(wallet)
        try context.save()

        XCTAssertEqual((try context.fetchCount(FetchDescriptor<Goal>())), 1, "deleting the context wallet must not delete the Goal")
        XCTAssertNil(goal.contextWallet, "the display-only reference must be nullified, never block or cascade")
    }

    // MARK: - Legacy compatibility

    func testWalletGoalAmountStillWorksExactlyAsBefore() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet(name: "Savings")
        wallet.goalAmount = 5000
        context.insert(wallet)
        try context.save()

        XCTAssertEqual(wallet.goalAmount, 5000, "legacy Wallet.goalAmount is untouched by the new Goal model")
    }

    func testExistingWalletBalanceBehaviorIsUnchanged() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet(name: "Checking", startingBalance: 100)
        context.insert(wallet)
        let expense = TestSupport.makeEntry(amount: 40, date: .now, type: .expense, wallet: wallet)
        context.insert(expense)
        try context.save()

        XCTAssertEqual(wallet.balance, 60, "Wallet.balance math is unaffected by the new Goal/GoalContribution schema additions")
    }

    func testNoAutomaticGoalIsCreatedFromLegacyGoalAmount() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet(name: "Savings")
        wallet.goalAmount = 3000
        context.insert(wallet)
        try context.save()

        XCTAssertEqual((try context.fetchCount(FetchDescriptor<Goal>())), 0, "setting a legacy goalAmount must never silently create a Goal row")
    }
}
