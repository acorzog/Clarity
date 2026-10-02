import XCTest

/// Covers the "Removed Categories" screen end-to-end: archiving a category from the Categories
/// grid, confirming it surfaces in the global Removed Categories list (not just the per-Head-
/// Category inline reveal that already existed), restoring it from there, and confirming it's
/// back in the main grid afterward. A silent break anywhere in that chain — the toolbar button not
/// opening the sheet, the restore button not actually clearing `isArchived`, or the category not
/// reappearing in the grid — would strand a person's category with no way back to it short of
/// recreating it from scratch, which is exactly the scenario this feature exists to avoid.
final class RemovedCategoriesUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = UITestSupport.launchApp()
    }

    private func openCategories() {
        app.tabBars.buttons["More"].tap()
        app.staticTexts["Categories"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Categories"].waitForExistence(timeout: 8), "Categories screen should render")
    }

    func testArchivingThenRestoringFromRemovedCategoriesReturnsItToTheMainGrid() throws {
        openCategories()

        // Archive the seeded "Groceries" category via the existing remove-mode tap-to-archive flow.
        app.buttons["Remove Categories"].tap()
        app.button(containing: "Groceries").tap()
        app.buttons["Done Removing Categories"].tap()

        // It should disappear from the main (active) grid immediately.
        XCTAssertTrue(
            app.button(containing: "Groceries").waitForNonExistence(timeout: 8),
            "Archived category should no longer appear in the active grid"
        )

        // The new global Removed Categories screen should list it.
        app.buttons["Removed Categories"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Removed Categories"].waitForExistence(timeout: 8), "Removed Categories sheet should appear")
        XCTAssertTrue(app.staticTexts["Groceries"].waitForExistence(timeout: 8), "The archived category should be listed here")

        // Restore it. Checking the "Restore Groceries" button itself (rather than the plain
        // "Groceries" static text) for non-existence, since that text is ambiguous once restored
        // — it also legitimately reappears in the main Categories grid underneath this sheet,
        // which stays mounted (just covered) and so still "exists" for an unscoped query even
        // though it isn't on screen. The button's accessibility label is unique to this row.
        app.buttons["Restore Groceries"].tap()
        XCTAssertTrue(
            app.buttons["Restore Groceries"].waitForNonExistence(timeout: 8),
            "Restored category's row should drop off the Removed Categories list"
        )
        XCTAssertTrue(
            app.staticTexts["No Removed Categories"].waitForExistence(timeout: 8),
            "With nothing left archived, the empty state should show"
        )

        app.navigationBars.buttons["Done"].tap()

        // Back in the main Categories screen, the restored category should be selectable again.
        XCTAssertTrue(app.button(containing: "Groceries").waitForExistence(timeout: 8), "Restored category should reappear in the active grid")
    }

    func testRemovedCategoriesShowsEmptyStateWhenNothingIsArchived() throws {
        openCategories()

        app.buttons["Removed Categories"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Removed Categories"].waitForExistence(timeout: 8), "Removed Categories sheet should appear")
        XCTAssertTrue(app.staticTexts["No Removed Categories"].waitForExistence(timeout: 8), "A fresh install has nothing archived yet")
    }
}
