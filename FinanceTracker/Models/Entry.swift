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
        excludeFromBudget: Bool = false
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
    }
}
