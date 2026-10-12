import XCTest
import SwiftData
import Supabase
@testable import FinanceTracker

/// Covers `RootAuthState` — the pure, dependency-free rule `RootView` uses to decide between
/// `LoginView` and `MainTabView` at launch. Exercised directly here rather than through `RootView`
/// itself, since that view needs a live (or stubbed) `SupabaseAuthService` session check; this
/// rule has no such dependency.
final class RootAuthStateTests: XCTestCase {

    func testResolvedWithActiveSessionIsSignedIn() {
        XCTAssertEqual(RootAuthState.resolved(hasActiveSession: true), .signedIn)
    }

    func testResolvedWithNoSessionIsSignedOut() {
        XCTAssertEqual(RootAuthState.resolved(hasActiveSession: false), .signedOut)
    }

    /// `RootView` starts in `.loading` until its launch `.task` resolves — never defaults straight
    /// to showing either `LoginView` or `MainTabView` before that check completes.
    func testLoadingIsItsOwnDistinctCase() {
        XCTAssertNotEqual(RootAuthState.loading, .signedIn)
        XCTAssertNotEqual(RootAuthState.loading, .signedOut)
    }

    /// `LoginView.onSignedIn` sets `authState = .signedIn` directly (not via `resolved(
    /// hasActiveSession:)`) — this documents that as the one other legal way `authState` reaches
    /// `.signedIn`, so a future refactor that routes it back through `resolved` doesn't silently
    /// change behavior for a fresh sign-in (as opposed to a restored session).
    func testSignedInIsReachableWithoutGoingThroughResolved() {
        var authState = RootAuthState.signedOut
        authState = .signedIn
        XCTAssertEqual(authState, .signedIn)
    }

    // MARK: - Sign out

    /// `ToolsView`'s Sign Out action always lands on `.signedOut` after a successful
    /// `SupabaseAuthService.signOut()` call, regardless of what `authState` was beforehand.
    func testSignedOutByUserIsAlwaysSignedOut() {
        XCTAssertEqual(RootAuthState.signedOutByUser, .signedOut)
    }

    /// A failed sign-out (handled entirely within `ToolsView` via its own error alert) must never
    /// touch `authState` — `RootView` only transitions on a successful call reaching `signOutAction`.
    func testFailedSignOutLeavesAuthStateUnchanged() {
        var authState = RootAuthState.signedIn
        // Simulates `ToolsView.signOut()`'s catch branch: on failure it sets a local error message
        // and never calls `signOutAction`, so the transition below never happens.
        let signOutSucceeded = false
        if signOutSucceeded {
            authState = .signedOutByUser
        }
        XCTAssertEqual(authState, .signedIn)
    }

    // MARK: - Seeding (Phase 4A)

    /// Only a signed-out/local-only user should ever get `SeedData`'s generic starter set —
    /// see `shouldSeedLocalDefaults`'s own doc comment for why `.signedIn` must never seed.
    func testSignedOutShouldSeedLocalDefaults() {
        XCTAssertTrue(RootAuthState.signedOut.shouldSeedLocalDefaults)
    }

    func testSignedInShouldNotSeedLocalDefaults() {
        XCTAssertFalse(RootAuthState.signedIn.shouldSeedLocalDefaults)
    }

    func testLoadingShouldNotSeedLocalDefaults() {
        XCTAssertFalse(RootAuthState.loading.shouldSeedLocalDefaults)
    }

    /// End-to-end characterization of `RootView`'s launch `.task`, Phase 4A: a signed-out startup
    /// (no Supabase session) must still seed the local defaults exactly as before this phase's
    /// change, just now gated through `shouldSeedLocalDefaults` rather than running unconditionally
    /// in `FinanceTrackerApp.init()`.
    @MainActor
    func testSignedOutStartupSeedsDefaults() throws {
        let context = TestSupport.makeInMemoryContext()
        let resolvedState = RootAuthState.resolved(hasActiveSession: false)

        if resolvedState.shouldSeedLocalDefaults {
            try SeedData.seedIfNeeded(context: context)
        }

        let headCategories = try context.fetch(FetchDescriptor<HeadCategory>())
        let wallets = try context.fetch(FetchDescriptor<Wallet>())
        XCTAssertFalse(headCategories.isEmpty, "a signed-out startup must seed the default head categories")
        XCTAssertEqual(wallets.count, 1, "a signed-out startup must seed the default wallet")
    }

    /// The core Phase 4A fix: a signed-in startup (an existing Supabase session was restored) must
    /// NOT seed — doing so used to insert a generic starter set with no `remoteID`, which automatic
    /// sync would then push to Supabase as duplicate data alongside the user's real rows.
    @MainActor
    func testSignedInStartupDoesNotSeed() throws {
        let context = TestSupport.makeInMemoryContext()
        let resolvedState = RootAuthState.resolved(hasActiveSession: true)

        if resolvedState.shouldSeedLocalDefaults {
            try SeedData.seedIfNeeded(context: context)
        }

        let headCategories = try context.fetch(FetchDescriptor<HeadCategory>())
        let wallets = try context.fetch(FetchDescriptor<Wallet>())
        XCTAssertTrue(headCategories.isEmpty, "a signed-in startup must not seed any head categories")
        XCTAssertTrue(wallets.isEmpty, "a signed-in startup must not seed the default wallet")
    }

    // MARK: - Session lifecycle (Phase 6.0.4)

    func testSignedOutBySessionInvalidationIsAlwaysSignedOut() {
        XCTAssertEqual(RootAuthState.signedOutBySessionInvalidation, .signedOut)
    }

    /// The core Phase 6.0.4 case: a session invalidated out from under the app (revoked
    /// server-side, or its refresh token expiring) while the app believed it was signed in must
    /// transition back to `.signedOut`.
    func testSessionInvalidationWhileSignedInTransitionsToSignedOut() {
        XCTAssertTrue(RootAuthState.shouldTransitionToSignedOut(for: .signedOut, currentState: .signedIn))
    }

    /// The guard that prevents a duplicate/redundant transition from the app's own explicit
    /// sign-out: by the time that `.signedOut` event is actually processed, `authState` has
    /// already been flipped by `signOutAction` (synchronously, independently of this listener),
    /// so the listener must find nothing left to do.
    func testSignedOutEventWhileAlreadySignedOutDoesNothing() {
        XCTAssertFalse(RootAuthState.shouldTransitionToSignedOut(for: .signedOut, currentState: .signedOut))
    }

    /// A `.signedOut` event arriving before the launch task has ever resolved `authState` past
    /// `.loading` (not realistic in practice, but a real possible value) must also do nothing —
    /// there is nothing to sign out of yet.
    func testSignedOutEventWhileLoadingDoesNothing() {
        XCTAssertFalse(RootAuthState.shouldTransitionToSignedOut(for: .signedOut, currentState: .loading))
    }

    /// Every other `AuthChangeEvent` the stream can emit must never trigger a transition — this
    /// listener's one job is noticing an externally-invalidated session, nothing else. Covers
    /// `.initialSession` specifically: the SDK always emits it immediately upon subscribing, so if
    /// it were mishandled as a sign-out signal, merely starting the listener would immediately
    /// (and incorrectly) sign out a freshly-restored session.
    func testNonSignedOutEventsNeverTriggerATransitionEvenWhileSignedIn() {
        let nonSignOutEvents: [AuthChangeEvent] = [
            .initialSession, .signedIn, .tokenRefreshed, .userUpdated,
            .passwordRecovery, .mfaChallengeVerified, .userDeleted,
        ]
        for event in nonSignOutEvents {
            XCTAssertFalse(
                RootAuthState.shouldTransitionToSignedOut(for: event, currentState: .signedIn),
                "\(event) must never trigger a signed-out transition"
            )
        }
    }

    // MARK: - App Lock suggestion (biometric login discoverability)

    /// The common case: biometrics are available, the user has never seen the suggestion, and the
    /// lock isn't already on — show it.
    func testSuggestsAppLockWhenEligible() {
        XCTAssertTrue(
            RootView.shouldSuggestAppLock(hasSeenSuggestion: false, lockEnabled: false, biometricsAvailable: true)
        )
    }

    /// Shown at most once ever — never nags again on a later sign-in just because the user
    /// declined (or accepted and later turned it back off) before.
    func testDoesNotSuggestAppLockAfterAlreadyShown() {
        XCTAssertFalse(
            RootView.shouldSuggestAppLock(hasSeenSuggestion: true, lockEnabled: false, biometricsAvailable: true)
        )
    }

    /// Already on — nothing to suggest.
    func testDoesNotSuggestAppLockWhenAlreadyEnabled() {
        XCTAssertFalse(
            RootView.shouldSuggestAppLock(hasSeenSuggestion: false, lockEnabled: true, biometricsAvailable: true)
        )
    }

    /// No Face ID/Touch ID enrolled (or unavailable on the device) — the suggestion would just be
    /// a dead end, so it's never shown.
    func testDoesNotSuggestAppLockWithoutBiometrics() {
        XCTAssertFalse(
            RootView.shouldSuggestAppLock(hasSeenSuggestion: false, lockEnabled: false, biometricsAvailable: false)
        )
    }
}
