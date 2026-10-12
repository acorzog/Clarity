import Foundation
import SwiftData

/// Phase 6.1 — Local Account Isolation. The local SwiftData store is a single, shared store (see
/// `SharedModelContainer`, intentionally unchanged by this phase) with no per-row owner field —
/// before this phase, nothing noticed when the authenticated Supabase user changed, so switching
/// accounts on the same device silently mixed the previous user's local data into the new one's,
/// and automatic sync could then push the previous user's rows under the new user's id.
///
/// `decide` is pure and dependency-free so the rule itself is unit-testable without any
/// UserDefaults/ModelContext involved — see `LocalStoreOwnershipTests`.
enum LocalStoreOwnership {
    enum Decision: Equatable {
        /// No owner marker existed yet — either a pre-6.1 install (which already has one user's
        /// real data and must never be wiped just because it predates this feature) or a
        /// genuinely fresh one. Either way: adopt the signed-in user as the store's owner without
        /// touching any data.
        case adopt
        /// The store already belongs to this exact user — nothing to do.
        case alreadyOwner
        /// A different user is now authenticated than whoever the store currently belongs to —
        /// the store must be wiped before anything else (seeding, sync) touches it.
        case wipe
    }

    static func decide(storedOwnerID: UUID?, authenticatedUserID: UUID) -> Decision {
        guard let storedOwnerID else { return .adopt }
        return storedOwnerID == authenticatedUserID ? .alreadyOwner : .wipe
    }
}

/// Persists which Supabase user the local SwiftData store currently belongs to. App-Group-scoped
/// (same `UserDefaults` suite `UserDefaultsSyncLastSuccessStore` already uses) purely for
/// consistency with that one existing pattern for small non-SwiftData app state — the widget and
/// Intents don't read this today and this phase doesn't change that.
protocol LocalStoreOwnerStoring: AnyObject {
    var ownerUserID: UUID? { get set }
}

final class UserDefaultsLocalStoreOwnerStore: LocalStoreOwnerStoring {
    private let defaults: UserDefaults
    private static let key = "com.andreacorzo.FinanceTracker.localStoreOwnerUserID"

    init(defaults: UserDefaults = UserDefaults(suiteName: SharedModelContainer.appGroupID) ?? .standard) {
        self.defaults = defaults
    }

    var ownerUserID: UUID? {
        get {
            guard let raw = defaults.string(forKey: Self.key) else { return nil }
            return UUID(uuidString: raw)
        }
        set { defaults.set(newValue?.uuidString, forKey: Self.key) }
    }
}

/// The actual orchestration: given the just-authenticated user's id, applies `LocalStoreOwnership
/// .decide` and — on a genuine mismatch — wipes the local store (reusing the same
/// `LocalBackupService.eraseAllData` "Backup & Restore → Erase All Data" already uses) and resets
/// `SyncCoordinator`'s bookkeeping, before recording the new owner. Free-standing rather than a
/// `RootView` method so it's unit-testable without driving SwiftUI — see
/// `RootView.establishSignedIn`, the single call site every signed-in transition (launch, sign-in,
/// sign-up, password-recovery completion) is centralized through.
enum LocalAccountTransition {
    @MainActor
    static func establishOwnership(
        userID: UUID,
        modelContext: ModelContext,
        ownerStore: LocalStoreOwnerStoring,
        syncCoordinator: SyncCoordinator
    ) throws {
        let decision = LocalStoreOwnership.decide(storedOwnerID: ownerStore.ownerUserID, authenticatedUserID: userID)
        if decision == .wipe {
            try LocalBackupService.eraseAllData(in: modelContext)
            syncCoordinator.resetStateAfterLocalStoreWipe()
        }
        // Written last and unconditionally (including the `.alreadyOwner` no-op case, which is a
        // harmless re-write of the same value) — only ever reached once the wipe above has
        // already succeeded, so the marker can never point at a user whose wipe didn't complete.
        ownerStore.ownerUserID = userID
    }

    /// Phase 6.0.5 — called once the remote account is confirmed deleted, so there is no signed-in
    /// user left to "establish" ownership for. Always attempts the local wipe and always resets
    /// `SyncCoordinator`'s bookkeeping (signing out immediately after means no sync pass can run
    /// anyway), but only clears the owner marker on a *successful* wipe. If `eraseAllData` throws,
    /// the marker is deliberately left pointing at the now-deleted user's id — `LocalStoreOwnership
    /// .decide` then forces a `.wipe` the next time any user (including a different one) signs in
    /// on this device, rather than letting this leftover data become visible to them.
    @MainActor
    static func wipeAfterAccountDeletion(
        modelContext: ModelContext,
        ownerStore: LocalStoreOwnerStoring,
        syncCoordinator: SyncCoordinator,
        erase: (ModelContext) throws -> Void = LocalBackupService.eraseAllData
    ) {
        do {
            try erase(modelContext)
            ownerStore.ownerUserID = nil
        } catch {
            // Left as-is on purpose — see doc comment above.
        }
        syncCoordinator.resetStateAfterLocalStoreWipe()
    }
}
