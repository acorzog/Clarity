import XCTest
@testable import FinanceTracker

/// Coverage for `Array<Budget>.matchesFixedPlannedAmount(_:for:month:)` — the auto-mark signal
/// `TransactionSaving.createEntry`/`AddTransactionView`/the Shortcuts intents use to set
/// `isPlannedExpense` without a person toggling it by hand each time. Pure, in-memory
/// `Budget`/`Category` objects, matching `BudgetQueryingFixedCarryForwardTests`'s own style.
final class BudgetQueryingMatchesFixedPlannedAmountTests: XCTestCase {
    private func date(_ year: Int, _ month: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: 1))!
    }

    /// The worked example from the request this feature answers: "Gestor" is a fixed accountant
    /// fee, budgeted at 72.60 — a transaction for exactly that amount auto-marks.
    func testExactMatchOnAFixedPlannedCategoryAutoMarks() {
        let head = TestSupport.makeHeadCategory()
        let gestor = TestSupport.makeCategory(name: "Gestor", isFixedPlannedCategory: true, headCategory: head)
        let budgets = [TestSupport.makeBudget(category: gestor, monthlyLimit: 72.6, month: 6, year: 2026)]

        XCTAssertTrue(budgets.matchesFixedPlannedAmount(72.6, for: gestor, month: date(2026, 6)))
    }

    /// An amount that exceeds the planned budget — even on a Fixed Planned category — must not
    /// auto-mark; only an exact match counts, never "at least this much."
    func testAmountExceedingThePlannedBudgetDoesNotAutoMarkEvenOnAFixedPlannedCategory() {
        let head = TestSupport.makeHeadCategory()
        let gestor = TestSupport.makeCategory(name: "Gestor", isFixedPlannedCategory: true, headCategory: head)
        let budgets = [TestSupport.makeBudget(category: gestor, monthlyLimit: 72.6, month: 6, year: 2026)]

        XCTAssertFalse(budgets.matchesFixedPlannedAmount(90, for: gestor, month: date(2026, 6)))
    }

    /// An amount under the planned budget must not auto-mark either — only an exact match.
    func testAmountUnderThePlannedBudgetDoesNotAutoMark() {
        let head = TestSupport.makeHeadCategory()
        let gestor = TestSupport.makeCategory(name: "Gestor", isFixedPlannedCategory: true, headCategory: head)
        let budgets = [TestSupport.makeBudget(category: gestor, monthlyLimit: 72.6, month: 6, year: 2026)]

        XCTAssertFalse(budgets.matchesFixedPlannedAmount(50, for: gestor, month: date(2026, 6)))
    }

    /// The other worked example: "Groceries" is budgeted at 300 across many smaller purchases —
    /// none of a 20-40 range of individual transactions should ever auto-mark, because the
    /// category itself was never flagged `isFixedPlannedCategory` in the first place. This must
    /// hold even if, by coincidence, a single purchase happens to equal the planned total exactly.
    func testUnflaggedCategoryNeverAutoMarksRegardlessOfAmount() {
        let head = TestSupport.makeHeadCategory()
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: head) // isFixedPlannedCategory defaults false
        let budgets = [TestSupport.makeBudget(category: groceries, monthlyLimit: 300, month: 6, year: 2026)]

        XCTAssertFalse(budgets.matchesFixedPlannedAmount(35, for: groceries, month: date(2026, 6)))
        // Coincidental exact match on an unflagged category — still must not auto-mark.
        XCTAssertFalse(budgets.matchesFixedPlannedAmount(300, for: groceries, month: date(2026, 6)))
    }

    func testNilCategoryNeverAutoMarks() {
        XCTAssertFalse([Budget]().matchesFixedPlannedAmount(72.6, for: nil, month: date(2026, 6)))
    }

    /// A Fixed Planned category with no budget set for the month at all (nothing to match
    /// against) must not auto-mark — guards the `planned > 0` check from matching a stray `0`.
    func testFixedPlannedCategoryWithNoBudgetForTheMonthDoesNotAutoMark() {
        let head = TestSupport.makeHeadCategory()
        let gestor = TestSupport.makeCategory(name: "Gestor", isFixedPlannedCategory: true, headCategory: head)

        XCTAssertFalse([Budget]().matchesFixedPlannedAmount(0, for: gestor, month: date(2026, 6)))
    }

    /// A Fixed carry-forward amount (see `BudgetQueryingFixedCarryForwardTests`) still counts as
    /// "the planned amount for this month" even with no explicit row for the month itself —
    /// `matchesFixedPlannedAmount` reuses `amount(for:month:)` rather than re-deriving it.
    func testMatchesAgainstACarriedForwardFixedAmount() {
        let head = TestSupport.makeHeadCategory()
        let rent = TestSupport.makeCategory(name: "Rent", isFixedPlannedCategory: true, headCategory: head)
        let budgets = [TestSupport.makeBudget(category: rent, monthlyLimit: 1200, month: 3, year: 2026, isFixed: true)]

        XCTAssertTrue(budgets.matchesFixedPlannedAmount(1200, for: rent, month: date(2026, 4)))
    }
}
