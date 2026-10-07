import XCTest
import SwiftData
@testable import FinanceTracker

/// Phase 4D: covers `SupabaseSyncService.pullBudgets` — the remote→local merge path for the
/// `budgets` table, following exactly the same `remoteID`-matched, last-write-wins rule
/// `PullReferenceDataTests` already covers for `HeadCategory`/`Category`/`Wallet`. A separate
/// mock from the reference-data pull tests (`SupabaseBudgetDownloading` is its own protocol,
/// deliberately kept apart from `SupabaseReferenceDataDownloading`) so none of the existing
/// `pullReferenceData` tests/mocks needed to change. No network connection is used anywhere here.
private final class StubBudgetDownloader: SupabaseBudgetDownloading {
    var budgets: [BudgetDTO] = []
    func fetchBudgets(userID: UUID) async throws -> [BudgetDTO] { budgets }
}

private final class StubUserProvider: SupabaseSyncUserProviding {
    var userID: UUID?
    func currentUserID() async throws -> UUID? { userID }
}

/// A production `SupabaseReferenceDataUploading`/`SupabaseReferenceDataDownloading` conformance is
/// still required by `SupabaseSyncService.init`, even though `pullBudgets` never touches either —
/// a minimal no-op stand-in keeps these tests from needing any of the existing push/pull mocks.
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

final class PullBudgetsTests: XCTestCase {
    private var budgetDownloader: StubBudgetDownloader!
    private var userProvider: StubUserProvider!
    private var service: SupabaseSyncService!
    private var context: ModelContext!
    private let userID = UUID()

    @MainActor
    override func setUp() {
        super.setUp()
        budgetDownloader = StubBudgetDownloader()
        userProvider = StubUserProvider()
        userProvider.userID = userID
        service = SupabaseSyncService(
            uploader: UnusedUploader(),
            downloader: UnusedDownloader(),
            budgetDownloader: budgetDownloader,
            userProvider: userProvider
        )
        context = TestSupport.makeInMemoryContext()
    }

    /// Inserts and saves a `HeadCategory`/`Category` pair with the given `Category` `remoteID`, so
    /// a `BudgetDTO.categoryID` can resolve against it.
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

    // MARK: - Create (remote missing locally)

    @MainActor
    func testPullCreatesALocalBudgetThatDoesNotExistLocally() async throws {
        let categoryRemoteID = UUID()
        try makeSyncedCategory(remoteID: categoryRemoteID)

        let budgetRemoteID = UUID()
        let remoteCreatedAt = Date(timeIntervalSince1970: 1_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_000)
        budgetDownloader.budgets = [
            BudgetDTO(
                id: budgetRemoteID, userID: userID, categoryID: categoryRemoteID, monthlyLimit: 500,
                month: 3, year: 2026, isHidden: false, isFixed: true,
                createdAt: remoteCreatedAt, updatedAt: remoteUpdatedAt
            ),
        ]

        try await service.pullBudgets(modelContext: context)

        let local = try XCTUnwrap(try context.fetch(FetchDescriptor<Budget>()).first)
        XCTAssertEqual(local.remoteID, budgetRemoteID, "the remote's own id must be preserved, not a freshly minted one")
        XCTAssertEqual(local.monthlyLimit, 500)
        XCTAssertEqual(local.month, 3)
        XCTAssertEqual(local.year, 2026)
        XCTAssertTrue(local.isFixed)
        XCTAssertFalse(local.isHidden)
        XCTAssertEqual(local.category.remoteID, categoryRemoteID)
        XCTAssertEqual(local.createdAt, remoteCreatedAt)
        XCTAssertEqual(local.updatedAt, remoteUpdatedAt)
    }

    // MARK: - Update (remote newer)

    @MainActor
    func testPullUpdatesExistingBudgetWhenRemoteIsNewer() async throws {
        let categoryRemoteID = UUID()
        let category = try makeSyncedCategory(remoteID: categoryRemoteID)

        let budgetRemoteID = UUID()
        let localUpdatedAt = Date(timeIntervalSince1970: 1_000)
        let existing = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 1, year: 2026)
        existing.remoteID = budgetRemoteID
        existing.updatedAt = localUpdatedAt
        context.insert(existing)
        try context.save()

        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_000)
        budgetDownloader.budgets = [
            BudgetDTO(
                id: budgetRemoteID, userID: userID, categoryID: categoryRemoteID, monthlyLimit: 999,
                month: 6, year: 2027, isHidden: true, isFixed: true,
                createdAt: existing.createdAt, updatedAt: remoteUpdatedAt
            ),
        ]

        try await service.pullBudgets(modelContext: context)

        let budgets = try context.fetch(FetchDescriptor<Budget>())
        XCTAssertEqual(budgets.count, 1, "an update must never insert a second row")
        let updated = try XCTUnwrap(budgets.first)
        XCTAssertEqual(updated.monthlyLimit, 999)
        XCTAssertEqual(updated.month, 6)
        XCTAssertEqual(updated.year, 2027)
        XCTAssertTrue(updated.isHidden)
        XCTAssertEqual(updated.updatedAt, remoteUpdatedAt)
    }

    // MARK: - Local newer / equal (must not be overwritten)

    @MainActor
    func testPullLeavesLocalBudgetUnchangedWhenLocalIsNewer() async throws {
        let categoryRemoteID = UUID()
        let category = try makeSyncedCategory(remoteID: categoryRemoteID)

        let budgetRemoteID = UUID()
        let localUpdatedAt = Date(timeIntervalSince1970: 5_000)
        let existing = TestSupport.makeBudget(category: category, monthlyLimit: 250, month: 4, year: 2026)
        existing.remoteID = budgetRemoteID
        existing.updatedAt = localUpdatedAt
        context.insert(existing)
        try context.save()

        let remoteUpdatedAt = Date(timeIntervalSince1970: 1_000)
        budgetDownloader.budgets = [
            BudgetDTO(
                id: budgetRemoteID, userID: userID, categoryID: categoryRemoteID, monthlyLimit: 1,
                month: 1, year: 2000, isHidden: true, isFixed: true,
                createdAt: existing.createdAt, updatedAt: remoteUpdatedAt
            ),
        ]

        try await service.pullBudgets(modelContext: context)

        let updated = try XCTUnwrap(try context.fetch(FetchDescriptor<Budget>()).first)
        XCTAssertEqual(updated.monthlyLimit, 250, "a local row at least as current as the remote must never be overwritten")
        XCTAssertEqual(updated.month, 4)
        XCTAssertEqual(updated.year, 2026)
        XCTAssertEqual(updated.updatedAt, localUpdatedAt)
    }

    @MainActor
    func testPullLeavesLocalBudgetUnchangedWhenTimestampsAreEqual() async throws {
        let categoryRemoteID = UUID()
        let category = try makeSyncedCategory(remoteID: categoryRemoteID)

        let budgetRemoteID = UUID()
        let sharedUpdatedAt = Date(timeIntervalSince1970: 3_000)
        let existing = TestSupport.makeBudget(category: category, monthlyLimit: 250, month: 4, year: 2026)
        existing.remoteID = budgetRemoteID
        existing.updatedAt = sharedUpdatedAt
        context.insert(existing)
        try context.save()

        budgetDownloader.budgets = [
            BudgetDTO(
                id: budgetRemoteID, userID: userID, categoryID: categoryRemoteID, monthlyLimit: 999,
                month: 1, year: 2000, isHidden: true, isFixed: true,
                createdAt: existing.createdAt, updatedAt: sharedUpdatedAt
            ),
        ]

        try await service.pullBudgets(modelContext: context)

        let updated = try XCTUnwrap(try context.fetch(FetchDescriptor<Budget>()).first)
        XCTAssertEqual(updated.monthlyLimit, 250, "strictly-greater is required — an equal remote updatedAt must not overwrite")
    }

    // MARK: - Missing Category

    @MainActor
    func testPullSkipsABudgetWhoseCategoryHasNoLocalMatch() async throws {
        budgetDownloader.budgets = [
            BudgetDTO(
                id: UUID(), userID: userID, categoryID: UUID(), monthlyLimit: 500,
                month: 3, year: 2026, isHidden: false, isFixed: false,
                createdAt: .now, updatedAt: .now
            ),
        ]

        try await service.pullBudgets(modelContext: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<Budget>()).isEmpty, "a budget whose category isn't resolved locally must be skipped, not crash or insert with a dangling reference")
    }

    // MARK: - Idempotency

    @MainActor
    func testRunningPullTwiceWithTheSameRemoteDataIsIdempotent() async throws {
        let categoryRemoteID = UUID()
        try makeSyncedCategory(remoteID: categoryRemoteID)

        let budgetRemoteID = UUID()
        budgetDownloader.budgets = [
            BudgetDTO(
                id: budgetRemoteID, userID: userID, categoryID: categoryRemoteID, monthlyLimit: 500,
                month: 3, year: 2026, isHidden: false, isFixed: true,
                createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 2_000)
            ),
        ]

        try await service.pullBudgets(modelContext: context)
        try await service.pullBudgets(modelContext: context)

        let budgets = try context.fetch(FetchDescriptor<Budget>())
        XCTAssertEqual(budgets.count, 1, "a second pull of identical remote data must not create a duplicate")
        XCTAssertEqual(budgets.first?.monthlyLimit, 500)
    }

    // MARK: - No session

    @MainActor
    func testPullWithNoSessionThrowsBeforeFetchingAnything() async throws {
        userProvider.userID = nil
        budgetDownloader.budgets = [
            BudgetDTO(
                id: UUID(), userID: userID, categoryID: UUID(), monthlyLimit: 500,
                month: 3, year: 2026, isHidden: false, isFixed: false,
                createdAt: .now, updatedAt: .now
            ),
        ]

        do {
            try await service.pullBudgets(modelContext: context)
            XCTFail("expected notAuthenticated to be thrown")
        } catch SupabaseSyncError.notAuthenticated {
            // expected
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<Budget>()).isEmpty)
    }
}
