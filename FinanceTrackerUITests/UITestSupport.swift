import XCTest

/// Shared launch/lookup helpers for every UI test — kept in one place so a change to how the app
/// needs to be launched for testing (a new reset flag, a new disabled animation, etc.) doesn't
/// need repeating across every test file.
enum UITestSupport {
    /// Launches the app with `-uiTestReset`, which `FinanceTrackerApp.init()` uses to delete the
    /// on-disk store before `SeedData.seedIfNeeded` runs — every test therefore starts from the
    /// same clean slate (the default categories and a single "Spending" wallet, no transactions or
    /// budgets) regardless of what an earlier test run left behind. Only ever set by this test
    /// bundle, so it can never affect a real launch or touch a real device's actual data.
    static func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestReset"]
        app.launch()
        // `RootView` shows `LaunchScreenView` at `.zIndex(2)` — an opaque overlay — for a fixed
        // 1.3s after launch before revealing the tab bar underneath. Without waiting it out here,
        // a test's very first tap can land on that overlay instead of the tab bar it's aiming
        // for, silently going nowhere rather than failing loudly — exactly the kind of flake that
        // only shows up under a loaded/slow simulator, since a human's reaction time naturally
        // clears it every time a person actually uses the app.
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 5)
        return app
    }
}

extension UITestSupport {
    /// Drives the full "add an expense" flow from Overview's "+" button through to a saved entry
    /// — every test that needs at least one transaction on the books before it can assert
    /// anything about wallets, budgets, or transaction lists starts here, rather than each
    /// re-deriving the same handful of taps.
    static func addExpense(app: XCUIApplication, amount: String, category: String) {
        app.tabBars.buttons["Overview"].tap()
        let addButton = app.buttons["Add transaction"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 8), "Overview's Add transaction button should render")
        addButton.tap()

        XCTAssertTrue(app.navigationBars.buttons["Save"].waitForExistence(timeout: 8), "Add Transaction sheet should appear")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), "Amount field should auto-focus for a new entry")
        app.typeText(amount)

        app.buttons["Category"].tap()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 8), "Category picker's search field should appear")
        searchField.tap()
        searchField.typeText(category)
        let categoryRow = app.staticTexts[category]
        XCTAssertTrue(categoryRow.waitForExistence(timeout: 8), "\(category) should appear once the search filters to it")
        categoryRow.tap()

        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Save"].waitForNonExistence(timeout: 8), "Sheet should dismiss after saving")
    }
}

extension XCUIElement {
    /// Polls until the element disappears (or `timeout` elapses) — the negative-space counterpart
    /// to `waitForExistence`, used to confirm a sheet actually dismissed rather than just assuming
    /// a tap on Save worked.
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

extension XCUIApplication {
    /// Case-insensitive lookup for a static text whose exact casing varies by call site (e.g.
    /// `WalletRow` uppercases the account name for display) — matching on content rather than a
    /// display transform that's incidental to the assertion being made.
    func staticText(containing substring: String) -> XCUIElement {
        staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", substring)).firstMatch
    }

    func button(containing substring: String) -> XCUIElement {
        buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", substring)).firstMatch
    }
}
