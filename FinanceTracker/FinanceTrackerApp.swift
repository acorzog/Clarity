import SwiftUI
import SwiftData

@main
struct FinanceTrackerApp: App {
    @UIApplicationDelegateAdaptor(CollaborationAppDelegate.self) private var collaborationAppDelegate

    private let container: ModelContainer

    init() {
        if ProcessInfo.processInfo.arguments.contains("-uiTestReset") {
            SharedModelContainer.resetStoreForUITesting()
            BudgetSettingsStore.resetForUITesting()
        }
        container = SharedModelContainer.make()
        SeedData.seedIfNeeded(context: container.mainContext)
        CategorizationService.modelContext = container.mainContext
        SpendingInsightsService.modelContext = container.mainContext
        // Gated by the single collaboration feature flag: while it's off (the current Personal
        // Team build), CollaborationSyncService.shared stays nil, so nothing anywhere in the app
        // constructs a CKContainer/CKSyncEngine or attempts any CloudKit network operation.
        // Everything that reaches for `.shared` already guards for nil and no-ops gracefully —
        // see CollaborationFeatureFlag's doc comment for exactly how to turn this back on.
        if CollaborationFeatureFlag.isEnabled {
            CollaborationSyncService.configureShared(modelContext: container.mainContext)
        }
        // So a transaction logged silently by a Shortcuts Automation (no app UI open) can still
        // confirm itself via a push notification — see `TransactionConfirmationNotifier`.
        TransactionConfirmationNotifier.requestAuthorizationIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
