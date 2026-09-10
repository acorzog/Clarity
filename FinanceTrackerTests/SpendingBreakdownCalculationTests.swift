import XCTest
import SwiftData
@testable import FinanceTracker

private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
}

/// Mirrors `BudgetSettingsStore`'s actual defaults, matching `BudgetCalculatorTests`' convention.
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

/// `SpendingBreakdownView`'s exact calculation contract (`Views/SpendingBreakdownView.swift`,
/// `calculationSettings`): always calls `BudgetCalculator.periodSpendingSummary` with
/// `cycleStartDay` forced to 1, regardless of the live `BudgetSettingsStore`'s configured Budget
/// Cycle — see `CLARITY_OVERVIEW_ACTIVITY_SPEC.md` §13/§23/§28's "Spending = calendar month,
/// never Budget Cycle" decision. These tests exercise `BudgetCalculator` under that exact
/// configuration rather than re-testing `BudgetCalculator`'s general behavior, which
/// `BudgetCalculatorTests.swift` already covers.
final class SpendingBreakdownCalculationTests: XCTestCase {

    // MARK: - excludeFromBudget / eligibility (1, 2)

    func testSpendingExcludesEntriesMarkedExcludeFromBudget() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let excluded = TestSupport.makeEntry(amount: 500, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet, excludeFromBudget: true)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(excluded)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1), entries: [excluded], budgets: [], headCategories: [head],
            settings: testSettings(cycleStartDay: 1), respectHiddenCategories: true
        )

        XCTAssertEqual(summary.byCategory.first { $0.category === category }?.actual ?? 0, 0)
    }

    func testSpendingIncludesEligibleExpenseEntries() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let eligible = TestSupport.makeEntry(amount: 45, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(eligible)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1), entries: [eligible], budgets: [], headCategories: [head],
            settings: testSettings(cycleStartDay: 1), respectHiddenCategories: true
        )

        XCTAssertEqual(summary.byCategory.first { $0.category === category }?.actual, 45)
    }

    // MARK: - Income / transfers ignored for expense category totals (3, 4)

    func testSpendingIgnoresIncomeForExpenseCategoryTotals() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Income")
        let incomeCategory = TestSupport.makeCategory(name: "Salary", isIncome: true, headCategory: head)
        let income = TestSupport.makeEntry(amount: 3000, date: testDate(2025, 6, 1), type: .income, category: incomeCategory, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(incomeCategory); context.insert(income)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1), entries: [income], budgets: [], headCategories: [head],
            settings: testSettings(cycleStartDay: 1), respectHiddenCategories: true
        )

        // Income categories never appear in byCategory at all (it's expense-categories-only).
        XCTAssertNil(summary.byCategory.first { $0.category === incomeCategory })
    }

    func testSpendingIgnoresTransfersForCategoryTotals() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let destination = TestSupport.makeWallet(name: "Savings")
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        // A transfer entry can still carry a category in the model; it must not count as spend.
        let transfer = TestSupport.makeEntry(amount: 200, date: testDate(2025, 6, 10), type: .transfer, category: category, wallet: wallet, destinationWallet: destination)
        context.insert(wallet); context.insert(destination); context.insert(head); context.insert(category); context.insert(transfer)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1), entries: [transfer], budgets: [], headCategories: [head],
            settings: testSettings(cycleStartDay: 1), respectHiddenCategories: true
        )

        XCTAssertEqual(summary.byCategory.first { $0.category === category }?.actual ?? 0, 0)
    }

    // MARK: - Category / head-category totals (5, 6)

    func testSpendingCategoryTotalsSumOnlyTheirOwnCategory() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let diningEntry1 = TestSupport.makeEntry(amount: 30, date: testDate(2025, 6, 5), type: .expense, category: dining, wallet: wallet)
        let diningEntry2 = TestSupport.makeEntry(amount: 20, date: testDate(2025, 6, 15), type: .expense, category: dining, wallet: wallet)
        let groceriesEntry = TestSupport.makeEntry(amount: 60, date: testDate(2025, 6, 8), type: .expense, category: groceries, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(dining); context.insert(groceries)
        context.insert(diningEntry1); context.insert(diningEntry2); context.insert(groceriesEntry)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1), entries: [diningEntry1, diningEntry2, groceriesEntry], budgets: [], headCategories: [head],
            settings: testSettings(cycleStartDay: 1), respectHiddenCategories: true
        )

        XCTAssertEqual(summary.byCategory.first { $0.category === dining }?.actual, 50)
        XCTAssertEqual(summary.byCategory.first { $0.category === groceries }?.actual, 60)
    }

    func testSpendingHeadCategoryTotalsAggregateAcrossItsCategories() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let diningEntry = TestSupport.makeEntry(amount: 30, date: testDate(2025, 6, 5), type: .expense, category: dining, wallet: wallet)
        let groceriesEntry = TestSupport.makeEntry(amount: 60, date: testDate(2025, 6, 8), type: .expense, category: groceries, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(dining); context.insert(groceries)
        context.insert(diningEntry); context.insert(groceriesEntry)

        let summary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1), entries: [diningEntry, groceriesEntry], budgets: [], headCategories: [head],
            settings: testSettings(cycleStartDay: 1), respectHiddenCategories: true
        )

        XCTAssertEqual(summary.byHeadCategory.first { $0.headCategory === head }?.actual, 90)
    }

    // MARK: - Calendar month, never Budget Cycle (7, 8)

    /// An entry dated after a hypothetical mid-month Budget Cycle boundary — under
    /// `cycleStartDay: 15`, `June 20` falls *outside* the May15–June15 cycle window, but is
    /// still squarely inside calendar June. Spending's forced `cycleStartDay: 1` must include it.
    func testSpendingUsesCalendarMonthNotBudgetCycle() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let lateJuneEntry = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 20), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(lateJuneEntry)

        // Spending's exact configuration: cycleStartDay forced to 1.
        let spendingSummary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1), entries: [lateJuneEntry], budgets: [], headCategories: [head],
            settings: testSettings(cycleStartDay: 1), respectHiddenCategories: true
        )
        XCTAssertEqual(spendingSummary.byCategory.first { $0.category === category }?.actual, 40)

        // Contrast: a genuine Budget Cycle consumer (cycleStartDay: 15) would exclude this same
        // entry from the "June" period, since it falls after the May15–June15 window closes.
        let cycleSummary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1), entries: [lateJuneEntry], budgets: [], headCategories: [head],
            settings: testSettings(cycleStartDay: 15), respectHiddenCategories: true
        )
        XCTAssertEqual(cycleSummary.byCategory.first { $0.category === category }?.actual ?? 0, 0)
    }

    /// Proves the exact mechanism `SpendingBreakdownView.calculationSettings` uses: no matter
    /// what `cycleStartDay` the live `BudgetSettingsStore` is configured with, forcing it to 1
    /// before calling `periodSpendingSummary` yields the same, Budget-Cycle-independent result.
    func testNonDefaultBudgetCycleDoesNotChangeSpendingResult() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let entry = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 20), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(entry)

        func spendingResult(asIfUserConfiguredCycleStartDay userCycleStartDay: Int) -> Decimal {
            // Mirrors `SpendingBreakdownView.calculationSettings` exactly: start from "whatever
            // the user configured," then force cycleStartDay to 1.
            var settings = testSettings(cycleStartDay: userCycleStartDay)
            settings.cycleStartDay = 1
            let summary = BudgetCalculator.periodSpendingSummary(
                month: testDate(2025, 6, 1), entries: [entry], budgets: [], headCategories: [head],
                settings: settings, respectHiddenCategories: true
            )
            return summary.byCategory.first { $0.category === category }?.actual ?? 0
        }

        XCTAssertEqual(spendingResult(asIfUserConfiguredCycleStartDay: 1), 40)
        XCTAssertEqual(spendingResult(asIfUserConfiguredCycleStartDay: 10), 40)
        XCTAssertEqual(spendingResult(asIfUserConfiguredCycleStartDay: 28), 40)
    }

    // MARK: - Cross-surface consistency: Activity/Calendar stay raw, Spending doesn't (9, 10, 11)

    func testActivityRemainsRawAndIncludesExcludedTransactions() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let excluded = TestSupport.makeEntry(amount: 500, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet, excludeFromBudget: true)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(excluded)

        // `EntryListView`'s exact population — `allEntries.inMonth(month)`, no `.budgetEligible`.
        let activityEntries = [excluded].inMonth(testDate(2025, 6, 15))

        XCTAssertTrue(activityEntries.contains { $0 === excluded }, "Activity must keep showing an excludeFromBudget entry")
    }

    func testCalendarRemainsRawAndIncludesExcludedTransactions() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let excluded = TestSupport.makeEntry(amount: 75, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet, excludeFromBudget: true)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(excluded)

        // `CalendarView.dailyTotals`'s exact formula — unfiltered, expense subtracts from net.
        let calendarEntries = [excluded].inMonth(testDate(2025, 6, 1))
        let dailyNet = calendarEntries.reduce(Decimal(0)) { total, entry in
            switch entry.type {
            case .income: total + entry.amount
            case .expense: total - entry.amount
            case .transfer: total
            }
        }

        XCTAssertEqual(dailyNet, -75, "Calendar's raw daily net must reflect an excludeFromBudget entry")
    }

    func testExcludedTransactionAppearsInActivityAndCalendarButNotInSpending() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let excluded = TestSupport.makeEntry(amount: 120, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet, excludeFromBudget: true)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(excluded)

        // Activity/Calendar (raw): the entry is present.
        let rawEntries = [excluded].inMonth(testDate(2025, 6, 1))
        XCTAssertTrue(rawEntries.contains { $0 === excluded })

        // Spending (budget analysis, via BudgetCalculator): the entry contributes nothing.
        let spendingSummary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1), entries: [excluded], budgets: [], headCategories: [head],
            settings: testSettings(cycleStartDay: 1), respectHiddenCategories: true
        )
        XCTAssertEqual(spendingSummary.byCategory.first { $0.category === category }?.actual ?? 0, 0)

        // This divergence is intentional — not a bug to reconcile. See
        // CLARITY_OVERVIEW_ACTIVITY_SPEC.md §26 "Cross-surface consistency."
    }
}
