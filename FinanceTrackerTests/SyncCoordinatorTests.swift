import XCTest
import SwiftData
@testable import FinanceTracker

/// Phase 3C/4C: covers `SyncCoordinator`'s scheduling behavior — debounce/coalescing, overlap
/// protection, session gating, and pull-then-push sync ordering. Uses the exact same
/// `SupabaseReferenceDataUploading`/`SupabaseReferenceDataDownloading`/`SupabaseSyncUserProviding`
/// mock pattern `SupabaseSyncServiceTests`/`EntrySyncTests`/`BudgetSyncTests`/
/// `PullReferenceDataTests` already use, wrapped in a real `SupabaseSyncService` —
/// `SyncCoordinator` itself is only ever given that real service plus a mock session checker,
/// never a mock `SupabaseSyncService`, so these tests exercise the actual call sequence
/// `SyncCoordinator` produces. No network connection is used anywhere here; small `Duration`s
/// stand in for the debounce interval so these run in well under a second.
private final class OrderedCallLog {
    private(set) var calls: [String] = []
    func record(_ name: String) { calls.append(name) }
}

private final class RecordingUploader: SupabaseReferenceDataUploading {
    private(set) var callOrder: [String] = []
    /// Lets a test simulate a slow/in-flight network call, to exercise the `isSyncing` overlap
    /// guard deterministically instead of racing real timing.
    var headCategoriesBatchDelay: Duration?
    /// Optional cross-recorder order log — only set by tests that need to verify relative
    /// ordering between `RecordingDownloader`'s pull calls and this uploader's push calls;
    /// `callOrder` alone can't show that since it only ever sees this object's own calls. Left
    /// `nil` (the default) for every pre-existing push-only test, so `callOrder`'s contents are
    /// completely unaffected by Phase 4C's pull wiring.
    var sharedLog: OrderedCallLog?
    /// Flipped the instant `upsertHeadCategories` is *entered*, before `headCategoriesBatchDelay`
    /// elapses — so a test can detect "the push has genuinely started" without waiting for the
    /// delay to finish (`callOrder` isn't appended to until after it).
    private(set) var hasStartedUploadingHeadCategories = false

    private func record(_ name: String) {
        callOrder.append(name)
        sharedLog?.record(name)
    }

    func upsertHeadCategory(_ dto: HeadCategoryDTO) async throws {}
    func upsertCategory(_ dto: CategoryDTO) async throws {}
    func upsertWallet(_ dto: WalletDTO) async throws {}

    func upsertHeadCategories(_ dtos: [HeadCategoryDTO]) async throws {
        hasStartedUploadingHeadCategories = true
        if let delay = headCategoriesBatchDelay {
            try? await Task.sleep(for: delay)
        }
        record("headCategoriesBatch")
    }

    func upsertCategories(_ dtos: [CategoryDTO]) async throws { record("categoriesBatch") }
    func upsertWallets(_ dtos: [WalletDTO]) async throws { record("walletsBatch") }
    func upsertBudgets(_ dtos: [BudgetDTO]) async throws { record("budgetsBatch") }
    func upsertEntries(_ dtos: [EntryDTO]) async throws { record("entriesBatch") }
}

/// Phase 4C — the pull-side counterpart to `RecordingUploader`, so `SyncCoordinator`'s tests can
/// supply a `SupabaseSyncService` that never touches the real network for either direction. Empty
/// DTO arrays by default (matching `RecordingUploader`'s empty-is-safe batches), so every
/// pre-existing push-ordering test keeps passing unchanged once pull is wired in ahead of push —
/// an empty pull is a real, successful pull, not a skipped one.
private final class RecordingDownloader: SupabaseReferenceDataDownloading {
    private(set) var callOrder: [String] = []
    var sharedLog: OrderedCallLog?
    var headCategories: [HeadCategoryDTO] = []
    var categories: [CategoryDTO] = []
    var wallets: [WalletDTO] = []
    /// Set by a test to make `pullReferenceData` fail partway through — the push-skipping
    /// behavior this is meant to exercise only matters if the failure happens *after* at least
    /// one pull call has already run.
    var errorToThrow: Error?
    /// Phase 4G.6 — lets a test pause mid-pull (after `fetchHeadCategories` is entered, before it
    /// returns) to simulate a cross-process notification landing exactly inside the
    /// `isApplyingPullChanges` window, deterministically instead of racing real timing.
    var headCategoriesDelay: Duration?
    private(set) var hasStartedFetchingHeadCategories = false

    private func record(_ name: String) throws {
        callOrder.append(name)
        sharedLog?.record(name)
        if let errorToThrow { throw errorToThrow }
    }

    func fetchHeadCategories(userID: UUID) async throws -> [HeadCategoryDTO] {
        hasStartedFetchingHeadCategories = true
        if let headCategoriesDelay {
            try? await Task.sleep(for: headCategoriesDelay)
        }
        try record("pullHeadCategories")
        return headCategories
    }

    func fetchCategories(userID: UUID) async throws -> [CategoryDTO] {
        try record("pullCategories")
        return categories
    }

    func fetchWallets(userID: UUID) async throws -> [WalletDTO] {
        try record("pullWallets")
        return wallets
    }
}

/// Phase 4F — the budget-pull counterpart to `RecordingDownloader`, same shape and same reasons.
private final class RecordingBudgetDownloader: SupabaseBudgetDownloading {
    private(set) var callOrder: [String] = []
    var sharedLog: OrderedCallLog?
    var budgets: [BudgetDTO] = []
    var errorToThrow: Error?

    func fetchBudgets(userID: UUID) async throws -> [BudgetDTO] {
        callOrder.append("pullBudgets")
        sharedLog?.record("pullBudgets")
        if let errorToThrow { throw errorToThrow }
        return budgets
    }
}

/// Phase 4F — the entry-pull counterpart to `RecordingDownloader`, same shape and same reasons.
private final class RecordingEntryDownloader: SupabaseEntryDownloading {
    private(set) var callOrder: [String] = []
    var sharedLog: OrderedCallLog?
    var entries: [EntryDTO] = []
    var errorToThrow: Error?

    func fetchEntries(userID: UUID) async throws -> [EntryDTO] {
        callOrder.append("pullEntries")
        sharedLog?.record("pullEntries")
        if let errorToThrow { throw errorToThrow }
        return entries
    }
}

private final class RecordingUserProvider: SupabaseSyncUserProviding {
    var userID: UUID?
    /// Phase 4G.3A — counts calls so a test can confirm `SyncCoordinator` resolves the user id
    /// exactly once per sync pass (via `SupabaseSyncService.requireUserID()`), not once per step.
    private(set) var callCount = 0
    func currentUserID() async throws -> UUID? {
        callCount += 1
        return userID
    }
}

private final class MockSessionChecker: SyncCoordinatorSessionChecking {
    var hasSession: Bool
    private(set) var callCount = 0

    init(hasSession: Bool) { self.hasSession = hasSession }

    func hasActiveSession() async -> Bool {
        callCount += 1
        return hasSession
    }
}

/// Phase 4G.3B — an in-memory stand-in for `UserDefaultsSyncLastSuccessStore`, so these tests
/// never touch real `UserDefaults`/the App Group suite.
private final class InMemorySyncLastSuccessStore: SyncLastSuccessStoring {
    var lastSuccessfulSync: Date?
}

final class SyncCoordinatorTests: XCTestCase {
    private var uploader: RecordingUploader!
    private var downloader: RecordingDownloader!
    private var budgetDownloader: RecordingBudgetDownloader!
    private var entryDownloader: RecordingEntryDownloader!
    private var userProvider: RecordingUserProvider!
    private var syncService: SupabaseSyncService!
    private var sessionChecker: MockSessionChecker!
    private var lastSyncStore: InMemorySyncLastSuccessStore!
    private var context: ModelContext!

    /// Short enough that every test here finishes in well under a second, long enough to leave a
    /// real window for a second `scheduleSync` call to land inside it and prove coalescing.
    private let tinyDebounce = Duration.milliseconds(20)

    @MainActor
    override func setUp() {
        super.setUp()
        uploader = RecordingUploader()
        downloader = RecordingDownloader()
        budgetDownloader = RecordingBudgetDownloader()
        entryDownloader = RecordingEntryDownloader()
        userProvider = RecordingUserProvider()
        userProvider.userID = UUID()
        syncService = SupabaseSyncService(
            uploader: uploader, downloader: downloader, budgetDownloader: budgetDownloader,
            entryDownloader: entryDownloader, userProvider: userProvider
        )
        sessionChecker = MockSessionChecker(hasSession: true)
        lastSyncStore = InMemorySyncLastSuccessStore()
        context = TestSupport.makeInMemoryContext()
        // A baseline head category so `syncReferenceData`'s first batch always has something to
        // upload — without this, the coalescing/overlap tests below (which don't care about the
        // exact row content, only how many times/in what order a sync happens) would see no
        // `headCategoriesBatch` call at all on an otherwise-empty store, making their assertions
        // meaningless.
        context.insert(TestSupport.makeHeadCategory())
        try? context.save()
    }

    /// Large enough that no test relying on the default never sees a spurious periodic tick
    /// fire mid-test; tests that specifically exercise periodic sync pass their own tiny value.
    private let noPeriodicTickInterval = Duration.seconds(3600)

    @MainActor
    private func makeCoordinator(debounceInterval: Duration? = nil, periodicSyncInterval: Duration? = nil) -> SyncCoordinator {
        SyncCoordinator(
            syncService: syncService,
            sessionChecker: sessionChecker,
            lastSyncStore: lastSyncStore,
            debounceInterval: debounceInterval ?? tinyDebounce,
            periodicSyncInterval: periodicSyncInterval ?? noPeriodicTickInterval
        )
    }

    /// Polls `condition` instead of sleeping a single fixed duration — the coalescing tests below
    /// wait on real (artificially-delayed) async work racing a debounce timer, which a blind sleep
    /// makes flaky under system load (a busy CI/dev machine can stretch wall-clock timing well
    /// past a fixed budget). Returns as soon as `condition` is true, or once `timeout` elapses,
    /// whichever comes first — fast on a quiet machine, robust on a loaded one.
    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Sync order

    @MainActor
    func testScheduleSyncUploadsReferenceDataThenBudgetsThenEntries() async throws {
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 1, year: 2026)
        context.insert(budget)
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, category: category, wallet: wallet)
        context.insert(entry)
        try context.save()

        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(uploader.callOrder, [
            "headCategoriesBatch", "categoriesBatch", "walletsBatch", "budgetsBatch", "entriesBatch",
        ])
    }

    // MARK: - Pull-then-push ordering (Phase 4C / 4F)

    /// All six steps must run to completion in the documented order — using a log shared between
    /// every recorder to capture their relative order, which no single recorder's own `callOrder`
    /// can show on its own: pull reference data, pull budgets, pull entries, push reference data,
    /// push budgets, push entries.
    @MainActor
    func testScheduleSyncRunsAllSixStepsInOrder() async throws {
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 1, year: 2026)
        context.insert(budget)
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, category: category, wallet: wallet)
        context.insert(entry)
        try context.save()

        let log = OrderedCallLog()
        downloader.sharedLog = log
        budgetDownloader.sharedLog = log
        entryDownloader.sharedLog = log
        uploader.sharedLog = log
        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(log.calls, [
            "pullHeadCategories", "pullCategories", "pullWallets", "pullBudgets", "pullEntries",
            "headCategoriesBatch", "categoriesBatch", "walletsBatch", "budgetsBatch", "entriesBatch",
        ])
    }

    /// A pull failure — at any one of the three pull steps — must stop the sync entirely: no push
    /// call (reference data, budgets, or entries) may run afterward.
    @MainActor
    func testScheduleSyncDoesNotPushWhenReferenceDataPullFails() async throws {
        struct PullFailure: Error {}
        downloader.errorToThrow = PullFailure()
        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertFalse(downloader.callOrder.isEmpty, "the pull should have at least started")
        XCTAssertTrue(budgetDownloader.callOrder.isEmpty, "a reference-data pull failure must stop the chain before budgets are pulled")
        XCTAssertTrue(entryDownloader.callOrder.isEmpty, "a reference-data pull failure must stop the chain before entries are pulled")
        XCTAssertTrue(uploader.callOrder.isEmpty, "no push call should run once pull has failed")
    }

    /// Same failure guarantee, but for the budget-pull step specifically: reference data must
    /// have already been pulled (it runs first), but entries must never be pulled, and nothing
    /// must be pushed.
    @MainActor
    func testScheduleSyncDoesNotPushWhenBudgetPullFails() async throws {
        struct PullFailure: Error {}
        budgetDownloader.errorToThrow = PullFailure()
        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertFalse(downloader.callOrder.isEmpty, "reference data must have already been pulled before budgets")
        XCTAssertFalse(budgetDownloader.callOrder.isEmpty, "the budget pull should have at least started")
        XCTAssertTrue(entryDownloader.callOrder.isEmpty, "a budget pull failure must stop the chain before entries are pulled")
        XCTAssertTrue(uploader.callOrder.isEmpty, "no push call should run once pull has failed")
    }

    /// Same failure guarantee, but for the entry-pull step specifically: both reference data and
    /// budgets must have already been pulled, but nothing must be pushed.
    @MainActor
    func testScheduleSyncDoesNotPushWhenEntryPullFails() async throws {
        struct PullFailure: Error {}
        entryDownloader.errorToThrow = PullFailure()
        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertFalse(downloader.callOrder.isEmpty, "reference data must have already been pulled before entries")
        XCTAssertFalse(budgetDownloader.callOrder.isEmpty, "budgets must have already been pulled before entries")
        XCTAssertFalse(entryDownloader.callOrder.isEmpty, "the entry pull should have at least started")
        XCTAssertTrue(uploader.callOrder.isEmpty, "no push call should run once pull has failed")
    }

    /// The mirror image of the failure cases above — a pull that succeeds at all three steps
    /// (even with nothing to pull) must still let push proceed exactly as it always has.
    @MainActor
    func testScheduleSyncProceedsToPushWhenPullSucceeds() async throws {
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        try context.save()
        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(downloader.callOrder, ["pullHeadCategories", "pullCategories", "pullWallets"])
        XCTAssertEqual(budgetDownloader.callOrder, ["pullBudgets"])
        XCTAssertEqual(entryDownloader.callOrder, ["pullEntries"])
        XCTAssertFalse(uploader.callOrder.isEmpty, "a successful pull should let push proceed")
    }

    /// The integration guarantee this phase is about: an `Entry` whose `walletID`/`categoryID`
    /// point at reference data that only exists *remotely* (not yet pulled into this local store)
    /// must still resolve successfully — not be skipped — because `pullReferenceData` runs, and
    /// saves, before `pullEntries` ever looks up those relationships locally. If entries were ever
    /// pulled first (or reference data weren't saved before entries ran), this would skip the
    /// entry instead of creating it.
    @MainActor
    func testEntryWithValidRemoteRelationshipIsNotSkippedWhenFullCoordinatorRuns() async throws {
        let remoteUserID = userProvider.userID!
        let headCategoryRemoteID = UUID()
        let categoryRemoteID = UUID()
        let walletRemoteID = UUID()
        let entryRemoteID = UUID()

        downloader.headCategories = [
            HeadCategoryDTO(
                id: headCategoryRemoteID, userID: remoteUserID, name: "Head", icon: "folder.fill",
                colorHex: "#FFFFFF", sortOrder: 0, createdAt: .now, updatedAt: .now
            ),
        ]
        downloader.categories = [
            CategoryDTO(
                id: categoryRemoteID, userID: remoteUserID, headCategoryID: headCategoryRemoteID, name: "Cat",
                customIcon: nil, iconIsEmoji: false, customColorHex: nil, isSavings: false, isArchived: false,
                isIncome: false, isFixedPlannedCategory: false, createdAt: .now, updatedAt: .now
            ),
        ]
        downloader.wallets = [
            WalletDTO(
                id: walletRemoteID, userID: remoteUserID, name: "Wallet", type: .spending, colorHex: "#FFFFFF",
                icon: "wallet.bifold", startingBalance: 0, goalAmount: nil, includeInNetWorth: true,
                isDefault: false, isArchived: false, sortOrder: 0, isDeleted: false, createdAt: .now, updatedAt: .now
            ),
        ]
        entryDownloader.entries = [
            EntryDTO(
                id: entryRemoteID, userID: remoteUserID, walletID: walletRemoteID, destinationWalletID: nil,
                categoryID: categoryRemoteID, amount: 42, date: .now, note: "remote-only", type: .expense,
                recurrence: .none, excludeFromBudget: false, isPlannedExpense: false, isDeleted: false,
                createdAt: .now, updatedAt: .now
            ),
        ]

        let coordinator = makeCoordinator()
        coordinator.scheduleSync(modelContext: context)
        await coordinator.waitForPendingWork()

        let entries = try context.fetch(FetchDescriptor<Entry>())
        let pulled = entries.first { $0.remoteID == entryRemoteID }
        let pulledEntry = try XCTUnwrap(pulled, "the entry must be created, not skipped, once reference data has resolved its wallet/category")
        XCTAssertEqual(pulledEntry.wallet.remoteID, walletRemoteID)
        XCTAssertEqual(pulledEntry.category?.remoteID, categoryRemoteID)
    }

    /// A second trigger landing while a (slow) pull is still in flight must never be dropped
    /// (Phase 4G.1) — it must coalesce into exactly one additional pass after the in-flight one
    /// finishes, the same guarantee `testSecondTriggerWhileASyncIsInFlightIsCoalescedIntoOneExtraPass`
    /// proves for a slow push must hold just as well now that pull runs first.
    @MainActor
    func testSecondTriggerWhileAPullIsInFlightIsCoalescedIntoOneExtraPass() async throws {
        final class SlowDownloaderWrapper: SupabaseReferenceDataDownloading {
            let inner: RecordingDownloader
            let delay: Duration
            /// Flipped the instant `fetchHeadCategories` is *entered*, before the artificial
            /// delay — so a test can detect "the sync has genuinely started" without waiting for
            /// the delay to finish (`inner`'s own `callOrder` isn't recorded until after it).
            private(set) var hasStartedFetching = false

            init(inner: RecordingDownloader, delay: Duration) {
                self.inner = inner
                self.delay = delay
            }
            func fetchHeadCategories(userID: UUID) async throws -> [HeadCategoryDTO] {
                hasStartedFetching = true
                try await Task.sleep(for: delay)
                return try await inner.fetchHeadCategories(userID: userID)
            }
            func fetchCategories(userID: UUID) async throws -> [CategoryDTO] {
                try await inner.fetchCategories(userID: userID)
            }
            func fetchWallets(userID: UUID) async throws -> [WalletDTO] {
                try await inner.fetchWallets(userID: userID)
            }
        }
        let slowDownloader = SlowDownloaderWrapper(inner: downloader, delay: .milliseconds(80))
        syncService = SupabaseSyncService(
            uploader: uploader, downloader: slowDownloader, budgetDownloader: budgetDownloader,
            entryDownloader: entryDownloader, userProvider: userProvider
        )
        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        // Wait for the first pass to actually start (land inside the artificially slow fetch),
        // so the second trigger below genuinely lands mid-sync rather than racing the debounce.
        await waitUntil { slowDownloader.hasStartedFetching }
        coordinator.scheduleSync(modelContext: context)

        await waitUntil { downloader.callOrder.filter { $0 == "pullHeadCategories" }.count >= 2 }

        XCTAssertEqual(downloader.callOrder.filter { $0 == "pullHeadCategories" }.count, 2, "the overlapping trigger must not be dropped — it must run as exactly one additional pass, not zero and not more than one")
    }

    // MARK: - Session gating

    @MainActor
    func testScheduleSyncDoesNothingWithoutAnActiveSession() async throws {
        sessionChecker.hasSession = false
        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(sessionChecker.callCount, 1)
        XCTAssertTrue(uploader.callOrder.isEmpty, "no sync call should be attempted without an active session")
    }

    @MainActor
    func testScheduleSyncProceedsWithAnActiveSession() async throws {
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        try context.save()

        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(sessionChecker.callCount, 1)
        XCTAssertFalse(uploader.callOrder.isEmpty, "a session is active, so the sync should have actually run")
    }

    // MARK: - Debounce / coalescing

    /// Two `scheduleSync` calls landing within the debounce window must collapse into exactly one
    /// eventual sync — the hallmark of coalescing rather than queuing.
    @MainActor
    func testRapidScheduleSyncCallsCoalesceIntoOneSync() async throws {
        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        coordinator.scheduleSync(modelContext: context)
        coordinator.scheduleSync(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(uploader.callOrder.filter { $0 == "headCategoriesBatch" }.count, 1, "three rapid triggers must still produce exactly one sync")
    }

    /// A second `scheduleSync` call arriving after the first sync has already completed must
    /// still schedule (and run) its own sync — coalescing must not suppress a genuinely new,
    /// separate trigger.
    @MainActor
    func testScheduleSyncAfterPreviousSyncCompletedRunsAgain() async throws {
        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        await coordinator.waitForPendingWork()
        XCTAssertEqual(uploader.callOrder.filter { $0 == "headCategoriesBatch" }.count, 1)

        coordinator.scheduleSync(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(uploader.callOrder.filter { $0 == "headCategoriesBatch" }.count, 2)
    }

    // MARK: - isSyncing / reentrancy protection (Phase 3C) and coalescing (Phase 4G.1)

    /// If a trigger's debounce elapses and starts a (slow) sync, a second trigger landing while
    /// that sync is still in flight must never be silently dropped (Phase 4G.1 — this is the exact
    /// root cause the Phase 4G audit found for a new Entry never reaching Supabase) — it must
    /// coalesce into exactly one additional pass, run immediately after the in-flight one finishes.
    @MainActor
    func testSecondTriggerWhileASyncIsInFlightIsCoalescedIntoOneExtraPass() async throws {
        uploader.headCategoriesBatchDelay = .milliseconds(80)
        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        // Wait for the first pass to actually start (land inside the artificially slow upload),
        // so the second call below genuinely lands mid-sync rather than racing the debounce.
        await waitUntil { uploader.hasStartedUploadingHeadCategories }
        coordinator.scheduleSync(modelContext: context)

        await waitUntil { uploader.callOrder.filter { $0 == "headCategoriesBatch" }.count >= 2 }

        XCTAssertEqual(uploader.callOrder.filter { $0 == "headCategoriesBatch" }.count, 2, "the overlapping trigger must not be dropped — it must run as exactly one additional pass, not zero and not more than one")
    }

    /// The exact Phase 4G symptom, reproduced directly: an `Entry` created (and saved) while an
    /// automatic sync is already in flight must still reach `syncEntries` — via the coalesced
    /// extra pass — without the caller needing some unrelated later trigger (another foreground,
    /// another unrelated save) to eventually pick it up.
    @MainActor
    func testEntryCreatedDuringAnActiveSyncIsPushedByTheCoalescedExtraPass() async throws {
        uploader.headCategoriesBatchDelay = .milliseconds(80)
        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        // Wait for the first pass to actually start (land inside the artificially slow upload).
        await waitUntil { uploader.hasStartedUploadingHeadCategories }

        // Simulate a new Entry being created and saved while that first pass is still mid-flight.
        let head = try XCTUnwrap(try context.fetch(FetchDescriptor<HeadCategory>()).first, "the baseline head category from setUp")
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, category: category, wallet: wallet)
        context.insert(entry)
        try context.save()
        coordinator.scheduleSync(modelContext: context)

        await waitUntil { uploader.callOrder.filter { $0 == "headCategoriesBatch" }.count >= 2 }

        XCTAssertEqual(uploader.callOrder.filter { $0 == "headCategoriesBatch" }.count, 2, "the mid-sync trigger must produce exactly one coalesced extra pass")
        XCTAssertNotNil(entry.remoteID, "the entry created mid-sync must be minted and pushed by the coalesced extra pass, not stranded until an unrelated future trigger")
    }

    /// However many triggers land while a sync is in flight, only ever one additional pass runs —
    /// the pending state is a single flag, not a queue, so this can never chain into an unbounded
    /// retry loop.
    @MainActor
    func testManyTriggersDuringAnActiveSyncStillProduceOnlyOneExtraPass() async throws {
        uploader.headCategoriesBatchDelay = .milliseconds(80)
        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        await waitUntil { uploader.hasStartedUploadingHeadCategories }

        for _ in 0..<5 {
            coordinator.scheduleSync(modelContext: context)
        }

        await waitUntil { uploader.callOrder.filter { $0 == "headCategoriesBatch" }.count >= 2 }

        XCTAssertEqual(uploader.callOrder.filter { $0 == "headCategoriesBatch" }.count, 2, "any number of triggers arriving mid-sync must still collapse into exactly one additional pass, never one per trigger")
    }

    /// The debounce itself must still coalesce a rapid burst into one debounce-task firing, even
    /// when nothing is in flight yet — the pending-rerun mechanism above is a separate, additional
    /// guarantee layered on top of this pre-existing one, not a replacement for it.
    @MainActor
    func testDebounceStillCoalescesARapidBurstWithNoSyncYetInFlight() async throws {
        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        coordinator.scheduleSync(modelContext: context)
        coordinator.scheduleSync(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(uploader.callOrder.filter { $0 == "headCategoriesBatch" }.count, 1, "a burst with no sync yet running must still collapse into exactly one pass via the debounce alone")
    }

    // MARK: - Phase 4G.3A

    /// Mirrors exactly what `RootView`'s `.onReceive(NotificationCenter.default.publisher(for:
    /// ModelContext.didSave))` does, scoped to one `ModelContext` so it can't leak across tests —
    /// lets a test observe (and forward into `handleDidSave`, exactly like `RootView` would) the
    /// *real* notification a real `modelContext.save()` call posts, rather than fabricating one.
    /// `MainActor.assumeIsolated` is safe here: the save that posts this notification only ever
    /// happens from `@MainActor` sync code in this test target, same as it does in `RootView`.
    @MainActor
    private func observeDidSave(on observedContext: ModelContext, forwardingTo coordinator: SyncCoordinator) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: observedContext, queue: nil) { notification in
            MainActor.assumeIsolated {
                coordinator.handleDidSave(notification, modelContext: observedContext)
            }
        }
    }

    /// The core Phase 4G.3A requirement: `SupabaseSyncService.requireUserID()` (i.e. the
    /// underlying `currentUserID()` call) must be resolved exactly once per sync pass, not once
    /// per one of the six steps.
    @MainActor
    func testUserIDIsResolvedExactlyOncePerSyncPass() async throws {
        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(userProvider.callCount, 1, "the user id must be resolved once per pass, not once per step")
    }

    /// A sync pass where every step finds nothing to change (steady state: nothing to pull,
    /// nothing needing a freshly-minted remoteID to push) must never call `modelContext.save()` —
    /// observable as zero `ModelContext.didSave` notifications for the whole pass.
    @MainActor
    func testNoOpStepsDoNotSaveOrPostDidSave() async throws {
        let steadyStateContext = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory()
        head.remoteID = UUID()
        steadyStateContext.insert(head)
        try steadyStateContext.save()

        let coordinator = makeCoordinator()
        var didSaveCount = 0
        let token = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: steadyStateContext, queue: nil) { _ in
            didSaveCount += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        coordinator.scheduleSync(modelContext: steadyStateContext)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(didSaveCount, 0, "a fully converged store must produce zero saves across all six steps")
        XCTAssertFalse(uploader.callOrder.isEmpty, "the one already-synced HeadCategory must still be re-uploaded (unchanged push behavior) even though nothing needed saving locally")
    }

    /// The exact Phase 4G.2 finding this phase fixes: a pull step's own `modelContext.save()`
    /// (here, `pullReferenceData` actually inserting a new remote `HeadCategory`) posts a real
    /// `ModelContext.didSave` notification — this must not schedule a redundant extra sync pass.
    /// `sessionChecker.callCount` counts how many `runOneSyncPass` invocations actually ran (one
    /// call to `hasActiveSession()` per pass), so `1` here proves no coalesced extra pass happened.
    @MainActor
    func testPullInducedSaveDoesNotTriggerARedundantExtraSync() async throws {
        let freshContext = TestSupport.makeInMemoryContext()
        downloader.headCategories = [
            HeadCategoryDTO(
                id: UUID(), userID: userProvider.userID!, name: "Pulled", icon: "folder.fill",
                colorHex: "#FFFFFF", sortOrder: 0, createdAt: .now, updatedAt: .now
            ),
        ]
        let coordinator = makeCoordinator()
        let token = observeDidSave(on: freshContext, forwardingTo: coordinator)
        defer { NotificationCenter.default.removeObserver(token) }

        coordinator.scheduleSync(modelContext: freshContext)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(sessionChecker.callCount, 1, "the pull's own save must not have scheduled a second, redundant sync pass")
        XCTAssertEqual(uploader.callOrder.filter { $0 == "headCategoriesBatch" }.count, 1, "the pulled HeadCategory must be pushed back exactly once, by the same pass that pulled it — never twice")
    }

    // MARK: - Phase 4G.3B — local save no longer schedules a sync directly

    /// The core Phase 4G.3B requirement: saving a syncable model must never, by itself, kick off
    /// a network sync. No `scheduleSync`/`ensureSyncRunning` call happens purely from a save —
    /// only `handleAppBecameActive`/`refresh`/the periodic timer actually start one.
    @MainActor
    func testLocalSaveDoesNotTriggerImmediateSync() async throws {
        let coordinator = makeCoordinator()
        let token = observeDidSave(on: context, forwardingTo: coordinator)
        defer { NotificationCenter.default.removeObserver(token) }

        let head = try XCTUnwrap(try context.fetch(FetchDescriptor<HeadCategory>()).first)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)
        try context.save()

        // Long enough that, under the old (Phase 4G.1) behavior, a debounced sync would already
        // have fired by now — nothing here ever calls `scheduleSync`, so there's no debounce
        // task to await; a short real wait is the only way to assert a genuine absence.
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(uploader.callOrder.isEmpty, "a local save alone must never trigger a network sync")
        XCTAssertEqual(sessionChecker.callCount, 0, "no sync pass — not even a skipped one — should have started")
    }

    /// A genuine local save must still be remembered as a pending change, observable via the
    /// *next* real trigger: even with a very fresh `lastSuccessfulSync`, app activation must still
    /// sync if something was saved since then. This is also "pending local changes cause app
    /// activation sync."
    @MainActor
    func testLocalSaveMarksPendingChangesWhichCauseTheNextAppActivationToSync() async throws {
        lastSyncStore.lastSuccessfulSync = .now
        let coordinator = makeCoordinator()
        let token = observeDidSave(on: context, forwardingTo: coordinator)
        defer { NotificationCenter.default.removeObserver(token) }

        let head = try XCTUnwrap(try context.fetch(FetchDescriptor<HeadCategory>()).first)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)
        try context.save()

        coordinator.handleAppBecameActive(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertFalse(uploader.callOrder.isEmpty, "a pending local change must cause app activation to sync even though the last sync is very fresh")
    }

    /// Several local saves in a row must still collapse into a single "there is pending work"
    /// state, not anything that scales with how many saves happened — the very next trigger syncs
    /// everything together in one pass, same as always.
    @MainActor
    func testMultipleLocalSavesRemainOnePendingState() async throws {
        lastSyncStore.lastSuccessfulSync = .now
        let coordinator = makeCoordinator()
        let token = observeDidSave(on: context, forwardingTo: coordinator)
        defer { NotificationCenter.default.removeObserver(token) }

        let head = try XCTUnwrap(try context.fetch(FetchDescriptor<HeadCategory>()).first)
        for index in 0..<5 {
            let category = TestSupport.makeCategory(name: "Category \(index)", headCategory: head)
            context.insert(category)
            try context.save()
        }

        coordinator.handleAppBecameActive(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(sessionChecker.callCount, 1, "five saves in a row must still cause exactly one sync pass, not one per save")
    }

    /// Mirrors `testPullInducedSaveDoesNotTriggerARedundantExtraSync` above, but checks the thing
    /// that actually matters post-4G.3B: a pull step's own save must not even mark pending
    /// changes. Proven by activating again right after the pass completes (`lastSuccessfulSync`
    /// is now very fresh) and confirming nothing re-syncs.
    @MainActor
    func testPullInducedSaveDoesNotMarkPendingChanges() async throws {
        let freshContext = TestSupport.makeInMemoryContext()
        downloader.headCategories = [
            HeadCategoryDTO(
                id: UUID(), userID: userProvider.userID!, name: "Pulled", icon: "folder.fill",
                colorHex: "#FFFFFF", sortOrder: 0, createdAt: .now, updatedAt: .now
            ),
        ]
        let coordinator = makeCoordinator()
        let token = observeDidSave(on: freshContext, forwardingTo: coordinator)
        defer { NotificationCenter.default.removeObserver(token) }

        coordinator.handleAppBecameActive(modelContext: freshContext)
        await coordinator.waitForPendingWork()
        XCTAssertEqual(sessionChecker.callCount, 1, "the first activation should have synced once")

        coordinator.handleAppBecameActive(modelContext: freshContext)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(sessionChecker.callCount, 1, "reactivating right after a fresh sync, with the pull's own save never having marked anything pending, must not sync again")
    }

    // MARK: - Phase 4G.3B — trigger 1: app active / launch

    /// App activation must sync when the last successful sync is older than the freshness window
    /// (here, a stand-in for "10 minutes"), even with nothing pending.
    @MainActor
    func testAppActivationSyncsWhenLastSyncIsOlderThanTheFreshnessWindow() async throws {
        let coordinator = makeCoordinator(periodicSyncInterval: .seconds(600))
        lastSyncStore.lastSuccessfulSync = Date.now.addingTimeInterval(-700)

        coordinator.handleAppBecameActive(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(sessionChecker.callCount, 1, "a stale last-sync timestamp must cause app activation to sync")
    }

    /// App activation must NOT sync when the last successful sync is recent and nothing is
    /// pending — the core "don't sync on every reactivation" requirement.
    @MainActor
    func testAppActivationDoesNotSyncWhenLastSyncIsRecentAndNothingIsPending() async throws {
        let coordinator = makeCoordinator(periodicSyncInterval: .seconds(600))
        lastSyncStore.lastSuccessfulSync = Date.now.addingTimeInterval(-60)

        coordinator.handleAppBecameActive(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(sessionChecker.callCount, 0, "a fresh last-sync timestamp with nothing pending must not sync")
        XCTAssertTrue(uploader.callOrder.isEmpty)
    }

    /// The very first authenticated activation (no `lastSuccessfulSync` on record at all) must
    /// still be able to sync — "never synced" counts as stale, not fresh.
    @MainActor
    func testFirstAuthenticatedActivationSyncsWhenThereIsNoRecordedLastSync() async throws {
        XCTAssertNil(lastSyncStore.lastSuccessfulSync)
        let coordinator = makeCoordinator(periodicSyncInterval: .seconds(600))

        coordinator.handleAppBecameActive(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(sessionChecker.callCount, 1, "an app that has never recorded a successful sync must still sync on its first activation")
    }

    /// Reactivating repeatedly within the freshness window, with nothing pending, must never
    /// cause a second sync — not just the first reactivation.
    @MainActor
    func testAppActivationDoesNotSyncRepeatedlyWithinTheFreshnessWindow() async throws {
        let coordinator = makeCoordinator(periodicSyncInterval: .seconds(600))
        lastSyncStore.lastSuccessfulSync = Date.now.addingTimeInterval(-30)

        coordinator.handleAppBecameActive(modelContext: context)
        await coordinator.waitForPendingWork()
        coordinator.handleAppBecameActive(modelContext: context)
        await coordinator.waitForPendingWork()
        coordinator.handleAppBecameActive(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(sessionChecker.callCount, 0, "repeated reactivation inside the freshness window must never sync")
    }

    // MARK: - Phase 4G.3B — trigger 2: pull-to-refresh

    /// Pull-to-refresh must always request a sync, even with a `lastSuccessfulSync` from a moment
    /// ago and nothing pending — the one trigger with no staleness/pending gate at all.
    @MainActor
    func testPullToRefreshAlwaysRequestsSync() async throws {
        lastSyncStore.lastSuccessfulSync = .now
        let coordinator = makeCoordinator()

        await coordinator.refresh(modelContext: context)

        XCTAssertEqual(sessionChecker.callCount, 1, "pull-to-refresh must sync regardless of how fresh the last sync was")
        XCTAssertFalse(uploader.callOrder.isEmpty)
    }

    /// `refresh(modelContext:)` must not return until the sync it requested has actually
    /// finished — including a slow push step — so a `.refreshable` spinner bound to it never
    /// dismisses early.
    @MainActor
    func testPullToRefreshAwaitsSyncCompletionBeforeReturning() async throws {
        uploader.headCategoriesBatchDelay = .milliseconds(80)
        let coordinator = makeCoordinator()

        await coordinator.refresh(modelContext: context)

        XCTAssertFalse(uploader.callOrder.isEmpty, "by the time refresh() returns, the slow push step must have already completed")
    }

    // MARK: - Phase 4G.3B — trigger 3: periodic sync

    /// While the app is active, a sync must fire again on its own roughly every
    /// `periodicSyncInterval`, with no further trigger needed.
    @MainActor
    func testPeriodicSyncFiresWhileActive() async throws {
        let coordinator = makeCoordinator(periodicSyncInterval: .milliseconds(40))
        lastSyncStore.lastSuccessfulSync = .now // the initial activation itself must not sync

        coordinator.handleAppBecameActive(modelContext: context)
        await coordinator.waitForPendingWork() // nothing pending yet — this should be a no-op

        await waitUntil { sessionChecker.callCount >= 1 }

        XCTAssertGreaterThanOrEqual(sessionChecker.callCount, 1, "the periodic timer must have fired at least once on its own")
    }

    /// The periodic timer must stop ticking once the app goes to the background — no further
    /// sync should fire after that, even if the interval keeps elapsing in real time.
    @MainActor
    func testPeriodicSyncDoesNotFireWhileInactive() async throws {
        let coordinator = makeCoordinator(periodicSyncInterval: .milliseconds(30))
        lastSyncStore.lastSuccessfulSync = .now

        coordinator.handleAppBecameActive(modelContext: context)
        await coordinator.waitForPendingWork()
        coordinator.handleAppDidEnterBackground()

        let countRightAfterBackgrounding = sessionChecker.callCount
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(sessionChecker.callCount, countRightAfterBackgrounding, "no periodic tick must fire once the app is backgrounded")
    }

    // MARK: - Phase 4G.3B — overlapping sync protection

    /// A pull-to-refresh that arrives while a (slow) sync from another trigger is already running
    /// must not start a second, overlapping sync pass — it joins the existing coalescing
    /// protection (Phase 4G.1) exactly like any other mid-sync trigger, and `refresh()` still only
    /// returns once the whole thing (including the coalesced extra pass) is done.
    @MainActor
    func testOverlappingSyncRemainsProtectedAndCoalesced() async throws {
        uploader.headCategoriesBatchDelay = .milliseconds(80)
        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        await waitUntil { uploader.hasStartedUploadingHeadCategories }

        await coordinator.refresh(modelContext: context)

        XCTAssertEqual(uploader.callOrder.filter { $0 == "headCategoriesBatch" }.count, 2, "the overlapping refresh must coalesce into exactly one additional pass, not run concurrently")
    }

    // MARK: - Phase 4G.3B — lastSuccessfulSync bookkeeping

    /// A sync pass that completes all six steps must record the current time as the new
    /// `lastSuccessfulSync`.
    @MainActor
    func testSuccessfulSyncUpdatesLastSuccessfulSync() async throws {
        XCTAssertNil(lastSyncStore.lastSuccessfulSync)
        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        await coordinator.waitForPendingWork()

        let recorded = try XCTUnwrap(lastSyncStore.lastSuccessfulSync)
        XCTAssertLessThan(abs(recorded.timeIntervalSinceNow), 5, "lastSuccessfulSync must be set to (approximately) now")
    }

    /// A sync pass that fails partway through must leave `lastSuccessfulSync` exactly as it was
    /// — a failed sync was not successful, and must not be mistaken for one later.
    @MainActor
    func testFailedSyncDoesNotUpdateLastSuccessfulSync() async throws {
        struct PullFailure: Error {}
        downloader.errorToThrow = PullFailure()
        let staleDate = Date.now.addingTimeInterval(-3_000)
        lastSyncStore.lastSuccessfulSync = staleDate
        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(lastSyncStore.lastSuccessfulSync, staleDate, "a failed sync must never update lastSuccessfulSync")
    }

    // MARK: - Phase 4G.6 — handleCrossProcessChange suppression during a pull

    /// Mirrors `testPullInducedSaveDoesNotMarkPendingChanges`, but for the other notification path
    /// `RootView` wires to `SyncCoordinator`: a pull step's own `modelContext.save()` can also post
    /// `NSPersistentStoreRemoteChangeNotification` (persistent history tracking notifies every
    /// observer of a committed change, not only a genuinely different process), which `RootView`
    /// forwards to `handleCrossProcessChange()`. Before this fix, that call happening while a pull
    /// is mid-flight would mark `hasPendingLocalChanges = true` immediately after the pass that
    /// pull belongs to clears it — this proves it no longer does, the same way the didSave test
    /// does: reactivate right after a fresh sync and confirm nothing re-syncs.
    @MainActor
    func testPullInducedCrossProcessChangeDoesNotMarkPendingChanges() async throws {
        downloader.headCategoriesDelay = .milliseconds(60)
        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        await waitUntil { downloader.hasStartedFetchingHeadCategories }
        // Simulates the remote-change notification landing while this pass's own pull is still
        // mid-flight (isApplyingPullChanges is true for the duration of pullReferenceData).
        coordinator.handleCrossProcessChange()
        // `waitForPendingWork()` only awaits the *debounce* task, which may already have fired
        // and nilled itself out by the time the `waitUntil` above returns (the debounce elapses
        // well before the artificially delayed pull does) — it would return immediately here,
        // before the pass has actually finished. Waiting on `lastSuccessfulSync` instead proves
        // the full six-step pass genuinely completed before this test proceeds.
        await waitUntil { lastSyncStore.lastSuccessfulSync != nil }
        XCTAssertEqual(sessionChecker.callCount, 1, "the first scheduled sync should have run once")

        coordinator.handleAppBecameActive(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(sessionChecker.callCount, 1, "a cross-process notification caused by this sync's own pull must not have marked anything pending — reactivating right after must not sync again")
    }

    /// The flip side: a cross-process change that genuinely happens *outside* any sync pass (no
    /// pull in flight) must still mark pending local changes, exactly as it always has — the
    /// suppression above must be scoped to the pull window, never a blanket no-op.
    @MainActor
    func testGenuineCrossProcessChangeOutsideSyncStillMarksPending() async throws {
        lastSyncStore.lastSuccessfulSync = .now
        let coordinator = makeCoordinator()

        // No sync in flight at all — isApplyingPullChanges is false here.
        coordinator.handleCrossProcessChange()

        coordinator.handleAppBecameActive(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertFalse(uploader.callOrder.isEmpty, "a genuine cross-process change must still cause the next app activation to sync, even with a very fresh last-sync timestamp")
    }

    // MARK: - Phase 4G.6 — Budget reconciliation lets the coordinator reach syncEntries

    /// The end-to-end regression test for the production failure: before this fix, two local
    /// `Budget`s sharing the same natural key (`Category` + month + year, one already synced, one
    /// not) made `syncBudgets` mint a second, conflicting `remoteID` and throw — aborting the pass
    /// before `syncEntries` ever ran. Now `syncBudgets` reconciles them into one upload and the
    /// pass continues all the way through to `syncEntries`.
    @MainActor
    func testBudgetReconciliationAllowsCoordinatorToReachSyncEntries() async throws {
        let head = try XCTUnwrap(try context.fetch(FetchDescriptor<HeadCategory>()).first)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)

        let alreadySynced = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 5, year: 2026)
        alreadySynced.remoteID = UUID()
        context.insert(alreadySynced)
        let neverSynced = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 5, year: 2026)
        context.insert(neverSynced)

        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, category: category, wallet: wallet)
        context.insert(entry)
        try context.save()

        let coordinator = makeCoordinator()

        coordinator.scheduleSync(modelContext: context)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(uploader.callOrder.filter { $0 == "budgetsBatch" }.count, 1, "syncBudgets must have succeeded exactly once, not thrown")
        XCTAssertEqual(uploader.callOrder.filter { $0 == "entriesBatch" }.count, 1, "syncEntries must have been reached and run after syncBudgets succeeded")
        XCTAssertEqual(uploader.callOrder.last, "entriesBatch", "entries is still the last of the six steps")
        XCTAssertNotNil(entry.remoteID, "the entry must have actually been minted and pushed, proving syncEntries truly ran, not just that onProgress fired")
    }

    // MARK: - Phase 6.1 — the signal AccountView checks before a destructive sign-out

    /// `AccountView.signOut()` always tries `refresh(modelContext:)` first, then checks
    /// `hasPendingLocalChanges` to decide whether it's safe to proceed silently. This is the
    /// success half: a flush that actually completes must clear it, so sign-out doesn't warn
    /// unnecessarily.
    @MainActor
    func testPendingChangesClearAfterASuccessfulFlush() async throws {
        let coordinator = makeCoordinator()
        let token = observeDidSave(on: context, forwardingTo: coordinator)
        defer { NotificationCenter.default.removeObserver(token) }

        let head = try XCTUnwrap(try context.fetch(FetchDescriptor<HeadCategory>()).first)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)
        try context.save()
        XCTAssertTrue(coordinator.hasPendingLocalChanges, "setup: the save above must have marked pending changes")

        await coordinator.refresh(modelContext: context)

        XCTAssertFalse(coordinator.hasPendingLocalChanges, "a successful flush must clear pending changes, so sign-out can proceed without a warning")
    }

    /// The failure half, and the one that actually protects against data loss: a flush attempt
    /// that fails (offline, server error, etc.) must leave pending changes exactly as they were —
    /// never silently cleared — so `AccountView` knows to warn before discarding them.
    @MainActor
    func testPendingChangesRemainAfterAFailedFlushAttempt() async throws {
        struct PullFailure: Error {}
        downloader.errorToThrow = PullFailure()
        let coordinator = makeCoordinator()
        let token = observeDidSave(on: context, forwardingTo: coordinator)
        defer { NotificationCenter.default.removeObserver(token) }

        let head = try XCTUnwrap(try context.fetch(FetchDescriptor<HeadCategory>()).first)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)
        try context.save()
        XCTAssertTrue(coordinator.hasPendingLocalChanges, "setup: the save above must have marked pending changes")

        await coordinator.refresh(modelContext: context)

        XCTAssertTrue(coordinator.hasPendingLocalChanges, "a sync attempt that fails must leave pending changes exactly as they were — never silently discarded")
    }
}
