import Foundation
import SwiftData

/// A participant in shared expenses. Not necessarily a Clarity user — just a name the user
/// tracks spending against (themselves, a partner, a friend). No contacts integration in V1.
@Model
final class Person {
    var displayName: String
    var colorHex: String?
    /// True for the single Person record representing the app's own user — every SharedEvent
    /// implicitly includes them, and balances are always expressed relative to this person.
    var isCurrentUser: Bool
    /// Marks a person worth resurfacing first when picking participants for a new event.
    var isFrequent: Bool
    var createdAt: Date
    /// Stable local anchor used only to derive this person's CloudKit `Participant` record ID
    /// for a given SharedEvent (combined with that event's own `remoteID`) — see
    /// `CloudKitSharedEventMapper`. Not itself synced anywhere; a `Person` never becomes a
    /// CloudKit record directly, since the same local `Person` can be reused across multiple
    /// independently-shared events, each needing its own record.
    var sharingAnchorID: UUID = UUID()

    @Relationship(inverse: \SharedEvent.participants)
    var sharedEvents: [SharedEvent] = []

    @Relationship(deleteRule: .nullify, inverse: \SharedExpense.paidBy)
    var paidExpenses: [SharedExpense] = []

    @Relationship(deleteRule: .cascade, inverse: \SharedExpenseParticipant.person)
    var expenseShares: [SharedExpenseParticipant] = []

    @Relationship(deleteRule: .nullify, inverse: \Settlement.fromPerson)
    var settlementsPaid: [Settlement] = []

    @Relationship(deleteRule: .nullify, inverse: \Settlement.toPerson)
    var settlementsReceived: [Settlement] = []

    init(
        displayName: String,
        colorHex: String? = nil,
        isCurrentUser: Bool = false,
        isFrequent: Bool = false,
        createdAt: Date = .now
    ) {
        self.displayName = displayName
        self.colorHex = colorHex
        self.isCurrentUser = isCurrentUser
        self.isFrequent = isFrequent
        self.createdAt = createdAt
    }
}

extension Person {
    /// Fetches (or lazily creates) the single Person representing the app's own user —
    /// every SharedEvent implicitly includes them as a participant.
    ///
    /// Checks the context's own not-yet-saved inserts first: a plain `fetch` can miss an
    /// object this same context already inserted but hasn't autosaved yet, which would let two
    /// back-to-back calls (e.g. the Shared tab appearing right before a new event is created)
    /// each create their own "You". Inspecting `insertedModelsArray` closes that gap without
    /// forcing an extra save.
    static func currentUser(in context: ModelContext) -> Person {
        if let pending = context.insertedModelsArray.lazy
            .compactMap({ $0 as? Person })
            .first(where: { $0.isCurrentUser }) {
            return pending
        }

        let descriptor = FetchDescriptor<Person>(predicate: #Predicate { $0.isCurrentUser })
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }

        let you = Person(displayName: "You", isCurrentUser: true, isFrequent: true)
        context.insert(you)
        return you
    }
}
