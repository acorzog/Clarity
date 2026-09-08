import Foundation
import SwiftData
import CloudKit

/// Coordinates CloudKit synchronization and sharing for collaborative Shared Events only. This
/// is transport, reconciliation, and sharing-boundary infrastructure — it has no domain logic of
/// its own: it never calculates balances (see `SharedEventQuerying`), never creates a personal
/// `Entry`, never presents collaborative-expense-editing UI, and never manages participant
/// identity/claiming (a later phase). Its jobs are (1) moving the raw ledger —
/// `SharedEvent`/`Participant`/`Expense`/`ExpenseParticipant`/`Settlement` — between SwiftData
/// and CloudKit via `CKSyncEngine`, using `CloudKitSharedEventMapper` for the local → CKRecord
/// direction and deterministic-identity lookups for the reverse, and (2), as of Phase 3,
/// creating/reusing the `CKShare` that makes one event's custom zone visible to another iCloud
/// user and presenting Apple's native sharing UI for it.
///
/// Held on the main actor deliberately: SwiftData's `ModelContext` here is the app's own main
/// context (matching how the rest of the app already uses `@Environment(\.modelContext)`), and
/// `CKSyncEngineDelegate`'s callbacks aren't isolated to any particular actor by the framework,
/// so this class provides that isolation itself rather than juggling a background context.
@MainActor
final class CollaborationSyncService: CKSyncEngineDelegate {
    /// Apple's default per-app iCloud container naming convention (`iCloud.<bundle-id>`), and
    /// the identifier Phase 3 actually configures in `FinanceTracker.entitlements` (see that
    /// file and the Phase 3 report for what registering it in the Apple Developer portal still
    /// requires). Constructing a `CKContainer` with an unregistered identifier does not crash;
    /// it only surfaces as a `CKError` the first time an operation is attempted, which every
    /// entry point below already handles.
    nonisolated static let containerIdentifier = "iCloud.com.andreacorzo.FinanceTracker"

    let container: CKContainer
    private let modelContext: ModelContext

    /// Records that arrived before a dependency they need (their `SharedEvent`, their `Expense`,
    /// or a `Participant`'s local `Person`) had itself been applied yet — CloudKit does not
    /// guarantee delivery respects our domain's dependency order, so e.g. a `Participant` can
    /// legitimately arrive before its `SharedEvent`. Held in memory only, for this service
    /// instance's lifetime: nothing here is ever given up on. Every successful `apply(_:)` — a
    /// record resolving is itself evidence some dependency just became available — retries
    /// everything still pending, so a record can wait through any number of intermediate syncs
    /// and still eventually resolve once the record it needs actually arrives. Never grows
    /// unboundedly with genuinely bad data: a record that fails for a reason other than "its
    /// dependency hasn't arrived yet" (an unparseable ID or reference) is logged and discarded,
    /// never queued here.
    private var pendingRecords: [CKRecord] = []

    /// This device's own zones — every collaborative `SharedEvent` this device created lives
    /// here, and this is the only engine this service ever queues local writes into.
    private var ownedSyncEngine: CKSyncEngine!
    /// Zones other iCloud users have shared with this device via `CKShare`. Fetch-only in
    /// Phase 3: accepting a share pulls a shared event's records down into SwiftData so the
    /// recipient can see it, but writing back into someone else's shared zone is collaborative-
    /// expense-editing UX, which Phase 3 explicitly defers.
    private var sharedSyncEngine: CKSyncEngine!
    private var accountChangeObserver: NSObjectProtocol?

    init(
        modelContext: ModelContext,
        container: CKContainer = CKContainer(identifier: CollaborationSyncService.containerIdentifier),
        stateSerialization: CKSyncEngine.State.Serialization? = CollaborationSyncStateStore.load(for: .owned)
    ) {
        self.modelContext = modelContext
        self.container = container

        let ownedConfiguration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: stateSerialization,
            delegate: self
        )
        self.ownedSyncEngine = CKSyncEngine(ownedConfiguration)

        let sharedConfiguration = CKSyncEngine.Configuration(
            database: container.sharedCloudDatabase,
            stateSerialization: CollaborationSyncStateStore.load(for: .shared),
            delegate: self
        )
        self.sharedSyncEngine = CKSyncEngine(sharedConfiguration)

        // A stale cached identity after switching iCloud accounts would make every "your"
        // balance calculation wrong, not just a display label — worth invalidating explicitly
        // rather than waiting for the next call site that happens to re-resolve it.
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { _ in
            CollaborationCurrentUser.set(nil)
        }
    }

    deinit {
        if let accountChangeObserver {
            NotificationCenter.default.removeObserver(accountChangeObserver)
        }
    }

    // MARK: - App-wide shared instance

    private static var _shared: CollaborationSyncService?

    /// The instance the running app uses — `nil` until `configureShared(modelContext:)` runs at
    /// launch. Tests never touch this; they construct their own instances directly via `init`,
    /// which is why every method here works identically on `shared` or on a fresh instance.
    static var shared: CollaborationSyncService? { _shared }

    /// Configures the app-wide instance. Safe to call more than once — only the first call takes
    /// effect, so a re-entrant SwiftUI view update can't spin up a second engine pair pointed at
    /// the same CloudKit zones.
    static func configureShared(modelContext: ModelContext) {
        guard _shared == nil else { return }
        _shared = CollaborationSyncService(modelContext: modelContext)
    }

    // MARK: - Local → Cloud

    /// This device's own zone lives in the private database and is written through
    /// `ownedSyncEngine`; an event received via `CKShare` acceptance (`isRemoteOwned`) lives in
    /// the shared database and must be written through `sharedSyncEngine` instead. Every write
    /// path below goes through this so a new write path never has to re-derive the rule itself.
    private func syncEngine(for event: SharedEvent) -> CKSyncEngine {
        event.isRemoteOwned ? sharedSyncEngine : ownedSyncEngine
    }

    /// Ensures every current participant of `event` has a backing `EventParticipant` row before
    /// the event is mapped/uploaded. The mapper itself stays a pure, context-free function (as
    /// tested since Phase 1) and never creates rows — this is the one place that does, and only
    /// for the general full-graph upload path below, never for a single-participant identity
    /// claim (see `claimParticipant`), which must never risk re-uploading a stand-in row for a
    /// participant whose real state this device hasn't finished reconciling yet.
    ///
    /// Not private: the collaborative Add Expense UI calls this directly (before reading
    /// `event.eventParticipants` to build its participant/payer pickers — rule 25) so that list
    /// is never empty just because this event has never been uploaded yet. Purely local, pure
    /// SwiftData work — no network, safe to call as often as needed.
    func ensureEventParticipants(for event: SharedEvent) {
        for person in event.participants where !event.eventParticipants.contains(where: { $0.person === person }) {
            let role: ParticipantRole = person === event.currentUser ? .owner : .member
            let created = EventParticipant(event: event, person: person, role: role)
            modelContext.insert(created)
            event.eventParticipants.append(created)
        }
    }

    /// Marks `event` as collaborative (idempotent — safe to call again) and queues its full
    /// current graph for upload. Local SharedEvents that never call this stay local-only
    /// forever, matching the standing rule: nothing here uploads an event automatically.
    func enableCollaboration(for event: SharedEvent) {
        event.isCollaborationEnabled = true
        queueUpload(of: event)
    }

    /// Re-queues a collaborative event's current local state for upload — call after any local
    /// edit to one of its expenses/participants/settlements. A no-op for an event that was never
    /// explicitly enabled for collaboration.
    func queueUpload(of event: SharedEvent) {
        guard event.isCollaborationEnabled else {
            CollaborationLog.log("Skipped queuing upload — event is not collaboration-enabled")
            return
        }

        ensureEventParticipants(for: event)
        let graph = CloudKitSharedEventMapper.map(event)
        let engine = syncEngine(for: event)
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: graph.zoneID))])
        engine.state.add(pendingRecordZoneChanges: graph.allRecords.map { .saveRecord($0.recordID) })
        CollaborationLog.log("Queued \(graph.allRecords.count) record(s) for zone \(graph.zoneID.zoneName)")
    }

    /// Queues deletion of `expense`'s own CloudKit Expense record — call before removing a
    /// collaborative expense locally. Its ExpenseParticipant children don't need a separate
    /// deletion call: each was saved with a `.deleteSelf` reference back to its expense (see
    /// `CloudKitSharedEventMapper`), so CloudKit cascades their deletion automatically once the
    /// expense record itself is deleted server-side. A no-op for a non-collaborative event, or an
    /// expense that was never uploaded (`remoteID == nil` — nothing exists on the server yet).
    func queueDeletion(of expense: SharedExpense, from event: SharedEvent) {
        guard event.isCollaborationEnabled, let remoteID = expense.remoteID else { return }
        let zoneID = CloudKitSharedEventMapper.map(event).zoneID
        let recordID = CKRecord.ID(recordName: remoteID.uuidString, zoneID: zoneID)
        syncEngine(for: event).state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        CollaborationLog.log("Queued deletion of Expense \(remoteID)")
    }

    /// Queues deletion of specific ExpenseParticipant records — call when editing a collaborative
    /// expense replaces its shares (the existing Add Expense flow deletes and recreates every
    /// `SharedExpenseParticipant` on every edit, even unchanged ones, which mints fresh
    /// `remoteID`s and would otherwise leave the old CKRecords as stale, orphaned shares on the
    /// server — see rule 13). `remoteIDs` must be captured BEFORE the local rows are deleted,
    /// since deleting them loses the ID needed to address the corresponding CKRecord.
    func queueRemovalOfExpenseParticipants(_ remoteIDs: [UUID], for event: SharedEvent) {
        guard event.isCollaborationEnabled, !remoteIDs.isEmpty else { return }
        let zoneID = CloudKitSharedEventMapper.map(event).zoneID
        let recordIDs = remoteIDs.map { CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID) }
        syncEngine(for: event).state.add(pendingRecordZoneChanges: recordIDs.map { .deleteRecord($0) })
        CollaborationLog.log("Queued removal of \(recordIDs.count) obsolete ExpenseParticipant record(s)")
    }

    /// Explicitly asks both CKSyncEngines to send/fetch whatever's currently pending. Each engine
    /// also runs on its own automatic schedule; this exists for an explicit "sync now" request,
    /// e.g. after reconnecting. Fails gracefully — never throws out of here, per the
    /// offline-tolerance rule; a failure on one engine doesn't prevent the other from trying.
    func sendPendingChanges() async {
        do {
            try await ownedSyncEngine.sendChanges()
        } catch {
            CollaborationLog.error("sendChanges (owned) failed: \(error.localizedDescription)")
        }
        do {
            try await sharedSyncEngine.sendChanges()
        } catch {
            CollaborationLog.error("sendChanges (shared) failed: \(error.localizedDescription)")
        }
    }

    func fetchRemoteChanges() async {
        do {
            try await ownedSyncEngine.fetchChanges()
        } catch {
            CollaborationLog.error("fetchChanges (owned) failed: \(error.localizedDescription)")
        }
        do {
            try await sharedSyncEngine.fetchChanges()
        } catch {
            CollaborationLog.error("fetchChanges (shared) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Sharing (CKShare)

    /// Creates (or, if one already exists, reuses) the `CKShare` for `event`'s custom zone — the
    /// operation behind the "Share Event" button. This is zone-wide sharing
    /// (`CKShare(recordZoneID:)`), not hierarchical root-record sharing: the event's own custom
    /// zone is already this app's per-event collaboration/privacy boundary (see
    /// `CloudKitSharedEventMapper`), so the share simply grants access to that whole zone rather
    /// than needing a `CKRecord.parent` hierarchy of its own.
    ///
    /// Idempotent by construction, not by locally-tracked state: a CloudKit record zone can take
    /// part in only one share ever, and a zone-wide share always uses the well-known record name
    /// `CKRecordNameZoneWideShare`, so this always checks CloudKit itself for an existing share
    /// before creating a new one — calling this twice for the same event never creates two
    /// shares.
    ///
    /// Never deletes or otherwise damages the local `SharedEvent` on failure (rule 21): the event
    /// remains a perfectly usable local event regardless of the outcome, and the caller can
    /// retry later.
    func share(event: SharedEvent) async throws -> CKShare {
        if !event.isCollaborationEnabled {
            enableCollaboration(for: event)
        } else {
            queueUpload(of: event)
        }

        do {
            try await ownedSyncEngine.sendChanges()
        } catch {
            CollaborationLog.error("share(event:) failed while pushing the event graph: \(error.localizedDescription)")
            throw CollaborationSharingError.underlying(error)
        }

        let zoneID = CloudKitSharedEventMapper.map(event).zoneID
        let shareRecordID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)

        if let existingShare = await fetchExistingShare(recordID: shareRecordID) {
            CollaborationLog.log("Reusing existing share for zone \(zoneID.zoneName)")
            return existingShare
        }

        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = event.title
        share.publicPermission = .none

        do {
            _ = try await container.privateCloudDatabase.modifyRecords(saving: [share], deleting: [])
            CollaborationLog.log("Created new share for zone \(zoneID.zoneName)")
            return share
        } catch {
            CollaborationLog.error("share(event:) failed while saving the new CKShare: \(error.localizedDescription)")
            throw CollaborationSharingError.underlying(error)
        }
    }

    /// Looks up the zone-wide share by its well-known deterministic record ID rather than
    /// tracking "do we already have a share" as separate local state — CloudKit itself is
    /// already the source of truth for whether one exists. Returns `nil` on any failure
    /// (including "no share exists yet"), which `share(event:)` treats as "create one."
    private func fetchExistingShare(recordID: CKRecord.ID) async -> CKShare? {
        guard let results = try? await container.privateCloudDatabase.records(for: [recordID]) else { return nil }
        guard case .success(let record) = results[recordID] else { return nil }
        return record as? CKShare
    }

    /// Accepts an incoming share — the recipient side of the flow, invoked from
    /// `application(_:userDidAcceptCloudKitShareWith:)` when the user taps a share
    /// invitation. After CloudKit accepts, the shared event's records live in this device's
    /// *shared* database, not its private one, so this also kicks the shared engine to fetch
    /// them down into SwiftData right away rather than waiting for its next automatic pass.
    func acceptShare(metadata: CKShare.Metadata) async {
        do {
            let results = try await container.accept([metadata])
            switch results[metadata] {
            case .success:
                CollaborationLog.log("Accepted incoming share")
            case .failure(let error):
                CollaborationLog.error("Failed to accept incoming share: \(error.localizedDescription)")
                return
            case .none:
                CollaborationLog.error("Accepting incoming share returned no result")
                return
            }
        } catch {
            CollaborationLog.error("Failed to accept incoming share: \(error.localizedDescription)")
            return
        }

        do {
            try await sharedSyncEngine.fetchChanges()
        } catch {
            CollaborationLog.error("fetchChanges after share acceptance failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Event-scoped participant identity (Phase 4)

    /// The authenticated iCloud user's stable identifier, or `nil` if it can't be determined
    /// right now (no account, restricted, network error, anything else) — never throws. Every
    /// caller treats "identity unknown" identically regardless of the underlying reason, per the
    /// iCloud-unavailable rule: local Shared Expenses usage is never blocked by this.
    ///
    /// Every successful resolution also populates `CollaborationCurrentUser`, the synchronous
    /// session-level cache `SharedEventQuerying`'s balance calculations read — so any existing
    /// caller of this method (the identity check in `SharedEventDetailView`, the default-payer
    /// resolution in `AddSharedExpenseView`/`RecordPaymentView`, etc.) also warms that cache as a
    /// side effect, with no new call sites needed anywhere.
    func currentUserRecordID() async -> String? {
        do {
            let userRecordID = try await container.userRecordID().recordName
            CollaborationCurrentUser.set(userRecordID)
            return userRecordID
        } catch {
            CollaborationLog.error("Failed to fetch current user record ID: \(error.localizedDescription)")
            return nil
        }
    }

    /// Associates `userRecordID` with `participant` — the operation behind "Who are you?"
    /// (rule 4/7). Only ever touches the ONE Participant record being claimed, never the rest of
    /// the event's graph (unlike `queueUpload`), specifically so this can never risk re-uploading
    /// a stand-in/incomplete row for some other participant this device hasn't fully reconciled
    /// yet — see `CloudKitSharedEventMapper.participantRecord(for:in:)`.
    ///
    /// Race safety is two-layered: a local guard rejects an already-claimed participant
    /// immediately, without a network round trip, for the common case where this device already
    /// knows about the claim. For the genuine race — two devices claiming the same unclaimed
    /// participant at the same instant — CloudKit's own change-tag conflict detection is the real
    /// safety net: whichever write reaches the server second surfaces as `.serverRecordChanged`
    /// in `handleFailedSave`, which already (since Phase 2) accepts the server's copy and
    /// reconciles it back through `applyParticipant` exactly like any other incoming change —
    /// correcting the losing device's local `userRecordID` to match reality, automatically, with
    /// no additional code. Nothing here overwrites another user's association.
    func claimParticipant(_ participant: EventParticipant, in event: SharedEvent, as userRecordID: String) async -> ParticipantClaimResult {
        guard participant.userRecordID == nil else {
            return .alreadyClaimedByAnother
        }
        guard
            let person = participant.person,
            let record = CloudKitSharedEventMapper.participantRecord(for: person, in: event)
        else {
            return .failed(ParticipantClaimError.participantNotResolvable)
        }

        participant.userRecordID = userRecordID

        let engine = syncEngine(for: event)
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        do {
            try await engine.sendChanges()
        } catch {
            // Roll back the optimistic local write — the claim never actually reached CloudKit,
            // so this device must not present itself as identified when it isn't.
            participant.userRecordID = nil
            CollaborationLog.error("claimParticipant failed: \(error.localizedDescription)")
            return .failed(error)
        }
        CollaborationLog.log("Claimed participant for zone \(record.recordID.zoneID.zoneName)")
        return .claimed
    }

    // MARK: - CKSyncEngineDelegate — supplying outgoing records

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] recordID in
            await self?.record(for: recordID)
        }
    }

    /// Re-derives the CKRecord for one pending change by re-mapping its owning SharedEvent. The
    /// mapper is pure and cheap, so this avoids keeping a second, parallel in-memory cache of
    /// records that could drift from SwiftData's actual current state — SwiftData (via
    /// `remoteID`) stays the only source of truth for what a record currently looks like. Only
    /// ever called for the owned engine in practice, since nothing queues pending changes into
    /// the shared engine in Phase 3.
    private func record(for recordID: CKRecord.ID) -> CKRecord? {
        guard let event = owningSharedEvent(for: recordID.zoneID) else {
            CollaborationLog.error("No local SharedEvent found for zone \(recordID.zoneID.zoneName)")
            return nil
        }
        let graph = CloudKitSharedEventMapper.map(event)
        return graph.allRecords.first { $0.recordID == recordID }
    }

    /// Finds the local `SharedEvent` a zone change belongs to by comparing only the zone's
    /// `zoneName` (which already embeds the event's `remoteID` — see
    /// `CloudKitSharedEventMapper`), never its `ownerName`. This matters once a second device is
    /// involved: a zone this device owns has `ownerName == CKCurrentUserDefaultName`, but the
    /// exact same zone as it appears in a *recipient's* shared database is reported with the
    /// sharer's own opaque owner name instead. Matching on `zoneName` alone is correct in both
    /// cases and is still exact, since the event's UUID makes every zone name unique regardless
    /// of whose database it's read from.
    func owningSharedEvent(for zoneID: CKRecordZone.ID) -> SharedEvent? {
        let descriptor = FetchDescriptor<SharedEvent>()
        guard let events = try? modelContext.fetch(descriptor) else { return nil }
        return events.first {
            guard let remoteID = $0.remoteID else { return false }
            return zoneID.zoneName == "SharedEvent-\(remoteID.uuidString)"
        }
    }

    // MARK: - CKSyncEngineDelegate — lifecycle + incoming changes

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let stateUpdate):
            let scope: CollaborationSyncStateStore.Scope = (syncEngine === sharedSyncEngine) ? .shared : .owned
            CollaborationSyncStateStore.save(stateUpdate.stateSerialization, for: scope)

        case .accountChange(let change):
            CollaborationLog.log("iCloud account changed: \(change.changeType)")

        case .fetchedDatabaseChanges(let changes):
            applyFetchedDatabaseChanges(changes)

        case .fetchedRecordZoneChanges(let changes):
            applyFetchedRecordZoneChanges(changes)

        case .sentRecordZoneChanges(let changes):
            handleSentRecordZoneChanges(changes)

        case .sentDatabaseChanges(let changes):
            if !changes.failedZoneSaves.isEmpty {
                CollaborationLog.error("Failed to save \(changes.failedZoneSaves.count) zone(s)")
            }

        case .willFetchChanges, .didFetchChanges, .willFetchRecordZoneChanges,
             .didFetchRecordZoneChanges, .willSendChanges, .didSendChanges:
            break // Lifecycle markers only — nothing to react to for this foundation.

        @unknown default:
            break
        }
    }

    private func applyFetchedDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) {
        for deletion in changes.deletions {
            CollaborationLog.log("Zone deleted remotely: \(deletion.zoneID.zoneName)")
            // The local ledger stays exactly as it is — only the collaboration flag drops, so
            // the event falls back to behaving like any other local-only SharedEvent rather
            // than losing data because its remote copy is gone. Best-effort: if this device is
            // a recipient whose shared zone was unshared, the lookup may not find a match (see
            // `owningSharedEvent`'s doc); the local event simply keeps its flag in that case,
            // which is a harmless staleness, not a privacy or data-loss issue.
            owningSharedEvent(for: deletion.zoneID)?.isCollaborationEnabled = false
        }
    }

    private func applyFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        for modification in changes.modifications {
            apply(modification.record)
        }
        for deletion in changes.deletions {
            applyDeletion(recordID: deletion.recordID, recordType: deletion.recordType)
        }
    }

    private func handleSentRecordZoneChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) {
        for failure in changes.failedRecordSaves {
            handleFailedSave(failure)
        }
        if !changes.savedRecords.isEmpty {
            CollaborationLog.log("Uploaded \(changes.savedRecords.count) record(s)")
        }
    }

    /// Conflict policy — documented here and in the Phase 2/3 reports: CloudKit itself is the
    /// arbiter. A `.serverRecordChanged` failure means someone else's write already landed, so
    /// this device accepts the server's copy and reconciles it into SwiftData exactly like any
    /// other incoming change, rather than retrying its own write or attempting a field-level
    /// merge. No timestamp comparison, no CRDT — last write to actually reach CloudKit wins, and
    /// the loser's local state is corrected to match on the very next event.
    private func handleFailedSave(_ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave) {
        switch failure.error.code {
        case .serverRecordChanged:
            if let serverRecord = failure.error.serverRecord {
                apply(serverRecord)
                CollaborationLog.log("Conflict on \(failure.record.recordID.recordName) — accepted the server's version")
            }
        case .zoneNotFound, .userDeletedZone:
            CollaborationLog.error("Zone missing for \(failure.record.recordID.recordName) — leaving local data untouched")
        default:
            CollaborationLog.error("Failed to save \(failure.record.recordID.recordName): \(failure.error.localizedDescription)")
        }
    }

    // MARK: - Cloud → Local reconciliation

    /// Whether reconciling one CKRecord succeeded, needs to wait for a dependency that hasn't
    /// arrived yet, or can never succeed at all. Only `.deferred` records are retried later —
    /// `.invalid` ones (an unparseable ID or reference) are logged and dropped for good, since
    /// waiting can never fix a malformed record.
    private enum ReconciliationOutcome {
        case applied
        case deferred
        case invalid
    }

    /// Reconciles one incoming CKRecord into SwiftData — an upsert keyed by deterministic
    /// identity (`CloudKitRecordIdentity`, never array position or object identity), so
    /// processing the same remote record any number of times always yields exactly one local
    /// row. Only ever touches the five Shared* models; never creates Entry/Wallet/Budget/
    /// Category — there is no code path here that even references those types. Works identically
    /// whether the record arrived via the owned or the shared database.
    ///
    /// CloudKit does not guarantee delivery respects our domain's dependency order (a
    /// `Participant` can arrive before its `SharedEvent`, an `Expense` before its `SharedEvent`,
    /// an `ExpenseParticipant` before its `Expense`, a `Settlement` before its `Participant`s), so
    /// a record that can't yet resolve its dependency is queued in `pendingRecords` rather than
    /// dropped. Since resolving any record is itself evidence a dependency just became available,
    /// every successful apply retries the whole pending queue.
    func apply(_ record: CKRecord) {
        switch reconcile(record) {
        case .applied:
            drainPendingRecords()
        case .deferred:
            pendingRecords.append(record)
            CollaborationLog.log("Deferred \(record.recordType) \(record.recordID.recordName) — a dependency hasn't arrived yet")
        case .invalid:
            break // Already logged by the specific reconciler below.
        }
    }

    private func reconcile(_ record: CKRecord) -> ReconciliationOutcome {
        switch record.recordType {
        case CloudKitSharedEventMapper.RecordType.sharedEvent:
            return applySharedEvent(record)
        case CloudKitSharedEventMapper.RecordType.participant:
            return applyParticipant(record)
        case CloudKitSharedEventMapper.RecordType.expense:
            return applyExpense(record)
        case CloudKitSharedEventMapper.RecordType.expenseParticipant:
            return applyExpenseParticipant(record)
        case CloudKitSharedEventMapper.RecordType.settlement:
            return applySettlement(record)
        default:
            CollaborationLog.error("Ignored unknown record type: \(record.recordType)")
            return .invalid
        }
    }

    /// Retries every currently pending record, repeating until a full pass resolves nothing more
    /// (a fixed point) — one dependency becoming available can unblock a chain (e.g. a
    /// `SharedEvent` unblocks a `Participant`, which then unblocks a `Settlement` that needed that
    /// participant's `Person`). Safe to call as often as needed: `reconcile` is an idempotent
    /// upsert, so retrying an already-applied record is a harmless no-op.
    private func drainPendingRecords() {
        guard !pendingRecords.isEmpty else { return }
        var madeProgress = true
        while madeProgress {
            madeProgress = false
            var stillPending: [CKRecord] = []
            for record in pendingRecords {
                switch reconcile(record) {
                case .applied:
                    madeProgress = true
                case .deferred:
                    stillPending.append(record)
                case .invalid:
                    madeProgress = true // Drop it — don't requeue a record that can never resolve.
                }
            }
            pendingRecords = stillPending
        }
    }

    private func applySharedEvent(_ record: CKRecord) -> ReconciliationOutcome {
        guard let remoteID = CloudKitRecordIdentity.remoteID(fromRecordName: record.recordID.recordName) else {
            CollaborationLog.error("SharedEvent record has an unparseable ID")
            return .invalid
        }

        let event = fetchSharedEvent(remoteID: remoteID) ?? {
            let created = SharedEvent(title: "")
            created.remoteID = remoteID
            created.isCollaborationEnabled = true
            // The only way a SharedEvent is genuinely first-seen through reconciliation (rather
            // than already existing locally from NewSharedEventView/enableCollaboration) is by
            // arriving via the shared database — this device's own uploads always create the
            // local row first. That makes this the correct, one-time signal for `isRemoteOwned`.
            created.isRemoteOwned = true
            modelContext.insert(created)
            return created
        }()

        event.title = (record["title"] as? String) ?? event.title
        event.icon = record["icon"] as? String
        event.colorHex = record["colorHex"] as? String
        if let statusRaw = record["status"] as? String, let status = SharedEventStatus(rawValue: statusRaw) {
            event.status = status
        }
        event.startDate = record["startDate"] as? Date
        event.endDate = record["endDate"] as? Date
        if let updatedAt = record["updatedAt"] as? Date {
            event.updatedAt = updatedAt
        }
        return .applied
    }

    private func applyParticipant(_ record: CKRecord) -> ReconciliationOutcome {
        guard let components = CloudKitRecordIdentity.participantComponents(fromRecordName: record.recordID.recordName) else {
            CollaborationLog.error("Participant record has an unparseable ID")
            return .invalid
        }
        guard let event = fetchSharedEvent(remoteID: components.eventID) else {
            return .deferred
        }

        let displayName = (record["displayName"] as? String) ?? "Participant"
        let person = fetchPerson(sharingAnchorID: components.personAnchorID) ?? {
            let created = Person(displayName: displayName)
            created.sharingAnchorID = components.personAnchorID
            modelContext.insert(created)
            return created
        }()
        person.displayName = displayName
        person.colorHex = record["colorHex"] as? String

        if !event.participants.contains(where: { $0 === person }) {
            event.participants.append(person)
        }

        let membership = event.eventParticipants.first(where: { $0.person === person }) ?? {
            let created = EventParticipant(event: event, person: person)
            modelContext.insert(created)
            event.eventParticipants.append(created)
            return created
        }()
        if let roleRaw = record["role"] as? String, let role = ParticipantRole(rawValue: roleRaw) {
            membership.role = role
        }
        // The authoritative identity association for this event — see `EventParticipant`. `nil`
        // (the field absent from the record) correctly reconciles back to `nil` here, matching
        // "no value" rather than leaving a stale local claim in place.
        membership.userRecordID = record["userRecordID"] as? String
        if let joinedAt = record["joinedAt"] as? Date {
            membership.joinedAt = joinedAt
        }
        membership.isRemoved = ((record["isRemoved"] as? Int64) ?? 0) != 0

        return .applied
    }

    private func applyExpense(_ record: CKRecord) -> ReconciliationOutcome {
        guard let remoteID = CloudKitRecordIdentity.remoteID(fromRecordName: record.recordID.recordName) else {
            CollaborationLog.error("Expense record has an unparseable ID")
            return .invalid
        }
        guard
            let eventReference = record["event"] as? CKRecord.Reference,
            let eventRemoteID = CloudKitRecordIdentity.remoteID(fromRecordName: eventReference.recordID.recordName)
        else {
            CollaborationLog.error("Expense record has an unresolvable event reference")
            return .invalid
        }
        guard let event = fetchSharedEvent(remoteID: eventRemoteID) else {
            return .deferred
        }

        let expense = fetchExpense(remoteID: remoteID) ?? {
            let created = SharedExpense(amount: 0, currency: "USD", event: event)
            created.remoteID = remoteID
            modelContext.insert(created)
            event.expenses.append(created)
            return created
        }()

        expense.amount = Self.decimal(fromCents: record["amountCents"] as? Int64)
        expense.currency = (record["currency"] as? String) ?? expense.currency
        expense.note = (record["note"] as? String) ?? ""
        expense.date = (record["date"] as? Date) ?? expense.date
        if let splitRaw = record["splitMethod"] as? String, let split = SharedSplitMethod(rawValue: splitRaw) {
            expense.splitMethod = split
        }
        if let updatedAt = record["updatedAt"] as? Date {
            expense.updatedAt = updatedAt
        }
        // categoryName/categoryIcon/categoryColorHex are a read-only display snapshot from
        // whoever created the expense — this device never re-links them to its own personal
        // Category table (that would blur the shared/personal boundary and could fabricate or
        // alter a personal category), it only mirrors them into the snapshot fields so the UI
        // can still show the original badge. `expense.category` (the real link) is untouched.
        expense.remoteCategoryName = record["categoryName"] as? String
        expense.remoteCategoryIcon = record["categoryIcon"] as? String
        expense.remoteCategoryColorHex = record["categoryColorHex"] as? String

        // paidBy stays a soft, best-effort resolution (unlike the hard dependencies above): an
        // expense is still fully usable with no payer yet, and there is no local list this
        // reference could otherwise get permanently stuck in. It's still validated, though: a
        // reference whose own encoded event ID doesn't match this expense's event is rejected
        // outright rather than resolved — a participant can never be borrowed from another event.
        if
            let payerReference = record["paidBy"] as? CKRecord.Reference,
            let payerComponents = CloudKitRecordIdentity.participantComponents(fromRecordName: payerReference.recordID.recordName)
        {
            if payerComponents.eventID == eventRemoteID, let payer = fetchPerson(sharingAnchorID: payerComponents.personAnchorID) {
                expense.paidBy = payer
            } else if payerComponents.eventID != eventRemoteID {
                CollaborationLog.error("Rejected cross-event paidBy reference on Expense \(remoteID)")
            }
        }
        return .applied
    }

    private func applyExpenseParticipant(_ record: CKRecord) -> ReconciliationOutcome {
        guard let remoteID = CloudKitRecordIdentity.remoteID(fromRecordName: record.recordID.recordName) else {
            CollaborationLog.error("ExpenseParticipant record has an unparseable ID")
            return .invalid
        }
        guard
            let expenseReference = record["expense"] as? CKRecord.Reference,
            let expenseRemoteID = CloudKitRecordIdentity.remoteID(fromRecordName: expenseReference.recordID.recordName)
        else {
            CollaborationLog.error("ExpenseParticipant record has an unresolvable expense reference")
            return .invalid
        }
        guard
            let participantReference = record["participant"] as? CKRecord.Reference,
            let components = CloudKitRecordIdentity.participantComponents(fromRecordName: participantReference.recordID.recordName)
        else {
            CollaborationLog.error("ExpenseParticipant record has an unresolvable participant reference")
            return .invalid
        }
        guard let expense = fetchExpense(remoteID: expenseRemoteID) else {
            return .deferred
        }
        // Cross-event validation (rule 22): the participant reference's own encoded event ID must
        // match the expense's actual event — never resolvable by waiting, so this is `.invalid`,
        // not `.deferred`.
        guard let expenseEventRemoteID = expense.event?.remoteID, components.eventID == expenseEventRemoteID else {
            CollaborationLog.error("Rejected cross-event participant reference on ExpenseParticipant \(remoteID)")
            return .invalid
        }
        guard let person = fetchPerson(sharingAnchorID: components.personAnchorID) else {
            return .deferred
        }

        let share = fetchExpenseParticipant(remoteID: remoteID) ?? {
            let created = SharedExpenseParticipant(person: person, amount: 0, expense: expense)
            created.remoteID = remoteID
            modelContext.insert(created)
            expense.participants.append(created)
            return created
        }()

        share.person = person
        share.amount = Self.decimal(fromCents: record["amountCents"] as? Int64)
        share.parts = (record["parts"] as? Int64).map { Int($0) }
        return .applied
    }

    private func applySettlement(_ record: CKRecord) -> ReconciliationOutcome {
        guard let remoteID = CloudKitRecordIdentity.remoteID(fromRecordName: record.recordID.recordName) else {
            CollaborationLog.error("Settlement record has an unparseable ID")
            return .invalid
        }
        guard
            let eventReference = record["event"] as? CKRecord.Reference,
            let eventRemoteID = CloudKitRecordIdentity.remoteID(fromRecordName: eventReference.recordID.recordName)
        else {
            CollaborationLog.error("Settlement record has an unresolvable event reference")
            return .invalid
        }
        guard
            let fromReference = record["fromParticipant"] as? CKRecord.Reference,
            let fromComponents = CloudKitRecordIdentity.participantComponents(fromRecordName: fromReference.recordID.recordName),
            let toReference = record["toParticipant"] as? CKRecord.Reference,
            let toComponents = CloudKitRecordIdentity.participantComponents(fromRecordName: toReference.recordID.recordName)
        else {
            CollaborationLog.error("Settlement record has an unresolvable participant reference")
            return .invalid
        }
        // Cross-event validation (consistent with applyExpense/applyExpenseParticipant): a
        // participant reference's own encoded event ID must match this settlement's actual
        // event. Never resolvable by waiting, so this is `.invalid`, not `.deferred` — checked
        // before fetching the event so a forged reference is rejected even before the event
        // itself has arrived.
        guard fromComponents.eventID == eventRemoteID, toComponents.eventID == eventRemoteID else {
            CollaborationLog.error("Rejected cross-event participant reference on Settlement \(remoteID)")
            return .invalid
        }
        guard let event = fetchSharedEvent(remoteID: eventRemoteID) else {
            return .deferred
        }
        guard
            let fromPerson = fetchPerson(sharingAnchorID: fromComponents.personAnchorID),
            let toPerson = fetchPerson(sharingAnchorID: toComponents.personAnchorID)
        else {
            return .deferred
        }

        let settlement = fetchSettlement(remoteID: remoteID) ?? {
            let created = Settlement(fromPerson: fromPerson, toPerson: toPerson, amount: 0, paymentMethod: .other, event: event)
            created.remoteID = remoteID
            modelContext.insert(created)
            event.settlements.append(created)
            return created
        }()

        settlement.fromPerson = fromPerson
        settlement.toPerson = toPerson
        settlement.amount = Self.decimal(fromCents: record["amountCents"] as? Int64)
        if let methodRaw = record["paymentMethod"] as? String, let method = SettlementPaymentMethod(rawValue: methodRaw) {
            settlement.paymentMethod = method
        }
        settlement.date = (record["date"] as? Date) ?? settlement.date
        // settlement.transaction is never read or set here — it has no CloudKit counterpart at
        // all (see Settlement.swift and CloudKitSharedEventMapper) and must remain exactly
        // whatever this device's own local state already says, regardless of remote data.
        return .applied
    }

    private func applyDeletion(recordID: CKRecord.ID, recordType: CKRecord.RecordType) {
        // A record that was deferred and then deleted server-side before its dependency ever
        // arrived would otherwise wait in `pendingRecords` forever, since it never created a
        // local row for this to find and delete below.
        pendingRecords.removeAll { $0.recordID == recordID }
        switch recordType {
        case CloudKitSharedEventMapper.RecordType.sharedEvent:
            deleteIfPresent(fetchSharedEvent(remoteID:), recordID: recordID)
        case CloudKitSharedEventMapper.RecordType.expense:
            deleteIfPresent(fetchExpense(remoteID:), recordID: recordID)
        case CloudKitSharedEventMapper.RecordType.expenseParticipant:
            deleteIfPresent(fetchExpenseParticipant(remoteID:), recordID: recordID)
        case CloudKitSharedEventMapper.RecordType.settlement:
            deleteIfPresent(fetchSettlement(remoteID:), recordID: recordID)
        case CloudKitSharedEventMapper.RecordType.participant:
            // A Participant record going away doesn't delete the local, reusable Person, and
            // "removed from this event" semantics belong with real sharing (alongside the
            // `isRemoved` design already scoped for the participant-identity phase) — no action
            // here yet.
            CollaborationLog.log("Participant record deleted remotely — no local action yet")
        default:
            break
        }
    }

    private func deleteIfPresent<Model: PersistentModel>(_ fetch: (UUID) -> Model?, recordID: CKRecord.ID) {
        guard
            let remoteID = CloudKitRecordIdentity.remoteID(fromRecordName: recordID.recordName),
            let model = fetch(remoteID)
        else { return }
        modelContext.delete(model)
    }

    // MARK: - Local lookups (identity-keyed, never by array position or object identity)

    private func fetchSharedEvent(remoteID: UUID) -> SharedEvent? {
        let descriptor = FetchDescriptor<SharedEvent>(predicate: #Predicate { $0.remoteID == remoteID })
        return try? modelContext.fetch(descriptor).first
    }

    private func fetchPerson(sharingAnchorID: UUID) -> Person? {
        let descriptor = FetchDescriptor<Person>(predicate: #Predicate { $0.sharingAnchorID == sharingAnchorID })
        return try? modelContext.fetch(descriptor).first
    }

    private func fetchExpense(remoteID: UUID) -> SharedExpense? {
        let descriptor = FetchDescriptor<SharedExpense>(predicate: #Predicate { $0.remoteID == remoteID })
        return try? modelContext.fetch(descriptor).first
    }

    private func fetchExpenseParticipant(remoteID: UUID) -> SharedExpenseParticipant? {
        let descriptor = FetchDescriptor<SharedExpenseParticipant>(predicate: #Predicate { $0.remoteID == remoteID })
        return try? modelContext.fetch(descriptor).first
    }

    private func fetchSettlement(remoteID: UUID) -> Settlement? {
        let descriptor = FetchDescriptor<Settlement>(predicate: #Predicate { $0.remoteID == remoteID })
        return try? modelContext.fetch(descriptor).first
    }

    private static func decimal(fromCents cents: Int64?) -> Decimal {
        guard let cents else { return 0 }
        return Decimal(cents) / 100
    }
}

/// User-facing sharing failures — deliberately small and never carries a raw `CKError` string
/// out to the UI (rule 20: "do not expose raw CloudKit error dumps to users"). Diagnostic detail
/// still goes to `CollaborationLog` at the point of failure.
enum CollaborationSharingError: LocalizedError {
    case underlying(Error)

    var errorDescription: String? {
        "Couldn't share this event. Check your iCloud connection and try again."
    }
}

/// The outcome of `CollaborationSyncService.claimParticipant(_:in:as:)`.
enum ParticipantClaimResult {
    case claimed
    case alreadyClaimedByAnother
    case failed(Error)
}

enum ParticipantClaimError: LocalizedError {
    /// The chosen `EventParticipant`'s `Person` is no longer a participant of the event (e.g.
    /// removed locally between the "Who are you?" list loading and the user tapping Continue).
    case participantNotResolvable

    var errorDescription: String? {
        "Couldn't confirm your identity. Please try again."
    }
}
