import XCTest
import Supabase
@testable import FinanceTracker

/// Covers the pure, dependency-free pieces of `SupabaseAuthService` — email/password validation
/// and `userFacingMessage(for:flow:)`'s error mapping — without needing a live Supabase session.
final class SupabaseAuthServiceTests: XCTestCase {

    // MARK: - Email validation

    func testValidEmailsPass() {
        XCTAssertTrue(SupabaseAuthService.isValidEmail("user@example.com"))
        XCTAssertTrue(SupabaseAuthService.isValidEmail("first.last+tag@sub.example.co"))
    }

    func testInvalidEmailsFail() {
        XCTAssertFalse(SupabaseAuthService.isValidEmail(""))
        XCTAssertFalse(SupabaseAuthService.isValidEmail("not-an-email"))
        XCTAssertFalse(SupabaseAuthService.isValidEmail("missing-domain@"))
        XCTAssertFalse(SupabaseAuthService.isValidEmail("@missing-local.com"))
        XCTAssertFalse(SupabaseAuthService.isValidEmail("spaces in@email.com"))
    }

    // MARK: - userFacingMessage

    private func makeAuthError(_ code: ErrorCode) -> AuthError {
        .api(
            message: "irrelevant server message",
            errorCode: code,
            underlyingData: Data(),
            underlyingResponse: HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func testInvalidCredentialsMapsToFriendlyMessage() {
        let message = SupabaseAuthService.userFacingMessage(for: makeAuthError(.invalidCredentials), flow: .signIn)
        XCTAssertEqual(message, "Incorrect email or password.")
    }

    func testEmailExistsMapsToFriendlyMessage() {
        let message = SupabaseAuthService.userFacingMessage(for: makeAuthError(.emailExists), flow: .signUp)
        XCTAssertEqual(message, "An account with that email already exists.")
    }

    func testWeakPasswordMapsToFriendlyMessage() {
        let message = SupabaseAuthService.userFacingMessage(for: makeAuthError(.weakPassword), flow: .signUp)
        XCTAssertEqual(message, "Choose a stronger password — at least 8 characters.")
    }

    func testOverEmailRateLimitMapsToFriendlyMessage() {
        let message = SupabaseAuthService.userFacingMessage(for: makeAuthError(.overEmailSendRateLimit), flow: .resetPassword)
        XCTAssertEqual(message, "Too many attempts. Wait a moment and try again.")
    }

    /// An unmapped error code falls back to the flow's own generic message rather than leaking
    /// the raw server string — distinct per flow, so this checks sign-in vs. sign-up specifically.
    func testUnmappedErrorCodeFallsBackToFlowGenericMessage() {
        let unmapped = makeAuthError(.badJSON)
        XCTAssertEqual(
            SupabaseAuthService.userFacingMessage(for: unmapped, flow: .signIn),
            "Couldn't sign in. Check your email and password and try again."
        )
        XCTAssertEqual(
            SupabaseAuthService.userFacingMessage(for: unmapped, flow: .signUp),
            "Couldn't create your account. Please try again."
        )
    }

    func testNonAuthErrorFallsBackToFlowGenericMessage() {
        struct SomeOtherError: Error {}
        XCTAssertEqual(
            SupabaseAuthService.userFacingMessage(for: SomeOtherError(), flow: .signOut),
            "Couldn't sign out. Check your connection and try again."
        )
    }

    // MARK: - Reauthentication (Phase 6.0.1)

    /// Thrown by a sensitive `update(user:)` call (password/email change) when the project
    /// requires reauthentication first and the caller hasn't done that yet.
    func testReauthenticationNeededMapsToFriendlyMessage() {
        let message = SupabaseAuthService.userFacingMessage(for: makeAuthError(.reauthenticationNeeded), flow: .updatePassword)
        XCTAssertEqual(message, "For your security, please confirm it's you before continuing.")
    }

    /// Thrown by that same sensitive call when the nonce attached to it was wrong or expired —
    /// distinct from `reauthenticationNeeded` (no attempt made yet) and from the generic
    /// "link expired" copy used for recovery/confirmation links.
    func testReauthenticationNotValidMapsToFriendlyMessage() {
        let message = SupabaseAuthService.userFacingMessage(for: makeAuthError(.reauthenticationNotValid), flow: .updatePassword)
        XCTAssertEqual(message, "That code wasn't correct. Please try again.")
    }

    func testSamePasswordMapsToFriendlyMessage() {
        let message = SupabaseAuthService.userFacingMessage(for: makeAuthError(.samePassword), flow: .updatePassword)
        XCTAssertEqual(message, "Your new password must be different from your current password.")
    }

    /// `.reauthenticate` is its own `AuthFlow` case (used when `reauthenticate()` itself fails to
    /// send the code) with a fallback distinct from the other flows' — this locks in that it
    /// actually gets picked, not some other flow's generic message.
    func testReauthenticateFlowFallsBackToItsOwnGenericMessage() {
        struct SomeOtherError: Error {}
        XCTAssertEqual(
            SupabaseAuthService.userFacingMessage(for: SomeOtherError(), flow: .reauthenticate),
            "Couldn't send a confirmation code. Please try again."
        )
    }

    // MARK: - requiresReauthentication (Phase 6.0.2)

    /// The exact signal `ChangePasswordView` branches on to decide whether to present
    /// `ReauthenticationView` rather than just showing an error.
    func testRequiresReauthenticationIsTrueOnlyForThatSpecificCode() {
        XCTAssertTrue(SupabaseAuthService.requiresReauthentication(makeAuthError(.reauthenticationNeeded)))
    }

    func testRequiresReauthenticationIsFalseForOtherAuthErrors() {
        XCTAssertFalse(SupabaseAuthService.requiresReauthentication(makeAuthError(.reauthenticationNotValid)))
        XCTAssertFalse(SupabaseAuthService.requiresReauthentication(makeAuthError(.invalidCredentials)))
        XCTAssertFalse(SupabaseAuthService.requiresReauthentication(makeAuthError(.samePassword)))
    }

    func testRequiresReauthenticationIsFalseForNonAuthErrors() {
        struct SomeOtherError: Error {}
        XCTAssertFalse(SupabaseAuthService.requiresReauthentication(SomeOtherError()))
    }

    // MARK: - Change email (Phase 6.0.3)

    /// `.changeEmail` (the request-a-change step, `ChangeEmailView.submit`) has its own fallback,
    /// distinct from every other flow's.
    func testChangeEmailFlowFallsBackToItsOwnGenericMessage() {
        struct SomeOtherError: Error {}
        XCTAssertEqual(
            SupabaseAuthService.userFacingMessage(for: SomeOtherError(), flow: .changeEmail),
            "Couldn't change your email. Please try again."
        )
    }

    /// `.emailChangeLink` (completing the emailed confirmation link, `RootView
    /// .handleEmailChangeLink`) has its own fallback too — deliberately distinct wording from
    /// `.emailConfirmationLink`'s ("Try signing up again" would be nonsensical for an existing
    /// user changing their email).
    func testEmailChangeLinkFlowFallsBackToItsOwnGenericMessage() {
        struct SomeOtherError: Error {}
        XCTAssertEqual(
            SupabaseAuthService.userFacingMessage(for: SomeOtherError(), flow: .emailChangeLink),
            "This confirmation link is invalid or has expired. Request the change again."
        )
    }

    /// An expired/already-used confirmation link routes through `.emailChangeLink`'s own
    /// fallback — the same "falls through to flow's generic message" mechanism already proven for
    /// password-recovery and signup-confirmation links, now covering the email-change link too.
    func testExpiredLinkCodeFallsBackToEmailChangeLinkFlowMessage() {
        let message = SupabaseAuthService.userFacingMessage(for: makeAuthError(.flowStateExpired), flow: .emailChangeLink)
        XCTAssertEqual(message, "This confirmation link is invalid or has expired. Request the change again.")
    }

    /// Requesting a change to an email already used by another account reuses the existing
    /// `emailExists`/`userAlreadyExists` mapping — proven here specifically in the `.changeEmail`
    /// context, since that mapping is flow-agnostic and this locks in it still applies here.
    func testEmailExistsMapsToFriendlyMessageForChangeEmailFlow() {
        let message = SupabaseAuthService.userFacingMessage(for: makeAuthError(.emailExists), flow: .changeEmail)
        XCTAssertEqual(message, "An account with that email already exists.")
    }

    /// The same reauthentication signal `ChangePasswordView` uses applies identically to the
    /// change-email flow — `requiresReauthentication` is deliberately flow-agnostic.
    func testRequiresReauthenticationAppliesToChangeEmailFlowErrorsToo() {
        XCTAssertTrue(SupabaseAuthService.requiresReauthentication(makeAuthError(.reauthenticationNeeded)))
    }

    // MARK: - updateAvatar (Phase C, profile roadmap)

    /// A storage/network failure during avatar upload (e.g. the user is offline, or the `avatars`
    /// bucket policy rejects the write) has no specific `AuthError` mapping — it should fall back
    /// to `.updateAvatar`'s own generic message rather than `.updateProfile`'s, since the two are
    /// shown from different screens (`ProfileEditView`'s photo picker vs. its name field).
    func testUpdateAvatarFlowFallsBackToItsOwnGenericMessage() {
        struct SomeOtherError: Error {}
        XCTAssertEqual(
            SupabaseAuthService.userFacingMessage(for: SomeOtherError(), flow: .updateAvatar),
            "Couldn't update your photo. Please try again."
        )
    }

    /// Avatar upload isn't a Supabase "secure change" category (unlike email/password), but if a
    /// reauthentication-required error were ever surfaced from the `profiles` PATCH it still maps
    /// the same way every other flow's does — `requiresReauthentication` is flow-agnostic by design.
    func testRequiresReauthenticationAppliesToUpdateAvatarFlowToo() {
        let message = SupabaseAuthService.userFacingMessage(for: makeAuthError(.reauthenticationNeeded), flow: .updateAvatar)
        XCTAssertEqual(message, "For your security, please confirm it's you before continuing.")
    }

    /// Regression test for a real bug: `uploadAvatar` built its storage path from `UUID.
    /// uuidString` directly (uppercase), but the `avatars` bucket's RLS policy compares against
    /// Postgres's lowercase `auth.uid()::text`, so every upload was rejected with a 403 "row-level
    /// security policy" error regardless of who the signed-in user was.
    func testAvatarStoragePathIsLowercased() {
        let userID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        XCTAssertEqual(
            SupabaseAuthService.avatarStoragePath(for: userID),
            "3f2504e0-4f89-11d3-9a0c-0305e82c3301/avatar.jpg"
        )
    }

    // MARK: - Account deletion (Phase 6.0.5)

    /// `deletionRequiresReauthentication` must be true only for a stale-but-otherwise-valid
    /// sign-in (the Edge Function's `reauthentication_required`, from its own `last_sign_in_at`
    /// freshness check) — not for a wallet conflict, a hard failure, an invalid/revoked session,
    /// or the ambiguous "may already be deleted" outcome, each a materially different situation.
    func testDeletionRequiresReauthenticationForNonceErrors() {
        XCTAssertTrue(SupabaseAuthService.deletionRequiresReauthentication(AccountDeletionError.reauthenticationRequired))
    }

    func testDeletionDoesNotRequireReauthenticationForOtherErrors() {
        XCTAssertFalse(SupabaseAuthService.deletionRequiresReauthentication(AccountDeletionError.walletConflict(message: nil)))
        XCTAssertFalse(SupabaseAuthService.deletionRequiresReauthentication(AccountDeletionError.ambiguous))
        XCTAssertFalse(SupabaseAuthService.deletionRequiresReauthentication(AccountDeletionError.sessionInvalid))
        XCTAssertFalse(SupabaseAuthService.deletionRequiresReauthentication(AccountDeletionError.failed(message: nil)))
        struct SomeOtherError: Error {}
        XCTAssertFalse(SupabaseAuthService.deletionRequiresReauthentication(SomeOtherError()))
    }

    /// A wallet conflict (the RESTRICT defensive guard tripping server-side) must surface its own
    /// server-provided message verbatim rather than a generic fallback, since it's the one error
    /// that tells the user exactly what to fix (unlink a shared wallet) before retrying.
    func testWalletConflictSurfacesServerMessage() {
        let message = SupabaseAuthService.userFacingMessage(
            for: AccountDeletionError.walletConflict(message: "Another account has transactions linked to one of your wallets."),
            flow: .deleteAccount
        )
        XCTAssertEqual(message, "Another account has transactions linked to one of your wallets.")
    }

    func testWalletConflictWithoutServerMessageFallsBackToGenericConflictCopy() {
        let message = SupabaseAuthService.userFacingMessage(for: AccountDeletionError.walletConflict(message: nil), flow: .deleteAccount)
        XCTAssertEqual(message, "Another account has transactions linked to one of your wallets.")
    }

    /// The ambiguous case (GoTrue's `user_not_found` — the JWT and session are fine, but the
    /// user row is gone, as a retried call after the real deletion's response was lost would
    /// look) must say so honestly — never phrased as a confirmed success or a plain retry error.
    func testAmbiguousDeletionOutcomeGetsItsOwnHonestMessage() {
        let message = SupabaseAuthService.userFacingMessage(for: AccountDeletionError.ambiguous, flow: .deleteAccount)
        XCTAssertEqual(message, "We couldn't confirm this completed. If your account still exists, sign in again and retry.")
    }

    /// A generic/unmapped deletion failure (network error, the irreversible `deleteUser` call
    /// itself failing) falls back to `.deleteAccount`'s own generic copy.
    func testGenericDeletionFailureFallsBackToDeleteAccountFlowMessage() {
        let message = SupabaseAuthService.userFacingMessage(for: AccountDeletionError.failed(message: nil), flow: .deleteAccount)
        XCTAssertEqual(message, "Couldn't delete your account. Please try again.")
    }

    // MARK: - Reauthentication hardening (Phase 6.0.5, second pass)
    //
    // v2 of the delete-account Edge Function sent the caller's password in its own request body
    // and verified it server-side via `signInWithPassword`. That IS real verification, but the
    // Supabase Dashboard's Edge Functions "Invocations" view captures full request bodies by
    // default (confirmed directly from Supabase's own docs) with no documented redaction — so a
    // plaintext password would sit in a retained log for no good reason.
    //
    // v3 (current) verifies the password entirely client-side via the ordinary
    // `signIn(email:password:)` call `AccountView.deleteAccount` makes before ever invoking the
    // delete-account function — the same path every login already uses, not a custom function's
    // logged body — and the function independently confirms, server-side via the Admin API, that
    // this sign-in actually happened recently (`auth.users.last_sign_in_at`, which a plain
    // refresh-token grant never touches, confirmed by reading `supabase/auth`'s source) rather
    // than trusting the client's say-so or a merely-valid JWT.
    //
    // A wrong password is no longer a case this error type represents at all: `signIn` throws a
    // plain `AuthError.invalidCredentials` before the delete-account function is ever called, so
    // that failure is covered by the pre-existing sign-in message mapping, not here.

    /// A stale-but-otherwise-valid sign-in (the pre-call `signIn` succeeded, but the Edge
    /// Function's own `last_sign_in_at` freshness check rejected it — clock skew, an unusually
    /// slow hop between the two calls) gets a prompt that matches what actually happened: sign in
    /// again and retry, not "enter your password" (already done) or "that was wrong" (it wasn't).
    func testReauthenticationRequiredMapsToStaleAuthPrompt() {
        let message = SupabaseAuthService.userFacingMessage(for: AccountDeletionError.reauthenticationRequired, flow: .deleteAccount)
        XCTAssertEqual(message, "Please sign in again, then retry deleting your account.")
    }

    /// A plain invalid, expired, or revoked session (GoTrue's `bad_jwt`/`session_not_found`, or
    /// no Authorization header) is a materially different situation from "may already be
    /// deleted" and must never be funneled into the ambiguous/local-wipe path — the account is
    /// presumably fully intact, so this just asks the user to sign in again.
    func testSessionInvalidMapsToSignInAgainMessageAndNeverRequiresReauthentication() {
        let error = AccountDeletionError.sessionInvalid
        XCTAssertFalse(
            SupabaseAuthService.deletionRequiresReauthentication(error),
            "an invalid/expired/revoked session must not be treated as the stale-sign-in case"
        )
        XCTAssertEqual(
            SupabaseAuthService.userFacingMessage(for: error, flow: .deleteAccount),
            "Your session is no longer valid. Please sign in again."
        )
    }

    /// Deletion failing *after* reauthentication already succeeded (the irreversible
    /// `admin.deleteUser` call itself erroring — network blip, rate limit, Auth outage) is a
    /// different situation from a stale/invalid session and must not be confused with one:
    /// `deletionRequiresReauthentication` must stay false, and no raw server message ever leaks
    /// into the UI regardless of what the Edge Function's `message` field contained.
    func testDeletionFailureAfterSuccessfulAuthorizationNeverRequiresReauthentication() {
        let error = AccountDeletionError.failed(message: "relation \"wallets\" does not exist")
        XCTAssertFalse(SupabaseAuthService.deletionRequiresReauthentication(error))
        XCTAssertEqual(
            SupabaseAuthService.userFacingMessage(for: error, flow: .deleteAccount),
            "Couldn't delete your account. Please try again.",
            "a raw Postgres/GoTrue error string must never reach the user, even wrapped in .failed"
        )
    }

    /// The one outcome that may be treated as "may already be deleted" (GoTrue's own
    /// `user_not_found` code) must say so honestly rather than claiming confirmed success — this
    /// locks in the distinction between `.ambiguous` and `.sessionInvalid` from the user-facing
    /// copy's own perspective, not just the routing logic above.
    func testAmbiguousOutcomeNeverClaimsConfirmedSuccess() {
        let message = SupabaseAuthService.userFacingMessage(for: AccountDeletionError.ambiguous, flow: .deleteAccount)
        XCTAssertFalse(message.localizedCaseInsensitiveContains("deleted"), "must not imply deletion is confirmed")
        XCTAssertEqual(message, "We couldn't confirm this completed. If your account still exists, sign in again and retry.")
    }

    /// Partial outcome: the irreversible `admin.deleteUser` call succeeded but avatar Storage
    /// cleanup didn't (even after the Edge Function's bounded retries) — `AccountDeletionResponse`
    /// must decode `avatarCleanupFailed` faithfully rather than collapsing it into `success`, so
    /// the account deletion itself is never misreported just because a cosmetic cleanup step
    /// failed, and vice versa a clean run must decode `false`, not merely absent/nil-like.
    func testAccountDeletionResponseDecodesPartialStorageOutcome() throws {
        let decoder = JSONDecoder()

        let partial = try decoder.decode(AccountDeletionResponse.self, from: Data(#"{"success":true,"avatarCleanupFailed":true}"#.utf8))
        XCTAssertTrue(partial.success, "the account itself must still read as deleted — that's the irreversible, already-committed step")
        XCTAssertTrue(partial.avatarCleanupFailed, "the Storage failure must be visible, not swallowed into a flat success")

        let clean = try decoder.decode(AccountDeletionResponse.self, from: Data(#"{"success":true,"avatarCleanupFailed":false}"#.utf8))
        XCTAssertTrue(clean.success)
        XCTAssertFalse(clean.avatarCleanupFailed)
    }

    // MARK: - ProfileDTO decoding

    private func decodeProfile(_ json: String) throws -> ProfileDTO {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProfileDTO.self, from: Data(json.utf8))
    }

    /// The common case once Phase C ships: both `display_name` and `avatar_url` are set.
    func testProfileDTODecodesDisplayNameAndAvatarURL() throws {
        let profile = try decodeProfile("""
        {"id":"8f14e45f-ceea-467e-bd42-dffb0c2343aa","created_at":"2026-01-01T00:00:00Z","display_name":"Andrea","avatar_url":"https://example.com/avatars/8f14e45f/avatar.jpg?cacheNonce=abc"}
        """)
        XCTAssertEqual(profile.displayName, "Andrea")
        XCTAssertEqual(profile.avatarURL, "https://example.com/avatars/8f14e45f/avatar.jpg?cacheNonce=abc")
    }

    /// A profile row that predates Phase C (or simply never had a photo uploaded) has a `NULL`
    /// `avatar_url` column — must decode to `nil`, not throw, so `fetchCurrentProfile` keeps
    /// working for every existing account.
    func testProfileDTODecodesNullAvatarURLAsNil() throws {
        let profile = try decodeProfile("""
        {"id":"8f14e45f-ceea-467e-bd42-dffb0c2343aa","created_at":"2026-01-01T00:00:00Z","display_name":null,"avatar_url":null}
        """)
        XCTAssertNil(profile.displayName)
        XCTAssertNil(profile.avatarURL)
    }
}
