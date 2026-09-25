import XCTest
import SwiftData
@testable import FinanceTracker

final class BudgetEligibilityTests: XCTestCase {

    func testNonExcludedExpenseIsEligible() {
        let wallet = TestSupport.makeWallet()
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet, excludeFromBudget: false)
        XCTAssertTrue(entry.isBudgetEligible)
    }

    func testExcludedExpenseIsNotEligible() {
        let wallet = TestSupport.makeWallet()
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet, excludeFromBudget: true)
        XCTAssertFalse(entry.isBudgetEligible)
    }

    func testNonExcludedIncomeIsEligible() {
        let wallet = TestSupport.makeWallet()
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .income, wallet: wallet, excludeFromBudget: false)
        XCTAssertTrue(entry.isBudgetEligible)
    }

    func testExcludedIncomeIsNotEligible() {
        let wallet = TestSupport.makeWallet()
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .income, wallet: wallet, excludeFromBudget: true)
        XCTAssertFalse(entry.isBudgetEligible)
    }

    /// Eligibility follows the same `excludeFromBudget` field for every entry type — a transfer
    /// is not a special case, even though transfers are never income/expense by type.
    func testTransferEligibilityFollowsTheSameFieldRule() {
        let source = TestSupport.makeWallet(name: "Source")
        let destination = TestSupport.makeWallet(name: "Destination")

        let eligibleTransfer = TestSupport.makeEntry(
            amount: 10, date: .now, type: .transfer, wallet: source, destinationWallet: destination, excludeFromBudget: false
        )
        let excludedTransfer = TestSupport.makeEntry(
            amount: 10, date: .now, type: .transfer, wallet: source, destinationWallet: destination, excludeFromBudget: true
        )

        XCTAssertTrue(eligibleTransfer.isBudgetEligible)
        XCTAssertFalse(excludedTransfer.isBudgetEligible)
    }

    func testArrayBudgetEligibleFiltersOutOnlyExcludedEntries() {
        let wallet = TestSupport.makeWallet()
        let eligible = TestSupport.makeEntry(amount: 5, date: .now, type: .expense, wallet: wallet, excludeFromBudget: false)
        let excluded = TestSupport.makeEntry(amount: 7, date: .now, type: .income, wallet: wallet, excludeFromBudget: true)
        let anotherEligible = TestSupport.makeEntry(amount: 3, date: .now, type: .expense, wallet: wallet, excludeFromBudget: false)

        let result = [eligible, excluded, anotherEligible].budgetEligible

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains { $0 === eligible })
        XCTAssertTrue(result.contains { $0 === anotherEligible })
        XCTAssertFalse(result.contains { $0 === excluded })
    }
}
