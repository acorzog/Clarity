import XCTest
import SwiftData
@testable import FinanceTracker

private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
}

private let today = testDate(2025, 6, 20)

private func testSettings() -> BudgetCalculationSettings {
    BudgetCalculationSettings(cycleStartDay: 1, manualMonthlyBudget: 0, includeUnplannedAsOtherExpenses: true, includeSavingsTransfers: false, includeDebtTransfers: true)
}

/// Covers the UI-only presentation layer in `Views/AskClarityView.swift` that turns an already-
/// answered question into a structured `AskClarityInsight` card — never a second calculation, just
/// a second, independent run of the same local **interpret → plan → execute** stages
/// `AskClarityEngine.respond` itself uses, kept for its raw numbers. See `AskClarityInsight`'s doc
/// comment.
final class AskClarityInsightTests: XCTestCase {
    func testSpendingInsightForAPlainTotalSpendingQuestion() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let expense = TestSupport.makeEntry(amount: 250, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(expense)

        guard let insight = AskClarityInsight.build(
            for: "How much did I spend this month?", context: .empty, entries: [expense], budgets: [], headCategories: [head], settings: testSettings(), today: today
        ) else {
            return XCTFail("should build a spending insight")
        }
        guard case .spending(let data) = insight else { return XCTFail("expected .spending, got \(insight)") }
        XCTAssertEqual(data.amount, 250)
    }

    /// The exact figure must track the real input, never a fixed/example number.
    func testSpendingInsightAmountIsNeverHardcoded() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        context.insert(wallet); context.insert(head); context.insert(category)

        for amount: Decimal in [37, 1912.50] {
            let expense = TestSupport.makeEntry(amount: amount, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
            guard case .spending(let data) = AskClarityInsight.build(
                for: "How much did I spend this month?", context: .empty, entries: [expense], budgets: [], headCategories: [head], settings: testSettings(), today: today
            ) else {
                return XCTFail("should build a spending insight for amount \(amount)")
            }
            XCTAssertEqual(data.amount, amount)
        }
    }

    func testCategoryInsightForWhereAmISpendingTheMost() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let rent = TestSupport.makeCategory(name: "Rent", headCategory: head)
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let rentExpense = TestSupport.makeEntry(amount: 1200, date: testDate(2025, 6, 1), type: .expense, category: rent, wallet: wallet)
        let groceriesExpense = TestSupport.makeEntry(amount: 300, date: testDate(2025, 6, 5), type: .expense, category: groceries, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(rent); context.insert(groceries)
        context.insert(rentExpense); context.insert(groceriesExpense)

        guard let insight = AskClarityInsight.build(
            for: "Where am I spending the most?", context: .empty, entries: [rentExpense, groceriesExpense], budgets: [],
            headCategories: [head], settings: testSettings(), today: today
        ) else {
            return XCTFail("should build a category insight")
        }
        guard case .category(let data) = insight else { return XCTFail("expected .category, got \(insight)") }
        XCTAssertEqual(data.category.name, "Rent")
        XCTAssertEqual(data.amount, 1200)
        XCTAssertEqual(data.shareOfTotal ?? -1, 0.8, accuracy: 0.001, "1200 of a 1500 total")
    }

    func testBudgetInsightForAmIWithinMyBudgetOverall() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 200, month: 6, year: 2025)
        let expense = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(expense)

        guard let insight = AskClarityInsight.build(
            for: "Am I within my budget?", context: .empty, entries: [expense], budgets: [budget], headCategories: [head], settings: testSettings(), today: today
        ) else {
            return XCTFail("should build a budget insight")
        }
        guard case .budget(let data) = insight else { return XCTFail("expected .budget, got \(insight)") }
        XCTAssertEqual(data.state, .onTrack)
        XCTAssertEqual(data.spent, 40)
        XCTAssertEqual(data.available, 200)
    }

    func testCategoryBudgetListInsightForWhichCategoriesAreOverBudget() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let over = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let onTrack = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let overBudget = TestSupport.makeBudget(category: over, monthlyLimit: 100, month: 6, year: 2025)
        let onTrackBudget = TestSupport.makeBudget(category: onTrack, monthlyLimit: 200, month: 6, year: 2025)
        let overExpense = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: over, wallet: wallet)
        let onTrackExpense = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 10), type: .expense, category: onTrack, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(over); context.insert(onTrack)
        context.insert(overBudget); context.insert(onTrackBudget); context.insert(overExpense); context.insert(onTrackExpense)

        guard let insight = AskClarityInsight.build(
            for: "Which categories are over budget?", context: .empty, entries: [overExpense, onTrackExpense],
            budgets: [overBudget, onTrackBudget], headCategories: [head], settings: testSettings(), today: today
        ) else {
            return XCTFail("should build a category-budget-list insight")
        }
        guard case .categoryBudgetList(let data) = insight else { return XCTFail("expected .categoryBudgetList, got \(insight)") }
        XCTAssertEqual(data.state, .overBudget)
        XCTAssertEqual(data.rows.map(\.category.name), ["Dining"])
    }

    /// No spending logged at all — nothing genuine to visualize, so the graceful fallback is
    /// `nil`, letting the existing plain-text answer show instead. Never an empty/zeroed chart.
    func testFallsBackToNilWhenThereIsNoSpendingToShow() {
        let insight = AskClarityInsight.build(
            for: "How much did I spend this month?", context: .empty, entries: [], budgets: [], headCategories: [], settings: testSettings(), today: today
        )
        XCTAssertNil(insight)
    }

    /// A question shape with no card designed for it yet — an un-categoried "why" question stays
    /// `.legacyFallback` at the Planner level (`AskClarityPlanner.plan`, step 6) rather than
    /// producing a `Plan` at all — must fall back to `nil`, not crash or guess a shape for it.
    func testFallsBackToNilForAQuestionShapeWithNoDesignedCard() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let expense = TestSupport.makeEntry(amount: 250, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(expense)

        let insight = AskClarityInsight.build(
            for: "Why am I overspending?", context: .empty, entries: [expense], budgets: [], headCategories: [head], settings: testSettings(), today: today
        )
        XCTAssertNil(insight)
    }

    /// Zero budgets configured at all — the overall budget insight must not fabricate a "within
    /// budget" verdict against a zero denominator.
    func testBudgetInsightFallsBackToNilWithNoBudgetConfigured() {
        let insight = AskClarityInsight.build(
            for: "Am I within my budget?", context: .empty, entries: [], budgets: [], headCategories: [], settings: testSettings(), today: today
        )
        XCTAssertNil(insight)
    }
}
