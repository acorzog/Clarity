import XCTest
import SwiftData
@testable import FinanceTracker

/// Covers Phase 3B-1: `Entry.isSoftDeleted`, the soft-delete marker that replaces
/// `modelContext.delete(entry)` across the app's normal deletion paths so a future Supabase sync
/// can learn a row was removed instead of inferring it from the row's mere absence. Deliberately
/// narrow — this phase adds no network code, so these tests exercise only the local model,
/// filtering, and backup round-trip.
final class EntrySoftDeleteTests: XCTestCase {

    // MARK: - Defaults

    func testNewEntryDefaultsToNotDeleted() {
        let wallet = TestSupport.makeWallet()
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)

        XCTAssertFalse(entry.isSoftDeleted)
    }

    // MARK: - Marking deleted

    func testMarkingAnEntryDeletedSetsIsDeleted() {
        let wallet = TestSupport.makeWallet()
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)

        entry.isSoftDeleted = true

        XCTAssertTrue(entry.isSoftDeleted)
    }

    /// Mirrors exactly what every converted deletion site now does: set `isSoftDeleted`, then bump
    /// `updatedAt` — the same explicit-bump convention `AddTransactionView.save()`'s edit branch
    /// already established for ordinary field edits.
    func testSoftDeletingAnEntryBumpsUpdatedAtButNotCreatedAt() {
        let wallet = TestSupport.makeWallet()
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)
        let originalTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        entry.createdAt = originalTimestamp
        entry.updatedAt = originalTimestamp

        entry.isSoftDeleted = true
        entry.updatedAt = .now

        XCTAssertEqual(entry.createdAt, originalTimestamp, "soft-deleting must never move createdAt")
        XCTAssertGreaterThan(entry.updatedAt, originalTimestamp, "soft-deleting must bump updatedAt forward")
    }

    // MARK: - Fetch/list exclusion

    /// The same `#Predicate<Entry> { !$0.isSoftDeleted }` now used by every `@Query` this phase
    /// touched (`EntryListView`, `HomeView`, `CalendarView`, etc.) — exercised here against a real
    /// `FetchDescriptor` so the predicate itself is verified against SwiftData, independent of
    /// SwiftUI's own `@Query` wiring.
    func testFetchDescriptorPredicateExcludesSoftDeletedEntries() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)

        let kept = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)
        let deleted = TestSupport.makeEntry(amount: 20, date: .now, type: .expense, wallet: wallet)
        deleted.isSoftDeleted = true
        context.insert(kept)
        context.insert(deleted)
        try context.save()

        let descriptor = FetchDescriptor<Entry>(predicate: #Predicate<Entry> { !$0.isSoftDeleted })
        let fetched = try context.fetch(descriptor)

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.amount, 10)
    }

    /// `Wallet.allEntries`/`Wallet.balance` read the raw `entries`/`incomingTransfers` relationship
    /// arrays directly, not a `@Query` — so they need their own `!isSoftDeleted` filter (added in
    /// `Wallet.swift`), separately from every view-level `@Query`. A soft-deleted entry must stop
    /// affecting the balance exactly as if it had been hard-deleted.
    func testWalletBalanceExcludesSoftDeletedEntries() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet(startingBalance: 100)
        context.insert(wallet)

        let keptExpense = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)
        let deletedExpense = TestSupport.makeEntry(amount: 50, date: .now, type: .expense, wallet: wallet)
        context.insert(keptExpense)
        context.insert(deletedExpense)
        deletedExpense.isSoftDeleted = true
        try context.save()

        // 100 - 10 (kept) = 90 — the soft-deleted 50 expense must not reduce the balance at all.
        XCTAssertEqual(wallet.balance, 90)
        XCTAssertEqual(wallet.allEntries.map(\.amount), [10])
    }

    // MARK: - Backup compatibility

    /// A backup exported before `isSoftDeleted` existed has no such key in its `EntrySnapshot` JSON —
    /// decoding it must still succeed, defaulting to `false`, exactly like `isPlannedExpense`'s
    /// existing backward-compat handling.
    func testEntrySnapshotDecodesOlderBackupsMissingTheIsDeletedKey() throws {
        let json = """
        {"amount":42,"categoryIndex":null,"date":"2026-01-15T10:00:00Z",
         "excludeFromBudget":false,"note":"","recurrence":"none","type":"expense","walletIndex":0}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(LocalBackupService.EntrySnapshot.self, from: json)

        XCTAssertFalse(snapshot.isSoftDeleted)
    }

    /// A current backup round-trip must preserve `isSoftDeleted` for both a kept and a soft-deleted
    /// entry — this is now sync-relevant state (a future Supabase sync needs it intact), not just
    /// cosmetic, so losing it on restore would be a real regression.
    func testBackupRoundTripPreservesIsDeleted() throws {
        let source = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet(name: "Spending")
        source.insert(wallet)

        let kept = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)
        let deleted = TestSupport.makeEntry(amount: 20, date: .now, type: .expense, wallet: wallet)
        deleted.isSoftDeleted = true
        source.insert(kept)
        source.insert(deleted)
        try source.save()

        let data = try LocalBackupService.export(context: source)
        let destination = TestSupport.makeInMemoryContext()
        try LocalBackupService.restore(from: data, context: destination)

        let restored = try destination.fetch(FetchDescriptor<Entry>())
        let restoredKept = try XCTUnwrap(restored.first { $0.amount == 10 })
        let restoredDeleted = try XCTUnwrap(restored.first { $0.amount == 20 })

        XCTAssertFalse(restoredKept.isSoftDeleted)
        XCTAssertTrue(restoredDeleted.isSoftDeleted, "restore must preserve isSoftDeleted — backup/restore is intentionally a full historical snapshot, soft-deleted entries included")
    }
}
