import Foundation
import SwiftData
import os

/// The minimal surface `SyncCoordinator` needs to decide whether an automatic sync should even
/// attempt the network — matches `SupabaseAuthService.hasActiveSession()`'s existing signature
/// exactly, so that type conforms with no changes of its own. Exists so tests can substitute a
/// mock session state instead of a real one. Deliberately separate from `SupabaseSyncUserProviding`
/// (used internally by `SupabaseSyncService` itself) — this is a cheaper, coordinator-level
/// short-circuit so an automatic trigger firing while fully signed out never even constructs a
/// fetch/batch request, not a replacement for the service's own `requireUserID()` check.
protocol SyncCoordinatorSessionChecking {
    func hasActiveSession() async -> Bool
}

extension SupabaseAuthService: SyncCoordinatorSessionChecking {}

/// The minimum state `SyncCoordinator` needs to survive across launches — just the timestamp of
/// the last sync that actually completed successfully (Phase 4G.3B). `isSyncing`/
/// `hasPendingLocalChanges` are deliberately *not* part of this protocol: both are meaningless
/// once the process exits (a mid-flight sync is simply gone; "pending" local changes are re-
/// derived the instant anything saves again), so neither is persisted. Separate from
/// `SyncCoordinatorSessionChecking`/`SupabaseSyncUserProviding` for the same reason those are
/// their own protocols — a narrow, swappable surface so tests never touch real `UserDefaults`.
protocol SyncLastSuccessStoring: AnyObject {
    var lastSuccessfulSync: Date? { get set }
}

/// Backed by the same App-Group-scoped `UserDefaults` suite `BudgetSettingsStore` already uses
/// (falls back to `.standard` only if that container is ever unavailable) — not because the
/// widget extension needs this value, but to stay consistent with this app's one established
/// pattern for a small piece of persisted app state that isn't SwiftData.
final class UserDefaultsSyncLastSuccessStore: SyncLastSuccessStoring {
    private let defaults: UserDefaults
    private static let key = "com.andreacorzo.FinanceTracker.lastSuccessfulSync"

    init(defaults: UserDefaults = UserDefaults(suiteName: SharedModelContainer.appGroupID) ?? .standard) {
        self.defaults = defaults
    }

    var lastSuccessfulSync: Date? {
        get { defaults.object(forKey: Self.key) as? Date }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

/// Phase 3C/4G.3B — the single place automatic (non-manual) Supabase sync is triggered from.
/// Reuses `SupabaseSyncService` entirely unchanged; this only decides *when* to call it. The
/// manual "Sync Reference Data" / "Entry Sync" / "Sync All Data" buttons in `SupabaseTestView`
/// are unrelated and untouched by this type.
///
/// Phase 4G.3B replaced "sync after every local save" with four controlled triggers, because a
/// local SwiftData save must always update the UI immediately and never wait on a network round
/// trip, but that doesn't mean every save should *also* kick off one:
/// - **App active/launch** (`handleAppBecameActive`) — syncs only if the last successful sync is
///   stale (`periodicSyncInterval`, default 10 minutes, or never) or there are pending local
///   changes; otherwise a no-op. Also (re)starts the periodic timer below.
/// - **Pull-to-refresh** (`refresh(modelContext:)`) — always syncs, unconditionally, and the
///   returned/awaited work only finishes once a real sync pass (including any coalesced extra
///   pass) has actually completed, so a `.refreshable` spinner bound to it stays accurate.
/// - **Periodic** — a timer loop, started on `handleAppBecameActive` and stopped on
///   `handleAppDidEnterBackground`, that requests a sync roughly every `periodicSyncInterval`
///   while active.
/// - **Local changes** (`handleDidSave`) — no longer schedules a sync at all. It only flips
///   `hasPendingLocalChanges` to `true` (so the *next* real trigger knows there's something worth
///   syncing), exactly like it already ignores a pull step's own save (Phase 4G.3A) for the same
///   reason: that save didn't originate from the user.
///
/// All four still funnel into `ensureSyncRunning(modelContext:)`, which still never runs two sync
/// passes at once and still never silently drops a trigger that arrives mid-sync (Phase 4G.1) —
/// it coalesces into exactly one additional pass immediately after the in-flight one finishes,
/// with the same hard two-pass-per-invocation cap that rules out an unbounded chain. A sync pass
/// that's skipped outright (no session) or that fails outright never touches
/// `lastSuccessfulSync`/`hasPendingLocalChanges` — only a pass that actually completes all six
/// steps does. SwiftData remains the local source of truth throughout: nothing here ever touches,
/// blocks, or rolls back the local save that set `hasPendingLocalChanges`.
@MainActor
final class SyncCoordinator {
    static let shared = SyncCoordinator()

    /// `ModelContext.didSave`'s notification only needs to be inspected, never fetched from, to
    /// decide whether a save is worth marking as a pending change — a save that only touched,
    /// say, `SpendingInsight` or `GoalContribution` shouldn't mark anything. Matches exactly the
    /// five models `SupabaseSyncService` currently uploads (`HeadCategory`/`Category`/`Wallet`/
    /// `Budget`/`Entry`).
    private static let syncableEntityNames: Set<String> = [
        "Entry", "Wallet", "Category", "HeadCategory", "Budget",
    ]

    private static let logger = Logger(subsystem: "com.andreacorzo.FinanceTracker", category: "SyncCoordinator")

    private let syncService: SupabaseSyncService
    private let sessionChecker: SyncCoordinatorSessionChecking
    private let lastSyncStore: SyncLastSuccessStoring
    private let debounceInterval: Duration
    /// Both "how stale does the last successful sync need to be for an app-activation trigger to
    /// fire" and "how often the periodic timer ticks while active" — the same ~10 minutes covers
    /// both roles by design (Phase 4G.3B), so one value drives both rather than two that could
    /// drift apart. Injectable so tests never wait 10 real minutes.
    private let periodicSyncInterval: Duration

    private var debounceTask: Task<Void, Never>?
    private var periodicSyncTask: Task<Void, Never>?
    private var activeSyncTask: Task<Void, Never>?
    private var isSyncing = false
    /// Phase 4G.1 — set when a trigger lands while `isSyncing` is already true, instead of that
    /// trigger being silently dropped forever. Holds the `modelContext` that trigger would have
    /// used, so the one extra pass runs against it. A plain `ModelContext?` rather than a
    /// counter/queue is deliberate: it can only ever represent "one more pass is owed," never "N
    /// more passes are owed" — see `ensureSyncRunning`'s own doc comment for why that cap, not the
    /// trigger itself, is what prevents an unbounded retry loop.
    private var pendingResyncModelContext: ModelContext?
    /// Phase 4G.3A — true for the exact duration of each of the three pull calls (`pullReferenceData`/
    /// `pullBudgets`/`pullEntries`) in `runOneSyncPass`, nothing else. A pull step's own internal
    /// `modelContext.save()` posts a real `ModelContext.didSave` notification — indistinguishable
    /// from a user's own save by content — so `handleDidSave` checks this flag to tell "this sync
    /// pass's own pull just saved something" apart from "something else changed" and ignore only
    /// the former (now: skip marking `hasPendingLocalChanges`, Phase 4G.3B). Deliberately scoped
    /// to pull only, not push — push's own remoteID-minting save is similarly self-caused, but
    /// only pull was identified as the redundant-trigger source in the 4G.2 audit.
    ///
    /// Phase 4G.6 — `handleCrossProcessChange` checks this same flag for the same reason: a
    /// pull's own save can post `NSPersistentStoreRemoteChangeNotification` too (persistent
    /// history tracking notifies every observer, not only a genuinely different process), so both
    /// of `RootView`'s notification paths are suppressed by the same window, not just one of them.
    private var isApplyingPullChanges = false
    /// True for the entire duration of `runOneSyncPass` (not just its pull steps). Each of the six
    /// steps saves against its own `BackgroundSyncExecutor` context and posts its own
    /// `.NSPersistentStoreRemoteChange`, which `RootView` otherwise answers with an immediate
    /// `modelContext.rollback()` on the *main* context — up to six rollbacks in one pass. Rolling
    /// back invalidates every object the main context currently has registered, including whatever
    /// a `@Query`-driven view is mid-computation over (walking `.category`/`.headCategory`/`.wallet`
    /// relationships) — landing one there is what produced the "Attempting to read a value after
    /// it has been invalidated" flood and the real freeze/crash reported from a loaded account
    /// (not reproducible on a fresh/empty one, which never has enough to be mid-computation when a
    /// rollback lands). `RootView` checks this flag and skips its own immediate rollback while
    /// it's true; `runOneSyncPass` does exactly one rollback itself once the whole pass finishes,
    /// so the UI still ends up fresh — just from one rollback at a well-defined boundary instead of
    /// up to six at unpredictable moments mid-pass. A genuinely different process's write (widget/
    /// Shortcuts) is untouched by this — it arrives while this flag is false and still rolls back
    /// immediately, exactly as before.
    private(set) var isSyncPassInProgress = false
    /// Phase 4G.3B — set by `handleDidSave` whenever a genuine local save touches a syncable
    /// model; cleared only when a sync pass actually completes all six steps successfully (never
    /// on failure or on an outright skip, so changes that didn't really make it out aren't
    /// forgotten). Deliberately in-memory only — see `SyncLastSuccessStoring`'s own doc comment
    /// for why this is never persisted. Externally readable (Phase 6.1) so `AccountView` can tell,
    /// right before sign-out, whether a just-attempted flush sync actually cleared everything or
    /// left something unsynced — still only ever written from inside this class.
    private(set) var hasPendingLocalChanges = false

    init(
        syncService: SupabaseSyncService = .shared,
        sessionChecker: SyncCoordinatorSessionChecking = SupabaseAuthService.shared,
        lastSyncStore: SyncLastSuccessStoring = UserDefaultsSyncLastSuccessStore(),
        debounceInterval: Duration = .seconds(1.5),
        periodicSyncInterval: Duration = .seconds(600)
    ) {
        self.syncService = syncService
        self.sessionChecker = sessionChecker
        self.lastSyncStore = lastSyncStore
        self.debounceInterval = debounceInterval
        self.periodicSyncInterval = periodicSyncInterval
    }

    // MARK: - Phase 6.1: local store wipe on a detected user switch

    /// Called by `LocalAccountTransition.establishOwnership` immediately after it wipes the local
    /// store for a newly-authenticated user that doesn't match the store's previous owner.
    /// Without this, a stale `lastSuccessfulSync` could make the next `handleAppBecameActive` call
    /// think a sync isn't needed yet even though the store was just emptied, and a stale
    /// `hasPendingLocalChanges` would still refer to the previous user's now-deleted data.
    func resetStateAfterLocalStoreWipe() {
        lastSyncStore.lastSuccessfulSync = nil
        hasPendingLocalChanges = false
        SyncDiagnosticLog.log("resetStateAfterLocalStoreWipe — cleared lastSuccessfulSync and hasPendingLocalChanges")
    }

    // MARK: - Trigger 1: app active / launch

    /// Called once when auth resolves to signed-in at launch, and again on every subsequent
    /// `scenePhase == .active` transition. Starts the periodic timer (idempotent — a no-op if
    /// one's already running) and requests a sync only if there's a real reason to: the last
    /// successful sync is stale, or a local change happened since then that hasn't gone out yet.
    /// Reactivating well within the freshness window with nothing pending is a deliberate no-op.
    func handleAppBecameActive(modelContext: ModelContext) {
        SyncDiagnosticLog.log("handleAppBecameActive — hasPendingLocalChanges=\(hasPendingLocalChanges)")
        startPeriodicSyncIfNeeded(modelContext: modelContext)
        guard hasPendingLocalChanges || isLastSuccessfulSyncStale() else {
            SyncDiagnosticLog.log("handleAppBecameActive — skipped: last sync is recent and nothing is pending")
            return
        }
        scheduleSync(modelContext: modelContext)
    }

    /// Stops the periodic timer — called on `scenePhase == .background`. The timer only exists to
    /// tick while the app is actually active; there is nothing to pause/resume, just start again
    /// on the next `handleAppBecameActive`.
    func handleAppDidEnterBackground() {
        SyncDiagnosticLog.log("handleAppDidEnterBackground — stopping periodic sync")
        periodicSyncTask?.cancel()
        periodicSyncTask = nil
    }

    private func isLastSuccessfulSyncStale() -> Bool {
        guard let last = lastSyncStore.lastSuccessfulSync else {
            // Never synced before — the very first authenticated activation must still be able
            // to sync, so "no record yet" counts as stale, not fresh.
            return true
        }
        return Date.now.timeIntervalSince(last) >= periodicSyncInterval.timeInterval
    }

    // MARK: - Trigger 2: pull-to-refresh

    /// `DataSyncService.refresh(_:)` (the shared `.refreshable` handler every tab's root scroll
    /// view already uses) calls this. Always requests a sync — no staleness check — and only
    /// returns once a real sync pass (including any coalesced extra pass picked up along the
    /// way) has actually finished, so the pull-to-refresh spinner stays up for exactly as long as
    /// a sync is genuinely in flight, never dismissing early.
    func refresh(modelContext: ModelContext) async {
        SyncDiagnosticLog.log("refresh — pull-to-refresh requested, always syncs")
        await ensureSyncRunning(modelContext: modelContext).value
    }

    // MARK: - Trigger 3: periodic

    private func startPeriodicSyncIfNeeded(modelContext: ModelContext) {
        guard periodicSyncTask == nil else { return }
        SyncDiagnosticLog.log("startPeriodicSyncIfNeeded — starting periodic timer (\(periodicSyncInterval))")
        periodicSyncTask = Task { [weak self, periodicSyncInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: periodicSyncInterval)
                guard !Task.isCancelled, let self else { break }
                SyncDiagnosticLog.log("periodic sync tick — requesting a sync")
                self.scheduleSync(modelContext: modelContext)
            }
        }
    }

    /// A cross-process write (widget/Siri/Shortcuts, landing in the shared App Group store from a
    /// different process's own `ModelContext`) is treated exactly like a local save (Phase
    /// 4G.3B) — it marks pending local changes rather than scheduling an immediate sync, for the
    /// same "don't sync on every save" reason `handleDidSave` does. `RootView` still calls
    /// `modelContext.rollback()` itself right before this, so the UI picks up that write
    /// immediately regardless of whether/when the next real sync trigger fires.
    ///
    /// Phase 4G.6 — ignored while `isApplyingPullChanges` is true, exactly like `handleDidSave`
    /// already ignores a pull step's own `ModelContext.didSave`. A pull step's own
    /// `modelContext.save()` can post `NSPersistentStoreRemoteChangeNotification` too (persistent
    /// history tracking, which the shared App Group store needs for the widget/Siri/Shortcuts to
    /// see this app's writes, notifies every observer of a committed change, not only ones in a
    /// different process) — without this guard, every sync pass that pulled anything would
    /// immediately mark itself as having "pending local changes" again right after successfully
    /// clearing that same flag, from data the pass itself just pulled, not a genuine external
    /// write.
    func handleCrossProcessChange() {
        guard !isApplyingPullChanges else {
            SyncDiagnosticLog.log("handleCrossProcessChange — ignored: caused by this sync's own pull step, not a genuine cross-process change")
            return
        }
        SyncDiagnosticLog.log("handleCrossProcessChange — marking pending local changes")
        hasPendingLocalChanges = true
    }

    // MARK: - Trigger 4: local changes

    /// `RootView`'s `ModelContext.didSave` observer calls this with the notification exactly as
    /// received — filtering to only the five syncable model types happens here, not in
    /// `RootView`, so `RootView` itself needs no knowledge of which models are sync-relevant.
    ///
    /// Phase 4G.3B — this no longer schedules a network sync at all. A local SwiftData save must
    /// update the UI immediately regardless of network state, and did already (SwiftData itself
    /// handled that before this notification even fired) — all this does now is remember that
    /// there's something worth syncing next time a real trigger fires, so several saves in a row
    /// collapse into the same one eventual upload rather than each kicking off its own.
    ///
    /// Ignored outright while `isApplyingPullChanges` is true (Phase 4G.3A/4G.3B): a pull step's
    /// own `modelContext.save()` posts this exact notification — indistinguishable from a user's
    /// own save by content — and marking "pending local changes" because of data that was *just
    /// pulled in* would be wrong; it isn't a local change awaiting upload.
    func handleDidSave(_ notification: Notification, modelContext: ModelContext) {
        guard !isApplyingPullChanges else {
            SyncDiagnosticLog.log("handleDidSave — ignored: caused by this sync's own pull step, not a user change")
            return
        }
        let matched = touchesSyncableModel(notification)
        SyncDiagnosticLog.log("handleDidSave — touchesSyncableModel=\(matched)")
        guard matched else { return }
        SyncDiagnosticLog.log("handleDidSave — marking pending local changes")
        hasPendingLocalChanges = true
    }

    // MARK: - Shared scheduling / coalescing

    /// The debounced path app-active and periodic triggers use — cancelling any already-pending
    /// debounce before scheduling a new one is what coalesces a burst of triggers landing close
    /// together (e.g. the app becoming active right as the periodic timer also ticks) into one
    /// eventual sync rather than one per trigger. Not `private` so tests can simulate any of
    /// those triggers directly, exactly as they already did before Phase 4G.3B.
    func scheduleSync(modelContext: ModelContext) {
        SyncDiagnosticLog.log("scheduleSync called — cancelling any pending debounce and scheduling a new one (\(debounceInterval))")
        debounceTask?.cancel()
        debounceTask = Task { [debounceInterval] in
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else {
                SyncDiagnosticLog.log("debounce Task was cancelled before firing — likely superseded by a later scheduleSync call")
                return
            }
            SyncDiagnosticLog.log("debounce elapsed — proceeding to ensureSyncRunning")
            self.debounceTask = nil
            await self.ensureSyncRunning(modelContext: modelContext).value
        }
    }

    /// Test-only hook: awaits whatever debounce-then-sync `Task` is currently in flight, if any,
    /// so a test can assert on post-sync state deterministically instead of guessing a sleep
    /// duration. Harmless left in production — it does nothing but await work that was already
    /// scheduled.
    func waitForPendingWork() async {
        await debounceTask?.value
    }

    /// Phase 4H — this runs on *every* `ModelContext.didSave` in the app (every entry/wallet/
    /// category edit, not only during a sync pass), so the per-key breakdown this used to build
    /// for `SyncDiagnosticLog` (an `entityNames` array via `identifiers.map(\.entityName)`) was
    /// real, unconditional work on every single save in every build configuration — `SyncDiagnosticLog.log`
    /// itself is a DEBUG-only no-op in Release, but that array was computed as a plain `let`
    /// *before* the (possibly-elided) log call, not inside its `@autoclosure`, so Release builds
    /// paid for it too. Removed along with the rest of that per-key diagnostic — the one-line
    /// "touchesSyncableModel=..." result log at `handleDidSave`'s own call site already covers
    /// what matters day to day; this was debugging detail from the original Phase 4G investigation
    /// into why automatic sync didn't appear to trigger, which is resolved.
    private func touchesSyncableModel(_ notification: Notification) -> Bool {
        guard let userInfo = notification.userInfo else {
            return false
        }
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        for key in keys {
            guard let identifiers = userInfo[key.rawValue] as? [PersistentIdentifier] else {
                continue
            }
            if identifiers.contains(where: { Self.syncableEntityNames.contains($0.entityName) }) {
                return true
            }
        }
        return false
    }

    /// The one place every trigger (app-active, periodic, pull-to-refresh) ultimately reaches.
    /// `isSyncing` is set *synchronously*, in this same call, the instant a new pass is decided
    /// on — never inside the `Task` it creates — specifically so there is no window between "we
    /// decided to start" and "we marked ourselves as syncing" for a second, concurrent call to
    /// slip through and start its own overlapping pass. If a sync is already running, the trigger
    /// is never dropped: it's recorded in `pendingResyncModelContext`, and the *already-running*
    /// task picks it up and runs exactly one additional pass right after its own finishes, before
    /// releasing `isSyncing` — a hard two-pass cap (not a loop), which is what rules out an
    /// unbounded chain (a trigger arriving during that one bonus pass is recorded the same way,
    /// but is left for the *next* call to `ensureSyncRunning` to pick up, exactly like any
    /// ordinary post-sync trigger already does).
    @discardableResult
    private func ensureSyncRunning(modelContext: ModelContext) -> Task<Void, Never> {
        if isSyncing {
            SyncDiagnosticLog.log("ensureSyncRunning — a sync is already in progress, recording a pending rerun instead of dropping this trigger")
            Self.logger.log("Automatic sync already in progress — coalescing this trigger into one more pass after it finishes")
            pendingResyncModelContext = modelContext
            if let activeSyncTask { return activeSyncTask }
        }
        isSyncing = true
        let task = Task { [weak self] in
            defer { self?.isSyncing = false }
            guard let self else { return }
            await self.runOneSyncPass(modelContext: modelContext)
            if let rerunContext = self.pendingResyncModelContext {
                self.pendingResyncModelContext = nil
                SyncDiagnosticLog.log("ensureSyncRunning — running one coalesced extra pass for a trigger that arrived mid-sync")
                await self.runOneSyncPass(modelContext: rerunContext)
            }
        }
        activeSyncTask = task
        return task
    }

    /// One actual pull-then-push cycle, strictly in the documented six-step order (Phase 4F): pull
    /// reference data, pull budgets, pull entries, push reference data, push budgets, push
    /// entries. Every pull runs to completion before any push starts — pulling remote state in
    /// isn't safe to skip ahead of pushing local state out, since push is what mints `remoteID`s a
    /// later pull depends on to merge correctly. Within each half, the Category → Budget/Entry
    /// dependency order is preserved (budgets/entries each reference a Category by remote id,
    /// exactly like `syncReferenceData`'s own internal HeadCategory → Category → Wallet ordering)
    /// — this is also why entries are pulled only after reference data and budgets have already
    /// landed locally: `pullEntries` resolves each entry's wallet/category purely against
    /// whatever's already in the local store, and neither pull method ever calls another pull
    /// method itself (each is a single, independent network round trip; sequencing across all six
    /// steps is `ensureSyncRunning`'s job alone). A failure at any one of the six steps throws
    /// immediately — Swift's `try` chain guarantees nothing after it runs, so a failed pull step
    /// never reaches push, and a failed push step never reaches a later push step.
    ///
    /// `userID` is resolved exactly once here (Phase 4G.3A, via `syncService.requireUserID()`)
    /// and passed into every one of the six calls, instead of each one re-resolving it
    /// independently. `lastSuccessfulSync`/`hasPendingLocalChanges` (Phase 4G.3B) are only ever
    /// touched after every one of the six steps has actually succeeded — a skip (no session) or a
    /// failure partway through leaves both exactly as they were, so a later trigger tries again.
    private func runOneSyncPass(modelContext: ModelContext) async {
        let hasSession = await sessionChecker.hasActiveSession()
        SyncDiagnosticLog.log("runOneSyncPass — hasActiveSession=\(hasSession)")
        guard hasSession else {
            Self.logger.log("Automatic sync skipped — no active Supabase session")
            SyncDiagnosticLog.log("runOneSyncPass aborted — no active Supabase session")
            return
        }

        // Phase 4H — total-pass timing. Only started once a pass is actually attempted (not on
        // the no-session skip above, which is instant and not a "sync" worth timing). `defer`
        // means this logs on every exit path, success or failure alike, exactly like the one it
        // replaces logged on success alone — a failed pass's partial duration is still useful for
        // diagnosing which attempt was slow right before it failed.
        let passStart = ContinuousClock.now
        isSyncPassInProgress = true
        defer {
            isSyncPassInProgress = false
            // The one rollback this whole pass's writes get — see `isSyncPassInProgress`'s own
            // doc comment for why this replaces up to six intermediate ones `RootView` would
            // otherwise have done mid-pass. Runs on success *and* failure (whatever steps did
            // complete before a throw still wrote through `BackgroundSyncExecutor`'s own context
            // and deserve to be visible), and unconditionally — there's no cheap way to know
            // whether anything actually changed, and an extra rollback with nothing to pick up is
            // harmless, unlike landing one mid-render.
            modelContext.rollback()
            SyncDiagnosticLog.log("runOneSyncPass — total duration \(ContinuousClock.now - passStart)")
        }

        do {
            let userID = try await syncService.requireUserID()
            // Runs every step against its own private, off-Main-Actor context instead of the
            // main one `modelContext` points at — see `BackgroundSyncExecutor`'s doc comment for
            // why this is what actually stops a sync pass from freezing the UI, and how the main
            // context still ends up with everything this writes.
            let executor = BackgroundSyncExecutor(modelContainer: modelContext.container)

            try await timedStep("pullReferenceData") {
                try await withPullInducedSaveSuppression {
                    try await executor.pullReferenceData(syncService: syncService, userID: userID)
                }
            }
            try await timedStep("pullBudgets") {
                try await withPullInducedSaveSuppression {
                    try await executor.pullBudgets(syncService: syncService, userID: userID)
                }
            }
            try await timedStep("pullEntries") {
                try await withPullInducedSaveSuppression {
                    try await executor.pullEntries(syncService: syncService, userID: userID)
                }
            }
            try await timedStep("syncReferenceData") {
                try await executor.syncReferenceData(syncService: syncService, userID: userID)
            }
            try await timedStep("syncBudgets") {
                try await executor.syncBudgets(syncService: syncService, userID: userID)
            }
            try await timedStep("syncEntries") {
                try await executor.syncEntries(syncService: syncService, userID: userID)
            }

            lastSyncStore.lastSuccessfulSync = .now
            hasPendingLocalChanges = false
            Self.logger.log("Automatic sync completed")
        } catch {
            // Best-effort by design — never surfaced to the UI and never retried on a timer. The
            // local save that triggered this already succeeded; only the outbound sync failed. A
            // failure at any pull or push step lands here identically — no step after it runs,
            // since `try` already stops the chain at whichever call threw. `lastSuccessfulSync`
            // and `hasPendingLocalChanges` are deliberately left untouched: whatever didn't make
            // it out is still pending, and this was not a successful sync.
            Self.logger.error("Automatic sync failed, will retry on next trigger: \(String(describing: error), privacy: .public)")
            SyncDiagnosticLog.log("runOneSyncPass — FAILED with error: \(error)")
        }
    }

    /// Phase 4H — wraps one of the six steps with start/duration logging, replacing the previous
    /// "X completed, starting Y" breadcrumbs with an actual number for each step (plus the total
    /// logged by `runOneSyncPass`'s own `defer`) — exactly what's needed to see where the
    /// previously-reported ~15s manual refresh actually goes, without adding any permanent
    /// analytics system (`SyncDiagnosticLog` is `#if DEBUG`-only and a no-op in Release, same as
    /// everywhere else it's used).
    private func timedStep<T>(_ label: String, _ operation: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        SyncDiagnosticLog.log("runOneSyncPass — starting \(label)")
        let result = try await operation()
        SyncDiagnosticLog.log("runOneSyncPass — \(label) finished in \(ContinuousClock.now - start)")
        return result
    }

    /// Brackets `operation` with `isApplyingPullChanges = true`, always restoring it to `false`
    /// afterward (including on throw) — see that property's own doc comment for what this is for.
    private func withPullInducedSaveSuppression(_ operation: () async throws -> Void) async rethrows {
        isApplyingPullChanges = true
        defer { isApplyingPullChanges = false }
        try await operation()
    }
}
