import Foundation

/// Deterministic identity parsing between CloudKit record names and local SwiftData rows, used
/// only by the sync reconciliation path (Cloud → Local).
///
/// This is Phase 2's answer to "is `remoteID` sufficient for deterministic CloudKit identity":
/// for `SharedEvent`/`SharedExpense`/`SharedExpenseParticipant`/`Settlement`, yes — each mints
/// its own `remoteID: UUID` and uses `remoteID.uuidString` directly as its CKRecord.ID.recordName
/// (see `CloudKitSharedEventMapper`), so reconciling one back to a local row is a direct UUID
/// lookup with no extra metadata required.
///
/// `Participant` is the one exception: a `Person` never owns a CKRecord directly, since the same
/// local `Person` is reused across independently-shared events (see `Person.sharingAnchorID`),
/// so its record name is a composite of the owning event's ID and the person's own anchor ID.
/// This type is the single place that composite format is assembled and parsed, so the two
/// directions can never drift apart — deliberately a pure parsing utility, not a persisted
/// domain model, since nothing here needs to be stored: it's re-derivable from data already on
/// disk every time.
enum CloudKitRecordIdentity {
    private static let participantMarker = "-participant-"

    /// Parses a `remoteID.uuidString`-shaped record name back into the UUID that names it —
    /// used for SharedEvent/Expense/ExpenseParticipant/Settlement records.
    static func remoteID(fromRecordName recordName: String) -> UUID? {
        UUID(uuidString: recordName)
    }

    /// The two components a `Participant` record name is built from: the event's `remoteID` and
    /// the person's `sharingAnchorID`. Returns nil if `recordName` isn't in that shape.
    static func participantComponents(fromRecordName recordName: String) -> (eventID: UUID, personAnchorID: UUID)? {
        guard let range = recordName.range(of: participantMarker) else { return nil }
        let eventIDString = String(recordName[recordName.startIndex..<range.lowerBound])
        let anchorIDString = String(recordName[range.upperBound...])
        guard let eventID = UUID(uuidString: eventIDString), let anchorID = UUID(uuidString: anchorIDString) else {
            return nil
        }
        return (eventID, anchorID)
    }
}
