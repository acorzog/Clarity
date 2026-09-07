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
        let selfEmployed = HeadCategory(name: "Autónomo", icon: "briefcase.fill", colorHex: "#EF4444", sortOrder: 5)
        let entertainment = HeadCategory(name: "Entertainment", icon: "gamecontroller.fill", colorHex: "#EC4899", sortOrder: 6)
        let health = HeadCategory(name: "Health", icon: "cross.case.fill", colorHex: "#0EA5E9", sortOrder: 7)
        let travelling = HeadCategory(name: "Travelling", icon: "airplane", colorHex: "#6366F1", sortOrder: 8)
        let outcomes = HeadCategory(name: "Outcomes", icon: "arrow.left.arrow.right", colorHex: "#84CC16", sortOrder: 9)

        let allHeadCategories = [
            income, housing, food, subscriptions, transportation, miscellaneous,
            selfEmployed, entertainment, health, travelling, outcomes
        ]
        for headCategory in allHeadCategories {
            context.insert(headCategory)
        }

        // Every category gets its own icon — sharing one icon across several categories under
        // the same head (e.g. every Income row using a banknote) makes them indistinguishable
        // at a glance, so each row here maps to a visually distinct SF Symbol.
        let categorySeeds: [(name: String, icon: String, isSavings: Bool, isIncome: Bool, headCategory: HeadCategory)] = [
            // Income
            ("Salary", "banknote.fill", false, true, income),
            ("Freelance", "briefcase.fill", false, true, income),
            ("Investments", "chart.line.uptrend.xyaxis", false, true, income),
            ("Bizum In", "arrow.down.circle.fill", false, true, income),
            ("Reimburse", "arrow.uturn.backward.circle.fill", false, true, income),
            ("Other Income", "dollarsign.circle.fill", false, true, income),

            // Housing
            ("Rent & Mortgage", "house.fill", false, false, housing),
            ("Utilities", "bolt.fill", false, false, housing),
            ("Internet", "wifi", false, false, housing),
            ("Phone", "iphone", false, false, housing),
            ("Water", "drop.fill", false, false, housing),
            ("Home Maintenance", "wrench.and.screwdriver.fill", false, false, housing),
            ("Cleaning", "sparkles", false, false, housing),
            ("Home Insurance", "shield.fill", false, false, housing),

            // Food & Drinks
            ("Groceries", "basket.fill", false, false, food),
            ("Restaurants", "fork.knife", false, false, food),
            ("Coffee & Snacks", "cup.and.saucer.fill", false, false, food),
            ("Drinks", "wineglass.fill", false, false, food),

            // Subscriptions
            ("Streaming", "play.rectangle.fill", false, false, subscriptions),
            ("Software", "square.grid.2x2.fill", false, false, subscriptions),
            ("AI Tools", "sparkles", false, false, subscriptions),
            ("Music", "music.note", false, false, subscriptions),
            ("Cloud Storage", "icloud.fill", false, false, subscriptions),
            ("Memberships", "arrow.clockwise.circle.fill", false, false, subscriptions),
            ("News", "newspaper.fill", false, false, subscriptions),
            ("VPN & Security", "lock.shield.fill", false, false, subscriptions),

            // Transportation
            ("Fuel", "fuelpump.fill", false, false, transportation),
            ("Public Transit", "bus.fill", false, false, transportation),
            ("Car Maintenance", "wrench.and.screwdriver.fill", false, false, transportation),
            ("Car Rental", "car.2.fill", false, false, transportation),
            ("Parking", "parkingsign.circle.fill", false, false, transportation),
            ("Train", "tram.fill", false, false, transportation),
            ("Taxi", "car.fill", false, false, transportation),

            // Miscellaneous
            ("Shopping", "cart.fill", false, false, miscellaneous),
            ("Savings & Investments", "banknote.fill", true, false, miscellaneous),
            ("Gifts & Donations", "gift.fill", false, false, miscellaneous),
            ("Fees & Charges", "percent", false, false, miscellaneous),
            ("Other", "questionmark.circle.fill", false, false, miscellaneous),

            // Autónomo
            ("Taxes", "percent", false, false, selfEmployed),
            ("VAT", "doc.text.fill", false, false, selfEmployed),
            ("Accountant", "person.crop.circle.fill", false, false, selfEmployed),
            ("Social Security", "building.columns.fill", false, false, selfEmployed),
            ("Liability Insurance", "shield.fill", false, false, selfEmployed),
            ("Health Insurance", "cross.case.fill", false, false, selfEmployed),
            ("Office & Equipment", "laptopcomputer", false, false, selfEmployed),

            // Entertainment
            ("Cinema", "film.fill", false, false, entertainment),
            ("Concerts & Events", "ticket.fill", false, false, entertainment),
            ("Games", "gamecontroller.fill", false, false, entertainment),
            ("Books & Education", "book.fill", false, false, entertainment),
            ("Sports", "figure.run", false, false, entertainment),
            ("Clothing", "tshirt.fill", false, false, entertainment),
            ("Beauty & Cosmetics", "paintpalette.fill", false, false, entertainment),
            ("Hairdresser", "scissors", false, false, entertainment),
            ("Nightlife", "moon.stars.fill", false, false, entertainment),

            // Health
            ("Doctor", "stethoscope", false, false, health),
            ("Dentist", "cross.case.fill", false, false, health),
            ("Pharmacy", "pills.fill", false, false, health),
            ("Supplements", "pill.fill", false, false, health),
            ("Glasses & Lenses", "eyeglasses", false, false, health),
            ("Gym", "figure.strengthtraining.traditional", false, false, health),
            ("Mental Health", "brain.head.profile", false, false, health),

            // Travelling
            ("Flights", "airplane", false, false, travelling),
            ("Hotel", "bed.double.fill", false, false, travelling),
            ("Trip Food", "fork.knife", false, false, travelling),
            ("Trip Drinks", "wineglass.fill", false, false, travelling),
            ("Activities", "figure.walk", false, false, travelling),
            ("Attractions", "binoculars.fill", false, false, travelling),
            ("Souvenirs", "gift.fill", false, false, travelling),
            ("Local Transportation", "tram.fill", false, false, travelling),

            // Outcomes
            ("Cash Withdrawal", "banknote.fill", false, false, outcomes),
            ("Bizum Out", "arrow.up.circle.fill", false, false, outcomes),
            ("Bank Transfer", "arrow.left.arrow.right", false, false, outcomes),
            ("International", "globe", false, false, outcomes)
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
