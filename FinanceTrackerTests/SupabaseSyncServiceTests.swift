import XCTest
import SwiftData
@testable import FinanceTracker

/// A no-network stand-in for `SupabasePostgRESTUploader` — records every upserted DTO, both
/// single-row and batch, plus the order calls arrive in across all three tables, so tests can
/// assert on exactly what would have been sent to Supabase without a real connection. Each batch
/// method can also be configured to throw, to test failure propagation between dependency stages.
private final class MockSupabaseUploader: SupabaseReferenceDataUploading {
    private(set) var headCategoryUploads: [HeadCategoryDTO] = []
    private(set) var categoryUploads: [CategoryDTO] = []
    private(set) var walletUploads: [WalletDTO] = []

    /// One entry per batch call — e.g. two `syncReferenceData` runs produce two entries here, each
    /// holding that run's full set of DTOs.
    private(set) var headCategoryBatches: [[HeadCategoryDTO]] = []
    private(set) var categoryBatches: [[CategoryDTO]] = []
    private(set) var walletBatches: [[WalletDTO]] = []

    /// One entry per upload call — single-row or batch — across all three tables, in the exact
    /// order they happened. Used to assert dependency ordering.
    private(set) var callOrder: [String] = []

    var headCategoriesBatchError: Error?
    var categoriesBatchError: Error?
    var walletsBatchError: Error?

    func upsertHeadCategory(_ dto: HeadCategoryDTO) async throws {
        headCategoryUploads.append(dto)
        callOrder.append("headCategory:\(dto.id)")
    }

    func upsertCategory(_ dto: CategoryDTO) async throws {
        categoryUploads.append(dto)
        callOrder.append("category:\(dto.id)")
    }

    func upsertWallet(_ dto: WalletDTO) async throws {
        walletUploads.append(dto)
        callOrder.append("wallet:\(dto.id)")
    }

    func upsertHeadCategories(_ dtos: [HeadCategoryDTO]) async throws {
        callOrder.append("headCategoriesBatch:\(dtos.count)")
        if let error = headCategoriesBatchError { throw error }
        headCategoryBatches.append(dtos)
    }

    func upsertCategories(_ dtos: [CategoryDTO]) async throws {
        callOrder.append("categoriesBatch:\(dtos.count)")
        if let error = categoriesBatchError { throw error }
        categoryBatches.append(dtos)
    }

    func upsertWallets(_ dtos: [WalletDTO]) async throws {
        callOrder.append("walletsBatch:\(dtos.count)")
        if let error = walletsBatchError { throw error }
        walletBatches.append(dtos)
    }

    /// Entry sync (Phase 3B-2) isn't exercised by this file's tests (see `EntrySyncTests.swift`
    /// instead) — required only to satisfy `SupabaseReferenceDataUploading` conformance.
    func upsertEntries(_ dtos: [EntryDTO]) async throws {
        callOrder.append("entriesBatch:\(dtos.count)")
    }

    /// Budget sync (Phase 3C) isn't exercised by this file's tests (see `BudgetSyncTests.swift`
    /// instead) — required only to satisfy `SupabaseReferenceDataUploading` conformance.
    func upsertBudgets(_ dtos: [BudgetDTO]) async throws {
        callOrder.append("budgetsBatch:\(dtos.count)")
    }
}

private final class MockSupabaseUserProvider: SupabaseSyncUserProviding {
    var userID: UUID?
    /// Counts calls so tests can confirm `requireUserID()` is resolved exactly once per
    /// `syncReferenceData` run, not once per record.
    private(set) var callCount = 0

    func currentUserID() async throws -> UUID? {
        callCount += 1
        return userID
    }
}

private struct StubError: Error, Equatable {}

final class SupabaseSyncServiceTests: XCTestCase {
    private var uploader: MockSupabaseUploader!
    private var userProvider: MockSupabaseUserProvider!
    private var service: SupabaseSyncService!
    private var context: ModelContext!
    private let userID = UUID()

    @MainActor
    override func setUp() {
        super.setUp()
        uploader = MockSupabaseUploader()
        userProvider = MockSupabaseUserProvider()
        userProvider.userID = userID
        service = SupabaseSyncService(uploader: uploader, userProvider: userProvider)
        context = TestSupport.makeInMemoryContext()
    }

    // MARK: - 1. No authenticated user → throws before any upload

    @MainActor
    func testSyncReferenceDataWithNoSessionThrowsBeforeUploadingAnything() async throws {
        userProvider.userID = nil
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        try context.save()

        await XCTAssertThrowsErrorAsync(try await service.syncReferenceData(modelContext: context)) { error in
            XCTAssertEqual(error as? SupabaseSyncError, .notAuthenticated)
        }
        XCTAssertTrue(uploader.callOrder.isEmpty, "nothing should be uploaded when there's no session")
    }

    @MainActor
    func testSyncingASingleModelWithNoSessionThrowsRatherThanCrashing() async throws {
        userProvider.userID = nil
        let head = TestSupport.makeHeadCategory()
        context.insert(head)

        do {
            try await service.syncHeadCategory(head, modelContext: context)
            XCTFail("expected notAuthenticated to be thrown")
        } catch SupabaseSyncError.notAuthenticated {
            // expected
        }
    }

    // MARK: - 2. Empty reference data → completes without unnecessary network calls

    @MainActor
    func testSyncReferenceDataWithNoLocalDataPerformsNoUploadCalls() async throws {
        try await service.syncReferenceData(modelContext: context)

        XCTAssertTrue(uploader.callOrder.isEmpty, "an empty store must not send any batch request")
        XCTAssertEqual(userProvider.callCount, 1, "the user id is still resolved once, even with nothing to upload")
    }

    // MARK: - 3/4/5. Each table uploads as exactly one batch

    @MainActor
    func testAllHeadCategoriesUploadInOneBatch() async throws {
        let heads = (0..<3).map { TestSupport.makeHeadCategory(name: "Head \($0)") }
        heads.forEach(context.insert)
        try context.save()

        try await service.syncReferenceData(modelContext: context)

        XCTAssertEqual(uploader.headCategoryBatches.count, 1)
        XCTAssertEqual(uploader.headCategoryBatches[0].count, 3)
    }

    @MainActor
    func testAllCategoriesUploadInOneBatch() async throws {
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let categories = (0..<4).map { TestSupport.makeCategory(name: "Category \($0)", headCategory: head) }
        categories.forEach(context.insert)
        try context.save()

        try await service.syncReferenceData(modelContext: context)

        XCTAssertEqual(uploader.categoryBatches.count, 1)
        XCTAssertEqual(uploader.categoryBatches[0].count, 4)
    }

    @MainActor
    func testAllWalletsUploadInOneBatch() async throws {
        let wallets = (0..<5).map { TestSupport.makeWallet(name: "Wallet \($0)") }
        wallets.forEach(context.insert)
        try context.save()

        try await service.syncReferenceData(modelContext: context)

        XCTAssertEqual(uploader.walletBatches.count, 1)
        XCTAssertEqual(uploader.walletBatches[0].count, 5)
    }

    /// The exact regression this phase fixes: Phase 2C found ~90 local rows producing hundreds of
    /// sequential network calls. With batching, the same shape of data (several categories sharing
    /// a head category, plus wallets) must produce exactly 3 upload calls total.
    @MainActor
    func testRealisticDatasetProducesExactlyThreeUploadCalls() async throws {
        let heads = (0..<3).map { TestSupport.makeHeadCategory(name: "Head \($0)") }
        heads.forEach(context.insert)
        let categories = (0..<10).map { TestSupport.makeCategory(name: "Category \($0)", headCategory: heads[$0 % heads.count]) }
        categories.forEach(context.insert)
        let wallets = (0..<4).map { TestSupport.makeWallet(name: "Wallet \($0)") }
        wallets.forEach(context.insert)
        try context.save()

        try await service.syncReferenceData(modelContext: context)

        XCTAssertEqual(uploader.callOrder.count, 3, "exactly one request per table, regardless of row count")
    }

    // MARK: - 6. Upload order is HeadCategories → Categories → Wallets

    @MainActor
    func testSyncReferenceDataUploadsBatchesInDependencyOrder() async throws {
        let head = TestSupport.makeHeadCategory(name: "Everyday")
        context.insert(head)
        let category = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        context.insert(category)
        let wallet = TestSupport.makeWallet(name: "Spending")
        context.insert(wallet)
        try context.save()

        try await service.syncReferenceData(modelContext: context)

        XCTAssertEqual(uploader.callOrder, [
            "headCategoriesBatch:1",
            "categoriesBatch:1",
            "walletsBatch:1",
        ])
    }

    // MARK: - 7. Category DTOs reference the correct HeadCategory remoteIDs

    @MainActor
    func testCategoryDTOsReferenceTheCorrectParentHeadCategoryRemoteID() async throws {
        let headA = TestSupport.makeHeadCategory(name: "A")
        let headB = TestSupport.makeHeadCategory(name: "B")
        context.insert(headA)
        context.insert(headB)
        let categoryA = TestSupport.makeCategory(name: "Under A", headCategory: headA)
        let categoryB = TestSupport.makeCategory(name: "Under B", headCategory: headB)
        context.insert(categoryA)
        context.insert(categoryB)
        try context.save()

        try await service.syncReferenceData(modelContext: context)

        let dtoA = try XCTUnwrap(uploader.categoryBatches[0].first { $0.id == categoryA.remoteID })
        let dtoB = try XCTUnwrap(uploader.categoryBatches[0].first { $0.id == categoryB.remoteID })
        XCTAssertEqual(dtoA.headCategoryID, headA.remoteID)
        XCTAssertEqual(dtoB.headCategoryID, headB.remoteID)
        XCTAssertNotEqual(dtoA.headCategoryID, dtoB.headCategoryID)
    }

    /// `syncReferenceData` must never call `syncHeadCategory` once per category — only the one
    /// batch request for the HeadCategories table, regardless of how many categories share it.
    @MainActor
    func testSyncReferenceDataNeverCallsSingleRowHeadCategoryUploadForCategories() async throws {
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let categories = (0..<6).map { TestSupport.makeCategory(name: "Category \($0)", headCategory: head) }
        categories.forEach(context.insert)
        try context.save()

        try await service.syncReferenceData(modelContext: context)

        XCTAssertTrue(uploader.headCategoryUploads.isEmpty, "no single-row head-category upload must happen during a batch sync")
        XCTAssertEqual(uploader.headCategoryBatches.count, 1)
        XCTAssertEqual(uploader.headCategoryBatches[0].count, 1, "one unique head category, uploaded exactly once despite 6 categories referencing it")
    }

    // MARK: - 8. remoteID generated once and reused

    @MainActor
    func testSyncReferenceDataMintsRemoteIDsForEveryModel() async throws {
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        try context.save()

        XCTAssertNil(head.remoteID)
        XCTAssertNil(category.remoteID)
        XCTAssertNil(wallet.remoteID)

        try await service.syncReferenceData(modelContext: context)

        XCTAssertNotNil(head.remoteID)
        XCTAssertNotNil(category.remoteID)
        XCTAssertNotNil(wallet.remoteID)
    }

    @MainActor
    func testSyncReferenceDataReusesAnAlreadyAssignedRemoteID() async throws {
        let head = TestSupport.makeHeadCategory()
        let existingID = UUID()
        head.remoteID = existingID
        context.insert(head)
        try context.save()

        try await service.syncReferenceData(modelContext: context)

        XCTAssertEqual(head.remoteID, existingID)
        XCTAssertEqual(uploader.headCategoryBatches[0].first?.id, existingID)
    }

    // MARK: - 9. Re-running sync performs the same three batch upserts without creating new IDs

    @MainActor
    func testSyncReferenceDataIsSafeToRunRepeatedly() async throws {
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        try context.save()

        try await service.syncReferenceData(modelContext: context)
        let headIDAfterFirst = head.remoteID
        let categoryIDAfterFirst = category.remoteID
        let walletIDAfterFirst = wallet.remoteID

        try await service.syncReferenceData(modelContext: context)

        XCTAssertEqual(head.remoteID, headIDAfterFirst)
        XCTAssertEqual(category.remoteID, categoryIDAfterFirst)
        XCTAssertEqual(wallet.remoteID, walletIDAfterFirst)

        // Each run is exactly 3 batch requests, so two runs are exactly 6 — never a 4th
        // head-category batch, never a second identity minted.
        XCTAssertEqual(uploader.headCategoryBatches.count, 2)
        XCTAssertEqual(uploader.categoryBatches.count, 2)
        XCTAssertEqual(uploader.walletBatches.count, 2)
        XCTAssertEqual(uploader.headCategoryBatches[0].map(\.id), uploader.headCategoryBatches[1].map(\.id))
        XCTAssertEqual(uploader.categoryBatches[0].map(\.id), uploader.categoryBatches[1].map(\.id))
        XCTAssertEqual(uploader.walletBatches[0].map(\.id), uploader.walletBatches[1].map(\.id))
    }

    // MARK: - 9b. Phase 4G.1 — batched ensureRemoteID saves are still durable

    /// The behavioral guarantee that matters after batching `ensureRemoteID`'s saves (one commit
    /// per table instead of one per row, Phase 4G.1): every minted `remoteID` must still be
    /// durable by the time `syncReferenceData` returns, not merely held in this call's in-memory
    /// context. Proven the same way `SeedDataTests` proves seed persistence — mint on one
    /// `ModelContext`, then read back from a *second*, independent `ModelContext` opened against
    /// the same underlying store, which can only see what was actually saved.
    @MainActor
    func testSyncReferenceDataPersistsMintedRemoteIDsImmediatelyAcrossAFreshContext() async throws {
        let container = TestSupport.makeInMemoryContainer()
        let writingContext = ModelContext(container)
        let head = TestSupport.makeHeadCategory(name: "Head")
        writingContext.insert(head)
        let category = TestSupport.makeCategory(name: "Category", headCategory: head)
        writingContext.insert(category)
        let wallet = TestSupport.makeWallet(name: "Wallet")
        writingContext.insert(wallet)
        try writingContext.save()

        try await service.syncReferenceData(modelContext: writingContext)
        let mintedHeadID = try XCTUnwrap(head.remoteID)
        let mintedCategoryID = try XCTUnwrap(category.remoteID)
        let mintedWalletID = try XCTUnwrap(wallet.remoteID)

        let freshContext = ModelContext(container)
        let freshHead = try XCTUnwrap(try freshContext.fetch(FetchDescriptor<HeadCategory>()).first)
        let freshCategory = try XCTUnwrap(try freshContext.fetch(FetchDescriptor<FinanceTracker.Category>()).first)
        let freshWallet = try XCTUnwrap(try freshContext.fetch(FetchDescriptor<Wallet>()).first)
        XCTAssertEqual(freshHead.remoteID, mintedHeadID, "a fresh context on the same store must already see the minted HeadCategory remoteID")
        XCTAssertEqual(freshCategory.remoteID, mintedCategoryID, "a fresh context on the same store must already see the minted Category remoteID")
        XCTAssertEqual(freshWallet.remoteID, mintedWalletID, "a fresh context on the same store must already see the minted Wallet remoteID")
    }

    /// Repeated-sync idempotency, specifically from a *second, independent* context on the same
    /// store (not just the same in-memory objects the first call already mutated) — the identity
    /// semantics `testSyncReferenceDataIsSafeToRunRepeatedly` proves within one context must hold
    /// just as well once persistence is involved.
    @MainActor
    func testSyncReferenceDataDoesNotRemintRemoteIDsOnASecondRunFromAFreshContext() async throws {
        let container = TestSupport.makeInMemoryContainer()
        let firstContext = ModelContext(container)
        let head = TestSupport.makeHeadCategory()
        firstContext.insert(head)
        try firstContext.save()

        try await service.syncReferenceData(modelContext: firstContext)
        let mintedID = try XCTUnwrap(head.remoteID)

        let secondContext = ModelContext(container)
        try await service.syncReferenceData(modelContext: secondContext)

        let headFromSecondContext = try XCTUnwrap(try secondContext.fetch(FetchDescriptor<HeadCategory>()).first)
        XCTAssertEqual(headFromSecondContext.remoteID, mintedID, "a second run against a fresh context on the same store must reuse the already-minted remoteID, never mint a second one")
        XCTAssertEqual(uploader.headCategoryBatches.count, 2)
        XCTAssertEqual(uploader.headCategoryBatches[0].map(\.id), uploader.headCategoryBatches[1].map(\.id))
    }

    // MARK: - 10/11/12. Batch failures propagate and block downstream batches

    @MainActor
    func testHeadCategoryBatchFailurePreventsCategoryAndWalletBatches() async throws {
        uploader.headCategoriesBatchError = StubError()
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        try context.save()

        await XCTAssertThrowsErrorAsync(try await service.syncReferenceData(modelContext: context)) { error in
            XCTAssertEqual(error as? StubError, StubError())
        }

        XCTAssertTrue(uploader.categoryBatches.isEmpty, "a failed HeadCategories batch must prevent the Categories batch")
        XCTAssertTrue(uploader.walletBatches.isEmpty, "a failed HeadCategories batch must prevent the Wallets batch")
    }

    @MainActor
    func testCategoryBatchFailurePreventsWalletBatch() async throws {
        uploader.categoriesBatchError = StubError()
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        try context.save()

        await XCTAssertThrowsErrorAsync(try await service.syncReferenceData(modelContext: context)) { error in
            XCTAssertEqual(error as? StubError, StubError())
        }

        XCTAssertEqual(uploader.headCategoryBatches.count, 1, "HeadCategories must still have succeeded before Categories failed")
        XCTAssertTrue(uploader.walletBatches.isEmpty, "a failed Categories batch must prevent the Wallets batch")
    }

    @MainActor
    func testWalletBatchFailurePropagates() async throws {
        uploader.walletsBatchError = StubError()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        try context.save()

        await XCTAssertThrowsErrorAsync(try await service.syncReferenceData(modelContext: context)) { error in
            XCTAssertEqual(error as? StubError, StubError())
        }
    }

    // MARK: - 13. DTO mapping preserves every relevant field

    func testHeadCategoryDTOMappingPreservesAllFields() {
        let head = HeadCategory(name: "Housing", icon: "house.fill", colorHex: "#F59E0B", sortOrder: 3)
        let remoteID = UUID()
        let dto = HeadCategoryDTO(headCategory: head, remoteID: remoteID, userID: userID)

        XCTAssertEqual(dto.id, remoteID)
        XCTAssertEqual(dto.userID, userID)
        XCTAssertEqual(dto.name, "Housing")
        XCTAssertEqual(dto.icon, "house.fill")
        XCTAssertEqual(dto.colorHex, "#F59E0B")
        XCTAssertEqual(dto.sortOrder, 3)
        XCTAssertEqual(dto.createdAt, head.createdAt)
        XCTAssertEqual(dto.updatedAt, head.updatedAt)
    }

    func testCategoryDTOMappingPreservesAllFields() {
        let head = HeadCategory(name: "Everyday", icon: "folder.fill", colorHex: "#FFFFFF")
        let category = FinanceTracker.Category(
            name: "Groceries", customIcon: "cart.fill", iconIsEmoji: false, customColorHex: "#22C55E",
            isSavings: true, isArchived: false, isIncome: false, isFixedPlannedCategory: true, headCategory: head
        )
        let remoteID = UUID()
        let headRemoteID = UUID()
        let dto = CategoryDTO(category: category, remoteID: remoteID, headCategoryRemoteID: headRemoteID, userID: userID)

        XCTAssertEqual(dto.id, remoteID)
        XCTAssertEqual(dto.userID, userID)
        XCTAssertEqual(dto.headCategoryID, headRemoteID)
        XCTAssertEqual(dto.name, "Groceries")
        XCTAssertEqual(dto.customIcon, "cart.fill")
        XCTAssertEqual(dto.iconIsEmoji, false)
        XCTAssertEqual(dto.customColorHex, "#22C55E")
        XCTAssertEqual(dto.isSavings, true)
        XCTAssertEqual(dto.isArchived, false)
        XCTAssertEqual(dto.isIncome, false)
        XCTAssertEqual(dto.isFixedPlannedCategory, true)
        XCTAssertEqual(dto.createdAt, category.createdAt)
        XCTAssertEqual(dto.updatedAt, category.updatedAt)
    }

    func testWalletDTOMappingPreservesAllFields() {
        let wallet = Wallet(
            name: "Savings", type: .savings, colorHex: "#0EA5E9", icon: "banknote.fill",
            startingBalance: 1234.56, goalAmount: 5000, includeInNetWorth: true,
            isDefault: true, isArchived: false, sortOrder: 2
        )
        let remoteID = UUID()
        let dto = WalletDTO(wallet: wallet, remoteID: remoteID, userID: userID)

        XCTAssertEqual(dto.id, remoteID)
        XCTAssertEqual(dto.userID, userID)
        XCTAssertEqual(dto.name, "Savings")
        XCTAssertEqual(dto.type, .savings)
        XCTAssertEqual(dto.colorHex, "#0EA5E9")
        XCTAssertEqual(dto.icon, "banknote.fill")
        XCTAssertEqual(dto.startingBalance, 1234.56)
        XCTAssertEqual(dto.goalAmount, 5000)
        XCTAssertEqual(dto.includeInNetWorth, true)
        XCTAssertEqual(dto.isDefault, true)
        XCTAssertEqual(dto.isArchived, false)
        XCTAssertEqual(dto.sortOrder, 2)
        XCTAssertEqual(dto.isDeleted, false)
        XCTAssertEqual(dto.createdAt, wallet.createdAt)
        XCTAssertEqual(dto.updatedAt, wallet.updatedAt)
    }

    /// Confirms the `CodingKeys` actually produce the `snake_case` column names the Postgres
    /// schema expects (`user_id`, `head_category_id`, `custom_icon`, etc.), not just that encoding
    /// succeeds — a mismatched key here would silently fail an upsert against the real schema.
    /// Also confirms an array of DTOs (the batch wire shape) encodes the same way a single DTO
    /// does, since `syncReferenceData` now always encodes `[DTO]`, never a bare `DTO`.
    func testWalletDTOBatchEncodesExpectedSnakeCaseKeys() throws {
        let wallets = [TestSupport.makeWallet(name: "Cash"), TestSupport.makeWallet(name: "Card")]
        let dtos = wallets.map { WalletDTO(wallet: $0, remoteID: UUID(), userID: userID) }

        let encoder = JSONEncoder()
        let data = try encoder.encode(dtos)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        XCTAssertEqual(json.count, 2)
        for row in json {
            for key in ["id", "user_id", "name", "type", "color_hex", "icon", "starting_balance", "include_in_net_worth", "is_default", "is_archived", "sort_order", "is_deleted", "created_at", "updated_at"] {
                XCTAssertNotNil(row[key], "missing expected column key: \(key)")
            }
        }
    }

    // MARK: - 14. Both single-model sync methods still behave correctly

    @MainActor
    func testSyncHeadCategoryMintsARemoteIDWhenNil() async throws {
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        XCTAssertNil(head.remoteID)

        let remoteID = try await service.syncHeadCategory(head, modelContext: context)

        XCTAssertEqual(head.remoteID, remoteID)
        XCTAssertNotNil(head.remoteID)
    }

    @MainActor
    func testSyncHeadCategoryReusesExistingRemoteIDRatherThanMintingANewOne() async throws {
        let head = TestSupport.makeHeadCategory()
        let existingID = UUID()
        head.remoteID = existingID
        context.insert(head)

        let returnedID = try await service.syncHeadCategory(head, modelContext: context)

        XCTAssertEqual(returnedID, existingID)
        XCTAssertEqual(head.remoteID, existingID)
    }

    @MainActor
    func testSyncCategoryMintsItsOwnRemoteIDWhenNil() async throws {
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)

        let remoteID = try await service.syncCategory(category, modelContext: context)

        XCTAssertEqual(category.remoteID, remoteID)
    }

    @MainActor
    func testSyncWalletMintsItsOwnRemoteIDWhenNil() async throws {
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)

        let remoteID = try await service.syncWallet(wallet, modelContext: context)

        XCTAssertEqual(wallet.remoteID, remoteID)
    }

    /// Standalone `syncCategory` intentionally keeps its own per-call dependency sync (ensuring
    /// its parent HeadCategory is uploaded first) — unlike `syncReferenceData`'s batch path, this
    /// is correct and unchanged for a single, independently-triggered category sync.
    @MainActor
    func testSyncCategoryStillUploadsItsHeadCategoryFirstWhenCalledStandalone() async throws {
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(headCategory: head)
        context.insert(category)

        _ = try await service.syncCategory(category, modelContext: context)

        XCTAssertEqual(uploader.callOrder.count, 2)
        XCTAssertTrue(uploader.callOrder[0].hasPrefix("headCategory:"), "the head category must upload before the category that references it")
        XCTAssertTrue(uploader.callOrder[1].hasPrefix("category:"))
        XCTAssertNotNil(head.remoteID, "syncing a category must also resolve its parent's remoteID")
    }
}

/// `XCTAssertThrowsError` has no async-throwing overload — this bridges an async throwing
/// expression the same way, used only where the thrown error itself needs inspecting (a bare
/// `do`/`catch` is used everywhere else in this file for that).
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
