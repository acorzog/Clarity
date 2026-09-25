import XCTest
@testable import FinanceTracker

private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
}

/// Focused tests for `SpendingInsightsAggregation` (Phase 2N-G) — proves `SpendingInsightsCardView`'s
/// financial inputs now agree with `BudgetEligibility`/`BudgetCalculator`, the same gate/source
/// every other budget/spending surface on Overview already uses. Pure, in-memory objects, no
/// `ModelContext` — matching `GoalCalculatorTests`'s own "prefer pure tests" convention, since
/// neither function under test reads a relationship that needs persistence to exist.
final class SpendingInsightsAggregationTests: XCTestCase {

    // MARK: - eligibleExpenses

    func testExcludeFromBudgetExpenseIsExcluded() {
        let wallet = TestSupport.makeWallet()
        let eligible = TestSupport.makeEntry(amount: 50, date: testDate(2026, 3, 10), type: .expense, wallet: wallet)
        let excluded = TestSupport.makeEntry(amount: 999, date: testDate(2026, 3, 11), type: .expense, wallet: wallet, excludeFromBudget: true)

        let result = SpendingInsightsAggregation.eligibleExpenses(from: [eligible, excluded], in: testDate(2026, 3, 1))

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.first === eligible, "an excludeFromBudget expense must never appear in the insight's figures")
    }

    func testOrdinaryEligibleExpensesAreUnchanged() {
        let wallet = TestSupport.makeWallet()
        let entries = (1...3).map { TestSupport.makeEntry(amount: Decimal($0) * 10, date: testDate(2026, 3, $0), type: .expense, wallet: wallet) }

        let result = SpendingInsightsAggregation.eligibleExpenses(from: entries, in: testDate(2026, 3, 1))

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.totalExpenses, 60)
    }

    func testIncomeAndTransferEntriesAreExcludedRegardlessOfEligibility() {
        let wallet = TestSupport.makeWallet()
        let destination = TestSupport.makeWallet(name: "Savings")
        let expense = TestSupport.makeEntry(amount: 40, date: testDate(2026, 3, 5), type: .expense, wallet: wallet)
        let income = TestSupport.makeEntry(amount: 500, date: testDate(2026, 3, 5), type: .income, wallet: wallet)
        let transfer = TestSupport.makeEntry(amount: 100, date: testDate(2026, 3, 5), type: .transfer, wallet: wallet, destinationWallet: destination)

        let result = SpendingInsightsAggregation.eligibleExpenses(from: [expense, income, transfer], in: testDate(2026, 3, 1))

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.first === expense)
    }

    func testEntriesOutsideTheMonthAreExcluded() {
        let wallet = TestSupport.makeWallet()
        let inMonth = TestSupport.makeEntry(amount: 40, date: testDate(2026, 3, 5), type: .expense, wallet: wallet)
        let otherMonth = TestSupport.makeEntry(amount: 999, date: testDate(2026, 4, 1), type: .expense, wallet: wallet)

        let result = SpendingInsightsAggregation.eligibleExpenses(from: [inMonth, otherMonth], in: testDate(2026, 3, 1))

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.first === inMonth)
    }

    // MARK: - budgetTotal

    func testHiddenCategoryIsExcludedFromBudgetTotal() {
        let head = TestSupport.makeHeadCategory()
        let visible = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let hidden = TestSupport.makeCategory(name: "Rare Category", headCategory: head)
        head.categories = [visible, hidden]

        let visibleBudget = TestSupport.makeBudget(category: visible, monthlyLimit: 300, month: 3, year: 2026)
        let hiddenBudget = TestSupport.makeBudget(category: hidden, monthlyLimit: 700, month: 3, year: 2026, isHidden: true)

        let total = SpendingInsightsAggregation.budgetTotal(
            budgets: [visibleBudget, hiddenBudget],
            headCategories: [head],
            month: testDate(2026, 3, 1)
        )

        XCTAssertEqual(total, 300, "a hidden category's planned amount must not inflate the insight's budget total, matching BudgetCalculator.totalBudgeted")
    }

    func testOrdinaryVisibleBudgetsAreUnchanged() {
        let head = TestSupport.makeHeadCategory()
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let transport = TestSupport.makeCategory(name: "Transport", headCategory: head)
        head.categories = [groceries, transport]

        let budgets = [
            TestSupport.makeBudget(category: groceries, monthlyLimit: 300, month: 3, year: 2026),
            TestSupport.makeBudget(category: transport, monthlyLimit: 150, month: 3, year: 2026)
        ]

        let total = SpendingInsightsAggregation.budgetTotal(budgets: budgets, headCategories: [head], month: testDate(2026, 3, 1))

        XCTAssertEqual(total, 450)
    }

    func testZeroBudgetTotalIsNilNotZero() {
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        head.categories = [category]

        let total = SpendingInsightsAggregation.budgetTotal(budgets: [], headCategories: [head], month: testDate(2026, 3, 1))

        XCTAssertNil(total, "matches the card's existing 'omit the budget line entirely' behavior when nothing is budgeted")
    }
}
