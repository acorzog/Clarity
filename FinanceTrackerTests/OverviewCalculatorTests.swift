import XCTest
import SwiftData
@testable import FinanceTracker

private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
}

/// Mirrors `BudgetSettingsStore`'s actual defaults, matching `BudgetCalculatorTests`'/
/// `HomeCalculatorTests`' own convention.
private func testSettings(
    cycleStartDay: Int = 1,
    manualMonthlyBudget: Decimal = 0,
    includeUnplannedAsOtherExpenses: Bool = true,
    includeSavingsTransfers: Bool = false,
    includeDebtTransfers: Bool = true
) -> BudgetCalculationSettings {
    BudgetCalculationSettings(
        cycleStartDay: cycleStartDay,
        manualMonthlyBudget: manualMonthlyBudget,
        includeUnplannedAsOtherExpenses: includeUnplannedAsOtherExpenses,
        includeSavingsTransfers: includeSavingsTransfers,
        includeDebtTransfers: includeDebtTransfers
    )
}

// MARK: - BudgetHealthState

final class BudgetHealthStateTests: XCTestCase {
    func testBelow85PercentIsOnTrack() {
        XCTAssertEqual(BudgetHealthState.forProgress(0), .onTrack)
        XCTAssertEqual(BudgetHealthState.forProgress(0.849), .onTrack)
    }

    func testAtOrAbove85PercentUpToAndIncludingExactly100PercentIsApproachingLimit() {
        // Hitting the plan exactly (100%) is "approaching," not "over" — spending exactly what
        // was planned isn't a bad outcome.
        XCTAssertEqual(BudgetHealthState.forProgress(0.85), .approachingLimit)
        XCTAssertEqual(BudgetHealthState.forProgress(0.999), .approachingLimit)
        XCTAssertEqual(BudgetHealthState.forProgress(1.0), .approachingLimit)
    }

    func testStrictlyAbove100PercentIsOverBudget() {
        XCTAssertEqual(BudgetHealthState.forProgress(1.001), .overBudget)
        XCTAssertEqual(BudgetHealthState.forProgress(2.5), .overBudget)
    }

    func testStatesAreOrderedOnTrackThenApproachingThenOverBudget() {
        XCTAssertLessThan(BudgetHealthState.onTrack, .approachingLimit)
        XCTAssertLessThan(BudgetHealthState.approachingLimit, .overBudget)
    }
}

// MARK: - OverviewCalculator.categorySpendingHealth

final class OverviewCalculatorSpendingHealthTests: XCTestCase {

    @discardableResult
    private func makeBudgetedCategory(
        name: String,
        monthlyLimit: Decimal,
        spent: Decimal,
        headCategory: HeadCategory,
        wallet: Wallet,
        in context: ModelContext
    ) -> FinanceTracker.Category {
        let category = TestSupport.makeCategory(name: name, headCategory: headCategory)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: monthlyLimit, month: 6, year: 2025)
        context.insert(category); context.insert(budget)
        if spent > 0 {
            let entry = TestSupport.makeEntry(amount: spent, date: testDate(2025, 6, 15), type: .expense, category: category, wallet: wallet)
            context.insert(entry)
        }
        return category
    }

    func testCategoryWithNoBudgetIsExcludedEntirely() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let expense = TestSupport.makeEntry(amount: 50, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(expense)

        let result = OverviewCalculator.categorySpendingHealth(
            month: testDate(2025, 6, 1), entries: [expense], budgets: [], headCategories: [head], settings: testSettings()
        )

        XCTAssertTrue(result.isEmpty, "a category with no budget has no meaningful health state to show")
    }

    /// A budgeted category with nothing spent yet must still show up — 0% "on track" — rather
    /// than being excluded (which `guard actual.planned > 0` only does for *unbudgeted*
    /// categories, never for unbudgeted-but-unspent ones).
    func testCategoryWithBudgetAndZeroSpendingIsOnTrackAtZeroPercent() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        context.insert(wallet); context.insert(head)
        let category = makeBudgetedCategory(name: "Untouched", monthlyLimit: 150, spent: 0, headCategory: head, wallet: wallet, in: context)

        let result = OverviewCalculator.categorySpendingHealth(
            month: testDate(2025, 6, 1), entries: fetchEntries(context), budgets: fetchBudgets(context), headCategories: [head], settings: testSettings()
        )

        let row = result.first { $0.category === category }
        XCTAssertNotNil(row, "a budgeted category with zero spend still has a meaningful health state to show")
        XCTAssertEqual(row?.state, .onTrack)
        XCTAssertEqual(row?.progress, 0)
        XCTAssertEqual(row?.spent, 0)
        XCTAssertEqual(row?.budgeted, 150)
    }

    /// An explicit `Budget` row with `monthlyLimit == 0` must be excluded exactly like having no
    /// `Budget` row at all — same `planned > 0` guard, no separate "budgeted at zero" code path
    /// that could divide by zero or invent a percentage.
    func testCategoryWithExplicitZeroLimitBudgetIsExcludedEntirely() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "ZeroLimit", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 0, month: 6, year: 2025)
        let expense = TestSupport.makeEntry(amount: 25, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(expense)

        let result = OverviewCalculator.categorySpendingHealth(
            month: testDate(2025, 6, 1), entries: [expense], budgets: [budget], headCategories: [head], settings: testSettings()
        )

        XCTAssertNil(result.first { $0.category === category }, "an explicit zero-limit budget is indistinguishable from no budget at all")
    }

    /// Integration check (not just the isolated `BudgetHealthState.forProgress` unit test): spend
    /// landing exactly on the budget limit, run through the real category totals, must still read
    /// as "approaching," not "over."
    func testCategoryAtExactlyOneHundredPercentIsApproachingLimitNotOverBudget() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        context.insert(wallet); context.insert(head)
        let category = makeBudgetedCategory(name: "ExactlyOnPlan", monthlyLimit: 200, spent: 200, headCategory: head, wallet: wallet, in: context)

        let result = OverviewCalculator.categorySpendingHealth(
            month: testDate(2025, 6, 1), entries: fetchEntries(context), budgets: fetchBudgets(context), headCategories: [head], settings: testSettings()
        )

        let row = result.first { $0.category === category }
        XCTAssertEqual(row?.progress ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(row?.state, .approachingLimit, "hitting the plan exactly isn't over budget")
    }

    /// A very small (sub-dollar) budget must produce a normal, finite percentage — no
    /// division-by-zero or runaway value — exactly like any other budget.
    func testVerySmallBudgetProducesAValidPercentageWhenOverspent() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        context.insert(wallet); context.insert(head)
        let category = makeBudgetedCategory(name: "TinyBudget", monthlyLimit: 0.01, spent: 0.02, headCategory: head, wallet: wallet, in: context)

        let result = OverviewCalculator.categorySpendingHealth(
            month: testDate(2025, 6, 1), entries: fetchEntries(context), budgets: fetchBudgets(context), headCategories: [head], settings: testSettings()
        )

        let row = result.first { $0.category === category }
        XCTAssertEqual(row?.progress ?? -1, 2.0, accuracy: 0.0001)
        XCTAssertTrue(row?.progress.isFinite ?? false)
        XCTAssertEqual(row?.state, .overBudget)
    }

    /// A category whose only entries are all `excludeFromBudget` must read exactly like a
    /// budgeted-but-untouched category — 0% on track — not get skipped or mis-flagged, tying
    /// together the exclusion guard and the zero-spend guard in the same scenario.
    func testCategoryWhereAllSpendingIsExcludedIsOnTrackAtZeroPercent() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "AllExcluded", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 6, year: 2025)
        let excluded = TestSupport.makeEntry(amount: 500, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet, excludeFromBudget: true)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(excluded)

        let result = OverviewCalculator.categorySpendingHealth(
            month: testDate(2025, 6, 1), entries: [excluded], budgets: [budget], headCategories: [head], settings: testSettings()
        )

        let row = result.first { $0.category === category }
        XCTAssertEqual(row?.spent, 0)
        XCTAssertEqual(row?.state, .onTrack)
    }

    /// When two categories land on the exact same state and progress, the tie must resolve the
    /// same way every time (Swift's `sorted` is stable, so ties preserve `byCategory`'s original
    /// order) — not depend on incidental hashing/traversal order that could vary run to run.
    func testTiedStateAndProgressResolveDeterministicallyByOriginalCategoryOrder() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        context.insert(wallet); context.insert(head)

        // Both categories: 90/100 = 0.9, both `.approachingLimit` — an exact tie on both sort keys.
        let first = makeBudgetedCategory(name: "FirstTied", monthlyLimit: 100, spent: 90, headCategory: head, wallet: wallet, in: context)
        let second = makeBudgetedCategory(name: "SecondTied", monthlyLimit: 100, spent: 90, headCategory: head, wallet: wallet, in: context)

        let result1 = OverviewCalculator.categorySpendingHealth(
            month: testDate(2025, 6, 1), entries: fetchEntries(context), budgets: fetchBudgets(context), headCategories: [head], settings: testSettings()
        )
        let result2 = OverviewCalculator.categorySpendingHealth(
            month: testDate(2025, 6, 1), entries: fetchEntries(context), budgets: fetchBudgets(context), headCategories: [head], settings: testSettings()
        )

        XCTAssertEqual(result1.map { $0.category.name }, [first.name, second.name])
        XCTAssertEqual(result1.map { $0.category.name }, result2.map { $0.category.name }, "repeated calls on identical input must produce the identical order")
    }

    func testCategoryUnderEightyFivePercentIsOnTrack() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        context.insert(wallet); context.insert(head)
        let category = makeBudgetedCategory(name: "Groceries", monthlyLimit: 200, spent: 100, headCategory: head, wallet: wallet, in: context)

        let result = OverviewCalculator.categorySpendingHealth(
            month: testDate(2025, 6, 1), entries: fetchEntries(context), budgets: fetchBudgets(context), headCategories: [head], settings: testSettings()
        )

        let row = result.first { $0.category === category }
        XCTAssertEqual(row?.state, .onTrack)
        XCTAssertEqual(row?.progress ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(row?.spent, 100)
        XCTAssertEqual(row?.budgeted, 200)
    }

    func testCategoryAtEightyFivePercentIsApproachingLimit() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        context.insert(wallet); context.insert(head)
        let category = makeBudgetedCategory(name: "Restaurants", monthlyLimit: 200, spent: 170, headCategory: head, wallet: wallet, in: context)

        let result = OverviewCalculator.categorySpendingHealth(
            month: testDate(2025, 6, 1), entries: fetchEntries(context), budgets: fetchBudgets(context), headCategories: [head], settings: testSettings()
        )

        let row = result.first { $0.category === category }
        XCTAssertEqual(row?.state, .approachingLimit)
        XCTAssertEqual(row?.progress ?? 0, 0.85, accuracy: 0.001)
    }

    func testCategoryAtOrOverBudgetIsOverBudget() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        context.insert(wallet); context.insert(head)
        let category = makeBudgetedCategory(name: "Shopping", monthlyLimit: 200, spent: 250, headCategory: head, wallet: wallet, in: context)

        let result = OverviewCalculator.categorySpendingHealth(
            month: testDate(2025, 6, 1), entries: fetchEntries(context), budgets: fetchBudgets(context), headCategories: [head], settings: testSettings()
        )

        let row = result.first { $0.category === category }
        XCTAssertEqual(row?.state, .overBudget)
        XCTAssertEqual(row?.progress ?? 0, 1.25, accuracy: 0.001)
    }

    func testExcludedEntriesDoNotCountTowardSpent() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 6, year: 2025)
        let normal = TestSupport.makeEntry(amount: 50, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        let excluded = TestSupport.makeEntry(amount: 500, date: testDate(2025, 6, 11), type: .expense, category: category, wallet: wallet, excludeFromBudget: true)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(normal); context.insert(excluded)

        let result = OverviewCalculator.categorySpendingHealth(
            month: testDate(2025, 6, 1), entries: [normal, excluded], budgets: [budget], headCategories: [head], settings: testSettings()
        )

        let row = result.first { $0.category === category }
        XCTAssertEqual(row?.spent, 50, "an excludeFromBudget entry must never count toward Spending Health")
        XCTAssertEqual(row?.state, .onTrack)
    }

    func testResultsAreRankedOverBudgetFirstThenApproachingThenOnTrack() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        context.insert(wallet); context.insert(head)

        let onTrack = makeBudgetedCategory(name: "OnTrack", monthlyLimit: 100, spent: 40, headCategory: head, wallet: wallet, in: context) // 0.4
        let approaching = makeBudgetedCategory(name: "Approaching", monthlyLimit: 100, spent: 90, headCategory: head, wallet: wallet, in: context) // 0.9
        let overLow = makeBudgetedCategory(name: "OverLow", monthlyLimit: 100, spent: 150, headCategory: head, wallet: wallet, in: context) // 1.5
        let overHigh = makeBudgetedCategory(name: "OverHigh", monthlyLimit: 100, spent: 180, headCategory: head, wallet: wallet, in: context) // 1.8

        let result = OverviewCalculator.categorySpendingHealth(
            month: testDate(2025, 6, 1), entries: fetchEntries(context), budgets: fetchBudgets(context), headCategories: [head], settings: testSettings()
        )

        XCTAssertEqual(result.map { $0.category.name }, [overHigh, overLow, approaching, onTrack].map(\.name))
    }

    func testResultIsCappedAtMaxSpendingHealthCategoriesKeepingTheHighestPriorityOnes() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        context.insert(wallet); context.insert(head)

        // Seven over-budget categories with strictly increasing progress — only the top
        // `maxSpendingHealthCategories` (highest progress) should survive the cap.
        let categories = (0..<7).map { index in
            makeBudgetedCategory(name: "Cat\(index)", monthlyLimit: 100, spent: Decimal(110 + index * 10), headCategory: head, wallet: wallet, in: context)
        }

        let result = OverviewCalculator.categorySpendingHealth(
            month: testDate(2025, 6, 1), entries: fetchEntries(context), budgets: fetchBudgets(context), headCategories: [head], settings: testSettings()
        )

        XCTAssertEqual(OverviewCalculator.maxSpendingHealthCategories, 5)
        XCTAssertEqual(result.count, 5)
        // Highest-progress five: Cat6 (1.80) down to Cat2 (1.30); Cat0/Cat1 dropped.
        let expectedNames = Array(categories.reversed().prefix(5)).map(\.name)
        XCTAssertEqual(result.map { $0.category.name }, expectedNames)
    }

    func testNoBudgetedCategoriesAtAllReturnsEmptyResult() {
        let result = OverviewCalculator.categorySpendingHealth(
            month: testDate(2025, 6, 1), entries: [], budgets: [], headCategories: [], settings: testSettings()
        )

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Helpers

    private func fetchEntries(_ context: ModelContext) -> [Entry] {
        (try? context.fetch(FetchDescriptor<Entry>())) ?? []
    }

    private func fetchBudgets(_ context: ModelContext) -> [Budget] {
        (try? context.fetch(FetchDescriptor<Budget>())) ?? []
    }
}
