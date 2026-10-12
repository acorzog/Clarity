import XCTest
import SwiftData
@testable import FinanceTracker

/// Phase 4E: covers `SupabaseSyncService.pullEntries` — the remote→local merge path for the
/// `entries` table, following exactly the same `remoteID`-matched, last-write-wins rule
/// `PullReferenceDataTests`/`PullBudgetsTests` already cover. A separate mock from those (
/// `SupabaseEntryDownloading` is its own protocol) so none of the existing pull tests/mocks
/// needed to change. No network connection is used anywhere here.
private final class StubEntryDownloader: SupabaseEntryDownloading {
    var entries: [EntryDTO] = []
    func fetchEntries(userID: UUID) async throws -> [EntryDTO] { entries }
}

private final class StubUserProvider: SupabaseSyncUserProviding {
    var userID: UUID?
    func currentUserID() async throws -> UUID? { userID }
}

/// Production `SupabaseReferenceDataUploading`/`SupabaseReferenceDataDownloading`/
/// `SupabaseBudgetDownloading` conformances are still required by `SupabaseSyncService.init`,
/// even though `pullEntries` never touches any of them — minimal no-op stand-ins keep these tests
/// from needing any of the existing push/pull mocks.
private final class UnusedUploader: SupabaseReferenceDataUploading {
    func upsertHeadCategory(_ dto: HeadCategoryDTO) async throws {}
    func upsertCategory(_ dto: CategoryDTO) async throws {}
    func upsertWallet(_ dto: WalletDTO) async throws {}
    func upsertHeadCategories(_ dtos: [HeadCategoryDTO]) async throws {}
    func upsertCategories(_ dtos: [CategoryDTO]) async throws {}
    func upsertWallets(_ dtos: [WalletDTO]) async throws {}
    func upsertBudgets(_ dtos: [BudgetDTO]) async throws {}
    func upsertEntries(_ dtos: [EntryDTO]) async throws {}
}

private final class UnusedDownloader: SupabaseReferenceDataDownloading {
    func fetchHeadCategories(userID: UUID) async throws -> [HeadCategoryDTO] { [] }
    func fetchCategories(userID: UUID) async throws -> [CategoryDTO] { [] }
    func fetchWallets(userID: UUID) async throws -> [WalletDTO] { [] }
}

private final class UnusedBudgetDownloader: SupabaseBudgetDownloading {
    func fetchBudgets(userID: UUID) async throws -> [BudgetDTO] { [] }
}

final class PullEntriesTests: XCTestCase {
    private var entryDownloader: StubEntryDownloader!
    private var userProvider: StubUserProvider!
    private var service: SupabaseSyncService!
    private var context: ModelContext!
    private let userID = UUID()

    @MainActor
    override func setUp() {
        super.setUp()
        entryDownloader = StubEntryDownloader()
        userProvider = StubUserProvider()
        userProvider.userID = userID
        service = SupabaseSyncService(
            uploader: UnusedUploader(),
            downloader: UnusedDownloader(),
            budgetDownloader: UnusedBudgetDownloader(),
            entryDownloader: entryDownloader,
            userProvider: userProvider
        )
        context = TestSupport.makeInMemoryContext()
    }

    @MainActor
    @discardableResult
    private func makeSyncedWallet(remoteID: UUID, name: String = "Wallet") throws -> Wallet {
        let wallet = TestSupport.makeWallet(name: name)
        wallet.remoteID = remoteID
        context.insert(wallet)
        try context.save()
        return wallet
    }

    @MainActor
    @discardableResult
    private func makeSyncedCategory(remoteID: UUID, name: String = "Groceries") throws -> FinanceTracker.Category {
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(name: name, headCategory: head)
        category.remoteID = remoteID
        context.insert(category)
        try context.save()
        return category
    }

    // MARK: - 1. Create

    @MainActor
    func testPullCreatesALocalEntryThatDoesNotExistLocally() async throws {
        let walletRemoteID = UUID()
        try makeSyncedWallet(remoteID: walletRemoteID)
        let categoryRemoteID = UUID()
        try makeSyncedCategory(remoteID: categoryRemoteID)

        let entryRemoteID = UUID()
        let remoteCreatedAt = Date(timeIntervalSince1970: 1_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_000)
        entryDownloader.entries = [
            EntryDTO(
                id: entryRemoteID, userID: userID, walletID: walletRemoteID, destinationWalletID: nil,
                categoryID: categoryRemoteID, amount: 42.50, date: Date(timeIntervalSince1970: 500),
                note: "Groceries run", type: .expense, recurrence: .none, excludeFromBudget: false,
                isPlannedExpense: true, isDeleted: false, createdAt: remoteCreatedAt, updatedAt: remoteUpdatedAt
            ),
        ]

        try await service.pullEntries(modelContext: context)

        let local = try XCTUnwrap(try context.fetch(FetchDescriptor<Entry>()).first)
        XCTAssertEqual(local.remoteID, entryRemoteID, "the remote's own id must be preserved, not a freshly minted one")
        XCTAssertEqual(local.amount, 42.50)
        XCTAssertEqual(local.note, "Groceries run")
        XCTAssertEqual(local.type, .expense)
        XCTAssertTrue(local.isPlannedExpense)
        XCTAssertFalse(local.isSoftDeleted)
        XCTAssertEqual(local.wallet.remoteID, walletRemoteID)
        XCTAssertEqual(local.category?.remoteID, categoryRemoteID)
        XCTAssertNil(local.destinationWallet)
        XCTAssertEqual(local.createdAt, remoteCreatedAt)
        XCTAssertEqual(local.updatedAt, remoteUpdatedAt)
    }

    // MARK: - 2. Update when remote is newer

    @MainActor
    func testPullUpdatesExistingEntryWhenRemoteIsNewer() async throws {
        let walletRemoteID = UUID()
        let wallet = try makeSyncedWallet(remoteID: walletRemoteID)
        let categoryRemoteID = UUID()
        let category = try makeSyncedCategory(remoteID: categoryRemoteID)

        let entryRemoteID = UUID()
        let localUpdatedAt = Date(timeIntervalSince1970: 1_000)
        let existing = TestSupport.makeEntry(amount: 10, date: .now, type: .expense, category: category, wallet: wallet)
        existing.remoteID = entryRemoteID
        existing.updatedAt = localUpdatedAt
        context.insert(existing)
        try context.save()

        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_000)
        entryDownloader.entries = [
            EntryDTO(
                id: entryRemoteID, userID: userID, walletID: walletRemoteID, destinationWalletID: nil,
                categoryID: categoryRemoteID, amount: 999, date: Date(timeIntervalSince1970: 1_500),
                note: "Updated", type: .expense, recurrence: .monthly, excludeFromBudget: true,
                isPlannedExpense: true, isDeleted: false, createdAt: existing.createdAt, updatedAt: remoteUpdatedAt
            ),
        ]

        try await service.pullEntries(modelContext: context)

        let entries = try context.fetch(FetchDescriptor<Entry>())
        XCTAssertEqual(entries.count, 1, "an update must never insert a second row")
        let updated = try XCTUnwrap(entries.first)
        XCTAssertEqual(updated.amount, 999)
        XCTAssertEqual(updated.note, "Updated")
        XCTAssertEqual(updated.recurrence, .monthly)
        XCTAssertTrue(updated.excludeFromBudget)
        XCTAssertEqual(updated.updatedAt, remoteUpdatedAt)
    }

    // MARK: - 3. Local newer remains unchanged

    @MainActor
    func testPullLeavesLocalEntryUnchangedWhenLocalIsNewer() async throws {
        let walletRemoteID = UUID()
        let wallet = try makeSyncedWallet(remoteID: walletRemoteID)
        let categoryRemoteID = UUID()
        let category = try makeSyncedCategory(remoteID: categoryRemoteID)

        let entryRemoteID = UUID()
        let localUpdatedAt = Date(timeIntervalSince1970: 5_000)
        let existing = TestSupport.makeEntry(amount: 250, date: .now, type: .expense, category: category, wallet: wallet)
        existing.remoteID = entryRemoteID
        existing.updatedAt = localUpdatedAt
        context.insert(existing)
        try context.save()

        entryDownloader.entries = [
            EntryDTO(
                id: entryRemoteID, userID: userID, walletID: walletRemoteID, destinationWalletID: nil,
                categoryID: categoryRemoteID, amount: 1, date: .now, note: "stale", type: .expense,
                recurrence: .none, excludeFromBudget: false, isPlannedExpense: false, isDeleted: false,
                createdAt: existing.createdAt, updatedAt: Date(timeIntervalSince1970: 1_000)
            ),
        ]

        try await service.pullEntries(modelContext: context)

        let updated = try XCTUnwrap(try context.fetch(FetchDescriptor<Entry>()).first)
        XCTAssertEqual(updated.amount, 250, "a local row newer than the remote must never be overwritten")
        XCTAssertEqual(updated.updatedAt, localUpdatedAt)
    }

    // MARK: - 4. Equal timestamp unchanged

    @MainActor
    func testPullLeavesLocalEntryUnchangedWhenTimestampsAreEqual() async throws {
        let walletRemoteID = UUID()
        let wallet = try makeSyncedWallet(remoteID: walletRemoteID)
        let categoryRemoteID = UUID()
        let category = try makeSyncedCategory(remoteID: categoryRemoteID)

        let entryRemoteID = UUID()
        let sharedUpdatedAt = Date(timeIntervalSince1970: 3_000)
        let existing = TestSupport.makeEntry(amount: 250, date: .now, type: .expense, category: category, wallet: wallet)
        existing.remoteID = entryRemoteID
        existing.updatedAt = sharedUpdatedAt
        context.insert(existing)
        try context.save()

        entryDownloader.entries = [
            EntryDTO(
                id: entryRemoteID, userID: userID, walletID: walletRemoteID, destinationWalletID: nil,
                categoryID: categoryRemoteID, amount: 999, date: .now, note: "stale", type: .expense,
                recurrence: .none, excludeFromBudget: false, isPlannedExpense: false, isDeleted: false,
                createdAt: existing.createdAt, updatedAt: sharedUpdatedAt
            ),
        ]

        try await service.pullEntries(modelContext: context)

        let updated = try XCTUnwrap(try context.fetch(FetchDescriptor<Entry>()).first)
        XCTAssertEqual(updated.amount, 250, "strictly-greater is required — an equal remote updatedAt must not overwrite")
    }

    // MARK: - 5. Missing wallet/category relationship

    @MainActor
    func testPullSkipsAnEntryWhoseWalletHasNoLocalMatch() async throws {
        entryDownloader.entries = [
            EntryDTO(
                id: UUID(), userID: userID, walletID: UUID(), destinationWalletID: nil, categoryID: nil,
                amount: 50, date: .now, note: "orphan", type: .expense, recurrence: .none,
                excludeFromBudget: false, isPlannedExpense: false, isDeleted: false, createdAt: .now, updatedAt: .now
            ),
        ]

        try await service.pullEntries(modelContext: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<Entry>()).isEmpty, "an entry whose wallet isn't resolved locally must be skipped, not crash or insert with a dangling reference")
    }

    @MainActor
    func testPullSkipsAnEntryWhoseCategoryHasNoLocalMatch() async throws {
        let walletRemoteID = UUID()
        try makeSyncedWallet(remoteID: walletRemoteID)

        entryDownloader.entries = [
            EntryDTO(
                id: UUID(), userID: userID, walletID: walletRemoteID, destinationWalletID: nil,
                categoryID: UUID(), amount: 50, date: .now, note: "orphan category", type: .expense,
                recurrence: .none, excludeFromBudget: false, isPlannedExpense: false, isDeleted: false,
                createdAt: .now, updatedAt: .now
            ),
        ]

        try await service.pullEntries(modelContext: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<Entry>()).isEmpty, "an entry whose category isn't resolved locally must be skipped")
    }

    // MARK: - 6. Destination wallet for transfers

    @MainActor
    func testPullCreatesATransferWithSourceAndDestinationWalletAndNoCategory() async throws {
        let sourceRemoteID = UUID()
        let source = try makeSyncedWallet(remoteID: sourceRemoteID, name: "Source")
        let destinationRemoteID = UUID()
        let destination = try makeSyncedWallet(remoteID: destinationRemoteID, name: "Destination")

        let entryRemoteID = UUID()
        entryDownloader.entries = [
            EntryDTO(
                id: entryRemoteID, userID: userID, walletID: sourceRemoteID, destinationWalletID: destinationRemoteID,
                categoryID: nil, amount: 100, date: .now, note: "Transfer", type: .transfer, recurrence: .none,
                excludeFromBudget: false, isPlannedExpense: false, isDeleted: false, createdAt: .now, updatedAt: .now
            ),
        ]

        try await service.pullEntries(modelContext: context)

        let local = try XCTUnwrap(try context.fetch(FetchDescriptor<Entry>()).first)
        XCTAssertEqual(local.type, .transfer)
        XCTAssertNil(local.category, "a transfer must never carry a category")
        XCTAssertEqual(local.wallet.remoteID, source.remoteID)
        XCTAssertEqual(local.destinationWallet?.remoteID, destination.remoteID)
    }

    @MainActor
    func testPullSkipsATransferWhoseDestinationWalletHasNoLocalMatch() async throws {
        let sourceRemoteID = UUID()
        try makeSyncedWallet(remoteID: sourceRemoteID, name: "Source")

        entryDownloader.entries = [
            EntryDTO(
                id: UUID(), userID: userID, walletID: sourceRemoteID, destinationWalletID: UUID(),
                categoryID: nil, amount: 100, date: .now, note: "orphan transfer", type: .transfer,
                recurrence: .none, excludeFromBudget: false, isPlannedExpense: false, isDeleted: false,
                createdAt: .now, updatedAt: .now
            ),
        ]

        try await service.pullEntries(modelContext: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<Entry>()).isEmpty, "a transfer whose destination wallet isn't resolved locally must be skipped")
    }

    // MARK: - 7. Soft-deleted remote entry

    @MainActor
    func testPullCreatesALocallyAbsentEntryThatIsAlreadySoftDeletedRemotely() async throws {
        let walletRemoteID = UUID()
        try makeSyncedWallet(remoteID: walletRemoteID)

        entryDownloader.entries = [
            EntryDTO(
                id: UUID(), userID: userID, walletID: walletRemoteID, destinationWalletID: nil, categoryID: nil,
                amount: 20, date: .now, note: "deleted elsewhere", type: .expense, recurrence: .none,
                excludeFromBudget: false, isPlannedExpense: false, isDeleted: true, createdAt: .now, updatedAt: .now
            ),
        ]

        try await service.pullEntries(modelContext: context)

        let local = try XCTUnwrap(try context.fetch(FetchDescriptor<Entry>()).first)
        XCTAssertTrue(local.isSoftDeleted, "a remote tombstone must land as a soft-deleted local Entry, not be dropped")
    }

    @MainActor
    func testPullMarksAnExistingEntrySoftDeletedWhenTheNewerRemoteRowIsATombstone() async throws {
        let walletRemoteID = UUID()
        let wallet = try makeSyncedWallet(remoteID: walletRemoteID)

        let entryRemoteID = UUID()
        let localUpdatedAt = Date(timeIntervalSince1970: 1_000)
        let existing = TestSupport.makeEntry(amount: 30, date: .now, type: .expense, wallet: wallet)
        existing.remoteID = entryRemoteID
        existing.updatedAt = localUpdatedAt
        context.insert(existing)
        try context.save()
        XCTAssertFalse(existing.isSoftDeleted)

        entryDownloader.entries = [
            EntryDTO(
                id: entryRemoteID, userID: userID, walletID: walletRemoteID, destinationWalletID: nil,
                categoryID: nil, amount: 30, date: .now, note: "", type: .expense, recurrence: .none,
                excludeFromBudget: false, isPlannedExpense: false, isDeleted: true,
                createdAt: existing.createdAt, updatedAt: Date(timeIntervalSince1970: 2_000)
            ),
        ]

        try await service.pullEntries(modelContext: context)

        let updated = try XCTUnwrap(try context.fetch(FetchDescriptor<Entry>()).first)
        XCTAssertTrue(updated.isSoftDeleted, "a newer remote tombstone must mark the existing local Entry deleted")
    }

    // MARK: - 8. Idempotent repeated Pull

    @MainActor
    func testRunningPullTwiceWithTheSameRemoteDataIsIdempotent() async throws {
        let walletRemoteID = UUID()
        try makeSyncedWallet(remoteID: walletRemoteID)

        let entryRemoteID = UUID()
        entryDownloader.entries = [
            EntryDTO(
                id: entryRemoteID, userID: userID, walletID: walletRemoteID, destinationWalletID: nil,
                categoryID: nil, amount: 75, date: .now, note: "repeat", type: .expense, recurrence: .none,
                excludeFromBudget: false, isPlannedExpense: false, isDeleted: false,
                createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 2_000)
            ),
        ]

        try await service.pullEntries(modelContext: context)
        try await service.pullEntries(modelContext: context)

        let entries = try context.fetch(FetchDescriptor<Entry>())
        XCTAssertEqual(entries.count, 1, "a second pull of identical remote data must not create a duplicate")
        XCTAssertEqual(entries.first?.amount, 75)
    }

    // MARK: - 9. No-session failure

    @MainActor
    func testPullWithNoSessionThrowsBeforeFetchingAnything() async throws {
        userProvider.userID = nil
        entryDownloader.entries = [
            EntryDTO(
                id: UUID(), userID: userID, walletID: UUID(), destinationWalletID: nil, categoryID: nil,
                amount: 10, date: .now, note: "", type: .expense, recurrence: .none,
                excludeFromBudget: false, isPlannedExpense: false, isDeleted: false, createdAt: .now, updatedAt: .now
            ),
        ]

        do {
            try await service.pullEntries(modelContext: context)
            XCTFail("expected notAuthenticated to be thrown")
        } catch SupabaseSyncError.notAuthenticated {
            // expected
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<Entry>()).isEmpty)
    }
}
