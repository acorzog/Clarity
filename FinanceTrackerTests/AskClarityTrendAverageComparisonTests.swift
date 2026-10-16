import XCTest
import SwiftData
@testable import FinanceTracker

private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
}

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

private let today = testDate(2025, 6, 20)

private func makePoint(_ label: String, _ amount: Decimal) -> (period: AskClarityPeriod, amount: Decimal) {
    (period: AskClarityPeriod(kind: .specificMonth(testDate(2025, 1, 1)), label: label), amount: amount)
}

// MARK: - AskClarityTrendAverageComparison (pure calculator)

final class AskClarityTrendAverageComparisonCalculatorTests: XCTestCase {
    func testComputesAverageAbsoluteAndPercentDifferenceForAHigherCurrentAmount() {
        let points = [makePoint("May 2025", 100), makePoint("April 2025", 100), makePoint("March 2025", 100)]
        guard let result = AskClarityTrendAverageComparison.compute(currentAmount: 300, currentPeriodLabel: "June 2025", historicalPoints: points) else {
            return XCTFail("three historical points should be enough to compute an average")
        }
        XCTAssertEqual(result.average, 100)
        XCTAssertEqual(result.periodsAveraged, 3)
        XCTAssertEqual(result.absoluteDifference, 200)
        XCTAssertTrue(result.isHigher)
        XCTAssertEqual(result.percentDifference ?? .nan, 2.0, accuracy: 0.0001, "300 is 200% above a 100 average")
    }

    func testComputesALowerCurrentAmountCorrectly() {
        let points = [makePoint("May 2025", 100), makePoint("April 2025", 100)]
        guard let result = AskClarityTrendAverageComparison.compute(currentAmount: 50, currentPeriodLabel: "June 2025", historicalPoints: points) else {
            return XCTFail("two historical points should be enough")
        }
        XCTAssertFalse(result.isHigher)
        XCTAssertEqual(result.absoluteDifference, 50)
        XCTAssertEqual(result.percentDifference ?? .nan, -0.5, accuracy: 0.0001)
    }

    /// The current period's own point, if present in `historicalPoints` (as it is when fed the
    /// raw output of `.trend`), must never be averaged into its own baseline.
    func testExcludesAPointMatchingTheCurrentPeriodLabelFromTheAverage() {
        let points = [makePoint("June 2025", 999), makePoint("May 2025", 100), makePoint("April 2025", 100)]
        guard let result = AskClarityTrendAverageComparison.compute(currentAmount: 300, currentPeriodLabel: "June 2025", historicalPoints: points) else {
            return XCTFail("should still compute from the two remaining points")
        }
        XCTAssertEqual(result.periodsAveraged, 2)
        XCTAssertEqual(result.average, 100)
    }

    func testFewerThanTheMinimumHistoricalPointsReturnsNil() {
        let points = [makePoint("May 2025", 100)]
        XCTAssertNil(AskClarityTrendAverageComparison.compute(currentAmount: 300, currentPeriodLabel: "June 2025", historicalPoints: points))
    }

    func testZeroHistoricalPointsReturnsNil() {
        XCTAssertNil(AskClarityTrendAverageComparison.compute(currentAmount: 300, currentPeriodLabel: "June 2025", historicalPoints: []))
    }

    /// Every historical period logged exactly nothing — a real, honest zero average, never a
    /// fabricated percentage (division by zero).
    func testZeroAverageNeverProducesAPercentDifference() {
        let points = [makePoint("May 2025", 0), makePoint("April 2025", 0)]
        guard let result = AskClarityTrendAverageComparison.compute(currentAmount: 50, currentPeriodLabel: "June 2025", historicalPoints: points) else {
            return XCTFail("should still compute an average (zero) from two zero points")
        }
        XCTAssertEqual(result.average, 0)
        XCTAssertNil(result.percentDifference, "a percentage deviation from a zero average is undefined and must never be fabricated")
        XCTAssertEqual(result.absoluteDifference, 50)
        XCTAssertTrue(result.isHigher)
    }

    /// `minimumPeriods` is a parameter, not a hardcoded constant — callers (the deterministic
    /// path and the semantic-fallback composition) can require more history before averaging.
    func testCustomMinimumPeriodsIsRespected() {
        let points = [makePoint("May 2025", 100), makePoint("April 2025", 100), makePoint("March 2025", 100)]
        XCTAssertNotNil(AskClarityTrendAverageComparison.compute(currentAmount: 100, currentPeriodLabel: "June 2025", historicalPoints: points, minimumPeriods: 3))
        XCTAssertNil(AskClarityTrendAverageComparison.compute(currentAmount: 100, currentPeriodLabel: "June 2025", historicalPoints: points, minimumPeriods: 4))
    }

    func testExactlyEqualCurrentAndAverageIsNeitherHigherNorFlaggedAsAnError() {
        let points = [makePoint("May 2025", 100), makePoint("April 2025", 100)]
        guard let result = AskClarityTrendAverageComparison.compute(currentAmount: 100, currentPeriodLabel: "June 2025", historicalPoints: points) else {
            return XCTFail("should compute")
        }
        XCTAssertFalse(result.isHigher)
        XCTAssertEqual(result.absoluteDifference, 0)
        XCTAssertEqual(result.percentDifference ?? .nan, 0, accuracy: 0.0001)
    }

    /// A single historical point is exactly what "the average of the last 2 periods" implies
    /// (current + 1 prior) — the window the question actually asked for must be honored, not
    /// rejected just because a larger, unrelated constant happened to require more.
    func testExactlyOneHistoricalPointSucceedsWhenThatIsWhatWasRequested() {
        let points = [makePoint("May 2025", 100)]
        guard let result = AskClarityTrendAverageComparison.compute(currentAmount: 150, currentPeriodLabel: "June 2025", historicalPoints: points, minimumPeriods: 1) else {
            return XCTFail("exactly one historical point must be enough when only one was required")
        }
        XCTAssertEqual(result.periodsAveraged, 1)
        XCTAssertEqual(result.average, 100)
    }

    /// `.remainingBudget` (and any other metric that can legitimately be negative) must never
    /// have its percentage direction flipped just because the *average* happens to be negative —
    /// dividing by the raw (possibly negative) average, rather than its magnitude, would invert
    /// the sign relationship here.
    func testNegativeAverageNeverInvertsTheSignOfThePercentDifference() {
        // Historically over budget by 50 on average; this period is comfortably positive (10).
        let points = [makePoint("May 2025", -50), makePoint("April 2025", -50)]
        guard let result = AskClarityTrendAverageComparison.compute(currentAmount: 10, currentPeriodLabel: "June 2025", historicalPoints: points) else {
            return XCTFail("should compute even with a negative average")
        }
        XCTAssertEqual(result.average, -50)
        XCTAssertTrue(result.isHigher, "10 is higher than -50")
        guard let percent = result.percentDifference else {
            return XCTFail("average is -50, not zero, so a percentage must be reported")
        }
        XCTAssertGreaterThan(percent, 0, "a higher current amount must always report a positive percent difference, matching isHigher, regardless of the average's own sign")
    }

    /// The mirror image of the above: a lower current amount against a negative average must
    /// report a *negative* percentage, never flipped positive by the sign of the average.
    func testNegativeAverageWithALowerCurrentAmountReportsANegativePercent() {
        let points = [makePoint("May 2025", -10), makePoint("April 2025", -10)]
        guard let result = AskClarityTrendAverageComparison.compute(currentAmount: -50, currentPeriodLabel: "June 2025", historicalPoints: points) else {
            return XCTFail("should compute even with a negative average")
        }
        XCTAssertFalse(result.isHigher, "-50 is lower than -10")
        guard let percent = result.percentDifference else {
            return XCTFail("average is -10, not zero, so a percentage must be reported")
        }
        XCTAssertLessThan(percent, 0, "a lower current amount must always report a negative percent difference, matching isHigher's false value")
    }
}

// MARK: - Interpreter: the new "average comparison" signal

final class AskClarityInterpreterAverageComparisonTests: XCTestCase {
    private func interpret(_ text: String, categories: [FinanceTracker.Category] = []) -> AskClarityQuery? {
        AskClarityInterpreter.interpret(text, categories: categories, context: .empty, today: today)
    }

    func testAverageWordCombinedWithAnExplicitSpanSetsWantsAverageComparison() {
        guard let query = interpret("Compare my dining spending to the average of the last 6 months") else {
            return XCTFail("should interpret")
        }
        XCTAssertTrue(query.wantsAverageComparison)
        XCTAssertTrue(query.wantsTrend)
        XCTAssertEqual(query.trendSpan, 6)
    }

    func testUsualTypicalAndNormalAllTriggerTheSameSignal() {
        for word in ["usual", "typical", "normal"] {
            guard let query = interpret("Is this \(word) for groceries over the last 4 months") else {
                return XCTFail("should interpret \"\(word)\"")
            }
            XCTAssertTrue(query.wantsAverageComparison, "\"\(word)\" should trigger the average-comparison signal")
        }
    }

    /// The word "average" alone, with no trend/span cue anywhere in the question, has no chain to
    /// average over — must never set the flag just because the word appeared.
    func testAverageWordAloneWithNoTrendCueDoesNotSetTheFlag() {
        guard let query = interpret("What's my average spending?") else {
            return XCTFail("should still interpret as a plain spending question")
        }
        XCTAssertFalse(query.wantsAverageComparison)
    }

    /// Existing questions must keep behaving exactly as before: a plain trend/span request with
    /// no "average"/"usual"/"typical"/"normal" wording must never set the new flag.
    func testPlainTrendRequestWithoutAnAverageWordNeverSetsTheFlag() {
        guard let query = interpret("What's my spending trend over the last 6 months?") else {
            return XCTFail("should interpret")
        }
        XCTAssertTrue(query.wantsTrend)
        XCTAssertFalse(query.wantsAverageComparison)
    }

    func testBareTrendCueWordCombinedWithAverageAlsoSetsTheFlag() {
        guard let query = interpret("How does my spending trend compare to average?") else {
            return XCTFail("should interpret")
        }
        XCTAssertTrue(query.wantsTrend)
        XCTAssertTrue(query.wantsAverageComparison)
    }
}

// MARK: - Planner: the new operation

final class AskClarityPlannerAverageComparisonTests: XCTestCase {
    func testQueryWithAverageComparisonPlansTheNewOperation() {
        var query = AskClarityQuery()
        query.metric = .spending
        query.wantsTrend = true
        query.wantsAverageComparison = true
        query.trendSpan = 6

        guard case .plan(let plan) = AskClarityPlanner.plan(for: query, context: .empty, today: today) else {
            return XCTFail("should produce a plan")
        }
        XCTAssertEqual(plan.operation, .trendAverageComparison)
        XCTAssertEqual(plan.trendSpan, 6)
    }

    /// A category-resolution problem must still be caught before the new operation is ever
    /// planned — never bypassing the existing never-guess rule for an ambiguous/missing category.
    func testCategoryNotFoundIsStillCaughtBeforeAverageComparisonPlanning() {
        var query = AskClarityQuery()
        query.wantsTrend = true
        query.wantsAverageComparison = true
        query.categoryMatch = .notFound(phrase: "zzz")

        guard case .categoryNotFound = AskClarityPlanner.plan(for: query, context: .empty, today: today) else {
            return XCTFail("a not-found category must still short-circuit before the new operation")
        }
    }
}

// MARK: - Engine: end-to-end deterministic "compared to my average" answers

final class AskClarityEngineAverageComparisonTests: XCTestCase {
    /// The canonical motivating question: a clear, large deviation for a specific category.
    func testCategoryComparedToSixMonthAverageReportsAbsoluteAndPercentDeviation() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        var entries: [Entry] = []
        for monthOffset in 1...5 {
            let date = Calendar.current.date(byAdding: .month, value: -monthOffset, to: testDate(2025, 6, 15))!
            entries.append(TestSupport.makeEntry(amount: 100, date: date, type: .expense, category: dining, wallet: wallet))
        }
        entries.append(TestSupport.makeEntry(amount: 300, date: testDate(2025, 6, 10), type: .expense, category: dining, wallet: wallet))
        context.insert(wallet); context.insert(head); context.insert(dining)
        entries.forEach { context.insert($0) }

        let result = AskClarityEngine.respond(
            to: "Compare my Dining spending to the average of the last 6 months", context: .empty, entries: entries,
            budgets: [], headCategories: [head], settings: testSettings(), today: testDate(2025, 6, 20)
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("300"), result.answer.headline)
        XCTAssertTrue(result.answer.headline.contains("Dining"), result.answer.headline)
        XCTAssertTrue(result.answer.supportingDetail.contains("200"), result.answer.supportingDetail) // absolute diff
        XCTAssertTrue(result.answer.supportingDetail.contains("100"), result.answer.supportingDetail) // average
        XCTAssertTrue(result.answer.supportingDetail.contains("200%"), result.answer.supportingDetail) // percent diff
        XCTAssertTrue(result.answer.supportingDetail.contains("more"), result.answer.supportingDetail)
        XCTAssertEqual(result.answer.comparisonIsFavorable, false, "spending more than usual is unfavorable")
    }

    /// No category named at all — a plain total-spending comparison, proving the operation also
    /// composes with the categoryless/plain-metric path (`AskClarityPlanner`'s own `query.metric`
    /// default), not only a category subject.
    func testPlainTotalSpendingComparedToItsOwnAverage() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        var entries: [Entry] = []
        for monthOffset in 1...3 {
            let date = Calendar.current.date(byAdding: .month, value: -monthOffset, to: testDate(2025, 6, 15))!
            entries.append(TestSupport.makeEntry(amount: 200, date: date, type: .expense, category: dining, wallet: wallet))
        }
        entries.append(TestSupport.makeEntry(amount: 50, date: testDate(2025, 6, 10), type: .expense, category: dining, wallet: wallet))
        context.insert(wallet); context.insert(head); context.insert(dining)
        entries.forEach { context.insert($0) }

        let result = AskClarityEngine.respond(
            to: "How does my spending compare to my average over the last 3 months", context: .empty, entries: entries,
            budgets: [], headCategories: [head], settings: testSettings(), today: testDate(2025, 6, 20)
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("50"), result.answer.headline)
        XCTAssertTrue(result.answer.supportingDetail.contains("150"), result.answer.supportingDetail) // |50-200|
        XCTAssertTrue(result.answer.supportingDetail.contains("200"), result.answer.supportingDetail) // average
        XCTAssertTrue(result.answer.supportingDetail.contains("less"), result.answer.supportingDetail)
        XCTAssertEqual(result.answer.comparisonIsFavorable, true, "spending less than usual is favorable")
    }

    /// A smaller window (3 months) and a larger one (6 months) over the exact same data must
    /// average a different number of periods and can legitimately report a different average.
    func testDifferentWindowSizesAverageADifferentNumberOfPeriods() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        // Recent 3 months average 200; the 3 months before that average 50 — so a 3-month window
        // and a 6-month window must disagree about the average.
        var entries: [Entry] = []
        for monthOffset in 1...3 {
            let date = Calendar.current.date(byAdding: .month, value: -monthOffset, to: testDate(2025, 6, 15))!
            entries.append(TestSupport.makeEntry(amount: 200, date: date, type: .expense, category: dining, wallet: wallet))
        }
        for monthOffset in 4...6 {
            let date = Calendar.current.date(byAdding: .month, value: -monthOffset, to: testDate(2025, 6, 15))!
            entries.append(TestSupport.makeEntry(amount: 50, date: date, type: .expense, category: dining, wallet: wallet))
        }
        entries.append(TestSupport.makeEntry(amount: 200, date: testDate(2025, 6, 10), type: .expense, category: dining, wallet: wallet))
        context.insert(wallet); context.insert(head); context.insert(dining)
        entries.forEach { context.insert($0) }

        let threeMonthResult = AskClarityEngine.respond(
            to: "Compare my Dining spending to the average of the last 3 months", context: .empty, entries: entries,
            budgets: [], headCategories: [head], settings: testSettings(), today: testDate(2025, 6, 20)
        )
        let sevenMonthResult = AskClarityEngine.respond(
            to: "Compare my Dining spending to the average of the last 7 months", context: .empty, entries: entries,
            budgets: [], headCategories: [head], settings: testSettings(), today: testDate(2025, 6, 20)
        )

        // 3-month window: current (200) vs. average of the 2 months immediately before (200 each) -> exactly the average, 0% deviation.
        XCTAssertTrue(threeMonthResult.answer.supportingDetail.contains("0%"), threeMonthResult.answer.supportingDetail)
        // 7-month window: current (200) vs. average of the 6 months before (200,200,200,50,50,50 -> average 125) -> a real, different deviation (60%).
        XCTAssertTrue(sevenMonthResult.answer.supportingDetail.contains("60%"), sevenMonthResult.answer.supportingDetail)
        XCTAssertNotEqual(threeMonthResult.answer.supportingDetail, sevenMonthResult.answer.supportingDetail, "a different window size must average a different set of periods")
    }

    /// Every historical month logged nothing at all for this category — a real zero average,
    /// reported with its own clear sentence, never a fabricated percentage.
    func testZeroHistoricalAverageIsReportedClearlyWithoutAPercentage() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let newCategory = TestSupport.makeCategory(name: "Skydiving", headCategory: head)
        let entry = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: newCategory, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(newCategory); context.insert(entry)

        let result = AskClarityEngine.respond(
            to: "Compare my Skydiving spending to the average of the last 4 months", context: .empty, entries: [entry],
            budgets: [], headCategories: [head], settings: testSettings(), today: testDate(2025, 6, 20)
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("150"), result.answer.headline)
        XCTAssertTrue(result.answer.supportingDetail.contains("no"), result.answer.supportingDetail)
        XCTAssertFalse(result.answer.supportingDetail.contains("%"), "a zero average must never produce a fabricated percentage: \(result.answer.supportingDetail)")
    }

    /// A week-based window can only ever chain back one step — asking for an average anchored on
    /// an already-previous period leaves no history at all to average, and that must be reported
    /// plainly rather than guessed at.
    func testInsufficientHistoryIsReportedClearlyWithoutAPercentage() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let entry = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 14), type: .expense, category: dining, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(dining); context.insert(entry)

        let result = AskClarityEngine.respond(
            to: "What's my usual Dining spending trend last week?", context: .empty, entries: [entry],
            budgets: [], headCategories: [head], settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.supportingDetail.lowercased().contains("enough history"), result.answer.supportingDetail)
        XCTAssertFalse(result.answer.supportingDetail.contains("%"), "insufficient history must never produce a fabricated percentage: \(result.answer.supportingDetail)")
    }

    /// The trend chain must cross a year boundary the exact same way plain `.trend` already does
    /// (`AskClarityPeriodKind.specificMonth.previousEquivalent`) — proving the comparison uses the
    /// same equivalent-period chain, not a second, independent one.
    func testChainCorrectlyCrossesAYearBoundary() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        // "Today" is February 2025 — a 4-month window must reach back into November/December 2024.
        let novemberDate = testDate(2024, 11, 15)
        let decemberDate = testDate(2024, 12, 15)
        let januaryDate = testDate(2025, 1, 15)
        let februaryDate = testDate(2025, 2, 10)
        let november = TestSupport.makeEntry(amount: 10, date: novemberDate, type: .expense, category: dining, wallet: wallet)
        let december = TestSupport.makeEntry(amount: 20, date: decemberDate, type: .expense, category: dining, wallet: wallet)
        let january = TestSupport.makeEntry(amount: 30, date: januaryDate, type: .expense, category: dining, wallet: wallet)
        let february = TestSupport.makeEntry(amount: 120, date: februaryDate, type: .expense, category: dining, wallet: wallet)
        let entries = [november, december, january, february]
        context.insert(wallet); context.insert(head); context.insert(dining)
        entries.forEach { context.insert($0) }

        let result = AskClarityEngine.respond(
            to: "Compare my Dining spending to the average of the last 4 months", context: .empty, entries: entries,
            budgets: [], headCategories: [head], settings: testSettings(), today: testDate(2025, 2, 20)
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("120"), result.answer.headline)
        // Average of 10, 20, 30 = 20.
        XCTAssertTrue(result.answer.supportingDetail.contains(Decimal(20).currencyFormatted), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains(Decimal(100).currencyFormatted), result.answer.supportingDetail) // |120-20|
    }

    /// A plain trend-list question (no "average"/"usual"/"typical"/"normal" wording) must still
    /// answer exactly as it always has — this capability is purely additive.
    func testExistingPlainTrendQuestionIsUnaffected() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let april = TestSupport.makeEntry(amount: 50, date: testDate(2025, 4, 15), type: .expense, category: dining, wallet: wallet)
        let may = TestSupport.makeEntry(amount: 80, date: testDate(2025, 5, 15), type: .expense, category: dining, wallet: wallet)
        let june = TestSupport.makeEntry(amount: 120, date: testDate(2025, 6, 10), type: .expense, category: dining, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(dining)
        context.insert(april); context.insert(may); context.insert(june)

        let result = AskClarityEngine.respond(
            to: "What's my Dining spending trend the last 3 months?", context: .empty, entries: [april, may, june],
            budgets: [], headCategories: [head], settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.lowercased().contains("trend"), result.answer.headline)
        XCTAssertTrue(result.answer.supportingDetail.contains("50"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("80"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("120"), result.answer.supportingDetail)
    }

    /// "The last 2 months" is the minimum valid window — it implies exactly one historical
    /// period (this month plus the one right before it), and that one period is exactly what's
    /// available here. Must succeed, not be rejected as "insufficient history."
    func testExactlyTheRequestedTwoMonthWindowSucceedsWithOnlyOneHistoricalPeriod() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let may = TestSupport.makeEntry(amount: 80, date: testDate(2025, 5, 15), type: .expense, category: dining, wallet: wallet)
        let june = TestSupport.makeEntry(amount: 120, date: testDate(2025, 6, 10), type: .expense, category: dining, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(dining); context.insert(may); context.insert(june)

        let result = AskClarityEngine.respond(
            to: "Compare my Dining spending to the average of the last 2 months", context: .empty, entries: [may, june],
            budgets: [], headCategories: [head], settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertFalse(result.answer.supportingDetail.lowercased().contains("enough history"), "exactly the requested 2-month window (1 historical period) was available: \(result.answer.supportingDetail)")
        XCTAssertTrue(result.answer.supportingDetail.contains("80"), result.answer.supportingDetail) // the single historical period's own amount is the average
        XCTAssertTrue(result.answer.supportingDetail.contains("40"), result.answer.supportingDetail) // |120-80|
        XCTAssertTrue(result.answer.supportingDetail.contains("more"), result.answer.supportingDetail)
    }

    /// A week-based window can only ever chain back one step, regardless of how large a span is
    /// requested — the "insufficient history" message must state how many periods *this specific
    /// question* actually required (3, for "the last 4 weeks"), never a generic, unrelated number.
    func testInsufficientHistoryMessageStatesTheActuallyRequiredCountForTheWindowAsked() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let entry = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 14), type: .expense, category: dining, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(dining); context.insert(entry)

        let result = AskClarityEngine.respond(
            to: "What's my usual Dining spending trend over the last 4 weeks?", context: .empty, entries: [entry],
            budgets: [], headCategories: [head], settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.supportingDetail.contains("at least 3"), result.answer.supportingDetail)
        XCTAssertFalse(result.answer.supportingDetail.contains("at least 2"), "the old, unrelated fixed minimum must never appear once the required count is derived from the actual request: \(result.answer.supportingDetail)")
        XCTAssertFalse(result.answer.supportingDetail.contains("%"), result.answer.supportingDetail)
    }

    /// The decrease direction, specifically combined with a chain that crosses a year boundary —
    /// proving sign and equivalent-period chaining both hold together, not just each in isolation.
    func testDecreaseDirectionHoldsAcrossAYearBoundary() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let november = TestSupport.makeEntry(amount: 200, date: testDate(2024, 11, 15), type: .expense, category: dining, wallet: wallet)
        let december = TestSupport.makeEntry(amount: 200, date: testDate(2024, 12, 15), type: .expense, category: dining, wallet: wallet)
        let january = TestSupport.makeEntry(amount: 200, date: testDate(2025, 1, 15), type: .expense, category: dining, wallet: wallet)
        let february = TestSupport.makeEntry(amount: 20, date: testDate(2025, 2, 10), type: .expense, category: dining, wallet: wallet)
        let entries = [november, december, january, february]
        context.insert(wallet); context.insert(head); context.insert(dining)
        entries.forEach { context.insert($0) }

        let result = AskClarityEngine.respond(
            to: "Compare my Dining spending to the average of the last 4 months", context: .empty, entries: entries,
            budgets: [], headCategories: [head], settings: testSettings(), today: testDate(2025, 2, 20)
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("20"), result.answer.headline)
        XCTAssertTrue(result.answer.supportingDetail.contains("180"), result.answer.supportingDetail) // |20-200|
        XCTAssertTrue(result.answer.supportingDetail.contains("less"), result.answer.supportingDetail)
        XCTAssertEqual(result.answer.comparisonIsFavorable, true, "spending less than usual is favorable")
    }
}
