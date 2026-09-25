import Foundation
import SwiftData

/// The SwiftData store lives in the shared App Group container so both the main
/// app and the widget extension (a separate process) read and write the same data.
enum SharedModelContainer {
    /// Derived from the running bundle rather than hardcoded, so this same source file — shared
    /// by every app target (FinanceTracker, FinanceTrackerDev) and the widget extension — resolves
    /// to each target's own App Group instead of always pointing at the production one. A widget
    /// extension's bundle ID is always its host app's plus ".Widgets", so that suffix is stripped
    /// to recover the host app's ID before prefixing "group.".
    static var appGroupID: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.andreacorzo.FinanceTracker"
        let hostAppBundleID = bundleID.hasSuffix(".Widgets") ? String(bundleID.dropLast(".Widgets".count)) : bundleID
        return "group.\(hostAppBundleID)"
    }

    static let schema = Schema([
        HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self, SpendingInsight.self,
        Person.self, SharedEvent.self, SharedExpense.self, SharedExpenseParticipant.self, Settlement.self,
        EventParticipant.self, Goal.self, GoalContribution.self
    ])

    static func make() -> ModelContainer {
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            fatalError("App Group container unavailable — check the \(appGroupID) entitlement.")
        }
        let storeURL = groupURL.appendingPathComponent("FinanceTracker.sqlite")
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create shared ModelContainer: \(error)")
        }
    }

    /// Deletes the on-disk store (and its `-wal`/`-shm` sidecar files) before `make()` creates the
    /// container — called from `FinanceTrackerApp.init()` only when launched with the
    /// `-uiTestReset` argument (`FinanceTrackerUITests/UITestSupport.swift`), so every UI test run
    /// starts from `SeedData`'s clean default categories/wallet instead of accumulating whatever
    /// wallets/transactions a previous run left behind. Never runs in a normal launch — the
    /// argument is only ever set by the UI test bundle itself — so this can't touch a real
    /// device's actual data.
    static func resetStoreForUITesting() {
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        let storeURL = groupURL.appendingPathComponent("FinanceTracker.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
    }
}
