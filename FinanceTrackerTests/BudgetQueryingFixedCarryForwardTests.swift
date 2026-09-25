import XCTest
@testable import FinanceTracker

/// Coverage for `Array<Budget>.amount(for:month:)`/`isFixed(for:month:)`'s carry-forward
/// behavior (Plan → Allocate's Fixed/Variable swipe toggle — see `PlanView.setFixed` and
/// `PlannedAmountRow`'s leading swipe action) — pure, in-memory `Budget`/`Category` objects, no
/// `ModelContext` needed since neither function reads a relationship that requires persistence to
/// exist. See `PersistenceProbeTests` for the same behavior exercised through real SwiftData
/// persistence instead of plain arrays.
final class BudgetQueryingFixedCarryForwardTests: XCTestCase {
    private func date(_ year: Int, _ month: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: 1))!
    }

    func testFixedBudgetCarriesForwardToALaterMonthWithNoEntry() {
        let head = TestSupport.makeHeadCategory()
        let rent = TestSupport.makeCategory(name: "Rent", headCategory: head)
        let budgets = [TestSupport.makeBudget(category: rent, monthlyLimit: 1200, month: 3, year: 2026, isFixed: true)]

        XCTAssertEqual(budgets.amount(for: rent, month: date(2026, 4)), 1200)
        XCTAssertTrue(budgets.isFixed(for: rent, month: date(2026, 4)))
    }

    func testVariableBudgetDoesNotCarryForward() {
        let head = TestSupport.makeHeadCategory()
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let budgets = [TestSupport.makeBudget(category: groceries, monthlyLimit: 300, month: 3, year: 2026, isFixed: false)]

        XCTAssertEqual(budgets.amount(for: groceries, month: date(2026, 4)), 0)
        XCTAssertFalse(budgets.isFixed(for: groceries, month: date(2026, 4)))
    }

    func testExplicitEntryForTheMonthWinsOverACarriedForwardValue() {
        let head = TestSupport.makeHeadCategory()
        let rent = TestSupport.makeCategory(name: "Rent", headCategory: head)
        let budgets = [
            TestSupport.makeBudget(category: rent, monthlyLimit: 1200, month: 3, year: 2026, isFixed: true),
            TestSupport.makeBudget(category: rent, monthlyLimit: 1300, month: 4, year: 2026, isFixed: true)
        ]

        // April's own (raised) entry is used, not March's carried-forward amount.
        XCTAssertEqual(budgets.amount(for: rent, month: date(2026, 4)), 1300)
        // May has no entry of its own — carries forward from the closest earlier fixed entry,
        // which is now April's raised amount, not March's.
        XCTAssertEqual(budgets.amount(for: rent, month: date(2026, 5)), 1300)
    }

    func testCarryForwardSkipsBackToTheClosestFixedMonthAcrossAGap() {
        let head = TestSupport.makeHeadCategory()
        let rent = TestSupport.makeCategory(name: "Rent", headCategory: head)
        // Only January is on record; several months have passed with nothing entered since.
        let budgets = [TestSupport.makeBudget(category: rent, monthlyLimit: 1000, month: 1, year: 2026, isFixed: true)]

        XCTAssertEqual(budgets.amount(for: rent, month: date(2026, 6)), 1000)
    }

    func testTurningFixedOffStopsFutureCarryForward() {
        let head = TestSupport.makeHeadCategory()
        let rent = TestSupport.makeCategory(name: "Rent", headCategory: head)
        let budgets = [
            TestSupport.makeBudget(category: rent, monthlyLimit: 1200, month: 3, year: 2026, isFixed: true),
            // The user switched it back to Variable in April.
            TestSupport.makeBudget(category: rent, monthlyLimit: 1200, month: 4, year: 2026, isFixed: false)
        ]

        XCTAssertEqual(budgets.amount(for: rent, month: date(2026, 5)), 0)
        XCTAssertFalse(budgets.isFixed(for: rent, month: date(2026, 5)))
    }

    func testNoEntryAnywhereYieldsZeroUnchanged() {
        let head = TestSupport.makeHeadCategory()
        let utilities = TestSupport.makeCategory(name: "Utilities", headCategory: head)
        let budgets: [Budget] = []

        XCTAssertEqual(budgets.amount(for: utilities, month: date(2026, 4)), 0)
        XCTAssertFalse(budgets.isFixed(for: utilities, month: date(2026, 4)))
    }
}
