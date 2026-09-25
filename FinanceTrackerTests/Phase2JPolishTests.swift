import XCTest
@testable import FinanceTracker

/// Focused tests for the pure, presentation-only helpers added in Phase 2J:
/// `RemainingView.gaugeAccessibilitySummary` (VoiceOver summary for the custom-drawn
/// `RemainingGauge`, previously silent/confusing to VoiceOver — matches the donut/trend chart
/// precedent from Phases 2F/2F-B) and `OverviewSummaryView.summaryHasActivity` (distinguishes
/// "no budget-eligible data this month" from "a real balanced month" for the Income/Expenses/Net
/// row). See `CLARITY_V1_POLISH_REPORT.md` §4/§6.
final class RemainingGaugeAccessibilityTests: XCTestCase {
    func testAvailableSummaryWithNoBreakdown() {
        let summary = RemainingView.gaugeAccessibilitySummary(totalAvailable: 1000, totalSpent: 400, breakdown: [])
        XCTAssertEqual(summary, "\(Decimal(600).currencyFormatted) available to spend.")
    }

    func testOverAvailableSummaryWithNoBreakdown() {
        let summary = RemainingView.gaugeAccessibilitySummary(totalAvailable: 500, totalSpent: 700, breakdown: [])
        XCTAssertEqual(summary, "\(Decimal(200).currencyFormatted) over available.")
    }

    func testSummaryIncludesEachHeadCategoryInOrder() {
        let breakdown: [(name: String, left: Decimal)] = [
            (name: "Housing", left: 300),
            (name: "Food", left: -50)
        ]
        let summary = RemainingView.gaugeAccessibilitySummary(totalAvailable: 1000, totalSpent: 400, breakdown: breakdown)

        XCTAssertTrue(summary.hasPrefix("\(Decimal(600).currencyFormatted) available to spend."))
        XCTAssertTrue(summary.contains("Housing: \(Decimal(300).currencyFormatted) left."))
        XCTAssertTrue(summary.contains("Food: \(Decimal(-50).currencyFormatted) left."))

        let housingRange = summary.range(of: "Housing")
        let foodRange = summary.range(of: "Food")
        XCTAssertNotNil(housingRange)
        XCTAssertNotNil(foodRange)
        XCTAssertTrue(housingRange!.lowerBound < foodRange!.lowerBound)
    }

    func testZeroTotalAvailableReadsAsAvailableNotOver() {
        // totalLeft == 0 must not be misread as "over available" — `>= 0` is the boundary.
        let summary = RemainingView.gaugeAccessibilitySummary(totalAvailable: 400, totalSpent: 400, breakdown: [])
        XCTAssertTrue(summary.contains("available to spend"))
        XCTAssertFalse(summary.contains("over available"))
    }
}

final class OverviewSummaryActivityTests: XCTestCase {
    func testNoIncomeAndNoExpensesHasNoActivity() {
        XCTAssertFalse(OverviewSummaryView.summaryHasActivity(income: 0, expenses: 0))
    }

    func testIncomeOnlyHasActivity() {
        XCTAssertTrue(OverviewSummaryView.summaryHasActivity(income: 500, expenses: 0))
    }

    func testExpensesOnlyHasActivity() {
        XCTAssertTrue(OverviewSummaryView.summaryHasActivity(income: 0, expenses: 200))
    }

    /// A real balanced month (equal income and expenses, net zero) must still count as
    /// activity — this is a genuine financial fact, not an empty state.
    func testEqualIncomeAndExpensesStillHasActivity() {
        XCTAssertTrue(OverviewSummaryView.summaryHasActivity(income: 500, expenses: 500))
    }
}

final class InsightsAccessibilityTests: XCTestCase {
    func testPlannedVsActualEmptyDataProducesMeaningfulSummary() {
        let summary = InsightsView.plannedVsActualAccessibilitySummary(data: [])
        XCTAssertEqual(summary, "Planned versus actual spending. No budgeted or spent categories this month yet.")
    }

    func testPlannedVsActualIncludesEachCategoryInOrder() {
        let data: [(name: String, planned: Decimal, actual: Decimal)] = [
            (name: "Housing", planned: 800, actual: 750),
            (name: "Food", planned: 300, actual: 340)
        ]
        let summary = InsightsView.plannedVsActualAccessibilitySummary(data: data)

        XCTAssertTrue(summary.contains("Housing: planned \(Decimal(800).currencyFormatted), actual \(Decimal(750).currencyFormatted)."))
        XCTAssertTrue(summary.contains("Food: planned \(Decimal(300).currencyFormatted), actual \(Decimal(340).currencyFormatted)."))
        let housingRange = summary.range(of: "Housing")
        let foodRange = summary.range(of: "Food")
        XCTAssertNotNil(housingRange)
        XCTAssertNotNil(foodRange)
        XCTAssertTrue(housingRange!.lowerBound < foodRange!.lowerBound)
    }

    func testSpendPaceNoBudgetProducesMeaningfulSummary() {
        let summary = InsightsView.spendPaceAccessibilitySummary(totalBudget: 0, data: [])
        XCTAssertEqual(summary, "Spending pace. No budget set for this period.")
    }

    func testSpendPaceNoSpendingYetIsHonest() {
        let data = [DailyPacePoint(day: 1, actual: nil, onPace: 50)]
        let summary = InsightsView.spendPaceAccessibilitySummary(totalBudget: 1500, data: data)
        XCTAssertTrue(summary.contains("No spending recorded yet"))
    }

    func testSpendPaceReportsLatestDataPointAheadOfPace() {
        let data = [
            DailyPacePoint(day: 1, actual: 100, onPace: 50),
            DailyPacePoint(day: 2, actual: 220, onPace: 100)
        ]
        let summary = InsightsView.spendPaceAccessibilitySummary(totalBudget: 1500, data: data)
        XCTAssertTrue(summary.contains("Day 2"))
        XCTAssertTrue(summary.contains("ahead of pace"))
    }

    func testSpendPaceReportsLatestDataPointOnPace() {
        let data = [DailyPacePoint(day: 1, actual: 30, onPace: 50)]
        let summary = InsightsView.spendPaceAccessibilitySummary(totalBudget: 1500, data: data)
        XCTAssertTrue(summary.contains("on pace or under"))
    }
}
