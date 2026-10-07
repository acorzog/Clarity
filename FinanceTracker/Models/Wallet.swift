import Foundation
import SwiftData

enum WalletType: String, Codable, CaseIterable {
    case spending
    case credit
    case cash
    case savings
    case debt
    case custom
}

@Model
final class Wallet {
    var name: String
    var type: WalletType
    var colorHex: String
    var icon: String
    var startingBalance: Decimal
    var goalAmount: Decimal?
    var includeInNetWorth: Bool = true
    var isDefault: Bool = false
    var isArchived: Bool = false
    var sortOrder: Int = 0

    /// Soft-delete marker — Phase 3D-1, mirroring `Entry.isSoftDeleted` exactly (including the
    /// reason it isn't just named `isDeleted`: that name collides with `NSManagedObject`'s own
    /// reserved `isDeleted` flag under SwiftData/Core Data and silently fails to persist — see
    /// `Entry.isSoftDeleted`'s doc comment, Phase 3B-1). "Remove Account" in `WalletEditorView`
    /// sets this instead of calling `modelContext.delete(wallet)`, so a future Supabase sync can
    /// learn the wallet was removed (`is_deleted = true`) rather than the row just vanishing from
    /// future upload batches with no explanation. Unlike `Entry`, a soft-deleted `Wallet`'s own
    /// historical `Entry` rows are deliberately left untouched and still fully intact — only the
    /// wallet itself disappears from normal lists/pickers (see `Wallet.active(in:)` and every
    /// `@Query` site filtered for this). The `= false` here (not just an init default) is required
    /// for SwiftData's lightweight migration to backfill this attribute on rows that already exist
    /// in an installed app's store — same requirement as `Entry.isSoftDeleted`.
    var isSoftDeleted: Bool = false

    /// This wallet's stable cross-device identity for a future Supabase sync — see `Entry.
    /// remoteID`'s doc comment for the full rationale; the same convention applies here.
    var remoteID: UUID?
    var createdAt: Date = Date.now
    /// Bumped by hand at every intentional mutation site (see `WalletEditorView.save()`) —
    /// deliberately not a `didSet` observer, for the same recursive-mutation reason documented on
    /// `Entry.updatedAt`.
    var updatedAt: Date = Date.now

    @Relationship(deleteRule: .deny, inverse: \Entry.wallet)
    var entries: [Entry] = []

    @Relationship(deleteRule: .nullify, inverse: \Entry.destinationWallet)
    var incomingTransfers: [Entry] = []

    /// Formal inverse of `Goal.contextWallet` — required only so SwiftData correctly nullifies a
    /// `Goal`'s display-only wallet reference when *this* wallet is deleted (mirrors
    /// `incomingTransfers`'s own "nullify, never block" rationale). Not otherwise read anywhere;
    /// added by Phase 2L (`CLARITY_GOALS_ARCHITECTURE.md`) — every other `Wallet` field/behavior,
    /// including `goalAmount`, is unchanged.
    @Relationship(deleteRule: .nullify, inverse: \Goal.contextWallet)
    var goalReferences: [Goal] = []

    init(
        name: String,
        type: WalletType,
        colorHex: String,
        icon: String,
        startingBalance: Decimal = 0,
        goalAmount: Decimal? = nil,
        includeInNetWorth: Bool = true,
        isDefault: Bool = false,
        isArchived: Bool = false,
        sortOrder: Int = 0,
        isSoftDeleted: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The effect this wallet's involvement in `entry` has on its own balance —
    /// positive for money in, negative for money out. Used both by `balance` and
    /// by transaction-list views that show a running balance per row.
    func effect(of entry: Entry) -> Decimal {
        if entry.wallet === self {
            switch entry.type {
            case .income: return entry.amount
            case .expense, .transfer: return -entry.amount
            }
        }
        if entry.destinationWallet === self {
            return entry.amount
        }
        return 0
    }

    /// Every entry that touches this wallet's balance — as the primary wallet (expense/income/
    /// outgoing transfer) or as a transfer's destination — newest first. Excludes soft-deleted
    /// entries (Phase 3B-1, `Entry.isSoftDeleted`) — `entries`/`incomingTransfers` are raw SwiftData
    /// relationship arrays with no predicate of their own, unlike a `@Query`, so this is the one
    /// place that filter must be applied by hand for every view built on this property
    /// (`WalletEditorView`, `WalletTransactionsView`).
    var allEntries: [Entry] {
        (entries + incomingTransfers).filter { !$0.isSoftDeleted }.sorted { $0.date > $1.date }
    }

    /// Derived from starting balance plus every entry dated today or earlier touching this
    /// wallet, so it can never drift out of sync — and so it represents the real, current bank
    /// balance this figure stands in for. An entry dated in the future (a known upcoming charge
    /// entered ahead of time, e.g. today for a bill due in 2 days) deliberately does NOT reduce
    /// this balance until its own date actually arrives — the balance shouldn't drop before the
    /// money has actually left the account.
    ///
    /// This is specific to `Wallet.balance` (and anything built on it: `NetWorthCalculator`,
    /// `WalletTransactionsView`'s running balance) — `BudgetCalculator.periodSpendingSummary`
    /// ("Available to Spend"/"Safe to Spend") and every other spending total in the app
    /// deliberately keep counting a future-dated entry immediately, as a safety net against
    /// spending that already-committed money on something else before it's due. Those two
    /// concepts (real current balance vs. planned available-to-spend) are allowed to disagree by
    /// design; this function only ever changes the former.
    var balance: Decimal {
        balance(asOf: .now)
    }

    /// `Wallet.balance`, but as of an arbitrary point in time — exposed for testing (`asOf` a
    /// fixed date rather than the real `.now`) and so any future caller needing "balance
    /// including everything scheduled" vs. "balance as of a specific day" has a single shared
    /// implementation rather than a second copy of this logic.
    func balance(asOf date: Date, calendar: Calendar = .current) -> Decimal {
        let cutoff = calendar.startOfDay(for: date)
        // `!$0.isSoftDeleted` (Phase 3B-1) — a soft-deleted entry must stop affecting the balance,
        // exactly as if it had been hard-deleted; see `allEntries`'s doc comment for why this
        // can't be expressed once at the relationship declaration itself.
        let eligibleEntries = entries.filter { !$0.isSoftDeleted && calendar.startOfDay(for: $0.date) <= cutoff }
        let eligibleTransfers = incomingTransfers.filter { !$0.isSoftDeleted && calendar.startOfDay(for: $0.date) <= cutoff }
        return eligibleEntries.reduce(startingBalance) { $0 + effect(of: $1) } + eligibleTransfers.reduce(0) { $0 + effect(of: $1) }
    }

    /// False once the wallet has transactions on it (as source) or is the destination of a
    /// transfer from another wallet. Originally gated whether `WalletEditorView`'s "Remove
    /// Account" could proceed at all (a true hard delete would hit SwiftData's `.deny` rule on
    /// `entries` otherwise) — since Phase 3D-1 switched that action to a soft delete, which never
    /// invokes `modelContext.delete` and so never reaches that constraint, this property is no
    /// longer used to gate removal. Still used by `resolveBalanceEdit` (via `!canBeDeleted` as
    /// `hasRealHistory`) to decide whether editing the balance field should log an auditable
    /// adjustment `Entry` or set `startingBalance` directly — an unrelated concern that happens to
    /// share the same "does this wallet have real activity" predicate.
    var canBeDeleted: Bool {
        entries.isEmpty && incomingTransfers.isEmpty
    }
}

extension Wallet {
    /// Non-archived, non-soft-deleted wallets — archived and removed wallets are excluded from
    /// every picker and fallback. Centralizing the `isSoftDeleted` check here (Phase 3D-1) means
    /// every caller that already routes through this helper — including the three Shortcuts/Siri
    /// intents, which fetch wallets directly via `FetchDescriptor` rather than a filtered `@Query`
    /// — is protected with no changes of their own.
    static func active(in wallets: [Wallet]) -> [Wallet] {
        wallets.filter { !$0.isArchived && !$0.isSoftDeleted }
    }

    /// The wallet to fall back to when none was explicitly requested: the default wallet if
    /// one exists among the active wallets, otherwise the first active wallet.
    static func preferredFallback(among wallets: [Wallet]) -> Wallet? {
        let candidates = active(in: wallets)
        return candidates.first { $0.isDefault } ?? candidates.first
    }
}
