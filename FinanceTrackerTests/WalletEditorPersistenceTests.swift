import XCTest
import SwiftData
@testable import FinanceTracker

/// Regression coverage for the bug found in the Phase 3C Wallet automatic-sync investigation:
/// `WalletEditorView.save()` used to mutate `wallet`/insert an adjustment `Entry` and then call
/// `dismiss()` with no explicit `modelContext.save()`, relying entirely on SwiftData's lazy
/// autosave. Because `RootView` calls `modelContext.rollback()` on every foreground transition and
/// cross-process store change, an edit that hadn't been explicitly saved yet could be silently
/// discarded before it ever reached disk — let alone Supabase's automatic sync. `save()` itself is
/// a private View method and can't be called directly from a test (no `ModelContext`/live-view
/// access, same limitation documented for `AddTransactionView.save()`'s `isSaving` guard), so these
/// tests instead characterize the exact persistence contract the fix depends on: a mutation
/// followed by an explicit `modelContext.save()` must survive a subsequent `rollback()`.
final class WalletEditorPersistenceTests: XCTestCase {
    @MainActor
    func testEditingAnExistingWalletPersistsChangedTypeNameAndIncludeInNetWorth() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet(name: "Old Name", type: .spending, includeInNetWorth: true)
        context.insert(wallet)
        try context.save()

        // Mirrors exactly what `WalletEditorView.save()`'s existing-wallet branch does.
        wallet.name = "New Name"
        wallet.type = .savings
        wallet.includeInNetWorth = false
        wallet.updatedAt = .now
        try context.save()

        let refetched = try XCTUnwrap(try context.fetch(FetchDescriptor<Wallet>()).first)
        XCTAssertEqual(refetched.name, "New Name")
        XCTAssertEqual(refetched.type, .savings)
        XCTAssertEqual(refetched.includeInNetWorth, false)
    }

    /// The heart of the reported bug: once a mutation has actually been saved, a later
    /// `rollback()` (as `RootView` performs on every foreground transition/remote store change)
    /// must not revert it — only a genuinely *unsaved* change should ever be at risk from that.
    @MainActor
    func testASavedWalletMutationSurvivesASubsequentRollback() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet(name: "Checking", type: .spending)
        context.insert(wallet)
        try context.save()

        wallet.type = .savings
        wallet.name = "Savings Goal"
        try context.save()

        context.rollback()

        XCTAssertEqual(wallet.type, .savings, "a saved mutation must not be discarded by a later rollback")
        XCTAssertEqual(wallet.name, "Savings Goal")
    }

    /// The other mutation path `WalletEditorView.save()` can take for a wallet with real
    /// transaction history: `resolveBalanceEdit` returns `.logAdjustmentEntry`, and a new "Balance
    /// adjustment" `Entry` is inserted rather than `startingBalance` being touched directly. That
    /// inserted `Entry` must also survive an explicit save + later rollback, exactly like the
    /// wallet mutation above.
    @MainActor
    func testBalanceAdjustmentEntryPersistsAndSurvivesRollback() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet(name: "Checking", type: .spending, startingBalance: 0)
        context.insert(wallet)
        let existingEntry = TestSupport.makeEntry(amount: 50, date: .now, type: .income, wallet: wallet)
        context.insert(existingEntry)
        try context.save()

        let outcome = WalletEditorView.resolveBalanceEdit(desiredBalance: 300, currentBalance: wallet.balance, hasRealHistory: !wallet.canBeDeleted)
        guard case .logAdjustmentEntry(let amount, let type) = outcome else {
            return XCTFail("expected a logged adjustment for a wallet with real history: \(outcome)")
        }
        let adjustment = Entry(amount: amount, note: "Balance adjustment", type: type, wallet: wallet, excludeFromBudget: true)
        context.insert(adjustment)
        try context.save()

        context.rollback()

        let entries = try context.fetch(FetchDescriptor<Entry>())
        XCTAssertEqual(entries.count, 2, "both the original entry and the saved adjustment must survive a later rollback")
        XCTAssertTrue(entries.contains { $0.note == "Balance adjustment" })
    }

    /// `WalletEditorView`'s "Remove Account" destructive action — a separate code path from
    /// `save()` — mirrors exactly the same bug: `modelContext.delete(wallet)` followed immediately
    /// by `dismiss()`, with no explicit save. Local-only fix: this does not touch Supabase's
    /// delete behavior at all, only whether the local deletion itself durably persists.
    @MainActor
    func testDeletingAWalletPersistsAndSurvivesRollback() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet(name: "Unused Card", type: .credit)
        context.insert(wallet)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Wallet>()).count, 1)

        context.delete(wallet)
        try context.save()

        context.rollback()

        XCTAssertTrue(try context.fetch(FetchDescriptor<Wallet>()).isEmpty, "a saved deletion must not be undone by a later rollback")
    }
}
