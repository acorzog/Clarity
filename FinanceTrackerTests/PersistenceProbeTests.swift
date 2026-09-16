import XCTest
import SwiftData
@testable import FinanceTracker

/// Exercises the exact save → rollback → refetch pipeline the real app runs, against an on-disk
/// store (not in-memory) — including a full container reload to simulate an app relaunch —
/// which `BudgetQueryingFixedCarryForwardTests`' pure in-memory arrays can't cover. Written while
/// chasing a user report that a Fixed budget wasn't carrying forward; this passing is what
/// pointed at a stale build rather than a real persistence bug (see `PlanView.setFixed`'s
/// explicit `modelContext.save()`, added for the same report).
final class PersistenceProbeTests: XCTestCase {
    func testFixedSurvivesSaveRollbackAndFreshContext() throws {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID()).store")
        let schema = Schema([HeadCategory.self, FinanceTracker.Category.self, Budget.self])
        let config = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let head = HeadCategory(name: "Housing", icon: "house.fill", colorHex: "#FFFFFF")
        let rent = FinanceTracker.Category(name: "Rent", isIncome: false, headCategory: head)
        context.insert(head)
        context.insert(rent)

        let budget = Budget(category: rent, monthlyLimit: 1200, month: 9, year: 2026, isFixed: true)
        context.insert(budget)

        // Mirrors PlanView.setFixed's exact sequence.
        try context.save()
        context.rollback()

        // Re-fetch in the SAME context, as PlanView's @Query would after rollback.
        let refetched = try context.fetch(FetchDescriptor<Budget>())
        XCTAssertEqual(refetched.count, 1, "Budget row should survive save+rollback")
        XCTAssertEqual(refetched.first?.isFixed, true, "isFixed should survive save+rollback")
        XCTAssertEqual(refetched.first?.monthlyLimit, 1200)

        // Now simulate a fresh app launch: brand-new container/context from the SAME store file.
        let container2 = try ModelContainer(for: schema, configurations: [config])
        let context2 = ModelContext(container2)
        let reloaded = try context2.fetch(FetchDescriptor<Budget>())
        XCTAssertEqual(reloaded.count, 1, "Budget row should survive a full container reload")
        XCTAssertEqual(reloaded.first?.isFixed, true, "isFixed should survive a full container reload")

        let categories = try context2.fetch(FetchDescriptor<FinanceTracker.Category>())
        let rentReloaded = try XCTUnwrap(categories.first { $0.name == "Rent" })
        let october = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        XCTAssertEqual(reloaded.amount(for: rentReloaded, month: october), 1200, "October should carry forward from the reloaded September row")
        XCTAssertTrue(reloaded.isFixed(for: rentReloaded, month: october))

        try? FileManager.default.removeItem(at: storeURL)
    }
}
