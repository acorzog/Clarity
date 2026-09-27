import XCTest

/// Covers two Remaining-screen additions: the collapsed-by-default "Consolidated" section (a
/// head-category → category recap of every category with spend this period, sitting once right
/// below the gauge) and `CategoryEntriesDetailView` showing each transaction's date (needed once
/// entries aren't already grouped under a per-day section header).
///
/// Uses two categories from different head categories — "Clothing" (Entertainment) and "Coffee &
/// Snacks" (Food & Drinks) — so the test can assert the disclosure actually separates them into
/// distinct head groups rather than just rendering one flat list.
final class RemainingOtherExpensesUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = UITestSupport.launchApp()
    }

    private func openRemaining() {
        app.tabBars.buttons["Plan"].tap()
        let remainingButton = app.buttons["Remaining"]
        XCTAssertTrue(remainingButton.waitForExistence(timeout: 8), "Plan should default to Remaining")
        remainingButton.tap()
    }

    func testConsolidatedSectionGroupsByHeadCategoryAndDrillsToDatedEntries() throws {
        UITestSupport.addExpense(app: app, amount: "45", category: "Clothing")
        UITestSupport.addExpense(app: app, amount: "12", category: "Coffee & Snacks")

        openRemaining()

        // Its own identifier (rather than matching on visible text) since "Consolidated" is a
        // recap of the same spend already shown in the ordinary `HeadRemainingSection` cards
        // below — by design, not something to disambiguate away, but it does mean text alone
        // isn't a reliable way to locate *this* row specifically.
        // `.accessibilityElement(children: .combine)` surfaces the identifier on more than one
        // node in the tree (the merged label plus the interactive control wrapping it) — `.firstMatch`
        // rather than a bare subscript, which fails on ambiguity.
        let consolidated = app.descendants(matching: .any).matching(identifier: "consolidatedSection").firstMatch
        XCTAssertTrue(consolidated.waitForExistence(timeout: 8), "Consolidated should render as an expandable disclosure, collapsed by default")
        consolidated.tap()

        let entertainmentGroup = app.descendants(matching: .any).matching(identifier: "consolidatedHeadGroup-Entertainment").firstMatch
        let foodGroup = app.descendants(matching: .any).matching(identifier: "consolidatedHeadGroup-Food & Drinks").firstMatch
        XCTAssertTrue(entertainmentGroup.waitForExistence(timeout: 5), "Clothing's head category should appear once Consolidated is expanded")
        XCTAssertTrue(foodGroup.waitForExistence(timeout: 5), "Coffee & Snacks' head category should appear as its own group, separate from Entertainment")

        foodGroup.tap()
        let coffeeCategoryRow = app.descendants(matching: .any).matching(identifier: "consolidatedCategoryRow-Coffee & Snacks").firstMatch
        XCTAssertTrue(coffeeCategoryRow.waitForExistence(timeout: 5), "Coffee & Snacks should appear once Food & Drinks is expanded")
        // Entertainment's own categories shouldn't leak into Food & Drinks' expanded group.
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "consolidatedCategoryRow-Clothing").firstMatch.exists)
        coffeeCategoryRow.tap()

        XCTAssertTrue(app.navigationBars["Coffee & Snacks"].waitForExistence(timeout: 8), "Tapping the category row should drill into its transaction list")
        // Locale/currency formatting varies by device settings, so match on the digits rather
        // than a hardcoded "-12,00 €"/"-$12.00" string.
        XCTAssertTrue(app.staticText(containing: "12").waitForExistence(timeout: 5), "The transaction added above should be listed")

        // The list isn't grouped by day here (unlike Home/EntryListView), so each row shows its
        // own date rather than relying on a section header.
        let todayLabel = Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        XCTAssertTrue(app.staticTexts[todayLabel].exists, "Entry row should show today's date (\(todayLabel)) since this list mixes entries with no date grouping")
    }
}
