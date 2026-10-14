import Foundation
import SwiftData

/// Runs each step of a Supabase sync pass against its own private `ModelContext`, entirely off
/// the Main Actor — `@ModelActor` gives this its own background executor and context, isolated
/// from (and never touching) the main-thread context `RootView`'s `@Query` views observe.
///
/// Before this existed, `SyncCoordinator` called `SupabaseSyncService`'s six steps directly
/// against the main context, so every fetch/insert/save in a sync pass — and the `@Query`
/// recomputation each of those six `save()`s triggers across Home/Remaining/Overview — ran
/// synchronously on the Main Actor, freezing the UI for the pass's full duration. `SyncCoordinator`
/// now routes each step through an instance of this actor instead; the main context picks up
/// whatever gets written here via the same `.NSPersistentStoreRemoteChange` notification +
/// `modelContext.rollback()` path `RootView` already uses for cross-process writes from the widget/
/// Shortcuts — a same-process, different-context save against the same store posts that identical
/// notification, so no new plumbing was needed to keep the UI current.
///
/// One instance is created per sync pass (in `SyncCoordinator.runOneSyncPass`) rather than reused
/// across passes, so each pass starts from a fresh context with no risk of carrying stale state
/// from a previous one.
@ModelActor
actor BackgroundSyncExecutor {
    func pullReferenceData(syncService: SupabaseSyncService, userID: UUID) async throws {
        try await syncService.pullReferenceData(modelContext: modelContext, userID: userID)
    }

    func pullBudgets(syncService: SupabaseSyncService, userID: UUID) async throws {
        try await syncService.pullBudgets(modelContext: modelContext, userID: userID)
    }

    func pullEntries(syncService: SupabaseSyncService, userID: UUID) async throws {
        try await syncService.pullEntries(modelContext: modelContext, userID: userID)
    }

    func syncReferenceData(syncService: SupabaseSyncService, userID: UUID) async throws {
        try await syncService.syncReferenceData(modelContext: modelContext, userID: userID)
    }

    func syncBudgets(syncService: SupabaseSyncService, userID: UUID) async throws {
        try await syncService.syncBudgets(modelContext: modelContext, userID: userID)
    }

    func syncEntries(syncService: SupabaseSyncService, userID: UUID) async throws {
        try await syncService.syncEntries(modelContext: modelContext, userID: userID)
    }
}
