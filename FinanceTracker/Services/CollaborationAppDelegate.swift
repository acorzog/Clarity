import UIKit
import CloudKit

/// The one piece of UIKit app-lifecycle plumbing collaboration needs: CloudKit only hands a
/// recipient their incoming `CKShare.Metadata` through this delegate callback when they tap a
/// share invitation, so a pure-SwiftUI `App` needs at least this much of an `UIApplicationDelegate`
/// to receive it. Everything else about accepting a share lives in
/// `CollaborationSyncService.acceptShare(metadata:)`; this type only forwards the callback.
@MainActor
final class CollaborationAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        true
    }

    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        guard let service = CollaborationSyncService.shared else {
            CollaborationLog.error("Received a share invitation before collaboration sync was configured")
            return
        }
        Task {
            await service.acceptShare(metadata: cloudKitShareMetadata)
        }
    }
}
