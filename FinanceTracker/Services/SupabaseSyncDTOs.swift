import Foundation

/// Wire format for the `head_categories` table. A plain, standalone `Codable` type rather than
/// `HeadCategory` itself conforming to `Codable` — the SwiftData model stays free of any
/// Supabase-shaped concerns, exactly like `ProfileDTO` already does for `profiles`.
struct HeadCategoryDTO: Codable, Equatable {
    var id: UUID
    var userID: UUID
    var name: String
    var icon: String
    var colorHex: String
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case name
        case icon
        case colorHex = "color_hex"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Plain memberwise init (Phase 4B) — the decode direction: `SupabaseSyncService.
    /// pullReferenceData` doesn't actually use this directly (a pulled row is decoded straight
    /// from JSON via the synthesized `Decodable` conformance), but tests constructing a DTO to
    /// stand in for "what the server returned" need it, since defining the encode-direction
    /// `init(headCategory:remoteID:userID:)` below suppresses Swift's synthesized memberwise init.
    init(id: UUID, userID: UUID, name: String, icon: String, colorHex: String, sortOrder: Int, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.userID = userID
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// `remoteID`/`userID` are supplied explicitly rather than read off `headCategory` itself —
    /// by the time this is called, `SupabaseSyncService` has already ensured `headCategory.
    /// remoteID` is non-nil (minting one if this is the first upload) and resolved the
    /// authenticated user's id; this initializer only ever maps already-resolved values.
    init(headCategory: HeadCategory, remoteID: UUID, userID: UUID) {
        self.id = remoteID
        self.userID = userID
        self.name = headCategory.name
        self.icon = headCategory.icon
        self.colorHex = headCategory.colorHex
        self.sortOrder = headCategory.sortOrder
        self.createdAt = headCategory.createdAt
        self.updatedAt = headCategory.updatedAt
    }
}

/// Wire format for the `categories` table. `headCategoryID` is the parent `HeadCategory`'s own
/// `remoteID` — resolved by `SupabaseSyncService.syncCategory` before this is constructed, per
/// the documented HeadCategory → Category → Wallet dependency order.
struct CategoryDTO: Codable, Equatable {
    var id: UUID
    var userID: UUID
    var headCategoryID: UUID
    var name: String
    var customIcon: String?
    var iconIsEmoji: Bool
    var customColorHex: String?
    var isSavings: Bool
    var isArchived: Bool
    var isIncome: Bool
    var isFixedPlannedCategory: Bool
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case headCategoryID = "head_category_id"
        case name
        case customIcon = "custom_icon"
        case iconIsEmoji = "icon_is_emoji"
        case customColorHex = "custom_color_hex"
        case isSavings = "is_savings"
        case isArchived = "is_archived"
        case isIncome = "is_income"
        case isFixedPlannedCategory = "is_fixed_planned_category"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Plain memberwise init (Phase 4B) — see `HeadCategoryDTO`'s equivalent init's doc comment
    /// for why this exists alongside the encode-direction init below.
    init(
        id: UUID, userID: UUID, headCategoryID: UUID, name: String, customIcon: String?,
        iconIsEmoji: Bool, customColorHex: String?, isSavings: Bool, isArchived: Bool, isIncome: Bool,
        isFixedPlannedCategory: Bool, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.userID = userID
        self.headCategoryID = headCategoryID
        self.name = name
        self.customIcon = customIcon
        self.iconIsEmoji = iconIsEmoji
        self.customColorHex = customColorHex
        self.isSavings = isSavings
        self.isArchived = isArchived
        self.isIncome = isIncome
        self.isFixedPlannedCategory = isFixedPlannedCategory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(category: Category, remoteID: UUID, headCategoryRemoteID: UUID, userID: UUID) {
        self.id = remoteID
        self.userID = userID
        self.headCategoryID = headCategoryRemoteID
        self.name = category.name
        self.customIcon = category.customIcon
        self.iconIsEmoji = category.iconIsEmoji
        self.customColorHex = category.customColorHex
        self.isSavings = category.isSavings
        self.isArchived = category.isArchived
        self.isIncome = category.isIncome
        self.isFixedPlannedCategory = category.isFixedPlannedCategory
        self.createdAt = category.createdAt
        self.updatedAt = category.updatedAt
    }
}

/// Wire format for the `wallets` table. `startingBalance`/`goalAmount` travel as plain
/// `Decimal` — unlike CKRecord (see `CloudKitSharedEventMapper`'s cents-as-`Int64` workaround),
/// PostgREST/Postgres's `numeric` column type encodes a Swift `Decimal` directly with no
/// precision workaround needed.
struct WalletDTO: Codable, Equatable {
    var id: UUID
    var userID: UUID
    var name: String
    var type: WalletType
    var colorHex: String
    var icon: String
    var startingBalance: Decimal
    var goalAmount: Decimal?
    var includeInNetWorth: Bool
    var isDefault: Bool
    var isArchived: Bool
    var sortOrder: Int
    /// Wire name matches the column directly (`is_deleted`) — unlike `Entry.isSoftDeleted`, no
    /// Swift-side name collision applies to this plain `Codable` struct, so no renaming is needed
    /// here either; mapped from `Wallet.isSoftDeleted`. See `EntryDTO.isDeleted`'s doc comment for
    /// the full rationale this mirrors. Never filtered out of `syncReferenceData`'s batch — a
    /// soft-deleted wallet must still upload so the tombstone actually reaches Supabase.
    var isDeleted: Bool
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case name
        case type
        case colorHex = "color_hex"
        case icon
        case startingBalance = "starting_balance"
        case goalAmount = "goal_amount"
        case includeInNetWorth = "include_in_net_worth"
        case isDefault = "is_default"
        case isArchived = "is_archived"
        case sortOrder = "sort_order"
        case isDeleted = "is_deleted"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Plain memberwise init (Phase 4B) — see `HeadCategoryDTO`'s equivalent init's doc comment
    /// for why this exists alongside the encode-direction init below.
    init(
        id: UUID, userID: UUID, name: String, type: WalletType, colorHex: String, icon: String,
        startingBalance: Decimal, goalAmount: Decimal?, includeInNetWorth: Bool, isDefault: Bool,
        isArchived: Bool, sortOrder: Int, isDeleted: Bool, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.type = type
        self.colorHex = colorHex
        self.icon = icon
        self.startingBalance = startingBalance
        self.goalAmount = goalAmount
        self.includeInNetWorth = includeInNetWorth
        self.isDefault = isDefault
        self.isArchived = isArchived
        self.sortOrder = sortOrder
        self.isDeleted = isDeleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(wallet: Wallet, remoteID: UUID, userID: UUID) {
        self.id = remoteID
        self.userID = userID
        self.name = wallet.name
        self.type = wallet.type
        self.colorHex = wallet.colorHex
        self.icon = wallet.icon
        self.startingBalance = wallet.startingBalance
        self.goalAmount = wallet.goalAmount
        self.includeInNetWorth = wallet.includeInNetWorth
        self.isDefault = wallet.isDefault
        self.isArchived = wallet.isArchived
        self.sortOrder = wallet.sortOrder
        self.isDeleted = wallet.isSoftDeleted
        self.createdAt = wallet.createdAt
        self.updatedAt = wallet.updatedAt
    }
}

/// Wire format for the `budgets` table. `categoryID` is the referenced `Category`'s own
/// `remoteID` — resolved by `SupabaseSyncService.syncBudgets` before this is constructed, exactly
/// like `CategoryDTO.headCategoryID` is resolved before `CategoryDTO` is built.
struct BudgetDTO: Codable, Equatable {
    var id: UUID
    var userID: UUID
    var categoryID: UUID
    var monthlyLimit: Decimal
    var month: Int
    var year: Int
    var isHidden: Bool
    var isFixed: Bool
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case categoryID = "category_id"
        case monthlyLimit = "monthly_limit"
        case month
        case year
        case isHidden = "is_hidden"
        case isFixed = "is_fixed"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Plain memberwise init (Phase 4D) — see `HeadCategoryDTO`'s equivalent init's doc comment
    /// for why this exists alongside the encode-direction init below.
    init(
        id: UUID, userID: UUID, categoryID: UUID, monthlyLimit: Decimal, month: Int, year: Int,
        isHidden: Bool, isFixed: Bool, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.userID = userID
        self.categoryID = categoryID
        self.monthlyLimit = monthlyLimit
        self.month = month
        self.year = year
        self.isHidden = isHidden
        self.isFixed = isFixed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(budget: Budget, remoteID: UUID, categoryRemoteID: UUID, userID: UUID) {
        self.id = remoteID
        self.userID = userID
        self.categoryID = categoryRemoteID
        self.monthlyLimit = budget.monthlyLimit
        self.month = budget.month
        self.year = budget.year
        self.isHidden = budget.isHidden
        self.isFixed = budget.isFixed
        self.createdAt = budget.createdAt
        self.updatedAt = budget.updatedAt
    }
}

/// Thrown by `EntryDTO.init(entry:userID:)` when a required remote identity is missing. Unlike
/// `HeadCategoryDTO`/`CategoryDTO`/`WalletDTO` (which take an already-resolved `remoteID: UUID`
/// supplied by the caller, never failing), `Entry`'s mapping reads `remoteID` directly off the
/// entry and its relationships and validates them itself — remote-ID *creation* stays
/// `SupabaseSyncService`'s job (via `ensureRemoteID`), but `EntryDTO` never mints one silently; a
/// missing identity is a mapping failure, not a value to paper over.
enum EntryDTOMappingError: Error, Equatable {
    case missingEntryRemoteID
    case missingWalletRemoteID
    case missingDestinationWalletRemoteID
    case missingCategoryRemoteID
}

/// Wire format for the `entries` table. `walletID`/`destinationWalletID`/`categoryID` are each the
/// referenced model's own `remoteID` — never minted here (see `EntryDTOMappingError`), and assumed
/// already uploaded by a prior `SupabaseSyncService.syncReferenceData` run (`SupabaseSyncService.
/// syncEntries`'s own doc comment covers this dependency explicitly).
///
/// `isDeleted` (wire name, matching the `is_deleted` column) is deliberately named differently
/// from its source, `Entry.isSoftDeleted` — the Swift property name on the model had to avoid
/// `isDeleted` outright, since that exact name collides with `NSManagedObject`'s own reserved
/// `isDeleted` flag under SwiftData/Core Data and silently fails to persist (see `Entry.
/// isSoftDeleted`'s doc comment, Phase 3B-1). No such collision exists for a plain `Codable`
/// struct, so this DTO uses the column's natural name directly.
///
/// Soft-deleted entries are valid, expected input to this DTO — `SupabaseSyncService.syncEntries`
/// includes them in its batch deliberately, so a deletion made on this device can reach Supabase
/// as `is_deleted = true` rather than being silently dropped.
struct EntryDTO: Codable, Equatable {
    var id: UUID
    var userID: UUID
    var walletID: UUID
    var destinationWalletID: UUID?
    var categoryID: UUID?
    var amount: Decimal
    var date: Date
    var note: String
    var type: EntryType
    var recurrence: RecurrenceRule
    var excludeFromBudget: Bool
    var isPlannedExpense: Bool
    var isDeleted: Bool
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case walletID = "wallet_id"
        case destinationWalletID = "destination_wallet_id"
        case categoryID = "category_id"
        case amount
        case date
        case note
        case type
        case recurrence
        case excludeFromBudget = "exclude_from_budget"
        case isPlannedExpense = "is_planned_expense"
        case isDeleted = "is_deleted"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Plain memberwise init (Phase 4E) — see `HeadCategoryDTO`'s equivalent init's doc comment
    /// for why this exists alongside the encode-direction init below: tests constructing a DTO to
    /// stand in for "what the server returned" have no `Entry` to build the throwing init from.
    init(
        id: UUID, userID: UUID, walletID: UUID, destinationWalletID: UUID?, categoryID: UUID?,
        amount: Decimal, date: Date, note: String, type: EntryType, recurrence: RecurrenceRule,
        excludeFromBudget: Bool, isPlannedExpense: Bool, isDeleted: Bool, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.userID = userID
        self.walletID = walletID
        self.destinationWalletID = destinationWalletID
        self.categoryID = categoryID
        self.amount = amount
        self.date = date
        self.note = note
        self.type = type
        self.recurrence = recurrence
        self.excludeFromBudget = excludeFromBudget
        self.isPlannedExpense = isPlannedExpense
        self.isDeleted = isDeleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// `userID` is supplied separately (from the authenticated Supabase session), exactly like the
    /// other three DTOs — never taken from `entry` itself, which has no such field. Throws rather
    /// than uploading an invalid row if `entry` itself, its `wallet`, its `destinationWallet` (when
    /// present), or its `category` (when present) lack a `remoteID` — each of those must already
    /// have been assigned one by `SupabaseSyncService` before this is called.
    init(entry: Entry, userID: UUID) throws {
        guard let remoteID = entry.remoteID else {
            throw EntryDTOMappingError.missingEntryRemoteID
        }
        guard let walletRemoteID = entry.wallet.remoteID else {
            throw EntryDTOMappingError.missingWalletRemoteID
        }
        let destinationWalletID: UUID?
        if let destinationWallet = entry.destinationWallet {
            guard let destinationRemoteID = destinationWallet.remoteID else {
                throw EntryDTOMappingError.missingDestinationWalletRemoteID
            }
            destinationWalletID = destinationRemoteID
        } else {
            destinationWalletID = nil
        }
        let categoryID: UUID?
        if let category = entry.category {
            guard let categoryRemoteID = category.remoteID else {
                throw EntryDTOMappingError.missingCategoryRemoteID
            }
            categoryID = categoryRemoteID
        } else {
            categoryID = nil
        }

        self.id = remoteID
        self.userID = userID
        self.walletID = walletRemoteID
        self.destinationWalletID = destinationWalletID
        self.categoryID = categoryID
        self.amount = entry.amount
        self.date = entry.date
        self.note = entry.note
        self.type = entry.type
        self.recurrence = entry.recurrence
        self.excludeFromBudget = entry.excludeFromBudget
        self.isPlannedExpense = entry.isPlannedExpense
        self.isDeleted = entry.isSoftDeleted
        self.createdAt = entry.createdAt
        self.updatedAt = entry.updatedAt
    }
}
