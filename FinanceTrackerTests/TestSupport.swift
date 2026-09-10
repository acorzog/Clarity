import Foundation
import SwiftData
@testable import FinanceTracker

/// A fresh in-memory ModelContainer/ModelContext pair — never touches the real (app group) store.
enum TestSupport {
    static func makeInMemoryContext() -> ModelContext {
        let schema = Schema([
            HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self, SpendingInsight.self,
            Person.self, SharedEvent.self, SharedExpense.self, SharedExpenseParticipant.self, Settlement.self,
            EventParticipant.self, Goal.self, GoalContribution.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    static func makeWallet(
        name: String = "Wallet",
        type: WalletType = .spending,
        startingBalance: Decimal = 0,
        includeInNetWorth: Bool = true,
        isDefault: Bool = false,
        isArchived: Bool = false
    ) -> Wallet {
        Wallet(
            name: name,
            type: type,
            colorHex: "#FFFFFF",
            icon: "wallet.bifold",
            startingBalance: startingBalance,
            includeInNetWorth: includeInNetWorth,
            isDefault: isDefault,
            isArchived: isArchived
        )
    }

    static func makeHeadCategory(name: String = "Head", colorHex: String = "#FFFFFF", sortOrder: Int = 0) -> HeadCategory {
        HeadCategory(name: name, icon: "folder.fill", colorHex: colorHex, sortOrder: sortOrder)
    }

    // `Category` is qualified as `FinanceTracker.Category` in type-annotation position below —
    // unqualified, it's ambiguous with the C typedef `Category` from <objc/runtime.h>
    // (`typedef struct objc_category *Category`), which the Clang importer also exposes at file
    // scope in this test target. Call-site usages (e.g. `Category(name:...)` elsewhere in this
    // test suite) aren't affected, since argument labels disambiguate there; only bare type
    // annotations are.
    static func makeCategory(
        name: String = "Category",
        isIncome: Bool = false,
        isArchived: Bool = false,
        headCategory: HeadCategory
    ) -> FinanceTracker.Category {
        FinanceTracker.Category(name: name, isArchived: isArchived, isIncome: isIncome, headCategory: headCategory)
    }

    static func makeBudget(
        category: FinanceTracker.Category,
        monthlyLimit: Decimal,
        month: Int,
        year: Int,
        isHidden: Bool = false
    ) -> Budget {
        Budget(category: category, monthlyLimit: monthlyLimit, month: month, year: year, isHidden: isHidden)
    }

    static func makeEntry(
        amount: Decimal,
        date: Date,
        type: EntryType,
        category: FinanceTracker.Category? = nil,
        wallet: Wallet,
        destinationWallet: Wallet? = nil,
        excludeFromBudget: Bool = false
    ) -> Entry {
        Entry(
            amount: amount,
            date: date,
            type: type,
            category: category,
            wallet: wallet,
            destinationWallet: destinationWallet,
            excludeFromBudget: excludeFromBudget
        )
    }

    static func makeGoal(
        name: String = "Goal",
        icon: String = "target",
        colorHex: String = "#FFFFFF",
        targetAmount: Decimal = 1000,
        createdAt: Date = .now,
        sortOrder: Int = 0,
        isArchived: Bool = false,
        targetDate: Date? = nil,
        contextWallet: Wallet? = nil
    ) -> Goal {
        Goal(
            name: name,
            icon: icon,
            colorHex: colorHex,
            targetAmount: targetAmount,
            createdAt: createdAt,
            sortOrder: sortOrder,
            isArchived: isArchived,
            targetDate: targetDate,
            contextWallet: contextWallet
        )
    }

    static func makeGoalContribution(
        amount: Decimal,
        date: Date = .now,
        goal: Goal,
        transaction: Entry? = nil,
        note: String? = nil
    ) -> GoalContribution {
        GoalContribution(amount: amount, date: date, goal: goal, transaction: transaction, note: note)
    }
}
