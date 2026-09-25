import XCTest
import SwiftUI
@testable import FinanceTracker

/// Focused tests for `SwipeToDeleteRow`'s VoiceOver accessibility action (Phase 2N-E,
/// `CLARITY_GOALS_QA_REPORT.md` §8) — shared by Goals, Plan, and `SharedEventDetailView`.
///
/// **What this can and can't verify:** this project has no SwiftUI view-inspection library
/// (ViewInspector or similar) and no UI test target, so these tests cannot render
/// `SwipeToDeleteRow` and assert that its rendered accessibility tree actually exposes an action
/// literally named "Delete" to VoiceOver's rotor — that specific wiring
/// (`.accessibilityAction(named: "Delete", performAccessibilityDelete)`, `SwipeToDeleteRow.swift`)
/// is a one-line call site verified by direct code inspection instead. What *is* testable, and
/// what these tests cover, is the exact behavior that action performs once triggered:
/// `performAccessibilityDelete()` is the same internal method the modifier calls, made directly
/// callable here for that reason.
final class SwipeToDeleteRowTests: XCTestCase {

    func testAccessibilityDeleteInvokesOnDeleteExactlyOnceWhenCanDelete() {
        var callCount = 0
        let row = SwipeToDeleteRow(canDelete: true, onDelete: { callCount += 1 }) {
            Text("Row")
        }

        row.performAccessibilityDelete()

        XCTAssertEqual(callCount, 1, "the accessibility Delete action must invoke the deletion closure exactly once")
    }

    func testAccessibilityDeleteDoesNothingWhenDeletionIsDisabled() {
        var callCount = 0
        let row = SwipeToDeleteRow(canDelete: false, onDelete: { callCount += 1 }) {
            Text("Row")
        }

        row.performAccessibilityDelete()

        XCTAssertEqual(callCount, 0, "matching the drag gesture's own `canDelete` guard, the accessibility action must not delete when deletion is disabled")
    }

    /// Calling it twice must invoke `onDelete` twice, not be silently debounced — VoiceOver users
    /// double-activating an action should behave exactly like double-tapping the reveal button.
    func testAccessibilityDeleteCanBeInvokedRepeatedly() {
        var callCount = 0
        let row = SwipeToDeleteRow(canDelete: true, onDelete: { callCount += 1 }) {
            Text("Row")
        }

        row.performAccessibilityDelete()
        row.performAccessibilityDelete()

        XCTAssertEqual(callCount, 2)
    }
}
