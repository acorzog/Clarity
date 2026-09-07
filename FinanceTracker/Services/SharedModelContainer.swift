import Foundation
import SwiftData

/// The SwiftData store lives in the shared App Group container so both the main
/// app and the widget extension (a separate process) read and write the same data.
enum SharedModelContainer {
    static let appGroupID = "group.com.andreacorzo.FinanceTracker"

    static let schema = Schema([
        HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self, SpendingInsight.self,
        Person.self, SharedEvent.self, SharedExpense.self, SharedExpenseParticipant.self, Settlement.self
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
}
