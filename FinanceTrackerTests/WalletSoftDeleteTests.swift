import XCTest
import SwiftData
@testable import FinanceTracker

/// Covers Phase 3D-1: `Wallet.isSoftDeleted`, the soft-delete marker that replaces
/// `modelContext.delete(wallet)` in `WalletEditorView`'s "Remove Account" action, mirroring
/// `Entry.isSoftDeleted` (Phase 3B-1) exactly. Unlike `Entry`, a soft-deleted `Wallet`'s own
/// historical entries are deliberately left untouched — only the wallet itself disappears from
/// normal lists/pickers.
final class WalletSoftDeleteTests: XCTestCase {

    // MARK: - Defaults

    func testNewWalletDefaultsToNotDeleted() {
        let wallet = TestSupport.makeWallet()
        XCTAssertFalse(wallet.isSoftDeleted)
    }

    // MARK: - Marking deleted (mirrors WalletEditorView's "Remove Account" action)

    func testSoftDeletingAWalletSetsIsSoftDeletedAndBumpsUpdatedAtButNotCreatedAt() {
        let wallet = TestSupport.makeWallet()
        let originalTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        wallet.createdAt = originalTimestamp
        wallet.updatedAt = originalTimestamp

        wallet.isSoftDeleted = true
        wallet.updatedAt = .now

        XCTAssertTrue(wallet.isSoftDeleted)
        XCTAssertEqual(wallet.createdAt, originalTimestamp, "soft-deleting must never move createdAt")
        XCTAssertGreaterThan(wallet.updatedAt, originalTimestamp, "soft-deleting must bump updatedAt forward")
    }

    /// Characterizes the actual persistence contract `WalletEditorView.save()`'s Remove Account
    /// action depends on — mirrors `WalletEditorPersistenceTests`'s existing pattern (that
    /// private View method can't be called directly from a test).
    @MainActor
    func testSoftDeletingAWalletPersistsAndSurvivesRollback() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet(name: "Old Card", type: .credit)
        context.insert(wallet)
        try context.save()

        wallet.isSoftDeleted = true
        wallet.updatedAt = .now
        try context.save()

        context.rollback()

        XCTAssertTrue(wallet.isSoftDeleted, "a saved soft-delete must not be discarded by a later rollback")
        // The row itself must still exist — this is a flag, not a real deletion.
        XCTAssertEqual(try context.fetch(FetchDescriptor<Wallet>()).count, 1)
    }

    // MARK: - Fetch/list exclusion

    /// The same `#Predicate<Wallet> { !$0.isSoftDeleted }` now used by every Wallet `@Query` this
    /// phase touched (`WalletsView`, `HomeView`, `AddTransactionView`, `WalletPickerView`,
    /// `ManageWalletsView`, etc.) — exercised here against a real `FetchDescriptor`, independent
    /// of SwiftUI's own `@Query` wiring.
    func testFetchDescriptorPredicateExcludesSoftDeletedWallets() throws {
        let context = TestSupport.makeInMemoryContext()
        let kept = TestSupport.makeWallet(name: "Spending")
        let removed = TestSupport.makeWallet(name: "Closed Account")
        removed.isSoftDeleted = true
        context.insert(kept)
        context.insert(removed)
        try context.save()

        let descriptor = FetchDescriptor<Wallet>(predicate: #Predicate<Wallet> { !$0.isSoftDeleted })
        let fetched = try context.fetch(descriptor)

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.name, "Spending")
    }

    /// `Wallet.active(in:)` is the shared gate the three Shortcuts/Siri intents (`LogExpenseIntent`,
    /// `WalletEntity`, `TransactionFromTextIntent`) rely on instead of a filtered `@Query` — must
    /// exclude a soft-deleted wallet exactly like it already excludes an archived one.
    func testActiveExcludesSoftDeletedWallets() {
        let kept = TestSupport.makeWallet(name: "Spending")
        let removed = TestSupport.makeWallet(name: "Closed Account")
        removed.isSoftDeleted = true
        let archived = TestSupport.makeWallet(name: "Archived", isArchived: true)

        let active = Wallet.active(in: [kept, removed, archived])

        XCTAssertEqual(active.map(\.name), ["Spending"])
    }

    // MARK: - Historical entries remain intact

    /// The key behavioral difference from `Entry.isSoftDeleted`: soft-deleting the *wallet* must
    /// never hide or zero out its own historical `Entry` rows or balance math — only the wallet
    /// disappears from normal lists/pickers. A soft-deleted wallet's entries are still exactly as
    /// real as they were before "removal."
    func testSoftDeletingAWalletLeavesItsHistoricalEntriesAndBalanceIntact() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet(name: "Old Card", startingBalance: 100)
        context.insert(wallet)
        let entry = TestSupport.makeEntry(amount: 30, date: .now, type: .expense, wallet: wallet)
        context.insert(entry)
        try context.save()

        wallet.isSoftDeleted = true
        wallet.updatedAt = .now
        try context.save()

        XCTAssertEqual(wallet.balance, 70, "soft-deleting the wallet must not affect its own balance calculation")
        XCTAssertEqual(wallet.allEntries.map(\.amount), [30], "the wallet's historical entry must remain fully intact")
        let allEntries = try context.fetch(FetchDescriptor<Entry>())
        XCTAssertEqual(allEntries.count, 1)
        XCTAssertFalse(allEntries[0].isSoftDeleted, "soft-deleting a wallet must never soft-delete its entries")
    }

    // MARK: - WalletDTO / sync

    func testWalletDTOMapsIsSoftDeletedToIsDeleted() {
        let wallet = TestSupport.makeWallet(name: "Closed Account")
        wallet.isSoftDeleted = true
        let dto = WalletDTO(wallet: wallet, remoteID: UUID(), userID: UUID())

        XCTAssertTrue(dto.isDeleted)
    }

    func testWalletDTOForANonDeletedWalletIsNotDeleted() {
        let wallet = TestSupport.makeWallet(name: "Spending")
        let dto = WalletDTO(wallet: wallet, remoteID: UUID(), userID: UUID())

        XCTAssertFalse(dto.isDeleted)
    }

    /// The core Phase 3D-1 sync requirement: a soft-deleted wallet is not filtered out of
    /// `syncReferenceData`'s input — it uploads in the same batch as every other wallet, with
    /// `is_deleted = true`, mirroring `syncEntries`'s existing behavior for soft-deleted entries.
    @MainActor
    func testSyncReferenceDataIncludesSoftDeletedWallets() async throws {
        final class RecordingUploader: SupabaseReferenceDataUploading {
            private(set) var walletBatches: [[WalletDTO]] = []
            func upsertHeadCategory(_ dto: HeadCategoryDTO) async throws {}
            func upsertCategory(_ dto: CategoryDTO) async throws {}
            func upsertWallet(_ dto: WalletDTO) async throws {}
            func upsertHeadCategories(_ dtos: [HeadCategoryDTO]) async throws {}
            func upsertCategories(_ dtos: [CategoryDTO]) async throws {}
            func upsertWallets(_ dtos: [WalletDTO]) async throws { walletBatches.append(dtos) }
            func upsertBudgets(_ dtos: [BudgetDTO]) async throws {}
            func upsertEntries(_ dtos: [EntryDTO]) async throws {}
        }
        final class StubUserProvider: SupabaseSyncUserProviding {
            let userID: UUID?
            init(userID: UUID?) { self.userID = userID }
            func currentUserID() async throws -> UUID? { userID }
        }

        let uploader = RecordingUploader()
        let userProvider = StubUserProvider(userID: UUID())
        let service = SupabaseSyncService(uploader: uploader, userProvider: userProvider)
        let context = TestSupport.makeInMemoryContext()

        let kept = TestSupport.makeWallet(name: "Spending")
        let removed = TestSupport.makeWallet(name: "Closed Account")
        context.insert(kept)
        context.insert(removed)
        try context.save()
        removed.isSoftDeleted = true
        removed.updatedAt = .now
        try context.save()

        try await service.syncReferenceData(modelContext: context)

        let batch = try XCTUnwrap(uploader.walletBatches.first)
        XCTAssertEqual(batch.count, 2, "the soft-deleted wallet must still be included in the batch")
        let keptDTO = try XCTUnwrap(batch.first { $0.id == kept.remoteID })
        let removedDTO = try XCTUnwrap(batch.first { $0.id == removed.remoteID })
        XCTAssertFalse(keptDTO.isDeleted)
        XCTAssertTrue(removedDTO.isDeleted)
    }

    /// Re-running `syncReferenceData` after a wallet has been soft-deleted must never mint a
    /// second identity or send a different row — it just re-sends the same tombstoned wallet,
    /// idempotently, exactly like every other remoteID in this architecture.
    @MainActor
    func testRepeatedSyncOfASoftDeletedWalletIsIdempotent() async throws {
        final class RecordingUploader: SupabaseReferenceDataUploading {
            private(set) var walletBatches: [[WalletDTO]] = []
            func upsertHeadCategory(_ dto: HeadCategoryDTO) async throws {}
            func upsertCategory(_ dto: CategoryDTO) async throws {}
            func upsertWallet(_ dto: WalletDTO) async throws {}
            func upsertHeadCategories(_ dtos: [HeadCategoryDTO]) async throws {}
            func upsertCategories(_ dtos: [CategoryDTO]) async throws {}
            func upsertWallets(_ dtos: [WalletDTO]) async throws { walletBatches.append(dtos) }
            func upsertBudgets(_ dtos: [BudgetDTO]) async throws {}
            func upsertEntries(_ dtos: [EntryDTO]) async throws {}
        }
        final class StubUserProvider: SupabaseSyncUserProviding {
            let userID: UUID?
            init(userID: UUID?) { self.userID = userID }
            func currentUserID() async throws -> UUID? { userID }
        }

        let uploader = RecordingUploader()
        let userProvider = StubUserProvider(userID: UUID())
        let service = SupabaseSyncService(uploader: uploader, userProvider: userProvider)
        let context = TestSupport.makeInMemoryContext()

        let wallet = TestSupport.makeWallet(name: "Closed Account")
        context.insert(wallet)
        try context.save()
        wallet.isSoftDeleted = true
        wallet.updatedAt = .now
        try context.save()

        try await service.syncReferenceData(modelContext: context)
        let idAfterFirst = wallet.remoteID

        try await service.syncReferenceData(modelContext: context)

        XCTAssertEqual(wallet.remoteID, idAfterFirst, "a repeated sync must never mint a second remoteID")
        XCTAssertEqual(uploader.walletBatches.count, 2)
        XCTAssertEqual(uploader.walletBatches[0].map(\.id), uploader.walletBatches[1].map(\.id))
        XCTAssertTrue(uploader.walletBatches[1].first { $0.id == wallet.remoteID }?.isDeleted ?? false)
    }

    // MARK: - Backup compatibility

    /// A backup exported before `isSoftDeleted` existed has no such key in its `WalletSnapshot`
    /// JSON — decoding it must still succeed, defaulting to `false`.
    func testWalletSnapshotDecodesOlderBackupsMissingTheIsSoftDeletedKey() throws {
        let json = """
        {"name":"Spending","type":"spending","colorHex":"#FFFFFF","icon":"wallet.bifold",
         "startingBalance":100,"includeInNetWorth":true,"isDefault":false,"isArchived":false,"sortOrder":0}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(LocalBackupService.WalletSnapshot.self, from: json)

        XCTAssertFalse(snapshot.isSoftDeleted)
    }

    /// A current backup round-trip must preserve `isSoftDeleted` for both a kept and a
    /// soft-deleted wallet — this is now sync-relevant state, not just cosmetic.
    @MainActor
    func testBackupRoundTripPreservesWalletIsSoftDeleted() throws {
        let source = TestSupport.makeInMemoryContext()
        let kept = TestSupport.makeWallet(name: "Spending")
        let removed = TestSupport.makeWallet(name: "Closed Account")
        source.insert(kept)
        source.insert(removed)
        try source.save()
        removed.isSoftDeleted = true
        removed.updatedAt = .now
        try source.save()

        let data = try LocalBackupService.export(context: source)
        let destination = TestSupport.makeInMemoryContext()
        try LocalBackupService.restore(from: data, context: destination)

        let restored = try destination.fetch(FetchDescriptor<Wallet>())
        let restoredKept = try XCTUnwrap(restored.first { $0.name == "Spending" })
        let restoredRemoved = try XCTUnwrap(restored.first { $0.name == "Closed Account" })

        XCTAssertFalse(restoredKept.isSoftDeleted)
        XCTAssertTrue(restoredRemoved.isSoftDeleted, "restore must preserve isSoftDeleted — backup/restore is intentionally a full historical snapshot, soft-deleted wallets included")
    }
}
