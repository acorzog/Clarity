import Foundation
import SwiftData

/// Manual, local, full-fidelity backup/restore of the entire personal store — the "move my data
/// to another device" stopgap chosen instead of CloudKit-mirrored sync (see
/// `CollaborationFeatureFlag`'s doc comment for why CloudKit sync isn't available yet: the app is
/// signed under a free Personal Team, which cannot request the iCloud capability at all).
///
/// A plain JSON snapshot, shared/opened like any other file (`ShareLink`/`.fileImporter` in
/// `BackupRestoreView`) — no entitlements, no CloudKit, no new persistent identifiers on the
/// `@Model` classes themselves. Relationships are encoded as array indices scoped to one export,
/// not stable IDs, which is why `restore` is a full replace rather than a merge: reusing a
/// snapshot's indices only makes sense against the exact object graph it was built from.
///
/// `SpendingInsight` is a regenerable cache, not user data, and is intentionally excluded.
enum LocalBackupService {
    struct DataSnapshot: Codable {
        var version = 1
        var exportedAt = Date.now
        var headCategories: [HeadCategorySnapshot] = []
        var categories: [CategorySnapshot] = []
        var wallets: [WalletSnapshot] = []
        var entries: [EntrySnapshot] = []
        var budgets: [BudgetSnapshot] = []
        var goals: [GoalSnapshot] = []
        var goalContributions: [GoalContributionSnapshot] = []
        var people: [PersonSnapshot] = []
        var sharedEvents: [SharedEventSnapshot] = []
        var sharedExpenses: [SharedExpenseSnapshot] = []
        var sharedExpenseParticipants: [SharedExpenseParticipantSnapshot] = []
        var settlements: [SettlementSnapshot] = []
        var eventParticipants: [EventParticipantSnapshot] = []
    }

    struct HeadCategorySnapshot: Codable {
        var name: String
        var icon: String
        var colorHex: String
        var sortOrder: Int
        var remoteID: UUID?
        var createdAt: Date
        var updatedAt: Date

        init(name: String, icon: String, colorHex: String, sortOrder: Int, remoteID: UUID?, createdAt: Date, updatedAt: Date) {
            self.name = name
            self.icon = icon
            self.colorHex = colorHex
            self.sortOrder = sortOrder
            self.remoteID = remoteID
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        /// Custom, rather than synthesized, only so `remoteID`/`createdAt`/`updatedAt` can default
        /// safely when restoring a backup exported before they existed — same lesson `EntrySnapshot`'s
        /// `isPlannedExpense` backward-compat decoder already established. There's no better proxy
        /// for a missing timestamp here (unlike `EntrySnapshot`, which can fall back to its own
        /// `date`), so both default to `.now` — the restored row's local history just starts now.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            icon = try container.decode(String.self, forKey: .icon)
            colorHex = try container.decode(String.self, forKey: .colorHex)
            sortOrder = try container.decode(Int.self, forKey: .sortOrder)
            remoteID = try container.decodeIfPresent(UUID.self, forKey: .remoteID)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        }
    }

    struct CategorySnapshot: Codable {
        var name: String
        var customIcon: String?
        var iconIsEmoji: Bool
        var customColorHex: String?
        var isSavings: Bool
        var isArchived: Bool
        var isIncome: Bool
        var headCategoryIndex: Int
        var remoteID: UUID?
        var createdAt: Date
        var updatedAt: Date

        init(
            name: String, customIcon: String?, iconIsEmoji: Bool, customColorHex: String?,
            isSavings: Bool, isArchived: Bool, isIncome: Bool, headCategoryIndex: Int,
            remoteID: UUID?, createdAt: Date, updatedAt: Date
        ) {
            self.name = name
            self.customIcon = customIcon
            self.iconIsEmoji = iconIsEmoji
            self.customColorHex = customColorHex
            self.isSavings = isSavings
            self.isArchived = isArchived
            self.isIncome = isIncome
            self.headCategoryIndex = headCategoryIndex
            self.remoteID = remoteID
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        /// Same backward-compat rationale as `HeadCategorySnapshot.init(from:)`.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            customIcon = try container.decodeIfPresent(String.self, forKey: .customIcon)
            iconIsEmoji = try container.decode(Bool.self, forKey: .iconIsEmoji)
            customColorHex = try container.decodeIfPresent(String.self, forKey: .customColorHex)
            isSavings = try container.decode(Bool.self, forKey: .isSavings)
            isArchived = try container.decode(Bool.self, forKey: .isArchived)
            isIncome = try container.decode(Bool.self, forKey: .isIncome)
            headCategoryIndex = try container.decode(Int.self, forKey: .headCategoryIndex)
            remoteID = try container.decodeIfPresent(UUID.self, forKey: .remoteID)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        }
    }

    struct WalletSnapshot: Codable {
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
        /// Phase 3D-1 soft-delete marker — see `Wallet.isSoftDeleted`'s doc comment. Defaults
        /// `false` for a backup exported before this field existed, same as `EntrySnapshot.
        /// isSoftDeleted` below.
        var isSoftDeleted: Bool
        var remoteID: UUID?
        var createdAt: Date
        var updatedAt: Date

        init(
            name: String, type: WalletType, colorHex: String, icon: String, startingBalance: Decimal,
            goalAmount: Decimal?, includeInNetWorth: Bool, isDefault: Bool, isArchived: Bool, sortOrder: Int,
            isSoftDeleted: Bool = false, remoteID: UUID?, createdAt: Date, updatedAt: Date
        ) {
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
            self.isSoftDeleted = isSoftDeleted
            self.remoteID = remoteID
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        /// Same backward-compat rationale as `HeadCategorySnapshot.init(from:)`.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            type = try container.decode(WalletType.self, forKey: .type)
            colorHex = try container.decode(String.self, forKey: .colorHex)
            icon = try container.decode(String.self, forKey: .icon)
            startingBalance = try container.decode(Decimal.self, forKey: .startingBalance)
            goalAmount = try container.decodeIfPresent(Decimal.self, forKey: .goalAmount)
            includeInNetWorth = try container.decode(Bool.self, forKey: .includeInNetWorth)
            isDefault = try container.decode(Bool.self, forKey: .isDefault)
            isArchived = try container.decode(Bool.self, forKey: .isArchived)
            sortOrder = try container.decode(Int.self, forKey: .sortOrder)
            isSoftDeleted = try container.decodeIfPresent(Bool.self, forKey: .isSoftDeleted) ?? false
            remoteID = try container.decodeIfPresent(UUID.self, forKey: .remoteID)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        }
    }

    struct EntrySnapshot: Codable {
        var amount: Decimal
        var date: Date
        var note: String
        var type: EntryType
        var recurrence: RecurrenceRule
        var excludeFromBudget: Bool
        var isPlannedExpense: Bool
        /// Phase 3B-1 soft-delete marker — see `Entry.isSoftDeleted`'s doc comment. Defaults `false`
        /// for a backup exported before this field existed, same as `isPlannedExpense` below.
        var isSoftDeleted: Bool
        var categoryIndex: Int?
        var walletIndex: Int
        var destinationWalletIndex: Int?
        var remoteID: UUID?
        var createdAt: Date
        var updatedAt: Date

        init(
            amount: Decimal,
            date: Date,
            note: String,
            type: EntryType,
            recurrence: RecurrenceRule,
            excludeFromBudget: Bool,
            isPlannedExpense: Bool = false,
            isSoftDeleted: Bool = false,
            categoryIndex: Int?,
            walletIndex: Int,
            destinationWalletIndex: Int?,
            remoteID: UUID? = nil,
            createdAt: Date? = nil,
            updatedAt: Date? = nil
        ) {
            self.amount = amount
            self.date = date
            self.note = note
            self.type = type
            self.recurrence = recurrence
            self.excludeFromBudget = excludeFromBudget
            self.isPlannedExpense = isPlannedExpense
            self.isSoftDeleted = isSoftDeleted
            self.categoryIndex = categoryIndex
            self.walletIndex = walletIndex
            self.destinationWalletIndex = destinationWalletIndex
            self.remoteID = remoteID
            // Falls back to `date` (this entry's own transaction date) rather than `.now`, since
            // that's a meaningfully better stand-in for "when this was created" than the moment a
            // backup happens to be exported/restored — only reachable from this memberwise init
            // when a caller omits the timestamps outright (the decoder below always passes them).
            self.createdAt = createdAt ?? date
            self.updatedAt = updatedAt ?? date
        }

        /// Custom, rather than synthesized, so `isPlannedExpense`/`isSoftDeleted`/`remoteID`/
        /// `createdAt`/`updatedAt` can all default safely when restoring a backup exported before
        /// they existed — every other field is decoded exactly as synthesis would. Without this,
        /// restoring an older backup (several already exist, predating these fields) would fail
        /// outright on a missing key. `createdAt`/`updatedAt` fall back to this entry's own `date`
        /// — a meaningfully better proxy than "now" for a transaction that may be years old.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            amount = try container.decode(Decimal.self, forKey: .amount)
            date = try container.decode(Date.self, forKey: .date)
            note = try container.decode(String.self, forKey: .note)
            type = try container.decode(EntryType.self, forKey: .type)
            recurrence = try container.decode(RecurrenceRule.self, forKey: .recurrence)
            excludeFromBudget = try container.decode(Bool.self, forKey: .excludeFromBudget)
            isPlannedExpense = try container.decodeIfPresent(Bool.self, forKey: .isPlannedExpense) ?? false
            isSoftDeleted = try container.decodeIfPresent(Bool.self, forKey: .isSoftDeleted) ?? false
            categoryIndex = try container.decodeIfPresent(Int.self, forKey: .categoryIndex)
            walletIndex = try container.decode(Int.self, forKey: .walletIndex)
            destinationWalletIndex = try container.decodeIfPresent(Int.self, forKey: .destinationWalletIndex)
            remoteID = try container.decodeIfPresent(UUID.self, forKey: .remoteID)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? date
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? date
        }
    }

    struct BudgetSnapshot: Codable {
        var monthlyLimit: Decimal
        var month: Int
        var year: Int
        var isHidden: Bool
        var categoryIndex: Int
        var remoteID: UUID?
        var createdAt: Date
        var updatedAt: Date

        init(monthlyLimit: Decimal, month: Int, year: Int, isHidden: Bool, categoryIndex: Int, remoteID: UUID?, createdAt: Date, updatedAt: Date) {
            self.monthlyLimit = monthlyLimit
            self.month = month
            self.year = year
            self.isHidden = isHidden
            self.categoryIndex = categoryIndex
            self.remoteID = remoteID
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        /// Custom, rather than synthesized, only so `remoteID`/`createdAt`/`updatedAt` can default
        /// safely when restoring a backup exported before they existed — same backward-compat
        /// lesson `HeadCategorySnapshot`'s decoder already established. There's no better proxy for
        /// a missing timestamp here, so both default to `.now` — the restored row's local history
        /// just starts now.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            monthlyLimit = try container.decode(Decimal.self, forKey: .monthlyLimit)
            month = try container.decode(Int.self, forKey: .month)
            year = try container.decode(Int.self, forKey: .year)
            isHidden = try container.decode(Bool.self, forKey: .isHidden)
            categoryIndex = try container.decode(Int.self, forKey: .categoryIndex)
            remoteID = try container.decodeIfPresent(UUID.self, forKey: .remoteID)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        }
    }

    struct GoalSnapshot: Codable {
        var name: String
        var icon: String
        var colorHex: String
        var targetAmount: Decimal
        var createdAt: Date
        var sortOrder: Int
        var isArchived: Bool
        var targetDate: Date?
        var contextWalletIndex: Int?
    }

    struct GoalContributionSnapshot: Codable {
        var amount: Decimal
        var date: Date
        var note: String?
        var goalIndex: Int
        var transactionIndex: Int?
    }

    struct PersonSnapshot: Codable {
        var displayName: String
        var colorHex: String?
        var isCurrentUser: Bool
        var isFrequent: Bool
        var createdAt: Date
        var sharingAnchorID: UUID
    }

    struct SharedEventSnapshot: Codable {
        var title: String
        var icon: String?
        var colorHex: String?
        var status: SharedEventStatus
        var createdAt: Date
        var updatedAt: Date
        var startDate: Date?
        var endDate: Date?
        var remoteID: UUID?
        var isCollaborationEnabled: Bool
        var isRemoteOwned: Bool
        var participantIndices: [Int]
    }

    struct SharedExpenseSnapshot: Codable {
        var amount: Decimal
        var currency: String
        var note: String
        var date: Date
        var splitMethod: SharedSplitMethod
        var createdAt: Date
        var updatedAt: Date
        var remoteID: UUID?
        var categoryIndex: Int?
        var remoteCategoryName: String?
        var remoteCategoryIcon: String?
        var remoteCategoryColorHex: String?
        var paidByIndex: Int?
        var eventIndex: Int?
    }

    struct SharedExpenseParticipantSnapshot: Codable {
        var amount: Decimal
        var parts: Int?
        var remoteID: UUID?
        var personIndex: Int?
        var expenseIndex: Int?
    }

    struct SettlementSnapshot: Codable {
        var fromPersonIndex: Int?
        var toPersonIndex: Int?
        var amount: Decimal
        var paymentMethod: SettlementPaymentMethod
        var date: Date
        var createdAt: Date
        var remoteID: UUID?
        var eventIndex: Int?
        var transactionIndex: Int?
    }

    struct EventParticipantSnapshot: Codable {
        var role: ParticipantRole
        var userRecordID: String?
        var joinedAt: Date
        var isRemoved: Bool
        var eventIndex: Int?
        var personIndex: Int?
    }

    // MARK: - Export

    static func export(context: ModelContext) throws -> Data {
        let headCategories = try context.fetch(FetchDescriptor<HeadCategory>())
        let categories = try context.fetch(FetchDescriptor<Category>())
        let wallets = try context.fetch(FetchDescriptor<Wallet>())
        let entries = try context.fetch(FetchDescriptor<Entry>())
        let budgets = try context.fetch(FetchDescriptor<Budget>())
        let goals = try context.fetch(FetchDescriptor<Goal>())
        let goalContributions = try context.fetch(FetchDescriptor<GoalContribution>())
        let people = try context.fetch(FetchDescriptor<Person>())
        let sharedEvents = try context.fetch(FetchDescriptor<SharedEvent>())
        let sharedExpenses = try context.fetch(FetchDescriptor<SharedExpense>())
        let sharedExpenseParticipants = try context.fetch(FetchDescriptor<SharedExpenseParticipant>())
        let settlements = try context.fetch(FetchDescriptor<Settlement>())
        let eventParticipants = try context.fetch(FetchDescriptor<EventParticipant>())

        let headCategoryIndex = indexMap(headCategories)
        let categoryIndex = indexMap(categories)
        let walletIndex = indexMap(wallets)
        let entryIndex = indexMap(entries)
        let goalIndex = indexMap(goals)
        let personIndex = indexMap(people)
        let eventIndex = indexMap(sharedEvents)
        let expenseIndex = indexMap(sharedExpenses)

        var snapshot = DataSnapshot()

        snapshot.headCategories = headCategories.map {
            HeadCategorySnapshot(
                name: $0.name, icon: $0.icon, colorHex: $0.colorHex, sortOrder: $0.sortOrder,
                remoteID: $0.remoteID, createdAt: $0.createdAt, updatedAt: $0.updatedAt
            )
        }
        snapshot.categories = categories.map {
            CategorySnapshot(
                name: $0.name, customIcon: $0.customIcon, iconIsEmoji: $0.iconIsEmoji,
                customColorHex: $0.customColorHex, isSavings: $0.isSavings, isArchived: $0.isArchived,
                isIncome: $0.isIncome, headCategoryIndex: headCategoryIndex[ObjectIdentifier($0.headCategory)]!,
                remoteID: $0.remoteID, createdAt: $0.createdAt, updatedAt: $0.updatedAt
            )
        }
        snapshot.wallets = wallets.map {
            WalletSnapshot(
                name: $0.name, type: $0.type, colorHex: $0.colorHex, icon: $0.icon,
                startingBalance: $0.startingBalance, goalAmount: $0.goalAmount,
                includeInNetWorth: $0.includeInNetWorth, isDefault: $0.isDefault,
                isArchived: $0.isArchived, sortOrder: $0.sortOrder, isSoftDeleted: $0.isSoftDeleted,
                remoteID: $0.remoteID, createdAt: $0.createdAt, updatedAt: $0.updatedAt
            )
        }
        snapshot.entries = entries.map {
            EntrySnapshot(
                amount: $0.amount, date: $0.date, note: $0.note, type: $0.type, recurrence: $0.recurrence,
                excludeFromBudget: $0.excludeFromBudget, isPlannedExpense: $0.isPlannedExpense,
                isSoftDeleted: $0.isSoftDeleted,
                categoryIndex: $0.category.map { categoryIndex[ObjectIdentifier($0)]! },
                walletIndex: walletIndex[ObjectIdentifier($0.wallet)]!,
                destinationWalletIndex: $0.destinationWallet.map { walletIndex[ObjectIdentifier($0)]! },
                remoteID: $0.remoteID, createdAt: $0.createdAt, updatedAt: $0.updatedAt
            )
        }
        snapshot.budgets = budgets.map {
            BudgetSnapshot(
                monthlyLimit: $0.monthlyLimit, month: $0.month, year: $0.year, isHidden: $0.isHidden,
                categoryIndex: categoryIndex[ObjectIdentifier($0.category)]!,
                remoteID: $0.remoteID, createdAt: $0.createdAt, updatedAt: $0.updatedAt
            )
        }
        snapshot.goals = goals.map {
            GoalSnapshot(
                name: $0.name, icon: $0.icon, colorHex: $0.colorHex, targetAmount: $0.targetAmount,
                createdAt: $0.createdAt, sortOrder: $0.sortOrder, isArchived: $0.isArchived,
                targetDate: $0.targetDate,
                contextWalletIndex: $0.contextWallet.map { walletIndex[ObjectIdentifier($0)]! }
            )
        }
        snapshot.goalContributions = goalContributions.map {
            GoalContributionSnapshot(
                amount: $0.amount, date: $0.date, note: $0.note,
                goalIndex: goalIndex[ObjectIdentifier($0.goal)]!,
                transactionIndex: $0.transaction.map { entryIndex[ObjectIdentifier($0)]! }
            )
        }
        snapshot.people = people.map {
            PersonSnapshot(
                displayName: $0.displayName, colorHex: $0.colorHex, isCurrentUser: $0.isCurrentUser,
                isFrequent: $0.isFrequent, createdAt: $0.createdAt, sharingAnchorID: $0.sharingAnchorID
            )
        }
        snapshot.sharedEvents = sharedEvents.map { event in
            SharedEventSnapshot(
                title: event.title, icon: event.icon, colorHex: event.colorHex, status: event.status,
                createdAt: event.createdAt, updatedAt: event.updatedAt, startDate: event.startDate,
                endDate: event.endDate, remoteID: event.remoteID,
                isCollaborationEnabled: event.isCollaborationEnabled, isRemoteOwned: event.isRemoteOwned,
                participantIndices: event.participants.map { personIndex[ObjectIdentifier($0)]! }
            )
        }
        snapshot.sharedExpenses = sharedExpenses.map {
            SharedExpenseSnapshot(
                amount: $0.amount, currency: $0.currency, note: $0.note, date: $0.date,
                splitMethod: $0.splitMethod, createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                remoteID: $0.remoteID,
                categoryIndex: $0.category.map { categoryIndex[ObjectIdentifier($0)]! },
                remoteCategoryName: $0.remoteCategoryName, remoteCategoryIcon: $0.remoteCategoryIcon,
                remoteCategoryColorHex: $0.remoteCategoryColorHex,
                paidByIndex: $0.paidBy.map { personIndex[ObjectIdentifier($0)]! },
                eventIndex: $0.event.map { eventIndex[ObjectIdentifier($0)]! }
            )
        }
        snapshot.sharedExpenseParticipants = sharedExpenseParticipants.map {
            SharedExpenseParticipantSnapshot(
                amount: $0.amount, parts: $0.parts, remoteID: $0.remoteID,
                personIndex: $0.person.map { personIndex[ObjectIdentifier($0)]! },
                expenseIndex: $0.expense.map { expenseIndex[ObjectIdentifier($0)]! }
            )
        }
        snapshot.settlements = settlements.map {
            SettlementSnapshot(
                fromPersonIndex: $0.fromPerson.map { personIndex[ObjectIdentifier($0)]! },
                toPersonIndex: $0.toPerson.map { personIndex[ObjectIdentifier($0)]! },
                amount: $0.amount, paymentMethod: $0.paymentMethod, date: $0.date, createdAt: $0.createdAt,
                remoteID: $0.remoteID,
                eventIndex: $0.event.map { eventIndex[ObjectIdentifier($0)]! },
                transactionIndex: $0.transaction.map { entryIndex[ObjectIdentifier($0)]! }
            )
        }
        snapshot.eventParticipants = eventParticipants.map {
            EventParticipantSnapshot(
                role: $0.role, userRecordID: $0.userRecordID, joinedAt: $0.joinedAt, isRemoved: $0.isRemoved,
                eventIndex: $0.event.map { eventIndex[ObjectIdentifier($0)]! },
                personIndex: $0.person.map { personIndex[ObjectIdentifier($0)]! }
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    /// Writes an export to a temp file for `ShareLink`, mirroring `CSVExporter.
    /// writeToTemporaryFile`'s existing pattern.
    static func writeToTemporaryFile(context: ModelContext) throws -> URL {
        let data = try export(context: context)
        let nameFormatter = DateFormatter()
        nameFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clarity-Backup-\(nameFormatter.string(from: .now))")
            .appendingPathExtension("json")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Restore

    /// Full replace, not a merge: every existing object of every model type is deleted first,
    /// then the whole graph is rebuilt from the snapshot. The snapshot's relationships are array
    /// indices scoped to the export that produced them, so a partial/merge restore would have no
    /// well-defined meaning — full replace is the only semantics that makes sense here.
    static func restore(from data: Data, context: ModelContext) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(DataSnapshot.self, from: data)

        try eraseAllData(in: context)

        let headCategories = snapshot.headCategories.map { s -> HeadCategory in
            let head = HeadCategory(
                name: s.name, icon: s.icon, colorHex: s.colorHex, sortOrder: s.sortOrder,
                createdAt: s.createdAt, updatedAt: s.updatedAt
            )
            head.remoteID = s.remoteID
            return head
        }
        headCategories.forEach(context.insert)

        let categories = snapshot.categories.map { s -> Category in
            let category = Category(
                name: s.name, customIcon: s.customIcon, iconIsEmoji: s.iconIsEmoji,
                customColorHex: s.customColorHex, isSavings: s.isSavings, isArchived: s.isArchived,
                isIncome: s.isIncome, headCategory: headCategories[s.headCategoryIndex],
                createdAt: s.createdAt, updatedAt: s.updatedAt
            )
            category.remoteID = s.remoteID
            return category
        }
        categories.forEach(context.insert)

        let wallets = snapshot.wallets.map { s -> Wallet in
            let wallet = Wallet(
                name: s.name, type: s.type, colorHex: s.colorHex, icon: s.icon,
                startingBalance: s.startingBalance, goalAmount: s.goalAmount,
                includeInNetWorth: s.includeInNetWorth, isDefault: s.isDefault,
                isArchived: s.isArchived, sortOrder: s.sortOrder, isSoftDeleted: s.isSoftDeleted,
                createdAt: s.createdAt, updatedAt: s.updatedAt
            )
            wallet.remoteID = s.remoteID
            return wallet
        }
        wallets.forEach(context.insert)

        let entries = snapshot.entries.map { s -> Entry in
            let entry = Entry(
                amount: s.amount, date: s.date, note: s.note, type: s.type,
                category: s.categoryIndex.map { categories[$0] },
                wallet: wallets[s.walletIndex],
                destinationWallet: s.destinationWalletIndex.map { wallets[$0] },
                recurrence: s.recurrence, excludeFromBudget: s.excludeFromBudget,
                isPlannedExpense: s.isPlannedExpense,
                createdAt: s.createdAt, updatedAt: s.updatedAt
            )
            entry.remoteID = s.remoteID
            entry.isSoftDeleted = s.isSoftDeleted
            return entry
        }
        entries.forEach(context.insert)

        snapshot.budgets.forEach {
            let budget = Budget(
                category: categories[$0.categoryIndex], monthlyLimit: $0.monthlyLimit,
                month: $0.month, year: $0.year, isHidden: $0.isHidden,
                createdAt: $0.createdAt, updatedAt: $0.updatedAt
            )
            budget.remoteID = $0.remoteID
            context.insert(budget)
        }

        let goals = snapshot.goals.map {
            Goal(
                name: $0.name, icon: $0.icon, colorHex: $0.colorHex, targetAmount: $0.targetAmount,
                createdAt: $0.createdAt, sortOrder: $0.sortOrder, isArchived: $0.isArchived,
                targetDate: $0.targetDate, contextWallet: $0.contextWalletIndex.map { wallets[$0] }
            )
        }
        goals.forEach(context.insert)

        snapshot.goalContributions.forEach {
            context.insert(GoalContribution(
                amount: $0.amount, date: $0.date, goal: goals[$0.goalIndex],
                transaction: $0.transactionIndex.map { entries[$0] }, note: $0.note
            ))
        }

        let people = snapshot.people.map { s -> Person in
            let person = Person(
                displayName: s.displayName, colorHex: s.colorHex, isCurrentUser: s.isCurrentUser,
                isFrequent: s.isFrequent, createdAt: s.createdAt
            )
            person.sharingAnchorID = s.sharingAnchorID
            return person
        }
        people.forEach(context.insert)

        let sharedEvents = snapshot.sharedEvents.map { s -> SharedEvent in
            let event = SharedEvent(
                title: s.title, icon: s.icon, colorHex: s.colorHex, status: s.status,
                participants: s.participantIndices.map { people[$0] },
                startDate: s.startDate, endDate: s.endDate, createdAt: s.createdAt, updatedAt: s.updatedAt
            )
            event.remoteID = s.remoteID
            event.isCollaborationEnabled = s.isCollaborationEnabled
            event.isRemoteOwned = s.isRemoteOwned
            return event
        }
        sharedEvents.forEach(context.insert)

        let sharedExpenses = snapshot.sharedExpenses.map { s -> SharedExpense in
            let expense = SharedExpense(
                amount: s.amount, currency: s.currency, note: s.note, date: s.date,
                category: s.categoryIndex.map { categories[$0] },
                paidBy: s.paidByIndex.map { people[$0] }, splitMethod: s.splitMethod,
                event: s.eventIndex.map { sharedEvents[$0] }, createdAt: s.createdAt, updatedAt: s.updatedAt
            )
            expense.remoteID = s.remoteID
            expense.remoteCategoryName = s.remoteCategoryName
            expense.remoteCategoryIcon = s.remoteCategoryIcon
            expense.remoteCategoryColorHex = s.remoteCategoryColorHex
            return expense
        }
        sharedExpenses.forEach(context.insert)

        snapshot.sharedExpenseParticipants.forEach {
            let participant = SharedExpenseParticipant(
                person: $0.personIndex.map { people[$0] }, amount: $0.amount, parts: $0.parts,
                expense: $0.expenseIndex.map { sharedExpenses[$0] }
            )
            participant.remoteID = $0.remoteID
            context.insert(participant)
        }

        snapshot.settlements.forEach {
            let settlement = Settlement(
                fromPerson: $0.fromPersonIndex.map { people[$0] },
                toPerson: $0.toPersonIndex.map { people[$0] },
                amount: $0.amount, paymentMethod: $0.paymentMethod, date: $0.date,
                event: $0.eventIndex.map { sharedEvents[$0] },
                transaction: $0.transactionIndex.map { entries[$0] }, createdAt: $0.createdAt
            )
            settlement.remoteID = $0.remoteID
            context.insert(settlement)
        }

        snapshot.eventParticipants.forEach {
            context.insert(EventParticipant(
                event: $0.eventIndex.map { sharedEvents[$0] },
                person: $0.personIndex.map { people[$0] },
                role: $0.role, userRecordID: $0.userRecordID, joinedAt: $0.joinedAt, isRemoved: $0.isRemoved
            ))
        }

        try context.save()
    }

    // MARK: - Helpers

    private static func indexMap<T: AnyObject>(_ objects: [T]) -> [ObjectIdentifier: Int] {
        Dictionary(uniqueKeysWithValues: objects.enumerated().map { (ObjectIdentifier($1), $0) })
    }

    /// Deletes every object of every model type — `restore`'s first step before rebuilding from a
    /// snapshot, and also exposed directly for `BackupRestoreView`'s "Erase All Data" action
    /// (wipe with nothing to restore afterward, e.g. to start over clean on a device).
    ///
    /// Deletion order matters only where a delete rule can block it — the single `.deny` rule in
    /// the schema is `Wallet.entries` (see `Wallet.swift`), so `Entry` must go before `Wallet`.
    /// Every other relationship in the schema is `.cascade`/`.nullify`, which never blocks a
    /// delete, so the rest of this order is just "children before the parents that named them,"
    /// not a hard requirement.
    static func eraseAllData(in context: ModelContext) throws {
        try deleteAll(EventParticipant.self, in: context)
        try deleteAll(Settlement.self, in: context)
        try deleteAll(SharedExpenseParticipant.self, in: context)
        try deleteAll(SharedExpense.self, in: context)
        try deleteAll(SharedEvent.self, in: context)
        try deleteAll(GoalContribution.self, in: context)
        try deleteAll(Goal.self, in: context)
        try deleteAll(Budget.self, in: context)
        try deleteAll(Entry.self, in: context)
        try deleteAll(Wallet.self, in: context)
        try deleteAll(Category.self, in: context)
        try deleteAll(HeadCategory.self, in: context)
        try deleteAll(Person.self, in: context)
        try context.save()
    }

    private static func deleteAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws {
        for object in try context.fetch(FetchDescriptor<T>()) {
            context.delete(object)
        }
    }
}
