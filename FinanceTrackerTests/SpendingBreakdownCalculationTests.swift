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

    // MARK: - Cross-surface consistency: Activity/Calendar-list stay raw, Calendar-total/Spending don't (9, 10, 11)
    //
    // The Money Calendar update deliberately split Calendar into two different eligibility
    // rules: its day *transaction list* (`CalendarView.entriesByDay`) stays raw like Activity —
    // an excludeFromBudget entry must still be visible/editable there — but its day *spend
    // total* (`CalendarView.dailySpending`) is now budget-eligible, matching Spending, per
    // `IMPLEMENTATION_LOG.md`'s Money Calendar entry ("Ensure totals respect the same financial
    // rules used elsewhere ... including excluded transactions where applicable").

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

    func testCalendarTransactionListRemainsRawAndIncludesExcludedTransactions() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let excluded = TestSupport.makeEntry(amount: 75, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet, excludeFromBudget: true)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(excluded)

        // `CalendarView.entriesByDay`'s exact population — `allEntries.inMonth(month)`, no
        // `.budgetEligible` — this is what `DayEntriesView`'s transaction list is built from.
        let dayEntries = [excluded].inMonth(testDate(2025, 6, 1))

        XCTAssertTrue(dayEntries.contains { $0 === excluded }, "Calendar's day transaction list must keep showing an excludeFromBudget entry")
    }

    func testCalendarDailySpendingTotalExcludesExcludedTransactions() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let excluded = TestSupport.makeEntry(amount: 75, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet, excludeFromBudget: true)
        let normal = TestSupport.makeEntry(amount: 20, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(excluded); context.insert(normal)

        // `CalendarView.dailySpending`'s exact formula — `.budgetEligible.filter { $0.type ==
        // .expense }.totalExpenses`, unlike the raw transaction list above.
        let dailySpending = [excluded, normal].inMonth(testDate(2025, 6, 1)).budgetEligible.filter { $0.type == .expense }.totalExpenses

        XCTAssertEqual(dailySpending, 20, "Calendar's daily spending total must exclude an excludeFromBudget entry, matching Spending")
    }

    func testExcludedTransactionAppearsInActivityAndCalendarListButNotInCalendarOrSpendingTotals() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let excluded = TestSupport.makeEntry(amount: 120, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet, excludeFromBudget: true)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(excluded)

        // Activity and Calendar's transaction list (both raw): the entry is present.
        let rawEntries = [excluded].inMonth(testDate(2025, 6, 1))
        XCTAssertTrue(rawEntries.contains { $0 === excluded })

        // Calendar's daily spend total (budget-eligible, like Spending): the entry contributes nothing.
        let dailySpending = rawEntries.budgetEligible.filter { $0.type == .expense }.totalExpenses
        XCTAssertEqual(dailySpending, 0)

        // Spending (budget analysis, via BudgetCalculator): the entry contributes nothing.
        let spendingSummary = BudgetCalculator.periodSpendingSummary(
            month: testDate(2025, 6, 1), entries: [excluded], budgets: [], headCategories: [head],
            settings: testSettings(cycleStartDay: 1), respectHiddenCategories: true
        )
        XCTAssertEqual(spendingSummary.byCategory.first { $0.category === category }?.actual ?? 0, 0)

        // This divergence (list stays raw, totals don't) is intentional — not a bug to reconcile.
    }

    // MARK: - Money Calendar: day boundaries, income/transfer-only days, and DayEntriesView's own formula

    /// An entry on the last instant of the previous month, and one on the first day of the next,
    /// must never leak into `dailySpending`'s grouping for the month in between — `entriesByDay`/
    /// `dailySpending` are both built from `monthEntries = allEntries.inMonth(month)` first, so a
    /// boundary leak here would mean the whole calendar grid, not just one cell.
    func testMonthBoundaryEntriesDoNotLeakIntoTheAdjacentMonthsDailyTotals() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let lastDayOfMay = TestSupport.makeEntry(amount: 30, date: testDate(2025, 5, 31), type: .expense, category: category, wallet: wallet)
        let firstDayOfJuly = TestSupport.makeEntry(amount: 40, date: testDate(2025, 7, 1), type: .expense, category: category, wallet: wallet)
        let insideJune = TestSupport.makeEntry(amount: 10, date: testDate(2025, 6, 15), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category)
        context.insert(lastDayOfMay); context.insert(firstDayOfJuly); context.insert(insideJune)

        let allEntries = [lastDayOfMay, firstDayOfJuly, insideJune]
        // `CalendarView.monthEntries`'s exact expression.
        let juneEntries = allEntries.inMonth(testDate(2025, 6, 1))

        XCTAssertEqual(juneEntries.count, 1, "only the entry actually dated in June should be in June's entriesByDay/dailySpending")
        XCTAssertTrue(juneEntries.contains { $0 === insideJune })
        XCTAssertFalse(juneEntries.contains { $0 === lastDayOfMay })
        XCTAssertFalse(juneEntries.contains { $0 === firstDayOfJuly })
    }

    /// A day with only income logged must be entirely absent from `dailySpending` (not present
    /// with a `0`) while still appearing, income entry included, in the raw day transaction list —
    /// exercising `dailySpending`'s `type == .expense` filter specifically, not just `.budgetEligible`.
    func testIncomeOnlyDayIsAbsentFromDailySpendingButPresentInTheDayEntryList() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Income")
        let category = TestSupport.makeCategory(name: "Salary", isIncome: true, headCategory: head)
        let income = TestSupport.makeEntry(amount: 2000, date: testDate(2025, 6, 5), type: .income, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(income)

        let monthEntries = [income].inMonth(testDate(2025, 6, 1))
        // `CalendarView.entriesByDay`: every entry for the day, unfiltered.
        XCTAssertTrue(monthEntries.contains { $0 === income }, "the day's raw transaction list must still include an income-only day's entry")

        // `CalendarView.dailySpending`: budget-eligible expenses only.
        let daySpending = monthEntries.budgetEligible.filter { $0.type == .expense }.totalExpenses
        XCTAssertEqual(daySpending, 0, "an income-only day contributes nothing to dailySpending")
    }

    /// Same shape as the income-only case, for a transfer between wallets: it must not read as
    /// "spending" for the day even though it's a real, visible transaction.
    func testTransferOnlyDayIsAbsentFromDailySpendingButPresentInTheDayEntryList() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let destination = TestSupport.makeWallet(name: "Savings")
        let transfer = TestSupport.makeEntry(amount: 300, date: testDate(2025, 6, 12), type: .transfer, wallet: wallet, destinationWallet: destination)
        context.insert(wallet); context.insert(destination); context.insert(transfer)

        let monthEntries = [transfer].inMonth(testDate(2025, 6, 1))
        XCTAssertTrue(monthEntries.contains { $0 === transfer })

        let daySpending = monthEntries.budgetEligible.filter { $0.type == .expense }.totalExpenses
        XCTAssertEqual(daySpending, 0, "a transfer-only day contributes nothing to dailySpending")
    }

    /// `DayEntriesView.daySpent`'s own exact formula (`entries.budgetEligible.totalExpenses`),
    /// pinned directly rather than only inferred from `CalendarView.dailySpending`'s equivalence —
    /// a day mixing a normal expense, an excluded expense, income, and a transfer all together,
    /// the mix most likely to reveal the two views' formulas silently drifting apart.
    func testDayEntriesViewSpentFormulaMatchesCalendarDailySpendingOnAMixedDay() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let destination = TestSupport.makeWallet(name: "Savings")
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let normal = TestSupport.makeEntry(amount: 25, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        let excluded = TestSupport.makeEntry(amount: 999, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet, excludeFromBudget: true)
        let income = TestSupport.makeEntry(amount: 500, date: testDate(2025, 6, 10), type: .income, wallet: wallet)
        let transfer = TestSupport.makeEntry(amount: 100, date: testDate(2025, 6, 10), type: .transfer, wallet: wallet, destinationWallet: destination)
        context.insert(wallet); context.insert(destination); context.insert(head); context.insert(category)
        context.insert(normal); context.insert(excluded); context.insert(income); context.insert(transfer)

        let dayEntries = [normal, excluded, income, transfer]

        // `CalendarView.dailySpending`'s formula for this one day.
        let calendarDailySpending = dayEntries.budgetEligible.filter { $0.type == .expense }.totalExpenses
        // `DayEntriesView.daySpent`'s formula, given the exact same day's entries.
        let daySpent = dayEntries.budgetEligible.totalExpenses

        XCTAssertEqual(calendarDailySpending, 25)
        XCTAssertEqual(daySpent, 25, "DayEntriesView's own total formula must land on the same figure the calendar cell showed for this day")
        XCTAssertEqual(calendarDailySpending, daySpent)

        // The list itself stays raw — all four entries, including the excluded/income/transfer
        // ones the total above doesn't count — visible and available to edit.
        XCTAssertEqual(Set(dayEntries.map { $0.persistentModelID }), Set([normal, excluded, income, transfer].map { $0.persistentModelID }))
    }
}
