import XCTest
import SwiftData
@testable import FinanceTracker

final class NetWorthCalculatorTests: XCTestCase {

    func testNetWorthSumsIncludedActiveWallets() {
        let a = TestSupport.makeWallet(name: "A", startingBalance: 1000)
        let b = TestSupport.makeWallet(name: "B", startingBalance: 500)

        XCTAssertEqual(NetWorthCalculator.netWorth(wallets: [a, b]), 1500)
    }

    func testNetWorthExcludesWalletsWithIncludeInNetWorthFalse() {
        let included = TestSupport.makeWallet(name: "Included", startingBalance: 1000)
        let excluded = TestSupport.makeWallet(name: "Excluded", startingBalance: 5000, includeInNetWorth: false)

        XCTAssertEqual(NetWorthCalculator.netWorth(wallets: [included, excluded]), 1000)
    }

    func testNetWorthExcludesArchivedWallets() {
        let active = TestSupport.makeWallet(name: "Active", startingBalance: 1000)
        let archived = TestSupport.makeWallet(name: "Archived", startingBalance: 5000, isArchived: true)

        XCTAssertEqual(NetWorthCalculator.netWorth(wallets: [active, archived]), 1000)
    }

    func testNetWorthCanBeNegativeWhenDebtOutweighsAssets() {
        let spending = TestSupport.makeWallet(name: "Spending", startingBalance: 200)
        let debt = TestSupport.makeWallet(name: "Debt", startingBalance: -800)

        XCTAssertEqual(NetWorthCalculator.netWorth(wallets: [spending, debt]), -600)
    }

    func testNetWorthReflectsEntriesNotJustStartingBalance() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet(startingBalance: 100)
        context.insert(wallet)
        let expense = TestSupport.makeEntry(amount: 40, date: .now, type: .expense, wallet: wallet)
        context.insert(expense)
        try? context.save()

        // 100 - 40 = 60, matching Wallet.balance exactly — NetWorthCalculator never re-derives this.
        XCTAssertEqual(NetWorthCalculator.netWorth(wallets: [wallet]), 60)
    }

    func testNetWorthOfEmptyWalletListIsZero() {
        XCTAssertEqual(NetWorthCalculator.netWorth(wallets: []), 0)
    }
}
