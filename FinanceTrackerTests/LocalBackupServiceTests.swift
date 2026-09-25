import XCTest
import SwiftData
@testable import FinanceTracker

/// Round-trip tests for `LocalBackupService` — export from one context (standing in for "device
/// A"), restore into a separate, fresh context ("device B"), and confirm the object graph
/// (including relationships) survives intact. Also confirms restore is a full replace, not a
/// merge, per its documented semantics.
final class LocalBackupServiceTests: XCTestCase {
    /// Builds a representative fixture spanning every model in the snapshot: two wallets, a
    /// transfer between them, a goal with both a linked and a manual contribution, and a shared
    /// event with an expense, a share, and a settlement recorded as a transaction — so every
    /// relationship kind (to-one, to-one optional, to-many, the Entry<->Settlement/
    /// GoalContribution link) is exercised by the round trip.
    private func makeFixture(in context: ModelContext) {
        let head = TestSupport.makeHeadCategory(name: "Everyday")
        context.insert(head)
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        context.insert(groceries)
        context.insert(Budget(category: groceries, monthlyLimit: 300, month: 3, year: 2026))

        let spending = TestSupport.makeWallet(name: "Spending", startingBalance: 100)
        let savings = TestSupport.makeWallet(name: "Savings", startingBalance: 0)
        context.insert(spending)
        context.insert(savings)

        let groceryEntry = TestSupport.makeEntry(amount: 42, date: .now, type: .expense, category: groceries, wallet: spending)
        context.insert(groceryEntry)
        let transfer = Entry(amount: 20, type: .transfer, wallet: spending, destinationWallet: savings)
        context.insert(transfer)

        let goal = TestSupport.makeGoal(name: "Emergency Fund", targetAmount: 1000, contextWallet: savings)
        context.insert(goal)
        context.insert(TestSupport.makeGoalContribution(amount: 20, goal: goal, transaction: transfer))
        context.insert(TestSupport.makeGoalContribution(amount: 50, goal: goal, note: "Birthday money"))

        let you = Person(displayName: "You", isCurrentUser: true)
        let alex = Person(displayName: "Alex")
        context.insert(you)
        context.insert(alex)

        let event = SharedEvent(title: "Trip", participants: [you, alex])
        context.insert(event)
        let expense = SharedExpense(amount: 80, currency: "EUR", category: groceries, paidBy: you, event: event)
        context.insert(expense)
        context.insert(SharedExpenseParticipant(person: alex, amount: 40, expense: expense))
        let settlementEntry = TestSupport.makeEntry(amount: 40, date: .now, type: .income, wallet: spending)
        context.insert(settlementEntry)
        context.insert(Settlement(fromPerson: alex, toPerson: you, amount: 40, paymentMethod: .cash, event: event, transaction: settlementEntry))

        try! context.save()
    }

    private func count<T: PersistentModel>(_ type: T.Type, in context: ModelContext) -> Int {
        (try? context.fetch(FetchDescriptor<T>()).count) ?? -1
    }

    func testRoundTripPreservesEveryModelsObjectCount() throws {
        let source = TestSupport.makeInMemoryContext()
        makeFixture(in: source)
        let data = try LocalBackupService.export(context: source)

        let destination = TestSupport.makeInMemoryContext()
        try LocalBackupService.restore(from: data, context: destination)

        XCTAssertEqual(count(HeadCategory.self, in: destination), count(HeadCategory.self, in: source))
        XCTAssertEqual(count(FinanceTracker.Category.self, in: destination), count(FinanceTracker.Category.self, in: source))
        XCTAssertEqual(count(Wallet.self, in: destination), count(Wallet.self, in: source))
        XCTAssertEqual(count(Entry.self, in: destination), count(Entry.self, in: source))
        XCTAssertEqual(count(Budget.self, in: destination), count(Budget.self, in: source))
        XCTAssertEqual(count(Goal.self, in: destination), count(Goal.self, in: source))
        XCTAssertEqual(count(GoalContribution.self, in: destination), count(GoalContribution.self, in: source))
        XCTAssertEqual(count(Person.self, in: destination), count(Person.self, in: source))
        XCTAssertEqual(count(SharedEvent.self, in: destination), count(SharedEvent.self, in: source))
        XCTAssertEqual(count(SharedExpense.self, in: destination), count(SharedExpense.self, in: source))
        XCTAssertEqual(count(SharedExpenseParticipant.self, in: destination), count(SharedExpenseParticipant.self, in: source))
        XCTAssertEqual(count(Settlement.self, in: destination), count(Settlement.self, in: source))
    }

    func testRoundTripPreservesRelationshipsAndValues() throws {
        let source = TestSupport.makeInMemoryContext()
        makeFixture(in: source)
        let data = try LocalBackupService.export(context: source)

        let destination = TestSupport.makeInMemoryContext()
        try LocalBackupService.restore(from: data, context: destination)

        let entries = try destination.fetch(FetchDescriptor<Entry>())
        let transfer = try XCTUnwrap(entries.first { $0.type == .transfer })
        XCTAssertEqual(transfer.wallet.name, "Spending")
        XCTAssertEqual(transfer.destinationWallet?.name, "Savings")

        let goals = try destination.fetch(FetchDescriptor<Goal>())
        let goal = try XCTUnwrap(goals.first)
        XCTAssertEqual(goal.contextWallet?.name, "Savings")
        XCTAssertEqual(GoalCalculator.progress(targetAmount: goal.targetAmount, contributions: goal.contributions).currentAmount, 70)

        let linkedContribution = try XCTUnwrap(goal.contributions.first { $0.transaction != nil })
        XCTAssertEqual(linkedContribution.transaction?.type, .transfer)
        let manualContribution = try XCTUnwrap(goal.contributions.first { $0.transaction == nil })
        XCTAssertEqual(manualContribution.note, "Birthday money")

        let events = try destination.fetch(FetchDescriptor<SharedEvent>())
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(Set(event.participants.map(\.displayName)), ["You", "Alex"])

        let settlements = try destination.fetch(FetchDescriptor<Settlement>())
        let settlement = try XCTUnwrap(settlements.first)
        XCTAssertEqual(settlement.fromPerson?.displayName, "Alex")
        XCTAssertEqual(settlement.toPerson?.displayName, "You")
        XCTAssertEqual(settlement.transaction?.amount, 40)
    }

    func testRestoreReplacesRatherThanMergesExistingData() throws {
        let source = TestSupport.makeInMemoryContext()
        makeFixture(in: source)
        let data = try LocalBackupService.export(context: source)

        // "Device B" already has unrelated data of its own before the restore.
        let destination = TestSupport.makeInMemoryContext()
        let staleHead = TestSupport.makeHeadCategory(name: "Stale")
        destination.insert(staleHead)
        destination.insert(TestSupport.makeWallet(name: "Stale Wallet"))
        try destination.save()

        try LocalBackupService.restore(from: data, context: destination)

        let wallets = try destination.fetch(FetchDescriptor<Wallet>())
        XCTAssertFalse(wallets.contains { $0.name == "Stale Wallet" })
        XCTAssertEqual(Set(wallets.map(\.name)), ["Spending", "Savings"])

        let headCategories = try destination.fetch(FetchDescriptor<HeadCategory>())
        XCTAssertFalse(headCategories.contains { $0.name == "Stale" })
    }

    func testEraseAllDataRemovesEveryModel() throws {
        let context = TestSupport.makeInMemoryContext()
        makeFixture(in: context)

        try LocalBackupService.eraseAllData(in: context)

        XCTAssertEqual(count(HeadCategory.self, in: context), 0)
        XCTAssertEqual(count(FinanceTracker.Category.self, in: context), 0)
        XCTAssertEqual(count(Wallet.self, in: context), 0)
        XCTAssertEqual(count(Entry.self, in: context), 0)
        XCTAssertEqual(count(Budget.self, in: context), 0)
        XCTAssertEqual(count(Goal.self, in: context), 0)
        XCTAssertEqual(count(GoalContribution.self, in: context), 0)
        XCTAssertEqual(count(Person.self, in: context), 0)
        XCTAssertEqual(count(SharedEvent.self, in: context), 0)
        XCTAssertEqual(count(SharedExpense.self, in: context), 0)
        XCTAssertEqual(count(SharedExpenseParticipant.self, in: context), 0)
        XCTAssertEqual(count(Settlement.self, in: context), 0)
        XCTAssertEqual(count(EventParticipant.self, in: context), 0)
    }

    func testExportedDataIsStableJSON() throws {
        let context = TestSupport.makeInMemoryContext()
        makeFixture(in: context)
        let data = try LocalBackupService.export(context: context)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(LocalBackupService.DataSnapshot.self, from: data)
        XCTAssertEqual(snapshot.wallets.count, 2)
        XCTAssertEqual(snapshot.entries.count, 3)
        XCTAssertEqual(snapshot.goalContributions.count, 2)
    }
}
