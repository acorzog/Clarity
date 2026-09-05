import Foundation
import SwiftData

enum SeedData {
    static func seedIfNeeded(context: ModelContext) {
        let headCategoryCount = (try? context.fetchCount(FetchDescriptor<HeadCategory>())) ?? 0
        guard headCategoryCount == 0 else { return }

        let income = HeadCategory(name: "Income", icon: "banknote.fill", colorHex: "#14B8A6", sortOrder: -1)
        let housing = HeadCategory(name: "Housing", icon: "house.fill", colorHex: "#F59E0B", sortOrder: 0)
        let food = HeadCategory(name: "Food & Drinks", icon: "fork.knife", colorHex: "#F97316", sortOrder: 1)
        let subscriptions = HeadCategory(name: "Subscriptions", icon: "arrow.clockwise.circle.fill", colorHex: "#8B5CF6", sortOrder: 2)
        let transportation = HeadCategory(name: "Transportation", icon: "car.fill", colorHex: "#3B82F6", sortOrder: 3)
        let miscellaneous = HeadCategory(name: "Miscellaneous", icon: "square.grid.2x2.fill", colorHex: "#6B7280", sortOrder: 4)

        for headCategory in [income, housing, food, subscriptions, transportation, miscellaneous] {
            context.insert(headCategory)
        }

        let categorySeeds: [(name: String, icon: String?, isSavings: Bool, isIncome: Bool, headCategory: HeadCategory)] = [
            ("Salary", nil, false, true, income),
            ("Freelance", nil, false, true, income),
            ("Investments", nil, false, true, income),
            ("Other Income", nil, false, true, income),

            ("Rent & Mortgage", nil, false, false, housing),
            ("Utilities", nil, false, false, housing),
            ("Home Maintenance", nil, false, false, housing),

            ("Groceries", nil, false, false, food),
            ("Restaurants", nil, false, false, food),
            ("Coffee & Snacks", nil, false, false, food),

            ("Streaming", nil, false, false, subscriptions),
            ("Software", nil, false, false, subscriptions),
            ("Memberships", nil, false, false, subscriptions),

            ("Fuel", nil, false, false, transportation),
            ("Public Transit", nil, false, false, transportation),
            ("Car Maintenance", nil, false, false, transportation),

            ("Shopping", nil, false, false, miscellaneous),
            ("Health", nil, false, false, miscellaneous),
            ("Entertainment", nil, false, false, miscellaneous),
            ("Savings & Investments", "banknote.fill", true, false, miscellaneous),
            ("Other", nil, false, false, miscellaneous)
        ]

        for seed in categorySeeds {
            context.insert(
                Category(
                    name: seed.name,
                    customIcon: seed.icon,
                    isSavings: seed.isSavings,
                    isIncome: seed.isIncome,
                    headCategory: seed.headCategory
                )
            )
        }

        let spendingWallet = Wallet(
            name: "Spending",
            type: .spending,
            colorHex: "#10B981",
            icon: "creditcard.fill",
            startingBalance: 0,
            isDefault: true
        )
        context.insert(spendingWallet)
    }
}
