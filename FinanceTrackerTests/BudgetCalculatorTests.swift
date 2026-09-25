import XCTest
import SwiftData
@testable import FinanceTracker

private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
}

/// Mirrors `BudgetSettingsStore`'s actual defaults (`Models/BudgetSettings.swift`) so a test that
/// doesn't care about a particular knob still exercises the real default behavior.
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

final class BudgetCalculatorPeriodSpendingSummaryTests: XCTestCase {

    // MARK: - Available money fallback chain (1-3)

    func testManualBudgetFallbackTakesPriorityOverEverything() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 200, month: 6, year: 2025)
        let income = TestSupport.makeEntry(amount: 500, date: testDate(2025, 6, 10), type: .income, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(income)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1),
            entries: [income],
            budgets: [budget],
            headCategories: [head],
            settings: testSettings(manualMonthlyBudget: 999),
            respectHiddenCategories: true
        )

        XCTAssertEqual(summary.totalAvailable, 999)
    }

    func testIncomeFallbackWinsOverPlannedBudgetWhenNoManualBudget() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 200, month: 6, year: 2025)
        let income = TestSupport.makeEntry(amount: 500, date: testDate(2025, 6, 10), type: .income, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(income)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1),
            entries: [income],
            budgets: [budget],
            headCategories: [head],
            settings: testSettings(),
            respectHiddenCategories: true
        )

        XCTAssertEqual(summary.totalAvailable, 500)
        XCTAssertEqual(summary.totalIncome, 500)
    }

    func testPlannedBudgetFallbackWhenNoManualBudgetAndNoIncome() {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 200, month: 6, year: 2025)
        context.insert(head); context.insert(category); context.insert(budget)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1),
            entries: [],
            budgets: [budget],
            headCategories: [head],
            settings: testSettings(),
            respectHiddenCategories: true
        )

        XCTAssertEqual(summary.totalAvailable, 200)
        XCTAssertEqual(summary.totalBudgeted, 200)
    }

    // MARK: - Unplanned ("Other") expenses (4-5)

    func testUnplannedExpensesAreIncludedInTotalSpentByDefault() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        let unbudgeted = TestSupport.makeCategory(name: "Misc", headCategory: head)
        let expense = TestSupport.makeEntry(amount: 30, date: testDate(2025, 6, 5), type: .expense, category: unbudgeted, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(unbudgeted); context.insert(expense)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1),
            entries: [expense],
            budgets: [],
            headCategories: [head],
            settings: testSettings(includeUnplannedAsOtherExpenses: true),
            respectHiddenCategories: true
        )

        XCTAssertEqual(summary.otherExpensesTotal, 30)
        XCTAssertEqual(summary.totalSpent, 30)
    }

    func testUnplannedExpensesAreExcludedFromTotalSpentWhenToggledOff() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        let unbudgeted = TestSupport.makeCategory(name: "Misc", headCategory: head)
        let expense = TestSupport.makeEntry(amount: 30, date: testDate(2025, 6, 5), type: .expense, category: unbudgeted, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(unbudgeted); context.insert(expense)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1),
            entries: [expense],
            budgets: [],
            headCategories: [head],
            settings: testSettings(includeUnplannedAsOtherExpenses: false),
            respectHiddenCategories: true
        )

        // otherExpensesTotal always reports the raw amount; only totalSpent's inclusion is toggled.
        XCTAssertEqual(summary.otherExpensesTotal, 30)
        XCTAssertEqual(summary.totalSpent, 0)
    }

    // MARK: - Savings transfers (6-7)

    func testSavingsTransfersAreIncludedInTotalSpentWhenToggledOn() {
        let context = TestSupport.makeInMemoryContext()
        let source = TestSupport.makeWallet(name: "Spending")
        let savings = TestSupport.makeWallet(name: "Savings", type: .savings)
        let head = TestSupport.makeHeadCategory()
        let transfer = TestSupport.makeEntry(
            amount: 100, date: testDate(2025, 6, 5), type: .transfer, wallet: source, destinationWallet: savings
        )
        context.insert(source); context.insert(savings); context.insert(head); context.insert(transfer)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1),
            entries: [transfer],
            budgets: [],
            headCategories: [head],
            settings: testSettings(includeSavingsTransfers: true),
            respectHiddenCategories: true
        )

        XCTAssertEqual(summary.savingsTransfersTotal, 100)
        XCTAssertEqual(summary.totalSpent, 100)
    }

    func testSavingsTransfersAreExcludedFromTotalSpentByDefault() {
        let context = TestSupport.makeInMemoryContext()
        let source = TestSupport.makeWallet(name: "Spending")
        let savings = TestSupport.makeWallet(name: "Savings", type: .savings)
        let head = TestSupport.makeHeadCategory()
        let transfer = TestSupport.makeEntry(
            amount: 100, date: testDate(2025, 6, 5), type: .transfer, wallet: source, destinationWallet: savings
        )
        context.insert(source); context.insert(savings); context.insert(head); context.insert(transfer)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1),
            entries: [transfer],
            budgets: [],
            headCategories: [head],
            settings: testSettings(), // includeSavingsTransfers defaults to false
            respectHiddenCategories: true
        )

        XCTAssertEqual(summary.savingsTransfersTotal, 100)
        XCTAssertEqual(summary.totalSpent, 0)
    }

    // MARK: - Debt transfers (8-9)

    func testDebtTransfersAreIncludedInTotalSpentByDefault() {
        let context = TestSupport.makeInMemoryContext()
        let source = TestSupport.makeWallet(name: "Spending")
        let debt = TestSupport.makeWallet(name: "Credit Card", type: .debt)
        let head = TestSupport.makeHeadCategory()
        let transfer = TestSupport.makeEntry(
            amount: 75, date: testDate(2025, 6, 5), type: .transfer, wallet: source, destinationWallet: debt
        )
        context.insert(source); context.insert(debt); context.insert(head); context.insert(transfer)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1),
            entries: [transfer],
            budgets: [],
            headCategories: [head],
            settings: testSettings(), // includeDebtTransfers defaults to true
            respectHiddenCategories: true
        )

        XCTAssertEqual(summary.debtTransfersTotal, 75)
        XCTAssertEqual(summary.totalSpent, 75)
    }

    func testDebtTransfersAreExcludedFromTotalSpentWhenToggledOff() {
        let context = TestSupport.makeInMemoryContext()
        let source = TestSupport.makeWallet(name: "Spending")
        let debt = TestSupport.makeWallet(name: "Credit Card", type: .debt)
        let head = TestSupport.makeHeadCategory()
        let transfer = TestSupport.makeEntry(
            amount: 75, date: testDate(2025, 6, 5), type: .transfer, wallet: source, destinationWallet: debt
        )
        context.insert(source); context.insert(debt); context.insert(head); context.insert(transfer)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1),
            entries: [transfer],
            budgets: [],
            headCategories: [head],
            settings: testSettings(includeDebtTransfers: false),
            respectHiddenCategories: true
        )

        XCTAssertEqual(summary.debtTransfersTotal, 75)
        XCTAssertEqual(summary.totalSpent, 0)
    }

    // MARK: - excludeFromBudget symmetry (10-11)

    func testExcludedExpenseNeverContributesToSpending() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 6, year: 2025)
        let excludedExpense = TestSupport.makeEntry(
            amount: 40, date: testDate(2025, 6, 5), type: .expense, category: category, wallet: wallet, excludeFromBudget: true
        )
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(excludedExpense)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1),
            entries: [excludedExpense],
            budgets: [budget],
            headCategories: [head],
            settings: testSettings(),
            respectHiddenCategories: true
        )

        XCTAssertEqual(summary.totalSpent, 0)
        XCTAssertEqual(summary.byCategory.first { $0.category === category }?.actual, 0)
    }

    func testExcludedIncomeNeverContributesToEligibleIncome() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        let excludedIncome = TestSupport.makeEntry(
            amount: 500, date: testDate(2025, 6, 5), type: .income, wallet: wallet, excludeFromBudget: true
        )
        context.insert(wallet); context.insert(head); context.insert(excludedIncome)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1),
            entries: [excludedIncome],
            budgets: [],
            headCategories: [head],
            settings: testSettings(), // no manual budget, no planned budget either
            respectHiddenCategories: true
        )

        XCTAssertEqual(summary.totalIncome, 0)
        // Falls all the way through to the (empty) planned-budget fallback, not the excluded income.
        XCTAssertEqual(summary.totalAvailable, 0)
    }

    // MARK: - Hidden categories (12)

    func testHiddenCategoryContributesNothingWhenRespected() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(name: "Subscriptions", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 50, month: 6, year: 2025, isHidden: true)
        let expense = TestSupport.makeEntry(amount: 20, date: testDate(2025, 6, 5), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(expense)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1),
            entries: [expense],
            budgets: [budget],
            headCategories: [head],
            settings: testSettings(),
            respectHiddenCategories: true
        )

        XCTAssertEqual(summary.totalBudgeted, 0)
        XCTAssertEqual(summary.byCategory.first { $0.category === category }?.planned, 0)
        // A hidden category's planned amount is 0, so its spend falls into "Other."
        XCTAssertEqual(summary.otherExpensesTotal, 20)
    }

    func testHiddenCategoryStillCountsWhenNotRespected() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(name: "Subscriptions", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 50, month: 6, year: 2025, isHidden: true)
        let expense = TestSupport.makeEntry(amount: 20, date: testDate(2025, 6, 5), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(expense)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1),
            entries: [expense],
            budgets: [budget],
            headCategories: [head],
            settings: testSettings(),
            respectHiddenCategories: false
        )

        XCTAssertEqual(summary.totalBudgeted, 50)
        XCTAssertEqual(summary.byCategory.first { $0.category === category }?.planned, 50)
        XCTAssertEqual(summary.otherExpensesTotal, 0)
    }

    // MARK: - Category / head-category actuals (13-15)

    func testCategoryActualsReportPlannedActualAndRemaining() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 6, year: 2025)
        let expense = TestSupport.makeEntry(amount: 30, date: testDate(2025, 6, 5), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(expense)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1),
            entries: [expense],
            budgets: [budget],
            headCategories: [head],
            settings: testSettings(),
            respectHiddenCategories: true
        )

        let actual = summary.byCategory.first { $0.category === category }
        XCTAssertEqual(actual?.planned, 100)
        XCTAssertEqual(actual?.actual, 30)
        XCTAssertEqual(actual?.remaining, 70)
    }

    func testHeadCategoryActualsAggregateItsCategoriesAndExcludeEmptyOrAllZeroHeads() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let food = TestSupport.makeHeadCategory(name: "Food")
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: food)
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: food)
        let groceriesBudget = TestSupport.makeBudget(category: groceries, monthlyLimit: 100, month: 6, year: 2025)
        let restaurantsBudget = TestSupport.makeBudget(category: restaurants, monthlyLimit: 50, month: 6, year: 2025)
        let expense = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 5), type: .expense, category: groceries, wallet: wallet)

        // A head category with no expense categories at all under it must never appear.
        let emptyHead = TestSupport.makeHeadCategory(name: "Empty")
        // A head with expense categories but zero planned and zero actual must not appear either.
        let untouchedHead = TestSupport.makeHeadCategory(name: "Untouched")
        let neverUsed = TestSupport.makeCategory(name: "NeverUsed", headCategory: untouchedHead)

        context.insert(wallet); context.insert(food); context.insert(groceries); context.insert(restaurants)
        context.insert(groceriesBudget); context.insert(restaurantsBudget); context.insert(expense)
        context.insert(emptyHead); context.insert(untouchedHead); context.insert(neverUsed)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1),
            entries: [expense],
            budgets: [groceriesBudget, restaurantsBudget],
            headCategories: [food, emptyHead, untouchedHead],
            settings: testSettings(),
            respectHiddenCategories: true
        )

        XCTAssertEqual(summary.byHeadCategory.count, 1)
        let foodSummary = summary.byHeadCategory.first { $0.headCategory === food }
        XCTAssertEqual(foodSummary?.planned, 150)
        XCTAssertEqual(foodSummary?.actual, 40)
        XCTAssertEqual(foodSummary?.remaining, 110)
    }

    func testOverBudgetCategoryHasNegativeRemaining() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 50, month: 6, year: 2025)
        let expense = TestSupport.makeEntry(amount: 80, date: testDate(2025, 6, 5), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(expense)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1),
            entries: [expense],
            budgets: [budget],
            headCategories: [head],
            settings: testSettings(),
            respectHiddenCategories: true
        )

        let actual = summary.byCategory.first { $0.category === category }
        XCTAssertEqual(actual?.remaining, -30)
    }

    // MARK: - Zero/empty data (16)

    func testEmptyInputsProduceAllZeroSummary() {
        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1),
            entries: [],
            budgets: [],
            headCategories: [],
            settings: testSettings(),
            respectHiddenCategories: true
        )

        XCTAssertEqual(summary.totalAvailable, 0)
        XCTAssertEqual(summary.totalSpent, 0)
        XCTAssertEqual(summary.totalBudgeted, 0)
        XCTAssertEqual(summary.totalIncome, 0)
        XCTAssertEqual(summary.totalLeft, 0)
        XCTAssertTrue(summary.byCategory.isEmpty)
        XCTAssertTrue(summary.byHeadCategory.isEmpty)
    }

    // MARK: - Non-default cycle start day (17-18)

    /// `Date.budgetPeriod(startDay:)` returns the cycle window **containing** the given date, not
    /// the window that starts within its calendar month — so viewing "July" (passing July 1) with
    /// `cycleStartDay == 15` yields the period June 15 - July 15 (the window July 1 actually falls
    /// inside), not July 15 - August 15. This is existing, unchanged `EntryQuerying`/`Date.
    /// budgetPeriod` behavior (see `Models/EntryQuerying.swift`), just exercised here for the
    /// first time.
    func testNonDefaultCycleStartScopesEntriesToTheShiftedPeriodNotTheCalendarMonth() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()

        // cycleStartDay = 15: viewing July (month = July 1) resolves to the period containing
        // July 1, which is June 15 - July 15.
        let beforePeriod = TestSupport.makeEntry(amount: 10, date: testDate(2025, 6, 10), type: .expense, wallet: wallet)
        let insidePeriodJune = TestSupport.makeEntry(amount: 20, date: testDate(2025, 6, 20), type: .expense, wallet: wallet)
        let insidePeriodJuly = TestSupport.makeEntry(amount: 30, date: testDate(2025, 7, 5), type: .expense, wallet: wallet)
        let afterPeriod = TestSupport.makeEntry(amount: 40, date: testDate(2025, 7, 20), type: .expense, wallet: wallet)
        context.insert(wallet); context.insert(head)
        context.insert(beforePeriod); context.insert(insidePeriodJune); context.insert(insidePeriodJuly); context.insert(afterPeriod)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 7, 1),
            entries: [beforePeriod, insidePeriodJune, insidePeriodJuly, afterPeriod],
            budgets: [],
            headCategories: [head],
            settings: testSettings(cycleStartDay: 15, includeUnplannedAsOtherExpenses: true),
            respectHiddenCategories: true
        )

        XCTAssertEqual(summary.totalSpent, 50) // only insidePeriodJune (20) + insidePeriodJuly (30)
        XCTAssertEqual(summary.period.start, testDate(2025, 6, 15))
        XCTAssertEqual(summary.period.end, testDate(2025, 7, 15))
    }

    func testBudgetLimitStaysCalendarMonthWhileActualSpendingUsesTheCycle() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        // The Budget row is keyed to July — the calendar month of the `month` argument below,
        // per BudgetQuerying — even though the cycle period it's compared against (June 15 -
        // July 15, see the test above) mostly overlaps June.
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 7, year: 2025)
        // This expense falls inside that June 15 - July 15 cycle period but its own calendar
        // date is in June, not July.
        let expenseInJunePartOfThePeriod = TestSupport.makeEntry(
            amount: 25, date: testDate(2025, 6, 20), type: .expense, category: category, wallet: wallet
        )
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget)
        context.insert(expenseInJunePartOfThePeriod)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 7, 1),
            entries: [expenseInJunePartOfThePeriod],
            budgets: [budget],
            headCategories: [head],
            settings: testSettings(cycleStartDay: 15),
            respectHiddenCategories: true
        )

        // Planned amount still comes from July's Budget row (the calendar month being viewed)...
        XCTAssertEqual(summary.byCategory.first { $0.category === category }?.planned, 100)
        // ...while actual spend correctly picks up the June-dated entry, since it's inside the
        // cycle period July 1 falls into.
        XCTAssertEqual(summary.byCategory.first { $0.category === category }?.actual, 25)
    }

    // MARK: - Decimal accuracy (19)

    func testDecimalArithmeticStaysCentAccurateAcrossManyEntries() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 1000, month: 6, year: 2025)
        let amounts: [Decimal] = [10.10, 20.20, 5.05, 3.33, 0.01, 99.99]
        let entries = amounts.map {
            TestSupport.makeEntry(amount: $0, date: testDate(2025, 6, 5), type: .expense, category: category, wallet: wallet)
        }
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget)
        for entry in entries { context.insert(entry) }

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1),
            entries: entries,
            budgets: [budget],
            headCategories: [head],
            settings: testSettings(),
            respectHiddenCategories: true
        )

        let expectedTotal: Decimal = 10.10 + 20.20 + 5.05 + 3.33 + 0.01 + 99.99
        XCTAssertEqual(summary.totalSpent, expectedTotal)
        XCTAssertEqual(summary.byCategory.first { $0.category === category }?.actual, expectedTotal)
    }
}

final class BudgetCalculatorPlannedBudgetTotalsTests: XCTestCase {

    func testVisibleCategoriesAreIncluded() {
        let context = TestSupport.makeInMemoryContext()
        let income = TestSupport.makeHeadCategory(name: "Income")
        let salary = TestSupport.makeCategory(name: "Salary", isIncome: true, headCategory: income)
        let salaryBudget = TestSupport.makeBudget(category: salary, monthlyLimit: 3000, month: 6, year: 2025)
        context.insert(income); context.insert(salary); context.insert(salaryBudget)

        let totals = BudgetCalculator.plannedBudgetTotals(
            month: testDate(2025, 6, 1),
            budgets: [salaryBudget],
            headCategories: [income]
        )

        XCTAssertEqual(totals.totalPlannedIncome, 3000)
    }

    func testHiddenCategoriesAreExcluded() {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory(name: "Housing")
        let rent = TestSupport.makeCategory(name: "Rent", headCategory: head)
        let hiddenBudget = TestSupport.makeBudget(category: rent, monthlyLimit: 1200, month: 6, year: 2025, isHidden: true)
        context.insert(head); context.insert(rent); context.insert(hiddenBudget)

        let totals = BudgetCalculator.plannedBudgetTotals(
            month: testDate(2025, 6, 1),
            budgets: [hiddenBudget],
            headCategories: [head]
        )

        XCTAssertEqual(totals.totalPlannedExpenses, 0)
    }

    func testIncomeTotalsOnlySumTheIncomeHeadCategory() {
        let context = TestSupport.makeInMemoryContext()
        let income = TestSupport.makeHeadCategory(name: "Income")
        let salary = TestSupport.makeCategory(name: "Salary", isIncome: true, headCategory: income)
        let housing = TestSupport.makeHeadCategory(name: "Housing")
        let rent = TestSupport.makeCategory(name: "Rent", headCategory: housing)
        let salaryBudget = TestSupport.makeBudget(category: salary, monthlyLimit: 3000, month: 6, year: 2025)
        let rentBudget = TestSupport.makeBudget(category: rent, monthlyLimit: 1200, month: 6, year: 2025)
        context.insert(income); context.insert(salary); context.insert(housing); context.insert(rent)
        context.insert(salaryBudget); context.insert(rentBudget)

        let totals = BudgetCalculator.plannedBudgetTotals(
            month: testDate(2025, 6, 1),
            budgets: [salaryBudget, rentBudget],
            headCategories: [income, housing]
        )

        XCTAssertEqual(totals.totalPlannedIncome, 3000)
        XCTAssertEqual(totals.totalPlannedExpenses, 1200)
    }

    func testExpenseTotalsSumEveryNonIncomeHead() {
        let context = TestSupport.makeInMemoryContext()
        let income = TestSupport.makeHeadCategory(name: "Income")
        let housing = TestSupport.makeHeadCategory(name: "Housing")
        let food = TestSupport.makeHeadCategory(name: "Food")
        let rent = TestSupport.makeCategory(name: "Rent", headCategory: housing)
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: food)
        let rentBudget = TestSupport.makeBudget(category: rent, monthlyLimit: 1200, month: 6, year: 2025)
        let groceriesBudget = TestSupport.makeBudget(category: groceries, monthlyLimit: 300, month: 6, year: 2025)
        context.insert(income); context.insert(housing); context.insert(food); context.insert(rent); context.insert(groceries)
        context.insert(rentBudget); context.insert(groceriesBudget)

        let totals = BudgetCalculator.plannedBudgetTotals(
            month: testDate(2025, 6, 1),
            budgets: [rentBudget, groceriesBudget],
            headCategories: [income, housing, food]
        )

        XCTAssertEqual(totals.totalPlannedExpenses, 1500)
    }

    func testLeftToBudgetIsIncomeMinusExpenses() {
        let context = TestSupport.makeInMemoryContext()
        let income = TestSupport.makeHeadCategory(name: "Income")
        let salary = TestSupport.makeCategory(name: "Salary", isIncome: true, headCategory: income)
        let housing = TestSupport.makeHeadCategory(name: "Housing")
        let rent = TestSupport.makeCategory(name: "Rent", headCategory: housing)
        let salaryBudget = TestSupport.makeBudget(category: salary, monthlyLimit: 3000, month: 6, year: 2025)
        let rentBudget = TestSupport.makeBudget(category: rent, monthlyLimit: 1200, month: 6, year: 2025)
        context.insert(income); context.insert(salary); context.insert(housing); context.insert(rent)
        context.insert(salaryBudget); context.insert(rentBudget)

        let totals = BudgetCalculator.plannedBudgetTotals(
            month: testDate(2025, 6, 1),
            budgets: [salaryBudget, rentBudget],
            headCategories: [income, housing]
        )

        XCTAssertEqual(totals.leftToBudget, 1800)
    }

    func testEmptyBudgetsProduceAllZeroTotals() {
        let context = TestSupport.makeInMemoryContext()
        let income = TestSupport.makeHeadCategory(name: "Income")
        let housing = TestSupport.makeHeadCategory(name: "Housing")
        context.insert(income); context.insert(housing)

        let totals = BudgetCalculator.plannedBudgetTotals(
            month: testDate(2025, 6, 1),
            budgets: [],
            headCategories: [income, housing]
        )

        XCTAssertEqual(totals.totalPlannedIncome, 0)
        XCTAssertEqual(totals.totalPlannedExpenses, 0)
        XCTAssertEqual(totals.leftToBudget, 0)
    }
}

final class BudgetCalculatorSpendingPaceTests: XCTestCase {

    func testCumulativeActualSpendingAccumulatesDayOverDay() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let day1 = TestSupport.makeEntry(amount: 10, date: testDate(2025, 6, 1), type: .expense, wallet: wallet)
        let day2 = TestSupport.makeEntry(amount: 15, date: testDate(2025, 6, 2), type: .expense, wallet: wallet)
        context.insert(wallet); context.insert(day1); context.insert(day2)

        // Viewing a fully-elapsed past month: every day has an actual value.
        let points = BudgetCalculator.spendingPace(
            month: testDate(2025, 6, 1),
            entries: [day1, day2],
            settings: testSettings(),
            totalPlanned: 300,
            today: testDate(2025, 8, 1)
        )

        XCTAssertEqual(points.first { $0.day == 1 }?.actual, 10)
        XCTAssertEqual(points.first { $0.day == 2 }?.actual, 25)
        XCTAssertEqual(points.first { $0.day == 3 }?.actual, 25) // no spend on day 3, cumulative carries forward
    }

    func testLinearOnPaceCalculationDividesTotalPlannedEvenlyAcrossPeriodDays() {
        let points = BudgetCalculator.spendingPace(
            month: testDate(2025, 6, 1), // June 2025 has 30 days
            entries: [],
            settings: testSettings(),
            totalPlanned: 300,
            today: testDate(2025, 8, 1)
        )

        XCTAssertEqual(points.count, 30)
        let perDay: Decimal = 300 / 30
        XCTAssertEqual(points.first { $0.day == 1 }?.onPace, perDay * 1)
        XCTAssertEqual(points.first { $0.day == 10 }?.onPace, perDay * 10)
        XCTAssertEqual(points.first { $0.day == 30 }?.onPace, perDay * 30)
    }

    func testPartialPeriodOnlyPopulatesActualThroughToday() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let entry = TestSupport.makeEntry(amount: 10, date: testDate(2025, 6, 1), type: .expense, wallet: wallet)
        context.insert(wallet); context.insert(entry)

        // "Today" is day 5 of the viewed (current) period.
        let points = BudgetCalculator.spendingPace(
            month: testDate(2025, 6, 1),
            entries: [entry],
            settings: testSettings(),
            totalPlanned: 300,
            today: testDate(2025, 6, 5)
        )

        XCTAssertNotNil(points.first { $0.day == 5 }?.actual)
        XCTAssertNil(points.first { $0.day == 6 }?.actual)
    }

    func testDaysWithoutActualsAreNilForAFuturePeriod() {
        // "Today" is before the viewed period even starts.
        let points = BudgetCalculator.spendingPace(
            month: testDate(2025, 6, 1),
            entries: [],
            settings: testSettings(),
            totalPlanned: 300,
            today: testDate(2025, 5, 1)
        )

        XCTAssertTrue(points.allSatisfy { $0.actual == nil })
        // onPace is still projected even for a future period.
        XCTAssertTrue(points.allSatisfy { $0.onPace > 0 || $0.day == 0 })
    }

    func testExcludedEntriesDoNotAffectPace() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let excluded = TestSupport.makeEntry(
            amount: 1000, date: testDate(2025, 6, 1), type: .expense, wallet: wallet, excludeFromBudget: true
        )
        context.insert(wallet); context.insert(excluded)

        let points = BudgetCalculator.spendingPace(
            month: testDate(2025, 6, 1),
            entries: [excluded],
            settings: testSettings(),
            totalPlanned: 300,
            today: testDate(2025, 8, 1)
        )

        XCTAssertEqual(points.first { $0.day == 1 }?.actual, 0)
    }
}
