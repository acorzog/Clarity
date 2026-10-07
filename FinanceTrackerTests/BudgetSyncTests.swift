import XCTest
import SwiftData
@testable import FinanceTracker

/// Phase 3C: covers `BudgetDTO`'s mapping and `SupabaseSyncService.syncBudgets`. A separate file
/// from `SupabaseSyncServiceTests`/`EntrySyncTests`, with its own small mock uploader, mirroring
/// how each phase's sync tests have stayed self-contained. No network connection is used anywhere
/// here.
private final class MockBudgetUploader: SupabaseReferenceDataUploading {
    private(set) var headCategoryBatches: [[HeadCategoryDTO]] = []
    private(set) var categoryBatches: [[CategoryDTO]] = []
    private(set) var walletBatches: [[WalletDTO]] = []
    private(set) var entryBatches: [[EntryDTO]] = []

    /// One entry per `upsertBudgets` call — used to assert the batch call count (exactly one per
    /// `syncBudgets` run) and each call's full DTO payload.
    private(set) var budgetBatches: [[BudgetDTO]] = []
    var budgetsBatchError: Error?

    func upsertHeadCategory(_ dto: HeadCategoryDTO) async throws {}
    func upsertCategory(_ dto: CategoryDTO) async throws {}
    func upsertWallet(_ dto: WalletDTO) async throws {}
    func upsertHeadCategories(_ dtos: [HeadCategoryDTO]) async throws { headCategoryBatches.append(dtos) }
    func upsertCategories(_ dtos: [CategoryDTO]) async throws { categoryBatches.append(dtos) }
    func upsertWallets(_ dtos: [WalletDTO]) async throws { walletBatches.append(dtos) }
    func upsertEntries(_ dtos: [EntryDTO]) async throws { entryBatches.append(dtos) }

    func upsertBudgets(_ dtos: [BudgetDTO]) async throws {
        if let error = budgetsBatchError { throw error }
        budgetBatches.append(dtos)
    }
}

private struct StubError: Error, Equatable {}

private final class MockBudgetSyncUserProvider: SupabaseSyncUserProviding {
    var userID: UUID?
    func currentUserID() async throws -> UUID? { userID }
}

final class BudgetSyncTests: XCTestCase {
    private var uploader: MockBudgetUploader!
    private var userProvider: MockBudgetSyncUserProvider!
    private var service: SupabaseSyncService!
    private var context: ModelContext!
    private let userID = UUID()

    @MainActor
    override func setUp() {
        super.setUp()
        uploader = MockBudgetUploader()
        userProvider = MockBudgetSyncUserProvider()
        userProvider.userID = userID
        service = SupabaseSyncService(uploader: uploader, userProvider: userProvider)
        context = TestSupport.makeInMemoryContext()
    }

    // MARK: - A. BudgetDTO mapping

    func testBudgetDTOMappingPreservesAllFields() {
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 350, month: 6, year: 2026, isHidden: true, isFixed: true)
        let remoteID = UUID()
        let categoryRemoteID = UUID()

        let dto = BudgetDTO(budget: budget, remoteID: remoteID, categoryRemoteID: categoryRemoteID, userID: userID)

        XCTAssertEqual(dto.id, remoteID)
        XCTAssertEqual(dto.userID, userID)
        XCTAssertEqual(dto.categoryID, categoryRemoteID)
        XCTAssertEqual(dto.monthlyLimit, 350)
        XCTAssertEqual(dto.month, 6)
        XCTAssertEqual(dto.year, 2026)
        XCTAssertEqual(dto.isHidden, true)
        XCTAssertEqual(dto.isFixed, true)
        XCTAssertEqual(dto.createdAt, budget.createdAt)
        XCTAssertEqual(dto.updatedAt, budget.updatedAt)
    }

    /// Confirms the `CodingKeys` actually produce the `snake_case` column names the Postgres
    /// `budgets` schema expects — a mismatched key here would silently fail an upsert. Encoded as
    /// a `[BudgetDTO]` array (the batch wire shape `syncBudgets` always sends).
    func testBudgetDTOBatchEncodesExpectedSnakeCaseKeys() throws {
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 1, year: 2026)
        let dto = BudgetDTO(budget: budget, remoteID: UUID(), categoryRemoteID: UUID(), userID: userID)

        let data = try JSONEncoder().encode([dto])
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]]).first!

        for key in ["id", "user_id", "category_id", "monthly_limit", "month", "year", "is_hidden", "is_fixed", "created_at", "updated_at"] {
            XCTAssertNotNil(json[key], "missing expected column key: \(key)")
        }
    }

    // MARK: - B. syncBudgets

    @MainActor
    func testSyncBudgetsWithNoSessionThrowsBeforeUploadingAnything() async throws {
        userProvider.userID = nil
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 50, month: 1, year: 2026)
        context.insert(budget)
        try context.save()

        do {
            try await service.syncBudgets(modelContext: context)
            XCTFail("expected notAuthenticated to be thrown")
        } catch SupabaseSyncError.notAuthenticated {
            // expected
        }
        XCTAssertTrue(uploader.budgetBatches.isEmpty)
    }

    @MainActor
    func testSyncBudgetsWithNoLocalBudgetsPerformsNoUploadCall() async throws {
        try await service.syncBudgets(modelContext: context)

        XCTAssertTrue(uploader.budgetBatches.isEmpty)
    }

    @MainActor
    func testAllBudgetsUploadInOneBatch() async throws {
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let categories = (0..<3).map { TestSupport.makeCategory(name: "Category \($0)", headCategory: head) }
        categories.forEach(context.insert)
        let budgets = categories.map { TestSupport.makeBudget(category: $0, monthlyLimit: 100, month: 1, year: 2026) }
        budgets.forEach(context.insert)
        try context.save()

        try await service.syncBudgets(modelContext: context)

        XCTAssertEqual(uploader.budgetBatches.count, 1, "exactly one upsertBudgets call regardless of row count")
        XCTAssertEqual(uploader.budgetBatches.first?.count, 3)
    }

    @MainActor
    func testSyncBudgetsMintsRemoteIDsForBudgetAndItsCategory() async throws {
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 50, month: 1, year: 2026)
        context.insert(budget)
        try context.save()
        XCTAssertNil(budget.remoteID)
        XCTAssertNil(category.remoteID)

        try await service.syncBudgets(modelContext: context)

        XCTAssertNotNil(budget.remoteID)
        XCTAssertNotNil(category.remoteID, "syncBudgets must resolve its own category's remoteID even if that category was never previously synced")
        XCTAssertEqual(uploader.budgetBatches.first?.first?.categoryID, category.remoteID)
    }

    @MainActor
    func testSyncBudgetsReusesExistingRemoteID() async throws {
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        category.remoteID = UUID()
        context.insert(category)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 50, month: 1, year: 2026)
        let existingID = UUID()
        budget.remoteID = existingID
        context.insert(budget)
        try context.save()

        try await service.syncBudgets(modelContext: context)

        XCTAssertEqual(budget.remoteID, existingID)
        XCTAssertEqual(uploader.budgetBatches.first?.first?.id, existingID)
    }

    @MainActor
    func testSyncBudgetsIsSafeToRunRepeatedly() async throws {
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 50, month: 1, year: 2026)
        context.insert(budget)
        try context.save()

        try await service.syncBudgets(modelContext: context)
        let idAfterFirst = budget.remoteID

        try await service.syncBudgets(modelContext: context)

        XCTAssertEqual(budget.remoteID, idAfterFirst)
        XCTAssertEqual(uploader.budgetBatches.count, 2)
        XCTAssertEqual(uploader.budgetBatches[0].map(\.id), uploader.budgetBatches[1].map(\.id))
    }

    // MARK: - B2. Phase 4G.1 — batched ensureRemoteID saves are still durable

    /// `syncBudgets` now mints every missing `Budget`/`Category` remoteID without saving, then
    /// commits once at the end rather than once per row — the behavioral guarantee that matters
    /// is that the minted id is still durable by the time this method returns, proven by reading
    /// it back from a second, independent `ModelContext` on the same store.
    @MainActor
    func testSyncBudgetsPersistsMintedRemoteIDImmediatelyAcrossAFreshContext() async throws {
        let container = TestSupport.makeInMemoryContainer()
        let writingContext = ModelContext(container)
        let head = TestSupport.makeHeadCategory()
        writingContext.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        writingContext.insert(category)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 50, month: 1, year: 2026)
        writingContext.insert(budget)
        try writingContext.save()

        try await service.syncBudgets(modelContext: writingContext)
        let mintedID = try XCTUnwrap(budget.remoteID)

        let freshContext = ModelContext(container)
        let freshBudget = try XCTUnwrap(try freshContext.fetch(FetchDescriptor<Budget>()).first)
        XCTAssertEqual(freshBudget.remoteID, mintedID, "a fresh context on the same store must already see the minted Budget remoteID")
    }

    /// Repeated-sync idempotency from a second, independent context on the same store.
    @MainActor
    func testSyncBudgetsDoesNotRemintOnASecondRunFromAFreshContext() async throws {
        let container = TestSupport.makeInMemoryContainer()
        let firstContext = ModelContext(container)
        let head = TestSupport.makeHeadCategory()
        firstContext.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        firstContext.insert(category)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 50, month: 1, year: 2026)
        firstContext.insert(budget)
        try firstContext.save()

        try await service.syncBudgets(modelContext: firstContext)
        let mintedID = try XCTUnwrap(budget.remoteID)

        let secondContext = ModelContext(container)
        try await service.syncBudgets(modelContext: secondContext)

        let budgetFromSecondContext = try XCTUnwrap(try secondContext.fetch(FetchDescriptor<Budget>()).first)
        XCTAssertEqual(budgetFromSecondContext.remoteID, mintedID, "a second run against a fresh context on the same store must reuse the already-minted remoteID")
        XCTAssertEqual(uploader.budgetBatches.count, 2)
        XCTAssertEqual(uploader.budgetBatches[0].map(\.id), uploader.budgetBatches[1].map(\.id))
    }

    // MARK: - C. Phase 4G.6 — natural-key duplicate reconciliation (the exact 23505 scenario)

    /// Reproduces the exact production failure: two local `Budget` objects for the same
    /// `Category`/month/year, one already synced (has a `remoteID`) and one not — e.g. because
    /// `pullBudgets` inserted a remote row as a brand-new local object alongside a pre-existing,
    /// never-synced local `Budget` for the same natural key (it only ever merges by `remoteID`,
    /// never by category/month/year). Before this fix, `syncBudgets` would mint the second
    /// `Budget` its own new `remoteID` and upload it as a distinct row, which Postgres rejects
    /// with 23505 on `budgets_user_id_category_id_month_year_key`. Now exactly one `BudgetDTO` is
    /// built, reusing the already-synced `remoteID` — never two different ids for the same
    /// natural key.
    @MainActor
    func testDuplicateNaturalKeyBudgetsReconcileToASingleUploadReusingTheExistingRemoteID() async throws {
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        category.remoteID = UUID()
        context.insert(category)

        let alreadySynced = TestSupport.makeBudget(category: category, monthlyLimit: 200, month: 6, year: 2026)
        let existingRemoteID = UUID()
        alreadySynced.remoteID = existingRemoteID
        alreadySynced.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(alreadySynced)

        // The never-synced duplicate — same category/month/year, no remoteID, as if it had been
        // created locally (or pulled in as a brand-new object) independently of `alreadySynced`.
        let neverSynced = TestSupport.makeBudget(category: category, monthlyLimit: 200, month: 6, year: 2026)
        neverSynced.updatedAt = Date(timeIntervalSince1970: 1_600_000_000)
        context.insert(neverSynced)
        try context.save()

        try await service.syncBudgets(modelContext: context)

        let batch = try XCTUnwrap(uploader.budgetBatches.first)
        XCTAssertEqual(uploader.budgetBatches.count, 1, "exactly one upsertBudgets call")
        XCTAssertEqual(batch.count, 1, "the two natural-key duplicates must reconcile into exactly one uploaded row, never two")
        XCTAssertEqual(batch.first?.id, existingRemoteID, "the already-synced remoteID must win — never replaced by a freshly minted one")

        let remaining = try context.fetch(FetchDescriptor<Budget>())
        XCTAssertEqual(remaining.count, 1, "the duplicate must actually be removed from the local store, not just excluded from this one upload")
    }

    /// LWW must still apply across the reconciliation: even though the already-synced `Budget`
    /// wins the surviving *identity* (its `remoteID`), the *field values* that get uploaded must
    /// come from whichever duplicate was updated most recently — here, the never-synced one.
    @MainActor
    func testDuplicateReconciliationPreservesLastWriteWinsFieldValues() async throws {
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        category.remoteID = UUID()
        context.insert(category)

        let alreadySynced = TestSupport.makeBudget(category: category, monthlyLimit: 200, month: 6, year: 2026, isHidden: false, isFixed: false)
        alreadySynced.remoteID = UUID()
        alreadySynced.updatedAt = Date(timeIntervalSince1970: 1_600_000_000) // older
        context.insert(alreadySynced)

        let newerDuplicate = TestSupport.makeBudget(category: category, monthlyLimit: 350, month: 6, year: 2026, isHidden: true, isFixed: true)
        newerDuplicate.updatedAt = Date(timeIntervalSince1970: 1_700_000_000) // newer — must win the field values
        context.insert(newerDuplicate)
        try context.save()

        try await service.syncBudgets(modelContext: context)

        let batch = try XCTUnwrap(uploader.budgetBatches.first)
        XCTAssertEqual(batch.count, 1)
        let uploaded = try XCTUnwrap(batch.first)
        XCTAssertEqual(uploaded.id, alreadySynced.remoteID, "surviving identity still comes from the already-synced duplicate")
        XCTAssertEqual(uploaded.monthlyLimit, 350, "field values must come from whichever duplicate is most recently updated")
        XCTAssertEqual(uploaded.isHidden, true)
        XCTAssertEqual(uploaded.isFixed, true)
    }

    /// Budgets for the same `Category` but *different* months/years are legitimately distinct —
    /// reconciliation must never collapse them.
    @MainActor
    func testBudgetsForDifferentMonthsAreNotTreatedAsDuplicates() async throws {
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)
        let january = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 1, year: 2026)
        let february = TestSupport.makeBudget(category: category, monthlyLimit: 150, month: 2, year: 2026)
        context.insert(january)
        context.insert(february)
        try context.save()

        try await service.syncBudgets(modelContext: context)

        let batch = try XCTUnwrap(uploader.budgetBatches.first)
        XCTAssertEqual(batch.count, 2, "distinct months must never be reconciled away")
    }

    /// Three (not just two) local duplicates for the same natural key must still collapse into
    /// exactly one uploaded row.
    @MainActor
    func testThreeWayNaturalKeyDuplicateStillReconcilesToOne() async throws {
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)

        let synced = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 3, year: 2026)
        synced.remoteID = UUID()
        context.insert(synced)
        let dup1 = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 3, year: 2026)
        context.insert(dup1)
        let dup2 = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 3, year: 2026)
        context.insert(dup2)
        try context.save()

        try await service.syncBudgets(modelContext: context)

        let batch = try XCTUnwrap(uploader.budgetBatches.first)
        XCTAssertEqual(batch.count, 1)
        let remaining = try context.fetch(FetchDescriptor<Budget>())
        XCTAssertEqual(remaining.count, 1)
    }

    @MainActor
    func testSyncBudgetsBatchFailurePropagates() async throws {
        uploader.budgetsBatchError = StubError()
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 50, month: 1, year: 2026)
        context.insert(budget)
        try context.save()

        do {
            try await service.syncBudgets(modelContext: context)
            XCTFail("expected the batch error to propagate")
        } catch is StubError {
            // expected
        }
    }
}
