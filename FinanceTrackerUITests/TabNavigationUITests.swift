import XCTest

/// Smoke coverage for the app's 5-tab shell (`MainTabView`) — every tab must actually switch and
/// render its own screen, and the tab bar's own selection state must track along with it. This is
/// the cheapest possible regression net for "a tab is broken/blank/crashes on first appearance,"
/// which a compile-time check can't catch since every tab's content is built lazily on first tap.
final class TabNavigationUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = UITestSupport.launchApp()
    }

    func testAllFiveTabsAreReachableAndShowDistinctContent() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5), "Tab bar should appear once the launch splash clears")

        let home = tabBar.buttons["Home"]
        let overview = tabBar.buttons["Overview"]
        let plan = tabBar.buttons["Plan"]
        let shared = tabBar.buttons["Shared"]
        let more = tabBar.buttons["More"]
        for button in [home, overview, plan, shared, more] {
            XCTAssertTrue(button.exists, "\(button) should be present in the tab bar")
        }

        home.tap()
        XCTAssertTrue(home.isSelected, "Tapping Home should select it")

        overview.tap()
        XCTAssertTrue(overview.isSelected)
        XCTAssertTrue(app.staticTexts["Overview"].waitForExistence(timeout: 8), "Overview's own header should render")

        plan.tap()
        XCTAssertTrue(plan.isSelected)
        XCTAssertTrue(app.staticTexts["Plan"].waitForExistence(timeout: 8), "Plan's own header should render")
        // Allocate is the default sub-tab every time Plan is opened.
        XCTAssertTrue(app.buttons["Allocate"].exists)

        shared.tap()
        XCTAssertTrue(shared.isSelected)
        XCTAssertTrue(app.staticTexts["Shared"].waitForExistence(timeout: 8), "Shared's own header should render")

        more.tap()
        XCTAssertTrue(more.isSelected)
        XCTAssertTrue(app.staticTexts["More"].waitForExistence(timeout: 8), "More's own header should render")
        XCTAssertTrue(app.staticTexts["Accounts"].exists, "More should list Accounts among its tools")

        home.tap()
        XCTAssertTrue(home.isSelected, "Should be able to navigate back to Home after visiting every other tab")
    }
}
