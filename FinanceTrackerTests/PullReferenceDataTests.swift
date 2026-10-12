import XCTest
import SwiftData
@testable import FinanceTracker

/// Phase 4B: covers `SupabaseSyncService.pullReferenceData` — the first remote→local sync path in
/// this app. A separate mock from the push-side tests (`SupabaseReferenceDataDownloading` is its
/// own protocol, deliberately kept apart from `SupabaseReferenceDataUploading` so none of the
/// existing push tests/mocks needed to change). No network connection is used anywhere here.
private final class StubDownloader: SupabaseReferenceDataDownloading {
    var headCategories: [HeadCategoryDTO] = []
    var categories: [CategoryDTO] = []
    var wallets: [WalletDTO] = []

    func fetchHeadCategories(userID: UUID) async throws -> [HeadCategoryDTO] { headCategories }
    func fetchCategories(userID: UUID) async throws -> [CategoryDTO] { categories }
    func fetchWallets(userID: UUID) async throws -> [WalletDTO] { wallets }
}

private final class StubUserProvider: SupabaseSyncUserProviding {
    var userID: UUID?
    func currentUserID() async throws -> UUID? { userID }
}

/// A production `SupabaseReferenceDataUploading` conformance is still required by
/// `SupabaseSyncService.init`, even though `pullReferenceData` never calls it — a minimal no-op
/// stand-in keeps these tests from needing any of the existing push mocks.
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

final class PullReferenceDataTests: XCTestCase {
    private var downloader: StubDownloader!
    private var userProvider: StubUserProvider!
    private var service: SupabaseSyncService!
    private var context: ModelContext!
    private let userID = UUID()

    @MainActor
    override func setUp() {
        super.setUp()
        downloader = StubDownloader()
        userProvider = StubUserProvider()
        userProvider.userID = userID
        service = SupabaseSyncService(uploader: UnusedUploader(), downloader: downloader, userProvider: userProvider)
        context = TestSupport.makeInMemoryContext()
    }

    // MARK: - No session

    @MainActor
    func testPullWithNoSessionThrowsBeforeFetchingAnything() async throws {
        userProvider.userID = nil
        downloader.headCategories = [HeadCategoryDTO(headCategory: TestSupport.makeHeadCategory(), remoteID: UUID(), userID: userID)]

        do {
            try await service.pullReferenceData(modelContext: context)
            XCTFail("expected notAuthenticated to be thrown")
        } catch SupabaseSyncError.notAuthenticated {
            // expected
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<HeadCategory>()).isEmpty)
    }

    // MARK: - Create (remote missing locally)

    @MainActor
    func testPullCreatesALocalHeadCategoryThatDoesNotExistLocally() async throws {
        let remoteID = UUID()
        let remoteCreatedAt = Date(timeIntervalSince1970: 1_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_000)
        downloader.headCategories = [
            HeadCategoryDTO(
                id: remoteID, userID: userID, name: "Travel", icon: "airplane", colorHex: "#3B82F6",
                sortOrder: 3, createdAt: remoteCreatedAt, updatedAt: remoteUpdatedAt
            ),
        ]

        try await service.pullReferenceData(modelContext: context)

        let local = try XCTUnwrap(try context.fetch(FetchDescriptor<HeadCategory>()).first)
        XCTAssertEqual(local.remoteID, remoteID, "the remote's own id must be preserved, not a freshly minted one")
        XCTAssertEqual(local.name, "Travel")
        XCTAssertEqual(local.icon, "airplane")
        XCTAssertEqual(local.colorHex, "#3B82F6")
        XCTAssertEqual(local.sortOrder, 3)
        XCTAssertEqual(local.createdAt, remoteCreatedAt, "the remote's own createdAt must be preserved")
        XCTAssertEqual(local.updatedAt, remoteUpdatedAt)
    }

    @MainActor
    func testPullCreatesALocalWalletThatDoesNotExistLocally() async throws {
        let remoteID = UUID()
        downloader.wallets = [
            WalletDTO(
                id: remoteID, userID: userID, name: "Savings", type: .savings, colorHex: "#0EA5E9",
                icon: "banknote.fill", startingBalance: 500, goalAmount: nil, includeInNetWorth: true,
                isDefault: false, isArchived: false, sortOrder: 1, isDeleted: false,
                createdAt: .now, updatedAt: .now
            ),
        ]

        try await service.pullReferenceData(modelContext: context)

        let local = try XCTUnwrap(try context.fetch(FetchDescriptor<Wallet>()).first)
        XCTAssertEqual(local.remoteID, remoteID)
        XCTAssertEqual(local.name, "Savings")
        XCTAssertEqual(local.startingBalance, 500)
        XCTAssertFalse(local.isSoftDeleted)
    }

    /// A pulled wallet with `is_deleted = true` (e.g. soft-deleted on another device) must create
    /// a local wallet that is itself already soft-deleted — not a visible, active one.
    @MainActor
    func testPullCreatesASoftDeletedLocalWalletWhenRemoteIsDeleted() async throws {
        downloader.wallets = [
            WalletDTO(
                id: UUID(), userID: userID, name: "Closed Account", type: .credit, colorHex: "#EF4444",
                icon: "creditcard.fill", startingBalance: 0, goalAmount: nil, includeInNetWorth: false,
                isDefault: false, isArchived: false, sortOrder: 0, isDeleted: true,
                createdAt: .now, updatedAt: .now
            ),
        ]

        try await service.pullReferenceData(modelContext: context)

        let local = try XCTUnwrap(try context.fetch(FetchDescriptor<Wallet>()).first)
        XCTAssertTrue(local.isSoftDeleted)
    }

    // MARK: - Update (remote newer)

    @MainActor
    func testPullUpdatesALocalHeadCategoryWhenRemoteIsNewer() async throws {
        let remoteID = UUID()
        let local = TestSupport.makeHeadCategory(name: "Old Name", colorHex: "#FFFFFF")
        local.remoteID = remoteID
        local.createdAt = Date(timeIntervalSince1970: 1_000)
        local.updatedAt = Date(timeIntervalSince1970: 2_000)
        context.insert(local)
        try context.save()

        let newerUpdatedAt = Date(timeIntervalSince1970: 3_000)
        downloader.headCategories = [
            HeadCategoryDTO(
                id: remoteID, userID: userID, name: "New Name", icon: "car.fill", colorHex: "#10B981",
                sortOrder: 5, createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: newerUpdatedAt
            ),
        ]

        try await service.pullReferenceData(modelContext: context)

        XCTAssertEqual(local.name, "New Name")
        XCTAssertEqual(local.icon, "car.fill")
        XCTAssertEqual(local.colorHex, "#10B981")
        XCTAssertEqual(local.sortOrder, 5)
        XCTAssertEqual(local.updatedAt, newerUpdatedAt)
        XCTAssertEqual(local.createdAt, Date(timeIntervalSince1970: 1_000), "createdAt must never change on an update")
    }

    @MainActor
    func testPullUpdatesALocalWalletWhenRemoteIsNewer() async throws {
        let remoteID = UUID()
        let local = TestSupport.makeWallet(name: "Old Name", type: .spending)
        local.remoteID = remoteID
        local.updatedAt = Date(timeIntervalSince1970: 1_000)
        context.insert(local)
        try context.save()

        downloader.wallets = [
            WalletDTO(
                id: remoteID, userID: userID, name: "New Name", type: .savings, colorHex: "#0EA5E9",
                icon: "banknote.fill", startingBalance: 999, goalAmount: nil, includeInNetWorth: true,
                isDefault: false, isArchived: false, sortOrder: 0, isDeleted: false,
                createdAt: .now, updatedAt: Date(timeIntervalSince1970: 2_000)
            ),
        ]

        try await service.pullReferenceData(modelContext: context)

        XCTAssertEqual(local.name, "New Name")
        XCTAssertEqual(local.type, .savings)
        XCTAssertEqual(local.startingBalance, 999)
    }

    // MARK: - Unchanged (local newer or equal)

    @MainActor
    func testPullDoesNotOverwriteALocalHeadCategoryWhenLocalIsNewer() async throws {
        let remoteID = UUID()
        let local = TestSupport.makeHeadCategory(name: "Local Name")
        local.remoteID = remoteID
        local.updatedAt = Date(timeIntervalSince1970: 5_000)
        context.insert(local)
        try context.save()

        downloader.headCategories = [
            HeadCategoryDTO(
                id: remoteID, userID: userID, name: "Stale Remote Name", icon: "folder.fill", colorHex: "#FFFFFF",
                sortOrder: 0, createdAt: .now, updatedAt: Date(timeIntervalSince1970: 1_000)
            ),
        ]

        try await service.pullReferenceData(modelContext: context)

        XCTAssertEqual(local.name, "Local Name", "a locally-newer row must not be overwritten by a stale remote one")
    }

    @MainActor
    func testPullDoesNotOverwriteWhenTimestampsAreExactlyEqual() async throws {
        let remoteID = UUID()
        let sameInstant = Date(timeIntervalSince1970: 5_000)
        let local = TestSupport.makeHeadCategory(name: "Local Name")
        local.remoteID = remoteID
        local.updatedAt = sameInstant
        context.insert(local)
        try context.save()

        downloader.headCategories = [
            HeadCategoryDTO(
                id: remoteID, userID: userID, name: "Remote Name", icon: "folder.fill", colorHex: "#FFFFFF",
                sortOrder: 0, createdAt: .now, updatedAt: sameInstant
            ),
        ]

        try await service.pullReferenceData(modelContext: context)

        XCTAssertEqual(local.name, "Local Name", "an exactly-equal timestamp must count as \"local is current\", not overwrite")
    }

    // MARK: - Local-only data is never touched (remoteID as merge key)

    @MainActor
    func testPullNeverTouchesALocalObjectThatHasNoRemoteID() async throws {
        let localOnly = TestSupport.makeHeadCategory(name: "Never Synced")
        context.insert(localOnly)
        try context.save()

        downloader.headCategories = [
            HeadCategoryDTO(id: UUID(), userID: userID, name: "Remote One", icon: "folder.fill", colorHex: "#FFFFFF", sortOrder: 0, createdAt: .now, updatedAt: .now),
        ]

        try await service.pullReferenceData(modelContext: context)

        let all = try context.fetch(FetchDescriptor<HeadCategory>())
        XCTAssertEqual(all.count, 2, "the local-only object must be left alone, and the remote one added alongside it")
        XCTAssertTrue(all.contains { $0.name == "Never Synced" && $0.remoteID == nil })
    }

    // MARK: - Foreign-key resolution (Category → HeadCategory)

    @MainActor
    func testPullResolvesCategorysHeadCategoryFromTheJustPulledHeadCategory() async throws {
        let headRemoteID = UUID()
        downloader.headCategories = [
            HeadCategoryDTO(id: headRemoteID, userID: userID, name: "Everyday", icon: "folder.fill", colorHex: "#FFFFFF", sortOrder: 0, createdAt: .now, updatedAt: .now),
        ]
        let categoryRemoteID = UUID()
        downloader.categories = [
            CategoryDTO(
                id: categoryRemoteID, userID: userID, headCategoryID: headRemoteID, name: "Groceries",
                customIcon: "cart.fill", iconIsEmoji: false, customColorHex: nil, isSavings: false,
                isArchived: false, isIncome: false, isFixedPlannedCategory: false, createdAt: .now, updatedAt: .now
            ),
        ]

        try await service.pullReferenceData(modelContext: context)

        let pulledCategory = try XCTUnwrap(try context.fetch(FetchDescriptor<FinanceTracker.Category>()).first)
        let pulledHead = try XCTUnwrap(try context.fetch(FetchDescriptor<HeadCategory>()).first)
        XCTAssertEqual(pulledCategory.headCategory.remoteID, headRemoteID)
        XCTAssertTrue(pulledCategory.headCategory === pulledHead, "must resolve to the exact local object just created for the pulled HeadCategory")
    }

    /// Resolution must also work against a HeadCategory that already existed locally before this
    /// pull ran (not just one pulled in the same call) — the lookup is built from the full local
    /// table, not just this run's newly-inserted rows.
    @MainActor
    func testPullResolvesCategorysHeadCategoryFromAnAlreadyExistingLocalHeadCategory() async throws {
        let headRemoteID = UUID()
        let existingHead = TestSupport.makeHeadCategory(name: "Everyday")
        existingHead.remoteID = headRemoteID
        context.insert(existingHead)
        try context.save()

        downloader.categories = [
            CategoryDTO(
                id: UUID(), userID: userID, headCategoryID: headRemoteID, name: "Groceries",
                customIcon: nil, iconIsEmoji: false, customColorHex: nil, isSavings: false,
                isArchived: false, isIncome: false, isFixedPlannedCategory: false, createdAt: .now, updatedAt: .now
            ),
        ]

        try await service.pullReferenceData(modelContext: context)

        let pulledCategory = try XCTUnwrap(try context.fetch(FetchDescriptor<FinanceTracker.Category>()).first)
        XCTAssertTrue(pulledCategory.headCategory === existingHead)
    }

    /// A `Category` row whose parent `HeadCategory` can't be resolved locally at all (not pulled,
    /// not already present) must be skipped rather than crash — it's expected to resolve on a
    /// later pull once its parent has synced.
    @MainActor
    func testPullSkipsACategoryWhoseHeadCategoryCannotBeResolved() async throws {
        downloader.categories = [
            CategoryDTO(
                id: UUID(), userID: userID, headCategoryID: UUID(), name: "Orphaned",
                customIcon: nil, iconIsEmoji: false, customColorHex: nil, isSavings: false,
                isArchived: false, isIncome: false, isFixedPlannedCategory: false, createdAt: .now, updatedAt: .now
            ),
        ]

        try await service.pullReferenceData(modelContext: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<FinanceTracker.Category>()).isEmpty)
    }

    // MARK: - Realistic push-then-pull round trip (reproduces the reported bug, or rules it out)

    /// The most realistic reproduction available without live network access: push a local object
    /// through the real `syncReferenceData` (minting its `remoteID` and building its DTO exactly
    /// as production does), capture exactly what was uploaded, then feed that *same* captured DTO
    /// back in as if a later `pullReferenceData` call fetched it from Supabase. If the merge-by-
    /// remoteID logic were broken, this is where it would show up — the pulled DTO's `id` is
    /// literally the same `remoteID` just minted and persisted on the local object.
    final class RecordingUploader: SupabaseReferenceDataUploading {
        private(set) var headCategoryBatches: [[HeadCategoryDTO]] = []
        private(set) var categoryBatches: [[CategoryDTO]] = []
        private(set) var walletBatches: [[WalletDTO]] = []
        func upsertHeadCategory(_ dto: HeadCategoryDTO) async throws {}
        func upsertCategory(_ dto: CategoryDTO) async throws {}
        func upsertWallet(_ dto: WalletDTO) async throws {}
        func upsertHeadCategories(_ dtos: [HeadCategoryDTO]) async throws { headCategoryBatches.append(dtos) }
        func upsertCategories(_ dtos: [CategoryDTO]) async throws { categoryBatches.append(dtos) }
        func upsertWallets(_ dtos: [WalletDTO]) async throws { walletBatches.append(dtos) }
        func upsertBudgets(_ dtos: [BudgetDTO]) async throws {}
        func upsertEntries(_ dtos: [EntryDTO]) async throws {}
    }

    @MainActor
    func testRealisticPushThenPullRoundTripUpdatesInPlaceWithoutDuplicating() async throws {
        let recordingUploader = RecordingUploader()
        let service = SupabaseSyncService(uploader: recordingUploader, downloader: downloader, userProvider: userProvider)

        let head = TestSupport.makeHeadCategory(name: "Everyday")
        context.insert(head)
        let category = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        context.insert(category)
        let wallet = TestSupport.makeWallet(name: "Spending")
        context.insert(wallet)
        try context.save()
        XCTAssertNil(head.remoteID)
        XCTAssertNil(category.remoteID)
        XCTAssertNil(wallet.remoteID)

        // Push: mints remoteIDs and uploads, exactly like production.
        try await service.syncReferenceData(modelContext: context)
        XCTAssertNotNil(head.remoteID)
        XCTAssertNotNil(category.remoteID)
        XCTAssertNotNil(wallet.remoteID)

        // Pull: feed back the *exact* DTOs that were just uploaded, as if Supabase returned them
        // completely unchanged.
        downloader.headCategories = try XCTUnwrap(recordingUploader.headCategoryBatches.last)
        downloader.categories = try XCTUnwrap(recordingUploader.categoryBatches.last)
        downloader.wallets = try XCTUnwrap(recordingUploader.walletBatches.last)

        try await service.pullReferenceData(modelContext: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<HeadCategory>()).count, 1, "pulling back the same row just pushed must never create a duplicate")
        XCTAssertEqual(try context.fetch(FetchDescriptor<FinanceTracker.Category>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Wallet>()).count, 1)
    }

    /// Reproduces the exact user-reported symptom and identifies its real cause: a local object
    /// that was *never synced* (`remoteID == nil` — e.g. a `SeedData` default, or any local data
    /// created before this device ever pushed) has no identity in common with the user's real
    /// remote data, even when the names happen to match. Pulling the real remote row therefore
    /// correctly creates a second local object — this is `remoteID`-as-merge-key working exactly as
    /// specified, not a defect in the matching code itself. The fix for this belongs to whatever
    /// keeps un-synced local data from existing in the first place (`SeedData` timing, Phase 4A),
    /// not to `pullReferenceData`, which has no way to know two differently-identified objects are
    /// "the same" without a merge key they actually share.
    @MainActor
    func testAnUnsyncedLocalObjectIsNotMatchedByNameAndProducesASecondLocalObject() async throws {
        let unsyncedLocalWallet = TestSupport.makeWallet(name: "Spending") // remoteID == nil, e.g. a SeedData default
        context.insert(unsyncedLocalWallet)
        try context.save()

        downloader.wallets = [
            WalletDTO(
                id: UUID(), userID: userID, name: "Spending", type: .spending, colorHex: "#10B981",
                icon: "creditcard.fill", startingBalance: 0, goalAmount: nil, includeInNetWorth: true,
                isDefault: true, isArchived: false, sortOrder: 0, isDeleted: false, createdAt: .now, updatedAt: .now
            ),
        ]

        try await service.pullReferenceData(modelContext: context)

        let allWallets = try context.fetch(FetchDescriptor<Wallet>())
        XCTAssertEqual(allWallets.count, 2, "an unsynced local object and a same-named remote object are NOT the same identity — remoteID is the only merge key, by design")
        XCTAssertTrue(allWallets.contains { $0.remoteID == nil }, "the original unsynced local wallet must be left untouched")
    }

    // MARK: - Idempotency

    @MainActor
    func testRepeatedPullIsIdempotent() async throws {
        let remoteID = UUID()
        downloader.headCategories = [
            HeadCategoryDTO(id: remoteID, userID: userID, name: "Everyday", icon: "folder.fill", colorHex: "#FFFFFF", sortOrder: 0, createdAt: .now, updatedAt: .now),
        ]

        try await service.pullReferenceData(modelContext: context)
        try await service.pullReferenceData(modelContext: context)

        let all = try context.fetch(FetchDescriptor<HeadCategory>())
        XCTAssertEqual(all.count, 1, "re-pulling the same unchanged remote row must never create a duplicate")
    }
}
