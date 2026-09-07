import Foundation
import SwiftData

/// One other participant's outstanding balance relative to the current user, after settlements.
/// Positive `amount` means they owe the current user; negative means the current user owes them.
struct SharedPersonBalance: Identifiable {
    let person: Person
    let amount: Decimal
    var id: PersistentIdentifier { person.persistentModelID }
}

extension SharedEvent {
    var currentUser: Person? {
        participants.first { $0.isCurrentUser }
    }

    var otherParticipants: [Person] {
        participants.filter { !$0.isCurrentUser }
    }

    var totalAmount: Decimal {
        expenses.reduce(Decimal(0)) { $0 + $1.amount }
    }

    /// What `person` actually handed over across every expense in this event.
    func amountPaid(by person: Person) -> Decimal {
        expenses.filter { $0.paidBy === person }.reduce(Decimal(0)) { $0 + $1.amount }
    }

    /// `person`'s total share of every expense in this event, regardless of who paid.
    func share(of person: Person) -> Decimal {
        expenses
            .flatMap(\.participants)
            .filter { $0.person === person }
            .reduce(Decimal(0)) { $0 + $1.amount }
    }

    /// `person`'s overall net position before settlements: positive means they fronted more
    /// than their share (the group owes them), negative means they owe into the group.
    func netBalance(of person: Person) -> Decimal {
        amountPaid(by: person) - share(of: person)
    }

    var yourShare: Decimal {
        currentUser.map(share(of:)) ?? 0
    }

    var youPaid: Decimal {
        currentUser.map(amountPaid(by:)) ?? 0
    }

    /// The current user's overall net balance before settlements: positive means the user is
    /// owed money overall, negative means the user owes money overall.
    var yourNetBalance: Decimal {
        youPaid - yourShare
    }

    /// Net settlement flow from `person` to the current user: positive reduces what `person`
    /// owes the user, negative reduces what the user owes `person`.
    private func settlementFlow(from person: Person) -> Decimal {
        guard let currentUser else { return 0 }
        let toYou = settlements.filter { $0.fromPerson === person && $0.toPerson === currentUser }
            .reduce(Decimal(0)) { $0 + $1.amount }
        let fromYou = settlements.filter { $0.fromPerson === currentUser && $0.toPerson === person }
            .reduce(Decimal(0)) { $0 + $1.amount }
        return toYou - fromYou
    }

    /// `person`'s outstanding balance relative to the current user, after settlements already
    /// recorded. Positive means `person` still owes the user; negative means the user still owes
    /// `person`. This is the number shown as "You are owed €X" / "You owe €X" per person.
    func outstandingBalance(for person: Person) -> Decimal {
        let rawRelativeBalance = -netBalance(of: person)
        return rawRelativeBalance - settlementFlow(from: person)
    }

    /// Outstanding balance for every other participant, most-owed-first.
    var balances: [SharedPersonBalance] {
        otherParticipants
            .map { SharedPersonBalance(person: $0, amount: outstandingBalance(for: $0)) }
            .sorted { $0.amount > $1.amount }
    }

    /// Sum of every other participant's outstanding balance — always equal to the current
    /// user's own outstanding net position, positive meaning the user is still owed overall.
    var outstandingNetBalance: Decimal {
        balances.reduce(Decimal(0)) { $0 + $1.amount }
    }

    /// True once every other participant's outstanding balance is exactly zero.
    var isFullySettled: Bool {
        balances.allSatisfy { $0.amount == 0 }
    }
}
