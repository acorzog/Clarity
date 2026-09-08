import Foundation
import CloudKit

/// Maps a local `SharedEvent` — and everything inside it — into the CloudKit record hierarchy
/// designed for collaboration: one custom zone per event, a `SharedEvent` root record, and
/// `Participant`/`Expense`/`ExpenseParticipant`/`Settlement` children referencing it.
///
/// This is representation only. It builds `CKRecord` graphs in memory and lazily mints the
/// stable identifiers (`remoteID`, `Person.sharingAnchorID`) each local row needs to keep
/// producing the same `CKRecord.ID` across repeated calls. It never talks to CloudKit's
/// network — no `CKContainer`, no `CKDatabase`, no zone creation, no `CKShare`. That's a
/// deliberately separate, later step once an actual sharing flow is built.
///
/// Reads only the Shared* models plus the display fields of `Category` needed for
/// denormalization (a shared `Expense` record can't hold a live reference to the personal
/// `Category` table, since other participants have no permission to resolve it). Never reads
/// or writes `Entry`, `Wallet`, or `Budget` — and `Settlement.transaction` (the one link into
/// personal finance) is deliberately never written to any CKRecord field at all: whether *this*
/// device turned a settlement into a personal transaction is private, per-device information.
enum CloudKitSharedEventMapper {

    enum RecordType {
        static let sharedEvent = "SharedEvent"
        static let participant = "Participant"
        static let expense = "Expense"
        static let expenseParticipant = "ExpenseParticipant"
        static let settlement = "Settlement"
    }

    /// Every CKRecord representing one SharedEvent's current local state.
    struct MappedGraph {
        let zoneID: CKRecordZone.ID
        let event: CKRecord
        let participants: [CKRecord]
        let expenses: [CKRecord]
        let expenseParticipants: [CKRecord]
        let settlements: [CKRecord]

        /// Every record in the graph, parents before children — not required by CloudKit
        /// (references resolve regardless of save order) but keeps a future save deterministic.
        var allRecords: [CKRecord] {
            [event] + participants + expenses + expenseParticipants + settlements
        }
    }

    /// Builds (and, where missing, mints) every CKRecord for `event`. Pure and offline: never
    /// requires the CloudKit capability to be enabled. Mutates `event` and its children only to
    /// persist newly-minted `remoteID`s through the caller's existing ModelContext, so repeated
    /// calls for the same local rows keep producing the same CKRecord.ID.
    static func map(_ event: SharedEvent) -> MappedGraph {
        let eventID = stableID(for: event)
        let zoneID = zoneID(forEventID: eventID)
        let eventRecordID = CKRecord.ID(recordName: eventID.uuidString, zoneID: zoneID)

        let eventRecord = CKRecord(recordType: RecordType.sharedEvent, recordID: eventRecordID)
        populate(eventRecord, from: event)

        var participantRecords: [Person: CKRecord] = [:]
        for person in event.participants {
            let membership = event.eventParticipants.first { $0.person === person }
            participantRecords[person] = participantRecord(
                for: person,
                eventID: eventID,
                isOwner: person === event.currentUser,
                zoneID: zoneID,
                eventRecordID: eventRecordID,
                membership: membership
            )
        }

        var expenseParticipantRecords: [CKRecord] = []
        let expenseRecords: [CKRecord] = event.expenses.map { expense in
            let record = expenseRecord(
                for: expense,
                zoneID: zoneID,
                eventRecordID: eventRecordID,
                participantRecords: participantRecords
            )
            for share in expense.participants {
                if let shareRecord = expenseParticipantRecord(
                    for: share,
                    zoneID: zoneID,
                    expenseRecordID: record.recordID,
                    participantRecords: participantRecords
                ) {
                    expenseParticipantRecords.append(shareRecord)
                }
            }
            return record
        }

        let settlementRecords: [CKRecord] = event.settlements.compactMap { settlement in
            settlementRecord(
                for: settlement,
                zoneID: zoneID,
                eventRecordID: eventRecordID,
                participantRecords: participantRecords
            )
        }

        return MappedGraph(
            zoneID: zoneID,
            event: eventRecord,
            participants: Array(participantRecords.values),
            expenses: expenseRecords,
            expenseParticipants: expenseParticipantRecords,
            settlements: settlementRecords
        )
    }

    // MARK: - Stable identity

    private static func stableID(for event: SharedEvent) -> UUID {
        if let remoteID = event.remoteID { return remoteID }
        let newID = UUID()
        event.remoteID = newID
        return newID
    }

    private static func stableID(for expense: SharedExpense) -> UUID {
        if let remoteID = expense.remoteID { return remoteID }
        let newID = UUID()
        expense.remoteID = newID
        return newID
    }

    private static func stableID(for share: SharedExpenseParticipant) -> UUID {
        if let remoteID = share.remoteID { return remoteID }
        let newID = UUID()
        share.remoteID = newID
        return newID
    }

    private static func stableID(for settlement: Settlement) -> UUID {
        if let remoteID = settlement.remoteID { return remoteID }
        let newID = UUID()
        settlement.remoteID = newID
        return newID
    }

    private static func zoneID(forEventID eventID: UUID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "SharedEvent-\(eventID.uuidString)", ownerName: CKCurrentUserDefaultName)
    }

    /// A participant's CKRecord name is derived from the event's ID plus their own stable local
    /// anchor rather than stored — the same `Person` reused across two different events must
    /// resolve to two different `Participant` records, one per event's zone.
    private static func participantRecordName(eventID: UUID, person: Person) -> String {
        "\(eventID.uuidString)-participant-\(person.sharingAnchorID.uuidString)"
    }

    // MARK: - Record builders

    private static func populate(_ record: CKRecord, from event: SharedEvent) {
        record["title"] = event.title
        record["icon"] = event.icon
        record["colorHex"] = event.colorHex
        record["status"] = event.status.rawValue
        record["startDate"] = event.startDate
        record["endDate"] = event.endDate
        record["createdAt"] = event.createdAt
        record["updatedAt"] = event.updatedAt
    }

    /// Builds the Participant record for `person`, sourcing identity fields (role/userRecordID/
    /// joinedAt/isRemoved) from `membership` — the local `EventParticipant` row that carries this
    /// event-scoped state (see that model). `membership` is optional purely for robustness: this
    /// function stays a pure, context-free read even if the caller hasn't ensured a backing row
    /// exists yet, falling back to the same "owner vs member" inference used before Phase 4.
    private static func participantRecord(
        for person: Person,
        eventID: UUID,
        isOwner: Bool,
        zoneID: CKRecordZone.ID,
        eventRecordID: CKRecord.ID,
        membership: EventParticipant?
    ) -> CKRecord {
        let recordName = participantRecordName(eventID: eventID, person: person)
        let record = CKRecord(recordType: RecordType.participant, recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
        record["event"] = CKRecord.Reference(recordID: eventRecordID, action: .deleteSelf)
        record["displayName"] = person.displayName
        record["colorHex"] = person.colorHex
        record["role"] = (membership?.role ?? (isOwner ? .owner : .member)).rawValue
        // nil clears the field on save — CloudKit's own way of representing "no value," matching
        // an unclaimed guest having no userRecordID key at all.
        record["userRecordID"] = membership?.userRecordID
        record["joinedAt"] = membership?.joinedAt ?? Date.now
        record["isRemoved"] = ((membership?.isRemoved ?? false) ? 1 : 0) as NSNumber
        return record
    }

    /// Builds just the one Participant record for `person` within `event` — used when only that
    /// participant's identity needs to be pushed (claiming), so the upload never re-sends every
    /// other participant's record and risks overwriting state this device hasn't reconciled yet.
    /// Returns `nil` if `person` isn't actually a participant of `event`.
    static func participantRecord(for person: Person, in event: SharedEvent) -> CKRecord? {
        guard event.participants.contains(where: { $0 === person }) else { return nil }
        let eventID = stableID(for: event)
        let zoneID = zoneID(forEventID: eventID)
        let eventRecordID = CKRecord.ID(recordName: eventID.uuidString, zoneID: zoneID)
        let membership = event.eventParticipants.first { $0.person === person }
        return participantRecord(
            for: person,
            eventID: eventID,
            isOwner: person === event.currentUser,
            zoneID: zoneID,
            eventRecordID: eventRecordID,
            membership: membership
        )
    }

    private static func expenseRecord(
        for expense: SharedExpense,
        zoneID: CKRecordZone.ID,
        eventRecordID: CKRecord.ID,
        participantRecords: [Person: CKRecord]
    ) -> CKRecord {
        let id = stableID(for: expense)
        let record = CKRecord(recordType: RecordType.expense, recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID))
        record["event"] = CKRecord.Reference(recordID: eventRecordID, action: .deleteSelf)
        record["amountCents"] = cents(from: expense.amount) as NSNumber
        record["currency"] = expense.currency
        record["note"] = expense.note
        record["date"] = expense.date
        record["splitMethod"] = expense.splitMethod.rawValue
        // Prefer this device's own local Category if it set one; otherwise fall back to whatever
        // snapshot this expense already carries (e.g. this device is re-uploading an edit to an
        // expense it received from someone else, and never had a matching local Category for it
        // in the first place) — so an edit never silently blanks out the original snapshot.
        record["categoryName"] = expense.category?.name ?? expense.remoteCategoryName
        record["categoryIcon"] = (expense.category?.customIcon ?? expense.category?.headCategory.icon) ?? expense.remoteCategoryIcon
        record["categoryColorHex"] = expense.category?.resolvedColorHex ?? expense.remoteCategoryColorHex
        if let paidBy = expense.paidBy, let payerRecord = participantRecords[paidBy] {
            record["paidBy"] = CKRecord.Reference(recordID: payerRecord.recordID, action: .none)
        }
        record["createdAt"] = expense.createdAt
        record["updatedAt"] = expense.updatedAt
        return record
    }

    private static func expenseParticipantRecord(
        for share: SharedExpenseParticipant,
        zoneID: CKRecordZone.ID,
        expenseRecordID: CKRecord.ID,
        participantRecords: [Person: CKRecord]
    ) -> CKRecord? {
        guard let person = share.person, let participantRecord = participantRecords[person] else { return nil }
        let id = stableID(for: share)
        let record = CKRecord(recordType: RecordType.expenseParticipant, recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID))
        record["expense"] = CKRecord.Reference(recordID: expenseRecordID, action: .deleteSelf)
        record["participant"] = CKRecord.Reference(recordID: participantRecord.recordID, action: .none)
        record["amountCents"] = cents(from: share.amount) as NSNumber
        if let parts = share.parts {
            record["parts"] = parts as NSNumber
        }
        return record
    }

    private static func settlementRecord(
        for settlement: Settlement,
        zoneID: CKRecordZone.ID,
        eventRecordID: CKRecord.ID,
        participantRecords: [Person: CKRecord]
    ) -> CKRecord? {
        guard
            let fromPerson = settlement.fromPerson, let fromRecord = participantRecords[fromPerson],
            let toPerson = settlement.toPerson, let toRecord = participantRecords[toPerson]
        else { return nil }

        let id = stableID(for: settlement)
        let record = CKRecord(recordType: RecordType.settlement, recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID))
        record["event"] = CKRecord.Reference(recordID: eventRecordID, action: .deleteSelf)
        record["fromParticipant"] = CKRecord.Reference(recordID: fromRecord.recordID, action: .none)
        record["toParticipant"] = CKRecord.Reference(recordID: toRecord.recordID, action: .none)
        record["amountCents"] = cents(from: settlement.amount) as NSNumber
        record["paymentMethod"] = settlement.paymentMethod.rawValue
        record["date"] = settlement.date
        record["createdAt"] = settlement.createdAt
        // settlement.transaction (the optional link to a personal Entry) is deliberately never
        // written here — see this type's header comment.
        return record
    }

    /// CKRecord has no Decimal field type (only Int64/Double/String/Date/Data/Reference/Asset/
    /// Location) — storing money as Double would reintroduce the floating-point risk the local
    /// split calculator exists to avoid, so amounts are stored as rounded minor-unit cents.
    private static func cents(from amount: Decimal) -> Int64 {
        let handler = NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )
        return NSDecimalNumber(decimal: amount * 100)
            .rounding(accordingToBehavior: handler)
            .int64Value
    }
}
