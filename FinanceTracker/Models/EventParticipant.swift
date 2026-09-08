import Foundation
import SwiftData

enum ParticipantRole: String, Codable, CaseIterable {
    case owner
    case member
}

/// A minimal, session-scoped cache of this device's own CloudKit user record ID — the "smallest
/// appropriate in-memory/session-level identity provider" the collaboration architecture has
/// called for since Phase 5.1, now also backing `SharedEventQuerying`'s balance calculations.
///
/// Deliberately not actor-isolated and dependency-free (no CloudKit/SwiftData imports):
/// `SharedEventQuerying`'s `currentUser`/`otherParticipants`/balance math are pure, synchronous
/// properties called from many contexts (SwiftUI view bodies across the whole Shared tab, tests,
/// and files the widget target also compiles) that must not be forced onto the main actor, or
/// made async, just to read one cached identifier.
///
/// Write access happens only from `CollaborationSyncService` (@MainActor) whenever
/// `currentUserRecordID()` resolves, or when the iCloud account changes. Reads from any context
/// only ever affect which participant a balance/label momentarily resolves to — never persisted
/// or financial data — so the narrow, effectively-single-writer race window here is intentionally
/// accepted rather than adding synchronization machinery to a pure calculation concern.
enum CollaborationCurrentUser {
    nonisolated(unsafe) private static var _userRecordID: String?

    static var userRecordID: String? { _userRecordID }

    static func set(_ userRecordID: String?) {
        _userRecordID = userRecordID
    }
}

/// The event-scoped identity/membership record for one `Person` inside one `SharedEvent` — the
/// local counterpart of the CloudKit `Participant` record (see `CloudKitSharedEventMapper`).
///
/// This is deliberately a separate model from `Person`, not a set of fields added to it:
/// `Person` is reusable across events, but `userRecordID` (which iCloud account this participant
/// is claimed by) is only ever meaningful *within one event* — the same `Person` can be a guest
/// in one event and claimed by a specific iCloud user in another, and nothing here may leak an
/// identity association from one `SharedEvent` into another. Existing `SharedEvent.participants:
/// [Person]` is untouched by this addition; this model exists alongside it purely to carry
/// per-event identity state that has nowhere else to live.
@Model
final class EventParticipant {
    var role: ParticipantRole
    /// The CloudKit `CKRecord.ID.recordName` of the iCloud user this participant is associated
    /// with — `nil` means an unclaimed guest. Never a display name, email, or phone number: see
    /// the Phase 4 spec's "displayName is never authoritative identity" rule. Authoritative only
    /// for *this* event; the same iCloud user has an entirely separate `EventParticipant` (and
    /// possibly `nil` `userRecordID`) in every other `SharedEvent`.
    var userRecordID: String?
    var joinedAt: Date
    /// Soft-removal only (mirrors the existing shared-expenses pattern elsewhere): removing a
    /// participant from an event's active roster must never cascade-delete their historical
    /// expense attribution, so this is a flag, not a delete.
    var isRemoved: Bool

    var event: SharedEvent?
    var person: Person?

    init(
        event: SharedEvent?,
        person: Person?,
        role: ParticipantRole = .member,
        userRecordID: String? = nil,
        joinedAt: Date = .now,
        isRemoved: Bool = false
    ) {
        self.event = event
        self.person = person
        self.role = role
        self.userRecordID = userRecordID
        self.joinedAt = joinedAt
        self.isRemoved = isRemoved
    }
}

extension SharedEvent {
    /// The event-scoped participant (if any) claimed by the given CloudKit user — the
    /// authoritative way to answer "who am I in this event," per the Phase 4 rule that
    /// `userRecordID` is authoritative and `Person.isCurrentUser`/displayName are not. Returns
    /// `nil` for a local-only event (nothing here has ever been claimed) or when `userRecordID`
    /// matches no participant of *this* event — identity never leaks in from another event.
    func currentParticipant(for userRecordID: String) -> EventParticipant? {
        eventParticipants.first { $0.userRecordID == userRecordID && !$0.isRemoved }
    }

    /// Participants of this event with no iCloud user claimed yet — the candidate list for the
    /// "Who are you?" selection screen. Scoped to this event only; never any other event's
    /// participants, contacts, or unrelated `Person` records.
    var unclaimedParticipants: [EventParticipant] {
        eventParticipants.filter { $0.userRecordID == nil && !$0.isRemoved }
    }

    /// The display label for `person` within this event — "You" if `person` is this device's
    /// own identified participant, otherwise their normal display name.
    ///
    /// For a collaborative event, identity is authoritative through `EventParticipant.
    /// userRecordID` (rule: never `Person.isCurrentUser`, never displayName, for collaborative
    /// identity) — `currentUserRecordID` must be supplied by the caller, already resolved
    /// (e.g. by `SharedEventDetailView`'s existing identity check); this never performs a
    /// CloudKit call itself, so it's safe to call from every row of a list. For a local-only
    /// event (or a collaborative one whose identity hasn't resolved yet on this render), this
    /// falls back to the existing `Person.isCurrentUser` behavior, unchanged.
    func displayName(for person: Person, currentUserRecordID: String?) -> String {
        if isCollaborationEnabled, let currentUserRecordID {
            return currentParticipant(for: currentUserRecordID)?.person === person ? "You" : person.displayName
        }
        return person.isCurrentUser ? "You" : person.displayName
    }
}
