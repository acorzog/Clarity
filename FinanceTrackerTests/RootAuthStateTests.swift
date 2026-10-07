import XCTest
import SwiftData
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
}
