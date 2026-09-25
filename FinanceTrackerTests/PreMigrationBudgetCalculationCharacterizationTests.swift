import XCTest
import SwiftData
@testable import FinanceTracker

/// Characterization tests for the budget/spending formulas as they existed **before** Phase 1's
/// `BudgetCalculator` migration — see `CLARITY_PHASE_0_AUDIT.md` (Section 10/12/13) and
/// `CLARITY_PHASE_1_CALCULATION_PROPOSAL.md` (Section 2/9).
///
/// These are frozen, faithful reproductions of the *old* private view logic (`RemainingView`,
/// `InsightsView`), not calls into production code — those properties were `private` and have
/// since been replaced by `BudgetCalculator` calls. This file exists purely as a documented
/// "before" record so a reviewer can see exactly what changed and why, per each scenario. It is
/// not exercised by the shipping app and should not be updated to match new behavior — its whole
/// purpose is to stay frozen.
///
/// Where a scenario's old result differs from `BudgetCalculatorTests`' new result for the same
/// inputs, the difference is one of the six inconsistencies Phase 0/1 documented and Phase 1
/// deliberately fixed (excludeFromBudget, hidden categories, or calendar-month-vs-cycle scoping).
final class PreMigrationBudgetCalculationCharacterizationTests: XCTestCase {

    private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - Old RemainingView formula (verbatim reproduction, pre-Phase-1)

    /// Reproduces `RemainingView`'s pre-migration `totalSpent`/`totalAvailable`/`totalBudgeted`
    /// exactly as it read on disk before this phase: entries scoped by `inBudgetPeriod`, but with
    /// **no** `excludeFromBudget` filtering and **no** hidden-category filtering — both are the
    /// bugs this phase fixes.
    private func oldRemainingTotals(
        month: Date,
        entries: [Entry],
        budgets: [Budget],
        headCategories: [HeadCategory],
        cycleStartDay: Int,
        manualMonthlyBudget: Decimal,
        includeUnplannedAsOtherExpenses: Bool,
        includeSavingsTransfers: Bool,
        includeDebtTransfers: Bool
    ) -> (totalBudgeted: Decimal, totalSpent: Decimal, totalAvailable: Decimal) {
        let periodEntries = entries.inBudgetPeriod(month, startDay: cycleStartDay)
        let monthExpenses = periodEntries.filter { $0.type == .expense }
        let monthTransfers = periodEntries.filter { $0.type == .transfer }

        func expenseCategories(for head: HeadCategory) -> [FinanceTracker.Category] {
            head.categories.filter { !$0.isIncome && !$0.isArchived }
        }
        func budgeted(for category: FinanceTracker.Category) -> Decimal {
            budgets.amount(for: category, month: month) // no isHidden check, old behavior
        }

        let totalBudgeted = headCategories.flatMap(expenseCategories).reduce(Decimal(0)) { $0 + budgeted(for: $1) }
        let totalIncome = periodEntries.filter { $0.type == .income }.reduce(Decimal(0)) { $0 + $1.amount }

        let otherExpensesTotal = monthExpenses
            .filter { entry in
                guard let category = entry.category else { return true }
                return budgeted(for: category) == 0
            }
            .reduce(Decimal(0)) { $0 + $1.amount }
        let savingsTransfersTotal = monthTransfers.filter { $0.destinationWallet?.type == .savings }.reduce(Decimal(0)) { $0 + $1.amount }
        let debtTransfersTotal = monthTransfers.filter { $0.destinationWallet?.type == .debt }.reduce(Decimal(0)) { $0 + $1.amount }

        var totalSpent = monthExpenses.reduce(Decimal(0)) { $0 + $1.amount }
        if !includeUnplannedAsOtherExpenses { totalSpent -= otherExpensesTotal }
        if includeSavingsTransfers { totalSpent += savingsTransfersTotal }
        if includeDebtTransfers { totalSpent += debtTransfersTotal }

        let totalAvailable: Decimal
        if manualMonthlyBudget > 0 {
            totalAvailable = manualMonthlyBudget
        } else {
            totalAvailable = totalIncome > 0 ? totalIncome : totalBudgeted
        }

        return (totalBudgeted, totalSpent, totalAvailable)
    }

    // MARK: - Old InsightsView formula (verbatim reproduction, pre-Phase-1)

    /// Reproduces `InsightsView`'s pre-migration `totalPlannedExpenses`/`monthExpenses`: scoped
    /// by plain calendar month (`inMonth`, never the configurable cycle), with no
    /// `excludeFromBudget` filtering and no hidden-category filtering.
    private func oldInsightsTotals(
        month: Date,
        entries: [Entry],
        budgets: [Budget]
    ) -> (totalPlannedExpenses: Decimal, actualExpenses: Decimal) {
        let (m, y) = month.monthYearComponents
        let totalPlannedExpenses = budgets
            .filter { $0.month == m && $0.year == y && !$0.category.isIncome }
            .reduce(Decimal(0)) { $0 + $1.monthlyLimit }
        let monthExpenses = entries.inMonth(month).filter { $0.type == .expense }
        let actualExpenses = monthExpenses.reduce(Decimal(0)) { $0 + $1.amount }
        return (totalPlannedExpenses, actualExpenses)
    }

    // MARK: - Scenarios (mirrors the 10 required in the Phase 1 proposal/instructions)

    func testBudgetedCategoryWithSpending() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 6, year: 2025)
        let expense = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 5), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(expense)

        let totals = oldRemainingTotals(
            month: testDate(2025, 6, 1), entries: [expense], budgets: [budget], headCategories: [head],
            cycleStartDay: 1, manualMonthlyBudget: 0,
            includeUnplannedAsOtherExpenses: true, includeSavingsTransfers: false, includeDebtTransfers: true
        )

        XCTAssertEqual(totals.totalBudgeted, 100)
        XCTAssertEqual(totals.totalSpent, 40)
    }

    func testCategoryOverBudget() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 50, month: 6, year: 2025)
        let expense = TestSupport.makeEntry(amount: 80, date: testDate(2025, 6, 5), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(expense)

        let totals = oldRemainingTotals(
            month: testDate(2025, 6, 1), entries: [expense], budgets: [budget], headCategories: [head],
            cycleStartDay: 1, manualMonthlyBudget: 0,
            includeUnplannedAsOtherExpenses: true, includeSavingsTransfers: false, includeDebtTransfers: true
        )

        XCTAssertEqual(totals.totalSpent, 80)
        XCTAssertGreaterThan(totals.totalSpent, totals.totalBudgeted)
    }

    func testCategoryWithoutBudgetFallsIntoOther() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(name: "Misc", headCategory: head)
        let expense = TestSupport.makeEntry(amount: 25, date: testDate(2025, 6, 5), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(expense)

        let totals = oldRemainingTotals(
            month: testDate(2025, 6, 1), entries: [expense], budgets: [], headCategories: [head],
            cycleStartDay: 1, manualMonthlyBudget: 0,
            includeUnplannedAsOtherExpenses: true, includeSavingsTransfers: false, includeDebtTransfers: true
        )

        XCTAssertEqual(totals.totalSpent, 25) // counted as "Other," included by default
    }

    /// **Pre-Phase-1 behavior:** a hidden category's budget still fully counts toward
    /// `totalBudgeted` — this is the bug Phase 1 fixes via `respectHiddenCategories`. Compare
    /// against `BudgetCalculatorPeriodSpendingSummaryTests.testHiddenCategoryContributesNothingWhenRespected`.
    func testHiddenCategoryStillCountedBeforeThisPhase() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(name: "Subscriptions", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 50, month: 6, year: 2025, isHidden: true)
        let expense = TestSupport.makeEntry(amount: 20, date: testDate(2025, 6, 5), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(expense)

        let totals = oldRemainingTotals(
            month: testDate(2025, 6, 1), entries: [expense], budgets: [budget], headCategories: [head],
            cycleStartDay: 1, manualMonthlyBudget: 0,
            includeUnplannedAsOtherExpenses: true, includeSavingsTransfers: false, includeDebtTransfers: true
        )

        XCTAssertEqual(totals.totalBudgeted, 50) // old: hidden still counted (new: 0, see BudgetCalculatorTests)
    }

    func testSavingsTransferOldDefaultBehaviorExcludedFromSpent() {
        let context = TestSupport.makeInMemoryContext()
        let source = TestSupport.makeWallet(name: "Spending")
        let savings = TestSupport.makeWallet(name: "Savings", type: .savings)
        let head = TestSupport.makeHeadCategory()
        let transfer = TestSupport.makeEntry(amount: 100, date: testDate(2025, 6, 5), type: .transfer, wallet: source, destinationWallet: savings)
        context.insert(source); context.insert(savings); context.insert(head); context.insert(transfer)

        let totals = oldRemainingTotals(
            month: testDate(2025, 6, 1), entries: [transfer], budgets: [], headCategories: [head],
            cycleStartDay: 1, manualMonthlyBudget: 0,
            includeUnplannedAsOtherExpenses: true, includeSavingsTransfers: false, includeDebtTransfers: true
        )

        XCTAssertEqual(totals.totalSpent, 0) // matches new behavior — this default was never buggy
    }

    func testDebtTransferOldDefaultBehaviorIncludedInSpent() {
        let context = TestSupport.makeInMemoryContext()
        let source = TestSupport.makeWallet(name: "Spending")
        let debt = TestSupport.makeWallet(name: "Credit Card", type: .debt)
        let head = TestSupport.makeHeadCategory()
        let transfer = TestSupport.makeEntry(amount: 75, date: testDate(2025, 6, 5), type: .transfer, wallet: source, destinationWallet: debt)
        context.insert(source); context.insert(debt); context.insert(head); context.insert(transfer)

        let totals = oldRemainingTotals(
            month: testDate(2025, 6, 1), entries: [transfer], budgets: [], headCategories: [head],
            cycleStartDay: 1, manualMonthlyBudget: 0,
            includeUnplannedAsOtherExpenses: true, includeSavingsTransfers: false, includeDebtTransfers: true
        )

        XCTAssertEqual(totals.totalSpent, 75) // matches new behavior — this default was never buggy
    }

    /// **Pre-Phase-1 behavior:** an excluded expense still fully counted toward `totalSpent` —
    /// the core bug this phase fixes. Compare against
    /// `BudgetCalculatorPeriodSpendingSummaryTests.testExcludedExpenseNeverContributesToSpending`.
    func testExcludedExpenseStillCountedBeforeThisPhase() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        let category = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 6, year: 2025)
        let excludedExpense = TestSupport.makeEntry(
            amount: 40, date: testDate(2025, 6, 5), type: .expense, category: category, wallet: wallet, excludeFromBudget: true
        )
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(excludedExpense)

        let totals = oldRemainingTotals(
            month: testDate(2025, 6, 1), entries: [excludedExpense], budgets: [budget], headCategories: [head],
            cycleStartDay: 1, manualMonthlyBudget: 0,
            includeUnplannedAsOtherExpenses: true, includeSavingsTransfers: false, includeDebtTransfers: true
        )

        XCTAssertEqual(totals.totalSpent, 40) // old: still counted (new: 0)
    }

    /// **Pre-Phase-1 behavior:** an excluded income entry still inflated `totalAvailable` via the
    /// income fallback — the symmetric half of the same bug. Compare against
    /// `BudgetCalculatorPeriodSpendingSummaryTests.testExcludedIncomeNeverContributesToEligibleIncome`.
    func testExcludedIncomeStillInflatedAvailableBeforeThisPhase() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        let excludedIncome = TestSupport.makeEntry(
            amount: 500, date: testDate(2025, 6, 5), type: .income, wallet: wallet, excludeFromBudget: true
        )
        context.insert(wallet); context.insert(head); context.insert(excludedIncome)

        let totals = oldRemainingTotals(
            month: testDate(2025, 6, 1), entries: [excludedIncome], budgets: [], headCategories: [head],
            cycleStartDay: 1, manualMonthlyBudget: 0,
            includeUnplannedAsOtherExpenses: true, includeSavingsTransfers: false, includeDebtTransfers: true
        )

        XCTAssertEqual(totals.totalAvailable, 500) // old: inflated by the excluded entry (new: 0)
    }

    func testManualMonthlyBudgetOverridesEverythingBothBeforeAndAfter() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        let income = TestSupport.makeEntry(amount: 5000, date: testDate(2025, 6, 5), type: .income, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(income)

        let totals = oldRemainingTotals(
            month: testDate(2025, 6, 1), entries: [income], budgets: [], headCategories: [head],
            cycleStartDay: 1, manualMonthlyBudget: 800,
            includeUnplannedAsOtherExpenses: true, includeSavingsTransfers: false, includeDebtTransfers: true
        )

        XCTAssertEqual(totals.totalAvailable, 800) // unaffected by either fix — never a bug
    }

    /// **Pre-Phase-1 behavior:** Insights scoped "this month" by the plain calendar month, never
    /// the configurable cycle — so it disagreed with Remaining whenever `cycleStartDay != 1`.
    /// Compare against `BudgetCalculatorPeriodSpendingSummaryTests.testNonDefaultCycleStartScopesEntriesToTheShiftedPeriodNotTheCalendarMonth`.
    ///
    /// Viewing "July" (month = July 1) with `cycleStartDay == 15`: `Date.budgetPeriod` resolves
    /// to the cycle window containing July 1, which is June 15 - July 15 (see
    /// `BudgetCalculatorTests`'s doc comment on the same scenario) — so a June-dated entry can
    /// legitimately fall inside "July's" cycle period even though it's outside July's calendar
    /// month.
    func testNonDefaultCycleStartDayInsightsDisagreedWithRemainingBeforeThisPhase() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory()
        // With cycleStartDay = 15, both June 20 and July 5 fall inside the cycle period that
        // "July" (July 1) resolves to: June 15 - July 15.
        let juneEntry = TestSupport.makeEntry(amount: 20, date: testDate(2025, 6, 20), type: .expense, wallet: wallet)
        let julyEntry = TestSupport.makeEntry(amount: 30, date: testDate(2025, 7, 5), type: .expense, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(juneEntry); context.insert(julyEntry)

        let remainingTotals = oldRemainingTotals(
            month: testDate(2025, 7, 1), entries: [juneEntry, julyEntry], budgets: [], headCategories: [head],
            cycleStartDay: 15, manualMonthlyBudget: 0,
            includeUnplannedAsOtherExpenses: true, includeSavingsTransfers: false, includeDebtTransfers: true
        )
        let insightsTotals = oldInsightsTotals(month: testDate(2025, 7, 1), entries: [juneEntry, julyEntry], budgets: [])

        // Remaining (cycle-scoped): both entries count, since both fall inside June 15 - July 15.
        XCTAssertEqual(remainingTotals.totalSpent, 50)
        // Insights (calendar-month-scoped): only the July-dated entry counts — a real disagreement.
        XCTAssertEqual(insightsTotals.actualExpenses, 30)
        XCTAssertNotEqual(remainingTotals.totalSpent, insightsTotals.actualExpenses)
    }
}
