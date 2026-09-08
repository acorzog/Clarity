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
    /// Stable identity used once this event is represented as CloudKit records (the zone name
    /// and this event's own record name are both derived from it) — nil until the first time
    /// `CloudKitSharedEventMapper.map(_:)` runs. Purely local bookkeeping; never touched unless
    /// collaboration is actually used, so a local-only event never gains one.
    var remoteID: UUID?
    /// Explicit opt-in: only events the user has chosen to share get a CloudKit zone at all.
    /// Defaults to false so every existing and newly-created local event stays local-only
    /// unless something later calls `CollaborationSyncService.enableCollaboration(for:)`.
    var isCollaborationEnabled: Bool = false
    /// True only for an event this device received via `CKShare` acceptance — its zone lives in
    /// someone else's private database, mirrored into this device's *shared* database, so any
    /// local edit that needs to sync (e.g. claiming a `EventParticipant`) must go out through the
    /// shared `CKSyncEngine`, not the owned one. Defaults to false: every event created on this
    /// device, and every pre-Phase-4 event, is owned by this device exactly as before.
    var isRemoteOwned: Bool = false

    var participants: [Person] = []

    /// Event-scoped participant identity/membership records — see `EventParticipant`. Additive
    /// to `participants` above, not a replacement: everything that already reads `participants`
    /// keeps working unchanged.
    @Relationship(deleteRule: .cascade, inverse: \EventParticipant.event)
    var eventParticipants: [EventParticipant] = []

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
