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

// MARK: - What's Different?

final class HomeCalculatorWhatsDifferentTests: XCTestCase {

    func testCategoryIncreaseAboveThresholdProducesUpInsight() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        context.insert(wallet); context.insert(head); context.insert(category)

        let previous = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 10), type: .expense, category: category, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 130, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(previous); context.insert(current)

        let insights = HomeCalculator.whatsDifferentInsights(
            month: testDate(2025, 6, 1), entries: [previous, current], budgets: [], headCategories: [head], settings: testSettings()
        )

        let categoryInsight = insights.first { $0.kind == .categoryChange }
        XCTAssertNotNil(categoryInsight)
        XCTAssertEqual(categoryInsight?.subject, "Food")
        XCTAssertEqual(categoryInsight?.direction, .up)
        XCTAssertEqual(categoryInsight?.isFavorable, false)
        XCTAssertEqual(categoryInsight?.magnitudeFraction ?? 0, 0.30, accuracy: 0.001)
    }

    func testCategoryDecreaseAboveThresholdProducesDownFavorableInsight() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        context.insert(wallet); context.insert(head); context.insert(category)

        let previous = TestSupport.makeEntry(amount: 200, date: testDate(2025, 5, 10), type: .expense, category: category, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 100, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(previous); context.insert(current)

        let insights = HomeCalculator.whatsDifferentInsights(
            month: testDate(2025, 6, 1), entries: [previous, current], budgets: [], headCategories: [head], settings: testSettings()
        )

        let categoryInsight = insights.first { $0.kind == .categoryChange }
        XCTAssertNotNil(categoryInsight)
        XCTAssertEqual(categoryInsight?.direction, .down)
        XCTAssertEqual(categoryInsight?.isFavorable, true)
        XCTAssertEqual(categoryInsight?.magnitudeFraction ?? 0, 0.5, accuracy: 0.001)
    }

    func testChangeBelowThresholdProducesNoInsight() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        context.insert(wallet); context.insert(head); context.insert(category)

        let previous = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 10), type: .expense, category: category, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 105, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(previous); context.insert(current)

        let insights = HomeCalculator.whatsDifferentInsights(
            month: testDate(2025, 6, 1), entries: [previous, current], budgets: [], headCategories: [head], settings: testSettings()
        )

        XCTAssertTrue(insights.isEmpty)
    }

    func testZeroOrMissingPreviousPeriodDataProducesNoCategoryInsight() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        context.insert(wallet); context.insert(head); context.insert(category)

        // No May entries at all for this category — insufficient history, not a 0% change.
        let current = TestSupport.makeEntry(amount: 50, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(current)

        let insights = HomeCalculator.whatsDifferentInsights(
            month: testDate(2025, 6, 1), entries: [current], budgets: [], headCategories: [head], settings: testSettings()
        )

        XCTAssertNil(insights.first { $0.kind == .categoryChange })
    }

    func testExcludedEntriesDoNotAffectCategoryComparison() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        context.insert(wallet); context.insert(head); context.insert(category)

        let previous = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 10), type: .expense, category: category, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 100, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        // A large excluded entry that must not move the budget-eligible comparison at all.
        let excluded = TestSupport.makeEntry(amount: 500, date: testDate(2025, 6, 12), type: .expense, category: category, wallet: wallet, excludeFromBudget: true)
        context.insert(previous); context.insert(current); context.insert(excluded)

        let insights = HomeCalculator.whatsDifferentInsights(
            month: testDate(2025, 6, 1), entries: [previous, current, excluded], budgets: [], headCategories: [head], settings: testSettings()
        )

        XCTAssertNil(insights.first { $0.kind == .categoryChange }, "an excludeFromBudget entry must never move a What's Different comparison")
    }

    func testOverPlanProducesWarningInsightIndependentOfPriorPeriod() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 100, month: 6, year: 2025)
        let expense = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(expense)

        let insights = HomeCalculator.whatsDifferentInsights(
            month: testDate(2025, 6, 1), entries: [expense], budgets: [budget], headCategories: [head], settings: testSettings()
        )

        let overPlan = insights.first { $0.kind == .overPlan }
        XCTAssertNotNil(overPlan)
        XCTAssertEqual(overPlan?.severity, .warning)
        XCTAssertEqual(overPlan?.isFavorable, false)
    }

    func testOverPaceProducesCautionInsightWhenAheadOfStraightLinePace() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        // 300 planned over a 30-day June => 10/day pace; by day 10, onPace = 100.
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 300, month: 6, year: 2025)
        let expense = TestSupport.makeEntry(amount: 200, date: testDate(2025, 6, 5), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(expense)

        let insights = HomeCalculator.whatsDifferentInsights(
            month: testDate(2025, 6, 1), entries: [expense], budgets: [budget], headCategories: [head],
            settings: testSettings(), today: testDate(2025, 6, 10)
        )

        let pace = insights.first { $0.kind == .overPace }
        XCTAssertNotNil(pace)
        XCTAssertEqual(pace?.severity, .caution)
    }

    func testIncomeChangeAboveThresholdIsFavorableWhenUp() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Income")
        let previous = TestSupport.makeEntry(amount: 1000, date: testDate(2025, 5, 10), type: .income, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 1300, date: testDate(2025, 6, 10), type: .income, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(previous); context.insert(current)

        let insights = HomeCalculator.whatsDifferentInsights(
            month: testDate(2025, 6, 1), entries: [previous, current], budgets: [], headCategories: [head], settings: testSettings()
        )

        let income = insights.first { $0.kind == .incomeChange }
        XCTAssertNotNil(income)
        XCTAssertEqual(income?.direction, .up)
        XCTAssertEqual(income?.isFavorable, true)
    }

    func testResultIsCappedAtMaxWhatsDifferentInsights() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        var heads: [HeadCategory] = []
        var entries: [Entry] = []
        // Five distinct head categories, each with a large enough swing to qualify — verifies
        // the cap, not just that ranking exists.
        for index in 0..<5 {
            let head = TestSupport.makeHeadCategory(name: "Head\(index)", sortOrder: index)
            let category = TestSupport.makeCategory(name: "Cat\(index)", headCategory: head)
            context.insert(head); context.insert(category)
            heads.append(head)

            let previous = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 10), type: .expense, category: category, wallet: wallet)
            let current = TestSupport.makeEntry(amount: 200, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
            context.insert(previous); context.insert(current)
            entries.append(contentsOf: [previous, current])
        }
        context.insert(wallet)

        let insights = HomeCalculator.whatsDifferentInsights(
            month: testDate(2025, 6, 1), entries: entries, budgets: [], headCategories: heads, settings: testSettings()
        )

        XCTAssertEqual(HomeCalculator.maxWhatsDifferentInsights, 3)
        XCTAssertLessThanOrEqual(insights.count, HomeCalculator.maxWhatsDifferentInsights)
    }
}

// MARK: - Forecast pace state

final class HomeCalculatorForecastPaceStateTests: XCTestCase {

    func testOnTrackWhenActualIsAtOrBelowPace() {
        let points = [
            DailyPacePoint(day: 1, actual: 5, onPace: 10),
            DailyPacePoint(day: 2, actual: 8, onPace: 20)
        ]
        XCTAssertEqual(HomeCalculator.forecastPaceState(pace: points), .onTrack)
    }

    func testAheadOfPaceWhenActualExceedsPace() {
        let points = [
            DailyPacePoint(day: 1, actual: 15, onPace: 10),
            DailyPacePoint(day: 2, actual: 25, onPace: 20)
        ]
        XCTAssertEqual(HomeCalculator.forecastPaceState(pace: points), .aheadOfPace)
    }

    func testInsufficientDataWhenNoPointHasActualYet() {
        let points = [
            DailyPacePoint(day: 1, actual: nil, onPace: 10),
            DailyPacePoint(day: 2, actual: nil, onPace: 20)
        ]
        XCTAssertEqual(HomeCalculator.forecastPaceState(pace: points), .insufficientData)
    }

    func testInsufficientDataWhenPaceIsEmpty() {
        XCTAssertEqual(HomeCalculator.forecastPaceState(pace: []), .insufficientData)
    }

    func testInsufficientDataWhenOnPaceIsZero() {
        // totalPlanned == 0 (no budget) => onPace is 0 for every day.
        let points = [DailyPacePoint(day: 1, actual: 0, onPace: 0)]
        XCTAssertEqual(HomeCalculator.forecastPaceState(pace: points), .insufficientData)
    }
}

// MARK: - Upcoming (Shared balances)

final class HomeCalculatorUpcomingTests: XCTestCase {

    /// A two-person event with one 50/50-split expense — `paidByYou` decides which participant
    /// fronted the money; `settleFully` optionally records a Settlement that closes the balance.
    @discardableResult
    private func makeEvent(
        in context: ModelContext,
        title: String,
        paidByYou: Bool,
        amount: Decimal = 100,
        settleFully: Bool = false
    ) -> SharedEvent {
        let you = Person(displayName: "You", isCurrentUser: true)
        let other = Person(displayName: "Other")
        context.insert(you); context.insert(other)

        let event = SharedEvent(title: title, participants: [you, other])
        context.insert(event)

        let half = amount / 2
        let expense = SharedExpense(amount: amount, currency: "EUR", paidBy: paidByYou ? you : other, event: event)
        context.insert(expense)
        let youShare = SharedExpenseParticipant(person: you, amount: half, expense: expense)
        let otherShare = SharedExpenseParticipant(person: other, amount: half, expense: expense)
        context.insert(youShare); context.insert(otherShare)
        expense.participants = [youShare, otherShare]
        event.expenses = [expense]

        if settleFully {
            let (from, to) = paidByYou ? (other, you) : (you, other)
            let settlement = Settlement(fromPerson: from, toPerson: to, amount: half, paymentMethod: .cash, event: event)
            context.insert(settlement)
            event.settlements = [settlement]
        }

        try? context.save()
        return event
    }

    func testOwedEventProducesPositiveAmount() {
        let context = TestSupport.makeInMemoryContext()
        let event = makeEvent(in: context, title: "Barcelona Trip", paidByYou: true)

        let result = HomeCalculator.upcomingSharedBalances(events: [event])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.amount, 50)
    }

    func testOwingEventProducesNegativeAmount() {
        let context = TestSupport.makeInMemoryContext()
        let event = makeEvent(in: context, title: "Dinner", paidByYou: false)

        let result = HomeCalculator.upcomingSharedBalances(events: [event])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.amount, -50)
    }

    func testFullySettledEventIsExcluded() {
        let context = TestSupport.makeInMemoryContext()
        let event = makeEvent(in: context, title: "Settled Trip", paidByYou: true, settleFully: true)
        XCTAssertTrue(event.isFullySettled)

        let result = HomeCalculator.upcomingSharedBalances(events: [event])

        XCTAssertTrue(result.isEmpty)
    }

    func testMultipleEventsAreSortedByAbsoluteOutstandingAmountDescending() {
        let context = TestSupport.makeInMemoryContext()
        let small = makeEvent(in: context, title: "Small", paidByYou: true, amount: 60)   // +30
        let large = makeEvent(in: context, title: "Large", paidByYou: true, amount: 160)  // +80
        let owing = makeEvent(in: context, title: "Owing", paidByYou: false, amount: 100) // -50

        let result = HomeCalculator.upcomingSharedBalances(events: [small, large, owing])

        XCTAssertEqual(result.map(\.amount), [80, -50, 30])
    }

    func testResultCanBeCappedToMaxUpcomingItems() {
        let context = TestSupport.makeInMemoryContext()
        let events = (0..<4).map { index in
            makeEvent(in: context, title: "Event\(index)", paidByYou: true, amount: Decimal(20 + index * 20))
        }

        let result = HomeCalculator.upcomingSharedBalances(events: events)
        let capped = Array(result.prefix(HomeCalculator.maxUpcomingItems))

        XCTAssertEqual(HomeCalculator.maxUpcomingItems, 3)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(capped.count, 3)
        // Largest three: amounts 20,40,60,80 => halves owed 10,20,30,40 => top three are 40,30,20.
        XCTAssertEqual(capped.map(\.amount), [40, 30, 20])
    }
}
