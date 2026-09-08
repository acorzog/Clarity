import Foundation
import CloudKit

/// Persists `CKSyncEngine`'s own state serialization across launches — this is CKSyncEngine's
/// bookkeeping (pending changes, server change tokens), not domain data, so it's kept as a
/// small JSON file in this app's own sandboxed Application Support directory rather than as a
/// SwiftData model or in the shared App Group store. Losing this file isn't destructive: worst
/// case, the next `fetchChanges()` re-derives everything from a fresh server state.
///
/// Phase 3 needs one such file per `CKDatabase.Scope`: this device runs two independent
/// `CKSyncEngine`s (one for its own private database, one for the shared database that holds
/// events other people have shared with it — see `CollaborationSyncService`), and each has its
/// own change tokens that must not be conflated with the other's.
enum CollaborationSyncStateStore {
    enum Scope: String {
        case owned
        case shared
    }

    private static func fileURL(for scope: Scope) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("CollaborationSyncEngineState-\(scope.rawValue).json")
    }

    static func load(for scope: Scope) -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: fileURL(for: scope)) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    static func save(_ serialization: CKSyncEngine.State.Serialization, for scope: Scope) {
        do {
            let url = fileURL(for: scope)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(serialization)
            try data.write(to: url, options: .atomic)
        } catch {
            CollaborationLog.error("Failed to persist sync engine state (\(scope.rawValue)): \(error.localizedDescription)")
        }
    }
}
