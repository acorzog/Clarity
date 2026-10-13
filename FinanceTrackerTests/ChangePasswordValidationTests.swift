import XCTest
@testable import FinanceTracker

/// Phase 6.0.2 — covers `ChangePasswordValidation` as a pure rule, the same way
/// `LocalStoreOwnershipTests` covers `LocalStoreOwnership.decide` directly rather than driving
/// `ChangePasswordView` itself.
final class ChangePasswordValidationTests: XCTestCase {

    // MARK: - validationMessage

    func testEmptyFieldsHaveNoValidationMessage() {
        XCTAssertNil(ChangePasswordValidation.validationMessage(currentPassword: "", newPassword: "", confirmPassword: ""))
    }

    /// Gated on `newPassword` alone having content — typing into `currentPassword` first must
    /// never flash a message about a field the user hasn't reached yet.
    func testShortNewPasswordIsFlaggedOnlyOnceItHasContent() {
        XCTAssertNil(ChangePasswordValidation.validationMessage(currentPassword: "oldpass1", newPassword: "", confirmPassword: ""))
        XCTAssertEqual(
            ChangePasswordValidation.validationMessage(currentPassword: "oldpass1", newPassword: "short", confirmPassword: ""),
            "Password must be at least 8 characters."
        )
    }

    func testMismatchedConfirmationIsFlagged() {
        XCTAssertEqual(
            ChangePasswordValidation.validationMessage(currentPassword: "oldpass1", newPassword: "newpass1", confirmPassword: "newpass2"),
            "Passwords don't match."
        )
    }

    /// The local, pre-network check that mirrors Supabase's own `samePassword` server error —
    /// checked directly against the plaintext values already in the form.
    func testNewPasswordSameAsCurrentIsFlaggedLocally() {
        XCTAssertEqual(
            ChangePasswordValidation.validationMessage(currentPassword: "samepass1", newPassword: "samepass1", confirmPassword: "samepass1"),
            "New password must be different from your current password."
        )
    }

    func testValidDistinctPasswordsHaveNoValidationMessage() {
        XCTAssertNil(
            ChangePasswordValidation.validationMessage(currentPassword: "oldpass1", newPassword: "newpass1", confirmPassword: "newpass1")
        )
    }

    // MARK: - canSubmit

    func testCannotSubmitWithAnyEmptyField() {
        XCTAssertFalse(ChangePasswordValidation.canSubmit(currentPassword: "", newPassword: "newpass1", confirmPassword: "newpass1"))
        XCTAssertFalse(ChangePasswordValidation.canSubmit(currentPassword: "oldpass1", newPassword: "", confirmPassword: "newpass1"))
        XCTAssertFalse(ChangePasswordValidation.canSubmit(currentPassword: "oldpass1", newPassword: "newpass1", confirmPassword: ""))
    }

    func testCannotSubmitWithAValidationFailure() {
        XCTAssertFalse(ChangePasswordValidation.canSubmit(currentPassword: "oldpass1", newPassword: "short", confirmPassword: "short"))
        XCTAssertFalse(ChangePasswordValidation.canSubmit(currentPassword: "oldpass1", newPassword: "newpass1", confirmPassword: "newpass2"))
        XCTAssertFalse(ChangePasswordValidation.canSubmit(currentPassword: "samepass1", newPassword: "samepass1", confirmPassword: "samepass1"))
    }

    func testCanSubmitWithAllFieldsFilledAndValid() {
        XCTAssertTrue(ChangePasswordValidation.canSubmit(currentPassword: "oldpass1", newPassword: "newpass1", confirmPassword: "newpass1"))
    }
}
