import Foundation
import SwiftData
@testable import FinanceTracker

/// A fresh in-memory ModelContainer/ModelContext pair — never touches the real (app group) store.
enum TestSupport {
    static func makeInMemoryContext() -> ModelContext {
        let schema = Schema([
            HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self, SpendingInsight.self,
            Person.self, SharedEvent.self, SharedExpense.self, SharedExpenseParticipant.self, Settlement.self,
            EventParticipant.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    static func makeWallet(
        name: String = "Wallet",
        type: WalletType = .spending,
        startingBalance: Decimal = 0,
        isDefault: Bool = false,
        isArchived: Bool = false
    ) -> Wallet {
        Wallet(
            name: name,
            type: type,
            colorHex: "#FFFFFF",
            icon: "wallet.bifold",
            startingBalance: startingBalance,
            isDefault: isDefault,
            isArchived: isArchived
        )
    }
}
