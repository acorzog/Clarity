import XCTest

/// Smoke coverage for the pull-to-refresh spinner added to every tab's root scroll view
/// (`DataSyncService.refresh`). A UI test can't observe that a `save()`/`rollback()` actually
/// happened internally, but it can and should confirm the gesture itself is wired up on the
/// screens that are supposed to have it, and that triggering it doesn't crash or leave the screen
/// in a broken state — the two failure modes an XCUITest black-box test can actually catch here.
final class PullToRefreshUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = UITestSupport.launchApp()
    }

    func testPullToRefreshOnHomeDoesNotDisruptTheScreen() throws {
        app.tabBars.buttons["Home"].tap()
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5))

        scrollView.swipeDown()

        // The tab bar (and Home's own content) should still be there and responsive afterward —
        // the cheapest possible signal that the refresh action didn't crash or hang the app.
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Home"].isSelected)
    }

    func testPullToRefreshOnPlanAllocateDoesNotDisruptTheScreen() throws {
        app.tabBars.buttons["Plan"].tap()
        XCTAssertTrue(app.buttons["Allocate"].waitForExistence(timeout: 8))
        // Plan now opens to Remaining by default, so Allocate must be selected explicitly — this
        // test is specifically about Allocate's own scroll view, not whatever the default happens
        // to be.
        app.buttons["Allocate"].tap()

        app.scrollViews.firstMatch.swipeDown()

        XCTAssertTrue(app.staticTexts["Plan"].waitForExistence(timeout: 8), "Plan's header should still be showing after a refresh pull")
        XCTAssertTrue(app.buttons["Allocate"].exists, "Allocate should still be showing its content after a refresh pull")
    }
}
