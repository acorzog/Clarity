import XCTest

/// Covers Overview's "Add transaction" flow end to end — the single most-used action in the app,
/// per its own toolbar placement on every screen that shows spending. A regression here (a picker
/// that won't open, a Save button that stays disabled, an entry that doesn't actually appear
/// after saving) would be a total blocker, so this is the highest-value scenario in the suite.
final class AddTransactionUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = UITestSupport.launchApp()
    }

    func testAddingAnExpenseMakesItAppearInTheTransactionList() throws {
        UITestSupport.addExpense(app: app, amount: "42", category: "Groceries")

        // Overview's List sub-tab is the canonical place to confirm an entry actually persisted.
        app.buttons["List"].tap()
        XCTAssertTrue(app.staticTexts["Groceries"].waitForExistence(timeout: 8), "The saved expense should show up in the transaction list")
    }

    func testAddingAnIncomeTransactionSwitchesAwayFromTheDefaultExpenseCategory() throws {
        app.tabBars.buttons["Overview"].tap()
        let addButton = app.buttons["Add transaction"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 8), "Overview's Add transaction button should render")
        addButton.tap()
        XCTAssertTrue(app.navigationBars.buttons["Save"].waitForExistence(timeout: 8))

        app.buttons["Income"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        app.typeText("1500")

        app.buttons["Category"].tap()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        searchField.tap()
        searchField.typeText("Salary")
        let salaryRow = app.staticTexts["Salary"]
        XCTAssertTrue(salaryRow.waitForExistence(timeout: 8), "Salary is an income category and should be selectable once Income is chosen")
        salaryRow.tap()

        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Save"].waitForNonExistence(timeout: 8))

        app.buttons["List"].tap()
        XCTAssertTrue(app.staticTexts["Salary"].waitForExistence(timeout: 8), "The saved income entry should show up in the transaction list")
    }
}
