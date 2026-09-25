import XCTest
import SwiftData
@testable import FinanceTracker

private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
}

/// `today` anchors every test at June 20, 2025 — mid-month, so `-7`/`-14`/`-44`-day windows never
/// cross a year boundary and stay easy to reason about. Expected scores/factors below were cross-
/// checked against an independent Python port of `ClarityScoreCalculator`'s exact arithmetic
/// (window boundaries, clamping, and round-half-away-from-zero), not hand-derived, since the
/// trailing-30-day "typical week" window can overlap the prior anchor's own previous-week window
/// once the anchor shifts back 7 days — see `testTrendUpWhenScoreImprovesFromWeekAgo`.
final class ClarityScoreCalculatorTests: XCTestCase {
    private let today = testDate(2025, 6, 20)

    private func makeBudgetSetup(in context: ModelContext, monthlyLimit: Decimal) -> (wallet: Wallet, budget: Budget) {
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: monthlyLimit, month: 6, year: 2025)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget)
        return (wallet, budget)
    }

    // MARK: - Minimum data guard

    func testNoDataAtAllReturnsNilScore() {
        let result = ClarityScoreCalculator.clarityScore(entries: [], budgets: [], headCategories: [], today: today)

        XCTAssertNil(result.score)
        XCTAssertEqual(result.trend, .notEnoughHistory)
        XCTAssertNil(result.pointsChange)
        XCTAssertTrue(result.factors.isEmpty)
    }

    func testExcludedAndIncomeEntriesAreIgnoredEntirely() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)

        // A large excluded expense and a large income entry, both in the recent week — neither
        // should count toward spend, so this must behave identically to having no data at all.
        let excluded = TestSupport.makeEntry(amount: 500, date: testDate(2025, 6, 15), type: .expense, wallet: wallet, excludeFromBudget: true)
        let income = TestSupport.makeEntry(amount: 1000, date: testDate(2025, 6, 15), type: .income, wallet: wallet)
        context.insert(excluded); context.insert(income)

        let result = ClarityScoreCalculator.clarityScore(entries: [excluded, income], budgets: [], headCategories: [], today: today)

        XCTAssertNil(result.score)
        XCTAssertEqual(result.trend, .notEnoughHistory)
    }

    // MARK: - Individual factors

    func testBudgetPaceFactorWhenOverBudget() {
        let context = TestSupport.makeInMemoryContext()
        let (wallet, budget) = makeBudgetSetup(in: context, monthlyLimit: 300) // 300/30 days * 7 = 70/week
        // 50% over the 70/week pace.
        let expense = TestSupport.makeEntry(amount: 105, date: testDate(2025, 6, 15), type: .expense, wallet: wallet)
        context.insert(expense)

        let result = ClarityScoreCalculator.clarityScore(entries: [expense], budgets: [budget], headCategories: [budget.category.headCategory], today: today)

        XCTAssertEqual(result.score, 57)
        let factor = result.factors.first { $0.kind == .budgetPace }
        XCTAssertEqual(factor?.isFavorable, false)
        XCTAssertEqual(factor?.magnitudeFraction ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(factor?.impact, -13)
    }

    func testBudgetPaceFactorWhenUnderBudget() {
        let context = TestSupport.makeInMemoryContext()
        let (wallet, budget) = makeBudgetSetup(in: context, monthlyLimit: 300)
        // 50% under the 70/week pace.
        let expense = TestSupport.makeEntry(amount: 35, date: testDate(2025, 6, 15), type: .expense, wallet: wallet)
        context.insert(expense)

        let result = ClarityScoreCalculator.clarityScore(entries: [expense], budgets: [budget], headCategories: [budget.category.headCategory], today: today)

        XCTAssertEqual(result.score, 83)
        let factor = result.factors.first { $0.kind == .budgetPace }
        XCTAssertEqual(factor?.isFavorable, true)
        XCTAssertEqual(factor?.impact, 13)
    }

    func testPreviousWeekFactorWhenNoBudgetOrOlderHistoryExists() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)

        let recent = TestSupport.makeEntry(amount: 50, date: testDate(2025, 6, 15), type: .expense, wallet: wallet) // recent week
        let previous = TestSupport.makeEntry(amount: 200, date: testDate(2025, 6, 10), type: .expense, wallet: wallet) // previous week
        context.insert(recent); context.insert(previous)

        let result = ClarityScoreCalculator.clarityScore(entries: [recent, previous], budgets: [], headCategories: [], today: today)

        XCTAssertEqual(result.score, 82)
        XCTAssertEqual(result.factors.count, 1)
        let factor = result.factors.first { $0.kind == .previousWeek }
        XCTAssertEqual(factor?.isFavorable, true)
        // (50-200)/200 = -0.75, clamped to -0.6.
        XCTAssertEqual(factor?.magnitudeFraction ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(factor?.impact, 12)
    }

    func testTypicalWeekFactorWhenOnlyOlderHistoryExists() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)

        let recent = TestSupport.makeEntry(amount: 105, date: testDate(2025, 6, 15), type: .expense, wallet: wallet) // recent week
        let older = TestSupport.makeEntry(amount: 300, date: testDate(2025, 5, 20), type: .expense, wallet: wallet) // typical window
        context.insert(recent); context.insert(older)

        let result = ClarityScoreCalculator.clarityScore(entries: [recent, older], budgets: [], headCategories: [], today: today)

        XCTAssertEqual(result.score, 62)
        XCTAssertEqual(result.factors.count, 1)
        let factor = result.factors.first { $0.kind == .typicalWeek }
        XCTAssertEqual(factor?.isFavorable, false)
        XCTAssertEqual(factor?.magnitudeFraction ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(factor?.impact, -8)
    }

    func testMonthOverMonthFactorWhenSpendingUpFromSamePointLastMonth() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)

        // `today` is June 20, so "month-to-date" is June 1-20 (19 elapsed days), compared against
        // May 1 through the same 19-day offset (May 20, exclusive). May 5 is deliberately before
        // the trailing-30-day "typical week" window (which starts May 7), so this factor is
        // isolated from `typicalWeek` rather than both triggering off the same entry.
        let recent = TestSupport.makeEntry(amount: 300, date: testDate(2025, 6, 15), type: .expense, wallet: wallet) // in month-to-date
        let sameSpanLastMonth = TestSupport.makeEntry(amount: 200, date: testDate(2025, 5, 5), type: .expense, wallet: wallet) // in last month's matching span
        context.insert(recent); context.insert(sameSpanLastMonth)

        let result = ClarityScoreCalculator.clarityScore(entries: [recent, sameSpanLastMonth], budgets: [], headCategories: [], today: today)

        XCTAssertEqual(result.factors.count, 1)
        let factor = result.factors.first { $0.kind == .monthOverMonth }
        XCTAssertEqual(factor?.isFavorable, false)
        // (300-200)/200 = 0.5
        XCTAssertEqual(factor?.magnitudeFraction ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(factor?.impact, -8) // -(0.5 * 15).rounded()
        XCTAssertEqual(result.score, 62)
    }

    func testMonthOverMonthFactorWhenSpendingDownFromSamePointLastMonth() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)

        let recent = TestSupport.makeEntry(amount: 100, date: testDate(2025, 6, 15), type: .expense, wallet: wallet)
        let sameSpanLastMonth = TestSupport.makeEntry(amount: 200, date: testDate(2025, 5, 5), type: .expense, wallet: wallet)
        context.insert(recent); context.insert(sameSpanLastMonth)

        let result = ClarityScoreCalculator.clarityScore(entries: [recent, sameSpanLastMonth], budgets: [], headCategories: [], today: today)

        let factor = result.factors.first { $0.kind == .monthOverMonth }
        XCTAssertEqual(factor?.isFavorable, true)
        XCTAssertEqual(factor?.impact, 8) // (100-200)/200 = -0.5, impact = +(0.5*15).rounded()
    }

    /// Spend that falls *after* the matching day-offset last month must not count — otherwise an
    /// early-month comparison would unfairly include all of last month's spend, not just the
    /// portion comparable to how far into this month `today` is.
    func testMonthOverMonthFactorExcludesSpendAfterTheMatchingDayOffsetLastMonth() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)

        // `today` is June 20 (19 elapsed days into June), so the comparable last-month window is
        // May 1 through May 20 (exclusive). This entry falls on May 25 — outside that window —
        // so it must not be picked up by the month-over-month comparison at all.
        let recent = TestSupport.makeEntry(amount: 100, date: testDate(2025, 6, 15), type: .expense, wallet: wallet)
        let outsideWindow = TestSupport.makeEntry(amount: 500, date: testDate(2025, 5, 25), type: .expense, wallet: wallet)
        context.insert(recent); context.insert(outsideWindow)

        let result = ClarityScoreCalculator.clarityScore(entries: [recent, outsideWindow], budgets: [], headCategories: [], today: today)

        XCTAssertNil(result.factors.first { $0.kind == .monthOverMonth }, "spend outside the matching day-offset window shouldn't feed the comparison")
    }

    func testMonthOverMonthFactorSkippedWhenNoDataAtTheMatchingPointLastMonth() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)

        let recent = TestSupport.makeEntry(amount: 100, date: testDate(2025, 6, 15), type: .expense, wallet: wallet)
        context.insert(recent)

        let result = ClarityScoreCalculator.clarityScore(entries: [recent], budgets: [], headCategories: [], today: today)

        XCTAssertNil(result.factors.first { $0.kind == .monthOverMonth })
    }

    func testAllThreeFactorsAreRankedByImpactMagnitudeDescending() {
        let context = TestSupport.makeInMemoryContext()
        let (wallet, budget) = makeBudgetSetup(in: context, monthlyLimit: 300)
        let recent = TestSupport.makeEntry(amount: 35, date: testDate(2025, 6, 15), type: .expense, wallet: wallet)
        let previousWeek = TestSupport.makeEntry(amount: 50, date: testDate(2025, 6, 10), type: .expense, wallet: wallet)
        let typicalWeek = TestSupport.makeEntry(amount: 140, date: testDate(2025, 5, 20), type: .expense, wallet: wallet)
        context.insert(recent); context.insert(previousWeek); context.insert(typicalWeek)

        let result = ClarityScoreCalculator.clarityScore(
            entries: [recent, previousWeek, typicalWeek], budgets: [budget], headCategories: [budget.category.headCategory], today: today
        )

        XCTAssertEqual(result.score, 88)
        XCTAssertLessThanOrEqual(result.factors.count, ClarityScoreCalculator.maxFactors)
        XCTAssertEqual(result.factors.map(\.kind), [.budgetPace, .previousWeek, .typicalWeek])
        XCTAssertEqual(result.factors.map(\.impact), [13, 6, -1])
    }

    // MARK: - Trend (compared to the same calculation one week earlier)

    func testTrendUpWhenScoreImprovesFromWeekAgo() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)

        // Weekly spend trending down: 100 (three weeks ago) -> 200 (two weeks ago) -> 50 (this
        // week). The "two weeks ago" entry also falls inside today's 30-day typical-week window
        // (which reaches back 44 days), so today's score reflects both a favorable previous-week
        // comparison AND an unfavorable typical-week one — this is intentional overlap between
        // windows at different anchors, not a bug (see the class doc comment).
        let e1 = TestSupport.makeEntry(amount: 50, date: testDate(2025, 6, 15), type: .expense, wallet: wallet)
        let e2 = TestSupport.makeEntry(amount: 200, date: testDate(2025, 6, 10), type: .expense, wallet: wallet)
        let e3 = TestSupport.makeEntry(amount: 100, date: testDate(2025, 6, 1), type: .expense, wallet: wallet)
        context.insert(e1); context.insert(e2); context.insert(e3)

        let result = ClarityScoreCalculator.clarityScore(entries: [e1, e2, e3], budgets: [], headCategories: [], today: today)

        XCTAssertEqual(result.score, 73)
        XCTAssertEqual(result.trend, .up)
        XCTAssertEqual(result.pointsChange, 15)
        XCTAssertEqual(result.factors.map(\.kind), [.previousWeek, .typicalWeek])
    }

    func testTrendDownWhenScoreWorsensFromWeekAgo() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)

        let e1 = TestSupport.makeEntry(amount: 200, date: testDate(2025, 6, 15), type: .expense, wallet: wallet)
        let e2 = TestSupport.makeEntry(amount: 50, date: testDate(2025, 6, 10), type: .expense, wallet: wallet)
        let e3 = TestSupport.makeEntry(amount: 200, date: testDate(2025, 6, 1), type: .expense, wallet: wallet)
        context.insert(e1); context.insert(e2); context.insert(e3)

        let result = ClarityScoreCalculator.clarityScore(entries: [e1, e2, e3], budgets: [], headCategories: [], today: today)

        XCTAssertEqual(result.score, 49)
        XCTAssertEqual(result.trend, .down)
        XCTAssertEqual(result.pointsChange, -33)
    }

    func testTrendStableWhenWeekOverWeekBudgetPaceRepeats() {
        let context = TestSupport.makeInMemoryContext()
        let (wallet, budget) = makeBudgetSetup(in: context, monthlyLimit: 300)
        // Same 35 spent in both this week and the week before it, against the same budget pace —
        // the score a week ago and the score today must land on the exact same number.
        let recent = TestSupport.makeEntry(amount: 35, date: testDate(2025, 6, 15), type: .expense, wallet: wallet)
        let aWeekBefore = TestSupport.makeEntry(amount: 35, date: testDate(2025, 6, 8), type: .expense, wallet: wallet)
        context.insert(recent); context.insert(aWeekBefore)

        let result = ClarityScoreCalculator.clarityScore(
            entries: [recent, aWeekBefore], budgets: [budget], headCategories: [budget.category.headCategory], today: today
        )

        XCTAssertEqual(result.score, 83)
        XCTAssertEqual(result.trend, .stable)
        XCTAssertEqual(result.pointsChange, 0)
        // Stable doesn't mean "no factors" — it means the score didn't move, even though this one
        // does have a real (favorable) driver.
        XCTAssertEqual(result.factors.first?.kind, .budgetPace)
    }

    /// Regression: a budget alone must never manufacture a "previous week" data point out of a
    /// week where nothing was actually logged. Before this was fixed, a brand-new user with a
    /// budget already configured — spending exactly at pace in their first-ever week — saw the
    /// trend read as a -15 "down" (because the *prior* week, which has zero real entries, was
    /// treated as "70/70 = fully under budget" purely from the budget's existence), while the
    /// summary text simultaneously said "right in line with your usual pattern" since the current
    /// week had no contributing factors. Both a phantom trend and self-contradictory copy.
    func testNoPhantomTrendFromBudgetOnlyPreviousWeekWithNoActualHistory() {
        let context = TestSupport.makeInMemoryContext()
        let (wallet, budget) = makeBudgetSetup(in: context, monthlyLimit: 300) // 70/week pace
        // Only this week has any actual entries at all (brand-new user with a budget already
        // configured); this week's spend exactly matches the weekly pace, so it shouldn't move
        // the score either way.
        let expense = TestSupport.makeEntry(amount: 70, date: testDate(2025, 6, 15), type: .expense, wallet: wallet)
        context.insert(expense)

        let result = ClarityScoreCalculator.clarityScore(entries: [expense], budgets: [budget], headCategories: [budget.category.headCategory], today: today)

        XCTAssertEqual(result.score, 70)
        XCTAssertEqual(result.trend, .notEnoughHistory, "a week with zero logged entries isn't a real comparison baseline just because a budget exists")
        XCTAssertNil(result.pointsChange)
        XCTAssertTrue(result.factors.isEmpty)
    }

    func testNotEnoughHistoryWhenNoDataExistsFromAWeekAgo() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)

        // Only this week has any data at all — a brand-new user's first week.
        let expense = TestSupport.makeEntry(amount: 50, date: testDate(2025, 6, 15), type: .expense, wallet: wallet)
        context.insert(expense)

        let result = ClarityScoreCalculator.clarityScore(entries: [expense], budgets: [], headCategories: [], today: today)

        XCTAssertEqual(result.score, 70)
        XCTAssertEqual(result.trend, .notEnoughHistory)
        XCTAssertNil(result.pointsChange)
        XCTAssertTrue(result.factors.isEmpty, "no comparison baseline exists yet, so no factor should be invented")
    }
}
