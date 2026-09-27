import XCTest
import SwiftData
@testable import FinanceTracker

final class WalletTests: XCTestCase {

    // MARK: - Balance math

    func testBalanceIncludesExpenseIncomeAndTransferWithoutDoubleCounting() throws {
        let context = TestSupport.makeInMemoryContext()

        let walletA = TestSupport.makeWallet(name: "A", startingBalance: 1000)
        let walletB = TestSupport.makeWallet(name: "B", startingBalance: 500)
        context.insert(walletA)
        context.insert(walletB)

        let expense = Entry(amount: 50, type: .expense, wallet: walletA)
        let income = Entry(amount: 100, type: .income, wallet: walletA)
        let transfer = Entry(amount: 30, type: .transfer, wallet: walletA, destinationWallet: walletB)
        context.insert(expense)
        context.insert(income)
        context.insert(transfer)
        try context.save()

        // A: 1000 - 50 (expense) + 100 (income) - 30 (transfer out) = 1020
        XCTAssertEqual(walletA.balance, 1020)
        // B: 500 + 30 (transfer in) = 530
        XCTAssertEqual(walletB.balance, 530)

        // The transfer's -30/+30 nets to zero across both wallets — it's a move, not new money.
        let totalBalance = walletA.balance + walletB.balance
        let totalStarting = walletA.startingBalance + walletB.startingBalance
        XCTAssertEqual(totalBalance, totalStarting + (100 - 50))
    }

    // MARK: - Future-dated entries don't reduce the current balance

    private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// The exact scenario reported: an expense entered today but dated a couple of days out (a
    /// known upcoming charge) must not move the wallet's current balance until that day arrives —
    /// the balance represents the real account balance right now, which hasn't actually changed yet.
    func testAFutureDatedExpenseDoesNotReduceTheCurrentBalance() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet(startingBalance: 1000)
        context.insert(wallet)

        let today = testDate(2026, 9, 27)
        let futureExpense = TestSupport.makeEntry(amount: 299, date: testDate(2026, 9, 29), type: .expense, wallet: wallet)
        context.insert(futureExpense)
        try context.save()

        XCTAssertEqual(wallet.balance(asOf: today), 1000, "a charge dated 2 days out must not have posted yet")
    }

    /// Once "today" actually reaches (or passes) the entry's date, it must count normally —
    /// this is the other half of the same behavior: not "never counted," just "not counted early."
    func testTheSameEntryCountsOnceItsOwnDateArrives() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet(startingBalance: 1000)
        context.insert(wallet)

        let entryDate = testDate(2026, 9, 29)
        let expense = TestSupport.makeEntry(amount: 299, date: entryDate, type: .expense, wallet: wallet)
        context.insert(expense)
        try context.save()

        XCTAssertEqual(wallet.balance(asOf: entryDate), 701, "on its own date, the charge has posted")
        XCTAssertEqual(wallet.balance(asOf: testDate(2026, 9, 30)), 701, "and stays posted on any later day")
    }

    /// A mix of past, today, and future entries — only past/today should count; the future one
    /// (regardless of its position in the underlying unsorted `entries` array) must be excluded.
    func testOnlyPastAndTodayEntriesCountTowardTheCurrentBalanceWhenMixedWithFutureOnes() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet(startingBalance: 500)
        context.insert(wallet)

        let today = testDate(2026, 9, 27)
        let past = TestSupport.makeEntry(amount: 50, date: testDate(2026, 9, 20), type: .expense, wallet: wallet)
        let todayEntry = TestSupport.makeEntry(amount: 20, date: today, type: .income, wallet: wallet)
        let future = TestSupport.makeEntry(amount: 299, date: testDate(2026, 10, 5), type: .expense, wallet: wallet)
        context.insert(past); context.insert(todayEntry); context.insert(future)
        try context.save()

        // 500 - 50 (past expense) + 20 (today's income) = 470 — the future 299 expense excluded.
        XCTAssertEqual(wallet.balance(asOf: today), 470)
    }

    /// `balance` (no arguments) is just `balance(asOf: .now)` — this pins that relationship so the
    /// two can never silently drift apart, since every call site in the app uses the plain
    /// `wallet.balance` property, not `balance(asOf:)` directly.
    func testPlainBalancePropertyMatchesBalanceAsOfNow() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet(startingBalance: 1000)
        context.insert(wallet)
        let futureExpense = TestSupport.makeEntry(amount: 299, date: Date().addingTimeInterval(60 * 60 * 24 * 2), type: .expense, wallet: wallet)
        context.insert(futureExpense)
        try context.save()

        XCTAssertEqual(wallet.balance, wallet.balance(asOf: .now))
        XCTAssertEqual(wallet.balance, 1000, "the future expense must not have reduced today's plain .balance either")
    }

    func testTransferEffectAppliesOnlyOnceOnEachSide() throws {
        let context = TestSupport.makeInMemoryContext()
        let source = TestSupport.makeWallet(name: "Source", startingBalance: 0)
        let destination = TestSupport.makeWallet(name: "Destination", startingBalance: 0)
        context.insert(source)
        context.insert(destination)

        let transfer = Entry(amount: 40, type: .transfer, wallet: source, destinationWallet: destination)
        context.insert(transfer)
        try context.save()

        XCTAssertEqual(source.effect(of: transfer), -40)
        XCTAssertEqual(destination.effect(of: transfer), 40)
        // A wallet unrelated to the transfer sees no effect from it at all.
        let bystander = TestSupport.makeWallet(name: "Bystander")
        XCTAssertEqual(bystander.effect(of: transfer), 0)
    }

    // MARK: - Deletion blocking

    func testCanBeDeletedIsTrueWithNoEntriesOrTransfers() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        try context.save()

        XCTAssertTrue(wallet.canBeDeleted)
    }

    func testDeletionBlockedWhenEntriesNonEmpty() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let entry = Entry(amount: 10, type: .expense, wallet: wallet)
        context.insert(entry)
        try context.save()

        XCTAssertFalse(wallet.canBeDeleted)

        // SwiftData's `.deny` delete rule on `entries` enforces this at the persistence layer too.
        context.delete(wallet)
        XCTAssertThrowsError(try context.save())
    }

    func testDeletionBlockedWhenIncomingTransfersNonEmpty() throws {
        let context = TestSupport.makeInMemoryContext()
        let source = TestSupport.makeWallet(name: "Source")
        let destination = TestSupport.makeWallet(name: "Destination")
        context.insert(source)
        context.insert(destination)
        let transfer = Entry(amount: 25, type: .transfer, wallet: source, destinationWallet: destination)
        context.insert(transfer)
        try context.save()

        XCTAssertFalse(destination.canBeDeleted)
    }

    // MARK: - Wallet.active / preferredFallback

    func testActiveExcludesArchivedWallets() {
        let active = TestSupport.makeWallet(name: "Active")
        let archived = TestSupport.makeWallet(name: "Archived", isArchived: true)

        XCTAssertEqual(Wallet.active(in: [active, archived]).map(\.name), ["Active"])
    }

    func testPreferredFallbackPrefersDefaultOverFirst() {
        let first = TestSupport.makeWallet(name: "First")
        let defaultWallet = TestSupport.makeWallet(name: "Default", isDefault: true)
        let third = TestSupport.makeWallet(name: "Third")

        XCTAssertEqual(Wallet.preferredFallback(among: [first, defaultWallet, third])?.name, "Default")
    }

    func testPreferredFallbackIgnoresArchivedDefault() {
        let first = TestSupport.makeWallet(name: "First")
        let archivedDefault = TestSupport.makeWallet(name: "ArchivedDefault", isDefault: true, isArchived: true)

        XCTAssertEqual(Wallet.preferredFallback(among: [first, archivedDefault])?.name, "First")
    }

    func testPreferredFallbackReturnsNilWhenNoActiveWallets() {
        let archived = TestSupport.makeWallet(name: "Archived", isArchived: true)
        XCTAssertNil(Wallet.preferredFallback(among: [archived]))
    }
}
