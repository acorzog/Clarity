import XCTest
@testable import FinanceTracker

/// Focused tests for `SpendingBreakdownView.donutAccessibilitySummary` — the pure,
/// presentation-only helper added in Phase 2F to give the donut chart a combined VoiceOver
/// summary. See `CLARITY_OVERVIEW_ACTIVITY_UX_SPEC.md` §14/§16.
///
/// This tests formatting logic only — it consumes the same `(name, amount)` pairs the chart
/// itself renders (already sourced from `BudgetCalculator` upstream in `SpendingBreakdownView`);
/// no calculation is exercised or duplicated here.
final class SpendingChartAccessibilityTests: XCTestCase {
    private func testDate(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func periodText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year())
    }

    func testEmptySpendingProducesMeaningfulNoExpensesSummary() {
        let month = testDate(2026, 9)
        let summary = SpendingBreakdownView.donutAccessibilitySummary(month: month, categories: [])
        XCTAssertEqual(summary, "Spending breakdown for \(periodText(month)). No expenses this month.")
    }

    func testSummaryIncludesEachCategoryName() {
        let month = testDate(2026, 9)
        let categories: [(name: String, amount: Decimal)] = [
            (name: "Food", amount: 450),
            (name: "Transport", amount: 210)
        ]
        let summary = SpendingBreakdownView.donutAccessibilitySummary(month: month, categories: categories)
        XCTAssertTrue(summary.contains("Food"))
        XCTAssertTrue(summary.contains("Transport"))
    }

    func testSummaryIncludesEachCategoryAmountUsingExistingCurrencyFormatting() {
        let month = testDate(2026, 9)
        let categories: [(name: String, amount: Decimal)] = [(name: "Food", amount: 450)]
        let summary = SpendingBreakdownView.donutAccessibilitySummary(month: month, categories: categories)
        XCTAssertTrue(summary.contains(Decimal(450).currencyFormatted))
    }

    func testSummaryIncludesShareAsAPercentageDerivedFromDisplayedAmounts() {
        let month = testDate(2026, 9)
        // 300 out of a 400 total is 75% — a simple, verifiable derivation from the two displayed
        // amounts, not a new financial calculation.
        let categories: [(name: String, amount: Decimal)] = [
            (name: "Food", amount: 300),
            (name: "Transport", amount: 100)
        ]
        let summary = SpendingBreakdownView.donutAccessibilitySummary(month: month, categories: categories)
        XCTAssertTrue(summary.contains("75 percent"))
        XCTAssertTrue(summary.contains("25 percent"))
    }

    func testSummaryOrderMatchesInputOrder() {
        let month = testDate(2026, 9)
        // The chart already sorts `donutSlices` descending before calling this formatter — the
        // formatter itself must not silently reorder, so callers stay the single source of order.
        let categories: [(name: String, amount: Decimal)] = [
            (name: "Food", amount: 450),
            (name: "Transport", amount: 210),
            (name: "Utilities", amount: 90)
        ]
        let summary = SpendingBreakdownView.donutAccessibilitySummary(month: month, categories: categories)
        let foodRange = summary.range(of: "Food")!
        let transportRange = summary.range(of: "Transport")!
        let utilitiesRange = summary.range(of: "Utilities")!
        XCTAssertTrue(foodRange.lowerBound < transportRange.lowerBound)
        XCTAssertTrue(transportRange.lowerBound < utilitiesRange.lowerBound)
    }

    /// Financial meaning (which category, how much, what share) must be fully recoverable from
    /// the label text alone — the donut's colors/wedge geometry carry no information VoiceOver
    /// needs, since none of it is encoded only there.
    func testSummaryMeaningDoesNotDependOnColor() {
        let month = testDate(2026, 9)
        let categories: [(name: String, amount: Decimal)] = [(name: "Food", amount: 450)]
        let summary = SpendingBreakdownView.donutAccessibilitySummary(month: month, categories: categories)

        XCTAssertFalse(summary.isEmpty)
        XCTAssertTrue(summary.contains("Food"))
        XCTAssertTrue(summary.contains(Decimal(450).currencyFormatted))
        XCTAssertTrue(summary.contains("100 percent"))
    }
}
