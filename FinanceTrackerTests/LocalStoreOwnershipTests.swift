import XCTest
import SwiftData
@testable import FinanceTracker

/// Phase 6.1 — Local Account Isolation. Covers `LocalStoreOwnership.decide` as a pure rule (no
/// dependencies at all), and `LocalAccountTransition.establishOwnership` as the actual
/// orchestration `RootView.establishSignedIn` delegates to for every signed-in transition —
/// exercised directly here, the same way `RootAuthStateTests` exercises `RootAuthState` rather
/// than driving `RootView` itself, since neither needs a live SwiftUI view or a real session.
final class LocalStoreOwnershipTests: XCTestCase {

    // MARK: - LocalStoreOwnership.decide (pure)

    func testNoStoredOwnerAdopts() {
        XCTAssertEqual(
            LocalStoreOwnership.decide(storedOwnerID: nil, authenticatedUserID: UUID()),
            .adopt,
            "a pre-6.1 install (or a genuinely fresh one) must adopt the signed-in user, never wipe"
        )
    }

    func testSameOwnerIsAlreadyOwner() {
        let userID = UUID()
        XCTAssertEqual(
            LocalStoreOwnership.decide(storedOwnerID: userID, authenticatedUserID: userID),
            .alreadyOwner
        )
    }

    func testDifferentOwnerWipes() {
        XCTAssertEqual(
            LocalStoreOwnership.decide(storedOwnerID: UUID(), authenticatedUserID: UUID()),
            .wipe
        )
    }

    // MARK: - Test doubles

    private final class InMemoryLocalStoreOwnerStore: LocalStoreOwnerStoring {
        var ownerUserID: UUID?
    }

    private final class InMemorySyncLastSuccessStore: SyncLastSuccessStoring {
        var lastSuccessfulSync: Date?
    }

    /// Forwards the real `ModelContext.didSave` notification a genuine `context.save()` posts
    /// into `coordinator.handleDidSave` — mirrors `SyncCoordinatorTests`' own `observeDidSave`
    /// helper (private to that file, so duplicated here rather than shared).
    @MainActor
    private func observeDidSave(on observedContext: ModelContext, forwardingTo coordinator: SyncCoordinator) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: observedContext, queue: nil) { notification in
            MainActor.assumeIsolated {
                coordinator.handleDidSave(notification, modelContext: observedContext)
            }
        }
    }

    // MARK: - The reported regression: User A → sign out → User B

    /// The exact bug report, reproduced directly: a device with User A's already-synced local
    /// data (head categories, categories, wallets, entries, all carrying a `remoteID`), followed
    /// by User B authenticating, must end up with an empty local store — not B seeing any of A's
    /// rows, and critically not automatic sync ever getting a chance to push A's rows under B's id.
    @MainActor
    func testUserSwitchErasesThePreviousUsersLocalRows() throws {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory()
        head.remoteID = UUID()
        context.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        category.remoteID = UUID()
        context.insert(category)
        let wallet = TestSupport.makeWallet()
        wallet.remoteID = UUID()
        context.insert(wallet)
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, category: category, wallet: wallet)
        entry.remoteID = UUID()
        context.insert(entry)
        try context.save()

        let ownerStore = InMemoryLocalStoreOwnerStore()
        let userA = UUID()
        ownerStore.ownerUserID = userA
        let coordinator = SyncCoordinator(lastSyncStore: InMemorySyncLastSuccessStore())

        let userB = UUID()
        try LocalAccountTransition.establishOwnership(
            userID: userB, modelContext: context, ownerStore: ownerStore, syncCoordinator: coordinator
        )

        XCTAssertTrue(try context.fetch(FetchDescriptor<HeadCategory>()).isEmpty, "User A's head categories must be gone")
        XCTAssertTrue(try context.fetch(FetchDescriptor<FinanceTracker.Category>()).isEmpty, "User A's categories must be gone")
        XCTAssertTrue(try context.fetch(FetchDescriptor<Wallet>()).isEmpty, "User A's wallets must be gone")
        XCTAssertTrue(try context.fetch(FetchDescriptor<Entry>()).isEmpty, "User A's entries must be gone")
        XCTAssertEqual(ownerStore.ownerUserID, userB, "the marker must now record User B as the store's owner")
    }

    /// The backward-compatibility case: no marker exists yet (a pre-6.1 install, or this device's
    /// first-ever authenticated transition), so the currently-signed-in user is adopted without
    /// touching any existing data.
    @MainActor
    func testFirstRunAdoptsWithoutWipingExistingData() throws {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory()
        head.remoteID = UUID()
        context.insert(head)
        try context.save()

        let ownerStore = InMemoryLocalStoreOwnerStore()
        XCTAssertNil(ownerStore.ownerUserID, "setup: no marker yet")
        let coordinator = SyncCoordinator(lastSyncStore: InMemorySyncLastSuccessStore())
        let userA = UUID()

        try LocalAccountTransition.establishOwnership(
            userID: userA, modelContext: context, ownerStore: ownerStore, syncCoordinator: coordinator
        )

        XCTAssertEqual(try context.fetch(FetchDescriptor<HeadCategory>()).count, 1, "existing data must survive an adopt — this is backward compatibility for every pre-6.1 install")
        XCTAssertEqual(ownerStore.ownerUserID, userA)
    }

    /// Signing in again as the same user must never wipe anything.
    @MainActor
    func testSameUserSigningInAgainDoesNotWipe() throws {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        try context.save()

        let userA = UUID()
        let ownerStore = InMemoryLocalStoreOwnerStore()
        ownerStore.ownerUserID = userA
        let coordinator = SyncCoordinator(lastSyncStore: InMemorySyncLastSuccessStore())

        try LocalAccountTransition.establishOwnership(
            userID: userA, modelContext: context, ownerStore: ownerStore, syncCoordinator: coordinator
        )

        XCTAssertEqual(try context.fetch(FetchDescriptor<HeadCategory>()).count, 1, "the same user reauthenticating must never wipe their own data")
    }

    // MARK: - SyncCoordinator state reset after a wipe

    @MainActor
    func testWipeResetsSyncCoordinatorState() throws {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        try context.save()

        let lastSyncStore = InMemorySyncLastSuccessStore()
        lastSyncStore.lastSuccessfulSync = .now
        let coordinator = SyncCoordinator(lastSyncStore: lastSyncStore)

        let token = observeDidSave(on: context, forwardingTo: coordinator)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)
        try context.save()
        NotificationCenter.default.removeObserver(token)
        XCTAssertTrue(coordinator.hasPendingLocalChanges, "setup: a syncable save must have marked pending changes")

        let ownerStore = InMemoryLocalStoreOwnerStore()
        ownerStore.ownerUserID = UUID()

        try LocalAccountTransition.establishOwnership(
            userID: UUID(), modelContext: context, ownerStore: ownerStore, syncCoordinator: coordinator
        )

        XCTAssertNil(lastSyncStore.lastSuccessfulSync, "a wipe must clear lastSuccessfulSync so the new user's first sync isn't skipped as 'not stale yet'")
        XCTAssertFalse(coordinator.hasPendingLocalChanges, "a wipe must clear hasPendingLocalChanges — it referred to the previous user's now-deleted data")
    }

    /// `.alreadyOwner`/`.adopt` must never touch `SyncCoordinator` state — only a genuine wipe does.
    @MainActor
    func testNoWipeLeavesSyncCoordinatorStateUntouched() throws {
        let context = TestSupport.makeInMemoryContext()
        let lastSyncStore = InMemorySyncLastSuccessStore()
        let recordedSync = Date.now.addingTimeInterval(-60)
        lastSyncStore.lastSuccessfulSync = recordedSync
        let coordinator = SyncCoordinator(lastSyncStore: lastSyncStore)
        let userA = UUID()
        let ownerStore = InMemoryLocalStoreOwnerStore()
        ownerStore.ownerUserID = userA

        try LocalAccountTransition.establishOwnership(
            userID: userA, modelContext: context, ownerStore: ownerStore, syncCoordinator: coordinator
        )

        XCTAssertEqual(lastSyncStore.lastSuccessfulSync, recordedSync, "the same user reauthenticating must not reset sync bookkeeping")
    }

    // MARK: - Seeding must stay decoupled from ownership establishment

    /// `establishOwnership` alone — the step every sign-in (including an ordinary, existing-user
    /// one) runs — must never seed. An existing user's data comes from sync, not a generic
    /// starter set, even though a just-wiped store is empty.
    @MainActor
    func testOwnershipEstablishmentAloneNeverSeeds() throws {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        try context.save()

        let ownerStore = InMemoryLocalStoreOwnerStore()
        ownerStore.ownerUserID = UUID() // a different user triggers a wipe
        let coordinator = SyncCoordinator(lastSyncStore: InMemorySyncLastSuccessStore())

        try LocalAccountTransition.establishOwnership(
            userID: UUID(), modelContext: context, ownerStore: ownerStore, syncCoordinator: coordinator
        )

        XCTAssertTrue(try context.fetch(FetchDescriptor<HeadCategory>()).isEmpty, "the store is empty after the wipe")
        // Mirrors RootView/LoginView's existing-user sign-in path: no SeedData call follows —
        // the store must stay empty, never auto-seeded just because it has zero rows.
        XCTAssertTrue(try context.fetch(FetchDescriptor<Wallet>()).isEmpty, "an existing user must never be seeded merely because their post-wipe store is empty")
    }

    /// Mirrors `RootView.establishSignedIn`'s `seedIfNewAccount: true` path (fresh sign-up, email
    /// confirmation) — ownership establishment followed by the existing `SeedData.seedIfNeeded`
    /// call must still produce the usual starter categories/wallet for a genuinely new account.
    @MainActor
    func testNewAccountCompletionStillGetsExistingSeedBehavior() throws {
        let context = TestSupport.makeInMemoryContext()
        let ownerStore = InMemoryLocalStoreOwnerStore() // no marker yet — this device's first run
        let coordinator = SyncCoordinator(lastSyncStore: InMemorySyncLastSuccessStore())
        let newUserID = UUID()

        try LocalAccountTransition.establishOwnership(
            userID: newUserID, modelContext: context, ownerStore: ownerStore, syncCoordinator: coordinator
        )
        try SeedData.seedIfNeeded(context: context)

        let headCategories = try context.fetch(FetchDescriptor<HeadCategory>())
        let wallets = try context.fetch(FetchDescriptor<Wallet>())
        XCTAssertFalse(headCategories.isEmpty, "a genuinely new account must still get the starter head categories")
        XCTAssertEqual(wallets.count, 1, "a genuinely new account must still get the default wallet")
        XCTAssertEqual(ownerStore.ownerUserID, newUserID)
    }

    /// Phase 6.0.3 — mirrors `RootView.handleEmailChangeLink`'s exact composition: ownership
    /// establishment for the *same* user id (an email change never changes who's signed in, so
    /// this is always `.alreadyOwner`, never a wipe) with no `SeedData` call following it at all.
    /// An email-change confirmation is always an existing, already-signed-in user and must never
    /// seed — unlike `handleEmailConfirmationLink`'s genuinely-new-account path.
    @MainActor
    func testEmailChangeConfirmationNeverSeeds() throws {
        let context = TestSupport.makeInMemoryContext()
        let userID = UUID()
        let ownerStore = InMemoryLocalStoreOwnerStore()
        ownerStore.ownerUserID = userID
        let coordinator = SyncCoordinator(lastSyncStore: InMemorySyncLastSuccessStore())

        try LocalAccountTransition.establishOwnership(
            userID: userID, modelContext: context, ownerStore: ownerStore, syncCoordinator: coordinator
        )
        // RootView.handleEmailChangeLink never calls SeedData.seedIfNeeded afterward — the store
        // must remain untouched, not just "still empty by coincidence."
        XCTAssertTrue(try context.fetch(FetchDescriptor<HeadCategory>()).isEmpty, "an email-change confirmation must never seed local data")
        XCTAssertTrue(try context.fetch(FetchDescriptor<Wallet>()).isEmpty, "an email-change confirmation must never seed local data")
    }

    // MARK: - wipeAfterAccountDeletion (Phase 6.0.5)

    /// The confirmed-success path: the local store is actually wiped, so it's safe to clear the
    /// owner marker and reset `SyncCoordinator`'s bookkeeping.
    @MainActor
    func testWipeAfterAccountDeletionSuccessClearsOwnerMarker() throws {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        try context.save()

        let deletedUserID = UUID()
        let ownerStore = InMemoryLocalStoreOwnerStore()
        ownerStore.ownerUserID = deletedUserID
        let lastSyncStore = InMemorySyncLastSuccessStore()
        lastSyncStore.lastSuccessfulSync = .now
        let coordinator = SyncCoordinator(lastSyncStore: lastSyncStore)

        LocalAccountTransition.wipeAfterAccountDeletion(
            modelContext: context, ownerStore: ownerStore, syncCoordinator: coordinator
        )

        XCTAssertTrue(try context.fetch(FetchDescriptor<HeadCategory>()).isEmpty, "the deleted account's local data must be gone")
        XCTAssertNil(ownerStore.ownerUserID, "a successful wipe must clear the owner marker — the store genuinely has no owner now")
        XCTAssertNil(lastSyncStore.lastSuccessfulSync, "sync bookkeeping must be reset so it can't confuse a future account on this device")
    }

    /// The critical safety case: if the local wipe itself fails (disk error, locked store, etc.),
    /// the owner marker must be LEFT POINTING at the deleted user's id — not cleared — so that the
    /// next account to sign in on this device (a different user; Supabase never reissues a
    /// deleted user's UUID) still triggers `LocalStoreOwnership.decide`'s `.wipe` path instead of
    /// silently inheriting the deleted account's leftover local rows.
    @MainActor
    func testWipeAfterAccountDeletionFailureLeavesOwnerMarkerIntact() throws {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        try context.save()

        let deletedUserID = UUID()
        let ownerStore = InMemoryLocalStoreOwnerStore()
        ownerStore.ownerUserID = deletedUserID
        let lastSyncStore = InMemorySyncLastSuccessStore()
        let coordinator = SyncCoordinator(lastSyncStore: lastSyncStore)

        struct SimulatedEraseFailure: Error {}

        LocalAccountTransition.wipeAfterAccountDeletion(
            modelContext: context, ownerStore: ownerStore, syncCoordinator: coordinator,
            erase: { _ in throw SimulatedEraseFailure() }
        )

        XCTAssertEqual(ownerStore.ownerUserID, deletedUserID, "a failed wipe must leave the marker pointing at the deleted user, not clear it")
        XCTAssertEqual(try context.fetch(FetchDescriptor<HeadCategory>()).count, 1, "data is untouched since the simulated erase never actually ran")
    }

    /// End-to-end isolation proof: a failed post-deletion wipe leaves stale data and an intact
    /// marker, and a *different* user signing in afterward must still wipe that stale data before
    /// their own session begins — the exact scenario Phase 6.0.5 must not regress on Phase 6.1's
    /// account-switch guarantee.
    @MainActor
    func testDifferentUserAfterFailedDeletionWipeStillGetsIsolated() throws {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        try context.save()

        let deletedUserID = UUID()
        let ownerStore = InMemoryLocalStoreOwnerStore()
        ownerStore.ownerUserID = deletedUserID
        let coordinator = SyncCoordinator(lastSyncStore: InMemorySyncLastSuccessStore())

        struct SimulatedEraseFailure: Error {}
        LocalAccountTransition.wipeAfterAccountDeletion(
            modelContext: context, ownerStore: ownerStore, syncCoordinator: coordinator,
            erase: { _ in throw SimulatedEraseFailure() }
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<HeadCategory>()).count, 1, "setup: the deleted account's stale data is still on disk")

        let nextUserID = UUID()
        try LocalAccountTransition.establishOwnership(
            userID: nextUserID, modelContext: context, ownerStore: ownerStore, syncCoordinator: coordinator
        )

        XCTAssertTrue(try context.fetch(FetchDescriptor<HeadCategory>()).isEmpty, "the next user signing in must never see the deleted account's leftover data")
        XCTAssertEqual(ownerStore.ownerUserID, nextUserID)
    }
}
