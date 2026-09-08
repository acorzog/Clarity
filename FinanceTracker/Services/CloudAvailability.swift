import Foundation
import CloudKit

/// Whether this device can currently participate in Shared Expenses collaboration via iCloud.
/// Deliberately small — just enough for the sync layer (and, later, UI) to decide whether to
/// attempt a sync or leave collaborative events exactly as they last were locally. Local Shared
/// Expenses usage never depends on this: it only gates collaboration, never the feature itself.
enum CloudAvailabilityState: Equatable {
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine
    /// Carries `error.localizedDescription` rather than the `Error` itself so this stays
    /// `Equatable`, which is all callers need (compare against `.available`, branch on cases).
    case error(String)
}

/// Watches iCloud account availability for the collaboration feature only. Never crashes and
/// never blocks: local Shared Expenses usage is unaffected by whatever this reports.
@MainActor
final class CloudAvailabilityMonitor: ObservableObject {
    @Published private(set) var state: CloudAvailabilityState = .couldNotDetermine

    private let container: CKContainer
    private var accountChangeObserver: NSObjectProtocol?

    init(container: CKContainer) {
        self.container = container
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    deinit {
        if let accountChangeObserver {
            NotificationCenter.default.removeObserver(accountChangeObserver)
        }
    }

    func refresh() async {
        do {
            let status = try await container.accountStatus()
            state = Self.map(status)
            CollaborationLog.log("iCloud account status: \(String(describing: status))")
        } catch {
            state = .error(error.localizedDescription)
            CollaborationLog.error("Failed to read iCloud account status: \(error.localizedDescription)")
        }
    }

    /// Pure mapping, exposed for testing without any network/account dependency.
    static func map(_ status: CKAccountStatus) -> CloudAvailabilityState {
        switch status {
        case .available: return .available
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .temporarilyUnavailable: return .temporarilyUnavailable
        case .couldNotDetermine: return .couldNotDetermine
        @unknown default: return .couldNotDetermine
        }
    }
}
