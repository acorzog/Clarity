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

    /// Reuses the existing personal `Category` model rather than a separate shared taxonomy.
    @Relationship(deleteRule: .nullify)
    var category: Category?

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

    var person: Person?
    var expense: SharedExpense?

    init(person: Person?, amount: Decimal, parts: Int? = nil, expense: SharedExpense? = nil) {
        self.person = person
        self.amount = amount
        self.parts = parts
        self.expense = expense
    }
}
