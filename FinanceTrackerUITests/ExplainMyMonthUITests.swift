import XCTest

/// Covers the "Explain My Month" entry point from Overview, the screen's own month navigation (no
/// separate month-selection screen — it opens straight on the current month, and changes by
/// tapping a bar in its Total Spending trend chart), and the no-data state for a fresh account with
/// no transactions logged.
final class ExplainMyMonthUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = UITestSupport.launchApp()
    }

    private func openExplainMyMonth() {
        app.tabBars.buttons["Overview"].tap()
        let entryCard = app.button(containing: "Explain My Month")
        XCTAssertTrue(entryCard.waitForExistence(timeout: 8), "Overview should show the Explain My Month entry card")
        entryCard.tap()
    }

    func testOpeningExplainMyMonthShowsTheCurrentMonthWithNoDataState() throws {
        openExplainMyMonth()

        let currentMonthLabel = Date.now.formatted(.dateTime.month(.wide).year())
        XCTAssertTrue(app.staticTexts[currentMonthLabel].waitForExistence(timeout: 8), "Should open directly on the current month, not a month-selection screen")

        // A freshly reset account (`-uiTestReset`) has no transactions at all yet.
        XCTAssertTrue(app.staticTexts["No spending logged yet"].waitForExistence(timeout: 8), "A month with no transactions should show the no-data state, not a misleading €0,00 total")
    }

    func testTappingAPastMonthBarInTheTrendChartSelectsThatMonth() throws {
        openExplainMyMonth()

        let currentMonthLabel = Date.now.formatted(.dateTime.month(.wide).year())
        XCTAssertTrue(app.staticTexts[currentMonthLabel].waitForExistence(timeout: 8))

        let previousMonthDate = Calendar.current.date(byAdding: .month, value: -1, to: .now)!
        let previousMonthLabel = previousMonthDate.formatted(.dateTime.month(.wide).year())

        // Each bar carries its own accessibility label (`MonthInsightsDetailView.trendChart`) —
        // both for VoiceOver and so this test can target one specific month's bar directly instead
        // of guessing a screen coordinate.
        let previousMonthBar = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", previousMonthLabel))
            .firstMatch
        XCTAssertTrue(previousMonthBar.waitForExistence(timeout: 8), "The trend chart should expose an accessible element for the previous month's bar")
        previousMonthBar.tap()

        XCTAssertTrue(app.staticTexts[previousMonthLabel].waitForExistence(timeout: 8), "Tapping the previous month's bar should select that month")
        XCTAssertFalse(app.staticTexts[currentMonthLabel].exists, "The old month label should no longer be shown")
    }

    func testAskAISectionIsReachableWithSuggestedQuestions() throws {
        openExplainMyMonth()

        XCTAssertTrue(app.staticTexts["ASK AI"].waitForExistence(timeout: 8), "The Ask AI section should be part of the screen")
        XCTAssertTrue(app.staticTexts["Why did I spend more this month?"].waitForExistence(timeout: 8), "A suggested question chip should be visible before anything is asked")
    }
}
