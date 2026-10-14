import XCTest

/// Shared launch/lookup helpers for every UI test — kept in one place so a change to how the app
/// needs to be launched for testing (a new reset flag, a new disabled animation, etc.) doesn't
/// need repeating across every test file.
enum UITestSupport {
    /// Launches the app with `-uiTestReset`, which `FinanceTrackerApp.init()` uses to delete the
    /// on-disk store before `SeedData.seedIfNeeded` runs — every test therefore starts from the
    /// same clean local slate (the default categories and a single "Spending" wallet, no
    /// transactions or budgets) regardless of what an earlier test run left behind. Only ever set
    /// by this test bundle, so it can never affect a real launch or touch a real device's actual
    /// data.
    ///
    /// `-uiTestReset` only wipes the *local* SwiftData store — it has no effect on a Supabase
    /// session already on disk (that's Keychain/UserDefaults-backed, a separate system; see
    /// `RootAuthState`). Since the account feature landed, a genuinely fresh simulator with no
    /// prior session lands on the sign-in screen, not the tab bar directly, so this signs in with
    /// `TEST_USER`/`TEST_USER_PASSWORD` (read from the test runner's own environment — set them in
    /// the scheme's Test action, or `TEST_USER=... TEST_USER_PASSWORD=... xcodebuild test ...` —
    /// never hardcoded here) whenever that screen appears. Most runs after the first never actually
    /// hit this path: the session from the previous run is still on disk, so launch goes straight
    /// to the tab bar as before.
    static func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestReset"]
        app.launch()
        // `RootView` shows `LaunchScreenView` at `.zIndex(2)` — an opaque overlay — for a fixed
        // 1.3s after launch before revealing whichever screen is underneath. Without waiting it
        // out here, a test's very first tap can land on that overlay instead of what it's aiming
        // for, silently going nowhere rather than failing loudly — exactly the kind of flake that
        // only shows up under a loaded/slow simulator, since a human's reaction time naturally
        // clears it every time a person actually uses the app.
        let tabBar = app.tabBars.firstMatch
        let signInButton = app.buttons["Sign In"]
        let exists = NSPredicate(format: "exists == true")
        _ = XCTWaiter().wait(
            for: [
                XCTNSPredicateExpectation(predicate: exists, object: tabBar),
                XCTNSPredicateExpectation(predicate: exists, object: signInButton),
            ],
            timeout: 5
        )

        if signInButton.exists && !tabBar.exists {
            signInWithTestAccount(app: app)
        }

        // Signing in triggers a real network round trip (and, once signed in, an automatic sync
        // pass) — allow noticeably longer than the plain splash-clearing wait above for the tab
        // bar to actually land.
        _ = tabBar.waitForExistence(timeout: tabBar.exists ? 5 : 20)
        return app
    }

    /// Reads credentials from the environment, not literals, so no real account details are ever
    /// committed to source. Fails loudly (not a silent skip) when they're missing, since a missing
    /// env var would otherwise show up as every single UI test timing out on the tab bar with no
    /// indication why.
    private static func signInWithTestAccount(app: XCUIApplication) {
        guard
            let email = ProcessInfo.processInfo.environment["TEST_USER"],
            let password = ProcessInfo.processInfo.environment["TEST_USER_PASSWORD"]
        else {
            XCTFail("The app requires sign-in on this simulator but TEST_USER/TEST_USER_PASSWORD aren't set in the test environment. Set them in the scheme's Test action environment variables, or pass TEST_USER=... TEST_USER_PASSWORD=... to xcodebuild test.")
            return
        }

        let emailField = app.textFields["Email"]
        guard emailField.waitForExistence(timeout: 8) else {
            XCTFail("Sign-in screen should show an Email field")
            return
        }
        emailField.tap()
        emailField.typeText(email)

        let passwordField = app.secureTextFields["Password"]
        guard passwordField.waitForExistence(timeout: 8) else {
            XCTFail("Sign-in screen should show a Password field")
            return
        }
        passwordField.tap()
        passwordField.typeText(password)

        app.buttons["Sign In"].tap()
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
