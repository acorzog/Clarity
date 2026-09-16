import XCTest

/// Covers Plan → Allocate and Remaining — specifically the Remaining category drill-down's two
/// newer actions (edit the planned amount, add a transaction) and whether either one actually
/// round-trips back to Allocate/that category's own entry list. These two screens share the same
/// underlying `Budget`/`Entry` data through entirely different UI paths, so a sync break between
/// them is exactly the kind of bug that only shows up by driving the real screens end to end.
///
/// Uses "Cleaning" (Housing, the first expense category alphabetically) rather than a category
/// deeper in the list — Allocate's card layout renders every category unconditionally expanded
/// with no built-in "scroll to row" affordance, and the `Income` category group is always the
/// first, tallest section pushing everything below it out of the initial viewport. Collapsing
/// that one section (a normal user action — the disclosure chevron every group already has) is
/// enough to bring Housing on screen without needing a synthetic scroll gesture at all.
final class PlanAllocateUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = UITestSupport.launchApp()
    }

    private func openAllocateWithIncomeCollapsed() {
        app.tabBars.buttons["Plan"].tap()
        XCTAssertTrue(app.buttons["Allocate"].waitForExistence(timeout: 8))
        app.buttons["Income category group"].tap()
        // The collapse itself animates (`withAnimation(.easeInOut(duration: 0.2))`) and Housing's
        // rows only settle into their final on-screen position once it finishes.
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Sets Cleaning's planned amount from Allocate — a precondition for the Remaining-based
    /// tests below, not just a thing under test in its own right: with *no* budget set anywhere,
    /// `RemainingView` shows its "No Budget Set" empty state instead of any category grid at all,
    /// so Cleaning's row genuinely doesn't exist yet at that point, regardless of scroll position.
    private func setCleaningAmount(_ amount: String) {
        let cleaningPill = app.buttons["Cleaning planned amount"]
        XCTAssertTrue(cleaningPill.waitForExistence(timeout: 5))
        cleaningPill.tap()
        XCTAssertTrue(app.buttons["Save amount"].waitForExistence(timeout: 8))
        app.typeText(amount)
        app.buttons["Save amount"].tap()
        XCTAssertTrue(app.buttons["Save amount"].waitForNonExistence(timeout: 8))
    }

    func testSettingAPlannedAmountInAllocateUpdatesThatCategorysPill() throws {
        openAllocateWithIncomeCollapsed()

        let cleaningPill = app.buttons["Cleaning planned amount"]
        setCleaningAmount("50")

        let updatedValue = cleaningPill.value as? String ?? ""
        XCTAssertTrue(updatedValue.contains("50"), "Cleaning's planned-amount pill should reflect the newly saved amount, got \(updatedValue)")
    }

    func testEditingPlannedAmountFromRemainingsCategoryDetailReflectsBackInAllocate() throws {
        openAllocateWithIncomeCollapsed()
        setCleaningAmount("30")

        app.buttons["Remaining"].tap()
        let cleaningRow = app.staticText(containing: "Cleaning")
        XCTAssertTrue(cleaningRow.waitForExistence(timeout: 5))
        cleaningRow.tap()

        XCTAssertTrue(app.buttons["Edit planned amount"].waitForExistence(timeout: 8), "Category detail should expose the edit-budget action")
        app.buttons["Edit planned amount"].tap()
        XCTAssertTrue(app.buttons["Save amount"].waitForExistence(timeout: 8))
        // The field opens pre-filled with the "30" set above — clear it before typing "75", or
        // it appends instead of replacing.
        let existingAmountText = (app.textFields.firstMatch.value as? String) ?? ""
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingAmountText.count))
        app.typeText("75")
        app.buttons["Save amount"].tap()
        XCTAssertTrue(app.buttons["Save amount"].waitForNonExistence(timeout: 8))

        app.navigationBars.buttons.element(boundBy: 0).tap() // back out of the category detail
        app.buttons["Allocate"].tap()

        let cleaningPill = app.buttons["Cleaning planned amount"]
        XCTAssertTrue(cleaningPill.waitForExistence(timeout: 5))
        cleaningPill.tap() // re-open to read its current value
        XCTAssertTrue(app.buttons["Save amount"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.textFields.firstMatch.value as? String, "75", "Allocate should show the amount that was set from Remaining's category detail")
        app.buttons["Cancel"].tap()
    }

    func testAddingATransactionFromRemainingsCategoryDetailShowsUpInThatCategorysList() throws {
        openAllocateWithIncomeCollapsed()
        setCleaningAmount("30")

        app.buttons["Remaining"].tap()
        let cleaningRow = app.staticText(containing: "Cleaning")
        XCTAssertTrue(cleaningRow.waitForExistence(timeout: 5))
        cleaningRow.tap()

        let addButton = app.button(containing: "Add Cleaning transaction")
        XCTAssertTrue(addButton.waitForExistence(timeout: 8), "Category detail should expose the add-transaction action")
        addButton.tap()

        XCTAssertTrue(app.navigationBars.buttons["Save"].waitForExistence(timeout: 8), "Add Transaction sheet should open pre-filled with Cleaning")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        app.typeText("12")
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Save"].waitForNonExistence(timeout: 8))

        XCTAssertTrue(app.staticTexts["Cleaning"].waitForExistence(timeout: 8), "The new transaction should appear in Cleaning's own entry list")
    }
}
