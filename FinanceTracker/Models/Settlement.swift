import Foundation
import SwiftData

enum SettlementPaymentMethod: String, Codable, CaseIterable {
    case cash
    case bankTransfer
    case bizum
    case other

    var displayName: String {
        switch self {
        case .cash: return "Cash"
        case .bankTransfer: return "Bank Transfer"
        case .bizum: return "Bizum"
        case .other: return "Other"
        }
    }
}

/// The bridge between the shared domain and personal finance. Recording a Settlement never by
/// itself creates a personal transaction — `transaction` is only set when the user explicitly
/// confirms "Add to Transactions". Until then it's a shared-only record that just reduces the
/// outstanding balance between `fromPerson` and `toPerson` inside the event.
@Model
final class Settlement {
    /// Who handed over the money.
    var fromPerson: Person?
    /// Who received it.
    var toPerson: Person?
    var amount: Decimal
    var paymentMethod: SettlementPaymentMethod
    var date: Date
    var createdAt: Date
    /// This settlement's own CloudKit record identity — nil until first mapped. Deliberately
    /// separate from `transaction`/`Entry`, which never has a CloudKit counterpart at all — see
    /// `CloudKitSharedEventMapper`.
    var remoteID: UUID?

    var event: SharedEvent?

    /// Set only when the user explicitly chose "Add to Transactions" — the SharedEvent/Settlement
    /// remain the source of truth for the shared expense regardless.
    @Relationship(deleteRule: .nullify, inverse: \Entry.sharedSettlement)
    var transaction: Entry?

    init(
        fromPerson: Person?,
        toPerson: Person?,
        amount: Decimal,
        paymentMethod: SettlementPaymentMethod,
        date: Date = .now,
        event: SharedEvent? = nil,
        transaction: Entry? = nil,
        createdAt: Date = .now
    ) {
        self.fromPerson = fromPerson
        self.toPerson = toPerson
        self.amount = amount
        self.paymentMethod = paymentMethod
        self.date = date
        self.event = event
        self.transaction = transaction
        self.createdAt = createdAt
    }
}
