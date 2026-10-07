import XCTest
import SwiftData
@testable import FinanceTracker

/// Covers the identity/change-tracking foundation added to `Entry`/`Wallet`/`Category`/
/// `HeadCategory` ahead of a future Supabase sync: `remoteID` (nil until a model first needs a
/// remote identity), `createdAt` (stamped once at construction), and `updatedAt` (bumped by hand
/// at each model's own mutation sites, e.g. `AddTransactionView.save()`'s edit branch). Mirrors
/// the existing CloudKit-sync convention already established on `SharedEvent`/`SharedExpense`/
/// `Settlement` — see those models' own `remoteID` doc comments.
final class SyncIdentityTests: XCTestCase {

    // MARK: - New instances receive stable createdAt/updatedAt, and no remoteID

    func testNewEntryReceivesCreatedAtAndUpdatedAtAndNoRemoteID() {
        let wallet = TestSupport.makeWallet()
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)

        XCTAssertNil(entry.remoteID, "a remote identity must never be minted at ordinary local construction")
        XCTAssertEqual(entry.createdAt, entry.updatedAt, "a freshly-created entry's createdAt and updatedAt must start identical")
    }

    func testNewWalletReceivesCreatedAtAndUpdatedAtAndNoRemoteID() {
        let wallet = TestSupport.makeWallet()

        XCTAssertNil(wallet.remoteID)
        XCTAssertEqual(wallet.createdAt, wallet.updatedAt)
    }

    func testNewHeadCategoryReceivesCreatedAtAndUpdatedAtAndNoRemoteID() {
        let head = TestSupport.makeHeadCategory()

        XCTAssertNil(head.remoteID)
        XCTAssertEqual(head.createdAt, head.updatedAt)
    }

    func testNewCategoryReceivesCreatedAtAndUpdatedAtAndNoRemoteID() {
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(headCategory: head)

        XCTAssertNil(category.remoteID)
        XCTAssertEqual(category.createdAt, category.updatedAt)
    }

    /// `TransactionSaving.createEntry` is the single choke point most of the app's "new entry"
    /// flows go through (`AddTransactionView`, `CategorizationService`, voice quick-save) — it
    /// must stamp fresh timestamps exactly like direct `Entry(...)` construction does, without
    /// needing every caller to pass them explicitly.
    func testTransactionSavingCreateEntryStampsFreshTimestamps() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)

        let entry = TransactionSaving.createEntry(amount: 25, type: .expense, category: nil, wallet: wallet, modelContext: context)

        XCTAssertNil(entry.remoteID)
        XCTAssertEqual(entry.createdAt, entry.updatedAt)
    }

    // MARK: - remoteID can be assigned and survives SwiftData persistence

    func testRemoteIDSurvivesSwiftDataPersistence() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)
        context.insert(entry)

        let mintedID = UUID()
        entry.remoteID = mintedID
        wallet.remoteID = UUID()
        try context.save()

        // Re-fetch from the context to confirm the value round-tripped through SwiftData, not
        // just an in-memory property still holding the assignment.
        let fetchedEntries = try context.fetch(FetchDescriptor<Entry>())
        let fetchedEntry = try XCTUnwrap(fetchedEntries.first)
        XCTAssertEqual(fetchedEntry.remoteID, mintedID)

        let fetchedWallets = try context.fetch(FetchDescriptor<Wallet>())
        XCTAssertNotNil(fetchedWallets.first?.remoteID)
    }

    // MARK: - Editing an Entry updates updatedAt

    /// Mirrors exactly what `AddTransactionView.save()`'s edit branch does: mutate fields on an
    /// existing, already-persisted `Entry`, then bump `updatedAt`. `createdAt` must never move.
    func testEditingAnExistingEntryBumpsUpdatedAtButNotCreatedAt() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)

        let originalTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, wallet: wallet)
        entry.createdAt = originalTimestamp
        entry.updatedAt = originalTimestamp
        context.insert(entry)
        try context.save()

        // The exact mutation shape AddTransactionView.save()'s edit branch performs.
        entry.amount = 20
        entry.note = "Edited"
        entry.updatedAt = .now

        XCTAssertEqual(entry.createdAt, originalTimestamp, "editing must never move createdAt")
        XCTAssertGreaterThan(entry.updatedAt, originalTimestamp, "editing must bump updatedAt forward")
    }

    // MARK: - Existing transfer behavior is unchanged

    /// The new fields are additive — a transfer `Entry` must still reference both its source and
    /// destination wallet, apply its balance effect on each exactly once, and leave `category`
    /// nil, exactly as before this change.
    func testTransferBehaviorIsUnchangedByTheNewFields() throws {
        let context = TestSupport.makeInMemoryContext()
        let source = TestSupport.makeWallet(name: "Source", startingBalance: 100)
        let destination = TestSupport.makeWallet(name: "Destination", startingBalance: 0)
        context.insert(source)
        context.insert(destination)

        let transfer = TestSupport.makeEntry(amount: 30, date: .now, type: .transfer, wallet: source, destinationWallet: destination)
        context.insert(transfer)
        try context.save()

        XCTAssertNil(transfer.category, "a transfer must still carry no category")
        XCTAssertEqual(source.effect(of: transfer), -30)
        XCTAssertEqual(destination.effect(of: transfer), 30)
        XCTAssertEqual(source.balance, 70)
        XCTAssertEqual(destination.balance, 30)
        // Both the source and destination relationship, and the fresh sync-identity fields, are
        // present side by side without conflict.
        XCTAssertNil(transfer.remoteID)
        XCTAssertEqual(transfer.createdAt, transfer.updatedAt)
    }
}
