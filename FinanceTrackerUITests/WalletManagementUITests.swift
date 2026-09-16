import XCTest

/// Covers More → Accounts: creating a new wallet, and the cross-cutting sync between a
/// transaction's wallet and that wallet's own transaction history — the "add to wallet" scenario.
/// A silent break in either direction (a saved expense not showing up under its wallet, or a new
/// wallet not showing up in the Accounts list) would surface as "my balances don't add up" for a
/// real user, which is exactly the kind of bug a unit test on the calculation layer alone
/// wouldn't catch if the UI itself failed to wire the two together.
final class WalletManagementUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = UITestSupport.launchApp()
    }

    private func openAccounts() {
        app.tabBars.buttons["More"].tap()
        XCTAssertTrue(app.staticTexts["Accounts"].waitForExistence(timeout: 8), "More's Accounts card should render")
        app.staticTexts["Accounts"].tap()
    }

    func testCreatingANewWalletShowsItInTheAccountsList() throws {
        openAccounts()
        XCTAssertTrue(app.staticText(containing: "Spending").waitForExistence(timeout: 8), "The seeded default wallet should already be listed")

        app.buttons["Add account"].tap()
        let nameField = app.textFields["Account name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 8), "New Account form should appear")
        nameField.tap()
        nameField.typeText("Vacation Fund")

        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Save"].waitForNonExistence(timeout: 8), "Sheet should dismiss after saving")

        XCTAssertTrue(app.staticText(containing: "Vacation Fund").waitForExistence(timeout: 8), "The newly created wallet should appear back in Accounts")
    }

    func testExpenseAgainstTheDefaultWalletAppearsInThatWalletsTransactionHistory() throws {
        UITestSupport.addExpense(app: app, amount: "18", category: "Groceries")

        openAccounts()
        app.button(containing: "Spending account").tap()
        XCTAssertTrue(app.staticTexts["Groceries"].waitForExistence(timeout: 8), "The expense should show up under the wallet it was charged to")

        // WalletEditorView is a sheet, opened read-only here — dismiss without changing anything.
        app.buttons["Cancel"].tap()
    }
}
