import XCTest
import SwiftData
@testable import FinanceTracker

/// Phase 3B-2: covers `EntryDTO`'s mapping/validation and `SupabaseSyncService.syncEntries`. A
/// separate file from `SupabaseSyncServiceTests` (reference-data sync) rather than extending it,
/// with its own small mock uploader — keeps each phase's tests self-contained and focused, per
/// this phase's "focused tests" instruction. No network connection is used anywhere here.
private final class MockEntryUploader: SupabaseReferenceDataUploading {
    private(set) var headCategoryUploads: [HeadCategoryDTO] = []
    private(set) var categoryUploads: [CategoryDTO] = []
    private(set) var walletUploads: [WalletDTO] = []
    private(set) var headCategoryBatches: [[HeadCategoryDTO]] = []
    private(set) var categoryBatches: [[CategoryDTO]] = []
    private(set) var walletBatches: [[WalletDTO]] = []

    /// One entry per `upsertEntries` call — used to assert the batch call count (exactly one per
    /// `syncEntries` run) and each call's full DTO payload.
    private(set) var entryBatches: [[EntryDTO]] = []

    /// Lets the orchestration tests simulate `syncReferenceData` failing partway, to confirm
    /// `syncEntries` is never reached afterward — mirrors `SupabaseSyncServiceTests`'s equivalent
    /// failure-injection fields.
    var headCategoriesBatchError: Error?

    func upsertHeadCategory(_ dto: HeadCategoryDTO) async throws { headCategoryUploads.append(dto) }
    func upsertCategory(_ dto: CategoryDTO) async throws { categoryUploads.append(dto) }
    func upsertWallet(_ dto: WalletDTO) async throws { walletUploads.append(dto) }

    func upsertHeadCategories(_ dtos: [HeadCategoryDTO]) async throws {
        if let error = headCategoriesBatchError { throw error }
        headCategoryBatches.append(dtos)
    }

    func upsertCategories(_ dtos: [CategoryDTO]) async throws { categoryBatches.append(dtos) }
    func upsertWallets(_ dtos: [WalletDTO]) async throws { walletBatches.append(dtos) }

    func upsertEntries(_ dtos: [EntryDTO]) async throws {
        entryBatches.append(dtos)
    }

    /// Budget sync (Phase 3C) isn't exercised by this file's tests (see `BudgetSyncTests.swift`
    /// instead) — required only to satisfy `SupabaseReferenceDataUploading` conformance.
    func upsertBudgets(_ dtos: [BudgetDTO]) async throws {}
}

private struct StubError: Error, Equatable {}

private final class MockEntrySyncUserProvider: SupabaseSyncUserProviding {
    var userID: UUID?
    func currentUserID() async throws -> UUID? { userID }
}

final class EntrySyncTests: XCTestCase {
    private var uploader: MockEntryUploader!
    private var userProvider: MockEntrySyncUserProvider!
    private var service: SupabaseSyncService!
    private var context: ModelContext!
    private let userID = UUID()

    @MainActor
    override func setUp() {
        super.setUp()
        uploader = MockEntryUploader()
        userProvider = MockEntrySyncUserProvider()
        userProvider.userID = userID
        service = SupabaseSyncService(uploader: uploader, userProvider: userProvider)
        context = TestSupport.makeInMemoryContext()
    }

    // MARK: - A. EntryDTO encoding

    func testEntryDTOMappingPreservesAllFields() throws {
        let wallet = TestSupport.makeWallet(name: "Spending")
        wallet.remoteID = UUID()
        let head = TestSupport.makeHeadCategory()
        head.remoteID = UUID()
        let category = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        category.remoteID = UUID()
        let destination = TestSupport.makeWallet(name: "Savings")
        destination.remoteID = UUID()

        let entry = TestSupport.makeEntry(
            amount: 42.50, date: Date(timeIntervalSince1970: 1_700_000_000), type: .expense,
            category: category, wallet: wallet, destinationWallet: destination,
            recurrence: .monthly, excludeFromBudget: true, isPlannedExpense: true
        )
        entry.remoteID = UUID()
        entry.isSoftDeleted = false

        let dto = try EntryDTO(entry: entry, userID: userID)

        XCTAssertEqual(dto.id, entry.remoteID)
        XCTAssertEqual(dto.userID, userID)
        XCTAssertEqual(dto.walletID, wallet.remoteID)
        XCTAssertEqual(dto.destinationWalletID, destination.remoteID)
        XCTAssertEqual(dto.categoryID, category.remoteID)
        XCTAssertEqual(dto.amount, 42.50)
        XCTAssertEqual(dto.date, entry.date)
        XCTAssertEqual(dto.note, entry.note)
        XCTAssertEqual(dto.type, .expense)
        XCTAssertEqual(dto.recurrence, .monthly)
        XCTAssertEqual(dto.excludeFromBudget, true)
        XCTAssertEqual(dto.isPlannedExpense, true)
        XCTAssertEqual(dto.isDeleted, false)
        XCTAssertEqual(dto.createdAt, entry.createdAt)
        XCTAssertEqual(dto.updatedAt, entry.updatedAt)
    }

    /// `is_deleted` is the one field whose wire name diverges from its source property
    /// (`Entry.isSoftDeleted`) — see `EntryDTO`'s own doc comment for why. Checked on its own
    /// since it's the easiest of the fourteen mapped fields to silently get backwards.
    func testEntryDTOIsDeletedMapsFromEntryIsSoftDeleted() throws {
        let wallet = TestSupport.makeWallet()
        wallet.remoteID = UUID()
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)
        entry.remoteID = UUID()
        entry.isSoftDeleted = true

        let dto = try EntryDTO(entry: entry, userID: userID)

        XCTAssertTrue(dto.isDeleted)
    }

    /// Confirms the `CodingKeys` actually produce the `snake_case` column names the Postgres
    /// `entries` schema expects — a mismatched key here would silently fail an upsert. Encoded as
    /// a `[EntryDTO]` array (the batch wire shape `syncEntries` always sends), matching how the
    /// reference-data DTOs' equivalent tests already verify the array-encoding path.
    func testEntryDTOBatchEncodesExpectedSnakeCaseKeys() throws {
        let wallet = TestSupport.makeWallet()
        wallet.remoteID = UUID()
        let destination = TestSupport.makeWallet(name: "Savings")
        destination.remoteID = UUID()
        let head = TestSupport.makeHeadCategory()
        head.remoteID = UUID()
        let category = TestSupport.makeCategory(headCategory: head)
        category.remoteID = UUID()
        let entry = TestSupport.makeEntry(
            amount: 10, date: .now, type: .income, category: category, wallet: wallet,
            destinationWallet: destination, recurrence: .weekly
        )
        entry.remoteID = UUID()

        let dto = try EntryDTO(entry: entry, userID: userID)
        let data = try JSONEncoder().encode([dto])
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]]).first!

        for key in [
            "id", "user_id", "wallet_id", "destination_wallet_id", "category_id", "amount", "date",
            "note", "type", "recurrence", "exclude_from_budget", "is_planned_expense", "is_deleted",
            "created_at", "updated_at",
        ] {
            XCTAssertNotNil(json[key], "missing expected column key: \(key)")
        }
        XCTAssertEqual(json["type"] as? String, "income")
        XCTAssertEqual(json["recurrence"] as? String, "weekly")
    }

    // MARK: - B. Optional relationships

    func testEntryDTONilDestinationWalletProducesNilDestinationWalletID() throws {
        let wallet = TestSupport.makeWallet()
        wallet.remoteID = UUID()
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)
        entry.remoteID = UUID()

        let dto = try EntryDTO(entry: entry, userID: userID)

        XCTAssertNil(dto.destinationWalletID)
    }

    func testEntryDTONilCategoryProducesNilCategoryID() throws {
        let wallet = TestSupport.makeWallet()
        wallet.remoteID = UUID()
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, category: nil, wallet: wallet)
        entry.remoteID = UUID()

        let dto = try EntryDTO(entry: entry, userID: userID)

        XCTAssertNil(dto.categoryID)
    }

    // MARK: - C. Validation

    func testEntryDTOThrowsWhenEntryRemoteIDMissing() throws {
        let wallet = TestSupport.makeWallet()
        wallet.remoteID = UUID()
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)
        // entry.remoteID left nil

        XCTAssertThrowsError(try EntryDTO(entry: entry, userID: userID)) { error in
            XCTAssertEqual(error as? EntryDTOMappingError, .missingEntryRemoteID)
        }
    }

    func testEntryDTOThrowsWhenWalletRemoteIDMissing() throws {
        let wallet = TestSupport.makeWallet()
        // wallet.remoteID left nil
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)
        entry.remoteID = UUID()

        XCTAssertThrowsError(try EntryDTO(entry: entry, userID: userID)) { error in
            XCTAssertEqual(error as? EntryDTOMappingError, .missingWalletRemoteID)
        }
    }

    func testEntryDTOThrowsWhenDestinationWalletRemoteIDMissing() throws {
        let wallet = TestSupport.makeWallet()
        wallet.remoteID = UUID()
        let destination = TestSupport.makeWallet(name: "Savings")
        // destination.remoteID left nil
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .transfer, wallet: wallet, destinationWallet: destination)
        entry.remoteID = UUID()

        XCTAssertThrowsError(try EntryDTO(entry: entry, userID: userID)) { error in
            XCTAssertEqual(error as? EntryDTOMappingError, .missingDestinationWalletRemoteID)
        }
    }

    func testEntryDTOThrowsWhenCategoryRemoteIDMissing() throws {
        let wallet = TestSupport.makeWallet()
        wallet.remoteID = UUID()
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(headCategory: head)
        // category.remoteID left nil
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, category: category, wallet: wallet)
        entry.remoteID = UUID()

        XCTAssertThrowsError(try EntryDTO(entry: entry, userID: userID)) { error in
            XCTAssertEqual(error as? EntryDTOMappingError, .missingCategoryRemoteID)
        }
    }

    // MARK: - D. Batch uploader

    /// The uploader must send every entry in exactly one `upsertEntries` call — never one call per
    /// entry — regardless of how many local entries exist.
    @MainActor
    func testUploaderSendsEntriesAsOneBatchNotOnePerEntry() async throws {
        let wallet = TestSupport.makeWallet()
        wallet.remoteID = UUID()
        context.insert(wallet)
        let entries = (0..<5).map { TestSupport.makeEntry(amount: Decimal($0 + 1), date: .now, type: .expense, wallet: wallet) }
        entries.forEach(context.insert)
        try context.save()

        try await service.syncEntries(modelContext: context)

        XCTAssertEqual(uploader.entryBatches.count, 1, "exactly one upsertEntries call regardless of row count")
        XCTAssertEqual(uploader.entryBatches.first?.count, 5)
    }

    // MARK: - E. Entry sync

    @MainActor
    func testSyncEntriesWithNoSessionThrowsBeforeUploadingAnything() async throws {
        userProvider.userID = nil
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)
        context.insert(entry)
        try context.save()

        do {
            try await service.syncEntries(modelContext: context)
            XCTFail("expected notAuthenticated to be thrown")
        } catch SupabaseSyncError.notAuthenticated {
            // expected
        }
        XCTAssertTrue(uploader.entryBatches.isEmpty)
    }

    @MainActor
    func testSyncEntriesMintsRemoteIDWhenMissing() async throws {
        let wallet = TestSupport.makeWallet()
        wallet.remoteID = UUID()
        context.insert(wallet)
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)
        context.insert(entry)
        try context.save()
        XCTAssertNil(entry.remoteID)

        try await service.syncEntries(modelContext: context)

        XCTAssertNotNil(entry.remoteID)
    }

    @MainActor
    func testSyncEntriesReusesExistingRemoteID() async throws {
        let wallet = TestSupport.makeWallet()
        wallet.remoteID = UUID()
        context.insert(wallet)
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)
        let existingID = UUID()
        entry.remoteID = existingID
        context.insert(entry)
        try context.save()

        try await service.syncEntries(modelContext: context)

        XCTAssertEqual(entry.remoteID, existingID)
        XCTAssertEqual(uploader.entryBatches.first?.first?.id, existingID)
    }

    /// The newly-minted `remoteID` must be saved to the local store, not just held in memory — a
    /// crash or process death right after `syncEntries` returns must not lose the identity and
    /// cause a duplicate row on the next sync.
    @MainActor
    func testSyncEntriesPersistsNewlyMintedRemoteIDLocally() async throws {
        let wallet = TestSupport.makeWallet()
        wallet.remoteID = UUID()
        context.insert(wallet)
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)
        context.insert(entry)
        try context.save()

        try await service.syncEntries(modelContext: context)
        let mintedID = try XCTUnwrap(entry.remoteID)

        let refetched = try XCTUnwrap(try context.fetch(FetchDescriptor<Entry>()).first)
        XCTAssertEqual(refetched.remoteID, mintedID, "the minted remoteID must have actually been saved, not just held in memory")
    }

    /// The core Phase 3B-2 requirement: a soft-deleted entry is not filtered out of the sync
    /// input — it uploads in the same single batch as every other entry, with `is_deleted = true`.
    @MainActor
    func testSyncEntriesIncludesSoftDeletedEntries() async throws {
        let wallet = TestSupport.makeWallet()
        wallet.remoteID = UUID()
        context.insert(wallet)
        let kept = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)
        let deleted = TestSupport.makeEntry(amount: 20, date: .now, type: .expense, wallet: wallet)
        context.insert(kept)
        context.insert(deleted)
        deleted.isSoftDeleted = true
        try context.save()

        try await service.syncEntries(modelContext: context)

        let batch = try XCTUnwrap(uploader.entryBatches.first)
        XCTAssertEqual(batch.count, 2, "the soft-deleted entry must still be included in the batch")
        let keptDTO = try XCTUnwrap(batch.first { $0.id == kept.remoteID })
        let deletedDTO = try XCTUnwrap(batch.first { $0.id == deleted.remoteID })
        XCTAssertFalse(keptDTO.isDeleted)
        XCTAssertTrue(deletedDTO.isDeleted)
    }

    /// Mirrors `syncReferenceData`'s existing "nothing to upload" behavior — an empty local store
    /// sends no request at all.
    @MainActor
    func testSyncEntriesWithNoLocalEntriesPerformsNoUploadCall() async throws {
        try await service.syncEntries(modelContext: context)

        XCTAssertTrue(uploader.entryBatches.isEmpty)
    }

    /// Re-running `syncEntries` must never mint a second identity or send a second distinct row —
    /// it just re-sends the same batch, idempotently.
    @MainActor
    func testSyncEntriesIsSafeToRunRepeatedly() async throws {
        let wallet = TestSupport.makeWallet()
        wallet.remoteID = UUID()
        context.insert(wallet)
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)
        context.insert(entry)
        try context.save()

        try await service.syncEntries(modelContext: context)
        let idAfterFirst = entry.remoteID

        try await service.syncEntries(modelContext: context)

        XCTAssertEqual(entry.remoteID, idAfterFirst)
        XCTAssertEqual(uploader.entryBatches.count, 2)
        XCTAssertEqual(uploader.entryBatches[0].map(\.id), uploader.entryBatches[1].map(\.id))
    }

    // MARK: - E2. Phase 4G.1 — batched ensureRemoteID saves are still durable

    /// `syncEntries` now mints every missing `Entry` remoteID without saving, then commits once
    /// at the end rather than once per entry. `testSyncEntriesPersistsNewlyMintedRemoteIDLocally`
    /// above re-fetches from the *same* context, which can't distinguish "actually saved" from
    /// "still only an in-memory mutation this context happens to see" — this one reads back from
    /// a second, independent `ModelContext` on the same underlying store, which only ever sees
    /// what was actually committed.
    @MainActor
    func testSyncEntriesPersistsMintedRemoteIDImmediatelyAcrossAFreshContext() async throws {
        let container = TestSupport.makeInMemoryContainer()
        let writingContext = ModelContext(container)
        let wallet = TestSupport.makeWallet()
        wallet.remoteID = UUID()
        writingContext.insert(wallet)
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)
        writingContext.insert(entry)
        try writingContext.save()

        try await service.syncEntries(modelContext: writingContext)
        let mintedID = try XCTUnwrap(entry.remoteID)

        let freshContext = ModelContext(container)
        let freshEntry = try XCTUnwrap(try freshContext.fetch(FetchDescriptor<Entry>()).first)
        XCTAssertEqual(freshEntry.remoteID, mintedID, "a fresh context on the same store must already see the minted Entry remoteID")
    }

    /// Repeated-sync idempotency from a second, independent context on the same store.
    @MainActor
    func testSyncEntriesDoesNotRemintOnASecondRunFromAFreshContext() async throws {
        let container = TestSupport.makeInMemoryContainer()
        let firstContext = ModelContext(container)
        let wallet = TestSupport.makeWallet()
        wallet.remoteID = UUID()
        firstContext.insert(wallet)
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)
        firstContext.insert(entry)
        try firstContext.save()

        try await service.syncEntries(modelContext: firstContext)
        let mintedID = try XCTUnwrap(entry.remoteID)

        let secondContext = ModelContext(container)
        try await service.syncEntries(modelContext: secondContext)

        let entryFromSecondContext = try XCTUnwrap(try secondContext.fetch(FetchDescriptor<Entry>()).first)
        XCTAssertEqual(entryFromSecondContext.remoteID, mintedID, "a second run against a fresh context on the same store must reuse the already-minted remoteID")
        XCTAssertEqual(uploader.entryBatches.count, 2)
        XCTAssertEqual(uploader.entryBatches[0].map(\.id), uploader.entryBatches[1].map(\.id))
    }

    // MARK: - F. Phase 4G.5 — one unmappable Entry must not block the rest of the batch

    /// The core 4G.5 regression test: before this fix, a single `Entry` whose `wallet` lacks a
    /// `remoteID` made the whole `entries.map` throw, so `upsertEntries` was never called at
    /// all — not even for the other, perfectly valid `Entry`. Now the invalid one is skipped and
    /// the valid one still uploads, in the same single batch call.
    @MainActor
    func testOneInvalidEntryDoesNotBlockAValidEntryFromUploading() async throws {
        let syncedWallet = TestSupport.makeWallet(name: "Spending")
        syncedWallet.remoteID = UUID()
        context.insert(syncedWallet)
        let unsyncedWallet = TestSupport.makeWallet(name: "Orphaned")
        // unsyncedWallet.remoteID left nil — makes any Entry using it unmappable.
        context.insert(unsyncedWallet)

        let validEntry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: syncedWallet)
        let invalidEntry = TestSupport.makeEntry(amount: 20, date: .now, type: .expense, wallet: unsyncedWallet)
        context.insert(validEntry)
        context.insert(invalidEntry)
        try context.save()

        try await service.syncEntries(modelContext: context)

        let batch = try XCTUnwrap(uploader.entryBatches.first)
        XCTAssertEqual(uploader.entryBatches.count, 1, "still exactly one upsertEntries call")
        XCTAssertEqual(batch.count, 1, "only the valid entry should be in the uploaded batch")
        XCTAssertEqual(batch.first?.id, validEntry.remoteID)
        XCTAssertNil(invalidEntry.remoteID, "an unmappable entry's remoteID must not be minted — it was never actually uploaded")
    }

    /// Several bad entries interleaved with several good ones — every valid entry still makes it
    /// into the one uploaded batch, regardless of how many invalid ones surround it.
    @MainActor
    func testMultipleInvalidEntriesDoNotBlockMultipleValidEntries() async throws {
        let syncedWallet = TestSupport.makeWallet(name: "Spending")
        syncedWallet.remoteID = UUID()
        context.insert(syncedWallet)
        let unsyncedWallet = TestSupport.makeWallet(name: "Orphaned")
        context.insert(unsyncedWallet)

        var validEntries: [Entry] = []
        var invalidEntries: [Entry] = []
        for index in 0..<3 {
            let valid = TestSupport.makeEntry(amount: Decimal(index + 1), date: .now, type: .expense, wallet: syncedWallet)
            let invalid = TestSupport.makeEntry(amount: Decimal(index + 100), date: .now, type: .expense, wallet: unsyncedWallet)
            context.insert(valid)
            context.insert(invalid)
            validEntries.append(valid)
            invalidEntries.append(invalid)
        }
        try context.save()

        try await service.syncEntries(modelContext: context)

        let batch = try XCTUnwrap(uploader.entryBatches.first)
        XCTAssertEqual(batch.count, 3, "only the three valid entries should be uploaded")
        let uploadedIDs = Set(batch.map(\.id))
        for valid in validEntries {
            XCTAssertTrue(uploadedIDs.contains(try XCTUnwrap(valid.remoteID)))
        }
        for invalid in invalidEntries {
            XCTAssertNil(invalid.remoteID)
        }
    }

    /// If every local entry is unmappable, `syncEntries` must complete without throwing or
    /// crashing — it simply sends no request, exactly like the existing empty-store case.
    @MainActor
    func testAllInvalidEntriesResultInNoUploadButSyncCompletes() async throws {
        let unsyncedWallet = TestSupport.makeWallet(name: "Orphaned")
        context.insert(unsyncedWallet)
        let invalidEntries = (0..<3).map { TestSupport.makeEntry(amount: Decimal($0 + 1), date: .now, type: .expense, wallet: unsyncedWallet) }
        invalidEntries.forEach(context.insert)
        try context.save()

        try await service.syncEntries(modelContext: context)

        XCTAssertTrue(uploader.entryBatches.isEmpty, "no request should be sent when every local entry is unmappable")
        for invalid in invalidEntries {
            XCTAssertNil(invalid.remoteID)
        }
    }

    // MARK: - Orchestration: syncReferenceData → syncEntries (Phase 3B-3's "Sync All Data" sequence)

    /// Mirrors exactly what `SupabaseTestView.runCombinedSync()` does: call `syncReferenceData`,
    /// then `syncEntries`, in sequence — no new orchestration method was added to
    /// `SupabaseSyncService` for this, so this test exercises the real two-call sequence directly.
    @MainActor
    func testCombinedSyncUploadsReferenceDataThenEntriesInOrder() async throws {
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, category: category, wallet: wallet)
        context.insert(entry)
        try context.save()

        try await service.syncReferenceData(modelContext: context)
        try await service.syncEntries(modelContext: context)

        XCTAssertEqual(uploader.headCategoryBatches.count, 1)
        XCTAssertEqual(uploader.categoryBatches.count, 1)
        XCTAssertEqual(uploader.walletBatches.count, 1)
        XCTAssertEqual(uploader.entryBatches.count, 1)
        XCTAssertEqual(uploader.entryBatches.first?.first?.id, entry.remoteID)
        XCTAssertEqual(uploader.entryBatches.first?.first?.walletID, wallet.remoteID)
        XCTAssertEqual(uploader.entryBatches.first?.first?.categoryID, category.remoteID)
    }

    /// The ordering requirement this phase cares about most: if reference-data sync fails,
    /// `syncEntries` must never run at all — not even a partial/empty upload attempt.
    @MainActor
    func testCombinedSyncNeverCallsEntrySyncWhenReferenceSyncFails() async throws {
        uploader.headCategoriesBatchError = StubError()
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)
        context.insert(entry)
        try context.save()

        do {
            try await service.syncReferenceData(modelContext: context)
            try await service.syncEntries(modelContext: context)
            XCTFail("expected syncReferenceData to throw before syncEntries could ever run")
        } catch is StubError {
            // expected
        }

        XCTAssertTrue(uploader.entryBatches.isEmpty, "syncEntries must never be reached when syncReferenceData fails first")
    }
}
