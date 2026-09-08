import SwiftUI
import CloudKit

/// Bridges Apple's native `UICloudSharingController` into SwiftUI. Deliberately just a bridge:
/// it knows nothing about `SharedEvent`/SwiftData — it's handed an already-created `CKShare`,
/// the container that owns it, and a plain title string, and its only job is presenting Apple's
/// stock collaboration UI and forwarding its delegate callbacks to `CollaborationLog`. Keeping
/// UIKit sharing concerns out of the domain models is deliberate (see the Phase 3 spec).
struct CloudSharingControllerRepresentable: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    let eventTitle: String
    var onStopSharing: (() -> Void)?

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        // Trust-based, private-invite-only model for V1 (rule 6): no public link sharing, and
        // members get write access consistent with the app's existing shared-expense semantics.
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(eventTitle: eventTitle, onStopSharing: onStopSharing)
    }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        private let eventTitle: String
        private let onStopSharing: (() -> Void)?

        init(eventTitle: String, onStopSharing: (() -> Void)?) {
            self.eventTitle = eventTitle
            self.onStopSharing = onStopSharing
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            eventTitle
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            CollaborationLog.error("UICloudSharingController failed to save share: \(error.localizedDescription)")
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            CollaborationLog.log("Share saved via native sharing UI")
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            CollaborationLog.log("Sharing stopped via native sharing UI")
            onStopSharing?()
        }
    }
}
