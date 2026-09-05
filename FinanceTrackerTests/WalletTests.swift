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
