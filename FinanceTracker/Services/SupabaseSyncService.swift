import Foundation
import SwiftData
import Supabase
import os

/// Traces the exact `remoteID` value an `Entry` carries immediately before and after
/// `ensureRemoteID`, across repeated `syncEntries` runs — originally added (Phase 3B-4) to
/// determine whether an already-synced `Entry` could ever be assigned a second, different
/// `remoteID`; kept on as the same debugging aid for the Phase 4G Entry-sync investigation. Phase
/// 4G.1 — gated entirely behind `#if DEBUG`, same shape and same reasoning as `SyncDiagnosticLog`
/// in `RootView.swift`: every call site still reads as plain `EntrySyncDiagnosticLog.log("...")`,
/// but the `message` argument is an `@autoclosure` that's never evaluated in a Release build, and
/// the function body is empty there — so the per-row, per-sync string-interpolation work building
/// these messages (previously real diagnostic audit finding: measurable, since this is called
/// twice per `Entry` on every single sync pass) costs nothing outside of DEBUG. Purely a debugging
/// aid; never the place real failures are reported.
enum EntrySyncDiagnosticLog {
    #if DEBUG
    private static let logger = Logger(subsystem: "com.andreacorzo.FinanceTracker", category: "EntrySyncDiagnostics")
    #endif

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        let resolved = message()
        logger.log("\(resolved, privacy: .public)")
        print("[EntrySyncDiagnostics] \(resolved)")
        #endif
    }
}

enum SupabaseSyncError: Error, Equatable {
    /// Thrown instead of crashing when a sync is attempted with no active Supabase session —
    /// e.g. a signed-out user, or a sync triggered before `RootView`'s launch session check
    /// resolves.
    case notAuthenticated
}

/// A SwiftData model that can be given a stable cross-device identity for Supabase sync — see
/// `Entry.remoteID`'s doc comment (Phase 2A) for the full rationale. Purely structural: no
/// Supabase-specific code lives on the models themselves, only this one settable property they
/// already had.
protocol RemoteSyncable: AnyObject {
    var remoteID: UUID? { get set }
}

extension HeadCategory: RemoteSyncable {}
extension Category: RemoteSyncable {}
extension Wallet: RemoteSyncable {}
extension Entry: RemoteSyncable {}
extension Budget: RemoteSyncable {}

/// The network boundary `SupabaseSyncService` uploads through — exists so unit tests can swap in
/// a mock and assert on exactly what would have been sent, without a real Supabase connection.
/// `SupabasePostgRESTUploader` is the only production conformance.
///
/// Both a single-row and a batch method exist per table: the single-row methods back
/// `syncHeadCategory`/`syncCategory`/`syncWallet` (kept for standalone/future use — e.g. syncing
/// one edited record right after a save), while `syncReferenceData` exclusively uses the batch
/// methods, so a full sync is exactly one request per table regardless of row count.
protocol SupabaseReferenceDataUploading {
    func upsertHeadCategory(_ dto: HeadCategoryDTO) async throws
    func upsertCategory(_ dto: CategoryDTO) async throws
    func upsertWallet(_ dto: WalletDTO) async throws

    func upsertHeadCategories(_ dtos: [HeadCategoryDTO]) async throws
    func upsertCategories(_ dtos: [CategoryDTO]) async throws
    func upsertWallets(_ dtos: [WalletDTO]) async throws

    /// Batch-only, mirroring `upsertEntries` — `syncBudgets` is the only caller and never has a
    /// reason to upload fewer than every local budget at once.
    func upsertBudgets(_ dtos: [BudgetDTO]) async throws

    /// Batch-only — unlike the three reference-data tables, there's no single-row
    /// `upsertEntry(_:)` counterpart. `syncEntries` is the only caller, and it never has a reason
    /// to upload fewer than "every local entry" at once; omitting the single-row method removes
    /// any temptation to later loop it per entry.
    func upsertEntries(_ dtos: [EntryDTO]) async throws
}

/// The network boundary `SupabaseSyncService.pullReferenceData` reads through — a separate
/// protocol from `SupabaseReferenceDataUploading` (Phase 4B) so every existing push test/mock
/// stays untouched; only the new pull path depends on this. `SupabasePostgRESTUploader` is the
/// only production conformance, same as the uploading side.
protocol SupabaseReferenceDataDownloading {
    func fetchHeadCategories(userID: UUID) async throws -> [HeadCategoryDTO]
    func fetchCategories(userID: UUID) async throws -> [CategoryDTO]
    func fetchWallets(userID: UUID) async throws -> [WalletDTO]
}

/// The network boundary `SupabaseSyncService.pullBudgets` reads through (Phase 4D) — kept
/// separate from `SupabaseReferenceDataDownloading` for the same reason that one's kept separate
/// from `SupabaseReferenceDataUploading`: every existing `pullReferenceData` test/mock stays
/// untouched; only the new budget pull path depends on this. `SupabasePostgRESTUploader` is the
/// only production conformance.
protocol SupabaseBudgetDownloading {
    func fetchBudgets(userID: UUID) async throws -> [BudgetDTO]
}

/// The network boundary `SupabaseSyncService.pullEntries` reads through (Phase 4E) — kept
/// separate from the other downloading protocols for the same reason `SupabaseBudgetDownloading`
/// is: every existing pull test/mock stays untouched; only the new entry pull path depends on
/// this. `SupabasePostgRESTUploader` is the only production conformance.
protocol SupabaseEntryDownloading {
    func fetchEntries(userID: UUID) async throws -> [EntryDTO]
}

/// Maps `SupabaseReferenceDataUploading` onto the real `SupabaseClient`. Every method — single-row
/// or batch — is one `upsert` keyed on each table's primary key (`id`, i.e. each model's
/// `remoteID`), so retrying ever updates existing rows rather than duplicating them. The batch
/// methods pass a `[DTO]` array directly to `upsert(_:)` — PostgREST accepts an array body for a
/// multi-row upsert in a single request exactly like a single-row body.
struct SupabasePostgRESTUploader: SupabaseReferenceDataUploading, SupabaseReferenceDataDownloading, SupabaseBudgetDownloading, SupabaseEntryDownloading {
    let client: SupabaseClient

    private enum Table {
        static let headCategories = "head_categories"
        static let categories = "categories"
        static let wallets = "wallets"
        static let entries = "entries"
        static let budgets = "budgets"
    }

    func upsertHeadCategory(_ dto: HeadCategoryDTO) async throws {
        try await client.from(Table.headCategories).upsert(dto).execute()
    }

    func upsertCategory(_ dto: CategoryDTO) async throws {
        try await client.from(Table.categories).upsert(dto).execute()
    }

    func upsertWallet(_ dto: WalletDTO) async throws {
        try await client.from(Table.wallets).upsert(dto).execute()
    }

    func upsertHeadCategories(_ dtos: [HeadCategoryDTO]) async throws {
        try await client.from(Table.headCategories).upsert(dtos).execute()
    }

    func upsertCategories(_ dtos: [CategoryDTO]) async throws {
        try await client.from(Table.categories).upsert(dtos).execute()
    }

    func upsertWallets(_ dtos: [WalletDTO]) async throws {
        try await client.from(Table.wallets).upsert(dtos).execute()
    }

    func upsertEntries(_ dtos: [EntryDTO]) async throws {
        try await client.from(Table.entries).upsert(dtos).execute()
    }

    func upsertBudgets(_ dtos: [BudgetDTO]) async throws {
        try await client.from(Table.budgets).upsert(dtos).execute()
    }

    /// Scoped to `user_id` explicitly rather than relying on RLS alone — belt-and-suspenders, and
    /// matches every other query in this app always sourcing the user id from the authenticated
    /// session rather than assuming the server-side policy is the only thing enforcing it.
    func fetchHeadCategories(userID: UUID) async throws -> [HeadCategoryDTO] {
        try await client.from(Table.headCategories).select().eq("user_id", value: userID.uuidString).execute().value
    }

    func fetchCategories(userID: UUID) async throws -> [CategoryDTO] {
        try await client.from(Table.categories).select().eq("user_id", value: userID.uuidString).execute().value
    }

    func fetchWallets(userID: UUID) async throws -> [WalletDTO] {
        try await client.from(Table.wallets).select().eq("user_id", value: userID.uuidString).execute().value
    }

    func fetchBudgets(userID: UUID) async throws -> [BudgetDTO] {
        try await client.from(Table.budgets).select().eq("user_id", value: userID.uuidString).execute().value
    }

    func fetchEntries(userID: UUID) async throws -> [EntryDTO] {
        try await client.from(Table.entries).select().eq("user_id", value: userID.uuidString).execute().value
    }
}

/// The minimal surface `SupabaseSyncService` needs from auth — matches `SupabaseAuthService.
/// currentUserID()`'s existing signature exactly, so that type conforms with no changes of its
/// own. Exists so tests can substitute a mock user instead of a real session.
protocol SupabaseSyncUserProviding {
    func currentUserID() async throws -> UUID?
}

extension SupabaseAuthService: SupabaseSyncUserProviding {}

/// Stages `syncReferenceData` reports via its `onProgress` callback — purely informational (e.g.
/// for `SupabaseTestView`'s status label); nothing about the sync's own logic depends on whether
/// anyone's listening. `.preparing` fires once, after all three local fetches but before any
/// upload; each `.uploading*` case fires immediately before that table's single batch request
/// (skipped entirely if that table has zero local rows, matching `syncReferenceData` itself
/// skipping the request); `.completed` fires once, after all (non-empty) batches have succeeded.
enum SupabaseSyncProgress: Equatable {
    case preparing(headCategories: Int, categories: Int, wallets: Int)
    case uploadingHeadCategories(count: Int)
    case uploadingCategories(count: Int)
    case uploadingWallets(count: Int)
    /// Phase 3B-2 — `syncEntries`'s own "fetched, about to map" stage, mirroring `.preparing`'s
    /// role for reference data. A separate case (not a reuse of `.preparing`) since it reports one
    /// count, not three, and `syncEntries` runs as its own call, never interleaved with the
    /// reference-data stages.
    case preparingEntries(count: Int)
    case uploadingEntries(count: Int)
    /// `syncBudgets`'s own "fetched, about to map" stage — same role as `.preparingEntries`,
    /// reporting one count for its one table.
    case preparingBudgets(count: Int)
    case uploadingBudgets(count: Int)
    /// Shared by `syncReferenceData`, `syncBudgets`, and `syncEntries` — "this call's batches are
    /// done" means the same thing for all three, so no separate per-method case was added.
    case completed
}

/// Phase 2B/2D of the Supabase migration: uploads `HeadCategory`/`Category`/`Wallet` — in that
/// dependency order, since a `Category` row references its parent `HeadCategory` by remote id,
/// and a future `Wallet`-owning record (Entry, in a later phase) will reference `Wallet` the same
/// way. SwiftData remains the local source of truth throughout; this only ever pushes local state
/// outward, never writes back into SwiftData from a remote read (no download/bidirectional sync
/// yet — see this phase's scope notes).
///
/// Deliberately *not* wired into any model-mutation call site yet (`AddTransactionView`,
/// `WalletEditorView`, etc.) — each `sync*` method is a standalone, explicitly-invoked operation
/// until a later phase decides where to trigger it automatically.
@MainActor
final class SupabaseSyncService {
    static let shared = SupabaseSyncService()

    /// Production-visible (not `#if DEBUG`-gated, unlike `EntrySyncDiagnosticLog`) — currently
    /// only used by `syncEntries` to report a skipped, unmappable `Entry` (Phase 4G.5). A skipped
    /// entry is real data that stays local-only until whatever made it unmappable is fixed, so it
    /// must be visible in a Release build's logs too, not just a DEBUG console.
    private static let logger = Logger(subsystem: "com.andreacorzo.FinanceTracker", category: "SupabaseSyncService")

    private let uploader: SupabaseReferenceDataUploading
    private let downloader: SupabaseReferenceDataDownloading
    private let budgetDownloader: SupabaseBudgetDownloading
    private let entryDownloader: SupabaseEntryDownloading
    private let userProvider: SupabaseSyncUserProviding

    init(
        uploader: SupabaseReferenceDataUploading = SupabasePostgRESTUploader(client: SupabaseManager.shared.client),
        downloader: SupabaseReferenceDataDownloading = SupabasePostgRESTUploader(client: SupabaseManager.shared.client),
        budgetDownloader: SupabaseBudgetDownloading = SupabasePostgRESTUploader(client: SupabaseManager.shared.client),
        entryDownloader: SupabaseEntryDownloading = SupabasePostgRESTUploader(client: SupabaseManager.shared.client),
        userProvider: SupabaseSyncUserProviding = SupabaseAuthService.shared
    ) {
        self.uploader = uploader
        self.downloader = downloader
        self.budgetDownloader = budgetDownloader
        self.entryDownloader = entryDownloader
        self.userProvider = userProvider
    }

    /// Uploads one `HeadCategory`. Mints and persists a `remoteID` first if this is the first
    /// time it's been synced; reuses the existing one otherwise. Returns the `remoteID` so
    /// `syncCategory` can use it as a dependent record's foreign key without a second lookup.
    /// Kept for standalone use (e.g. syncing a single edited record); `syncReferenceData` does not
    /// call this — see its own doc comment.
    @discardableResult
    func syncHeadCategory(_ headCategory: HeadCategory, modelContext: ModelContext) async throws -> UUID {
        let userID = try await requireUserID()
        let remoteID = try ensureRemoteID(for: headCategory, modelContext: modelContext)
        let dto = HeadCategoryDTO(headCategory: headCategory, remoteID: remoteID, userID: userID)
        try await uploader.upsertHeadCategory(dto)
        return remoteID
    }

    /// Uploads one `Category` — first ensuring its parent `HeadCategory` has a `remoteID` and has
    /// itself been uploaded, since `categories.head_category_id` has an RLS/foreign-key
    /// dependency on that row already existing. This per-call dependency sync is intentional and
    /// correct for standalone use (e.g. syncing a single newly-created category); it's exactly
    /// what `syncReferenceData` must avoid doing once per category in a full batch sync — see its
    /// own doc comment for why.
    @discardableResult
    func syncCategory(_ category: Category, modelContext: ModelContext) async throws -> UUID {
        let userID = try await requireUserID()
        let headCategoryRemoteID = try await syncHeadCategory(category.headCategory, modelContext: modelContext)
        let remoteID = try ensureRemoteID(for: category, modelContext: modelContext)
        let dto = CategoryDTO(category: category, remoteID: remoteID, headCategoryRemoteID: headCategoryRemoteID, userID: userID)
        try await uploader.upsertCategory(dto)
        return remoteID
    }

    /// Uploads one `Wallet`. `Wallet` has no parent dependency in this phase (Entry — the one
    /// model that references it — isn't synced yet), so this mints/reuses its own `remoteID`
    /// directly.
    @discardableResult
    func syncWallet(_ wallet: Wallet, modelContext: ModelContext) async throws -> UUID {
        let userID = try await requireUserID()
        let remoteID = try ensureRemoteID(for: wallet, modelContext: modelContext)
        let dto = WalletDTO(wallet: wallet, remoteID: remoteID, userID: userID)
        try await uploader.upsertWallet(dto)
        return remoteID
    }

    /// Phase 4B — downloads every remote `HeadCategory`, `Category`, and `Wallet` for the current
    /// user and merges each into the local store, strictly in the same dependency order push
    /// already uses (HeadCategories, then Categories, then Wallets), since a pulled `Category`
    /// needs its parent `HeadCategory` already resolved locally before it can set
    /// `Category.headCategory`.
    ///
    /// `remoteID` is the only merge key — a pulled row is matched to a local object purely by
    /// `remoteID`, never by name/content. A local object that has never been synced (`remoteID ==
    /// nil`) is invisible to this merge and is left completely untouched; it only ever becomes
    /// matchable once a future push mints it a `remoteID`. This is what makes pulling safe to run
    /// against a store that already has local-only, never-synced data (a first sync after login,
    /// or an existing local user signing into Supabase for the first time): nothing here can ever
    /// overwrite or duplicate that local-only data, it simply adds whatever's remote alongside it.
    ///
    /// Conflict rule is last-write-wins by `updatedAt`, per row (not per field):
    /// - remote row matches an existing local row and is newer → every field is overwritten from
    ///   the remote value (except `createdAt`, which never changes after creation).
    /// - remote row matches an existing local row but is not newer (local is newer or exactly
    ///   equal) → the local row is left untouched; a subsequent push will re-upload it, which is
    ///   correct since local is at least as current.
    /// - remote row has no local match at all → a brand-new local object is inserted, stamped
    ///   with the remote's own `remoteID`/`createdAt`/`updatedAt` rather than minting new ones.
    ///
    /// Deliberately does not push afterward and does not delete any local row for a remote row
    /// that's missing (no remote-deletion handling for `HeadCategory`/`Category` yet — neither has
    /// a tombstone field; see `Wallet.isSoftDeleted`/`WalletDTO.isDeleted` for the one model here
    /// that does, mapped straight onto `Wallet.isSoftDeleted` like any other field). Not wired into
    /// `SyncCoordinator` yet — standalone and explicitly invoked, exactly like `syncReferenceData`
    /// was before Phase 3C wired that one in.
    /// `userID` lets `SyncCoordinator` resolve the authenticated user once per sync pass and
    /// thread it through all six steps (Phase 4G.3A) instead of each step re-resolving it
    /// independently; `nil` (the default) preserves this method's original standalone behavior —
    /// every existing caller that doesn't pass one keeps resolving its own.
    func pullReferenceData(modelContext: ModelContext, userID: UUID? = nil) async throws {
        let resolvedUserID: UUID
        if let userID {
            resolvedUserID = userID
        } else {
            resolvedUserID = try await requireUserID()
        }
        let userID = resolvedUserID

        let headCategoryDTOs = try await downloader.fetchHeadCategories(userID: userID)
        let localHeadCategories = try modelContext.fetch(FetchDescriptor<HeadCategory>())
        var headCategoryByRemoteID: [UUID: HeadCategory] = [:]
        for headCategory in localHeadCategories {
            if let remoteID = headCategory.remoteID {
                headCategoryByRemoteID[remoteID] = headCategory
            }
        }
        for dto in headCategoryDTOs {
            if let existing = headCategoryByRemoteID[dto.id] {
                guard dto.updatedAt > existing.updatedAt else { continue }
                existing.name = dto.name
                existing.icon = dto.icon
                existing.colorHex = dto.colorHex
                existing.sortOrder = dto.sortOrder
                existing.updatedAt = dto.updatedAt
            } else {
                let newHeadCategory = HeadCategory(
                    name: dto.name, icon: dto.icon, colorHex: dto.colorHex, sortOrder: dto.sortOrder,
                    createdAt: dto.createdAt, updatedAt: dto.updatedAt
                )
                newHeadCategory.remoteID = dto.id
                modelContext.insert(newHeadCategory)
                headCategoryByRemoteID[dto.id] = newHeadCategory
            }
        }
        // Phase 4G.3A — skip the commit (and the didSave notification it would post) entirely
        // when this table's loop found nothing to change, instead of saving unconditionally.
        if modelContext.hasChanges {
            try modelContext.save()
        }

        let categoryDTOs = try await downloader.fetchCategories(userID: userID)
        let localCategories = try modelContext.fetch(FetchDescriptor<Category>())
        var categoryByRemoteID: [UUID: Category] = [:]
        for category in localCategories {
            if let remoteID = category.remoteID {
                categoryByRemoteID[remoteID] = category
            }
        }
        for dto in categoryDTOs {
            // The parent HeadCategory must already be resolved locally (either it was just
            // pulled above, or it already existed) — if it genuinely isn't found, this row is
            // skipped rather than crashing; it will resolve on a later pull once its parent has
            // synced.
            guard let headCategory = headCategoryByRemoteID[dto.headCategoryID] else { continue }
            if let existing = categoryByRemoteID[dto.id] {
                guard dto.updatedAt > existing.updatedAt else { continue }
                existing.name = dto.name
                existing.customIcon = dto.customIcon
                existing.iconIsEmoji = dto.iconIsEmoji
                existing.customColorHex = dto.customColorHex
                existing.isSavings = dto.isSavings
                existing.isArchived = dto.isArchived
                existing.isIncome = dto.isIncome
                existing.isFixedPlannedCategory = dto.isFixedPlannedCategory
                existing.headCategory = headCategory
                existing.updatedAt = dto.updatedAt
            } else {
                let newCategory = Category(
                    name: dto.name, customIcon: dto.customIcon, iconIsEmoji: dto.iconIsEmoji,
                    customColorHex: dto.customColorHex, isSavings: dto.isSavings, isArchived: dto.isArchived,
                    isIncome: dto.isIncome, isFixedPlannedCategory: dto.isFixedPlannedCategory,
                    headCategory: headCategory, createdAt: dto.createdAt, updatedAt: dto.updatedAt
                )
                newCategory.remoteID = dto.id
                modelContext.insert(newCategory)
                categoryByRemoteID[dto.id] = newCategory
            }
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }

        let walletDTOs = try await downloader.fetchWallets(userID: userID)
        let localWallets = try modelContext.fetch(FetchDescriptor<Wallet>())
        var walletByRemoteID: [UUID: Wallet] = [:]
        for wallet in localWallets {
            if let remoteID = wallet.remoteID {
                walletByRemoteID[remoteID] = wallet
            }
        }
        for dto in walletDTOs {
            if let existing = walletByRemoteID[dto.id] {
                guard dto.updatedAt > existing.updatedAt else { continue }
                existing.name = dto.name
                existing.type = dto.type
                existing.colorHex = dto.colorHex
                existing.icon = dto.icon
                existing.startingBalance = dto.startingBalance
                existing.goalAmount = dto.goalAmount
                existing.includeInNetWorth = dto.includeInNetWorth
                existing.isDefault = dto.isDefault
                existing.isArchived = dto.isArchived
                existing.sortOrder = dto.sortOrder
                existing.isSoftDeleted = dto.isDeleted
                existing.updatedAt = dto.updatedAt
            } else {
                let newWallet = Wallet(
                    name: dto.name, type: dto.type, colorHex: dto.colorHex, icon: dto.icon,
                    startingBalance: dto.startingBalance, goalAmount: dto.goalAmount,
                    includeInNetWorth: dto.includeInNetWorth, isDefault: dto.isDefault,
                    isArchived: dto.isArchived, sortOrder: dto.sortOrder, isSoftDeleted: dto.isDeleted,
                    createdAt: dto.createdAt, updatedAt: dto.updatedAt
                )
                newWallet.remoteID = dto.id
                modelContext.insert(newWallet)
                walletByRemoteID[dto.id] = newWallet
            }
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    /// Phase 4D — downloads every remote `Budget` for the current user and merges each into the
    /// local store, by `remoteID` only, exactly like `pullReferenceData`'s per-table loops: a
    /// remote row with no local match inserts a brand-new local `Budget` (stamped with the
    /// remote's own `remoteID`/`createdAt`/`updatedAt`); a remote row that matches an existing
    /// local `Budget` overwrites it field-by-field only if `dto.updatedAt` is strictly newer (last-
    /// write-wins, same rule, same `createdAt`-never-changes exception); a local `Budget` that's
    /// at least as current as its remote counterpart is left untouched.
    ///
    /// `categoryID` is resolved purely against already-synced local `Category` rows by their own
    /// `remoteID` — never by name, never minting a new `Category`. A remote `Budget` whose
    /// `categoryID` has no local match yet (that `Category` hasn't been pulled/pushed on this
    /// device) is skipped entirely, exactly like `pullReferenceData`'s `Category` loop skips a row
    /// whose parent `HeadCategory` isn't resolved yet — it will resolve on a later pull once its
    /// `Category` exists locally. Deliberately does not call `pullReferenceData` itself first; the
    /// caller is responsible for sequencing (see `SyncCoordinator`'s documented pull order).
    /// `userID` lets `SyncCoordinator` reuse the one id resolved per sync pass (Phase 4G.3A); `nil`
    /// (the default) preserves standalone-call behavior.
    func pullBudgets(modelContext: ModelContext, userID: UUID? = nil) async throws {
        let resolvedUserID: UUID
        if let userID {
            resolvedUserID = userID
        } else {
            resolvedUserID = try await requireUserID()
        }
        let userID = resolvedUserID

        let budgetDTOs = try await budgetDownloader.fetchBudgets(userID: userID)

        let localCategories = try modelContext.fetch(FetchDescriptor<Category>())
        var categoryByRemoteID: [UUID: Category] = [:]
        for category in localCategories {
            if let remoteID = category.remoteID {
                categoryByRemoteID[remoteID] = category
            }
        }

        let localBudgets = try modelContext.fetch(FetchDescriptor<Budget>())
        var budgetByRemoteID: [UUID: Budget] = [:]
        for budget in localBudgets {
            if let remoteID = budget.remoteID {
                budgetByRemoteID[remoteID] = budget
            }
        }

        for dto in budgetDTOs {
            guard let category = categoryByRemoteID[dto.categoryID] else { continue }
            if let existing = budgetByRemoteID[dto.id] {
                guard dto.updatedAt > existing.updatedAt else { continue }
                existing.monthlyLimit = dto.monthlyLimit
                existing.month = dto.month
                existing.year = dto.year
                existing.isHidden = dto.isHidden
                existing.isFixed = dto.isFixed
                existing.category = category
                existing.updatedAt = dto.updatedAt
            } else {
                let newBudget = Budget(
                    category: category, monthlyLimit: dto.monthlyLimit, month: dto.month, year: dto.year,
                    isHidden: dto.isHidden, isFixed: dto.isFixed, createdAt: dto.createdAt, updatedAt: dto.updatedAt
                )
                newBudget.remoteID = dto.id
                modelContext.insert(newBudget)
                budgetByRemoteID[dto.id] = newBudget
            }
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    /// Phase 4E — downloads every remote `Entry` for the current user and merges each into the
    /// local store, by `remoteID` only, following exactly the same per-row last-write-wins rule
    /// `pullReferenceData`/`pullBudgets` already use: a remote row with no local match inserts a
    /// brand-new local `Entry` (stamped with the remote's own `remoteID`/`createdAt`/`updatedAt`);
    /// a remote row that matches an existing local `Entry` overwrites it field-by-field only if
    /// `dto.updatedAt` is strictly newer; a local `Entry` at least as current as its remote
    /// counterpart is left untouched.
    ///
    /// `walletID` (always required), `destinationWalletID`, and `categoryID` (each required only
    /// when present on the DTO — a transfer's `categoryID` is legitimately nil, exactly like a
    /// non-transfer's `destinationWalletID` is) are each resolved purely against already-synced
    /// local `Wallet`/`Category` rows by their own `remoteID` — never minted, never matched by
    /// name. A remote row whose required relationship(s) can't be resolved locally yet is skipped
    /// entirely (logged via `EntrySyncDiagnosticLog`) rather than creating an `Entry` with a
    /// dangling or substituted reference; it will resolve on a later pull once that
    /// `Wallet`/`Category` exists locally.
    ///
    /// `isDeleted` maps straight onto `Entry.isSoftDeleted` like any other field — a soft-deleted
    /// remote row is ordinary, valid input (it either creates an already-deleted local `Entry`, or
    /// marks an existing one deleted if newer); this method never calls `modelContext.delete(_:)`
    /// itself, matching how a local soft-delete never does either.
    /// `userID` lets `SyncCoordinator` reuse the one id resolved per sync pass (Phase 4G.3A); `nil`
    /// (the default) preserves standalone-call behavior.
    func pullEntries(modelContext: ModelContext, userID: UUID? = nil) async throws {
        let resolvedUserID: UUID
        if let userID {
            resolvedUserID = userID
        } else {
            resolvedUserID = try await requireUserID()
        }
        let userID = resolvedUserID

        let entryDTOs = try await entryDownloader.fetchEntries(userID: userID)

        let localWallets = try modelContext.fetch(FetchDescriptor<Wallet>())
        var walletByRemoteID: [UUID: Wallet] = [:]
        for wallet in localWallets {
            if let remoteID = wallet.remoteID {
                walletByRemoteID[remoteID] = wallet
            }
        }

        let localCategories = try modelContext.fetch(FetchDescriptor<Category>())
        var categoryByRemoteID: [UUID: Category] = [:]
        for category in localCategories {
            if let remoteID = category.remoteID {
                categoryByRemoteID[remoteID] = category
            }
        }

        let localEntries = try modelContext.fetch(FetchDescriptor<Entry>())
        var entryByRemoteID: [UUID: Entry] = [:]
        for entry in localEntries {
            if let remoteID = entry.remoteID {
                entryByRemoteID[remoteID] = entry
            }
        }

        for dto in entryDTOs {
            guard let wallet = walletByRemoteID[dto.walletID] else {
                EntrySyncDiagnosticLog.log("pullEntries: skipping remote entry \(dto.id) — wallet \(dto.walletID) not resolved locally")
                continue
            }
            var destinationWallet: Wallet?
            if let destinationWalletID = dto.destinationWalletID {
                guard let resolved = walletByRemoteID[destinationWalletID] else {
                    EntrySyncDiagnosticLog.log("pullEntries: skipping remote entry \(dto.id) — destination wallet \(destinationWalletID) not resolved locally")
                    continue
                }
                destinationWallet = resolved
            }
            var category: Category?
            if let categoryID = dto.categoryID {
                guard let resolved = categoryByRemoteID[categoryID] else {
                    EntrySyncDiagnosticLog.log("pullEntries: skipping remote entry \(dto.id) — category \(categoryID) not resolved locally")
                    continue
                }
                category = resolved
            }

            if let existing = entryByRemoteID[dto.id] {
                guard dto.updatedAt > existing.updatedAt else { continue }
                existing.amount = dto.amount
                existing.date = dto.date
                existing.note = dto.note
                existing.type = dto.type
                existing.category = category
                existing.wallet = wallet
                existing.destinationWallet = destinationWallet
                existing.recurrence = dto.recurrence
                existing.excludeFromBudget = dto.excludeFromBudget
                existing.isPlannedExpense = dto.isPlannedExpense
                existing.isSoftDeleted = dto.isDeleted
                existing.updatedAt = dto.updatedAt
            } else {
                let newEntry = Entry(
                    amount: dto.amount, date: dto.date, note: dto.note, type: dto.type, category: category,
                    wallet: wallet, destinationWallet: destinationWallet, recurrence: dto.recurrence,
                    excludeFromBudget: dto.excludeFromBudget, isPlannedExpense: dto.isPlannedExpense,
                    isSoftDeleted: dto.isDeleted, createdAt: dto.createdAt, updatedAt: dto.updatedAt
                )
                newEntry.remoteID = dto.id
                modelContext.insert(newEntry)
                entryByRemoteID[dto.id] = newEntry
            }
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    /// Uploads every local `HeadCategory`, `Category`, and `Wallet` for the current user as three
    /// batch upserts — one request per table, regardless of row count — strictly in dependency
    /// order (HeadCategories, then Categories, then Wallets).
    ///
    /// Phase 2C's diagnostic logging found the original per-row implementation performing
    /// hundreds of sequential network/auth round trips for a dataset of only ~90 rows, because
    /// `syncCategory` re-synced its parent `HeadCategory` (including a fresh `requireUserID()`
    /// call) for every single category rather than once per unique head category. This rewrite
    /// fixes both: the authenticated user id is resolved exactly once up front, and every
    /// `HeadCategory` is processed (remoteID ensured) in its own loop *before* any `Category` DTO
    /// is built — so by the time a category looks up its parent's remoteID via `ensureRemoteID`,
    /// that parent has already been assigned one and already uploaded in the HeadCategories batch.
    /// `ensureRemoteID` does no network I/O (it's a local SwiftData read, and a `save()` only on
    /// first assignment), so this lookup costs nothing close to a second `syncHeadCategory` call.
    ///
    /// Safe to call repeatedly: `remoteID`s are only ever minted once, and every upload is an
    /// upsert keyed on that id, so re-running this after a partial failure (or just periodically)
    /// never creates duplicate rows — it just re-sends the same three batches.
    ///
    /// A batch for an empty table is skipped entirely (no request sent), and any batch failure
    /// propagates immediately: Swift's `try` already guarantees the Categories batch is never
    /// attempted if HeadCategories fails, and Wallets is never attempted if Categories fails.
    /// `userID` lets `SyncCoordinator` reuse the one id resolved per sync pass (Phase 4G.3A); `nil`
    /// (the default) preserves standalone-call behavior.
    func syncReferenceData(
        modelContext: ModelContext,
        userID: UUID? = nil,
        onProgress: (SupabaseSyncProgress) -> Void = { _ in }
    ) async throws {
        let resolvedUserID: UUID
        if let userID {
            resolvedUserID = userID
        } else {
            resolvedUserID = try await requireUserID()
        }
        let userID = resolvedUserID

        let headCategories = try modelContext.fetch(FetchDescriptor<HeadCategory>())
        let categories = try modelContext.fetch(FetchDescriptor<Category>())
        // Intentionally unfiltered (Phase 3D-1) — a soft-deleted `Wallet` must still upload with
        // `is_deleted = true` (`WalletDTO.isDeleted`), exactly like `syncEntries` already includes
        // soft-deleted `Entry` rows, so the tombstone actually reaches Supabase.
        let wallets = try modelContext.fetch(FetchDescriptor<Wallet>())
        onProgress(.preparing(headCategories: headCategories.count, categories: categories.count, wallets: wallets.count))

        // Phase 4G.1 — every `ensureRemoteID` call in these three loops mints without saving;
        // each loop commits once, after minting, rather than once per row (see `ensureRemoteID`'s
        // own doc comment for the durability trade-off this accepts).
        let headCategoryDTOs = try headCategories.map { headCategory in
            HeadCategoryDTO(
                headCategory: headCategory,
                remoteID: try ensureRemoteID(for: headCategory, modelContext: modelContext, save: false),
                userID: userID
            )
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
        if !headCategoryDTOs.isEmpty {
            onProgress(.uploadingHeadCategories(count: headCategoryDTOs.count))
            try await uploader.upsertHeadCategories(headCategoryDTOs)
        }

        let categoryDTOs = try categories.map { category in
            CategoryDTO(
                category: category,
                remoteID: try ensureRemoteID(for: category, modelContext: modelContext, save: false),
                // Never re-uploads the parent — every HeadCategory already got its remoteID (and
                // was already uploaded) above, so this is purely a local id lookup; already saved
                // by the headCategories loop's own commit, so this is never the save that persists it.
                headCategoryRemoteID: try ensureRemoteID(for: category.headCategory, modelContext: modelContext, save: false),
                userID: userID
            )
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
        if !categoryDTOs.isEmpty {
            onProgress(.uploadingCategories(count: categoryDTOs.count))
            try await uploader.upsertCategories(categoryDTOs)
        }

        let walletDTOs = try wallets.map { wallet in
            WalletDTO(
                wallet: wallet,
                remoteID: try ensureRemoteID(for: wallet, modelContext: modelContext, save: false),
                userID: userID
            )
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
        if !walletDTOs.isEmpty {
            onProgress(.uploadingWallets(count: walletDTOs.count))
            try await uploader.upsertWallets(walletDTOs)
        }

        onProgress(.completed)
    }

    /// Uploads every local `Entry` for the current user as one batch upsert — Phase 3B-2. Not
    /// wired into any automatic trigger, model-mutation call site, or `syncReferenceData` chain
    /// yet; this is a standalone, explicitly-invoked operation exactly like `syncReferenceData`
    /// was when it was first added.
    ///
    /// **Assumes reference data is already synced.** Unlike `syncReferenceData`'s own Category →
    /// HeadCategory handling, this method does *not* call `ensureRemoteID` on `entry.wallet`,
    /// `entry.destinationWallet`, or `entry.category` — it assumes a prior `syncReferenceData(
    /// modelContext:)` call already gave each of them a `remoteID` and uploaded them. If any of
    /// those is still missing one, `EntryDTO.init` throws `EntryDTOMappingError` rather than this
    /// method silently minting one or skipping the row. Composing the two is the caller's job and
    /// needs no new chaining API: calling `syncReferenceData(modelContext:)` followed by
    /// `syncEntries(modelContext:)` is exactly 3 reference-data batches + 1 entries batch, with no
    /// duplicated requests — `syncEntries` only ever touches the `entries` table.
    ///
    /// **Includes soft-deleted entries.** `Entry.isSoftDeleted` rows are *not* filtered out of this
    /// batch — each one uploads with `is_deleted = true` (see `EntryDTO.isDeleted`), since a
    /// deletion made on this device needs to reach Supabase, not disappear from the sync input
    /// entirely. This method also never mints a new `remoteID` for the `Entry` the way
    /// `TransactionSaving.createEntry` never does for ordinary creation — the one place this
    /// method *does* mint is the same `ensureRemoteID` used everywhere else, for an `Entry` that
    /// has never been synced before.
    ///
    /// Exactly one network request, regardless of how many local entries exist (an empty store
    /// sends none, same as `syncReferenceData`'s per-table skip).
    /// `userID` lets `SyncCoordinator` reuse the one id resolved per sync pass (Phase 4G.3A); `nil`
    /// (the default) preserves standalone-call behavior.
    func syncEntries(
        modelContext: ModelContext,
        userID: UUID? = nil,
        onProgress: (SupabaseSyncProgress) -> Void = { _ in }
    ) async throws {
        let resolvedUserID: UUID
        if let userID {
            resolvedUserID = userID
        } else {
            resolvedUserID = try await requireUserID()
        }
        let userID = resolvedUserID

        let entries = try modelContext.fetch(FetchDescriptor<Entry>())
        onProgress(.preparingEntries(count: entries.count))
        EntrySyncDiagnosticLog.log("syncEntries: fetched \(entries.count) local entries (modelContext=\(ObjectIdentifier(modelContext)))")

        // Phase 4G.5 — each entry is mapped independently rather than via one throwing `.map`.
        // Before this fix, a single `Entry` with an unresolvable relationship (its `wallet`/
        // `category`/`destinationWallet` missing a `remoteID` — see `EntryDTO.init`'s own
        // `EntryDTOMappingError` cases) made the whole `.map` throw, which meant `upsertEntries`
        // was never called at all — every *other*, perfectly valid local `Entry` silently failed
        // to upload too, with no distinguishing error. Looping and catching per entry means one
        // bad row is skipped (and logged, below) while every entry that maps successfully is
        // still collected into `entryDTOs` and uploaded in the same batch as before.
        var entryDTOs: [EntryDTO] = []
        entryDTOs.reserveCapacity(entries.count)
        for entry in entries {
            // Validate every dependency *before* minting anything for this entry. Minting the
            // entry's own remoteID first (then discovering a dependency is unmappable) would
            // leave that mint sitting as an uncommitted change that the one batched `save()`
            // below would still persist — silently giving a never-uploaded entry a remoteID
            // anyway. Checking dependencies up front means a skipped entry is left completely
            // untouched, exactly as if `syncEntries` had never looked at it.
            do {
                try validateEntryDependencies(entry)
                _ = try ensureRemoteID(for: entry, modelContext: modelContext, save: false)
                let dto = try EntryDTO(entry: entry, userID: userID)
                entryDTOs.append(dto)
            } catch {
                // Not DEBUG-gated — a skipped entry is real, user-visible data loss-in-waiting
                // (it stays local-only until whatever made it unmappable is fixed), not just a
                // debugging curiosity.
                Self.logger.error(
                    "syncEntries: skipping unmappable entry local=\(String(describing: entry.persistentModelID), privacy: .public) amount=\(String(describing: entry.amount), privacy: .public) date=\(String(describing: entry.date), privacy: .public) note=\"\(entry.note, privacy: .public)\" — \(String(describing: error), privacy: .public)"
                )
            }
        }
        // Phase 4G.1 — one commit for every remoteID minted above, not one per entry. Phase
        // 4G.3A — skipped entirely when nothing needed minting.
        if modelContext.hasChanges {
            try modelContext.save()
        }

        if !entryDTOs.isEmpty {
            onProgress(.uploadingEntries(count: entryDTOs.count))
            try await uploader.upsertEntries(entryDTOs)
        }

        onProgress(.completed)
    }

    /// Uploads every local `Budget` for the current user as one batch upsert — Phase 3C. Sits
    /// between `syncReferenceData` and `syncEntries` in the documented sync order: a `Budget` row
    /// references a `Category` by remote id (`category_id`), so its parent must already have a
    /// `remoteID` — exactly the same dependency shape `syncCategory` has on its parent
    /// `HeadCategory`. Rather than require the caller to run `syncReferenceData` first (which
    /// `syncEntries` does, undefended), this resolves each budget's category's `remoteID` via the
    /// same local-only `ensureRemoteID` used everywhere else, so `syncBudgets` is safe to call even
    /// if a category was never previously synced.
    ///
    /// Exactly one network request, regardless of row count — an empty local store sends none.
    /// `userID` lets `SyncCoordinator` reuse the one id resolved per sync pass (Phase 4G.3A); `nil`
    /// (the default) preserves standalone-call behavior.
    func syncBudgets(
        modelContext: ModelContext,
        userID: UUID? = nil,
        onProgress: (SupabaseSyncProgress) -> Void = { _ in }
    ) async throws {
        let resolvedUserID: UUID
        if let userID {
            resolvedUserID = userID
        } else {
            resolvedUserID = try await requireUserID()
        }
        let userID = resolvedUserID

        let fetchedBudgets = try modelContext.fetch(FetchDescriptor<Budget>())
        // Phase 4G.6 — collapse local natural-key duplicates (same `Category` + month + year)
        // before building any DTO. See `reconcileDuplicateNaturalKeyBudgets`'s own doc comment
        // for exactly how/why these arise; without this, two different local `Budget` objects
        // for the same natural key would mint two different `remoteID`s and upload two rows that
        // violate Supabase's `budgets_user_id_category_id_month_year_key` unique constraint
        // (Postgres error 23505) — which previously aborted this entire sync pass, including
        // `syncEntries` right after it.
        let budgets = reconcileDuplicateNaturalKeyBudgets(fetchedBudgets, modelContext: modelContext)
        if modelContext.hasChanges {
            try modelContext.save()
        }
        onProgress(.preparingBudgets(count: budgets.count))

        let budgetDTOs = try budgets.map { budget in
            BudgetDTO(
                budget: budget,
                remoteID: try ensureRemoteID(for: budget, modelContext: modelContext, save: false),
                // The category's own remoteID is normally already durable from a prior
                // `syncReferenceData` run; if it isn't, this mints it too, batched into the same
                // single commit below rather than its own separate save.
                categoryRemoteID: try ensureRemoteID(for: budget.category, modelContext: modelContext, save: false),
                userID: userID
            )
        }
        // Phase 4G.1 — one commit for every remoteID minted above, not one per budget. Phase
        // 4G.3A — skipped entirely when nothing needed minting.
        if modelContext.hasChanges {
            try modelContext.save()
        }
        if !budgetDTOs.isEmpty {
            onProgress(.uploadingBudgets(count: budgetDTOs.count))
            try await uploader.upsertBudgets(budgetDTOs)
        }

        onProgress(.completed)
    }

    // MARK: - Helpers

    /// Phase 4G.6 — collapses local `Budget` duplicates that share the same natural key
    /// (`Category` + `month` + `year` — the exact columns behind Supabase's
    /// `budgets_user_id_category_id_month_year_key` unique constraint) into one survivor, so
    /// `syncBudgets` never builds two `BudgetDTO`s that would upsert as two different rows for
    /// what the database considers a single budget.
    ///
    /// Two local `Budget` objects for the same `Category`/month/year arise because `pullBudgets`
    /// merges purely by `remoteID` (see its own doc comment) — it has no way to recognize that an
    /// incoming remote row and a pre-existing, never-synced local `Budget` (`remoteID == nil`)
    /// represent the same real-world budget, so it simply inserts the remote one as a brand-new
    /// local object alongside the pre-existing one. From that point on, both objects are genuinely
    /// local `Budget`s with *different* `remoteID`s (one already assigned by a prior sync
    /// elsewhere, one still nil) describing the same natural key — exactly the "local and remote
    /// records can have different IDs for the same natural budget" scenario this phase fixes.
    ///
    /// Grouping key is the local `Category` object's own identity (`ObjectIdentifier`), not
    /// `Category.remoteID` — `pullBudgets` always resolves a pulled `Budget`'s category against
    /// an *existing* local `Category` row (never minting a new one), so two local `Budget`s for
    /// the same natural key always already point at the same local `Category` instance by the
    /// time this runs.
    ///
    /// Reconciliation is deterministic, never "blind": within each duplicate group,
    /// - a `Budget` that already carries a `remoteID` always wins the surviving identity over one
    ///   that doesn't (an identity already known to Supabase must never be discarded for a
    ///   not-yet-synced duplicate) — preserving "remoteID identity whenever it already matches";
    /// - field values (last-write-wins) always come from whichever duplicate has the latest
    ///   `updatedAt`, even when that isn't the surviving object;
    /// - ties are broken by `persistentModelID`'s own description, so the outcome never depends
    ///   on fetch/dictionary ordering.
    /// Every other duplicate in the group is deleted from `modelContext` — this is the one
    /// deliberate, narrowly-scoped exception to "never delete budgets blindly": each deletion only
    /// ever removes a row proven, by natural key, to be a duplicate of the surviving one, never a
    /// distinct budget.
    private func reconcileDuplicateNaturalKeyBudgets(_ budgets: [Budget], modelContext: ModelContext) -> [Budget] {
        var groups: [ObjectIdentifier: [String: [Budget]]] = [:]
        for budget in budgets {
            let categoryKey = ObjectIdentifier(budget.category)
            let naturalKey = "\(budget.month)-\(budget.year)"
            groups[categoryKey, default: [:]][naturalKey, default: []].append(budget)
        }

        var survivors: [Budget] = []
        for byNaturalKey in groups.values {
            for duplicates in byNaturalKey.values {
                guard duplicates.count > 1 else {
                    survivors.append(duplicates[0])
                    continue
                }
                survivors.append(reconcileDuplicates(duplicates, modelContext: modelContext))
            }
        }
        return survivors
    }

    /// The per-duplicate-group resolution `reconcileDuplicateNaturalKeyBudgets` delegates to —
    /// see that method's own doc comment for the winner/LWW/deletion rules this implements.
    private func reconcileDuplicates(_ duplicates: [Budget], modelContext: ModelContext) -> Budget {
        let winner = duplicates.sorted { lhs, rhs in
            if (lhs.remoteID != nil) != (rhs.remoteID != nil) {
                return lhs.remoteID != nil
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return String(describing: lhs.persistentModelID) < String(describing: rhs.persistentModelID)
        }[0]

        let latest = duplicates.max { $0.updatedAt < $1.updatedAt }!
        if latest !== winner {
            winner.monthlyLimit = latest.monthlyLimit
            winner.isHidden = latest.isHidden
            winner.isFixed = latest.isFixed
            winner.updatedAt = latest.updatedAt
        }
        if winner.remoteID == nil {
            winner.remoteID = duplicates.first(where: { $0.remoteID != nil })?.remoteID
        }

        for duplicate in duplicates where duplicate !== winner {
            EntrySyncDiagnosticLog.log(
                "syncBudgets: reconciling duplicate natural-key Budget local=\(duplicate.persistentModelID) remoteID=\(duplicate.remoteID?.uuidString ?? "nil") month=\(duplicate.month) year=\(duplicate.year) into survivor local=\(winner.persistentModelID) remoteID=\(winner.remoteID?.uuidString ?? "nil")"
            )
            modelContext.delete(duplicate)
        }
        return winner
    }

    /// Phase 4G.5 — `syncEntries`'s own pre-check, mirroring exactly the three relationship
    /// guards `EntryDTO.init(entry:userID:)` performs (`missingWalletRemoteID`/
    /// `missingDestinationWalletRemoteID`/`missingCategoryRemoteID`), but run *before*
    /// `ensureRemoteID` touches the entry itself — see `syncEntries`'s own call site for why
    /// that ordering matters. Deliberately does not duplicate the `missingEntryRemoteID` case:
    /// `syncEntries` always calls `ensureRemoteID` on the entry right after this succeeds, which
    /// never leaves that one nil.
    private func validateEntryDependencies(_ entry: Entry) throws {
        guard entry.wallet.remoteID != nil else {
            throw EntryDTOMappingError.missingWalletRemoteID
        }
        if let destinationWallet = entry.destinationWallet, destinationWallet.remoteID == nil {
            throw EntryDTOMappingError.missingDestinationWalletRemoteID
        }
        if let category = entry.category, category.remoteID == nil {
            throw EntryDTOMappingError.missingCategoryRemoteID
        }
    }

    /// Internal (not `private`) since Phase 4G.3A — `SyncCoordinator.runOneSyncPass` calls this
    /// once per sync pass and threads the result through all six steps via their `userID:`
    /// parameter, instead of each step re-resolving it independently.
    func requireUserID() async throws -> UUID {
        guard let userID = try await userProvider.currentUserID() else {
            throw SupabaseSyncError.notAuthenticated
        }
        return userID
    }

    /// If `model.remoteID` is already set, returns it unchanged — a retried or repeated sync must
    /// never mint a second identity for the same local row. Otherwise mints a fresh `UUID` and
    /// assigns it. Purely local — no network I/O — so calling this for the same already-synced
    /// model multiple times within one `syncReferenceData` run (e.g. a `Category`'s parent
    /// `HeadCategory`) costs nothing beyond a property read.
    ///
    /// `save` defaults to `true` — immediately durable, matching every standalone single-row
    /// caller (`syncHeadCategory`/`syncCategory`/`syncWallet`), where "once per row" and "once per
    /// model" are the same thing anyway. The batch methods (`syncReferenceData`/`syncBudgets`/
    /// `syncEntries`) pass `save: false` for every call inside their per-row `.map` loops (Phase
    /// 4G.1) and call `modelContext.save()` themselves exactly once after each table's loop
    /// finishes — minting N remoteIDs used to mean N separate synchronous disk commits in a single
    /// sync pass (a real, measured source of main-thread stalling on a store with many
    /// never-before-synced rows); batching those into one save per table cuts that to one commit
    /// per table while leaving the identity itself just as durable by the time the batch method
    /// returns. The trade-off: a crash between minting and that one batched save now risks losing
    /// every remoteID minted in that table's loop, not just the last one — narrower per-row
    /// durability than before, in exchange for not blocking the main thread once per row.
    private func ensureRemoteID<T: RemoteSyncable>(for model: T, modelContext: ModelContext, save: Bool = true) throws -> UUID {
        if let existing = model.remoteID {
            return existing
        }
        let minted = UUID()
        model.remoteID = minted
        // Phase 4H — this is the one `ensureRemoteID` log worth keeping: it only ever fires for a
        // genuinely new identity (not once per already-synced row per sync, which the removed
        // "reusing existing remoteID" line used to do), so it stays useful for diagnosing *why* a
        // given row never got a `remoteID` without flooding the console on every normal sync.
        EntrySyncDiagnosticLog.log("ensureRemoteID: minting NEW remoteID=\(minted) for \(T.self), save=\(save)")
        if save {
            try modelContext.save()
        }
        return minted
    }
}
