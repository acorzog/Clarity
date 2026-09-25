import XCTest
import SwiftData
@testable import FinanceTracker

private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
}

/// Mirrors `BudgetSettingsStore`'s actual defaults, matching `BudgetCalculatorTests`'/
/// `HomeCalculatorTests`' convention.
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

// MARK: - First-month / no-activity state

final class ExplainMyMonthNoActivityTests: XCTestCase {

    func testEmptyMonthProducesNoActivityWithEmptyFields() {
        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [], budgets: [], headCategories: [], settings: testSettings()
        )

        XCTAssertFalse(explanation.hasActivity)
        XCTAssertEqual(explanation.totalSpending, 0)
        XCTAssertNil(explanation.previousMonthComparison)
        XCTAssertTrue(explanation.notableCategoryChanges.isEmpty)
        XCTAssertNil(explanation.budgetPerformance)
        XCTAssertNil(explanation.positiveHighlight)
        XCTAssertNil(explanation.attentionArea)
    }
}

// MARK: - Total spending + previous-month comparison

final class ExplainMyMonthComparisonTests: XCTestCase {

    func testTotalSpendingReflectsBudgetEligibleExpensesOnly() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        context.insert(wallet); context.insert(head); context.insert(category)

        let expense = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        let excluded = TestSupport.makeEntry(amount: 500, date: testDate(2025, 6, 12), type: .expense, category: category, wallet: wallet, excludeFromBudget: true)
        context.insert(expense); context.insert(excluded)

        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [expense, excluded], budgets: [], headCategories: [head], settings: testSettings()
        )

        XCTAssertTrue(explanation.hasActivity)
        XCTAssertEqual(explanation.totalSpending, 150)
    }

    func testNoComparisonWhenPreviousMonthHasNoData() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let expense = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(expense)

        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [expense], budgets: [], headCategories: [head], settings: testSettings()
        )

        XCTAssertNil(explanation.previousMonthComparison)
        XCTAssertTrue(explanation.notableCategoryChanges.isEmpty, "no previous data means no per-category comparison either")
    }

    func testComparisonUpWhenSpendingIncreasedVsPreviousMonth() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let previous = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 10), type: .expense, category: category, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 130, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(previous); context.insert(current)

        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [previous, current], budgets: [], headCategories: [head], settings: testSettings()
        )

        let comparison = try XCTUnwrap(explanation.previousMonthComparison)
        XCTAssertEqual(comparison.previousTotal, 100)
        XCTAssertEqual(comparison.currentTotal, 130)
        XCTAssertEqual(comparison.direction, .up)
        XCTAssertEqual(comparison.fraction, 0.30, accuracy: 0.001)
    }

    func testComparisonDownWhenSpendingDecreasedVsPreviousMonth() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let previous = TestSupport.makeEntry(amount: 200, date: testDate(2025, 5, 10), type: .expense, category: category, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 100, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(previous); context.insert(current)

        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [previous, current], budgets: [], headCategories: [head], settings: testSettings()
        )

        let comparison = try XCTUnwrap(explanation.previousMonthComparison)
        XCTAssertEqual(comparison.direction, .down)
        XCTAssertEqual(comparison.fraction, -0.5, accuracy: 0.001)
    }
}

// MARK: - Notable category changes

final class ExplainMyMonthNotableChangesTests: XCTestCase {

    private func makeHeadAndCategory(name: String, in context: ModelContext) -> (HeadCategory, FinanceTracker.Category) {
        let head = TestSupport.makeHeadCategory(name: name)
        let category = TestSupport.makeCategory(name: name, headCategory: head)
        context.insert(head); context.insert(category)
        return (head, category)
    }

    func testChangeBelowThresholdIsExcluded() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let (head, category) = makeHeadAndCategory(name: "Groceries", in: context)
        let previous = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 10), type: .expense, category: category, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 105, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(previous); context.insert(current)

        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [previous, current], budgets: [], headCategories: [head], settings: testSettings()
        )

        XCTAssertTrue(explanation.notableCategoryChanges.isEmpty)
    }

    func testExcludedEntriesDoNotProduceASpuriousChange() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let (head, category) = makeHeadAndCategory(name: "Groceries", in: context)
        let previous = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 10), type: .expense, category: category, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 100, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        let excluded = TestSupport.makeEntry(amount: 500, date: testDate(2025, 6, 12), type: .expense, category: category, wallet: wallet, excludeFromBudget: true)
        context.insert(previous); context.insert(current); context.insert(excluded)

        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [previous, current, excluded], budgets: [], headCategories: [head], settings: testSettings()
        )

        XCTAssertTrue(explanation.notableCategoryChanges.isEmpty)
    }

    func testResultIsRankedByMagnitudeAndCappedAtMax() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        var heads: [HeadCategory] = []
        var entries: [Entry] = []

        // Five categories, each increasing by a different (all above-threshold) amount, so the
        // cap is exercised and not just incidentally satisfied by having exactly 3.
        let multipliers: [Decimal] = [1.2, 1.9, 1.3, 1.6, 1.4]
        for (index, multiplier) in multipliers.enumerated() {
            let (head, category) = makeHeadAndCategory(name: "Cat\(index)", in: context)
            heads.append(head)
            let previous = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 10), type: .expense, category: category, wallet: wallet)
            let current = TestSupport.makeEntry(amount: 100 * multiplier, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
            context.insert(previous); context.insert(current)
            entries.append(contentsOf: [previous, current])
        }

        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: entries, budgets: [], headCategories: heads, settings: testSettings()
        )

        XCTAssertEqual(ExplainMyMonthCalculator.maxNotableCategoryChanges, 3)
        XCTAssertEqual(explanation.notableCategoryChanges.count, 3)
        // Largest-first: 1.9 (Cat1), 1.6 (Cat3), 1.4 (Cat4).
        XCTAssertEqual(explanation.notableCategoryChanges.map(\.subject), ["Cat1", "Cat3", "Cat4"])
    }

    func testDecreaseIsFavorableIncreaseIsNot() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let (upHead, upCategory) = makeHeadAndCategory(name: "Shopping", in: context)
        let (downHead, downCategory) = makeHeadAndCategory(name: "Transport", in: context)

        let upPrevious = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 10), type: .expense, category: upCategory, wallet: wallet)
        let upCurrent = TestSupport.makeEntry(amount: 160, date: testDate(2025, 6, 10), type: .expense, category: upCategory, wallet: wallet)
        let downPrevious = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 12), type: .expense, category: downCategory, wallet: wallet)
        let downCurrent = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 12), type: .expense, category: downCategory, wallet: wallet)
        context.insert(upPrevious); context.insert(upCurrent); context.insert(downPrevious); context.insert(downCurrent)

        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [upPrevious, upCurrent, downPrevious, downCurrent],
            budgets: [], headCategories: [upHead, downHead], settings: testSettings()
        )

        let up = explanation.notableCategoryChanges.first { $0.subject == "Shopping" }
        let down = explanation.notableCategoryChanges.first { $0.subject == "Transport" }
        XCTAssertEqual(up?.isFavorable, false)
        XCTAssertEqual(down?.isFavorable, true)
    }
}

// MARK: - Budget performance

final class ExplainMyMonthBudgetPerformanceTests: XCTestCase {

    func testNilWhenNothingIsBudgeted() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let expense = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(expense)

        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [expense], budgets: [], headCategories: [head], settings: testSettings()
        )

        XCTAssertNil(explanation.budgetPerformance)
    }

    func testOverBudgetStateAndListedCategory() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 6, year: 2025)
        let expense = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(expense)

        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [expense], budgets: [budget], headCategories: [head], settings: testSettings()
        )

        let performance = try XCTUnwrap(explanation.budgetPerformance)
        XCTAssertEqual(performance.spent, 150)
        XCTAssertEqual(performance.budgeted, 100)
        XCTAssertEqual(performance.state, .overBudget)
        XCTAssertEqual(performance.overBudgetCategories.map(\.category.name), ["Dining"])
    }

    func testOnTrackStateWithNoOverBudgetCategories() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 6, year: 2025)
        let expense = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(expense)

        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [expense], budgets: [budget], headCategories: [head], settings: testSettings()
        )

        let performance = try XCTUnwrap(explanation.budgetPerformance)
        XCTAssertEqual(performance.state, .onTrack)
        XCTAssertTrue(performance.overBudgetCategories.isEmpty)
    }
}

// MARK: - Positive highlight

final class ExplainMyMonthPositiveHighlightTests: XCTestCase {

    func testTotalSpendingDownTakesPriority() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let previous = TestSupport.makeEntry(amount: 200, date: testDate(2025, 5, 10), type: .expense, category: category, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 100, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(previous); context.insert(current)

        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [previous, current], budgets: [], headCategories: [head], settings: testSettings()
        )

        let highlight = try XCTUnwrap(explanation.positiveHighlight)
        XCTAssertEqual(highlight.kind, .totalSpendingDown)
        XCTAssertEqual(highlight.magnitudeFraction ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(highlight.amount, 100)
    }

    func testWithinBudgetWhenNoDecreaseButNothingIsOverBudget() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 6, year: 2025)
        let expense = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(expense)

        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [expense], budgets: [budget], headCategories: [head], settings: testSettings()
        )

        let highlight = try XCTUnwrap(explanation.positiveHighlight)
        XCTAssertEqual(highlight.kind, .withinBudget)
    }

    func testNilWhenNothingPositiveIsSupportedByTheData() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 6, year: 2025)
        let expense = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(expense)

        // No previous-month data and the only budgeted category is over budget — nothing here
        // supports a positive claim, so the calculator must not invent one.
        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [expense], budgets: [budget], headCategories: [head], settings: testSettings()
        )

        XCTAssertNil(explanation.positiveHighlight)
    }

    /// The legitimate path this highlight exists for: a category genuinely down from last month,
    /// and (unlike the regression test below) not over its own budget — must still surface as
    /// `.categoryDecrease`, so the over-budget exclusion doesn't overreach into filtering out
    /// decreases that have nothing to be contradicted by.
    func testCategoryDecreaseIsSelectedWhenThatCategoryIsNotOverBudget() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let diningHead = TestSupport.makeHeadCategory(name: "Food")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: diningHead)
        // Budgeted, but this month's spend stays comfortably under it — decreasing AND on track.
        let diningBudget = TestSupport.makeBudget(category: dining, monthlyLimit: 200, month: 6, year: 2025)
        let diningPrevious = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 10), type: .expense, category: dining, wallet: wallet)
        let diningCurrent = TestSupport.makeEntry(amount: 70, date: testDate(2025, 6, 10), type: .expense, category: dining, wallet: wallet)

        let shoppingHead = TestSupport.makeHeadCategory(name: "Shopping")
        let shopping = TestSupport.makeCategory(name: "Shopping", headCategory: shoppingHead)
        let shoppingPrevious = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 12), type: .expense, category: shopping, wallet: wallet)
        let shoppingCurrent = TestSupport.makeEntry(amount: 140, date: testDate(2025, 6, 12), type: .expense, category: shopping, wallet: wallet)

        context.insert(diningHead); context.insert(dining); context.insert(diningBudget)
        context.insert(diningPrevious); context.insert(diningCurrent)
        context.insert(shoppingHead); context.insert(shopping)
        context.insert(shoppingPrevious); context.insert(shoppingCurrent)

        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [diningPrevious, diningCurrent, shoppingPrevious, shoppingCurrent],
            budgets: [diningBudget], headCategories: [diningHead, shoppingHead], settings: testSettings()
        )

        // Total went up overall (200 -> 210), so `totalSpendingDown` can't have fired instead.
        XCTAssertEqual(explanation.previousMonthComparison?.direction, .up)
        let highlight = try XCTUnwrap(explanation.positiveHighlight)
        XCTAssertEqual(highlight.kind, .categoryDecrease)
        XCTAssertEqual(highlight.subject, "Dining")
    }
}

// MARK: - Attention area

final class ExplainMyMonthAttentionAreaTests: XCTestCase {

    /// Regression: a category that decreased from last month but is *still* over its own budget
    /// this month must never be handed to `positiveHighlight` — otherwise the card would praise
    /// ("Dining is down 25% from last month") and flag ("Dining went $50 over its budget") the
    /// exact same category in two adjacent rows, contradicting itself. Shopping's bigger, but
    /// unbudgeted, increase exists purely so Dining's decrease is the sole positive candidate and
    /// so the overall month total isn't itself meaningfully down (which would short-circuit
    /// before the per-category check even runs).
    func testCategoryStillOverBudgetIsNeverThePositiveHighlightEvenIfItDecreased() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let diningHead = TestSupport.makeHeadCategory(name: "Food")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: diningHead)
        let diningBudget = TestSupport.makeBudget(category: dining, monthlyLimit: 100, month: 6, year: 2025)
        let diningPrevious = TestSupport.makeEntry(amount: 200, date: testDate(2025, 5, 10), type: .expense, category: dining, wallet: wallet)
        let diningCurrent = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: dining, wallet: wallet)

        let shoppingHead = TestSupport.makeHeadCategory(name: "Shopping")
        let shopping = TestSupport.makeCategory(name: "Shopping", headCategory: shoppingHead)
        let shoppingPrevious = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 12), type: .expense, category: shopping, wallet: wallet)
        let shoppingCurrent = TestSupport.makeEntry(amount: 160, date: testDate(2025, 6, 12), type: .expense, category: shopping, wallet: wallet)

        context.insert(diningHead); context.insert(dining); context.insert(diningBudget)
        context.insert(diningPrevious); context.insert(diningCurrent)
        context.insert(shoppingHead); context.insert(shopping)
        context.insert(shoppingPrevious); context.insert(shoppingCurrent)

        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [diningPrevious, diningCurrent, shoppingPrevious, shoppingCurrent],
            budgets: [diningBudget], headCategories: [diningHead, shoppingHead], settings: testSettings()
        )

        // Dining is excluded as a positive candidate (still over budget); nothing else qualifies
        // (Shopping is unfavorable, and the month overall isn't "within budget" — Dining IS over)
        // so there is honestly nothing positive to say, rather than a misleading substitute claim.
        XCTAssertNil(explanation.positiveHighlight)
        XCTAssertEqual(explanation.attentionArea?.kind, .overBudgetCategory)
        XCTAssertEqual(explanation.attentionArea?.subject, "Dining")
    }

    func testOverBudgetCategoryTakesPriority() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 6, year: 2025)
        let expense = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(expense)

        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [expense], budgets: [budget], headCategories: [head], settings: testSettings()
        )

        let attention = try XCTUnwrap(explanation.attentionArea)
        XCTAssertEqual(attention.kind, .overBudgetCategory)
        XCTAssertEqual(attention.subject, "Dining")
        XCTAssertEqual(attention.amount, 50)
    }

    func testAheadOfPaceWhenNoCategoryIsOverBudgetYet() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        // 300 planned over a 30-day June => 10/day pace; by day 10, onPace = 100. Spending 200
        // by then is ahead of pace, but the category itself isn't over its own budget yet.
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 300, month: 6, year: 2025)
        let expense = TestSupport.makeEntry(amount: 200, date: testDate(2025, 6, 5), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(expense)

        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [expense], budgets: [budget], headCategories: [head],
            settings: testSettings(), today: testDate(2025, 6, 10)
        )

        let attention = try XCTUnwrap(explanation.attentionArea)
        XCTAssertEqual(attention.kind, .aheadOfPace)
    }

    func testCategoryIncreaseFallbackWhenNoBudgetAtAll() throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Shopping")
        let category = TestSupport.makeCategory(name: "Shopping", headCategory: head)
        let previous = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 10), type: .expense, category: category, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 160, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(previous); context.insert(current)

        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [previous, current], budgets: [], headCategories: [head], settings: testSettings()
        )

        let attention = try XCTUnwrap(explanation.attentionArea)
        XCTAssertEqual(attention.kind, .categoryIncrease)
        XCTAssertEqual(attention.subject, "Shopping")
    }

    func testNilWhenNothingNeedsAttention() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let expense = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(expense)

        let explanation = ExplainMyMonthCalculator.explain(
            month: testDate(2025, 6, 1), entries: [expense], budgets: [], headCategories: [head], settings: testSettings()
        )

        XCTAssertNil(explanation.attentionArea)
    }
}
