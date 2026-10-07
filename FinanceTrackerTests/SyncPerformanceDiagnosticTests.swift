import XCTest
import SwiftData
@testable import FinanceTracker

/// Phase 4G.2 — read-only investigation aid, not a permanent regression suite. Measures the
/// *local* (SwiftData fetch/save/map) cost of one full six-step sync pass in isolation from
/// network latency, using instant (zero-delay) mock uploaders/downloaders on realistic row counts
/// (44 HeadCategories / 291 Categories, matching the real device snapshot from the Phase 4G
/// duplicate-category audit, plus plausible Budget/Entry counts for a store that's been in use for
/// a while). This answers one specific question the audit needed a real number for: "of the
/// reported 1–3s per-action lag, how much is local SwiftData work the Phase 4G.1 batching already
/// addressed, versus how much is inherent to doing up to 9 sequential network round trips on
/// MainActor?" No assertions here beyond "it completes" — this is a measurement tool, not a
/// correctness test, and intentionally does not belong in the app target.
private final class InstantUploader: SupabaseReferenceDataUploading {
    func upsertHeadCategory(_ dto: HeadCategoryDTO) async throws {}
    func upsertCategory(_ dto: CategoryDTO) async throws {}
    func upsertWallet(_ dto: WalletDTO) async throws {}
    func upsertHeadCategories(_ dtos: [HeadCategoryDTO]) async throws {}
    func upsertCategories(_ dtos: [CategoryDTO]) async throws {}
    func upsertWallets(_ dtos: [WalletDTO]) async throws {}
    func upsertBudgets(_ dtos: [BudgetDTO]) async throws {}
    func upsertEntries(_ dtos: [EntryDTO]) async throws {}
}

private final class InstantReferenceDownloader: SupabaseReferenceDataDownloading {
    func fetchHeadCategories(userID: UUID) async throws -> [HeadCategoryDTO] { [] }
    func fetchCategories(userID: UUID) async throws -> [CategoryDTO] { [] }
    func fetchWallets(userID: UUID) async throws -> [WalletDTO] { [] }
}

private final class InstantBudgetDownloader: SupabaseBudgetDownloading {
    func fetchBudgets(userID: UUID) async throws -> [BudgetDTO] { [] }
}

private final class InstantEntryDownloader: SupabaseEntryDownloading {
    func fetchEntries(userID: UUID) async throws -> [EntryDTO] { [] }
}

private final class InstantUserProvider: SupabaseSyncUserProviding {
    var userID: UUID?
    func currentUserID() async throws -> UUID? { userID }
}

final class SyncPerformanceDiagnosticTests: XCTestCase {

    @MainActor
    private func makeSeededContext(headCount: Int, categoriesPerHead: Int, entryCount: Int, budgetCount: Int, mintRemoteIDs: Bool) throws -> ModelContext {
        let context = TestSupport.makeInMemoryContext()
        let userID = UUID()
        var categories: [FinanceTracker.Category] = []
        for h in 0..<headCount {
            let head = TestSupport.makeHeadCategory(name: "Head \(h)")
            if mintRemoteIDs { head.remoteID = UUID() }
            context.insert(head)
            for c in 0..<categoriesPerHead {
                let category = TestSupport.makeCategory(name: "Category \(h)-\(c)", headCategory: head)
                if mintRemoteIDs { category.remoteID = UUID() }
                context.insert(category)
                categories.append(category)
            }
        }
        let wallet = TestSupport.makeWallet(name: "Spending")
        if mintRemoteIDs { wallet.remoteID = UUID() }
        context.insert(wallet)

        for b in 0..<budgetCount {
            let budget = TestSupport.makeBudget(category: categories[b % categories.count], monthlyLimit: 100, month: (b % 12) + 1, year: 2026)
            if mintRemoteIDs { budget.remoteID = UUID() }
            context.insert(budget)
        }
        for e in 0..<entryCount {
            let entry = TestSupport.makeEntry(amount: Decimal(e), date: .now, type: .expense, category: categories[e % categories.count], wallet: wallet)
            if mintRemoteIDs { entry.remoteID = UUID() }
            context.insert(entry)
        }
        try context.save()
        _ = userID
        return context
    }

    @MainActor
    private func makeService() -> (SupabaseSyncService, InstantUserProvider) {
        let userProvider = InstantUserProvider()
        userProvider.userID = UUID()
        let service = SupabaseSyncService(
            uploader: InstantUploader(), downloader: InstantReferenceDownloader(),
            budgetDownloader: InstantBudgetDownloader(), entryDownloader: InstantEntryDownloader(),
            userProvider: userProvider
        )
        return (service, userProvider)
    }

    /// Steady state — every row already has a `remoteID` (the common case: a sync that runs after
    /// the store has already been fully synced once). This is what runs on *every* automatic sync
    /// trigger in ordinary day-to-day use, including the one scheduled after nearly every save.
    @MainActor
    func testMeasureSteadyStateSixStepPass() async throws {
        let context = try makeSeededContext(headCount: 11, categoriesPerHead: 27, entryCount: 1000, budgetCount: 50, mintRemoteIDs: true)
        let (service, _) = makeService()

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await service.pullReferenceData(modelContext: context)
            try await service.pullBudgets(modelContext: context)
            try await service.pullEntries(modelContext: context)
            try await service.syncReferenceData(modelContext: context)
            try await service.syncBudgets(modelContext: context)
            try await service.syncEntries(modelContext: context)
        }
        print("[PERF] Steady-state six-step pass (44 heads×... ~297 categories, 1000 entries, 50 budgets, no minting needed): \(elapsed)")
    }

    /// Worst case — nothing has a `remoteID` yet (first sync after a restore/clean install, or
    /// right after the Phase 4D "database cleaned/restored from backup" scenario). Every row needs
    /// `ensureRemoteID` to mint one, exercising the batched-save path end to end.
    @MainActor
    func testMeasureFirstSyncSixStepPassWithNothingPreviouslySynced() async throws {
        let context = try makeSeededContext(headCount: 11, categoriesPerHead: 27, entryCount: 1000, budgetCount: 50, mintRemoteIDs: false)
        let (service, _) = makeService()

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await service.pullReferenceData(modelContext: context)
            try await service.pullBudgets(modelContext: context)
            try await service.pullEntries(modelContext: context)
            try await service.syncReferenceData(modelContext: context)
            try await service.syncBudgets(modelContext: context)
            try await service.syncEntries(modelContext: context)
        }
        print("[PERF] First-sync six-step pass (nothing previously synced, same row counts): \(elapsed)")
    }

    /// Isolates just the per-step local cost (no network) in the steady state, so it's clear which
    /// of the six steps dominates the local-only budget.
    @MainActor
    func testMeasureEachStepIndividuallySteadyState() async throws {
        let context = try makeSeededContext(headCount: 11, categoriesPerHead: 27, entryCount: 1000, budgetCount: 50, mintRemoteIDs: true)
        let (service, _) = makeService()
        let clock = ContinuousClock()

        let pullRef = try await clock.measure { try await service.pullReferenceData(modelContext: context) }
        let pullBudg = try await clock.measure { try await service.pullBudgets(modelContext: context) }
        let pullEntr = try await clock.measure { try await service.pullEntries(modelContext: context) }
        let syncRef = try await clock.measure { try await service.syncReferenceData(modelContext: context) }
        let syncBudg = try await clock.measure { try await service.syncBudgets(modelContext: context) }
        let syncEntr = try await clock.measure { try await service.syncEntries(modelContext: context) }

        print("[PERF] pullReferenceData: \(pullRef)")
        print("[PERF] pullBudgets:       \(pullBudg)")
        print("[PERF] pullEntries:       \(pullEntr)")
        print("[PERF] syncReferenceData: \(syncRef)")
        print("[PERF] syncBudgets:       \(syncBudg)")
        print("[PERF] syncEntries:       \(syncEntr)")
    }

    /// Isolates whether `syncEntries`'s cost scales with entry count (consistent with per-row
    /// work — including `EntrySyncDiagnosticLog`'s unconditional-in-DEBUG per-entry `print`/
    /// `Logger` calls, Phase 3B-4) or is dominated by fixed overhead. Two row counts 5x apart;
    /// roughly-5x-apart timings would confirm per-row cost dominates in a DEBUG/Xcode-console
    /// build specifically (this diagnostic log is fully compiled out in Release, Phase 4G.1).
    @MainActor
    func testMeasureSyncEntriesScalingWithEntryCount() async throws {
        let (service, _) = makeService()
        let clock = ContinuousClock()

        let smallContext = try makeSeededContext(headCount: 11, categoriesPerHead: 27, entryCount: 200, budgetCount: 0, mintRemoteIDs: true)
        let smallElapsed = try await clock.measure { try await service.syncEntries(modelContext: smallContext) }

        let largeContext = try makeSeededContext(headCount: 11, categoriesPerHead: 27, entryCount: 1000, budgetCount: 0, mintRemoteIDs: true)
        let largeElapsed = try await clock.measure { try await service.syncEntries(modelContext: largeContext) }

        print("[PERF] syncEntries @ 200 entries:  \(smallElapsed)")
        print("[PERF] syncEntries @ 1000 entries: \(largeElapsed)")
    }

    /// `RootView`'s `scenePhase == .active` handler calls `modelContext.rollback()`
    /// unconditionally, before ever touching `SyncCoordinator` — this measures that call alone,
    /// in isolation, on a realistically-sized store, since it's a candidate for "cold launch and
    /// first interaction" sluggishness that has nothing to do with the network sync chain at all.
    @MainActor
    func testMeasureModelContextRollbackOnARealisticStore() async throws {
        let context = try makeSeededContext(headCount: 11, categoriesPerHead: 27, entryCount: 1000, budgetCount: 50, mintRemoteIDs: true)
        let clock = ContinuousClock()

        let elapsed = clock.measure {
            context.rollback()
        }
        print("[PERF] modelContext.rollback() on ~297 categories / 1000 entries / 50 budgets: \(elapsed)")
    }
}
