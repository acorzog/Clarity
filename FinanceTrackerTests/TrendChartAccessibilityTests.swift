import XCTest
@testable import FinanceTracker

/// Focused tests for `OverviewSummaryView.trendAccessibilitySummary` — the pure,
/// presentation-only helper added in Phase 2F-B to give the 6-month spending trend chart a
/// combined VoiceOver summary. See `CLARITY_OVERVIEW_ACTIVITY_UX_SPEC.md` §14/§16.
///
/// This tests formatting logic only — it consumes the same `(month, total)` pairs `Chart(trend)`
/// already renders (each `total` already an existing `.budgetEligible` monthly expense sum
/// computed upstream in `OverviewSummaryView`); no calculation is exercised or duplicated here.
final class TrendChartAccessibilityTests: XCTestCase {
    private func testDate(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func monthText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year())
    }

    func testEmptyTrendProducesMeaningfulNoDataSummary() {
        let summary = OverviewSummaryView.trendAccessibilitySummary(points: [])
        XCTAssertEqual(summary, "Monthly spending trend. No data available.")
    }

    func testSummaryCommunicatesThePeriod() {
        let points: [(month: Date, total: Decimal)] = [
            (month: testDate(2026, 4), total: 1200),
            (month: testDate(2026, 5), total: 1050),
            (month: testDate(2026, 6), total: 1300)
        ]
        let summary = OverviewSummaryView.trendAccessibilitySummary(points: points)
        XCTAssertTrue(summary.contains("\(monthText(testDate(2026, 4))) to \(monthText(testDate(2026, 6)))"))
    }

    func testSummaryIncludesEachDataPointsMonth() {
        let points: [(month: Date, total: Decimal)] = [
            (month: testDate(2026, 4), total: 1200),
            (month: testDate(2026, 5), total: 1050),
            (month: testDate(2026, 6), total: 1300)
        ]
        let summary = OverviewSummaryView.trendAccessibilitySummary(points: points)
        XCTAssertTrue(summary.contains(monthText(testDate(2026, 4))))
        XCTAssertTrue(summary.contains(monthText(testDate(2026, 5))))
        XCTAssertTrue(summary.contains(monthText(testDate(2026, 6))))
    }

    func testSummaryIncludesEachDataPointsValueUsingExistingCurrencyFormatting() {
        let points: [(month: Date, total: Decimal)] = [(month: testDate(2026, 4), total: 1200)]
        let summary = OverviewSummaryView.trendAccessibilitySummary(points: points)
        XCTAssertTrue(summary.contains(Decimal(1200).currencyFormatted))
    }

    func testSummaryOrderMatchesInputOrder() {
        // `trend` is built oldest-to-newest by `OverviewSummaryView` — the formatter must not
        // silently reorder, so the visible chart (left-to-right chronological) and the spoken
        // summary always agree. Searches for the point-line form ("<month>: ") specifically,
        // since the leading period header ("April 2026 to June 2026.") also mentions the first
        // and last months and would otherwise be matched first.
        let points: [(month: Date, total: Decimal)] = [
            (month: testDate(2026, 4), total: 1200),
            (month: testDate(2026, 5), total: 1050),
            (month: testDate(2026, 6), total: 1300)
        ]
        let summary = OverviewSummaryView.trendAccessibilitySummary(points: points)
        let aprilRange = summary.range(of: "\(monthText(testDate(2026, 4))): ")!
        let mayRange = summary.range(of: "\(monthText(testDate(2026, 5))): ")!
        let juneRange = summary.range(of: "\(monthText(testDate(2026, 6))): ")!
        XCTAssertTrue(aprilRange.lowerBound < mayRange.lowerBound)
        XCTAssertTrue(mayRange.lowerBound < juneRange.lowerBound)
    }

    func testSummaryHandlesAZeroValueMonthWithoutSpecialCasing() {
        let points: [(month: Date, total: Decimal)] = [(month: testDate(2026, 4), total: 0)]
        let summary = OverviewSummaryView.trendAccessibilitySummary(points: points)
        XCTAssertTrue(summary.contains(Decimal(0).currencyFormatted))
    }

    /// A single-point series must still read as a coherent sentence (no dangling "to" with no
    /// end month), matching the guard in the implementation for `points.count == 1`.
    func testSingleDataPointDoesNotProduceADanglingPeriodRange() {
        let points: [(month: Date, total: Decimal)] = [(month: testDate(2026, 4), total: 1200)]
        let summary = OverviewSummaryView.trendAccessibilitySummary(points: points)
        XCTAssertFalse(summary.contains(" to "))
        XCTAssertTrue(summary.contains(monthText(testDate(2026, 4))))
    }

    /// Financial meaning (which month, how much) must be fully recoverable from the label text
    /// alone — the trend line's color carries no information VoiceOver needs, since none of it
    /// is encoded only there.
    func testSummaryMeaningDoesNotDependOnColor() {
        let points: [(month: Date, total: Decimal)] = [
            (month: testDate(2026, 4), total: 1200),
            (month: testDate(2026, 5), total: 1050)
        ]
        let summary = OverviewSummaryView.trendAccessibilitySummary(points: points)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertTrue(summary.contains(monthText(testDate(2026, 4))))
        XCTAssertTrue(summary.contains(Decimal(1200).currencyFormatted))
    }
}
