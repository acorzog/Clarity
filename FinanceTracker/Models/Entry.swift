import Foundation
import SwiftData

enum EntryType: String, Codable, CaseIterable {
    case expense
    case income
    case transfer
}

enum RecurrenceRule: String, Codable, CaseIterable {
    case none
    case weekly
    case monthly
    case yearly
}

@Model
final class Entry {
    var amount: Decimal
    var date: Date
    var note: String
    var type: EntryType
    var recurrence: RecurrenceRule
    var excludeFromBudget: Bool
    /// A known, already-budgeted-for expense (rent, a quarterly tax bill) that shouldn't read as
    /// impulsive overspending just because it lands all at once. Unlike `excludeFromBudget`, this
    /// still counts normally everywhere else (`BudgetCalculator`, Remaining, Safe to Spend) — it
    /// only tells `ClarityScoreCalculator` to leave it out of the week-over-week pacing factors.
    /// Defaults `false` so existing entries (and anything that predates this field) behave exactly
    /// as before. The `= false` here (not just on the `init` parameter below) is required for
    /// SwiftData's lightweight migration to backfill this attribute on rows that already exist in
    /// an installed app's store — without it, migration fails outright on launch.
    var isPlannedExpense: Bool = false

    /// Soft-delete marker — Phase 3B-1. Normal "deleting" an entry sets this `true` (and bumps
    /// `updatedAt`) instead of calling `modelContext.delete(entry)`, so a future Supabase sync can
    /// learn a row was removed by seeing this flag change, rather than inferring deletion from a
    /// row's mere absence (which a one-way snapshot sync can't distinguish from "never fetched").
    /// The `= false` here (not just an init default) is required for SwiftData's lightweight
    /// migration to backfill this attribute on rows that already exist in an installed app's
    /// store — same requirement as `isPlannedExpense` above. Also needs an `init` parameter (even
    /// though no real call site ever constructs a pre-deleted `Entry`) for the same reason
    /// `isPlannedExpense` has one and `remoteID`/`createdAt`/`updatedAt` don't: a non-Optional
    /// stored property's inline default alone was empirically found to not reliably survive a
    /// post-construction mutation + `modelContext.save()` round trip unless the initializer also
    /// assigns it — verified directly against this SwiftData version by a failing test before this
    /// parameter was added.
    var isSoftDeleted: Bool = false

    /// This entry's stable cross-device identity for a future Supabase sync — nil until first
    /// mapped, mirroring `Settlement`/`SharedEvent`/`SharedExpense`'s existing CloudKit `remoteID`
    /// convention (see `CloudKitRecordIdentity.swift`'s doc comment). Deliberately never minted at
    /// ordinary local construction: SwiftData's own `persistentModelID` is store-local and not
    /// guaranteed stable across devices or migrations, so it can't stand in for this.
    var remoteID: UUID?
    /// Local creation timestamp, set once at construction.
    var createdAt: Date = Date.now
    /// Bumped by hand (`entry.updatedAt = .now`) at every intentional mutation site — see
    /// `AddTransactionView.save()`'s edit branch — following the same explicit-bump convention
    /// `SharedEvent`/`SharedExpense` already use. Deliberately not a `didSet` observer: one here
    /// would also fire on SwiftData's own internal property access/relationship faulting, not just
    /// genuine user edits, risking recursive mutation during a save.
    var updatedAt: Date = Date.now

    var category: Category?
    var wallet: Wallet
    var destinationWallet: Wallet?

    /// Set when this transaction originated from a shared-expense settlement (see `Settlement`).
    /// Personal transactions created any other way leave this nil.
    var sharedSettlement: Settlement?

    /// Set when this transaction has been explicitly marked as counting toward a `Goal` (see
    /// `GoalContribution`). Personal transactions created any other way, or not yet linked to a
    /// goal, leave this nil. Mirrors `sharedSettlement`'s exact shape and rationale — Phase 2L,
    /// `CLARITY_GOALS_ARCHITECTURE.md` §5/§18.
    var goalContribution: GoalContribution?

    init(
        amount: Decimal,
        date: Date = .now,
        note: String = "",
        type: EntryType,
        category: Category? = nil,
        wallet: Wallet,
        destinationWallet: Wallet? = nil,
        recurrence: RecurrenceRule = .none,
        excludeFromBudget: Bool = false,
        isPlannedExpense: Bool = false,
        isSoftDeleted: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.amount = amount
        self.date = date
        self.note = note
        self.type = type
        self.category = category
        self.wallet = wallet
        self.destinationWallet = destinationWallet
        self.recurrence = recurrence
        self.excludeFromBudget = excludeFromBudget
        self.isPlannedExpense = isPlannedExpense
        self.isSoftDeleted = isSoftDeleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Builds and inserts a brand-new `Entry` — the exact same construction `AddTransactionView.
/// save()` uses for a *new* (non-editing) entry, factored out so any other entry point that
/// creates a transaction (currently: Home's voice-expense batch review) does it identically
/// instead of re-implementing `Entry(...)` + `modelContext.insert(...)` itself. Deliberately does
/// *not* call `modelContext.save()` — callers that create several entries at once (the voice
/// batch case) save once after the whole loop, exactly as `AddTransactionView.save()` already
/// does for its own single entry.
///
/// Only ever creates a *new* entry — editing an existing one stays entirely inside
/// `AddTransactionView`, which also owns recurrence/transfer-destination editing this doesn't
/// need. Category is intentionally left optional here (never required) to match the app's own
/// established "don't block a save on a missing category" precedent — see `LogExpenseIntent`'s
/// doc comment for why that's a deliberate choice, not an oversight.
enum TransactionSaving {
    @discardableResult
    static func createEntry(
        amount: Decimal,
        date: Date = .now,
        note: String = "",
        type: EntryType,
        category: Category?,
        wallet: Wallet,
        destinationWallet: Wallet? = nil,
        recurrence: RecurrenceRule = .none,
        excludeFromBudget: Bool = false,
        isPlannedExpense: Bool = false,
        prefetchedBudgets: [Budget]? = nil,
        modelContext: ModelContext
    ) -> Entry {
        // Auto-marks on top of whatever the caller already decided (a manual toggle in
        // AddTransactionView, or simply `false`) — see `matchesFixedPlannedAmount`'s doc comment.
        // Fetched here by default (rather than threaded through every caller's signature) so this
        // benefits every entry point that already goes through this single choke point without
        // their own changes. A caller that creates several entries in one loop (voice quick-save)
        // can pass `prefetchedBudgets` instead, so the whole batch shares one fetch rather than
        // re-fetching the entire, unboundedly-growing Budget table once per entry.
        let budgets = prefetchedBudgets ?? ((try? modelContext.fetch(FetchDescriptor<Budget>())) ?? [])
        let autoPlanned = type == .expense && budgets.matchesFixedPlannedAmount(amount, for: category, month: date)

        let entry = Entry(
            amount: amount,
            date: date,
            note: note,
            type: type,
            category: type == .transfer ? nil : category,
            wallet: wallet,
            destinationWallet: destinationWallet,
            recurrence: recurrence,
            excludeFromBudget: excludeFromBudget,
            isPlannedExpense: isPlannedExpense || autoPlanned
        )
        modelContext.insert(entry)
        return entry
    }
}
