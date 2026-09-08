import Foundation

/// The single authoritative switch for CloudKit collaboration (Phases 1–6.1).
///
/// The current build targets Apple's free Personal Team, which cannot sign an app requesting the
/// iCloud/CloudKit capability at all — so this flag is `false` for now, and nothing that would
/// touch CloudKit (starting `CollaborationSyncService`, presenting "Share Event," accepting a
/// share, claiming a participant) may run while it is. None of the CloudKit collaboration
/// implementation itself was changed, removed, or redesigned to make this build possible — see
/// every file under `Services/Collaboration*`, `Services/CloudKit*`, and `Models/EventParticipant.swift`,
/// all still present and unmodified in behavior.
///
/// To reactivate CloudKit collaboration once enrolled in the Apple Developer Program:
/// 1. Flip `isEnabled` below to `true`.
/// 2. Point the app target's `CODE_SIGN_ENTITLEMENTS` build setting (currently
///    `FinanceTracker/FinanceTracker-LocalOnly.entitlements`) back to
///    `FinanceTracker/FinanceTracker.entitlements`, which already has the iCloud
///    capability keys and was never modified.
/// 3. In Xcode, select your paid Developer Program team in Signing & Capabilities, and confirm
///    the iCloud/CloudKit capability shows as configured (Xcode will register the
///    `iCloud.com.andreacorzo.FinanceTracker` container in the Developer Portal at that point).
///
/// No source file needs to change beyond this flag — everything else already checks it.
enum CollaborationFeatureFlag {
    static let isEnabled = false
}
