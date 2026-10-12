import SwiftData
import WidgetKit

/// Backs the pull-to-refresh spinner on every tab's root scroll view — a manual, user-triggered
/// version of `RootView`'s automatic foreground-transition sync. Widget/Siri/Shortcut writes land
/// in a separate process's `ModelContext`, so this app's own context can sit stale until nudged;
/// `RootView` already does that nudge on every foreground transition, but a user who stays inside
/// the app (e.g. logs something via a Shortcut without switching away) has had no way to ask for
/// that pickup on demand until now.
///
/// `save()` runs first specifically so this can never be the thing that loses data: `rollback()`
/// discards any *unsaved* local change, exactly the hazard already documented on `PlanView.
/// setAmount` and `AddTransactionView.save()`. Saving first means there's nothing left for the
/// rollback to discard — it only refreshes stale reads, never drops a pending edit.
///
/// Phase 4G.3B — this is sync trigger 2 (pull-to-refresh): `SyncCoordinator.shared.refresh(
/// modelContext:)` always requests a real Supabase sync, unconditionally (unlike the other three
/// triggers, which are gated), and this function doesn't return until that sync (including any
/// coalesced extra pass) has actually finished — so every `.refreshable` spinner already wired to
/// this stays up for exactly as long as a real sync is in flight, not a fixed guess.
enum DataSyncService {
    @MainActor
    static func refresh(_ modelContext: ModelContext) async {
        try? modelContext.save()
        modelContext.rollback()
        WidgetCenter.shared.reloadAllTimelines()
        await SyncCoordinator.shared.refresh(modelContext: modelContext)
        // `save()`/`rollback()`/a skipped-or-instant sync are all effectively instant, which
        // would make the spinner flash too briefly to register as "it did something" — this
        // floor just keeps it visible long enough to read as real feedback, not a UI glitch. A
        // genuine network sync will usually already exceed this on its own.
        try? await Task.sleep(for: .milliseconds(400))
    }
}
