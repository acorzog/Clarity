import Foundation
import SwiftData

enum SharedEventStatus: String, Codable, CaseIterable {
    case active
    case completed
}

/// A temporary shared-spending workspace — a trip, dinner, or any group activity with shared
/// costs. This is a separate domain from the personal ledger (`Entry`/`Wallet`/`Budget`):
/// nothing here touches personal balances until a `Settlement` is explicitly recorded as a
/// transaction. See `SharedEventQuerying` for balance math.
@Model
final class SharedEvent {
    var title: String
    var icon: String?
    var colorHex: String?
    var status: SharedEventStatus
    var createdAt: Date
    var updatedAt: Date
    var startDate: Date?
    var endDate: Date?

    var participants: [Person] = []

    @Relationship(deleteRule: .cascade, inverse: \SharedExpense.event)
    var expenses: [SharedExpense] = []

    @Relationship(deleteRule: .cascade, inverse: \Settlement.event)
    var settlements: [Settlement] = []

    init(
        title: String,
        icon: String? = nil,
        colorHex: String? = nil,
        status: SharedEventStatus = .active,
        participants: [Person] = [],
        startDate: Date? = nil,
        endDate: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.title = title
        self.icon = icon
        self.colorHex = colorHex
        self.status = status
        self.participants = participants
        self.startDate = startDate
        self.endDate = endDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
