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
        isPlannedExpense: Bool = false
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
        modelContext: ModelContext
    ) -> Entry {
        // Auto-marks on top of whatever the caller already decided (a manual toggle in
        // AddTransactionView, or simply `false`) — see `matchesFixedPlannedAmount`'s doc comment.
        // Fetched here rather than threaded through every caller's signature so this benefits
        // every entry point that already goes through this single choke point (manual save,
        // voice quick-save) without their own changes.
        let budgets = (try? modelContext.fetch(FetchDescriptor<Budget>())) ?? []
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
