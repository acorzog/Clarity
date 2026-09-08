import Foundation
import SwiftData

enum SharedSplitMethod: String, Codable, CaseIterable {
    case equal
    case byParts
    case exactAmounts
}

/// One cost inside a `SharedEvent` — e.g. "Hotel, €400, paid by You". This lives entirely in
/// the shared domain: creating one never creates a personal `Entry`, never touches a `Wallet`
/// balance, and never affects budgets. See CRITICAL rule in the shared-expenses spec.
@Model
final class SharedExpense {
    var amount: Decimal
    var currency: String
    var note: String
    var date: Date
    var splitMethod: SharedSplitMethod
    var createdAt: Date
    var updatedAt: Date
    /// This expense's own CloudKit record identity — nil until first mapped. See
    /// `CloudKitSharedEventMapper`.
    var remoteID: UUID?

    /// Reuses the existing personal `Category` model rather than a separate shared taxonomy.
    /// `nil` for an expense this device received from another participant — see the snapshot
    /// fields below.
    @Relationship(deleteRule: .nullify)
    var category: Category?

    /// Read-only display snapshot of another participant's category, received via CloudKit —
    /// populated only when this expense arrived from elsewhere (`category` is nil in that case)
    /// and never resolved back to this device's own personal `Category` table (see CRITICAL
    /// rule: a remote category snapshot must never alter or create a personal category). When
    /// this device is the one that created the expense, these stay nil and `category` is used
    /// directly; `CloudKitSharedEventMapper` falls back to these when `category` is nil so the
    /// snapshot survives even if this device later edits an expense it didn't originate.
    var remoteCategoryName: String?
    var remoteCategoryIcon: String?
    var remoteCategoryColorHex: String?

    var paidBy: Person?

    var event: SharedEvent?

    @Relationship(deleteRule: .cascade, inverse: \SharedExpenseParticipant.expense)
    var participants: [SharedExpenseParticipant] = []

    init(
        amount: Decimal,
        currency: String,
        note: String = "",
        date: Date = .now,
        category: Category? = nil,
        paidBy: Person? = nil,
        splitMethod: SharedSplitMethod = .equal,
        event: SharedEvent? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.amount = amount
        self.currency = currency
        self.note = note
        self.date = date
        self.category = category
        self.paidBy = paidBy
        self.splitMethod = splitMethod
        self.event = event
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One participant's share of a `SharedExpense` — the amount they owe toward it, and (for
/// `.byParts`) the raw part count the amount was derived from so the UI can still show "2 parts".
@Model
final class SharedExpenseParticipant {
    var amount: Decimal
    var parts: Int?
    /// This share's own CloudKit record identity — nil until first mapped. See
    /// `CloudKitSharedEventMapper`.
    var remoteID: UUID?

    var person: Person?
    var expense: SharedExpense?

    init(person: Person?, amount: Decimal, parts: Int? = nil, expense: SharedExpense? = nil) {
        self.person = person
        self.amount = amount
        self.parts = parts
        self.expense = expense
    }
}
