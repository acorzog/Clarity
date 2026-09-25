import XCTest
import SwiftData
@testable import FinanceTracker

private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
}

/// Mirrors `BudgetSettingsStore`'s actual defaults, matching every other calculator test's convention.
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

/// `today` anchors every test at June 20, 2025 (a Friday) — mid-month and mid-week, matching
/// `ClarityScoreCalculatorTests`' own convention so day/week windows never cross a year boundary.
private let today = testDate(2025, 6, 20)

private func dateRangeBounds(_ kind: AskClarityPeriodKind) -> (start: Date, end: Date)? {
    if case .dateRange(let start, let end) = kind { return (start, end) }
    return nil
}

// MARK: - Interpreter: periods

final class AskClarityInterpreterPeriodTests: XCTestCase {
    func testRecognizesEachSupportedRelativePeriod() {
        let cases: [(String, AskClarityPeriodKind)] = [
            ("How much did I spend today?", .today),
            ("How much did I spend yesterday?", .yesterday),
            ("How much did I spend this week?", .thisWeek),
            ("How much did I spend last week?", .lastWeek),
            ("How much did I spend this month?", .thisMonth),
            ("How much did I spend last month?", .lastMonth)
        ]
        for (text, expectedKind) in cases {
            let query = AskClarityInterpreter.interpret(text, categories: [], context: .empty, today: today)
            guard case .supported(let period) = query?.periodMatch else {
                return XCTFail("\(text) should resolve to a supported period")
            }
            XCTAssertEqual(period.kind, expectedKind, text)
        }
    }

    func testRecognizesAnExplicitCalendarMonthByName() {
        let query = AskClarityInterpreter.interpret("How much did I spend in January?", categories: [], context: .empty, today: today)
        guard case .supported(let period) = query?.periodMatch, case .specificMonth(let date) = period.kind else {
            return XCTFail("should resolve January to a specific month")
        }
        XCTAssertEqual(Calendar.current.component(.month, from: date), 1)
        XCTAssertEqual(Calendar.current.component(.year, from: date), 2025, "January hasn't happened yet this cycle relative to June, so it resolves to the most recent past January")
    }

    func testUnsupportedPeriodPhraseIsRecognizedButNotSilentlyDefaulted() {
        let query = AskClarityInterpreter.interpret("How much did I spend this year?", categories: [], context: .empty, today: today)
        guard case .unsupported(let phrase) = query?.periodMatch else {
            return XCTFail("'this year' should be recognized as an unsupported period, not silently dropped")
        }
        XCTAssertEqual(phrase, "this year")
    }

    func testThisMonthAndLastMonthTogetherMeansThisMonthAsThePrimarySubject() {
        let query = AskClarityInterpreter.interpret("Did I spend more this month than last month?", categories: [], context: .empty, today: today)
        guard case .supported(let period) = query?.periodMatch else { return XCTFail() }
        XCTAssertEqual(period.kind, .thisMonth)
        XCTAssertTrue(query?.comparisonRequested ?? false)
    }

    func testComparedWithLastMonthDoesNotHijackThePeriodAsLastMonth() {
        // "last month" here is a comparison marker, not the primary subject — the primary period
        // is left unspecified (defaults to "this month" at resolution time), not `.lastMonth`.
        let query = AskClarityInterpreter.interpret("What changed compared with last month?", categories: [], context: .empty, today: today)
        XCTAssertNil(query?.periodMatch)
        XCTAssertTrue(query?.comparisonRequested ?? false)
    }

    func testNoPeriodMentionedLeavesPeriodMatchNil() {
        let query = AskClarityInterpreter.interpret("How much did I spend?", categories: [], context: .empty, today: today)
        XCTAssertNil(query?.periodMatch)
    }

    // MARK: Weekend

    func testThisWeekendResolvesToTheWeekendPeriodKind() {
        let query = AskClarityInterpreter.interpret("How much did I spend this weekend?", categories: [], context: .empty, today: today)
        guard case .supported(let period) = query?.periodMatch else { return XCTFail("'this weekend' should be a supported period") }
        XCTAssertEqual(period.kind, .thisWeekend)
        XCTAssertEqual(period.label, "this weekend")
    }

    func testLastWeekendResolvesToTheWeekendPeriodKind() {
        let query = AskClarityInterpreter.interpret("How much did I spend last weekend?", categories: [], context: .empty, today: today)
        guard case .supported(let period) = query?.periodMatch else { return XCTFail("'last weekend' should be a supported period") }
        XCTAssertEqual(period.kind, .lastWeekend)
        XCTAssertEqual(period.label, "last weekend")
    }

    /// "This weekend"/"last weekend" must never be misread as "this week"/"last week" — both
    /// weekend phrases contain the shorter week phrase as a literal substring, so this pins the
    /// priority fix directly rather than relying on it as an incidental side effect.
    func testWeekendTakesPriorityOverWeekSoItIsNeverMisreadAsAWholeWeek() {
        let thisWeekend = AskClarityInterpreter.interpret("How much did I spend this weekend?", categories: [], context: .empty, today: today)
        guard case .supported(let period) = thisWeekend?.periodMatch else { return XCTFail() }
        XCTAssertNotEqual(period.kind, .thisWeek, "'this weekend' must not resolve as 'this week'")
        XCTAssertEqual(period.kind, .thisWeekend)

        let lastWeekend = AskClarityInterpreter.interpret("How much did I spend last weekend?", categories: [], context: .empty, today: today)
        guard case .supported(let period2) = lastWeekend?.periodMatch else { return XCTFail() }
        XCTAssertNotEqual(period2.kind, .lastWeek, "'last weekend' must not resolve as 'last week'")
        XCTAssertEqual(period2.kind, .lastWeekend)
    }

    /// Regression: plain "this week"/"last week" (no "-end") must keep resolving to the whole
    /// week exactly as before — the weekend-priority fix must not overreach into these.
    func testPlainThisWeekAndLastWeekStillResolveToTheWholeWeek() {
        let thisWeek = AskClarityInterpreter.interpret("How much did I spend this week?", categories: [], context: .empty, today: today)
        guard case .supported(let period) = thisWeek?.periodMatch else { return XCTFail() }
        XCTAssertEqual(period.kind, .thisWeek)

        let lastWeek = AskClarityInterpreter.interpret("How much did I spend last week?", categories: [], context: .empty, today: today)
        guard case .supported(let period2) = lastWeek?.periodMatch else { return XCTFail() }
        XCTAssertEqual(period2.kind, .lastWeek)
    }

    func testSupportedPeriodsDescriptionMentionsWeekend() {
        XCTAssertTrue(AskClarityInterpreter.supportedPeriodsDescription.contains("weekend"))
    }
}

// MARK: - Interpreter: categories

final class AskClarityInterpreterCategoryTests: XCTestCase {
    private func makeFoodHierarchy(in context: ModelContext) -> (food: HeadCategory, groceries: FinanceTracker.Category, restaurants: FinanceTracker.Category) {
        let food = TestSupport.makeHeadCategory(name: "Food")
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: food)
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: food)
        context.insert(food); context.insert(groceries); context.insert(restaurants)
        return (food, groceries, restaurants)
    }

    func testExactCategoryNameResolvesDirectly() {
        let context = TestSupport.makeInMemoryContext()
        let (_, groceries, restaurants) = makeFoodHierarchy(in: context)

        let query = AskClarityInterpreter.interpret("How much did I spend on restaurants?", categories: [groceries, restaurants], context: .empty, today: today)
        guard case .resolved(let category) = query?.categoryMatch else { return XCTFail("should resolve Restaurants directly") }
        XCTAssertEqual(category.name, "Restaurants")
    }

    func testMatchingIsCaseInsensitive() {
        let context = TestSupport.makeInMemoryContext()
        let (_, groceries, restaurants) = makeFoodHierarchy(in: context)

        let query = AskClarityInterpreter.interpret("How much did I spend on RESTAURANTS?", categories: [groceries, restaurants], context: .empty, today: today)
        guard case .resolved(let category) = query?.categoryMatch else { return XCTFail() }
        XCTAssertEqual(category.name, "Restaurants")
    }

    func testHeadCategoryNameWithOneChildResolvesDirectly() {
        let context = TestSupport.makeInMemoryContext()
        let transport = TestSupport.makeHeadCategory(name: "Transport")
        let gas = TestSupport.makeCategory(name: "Gas", headCategory: transport)
        context.insert(transport); context.insert(gas)

        let query = AskClarityInterpreter.interpret("How much did I spend on transport?", categories: [gas], context: .empty, today: today)
        guard case .resolved(let category) = query?.categoryMatch else { return XCTFail("a head category with exactly one child should resolve to it") }
        XCTAssertEqual(category.name, "Gas")
    }

    func testHeadCategoryNameWithMultipleChildrenIsAmbiguous() {
        let context = TestSupport.makeInMemoryContext()
        let (_, groceries, restaurants) = makeFoodHierarchy(in: context)

        let query = AskClarityInterpreter.interpret("How much did I spend on Food?", categories: [groceries, restaurants], context: .empty, today: today)
        guard case .resolvedHeadCategory(let head, let candidates) = query?.categoryMatch else { return XCTFail("Food should resolve as an aggregate head category, not ask for clarification") }
        XCTAssertEqual(head.name, "Food")
        XCTAssertEqual(Set(candidates.map(\.name)), Set(["Groceries", "Restaurants"]))
    }

    func testUnknownCategoryPhraseAfterPrepositionIsNotFoundNotGuessed() {
        let context = TestSupport.makeInMemoryContext()
        let (_, groceries, restaurants) = makeFoodHierarchy(in: context)

        let query = AskClarityInterpreter.interpret("How much did I spend on gadgets?", categories: [groceries, restaurants], context: .empty, today: today)
        guard case .notFound(let phrase) = query?.categoryMatch else { return XCTFail("an unmatched category phrase must be reported, not guessed") }
        XCTAssertEqual(phrase, "gadgets")
    }

    func testNoCategoryMentionedLeavesCategoryMatchNil() {
        let context = TestSupport.makeInMemoryContext()
        let (_, groceries, restaurants) = makeFoodHierarchy(in: context)

        let query = AskClarityInterpreter.interpret("How much did I spend this month?", categories: [groceries, restaurants], context: .empty, today: today)
        XCTAssertNil(query?.categoryMatch)
    }

    func testPrepositionalPhraseStopsAtATrailingPeriodWord() {
        let context = TestSupport.makeInMemoryContext()
        let (_, groceries, restaurants) = makeFoodHierarchy(in: context)

        let query = AskClarityInterpreter.interpret("How much did I spend on restaurants this month?", categories: [groceries, restaurants], context: .empty, today: today)
        guard case .resolved(let category) = query?.categoryMatch else { return XCTFail() }
        XCTAssertEqual(category.name, "Restaurants")
        guard case .supported(let period) = query?.periodMatch else { return XCTFail() }
        XCTAssertEqual(period.kind, .thisMonth)
    }

    // MARK: Head categories with children (aggregate, never ambiguous)

    private func makeTravellingHierarchy(in context: ModelContext) -> [FinanceTracker.Category] {
        let travelling = TestSupport.makeHeadCategory(name: "Travelling")
        let activities = TestSupport.makeCategory(name: "Activities", headCategory: travelling)
        let drinks = TestSupport.makeCategory(name: "Drinks", headCategory: travelling)
        let food = TestSupport.makeCategory(name: "Food", headCategory: travelling)
        let hotel = TestSupport.makeCategory(name: "Hotel", headCategory: travelling)
        context.insert(travelling); context.insert(activities); context.insert(drinks); context.insert(food); context.insert(hotel)
        return [activities, drinks, food, hotel]
    }

    func testHeadCategoryWithChildrenResolvesAsAnAggregateNeverAmbiguous() {
        let context = TestSupport.makeInMemoryContext()
        let children = makeTravellingHierarchy(in: context)

        let query = AskClarityInterpreter.interpret("How much did I spend travelling?", categories: children, context: .empty, today: today)
        guard case .resolvedHeadCategory(let head, let candidates) = query?.categoryMatch else {
            return XCTFail("Travelling should resolve as an aggregate over its children, not ask for clarification")
        }
        XCTAssertEqual(head.name, "Travelling")
        XCTAssertEqual(Set(candidates.map(\.name)), Set(["Activities", "Drinks", "Food", "Hotel"]))
    }

    /// A subcategory mentioned explicitly must still resolve to just that one category — the
    /// head-category aggregation must not swallow an explicit, more specific mention. Exact
    /// category-name matching (step 1 in `parseCategory`) already runs before head-category
    /// matching (step 2), so this pins that ordering still holds after the aggregation change.
    func testExplicitSubcategoryStillResolvesToItselfNotTheWholeGroup() {
        let context = TestSupport.makeInMemoryContext()
        let children = makeTravellingHierarchy(in: context)

        let query = AskClarityInterpreter.interpret("How much did I spend on Hotel?", categories: children, context: .empty, today: today)
        guard case .resolved(let category) = query?.categoryMatch else { return XCTFail("Hotel should resolve directly, not as the Travelling group") }
        XCTAssertEqual(category.name, "Hotel")
    }

    func testTravelSpellingVariantsAllResolveToTravelling() {
        let context = TestSupport.makeInMemoryContext()
        let children = makeTravellingHierarchy(in: context)

        for phrase in ["How much did I spend travelling?", "How much did I spend traveling?", "How much did I spend on travel?"] {
            let query = AskClarityInterpreter.interpret(phrase, categories: children, context: .empty, today: today)
            guard case .resolvedHeadCategory(let head, _) = query?.categoryMatch else {
                return XCTFail("\(phrase) should resolve Travelling via its spelling variant")
            }
            XCTAssertEqual(head.name, "Travelling", phrase)
        }
    }

    /// A head category with exactly one child still resolves directly to that single category —
    /// aggregation only applies once there's actually more than one to aggregate.
    func testHeadCategoryWithExactlyOneChildStillResolvesDirectly() {
        let context = TestSupport.makeInMemoryContext()
        let transport = TestSupport.makeHeadCategory(name: "Transport")
        let gas = TestSupport.makeCategory(name: "Gas", headCategory: transport)
        context.insert(transport); context.insert(gas)

        let query = AskClarityInterpreter.interpret("How much did I spend on transport?", categories: [gas], context: .empty, today: today)
        guard case .resolved(let category) = query?.categoryMatch else { return XCTFail() }
        XCTAssertEqual(category.name, "Gas")
    }
}

// MARK: - Interpreter: other entities and unknown text

final class AskClarityInterpreterEntityTests: XCTestCase {
    func testRankingKeywords() {
        XCTAssertEqual(AskClarityInterpreter.interpret("What's my biggest expense?", categories: [], context: .empty, today: today)?.ranking, .highest)
        XCTAssertEqual(AskClarityInterpreter.interpret("What's my smallest category?", categories: [], context: .empty, today: today)?.ranking, .lowest)
    }

    func testDirectionKeywords() {
        XCTAssertEqual(AskClarityInterpreter.interpret("Which category increased the most?", categories: [], context: .empty, today: today)?.direction, .increased)
        XCTAssertEqual(AskClarityInterpreter.interpret("Which category decreased the most?", categories: [], context: .empty, today: today)?.direction, .decreased)
    }

    func testBudgetStateKeywords() {
        XCTAssertEqual(AskClarityInterpreter.interpret("Which categories are over budget?", categories: [], context: .empty, today: today)?.budgetState, .overBudget)
        XCTAssertEqual(AskClarityInterpreter.interpret("Am I within my budget?", categories: [], context: .empty, today: today)?.budgetState, .withinBudget)
    }

    func testWantsListIsTrueOnlyForPluralCategories() {
        XCTAssertTrue(AskClarityInterpreter.interpret("Show me my biggest spending categories.", categories: [], context: .empty, today: today)?.wantsList ?? false)
        XCTAssertFalse(AskClarityInterpreter.interpret("What did I spend the most on?", categories: [], context: .empty, today: today)?.wantsList ?? true)
    }

    func testTransactionRankingDetectsSingularExpenseNotCategory() {
        XCTAssertTrue(AskClarityInterpreter.interpret("What was my biggest expense?", categories: [], context: .empty, today: today)?.wantsTransactionRanking ?? false)
        XCTAssertFalse(AskClarityInterpreter.interpret("What was my biggest expense category?", categories: [], context: .empty, today: today)?.wantsTransactionRanking ?? true)
    }

    func testAssessmentPhraseIsDetected() {
        XCTAssertTrue(AskClarityInterpreter.interpret("Am I spending too much on restaurants?", categories: [], context: .empty, today: today)?.wantsAssessment ?? false)
    }

    /// Regression: "I feel like I'm spending a lot on restaurants lately" is a fuzzy, unstructured
    /// assessment — no "too much"/"overspending on"/"too high"/"excessive" wording at all — that
    /// should still be recognized as an assessment request, not silently missed.
    func testSpendingALotOnPhraseIsDetectedAsAnAssessment() {
        XCTAssertTrue(AskClarityInterpreter.interpret("I feel like I'm spending a lot on restaurants lately", categories: [], context: .empty, today: today)?.wantsAssessment ?? false)
    }

    func testWhyAndReduceAdvicePhrasesAreDetected() {
        XCTAssertTrue(AskClarityInterpreter.interpret("Why am I spending more this month?", categories: [], context: .empty, today: today)?.wantsWhyExplanation ?? false)
        XCTAssertTrue(AskClarityInterpreter.interpret("Where could I reduce spending?", categories: [], context: .empty, today: today)?.wantsReduceAdvice ?? false)
    }

    func testContextualReferenceWordsAreDetectedAsWholeWordsOnly() {
        XCTAssertTrue(AskClarityInterpreter.interpret("How much was that last month?", categories: [], context: .empty, today: today)?.usedContextualReference ?? false)
        // "within" contains the substring "it" — must not false-positive as a contextual reference.
        XCTAssertFalse(AskClarityInterpreter.interpret("Am I within my budget?", categories: [], context: .empty, today: today)?.usedContextualReference ?? true)
    }

    func testCompletelyUnrecognizedTextReturnsNil() {
        // Deliberately avoids any recognized period/metric word ("today" alone would legitimately
        // resolve — see `AskClarityEngineUnknownQuestionTests` for that distinction).
        XCTAssertNil(AskClarityInterpreter.interpret("what's the weather like outside", categories: [], context: .empty, today: today))
        XCTAssertNil(AskClarityInterpreter.interpret("", categories: [], context: .empty, today: today))
        XCTAssertNil(AskClarityInterpreter.interpret("   ", categories: [], context: .empty, today: today))
    }

    func testQuestionMatchingMultipleSignalsKeepsAllOfThem() {
        // Budget + spending wording together — both signals should survive so the resolver (not
        // the parser) decides which combination takes priority.
        let query = AskClarityInterpreter.interpret("how much did I spend against my budget", categories: [], context: .empty, today: today)
        XCTAssertEqual(query?.metric, .spending)
    }
}

// MARK: - Engine: category spending amount

final class AskClarityEngineCategorySpendingTests: XCTestCase {
    func testReportsCategorySpendingThisMonthByDefault() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let expense = TestSupport.makeEntry(amount: 186, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(expense)

        let result = AskClarityEngine.respond(
            to: "How much did I spend on restaurants?", context: .empty, entries: [expense], budgets: [], headCategories: [head], settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("186"))
        XCTAssertTrue(result.answer.headline.contains("Restaurants"))
    }

    func testAnswerMatchesBudgetCalculatorExactly() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let e1 = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 5), type: .expense, category: restaurants, wallet: wallet)
        let e2 = TestSupport.makeEntry(amount: 25, date: testDate(2025, 6, 12), type: .expense, category: restaurants, wallet: wallet)
        let e3 = TestSupport.makeEntry(amount: 300, date: testDate(2025, 6, 15), type: .expense, category: groceries, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(groceries)
        context.insert(e1); context.insert(e2); context.insert(e3)
        let entries = [e1, e2, e3]

        let result = AskClarityEngine.respond(to: "How much did I spend on restaurants?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)

        let summary = BudgetCalculator.periodSpendingSummary(month: testDate(2025, 6, 1), entries: entries, budgets: [], headCategories: [head], settings: testSettings(), respectHiddenCategories: true)
        let expected = summary.byCategory.first { $0.category === restaurants }?.actual ?? 0
        XCTAssertEqual(expected, 65)
        XCTAssertTrue(result.answer.headline.contains(expected.currencyFormatted))
    }

    func testExcludeFromBudgetEntryNeverCountsTowardCategorySpending() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let normal = TestSupport.makeEntry(amount: 30, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        let excluded = TestSupport.makeEntry(amount: 500, date: testDate(2025, 6, 11), type: .expense, category: restaurants, wallet: wallet, excludeFromBudget: true)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(normal); context.insert(excluded)

        let result = AskClarityEngine.respond(to: "How much did I spend on restaurants?", context: .empty, entries: [normal, excluded], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.headline.contains("30"))
        XCTAssertFalse(result.answer.headline.contains("500"))
    }

    func testIncomeAndTransfersAreIgnoredForACategorySpendingQuestion() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let destination = TestSupport.makeWallet(name: "Savings")
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let expense = TestSupport.makeEntry(amount: 20, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        let income = TestSupport.makeEntry(amount: 1000, date: testDate(2025, 6, 1), type: .income, category: restaurants, wallet: wallet)
        let transfer = TestSupport.makeEntry(amount: 200, date: testDate(2025, 6, 5), type: .transfer, category: restaurants, wallet: wallet, destinationWallet: destination)
        context.insert(wallet); context.insert(destination); context.insert(head); context.insert(restaurants)
        context.insert(expense); context.insert(income); context.insert(transfer)

        let result = AskClarityEngine.respond(to: "How much did I spend on restaurants?", context: .empty, entries: [expense, income, transfer], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.headline.contains("20"))
        XCTAssertFalse(result.answer.headline.contains("1,000") )
        XCTAssertFalse(result.answer.headline.contains("1000"))
    }
}

// MARK: - Engine: head-category aggregation ("Travelling" = Activities + Drinks + Food + Hotel)

final class AskClarityEngineHeadCategoryAggregationTests: XCTestCase {
    private func makeTravellingHierarchy(in context: ModelContext, wallet: Wallet) -> (activities: FinanceTracker.Category, drinks: FinanceTracker.Category, food: FinanceTracker.Category, hotel: FinanceTracker.Category) {
        let travelling = TestSupport.makeHeadCategory(name: "Travelling")
        let activities = TestSupport.makeCategory(name: "Activities", headCategory: travelling)
        let drinks = TestSupport.makeCategory(name: "Drinks", headCategory: travelling)
        let food = TestSupport.makeCategory(name: "Food", headCategory: travelling)
        let hotel = TestSupport.makeCategory(name: "Hotel", headCategory: travelling)
        context.insert(travelling); context.insert(activities); context.insert(drinks); context.insert(food); context.insert(hotel)
        return (activities, drinks, food, hotel)
    }

    func testHowMuchDidISpendTravellingTotalsAllSubcategories() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let (activities, drinks, food, hotel) = makeTravellingHierarchy(in: context, wallet: wallet)
        let travellingHead = activities.headCategory

        let e1 = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 5), type: .expense, category: activities, wallet: wallet)
        let e2 = TestSupport.makeEntry(amount: 25, date: testDate(2025, 6, 6), type: .expense, category: drinks, wallet: wallet)
        let e3 = TestSupport.makeEntry(amount: 60, date: testDate(2025, 6, 7), type: .expense, category: food, wallet: wallet)
        let e4 = TestSupport.makeEntry(amount: 300, date: testDate(2025, 6, 8), type: .expense, category: hotel, wallet: wallet)
        [e1, e2, e3, e4].forEach { context.insert($0) }
        let entries = [e1, e2, e3, e4]

        let result = AskClarityEngine.respond(to: "How much did I spend travelling?", context: .empty, entries: entries, budgets: [], headCategories: [travellingHead], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("425"), result.answer.headline) // 40 + 25 + 60 + 300
        XCTAssertTrue(result.answer.headline.contains("Travelling"), result.answer.headline)
    }

    /// Same total regardless of which of the three real-world spellings is used.
    func testTravelSpellingVariantsAllProduceTheSameAggregateTotal() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let (activities, drinks, _, _) = makeTravellingHierarchy(in: context, wallet: wallet)
        let travellingHead = activities.headCategory

        let e1 = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 5), type: .expense, category: activities, wallet: wallet)
        let e2 = TestSupport.makeEntry(amount: 25, date: testDate(2025, 6, 6), type: .expense, category: drinks, wallet: wallet)
        context.insert(e1); context.insert(e2)
        let entries = [e1, e2]

        for phrase in ["How much did I spend travelling?", "How much did I spend traveling?", "How much did I spend on travel?"] {
            let result = AskClarityEngine.respond(to: phrase, context: .empty, entries: entries, budgets: [], headCategories: [travellingHead], settings: testSettings(), today: today)
            XCTAssertTrue(result.answer.headline.contains("65"), "\(phrase) -> \(result.answer.headline)") // 40 + 25
        }
    }

    /// A subcategory explicitly named within an aggregatable head category still answers about
    /// just that one category, not the whole Travelling total.
    func testExplicitSubcategoryOfTravellingStillAnswersJustThatCategory() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let (activities, drinks, _, hotel) = makeTravellingHierarchy(in: context, wallet: wallet)
        let travellingHead = activities.headCategory

        let hotelEntry = TestSupport.makeEntry(amount: 300, date: testDate(2025, 6, 8), type: .expense, category: hotel, wallet: wallet)
        let drinksEntry = TestSupport.makeEntry(amount: 25, date: testDate(2025, 6, 6), type: .expense, category: drinks, wallet: wallet)
        context.insert(hotelEntry); context.insert(drinksEntry)

        let result = AskClarityEngine.respond(to: "How much did I spend on Hotel?", context: .empty, entries: [hotelEntry, drinksEntry], budgets: [], headCategories: [travellingHead], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.headline.contains("300"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.contains("325"), "must not silently include Drinks: \(result.answer.headline)")
    }

    /// `excludeFromBudget` must still be respected once summed across an aggregate — the same
    /// eligibility rule, just applied per child category before the total is added up.
    func testExcludeFromBudgetIsRespectedAcrossTheAggregate() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let (activities, _, _, hotel) = makeTravellingHierarchy(in: context, wallet: wallet)
        let travellingHead = activities.headCategory

        let normal = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 5), type: .expense, category: activities, wallet: wallet)
        let excluded = TestSupport.makeEntry(amount: 5000, date: testDate(2025, 6, 8), type: .expense, category: hotel, wallet: wallet, excludeFromBudget: true)
        context.insert(normal); context.insert(excluded)

        let result = AskClarityEngine.respond(to: "How much did I spend travelling?", context: .empty, entries: [normal, excluded], budgets: [], headCategories: [travellingHead], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.headline.contains("40"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.contains("5000"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.contains("5,000"), result.answer.headline)
    }
}

// MARK: - Engine: follow-up / contextual references

final class AskClarityEngineFollowUpTests: XCTestCase {
    func testThatRefersToThePreviousTurnsRankingResult() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Shopping")
        let shopping = TestSupport.makeCategory(name: "Shopping", headCategory: head)
        let thisMonthEntry = TestSupport.makeEntry(amount: 340, date: testDate(2025, 6, 10), type: .expense, category: shopping, wallet: wallet)
        let lastMonthEntry = TestSupport.makeEntry(amount: 200, date: testDate(2025, 5, 10), type: .expense, category: shopping, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(shopping); context.insert(thisMonthEntry); context.insert(lastMonthEntry)
        let entries = [thisMonthEntry, lastMonthEntry]

        let turn1 = AskClarityEngine.respond(to: "Where am I spending the most?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertTrue(turn1.answer.headline.contains("Shopping"))
        XCTAssertEqual(turn1.updatedContext.lastCategory?.name, "Shopping")

        let turn2 = AskClarityEngine.respond(to: "How much was that last month?", context: turn1.updatedContext, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertTrue(turn2.answer.headline.contains("200"), turn2.answer.headline)
        XCTAssertTrue(turn2.answer.headline.contains("Shopping"), turn2.answer.headline)
    }

    func testFollowUpToADifferentPeriodComparesAgainstTheRememberedFigure() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let thisMonthEntry = TestSupport.makeEntry(amount: 186, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        let lastMonthEntry = TestSupport.makeEntry(amount: 157, date: testDate(2025, 5, 10), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(thisMonthEntry); context.insert(lastMonthEntry)
        let entries = [thisMonthEntry, lastMonthEntry]

        let turn1 = AskClarityEngine.respond(to: "How much did I spend on restaurants?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertTrue(turn1.answer.headline.contains("186"))

        let turn2 = AskClarityEngine.respond(to: "And last month?", context: turn1.updatedContext, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertTrue(turn2.answer.headline.contains("157"), turn2.answer.headline)
        // €29 less than this month (€186) — the comparison must land in the supporting detail.
        XCTAssertTrue(turn2.answer.supportingDetail.contains("29"), turn2.answer.supportingDetail)
        XCTAssertTrue(turn2.answer.supportingDetail.contains("less"), turn2.answer.supportingDetail)
    }

    func testSessionContextDoesNotCarryAcrossAFreshEmptyContext() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Shopping")
        let shopping = TestSupport.makeCategory(name: "Shopping", headCategory: head)
        let entry = TestSupport.makeEntry(amount: 340, date: testDate(2025, 6, 10), type: .expense, category: shopping, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(shopping); context.insert(entry)

        // "That" with no prior context at all must not silently succeed.
        let result = AskClarityEngine.respond(to: "How much was that last month?", context: .empty, entries: [entry], budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertFalse(result.answer.hasSufficientData)
    }

    /// "And restaurants?" — a bare category swap with no pronoun and no period of its own. Must
    /// pick up the *new* category while keeping the period the conversation was already using.
    func testAndCategorySwapsSubjectWhileKeepingThePreviousPeriod() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let shopping = TestSupport.makeCategory(name: "Shopping", headCategory: head)
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let shoppingLastMonth = TestSupport.makeEntry(amount: 200, date: testDate(2025, 5, 10), type: .expense, category: shopping, wallet: wallet)
        let restaurantsLastMonth = TestSupport.makeEntry(amount: 90, date: testDate(2025, 5, 12), type: .expense, category: restaurants, wallet: wallet)
        let restaurantsThisMonth = TestSupport.makeEntry(amount: 186, date: testDate(2025, 6, 12), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(shopping); context.insert(restaurants)
        context.insert(shoppingLastMonth); context.insert(restaurantsLastMonth); context.insert(restaurantsThisMonth)
        let entries = [shoppingLastMonth, restaurantsLastMonth, restaurantsThisMonth]

        let turn1 = AskClarityEngine.respond(to: "How much did I spend on Shopping last month?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertTrue(turn1.answer.headline.contains("200"), turn1.answer.headline)
        XCTAssertEqual(turn1.updatedContext.lastPeriod?.kind, .lastMonth)

        let turn2 = AskClarityEngine.respond(to: "And restaurants?", context: turn1.updatedContext, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertTrue(turn2.answer.headline.contains("Restaurants"), turn2.answer.headline)
        XCTAssertTrue(turn2.answer.headline.contains("90"), "should report last month's Restaurants figure (90), not this month's (186): \(turn2.answer.headline)")
        XCTAssertFalse(turn2.answer.headline.contains("186"), turn2.answer.headline)
    }

    /// "What about last week?" — a bare period swap. Must keep the previous turn's category.
    func testWhatAboutSwapsPeriodWhileKeepingThePreviousCategory() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        // June 20, 2025 is a Friday; the Monday-first week containing it is June 16-22, so June 17
        // is "this week" and June 10 is "last week."
        let thisWeekEntry = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 17), type: .expense, category: restaurants, wallet: wallet)
        let lastWeekEntry = TestSupport.makeEntry(amount: 55, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(thisWeekEntry); context.insert(lastWeekEntry)
        let entries = [thisWeekEntry, lastWeekEntry]

        let turn1 = AskClarityEngine.respond(to: "How much did I spend on restaurants this week?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertTrue(turn1.answer.headline.contains("40"), turn1.answer.headline)

        let turn2 = AskClarityEngine.respond(to: "What about last week?", context: turn1.updatedContext, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertTrue(turn2.answer.headline.contains("Restaurants"), turn2.answer.headline)
        XCTAssertTrue(turn2.answer.headline.contains("55"), turn2.answer.headline)
    }

    /// A genuinely new, self-contained question mid-conversation (its own metric *and* category)
    /// must not silently inherit a stale period from an unrelated earlier turn.
    func testACompleteNewQuestionDoesNotInheritAnUnrelatedPriorPeriod() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let shopping = TestSupport.makeCategory(name: "Shopping", headCategory: head)
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let shoppingLastMonth = TestSupport.makeEntry(amount: 200, date: testDate(2025, 5, 10), type: .expense, category: shopping, wallet: wallet)
        let restaurantsThisMonth = TestSupport.makeEntry(amount: 186, date: testDate(2025, 6, 12), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(shopping); context.insert(restaurants)
        context.insert(shoppingLastMonth); context.insert(restaurantsThisMonth)
        let entries = [shoppingLastMonth, restaurantsThisMonth]

        let turn1 = AskClarityEngine.respond(to: "How much did I spend on Shopping last month?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertEqual(turn1.updatedContext.lastPeriod?.kind, .lastMonth)

        // A fully self-contained question — explicit category AND explicit metric — should
        // default to "this month," not silently reuse "last month" from the unrelated prior turn.
        let turn2 = AskClarityEngine.respond(to: "How much did I spend on restaurants?", context: turn1.updatedContext, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertTrue(turn2.answer.headline.contains("186"), turn2.answer.headline)
        XCTAssertTrue(turn2.answer.headline.contains("this month"), turn2.answer.headline)
    }

    /// An explicit category mention must win over context inheritance — naming the parent head
    /// category mid-conversation aggregates across its children rather than silently continuing
    /// to answer about whatever single category the conversation happened to be about before.
    func testExplicitHeadCategoryMidConversationAggregatesRatherThanReusingContext() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let food = TestSupport.makeHeadCategory(name: "Food")
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: food)
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: food)
        let restaurantEntry = TestSupport.makeEntry(amount: 186, date: testDate(2025, 6, 12), type: .expense, category: restaurants, wallet: wallet)
        let groceryEntry = TestSupport.makeEntry(amount: 64, date: testDate(2025, 6, 5), type: .expense, category: groceries, wallet: wallet)
        context.insert(wallet); context.insert(food); context.insert(groceries); context.insert(restaurants)
        context.insert(restaurantEntry); context.insert(groceryEntry)
        let entries = [restaurantEntry, groceryEntry]

        let turn1 = AskClarityEngine.respond(to: "How much did I spend on restaurants?", context: .empty, entries: entries, budgets: [], headCategories: [food], settings: testSettings(), today: today)
        XCTAssertTrue(turn1.answer.headline.contains("186"), turn1.answer.headline)

        // Explicitly naming the head category aggregates Groceries + Restaurants (250) — it must
        // not silently keep answering just about Restaurants (186) from the previous turn.
        let turn2 = AskClarityEngine.respond(to: "How much did I spend on Food?", context: turn1.updatedContext, entries: entries, budgets: [], headCategories: [food], settings: testSettings(), today: today)
        XCTAssertTrue(turn2.answer.hasSufficientData)
        XCTAssertTrue(turn2.answer.headline.contains("250"), turn2.answer.headline)
        XCTAssertTrue(turn2.answer.headline.contains("Food"), turn2.answer.headline)
    }

    /// A three-turn conversation exercising category, then period, then a pronoun — each turn
    /// building on the previous one's inherited state.
    func testMultiTurnConversationChainsContextAcrossThreeTurns() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Shopping")
        let shopping = TestSupport.makeCategory(name: "Shopping", headCategory: head)
        let thisMonth = TestSupport.makeEntry(amount: 340, date: testDate(2025, 6, 10), type: .expense, category: shopping, wallet: wallet)
        let lastMonth = TestSupport.makeEntry(amount: 214, date: testDate(2025, 5, 10), type: .expense, category: shopping, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(shopping); context.insert(thisMonth); context.insert(lastMonth)
        let entries = [thisMonth, lastMonth]

        // Turn 1: ranking question, no category named explicitly.
        let turn1 = AskClarityEngine.respond(to: "Where am I spending the most?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertTrue(turn1.answer.headline.contains("Shopping"))
        XCTAssertEqual(turn1.updatedContext.lastCategory?.name, "Shopping")

        // Turn 2: bare period follow-up.
        let turn2 = AskClarityEngine.respond(to: "What about last month?", context: turn1.updatedContext, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertTrue(turn2.answer.headline.contains("214"), turn2.answer.headline)

        // Turn 3: pronoun follow-up referring back to the same subject, this time asking for the
        // month before that — since there's no prior-to-last-month data, this is a graceful
        // "not enough history" rather than a crash or a wrong number.
        let turn3 = AskClarityEngine.respond(to: "How much was that this month?", context: turn2.updatedContext, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertTrue(turn3.answer.headline.contains("340"), turn3.answer.headline)
    }

    /// Regression, found during manual validation: "Restaurants this month" (€20) -> "and last
    /// week" (€0, correctly "€20 less than this month") -> "and last month" was comparing against
    /// *last week's* remembered €0 instead of the original €20, producing an unhelpful "same as
    /// last week." The fix anchors every follow-up in a chain about the same category to the
    /// figure the chain started from, not to whatever the immediately-preceding turn showed.
    func testChainedPeriodFollowUpsAlwaysCompareAgainstTheOriginalAnchorNotTheImmediatelyPrecedingTurn() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        // This month (June): only June 3 has spend. This week (June 16-22) and last week (June
        // 9-15) both have zero Restaurants spend, since the only entry is on June 3 — outside
        // both windows. Last month (May) also has zero.
        let thisMonthEntry = TestSupport.makeEntry(amount: 20, date: testDate(2025, 6, 3), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(thisMonthEntry)
        let entries = [thisMonthEntry]

        let turn1 = AskClarityEngine.respond(to: "How much did I spend on restaurants?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertTrue(turn1.answer.headline.contains("20"), turn1.answer.headline)
        XCTAssertEqual(turn1.updatedContext.anchorPeriod?.kind, .thisMonth)
        XCTAssertEqual(turn1.updatedContext.anchorAnswerValue, 20)

        let turn2 = AskClarityEngine.respond(to: "What about last week?", context: turn1.updatedContext, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertTrue(turn2.answer.headline.contains("0"), turn2.answer.headline)
        XCTAssertTrue(turn2.answer.supportingDetail.contains("20"), turn2.answer.supportingDetail)
        XCTAssertTrue(turn2.answer.supportingDetail.contains("this month"), turn2.answer.supportingDetail)
        // The anchor itself must be untouched by this follow-up — still June/€20.
        XCTAssertEqual(turn2.updatedContext.anchorPeriod?.kind, .thisMonth)
        XCTAssertEqual(turn2.updatedContext.anchorAnswerValue, 20)

        let turn3 = AskClarityEngine.respond(to: "And last month?", context: turn2.updatedContext, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertTrue(turn3.answer.headline.contains("0"), turn3.answer.headline)
        // Must compare against the €20 anchor ("this month"), never "same as last week."
        XCTAssertTrue(turn3.answer.supportingDetail.contains("20"), turn3.answer.supportingDetail)
        XCTAssertTrue(turn3.answer.supportingDetail.contains("this month"), turn3.answer.supportingDetail)
        XCTAssertFalse(turn3.answer.supportingDetail.lowercased().contains("last week"), turn3.answer.supportingDetail)
    }

    /// Switching the subject (a genuinely new category) must start a fresh anchor rather than
    /// keep comparing against the previous subject's figure.
    func testAnchorResetsWhenTheCategoryChangesMidConversation() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let shopping = TestSupport.makeCategory(name: "Shopping", headCategory: head)
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let shoppingEntry = TestSupport.makeEntry(amount: 50, date: testDate(2025, 6, 10), type: .expense, category: shopping, wallet: wallet)
        let restaurantsEntry = TestSupport.makeEntry(amount: 20, date: testDate(2025, 6, 12), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(shopping); context.insert(restaurants)
        context.insert(shoppingEntry); context.insert(restaurantsEntry)
        let entries = [shoppingEntry, restaurantsEntry]

        let turn1 = AskClarityEngine.respond(to: "How much did I spend on shopping?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertEqual(turn1.updatedContext.anchorAnswerValue, 50)

        let turn2 = AskClarityEngine.respond(to: "And restaurants?", context: turn1.updatedContext, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        // The anchor must now belong to Restaurants (20), not still carry Shopping's 50.
        XCTAssertEqual(turn2.updatedContext.anchorCategory?.name, "Restaurants")
        XCTAssertEqual(turn2.updatedContext.anchorAnswerValue, 20)
    }
}

// MARK: - Engine: ranking

final class AskClarityEngineRankingTests: XCTestCase {
    func testTopSpendingCategory() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let small = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 5), type: .expense, category: groceries, wallet: wallet)
        let big = TestSupport.makeEntry(amount: 200, date: testDate(2025, 6, 6), type: .expense, category: dining, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(groceries); context.insert(dining); context.insert(small); context.insert(big)

        let result = AskClarityEngine.respond(to: "What did I spend the most on?", context: .empty, entries: [small, big], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.headline.contains("Dining"))
        XCTAssertTrue(result.answer.headline.contains("200"))
    }

    func testBiggestSpendingCategoriesList() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        var entries: [Entry] = []
        for (name, amount) in [("A", 300), ("B", 200), ("C", 100), ("D", 50)] {
            let category = TestSupport.makeCategory(name: name, headCategory: head)
            context.insert(category)
            let entry = TestSupport.makeEntry(amount: Decimal(amount), date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
            context.insert(entry)
            entries.append(entry)
        }
        context.insert(wallet); context.insert(head)

        let result = AskClarityEngine.respond(to: "Show me my biggest spending categories.", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.supportingDetail.contains("A"))
        XCTAssertTrue(result.answer.supportingDetail.contains("B"))
        XCTAssertTrue(result.answer.supportingDetail.contains("C"))
        XCTAssertFalse(result.answer.supportingDetail.contains("D"), "the list should cap at the top 3")
    }

    func testBiggestSingleExpenseIsATransactionNotACategory() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Shopping")
        let category = TestSupport.makeCategory(name: "Electronics", headCategory: head)
        let small1 = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 5), type: .expense, category: category, wallet: wallet)
        let small2 = TestSupport.makeEntry(amount: 45, date: testDate(2025, 6, 6), type: .expense, category: category, wallet: wallet)
        let laptop = TestSupport.makeEntry(amount: 500, date: testDate(2025, 6, 7), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(small1); context.insert(small2); context.insert(laptop)

        let result = AskClarityEngine.respond(to: "What was my biggest expense?", context: .empty, entries: [small1, small2, laptop], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.headline.contains("500"), result.answer.headline)
    }
}

// MARK: - Engine: comparisons

final class AskClarityEngineComparisonTests: XCTestCase {
    func testDidISpendMoreThisMonthThanLastMonth() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let previous = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 10), type: .expense, category: category, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(previous); context.insert(current)

        let result = AskClarityEngine.respond(to: "Did I spend more this month than last month?", context: .empty, entries: [previous, current], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.supportingDetail.contains("more"), result.answer.supportingDetail)
    }

    func testWhatChangedComparedWithLastMonthListsNotableCategoryChanges() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Shopping")
        let category = TestSupport.makeCategory(name: "Shopping", headCategory: head)
        let previous = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 10), type: .expense, category: category, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 160, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(previous); context.insert(current)

        let result = AskClarityEngine.respond(to: "What changed compared with last month?", context: .empty, entries: [previous, current], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.headline.contains("Shopping"), result.answer.headline)
    }

    func testCategoryThatIncreasedTheMost() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let upHead = TestSupport.makeHeadCategory(name: "Shopping")
        let upCategory = TestSupport.makeCategory(name: "Shopping", headCategory: upHead)
        let downHead = TestSupport.makeHeadCategory(name: "Transport")
        let downCategory = TestSupport.makeCategory(name: "Transport", headCategory: downHead)
        let upPrevious = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 10), type: .expense, category: upCategory, wallet: wallet)
        let upCurrent = TestSupport.makeEntry(amount: 160, date: testDate(2025, 6, 10), type: .expense, category: upCategory, wallet: wallet)
        let downPrevious = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 12), type: .expense, category: downCategory, wallet: wallet)
        let downCurrent = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 12), type: .expense, category: downCategory, wallet: wallet)
        context.insert(wallet); context.insert(upHead); context.insert(upCategory); context.insert(downHead); context.insert(downCategory)
        context.insert(upPrevious); context.insert(upCurrent); context.insert(downPrevious); context.insert(downCurrent)
        let entries = [upPrevious, upCurrent, downPrevious, downCurrent]

        let increase = AskClarityEngine.respond(to: "Which category increased the most?", context: .empty, entries: entries, budgets: [], headCategories: [upHead, downHead], settings: testSettings(), today: today)
        XCTAssertTrue(increase.answer.headline.contains("Shopping"), increase.answer.headline)

        let decrease = AskClarityEngine.respond(to: "Which category decreased the most?", context: .empty, entries: entries, budgets: [], headCategories: [upHead, downHead], settings: testSettings(), today: today)
        XCTAssertTrue(decrease.answer.headline.contains("Transport"), decrease.answer.headline)
    }
}

// MARK: - Engine: budget state

final class AskClarityEngineBudgetStateTests: XCTestCase {
    func testWhichCategoriesAreOverBudget() {
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

        let result = AskClarityEngine.respond(
            to: "Which categories are over budget?", context: .empty, entries: [overExpense, onTrackExpense],
            budgets: [overBudget, onTrackBudget], headCategories: [head], settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.headline.contains("Dining"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.contains("Groceries"), result.answer.headline)
    }

    func testAmIWithinMyBudgetOverall() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let budget = TestSupport.makeBudget(category: category, monthlyLimit: 200, month: 6, year: 2025)
        let expense = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(budget); context.insert(expense)

        let result = AskClarityEngine.respond(to: "Am I within my budget?", context: .empty, entries: [expense], budgets: [budget], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.headline.contains("within budget"), result.answer.headline)
    }

    func testIsASpecificCategoryOverBudget() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let budget = TestSupport.makeBudget(category: restaurants, monthlyLimit: 100, month: 6, year: 2025)
        let expense = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(budget); context.insert(expense)

        let result = AskClarityEngine.respond(to: "Is restaurants over budget?", context: .empty, entries: [expense], budgets: [budget], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.headline.contains("over budget"), result.answer.headline)
        XCTAssertTrue(result.answer.headline.contains("Restaurants"), result.answer.headline)
    }

    func testUnbudgetedCategoryReportsNoBudgetRatherThanGuessing() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let expense = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(expense)

        let result = AskClarityEngine.respond(to: "Is restaurants over budget?", context: .empty, entries: [expense], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.lowercased().contains("doesn't have a budget"), result.answer.headline)
    }

    /// "Am I within my budget?" with *no* categories budgeted at all must explain that there
    /// isn't enough budget configured to answer — never "no budgeted categories are within
    /// budget," which reads as though categories were checked and failed rather than that none
    /// exist to check in the first place.
    func testAmIWithinMyBudgetWithNoBudgetedCategoriesExplainsRatherThanImpliesOutOfBudget() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let expense = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(expense)

        let result = AskClarityEngine.respond(to: "Am I within my budget?", context: .empty, entries: [expense], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.lowercased().contains("haven't budgeted"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.lowercased().contains("no budgeted categories are within budget"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.lowercased().contains("over budget"), "must not imply anything is out of budget when nothing is budgeted at all: \(result.answer.headline)")
    }

    /// Same fix, checked against "which categories are over budget?" too — the wording issue
    /// applies to every budget-state question, not just "within budget."
    func testWhichCategoriesAreOverBudgetWithNoBudgetedCategoriesExplainsRatherThanImpliesNoneAreOver() {
        let result = AskClarityEngine.respond(to: "Which categories are over budget?", context: .empty, entries: [], budgets: [], headCategories: [], settings: testSettings(), today: today)

        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.lowercased().contains("haven't budgeted"), result.answer.headline)
    }
}

// MARK: - Engine: relative time periods (day/week)

final class AskClarityEngineTimePeriodTests: XCTestCase {
    func testTodayAndYesterdaySpending() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let todayEntry = TestSupport.makeEntry(amount: 25, date: today, type: .expense, category: category, wallet: wallet)
        let yesterdayEntry = TestSupport.makeEntry(amount: 15, date: testDate(2025, 6, 19), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(todayEntry); context.insert(yesterdayEntry)
        let entries = [todayEntry, yesterdayEntry]

        let todayResult = AskClarityEngine.respond(to: "How much did I spend today?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertTrue(todayResult.answer.headline.contains("25"), todayResult.answer.headline)

        let yesterdayResult = AskClarityEngine.respond(to: "How much did I spend yesterday?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertTrue(yesterdayResult.answer.headline.contains("15"), yesterdayResult.answer.headline)
    }

    func testThisWeekExcludesLastWeeksSpending() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        // June 20, 2025 is a Friday; the Monday-first week containing it is June 16-22.
        let thisWeekEntry = TestSupport.makeEntry(amount: 50, date: testDate(2025, 6, 17), type: .expense, category: category, wallet: wallet)
        let lastWeekEntry = TestSupport.makeEntry(amount: 70, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(thisWeekEntry); context.insert(lastWeekEntry)
        let entries = [thisWeekEntry, lastWeekEntry]

        let result = AskClarityEngine.respond(to: "How much did I spend this week?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.headline.contains("50"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.contains("70"), result.answer.headline)
    }

    func testThisWeekendAndLastWeekendResolveToSaturdayAndSunday() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        // June 16-22, 2025 is the Monday-first week containing June 20 (a Friday) — its weekend
        // is Saturday the 21st and Sunday the 22nd. The previous week's weekend is June 14-15.
        let thisWeekendSaturday = TestSupport.makeEntry(amount: 30, date: testDate(2025, 6, 21), type: .expense, category: category, wallet: wallet)
        let thisWeekendSunday = TestSupport.makeEntry(amount: 15, date: testDate(2025, 6, 22), type: .expense, category: category, wallet: wallet)
        let midWeekEntry = TestSupport.makeEntry(amount: 999, date: testDate(2025, 6, 18), type: .expense, category: category, wallet: wallet) // Wednesday — must not count
        let lastWeekendEntry = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 14), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category)
        context.insert(thisWeekendSaturday); context.insert(thisWeekendSunday); context.insert(midWeekEntry); context.insert(lastWeekendEntry)
        let entries = [thisWeekendSaturday, thisWeekendSunday, midWeekEntry, lastWeekendEntry]

        let thisWeekendResult = AskClarityEngine.respond(to: "How much did I spend this weekend?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertTrue(thisWeekendResult.answer.headline.contains("45"), thisWeekendResult.answer.headline) // 30 + 15
        XCTAssertFalse(thisWeekendResult.answer.headline.contains("999"), thisWeekendResult.answer.headline)

        let lastWeekendResult = AskClarityEngine.respond(to: "How much did I spend last weekend?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertTrue(lastWeekendResult.answer.headline.contains("40"), lastWeekendResult.answer.headline)
        XCTAssertFalse(lastWeekendResult.answer.headline.contains("45"), lastWeekendResult.answer.headline)
    }

    func testUnsupportedPeriodExplainsWhatIsSupportedInsteadOfDefaultingToThisMonth() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        // A large amount that WOULD show up if this silently fell back to "this month."
        let thisMonthEntry = TestSupport.makeEntry(amount: 9999, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(thisMonthEntry)

        let result = AskClarityEngine.respond(to: "How much did I spend this year?", context: .empty, entries: [thisMonthEntry], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertFalse(result.answer.headline.contains("9999"), "must never silently substitute the current month's total")
        XCTAssertTrue(result.answer.headline.contains("today"), result.answer.headline)
        XCTAssertTrue(result.answer.headline.contains("this month"), result.answer.headline)
    }
}

// MARK: - Engine: insight-style questions

final class AskClarityEngineInsightTests: XCTestCase {
    func testAmISpendingTooMuchComparesAgainstBudgetWhenOneExists() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let budget = TestSupport.makeBudget(category: restaurants, monthlyLimit: 100, month: 6, year: 2025)
        let expense = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(budget); context.insert(expense)

        let result = AskClarityEngine.respond(to: "Am I spending too much on restaurants?", context: .empty, entries: [expense], budgets: [budget], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.headline.contains("150"), result.answer.headline)
        XCTAssertTrue(result.answer.supportingDetail.contains("budget"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("over budget"), result.answer.supportingDetail)
    }

    func testAmISpendingTooMuchFallsBackToLastMonthWhenUnbudgeted() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let previous = TestSupport.makeEntry(amount: 50, date: testDate(2025, 5, 10), type: .expense, category: restaurants, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(previous); context.insert(current)

        let result = AskClarityEngine.respond(to: "Am I spending too much on restaurants?", context: .empty, entries: [previous, current], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.headline.contains("150"), result.answer.headline)
        XCTAssertTrue(result.answer.supportingDetail.contains("last month"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("notable increase"), result.answer.supportingDetail)
    }

    func testWhyAmISpendingMoreIdentifiesTheBiggestContributors() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Shopping")
        let category = TestSupport.makeCategory(name: "Shopping", headCategory: head)
        let previous = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 10), type: .expense, category: category, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 160, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(previous); context.insert(current)

        let result = AskClarityEngine.respond(to: "Why am I spending more this month?", context: .empty, entries: [previous, current], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.supportingDetail.contains("Shopping"), result.answer.supportingDetail)
    }

    func testWhyAmISpendingMoreIsHonestWhenSpendingIsActuallyDown() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let previous = TestSupport.makeEntry(amount: 200, date: testDate(2025, 5, 10), type: .expense, category: category, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 100, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(previous); context.insert(current)

        let result = AskClarityEngine.respond(to: "Why am I spending more this month?", context: .empty, entries: [previous, current], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.headline.lowercased().contains("less"), "must not invent an increase that didn't happen: \(result.answer.headline)")
    }

    func testWhereCouldIReduceSpendingIdentifiesOverBudgetAndIncreasedCategories() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let budget = TestSupport.makeBudget(category: dining, monthlyLimit: 100, month: 6, year: 2025)
        let expense = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: dining, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(dining); context.insert(budget); context.insert(expense)

        let result = AskClarityEngine.respond(to: "Where could I reduce spending?", context: .empty, entries: [expense], budgets: [budget], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.supportingDetail.contains("Dining"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("over"), result.answer.supportingDetail)
        XCTAssertFalse(result.answer.headline.lowercased().contains("generic"))
    }
}

// MARK: - Engine: ambiguity and unknown categories

final class AskClarityEngineAmbiguityTests: XCTestCase {
    /// Naming a head category with children is the user's own choice to see the combined total —
    /// it must aggregate across every child, never ask "do you mean X or Y."
    func testHeadCategoryAggregatesAcrossChildrenRatherThanAskingForClarification() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let food = TestSupport.makeHeadCategory(name: "Food")
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: food)
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: food)
        let groceryEntry = TestSupport.makeEntry(amount: 64, date: testDate(2025, 6, 5), type: .expense, category: groceries, wallet: wallet)
        let restaurantEntry = TestSupport.makeEntry(amount: 186, date: testDate(2025, 6, 12), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(food); context.insert(groceries); context.insert(restaurants)
        context.insert(groceryEntry); context.insert(restaurantEntry)

        let result = AskClarityEngine.respond(to: "How much did I spend on Food?", context: .empty, entries: [groceryEntry, restaurantEntry], budgets: [], headCategories: [food], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("Food"), result.answer.headline)
        XCTAssertTrue(result.answer.headline.contains("250"), result.answer.headline) // 64 (Groceries) + 186 (Restaurants)
        XCTAssertFalse(result.answer.headline.contains("Do you mean"), result.answer.headline)
    }

    func testUnknownCategoryExplainsRatherThanGuesses() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let food = TestSupport.makeHeadCategory(name: "Food")
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: food)
        context.insert(wallet); context.insert(food); context.insert(groceries)

        let result = AskClarityEngine.respond(to: "How much did I spend on gadgets?", context: .empty, entries: [], budgets: [], headCategories: [food], settings: testSettings(), today: today)

        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.lowercased().contains("don't have a category called"), result.answer.headline)
        XCTAssertTrue(result.answer.headline.contains("gadgets"), result.answer.headline)
    }
}

// MARK: - Engine: unknown / unmatched questions

final class AskClarityEngineUnknownQuestionTests: XCTestCase {
    func testCompletelyUnrelatedTextGetsAGracefulFallbackNotARestrictiveOne() {
        let result = AskClarityEngine.respond(to: "what's the weather like outside", context: .empty, entries: [], budgets: [], headCategories: [], settings: testSettings(), today: today)

        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertFalse(result.answer.headline.lowercased().contains("try one of these six questions"), "the fallback must not imply a fixed six-question limit")
    }

    func testEmptyTextGetsAGracefulFallback() {
        let result = AskClarityEngine.respond(to: "   ", context: .empty, entries: [], budgets: [], headCategories: [], settings: testSettings(), today: today)
        XCTAssertFalse(result.answer.hasSufficientData)
    }

    /// A question that's mostly unrelated but still contains a genuine financial concept (here,
    /// just the word "today") is answered from that fragment rather than rejected outright — the
    /// spec's own "attempt to interpret... if it can be answered safely, answer it" rule. This is
    /// a deliberate design choice, not an accident, so it's pinned explicitly here.
    func testAQuestionWithOnlyAPartialFinancialConceptIsStillAnswered() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let entry = TestSupport.makeEntry(amount: 25, date: today, type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(entry)

        let result = AskClarityEngine.respond(to: "what's the weather like today", context: .empty, entries: [entry], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("25"), result.answer.headline)
    }
}

// MARK: - Engine: insufficient data

final class AskClarityEngineInsufficientDataTests: XCTestCase {
    func testNoSpendingAtAllReportsInsufficientData() {
        let result = AskClarityEngine.respond(to: "How much did I spend this month?", context: .empty, entries: [], budgets: [], headCategories: [], settings: testSettings(), today: today)
        XCTAssertFalse(result.answer.hasSufficientData)
    }

    func testNoPreviousMonthReportsInsufficientDataForComparisons() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let expense = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(expense)

        let result = AskClarityEngine.respond(to: "Which categories increased?", context: .empty, entries: [expense], budgets: [], headCategories: [head], settings: testSettings(), today: today)
        XCTAssertFalse(result.answer.hasSufficientData)
    }
}

// MARK: - Engine: remaining budget / savings / income

final class AskClarityEngineOtherMetricsTests: XCTestCase {
    func testHowMuchBudgetLeft() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let income = TestSupport.makeEntry(amount: 1000, date: testDate(2025, 6, 1), type: .income, wallet: wallet)
        let expense = TestSupport.makeEntry(amount: 300, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(income); context.insert(expense)

        let result = AskClarityEngine.respond(to: "How much budget do I have left?", context: .empty, entries: [income, expense], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.headline.contains("700"), result.answer.headline)
    }

    func testHowMuchIncomeThisMonth() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let income = TestSupport.makeEntry(amount: 500, date: testDate(2025, 6, 1), type: .income, wallet: wallet)
        context.insert(wallet); context.insert(income)

        let result = AskClarityEngine.respond(to: "How much income did I earn this month?", context: .empty, entries: [income], budgets: [], headCategories: [], settings: testSettings(), today: today)

        // Avoids a 4-digit amount so this doesn't depend on the test locale's thousands separator.
        XCTAssertTrue(result.answer.headline.contains(Decimal(500).currencyFormatted), result.answer.headline)
    }
}

// MARK: - Engine: answer presentation (comparisonIsFavorable) and contextual follow-ups

final class AskClarityEngineAnswerPresentationTests: XCTestCase {
    func testSpendingLessThanTheComparisonPeriodIsFavorable() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let previous = TestSupport.makeEntry(amount: 200, date: testDate(2025, 5, 10), type: .expense, category: category, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 100, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(previous); context.insert(current)

        let result = AskClarityEngine.respond(to: "How much did I spend on dining compared to last month?", context: .empty, entries: [previous, current], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertEqual(result.answer.comparisonIsFavorable, true, result.answer.supportingDetail)
    }

    func testSpendingMoreThanTheComparisonPeriodIsUnfavorable() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let previous = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 10), type: .expense, category: category, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 200, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(previous); context.insert(current)

        let result = AskClarityEngine.respond(to: "How much did I spend on dining compared to last month?", context: .empty, entries: [previous, current], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertEqual(result.answer.comparisonIsFavorable, false, result.answer.supportingDetail)
    }

    func testNoComparisonLeavesFavorabilityNil() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let entry = TestSupport.makeEntry(amount: 100, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(entry)

        let result = AskClarityEngine.respond(to: "How much did I spend on dining?", context: .empty, entries: [entry], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertNil(result.answer.comparisonIsFavorable)
    }

    /// Follow-up suggestions must name the actual subject just discussed, not a fixed generic
    /// list — e.g. a Shopping answer should never suggest something about an unrelated category.
    func testFollowUpSuggestionsNameTheActualCategoryJustDiscussed() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Shopping")
        let shopping = TestSupport.makeCategory(name: "Shopping", headCategory: head)
        let entry = TestSupport.makeEntry(amount: 340, date: testDate(2025, 6, 10), type: .expense, category: shopping, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(shopping); context.insert(entry)

        let result = AskClarityEngine.respond(to: "How much did I spend on Shopping?", context: .empty, entries: [entry], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertFalse(result.answer.followUpSuggestions.isEmpty)
        XCTAssertTrue(result.answer.followUpSuggestions.allSatisfy { $0.contains("Shopping") }, "\(result.answer.followUpSuggestions)")
    }

    /// "Why did Shopping increase?" must ground its answer in the real month-over-month figures
    /// — never inventing a cause the transaction data can't support.
    func testWhyDidCategoryIncreaseIsGroundedInRealFigures() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Shopping")
        let shopping = TestSupport.makeCategory(name: "Shopping", headCategory: head)
        let previous = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 10), type: .expense, category: shopping, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 159, date: testDate(2025, 6, 10), type: .expense, category: shopping, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(shopping); context.insert(previous); context.insert(current)

        let result = AskClarityEngine.respond(to: "Why did Shopping increase?", context: .empty, entries: [previous, current], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("Shopping"), result.answer.headline)
        XCTAssertTrue(result.answer.headline.contains("59%") || result.answer.headline.contains("59 %"), result.answer.headline)
        // No invented explanation like "because of higher prices" or similar — only the figure.
        XCTAssertFalse(result.answer.headline.lowercased().contains("because"), result.answer.headline)
    }

    /// "Why did X increase" for a category that didn't actually change meaningfully must say so
    /// honestly rather than inventing a change.
    func testWhyDidCategoryIncreaseIsHonestWhenItDidNotChangeMeaningfully() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Shopping")
        let shopping = TestSupport.makeCategory(name: "Shopping", headCategory: head)
        let previous = TestSupport.makeEntry(amount: 100, date: testDate(2025, 5, 10), type: .expense, category: shopping, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 102, date: testDate(2025, 6, 10), type: .expense, category: shopping, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(shopping); context.insert(previous); context.insert(current)

        let result = AskClarityEngine.respond(to: "Why did Shopping increase?", context: .empty, entries: [previous, current], budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.headline.lowercased().contains("didn't change significantly"), result.answer.headline)
    }
}

// MARK: - Planner: simple queries

/// Exercises `AskClarityPlanner.plan(for:context:today:calendar:)` directly — confirms *what* it
/// decides to compute (operation/subject/period/ranking), separate from the wording `AskClarityEngine`
/// produces from that plan. Migrated question shapes (a category amount, a plain ranking, a plain
/// metric total, budget state) must produce a `Plan`; shapes intentionally not yet migrated (why,
/// reduce-advice, assessment, direction/change-ranking) must fall through to `.legacyFallback`
/// rather than being silently mishandled.
final class AskClarityPlannerSimpleQueryTests: XCTestCase {
    func testSimpleCategoryAmountQuestionProducesAnAmountPlan() {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        context.insert(head); context.insert(restaurants)

        guard let query = AskClarityInterpreter.interpret("How much did I spend on restaurants this month?", categories: [restaurants], context: .empty, today: today) else {
            return XCTFail("should interpret")
        }
        guard case .plan(let plan) = AskClarityPlanner.plan(for: query, context: .empty, today: today) else {
            return XCTFail("a plain single-category amount question should produce a Plan")
        }
        XCTAssertEqual(plan.operation, .amount)
        XCTAssertNil(plan.comparison)
        XCTAssertEqual(plan.subjects.count, 1)
        XCTAssertTrue(plan.subjects.first?.singleCategory === restaurants)
        XCTAssertEqual(plan.period.kind, .thisMonth)
    }

    func testSimpleRankingQuestionProducesARankCategoriesPlan() {
        guard let query = AskClarityInterpreter.interpret("Where am I spending the most?", categories: [], context: .empty, today: today) else {
            return XCTFail("should interpret")
        }
        guard case .plan(let plan) = AskClarityPlanner.plan(for: query, context: .empty, today: today) else {
            return XCTFail("a plain ranking question should produce a Plan")
        }
        XCTAssertEqual(plan.operation, .rankCategories)
        XCTAssertEqual(plan.ranking?.direction, .highest)
        XCTAssertEqual(plan.ranking?.wantsList, false)
    }

    /// A plain total-spending question (no category) produces an `.amount` plan with no subjects
    /// — the shared shape a category amount, a comparison, and a plain metric total all use.
    func testPlainTotalSpendingQuestionProducesAnAmountPlanWithNoSubjects() {
        guard let query = AskClarityInterpreter.interpret("How much did I spend this month?", categories: [], context: .empty, today: today) else {
            return XCTFail("should interpret")
        }
        guard case .plan(let plan) = AskClarityPlanner.plan(for: query, context: .empty, today: today) else {
            return XCTFail("a plain metric question with no category should produce a Plan")
        }
        XCTAssertEqual(plan.operation, .amount)
        XCTAssertEqual(plan.metric, .spending)
        XCTAssertTrue(plan.subjects.isEmpty)
        // Spending's existing quirk: "this month" always compares against last month by default,
        // even without an explicit "compared to."
        XCTAssertEqual(plan.comparison, .previousPeriod)
    }

    func testPlainIncomeQuestionOnlyComparesWhenExplicitlyAsked() {
        guard let query = AskClarityInterpreter.interpret("How much income did I earn this month?", categories: [], context: .empty, today: today) else {
            return XCTFail("should interpret")
        }
        guard case .plan(let plan) = AskClarityPlanner.plan(for: query, context: .empty, today: today) else {
            return XCTFail("a plain income question should produce a Plan")
        }
        XCTAssertEqual(plan.metric, .income)
        XCTAssertNil(plan.comparison, "income shouldn't auto-compare the way spending does")
    }

    func testBudgetStateQuestionProducesABudgetStatePlan() {
        guard let query = AskClarityInterpreter.interpret("Am I within my budget?", categories: [], context: .empty, today: today) else {
            return XCTFail("should interpret")
        }
        guard case .plan(let plan) = AskClarityPlanner.plan(for: query, context: .empty, today: today) else {
            return XCTFail("a budget-state question should produce a Plan")
        }
        XCTAssertEqual(plan.operation, .budgetState)
        XCTAssertEqual(plan.budgetState, .withinBudget)
        XCTAssertTrue(plan.subjects.isEmpty, "no category was named, so this is a global check")
    }
}

// MARK: - Planner: compound queries

/// End-to-end (`AskClarityEngine.respond`) coverage for the compositional questions this Query
/// Planner pass was built to support — each combines a metric, a category (single/aggregate/two-
/// sided), a period, and/or a ranking into one plan.
final class AskClarityPlannerCompoundQueryTests: XCTestCase {
    func testHowMuchDidISpendTravellingThisWeekend() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let travelling = TestSupport.makeHeadCategory(name: "Travelling")
        let hotel = TestSupport.makeCategory(name: "Hotel", headCategory: travelling)
        let flights = TestSupport.makeCategory(name: "Flights", headCategory: travelling)
        // June 21-22, 2025 (Sat/Sun) is "this weekend" relative to today (Friday, June 20).
        let hotelEntry = TestSupport.makeEntry(amount: 120, date: testDate(2025, 6, 21), type: .expense, category: hotel, wallet: wallet)
        let flightEntry = TestSupport.makeEntry(amount: 80, date: testDate(2025, 6, 22), type: .expense, category: flights, wallet: wallet)
        let midWeekEntry = TestSupport.makeEntry(amount: 999, date: testDate(2025, 6, 18), type: .expense, category: hotel, wallet: wallet)
        context.insert(wallet); context.insert(travelling); context.insert(hotel); context.insert(flights)
        context.insert(hotelEntry); context.insert(flightEntry); context.insert(midWeekEntry)
        let entries = [hotelEntry, flightEntry, midWeekEntry]

        let result = AskClarityEngine.respond(to: "How much did I spend travelling this weekend?", context: .empty, entries: entries, budgets: [], headCategories: [travelling], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("Travelling"), result.answer.headline)
        XCTAssertTrue(result.answer.headline.contains("this weekend"), result.answer.headline)
        XCTAssertTrue(result.answer.headline.contains("200"), result.answer.headline) // 120 + 80
        XCTAssertFalse(result.answer.headline.contains("999"), result.answer.headline)
    }

    func testDidISpendMoreOnRestaurantsThanGroceriesLastMonth() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let food = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: food)
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: food)
        let restaurantEntry = TestSupport.makeEntry(amount: 150, date: testDate(2025, 5, 10), type: .expense, category: restaurants, wallet: wallet)
        let groceryEntry = TestSupport.makeEntry(amount: 90, date: testDate(2025, 5, 12), type: .expense, category: groceries, wallet: wallet)
        context.insert(wallet); context.insert(food); context.insert(restaurants); context.insert(groceries)
        context.insert(restaurantEntry); context.insert(groceryEntry)

        let result = AskClarityEngine.respond(
            to: "Did I spend more on restaurants than groceries last month?", context: .empty, entries: [restaurantEntry, groceryEntry],
            budgets: [], headCategories: [food], settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.hasPrefix("Yes"), result.answer.headline)
        XCTAssertTrue(result.answer.headline.contains("Restaurants"), result.answer.headline)
        XCTAssertTrue(result.answer.headline.contains("Groceries"), result.answer.headline)
        XCTAssertTrue(result.answer.headline.contains("150"), result.answer.headline)
        XCTAssertTrue(result.answer.headline.contains("90"), result.answer.headline)
    }

    func testWhereDidMostOfMyMoneyGoThisMonth() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let smallEntry = TestSupport.makeEntry(amount: 60, date: testDate(2025, 6, 5), type: .expense, category: groceries, wallet: wallet)
        let bigEntry = TestSupport.makeEntry(amount: 240, date: testDate(2025, 6, 8), type: .expense, category: dining, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(groceries); context.insert(dining); context.insert(smallEntry); context.insert(bigEntry)

        let result = AskClarityEngine.respond(
            to: "Where did most of my money go this month?", context: .empty, entries: [smallEntry, bigEntry],
            budgets: [], headCategories: [head], settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("Dining"), result.answer.headline)
        XCTAssertTrue(result.answer.headline.contains("240"), result.answer.headline)
    }

    func testShowMeMyBiggestExpensesLastWeekend() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Shopping")
        let category = TestSupport.makeCategory(name: "Electronics", headCategory: head)
        // June 14-15, 2025 (Sat/Sun) is "last weekend" relative to today (Friday, June 20).
        let e1 = TestSupport.makeEntry(amount: 300, date: testDate(2025, 6, 14), type: .expense, category: category, wallet: wallet)
        let e2 = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 14), type: .expense, category: category, wallet: wallet)
        let e3 = TestSupport.makeEntry(amount: 90, date: testDate(2025, 6, 15), type: .expense, category: category, wallet: wallet)
        let e4 = TestSupport.makeEntry(amount: 10, date: testDate(2025, 6, 15), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category)
        [e1, e2, e3, e4].forEach { context.insert($0) }
        let entries = [e1, e2, e3, e4]

        let result = AskClarityEngine.respond(to: "Show me my biggest expenses last weekend.", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.lowercased().contains("expenses"), result.answer.headline)
        XCTAssertTrue(result.answer.headline.contains("last weekend"), result.answer.headline)
        XCTAssertTrue(result.answer.supportingDetail.contains("300"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("150"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("90"), result.answer.supportingDetail)
        XCTAssertFalse(result.answer.supportingDetail.contains("10.00"), "the list should cap at the top 3, excluding the smallest: \(result.answer.supportingDetail)")
    }
}

// MARK: - Planner: ambiguous / missing-data queries

/// A genuinely ambiguous or under-specified query must produce an explicit need for clarification
/// (or fall back to a path that already handles it honestly) rather than assuming.
final class AskClarityPlannerAmbiguousQueryTests: XCTestCase {
    /// `AskClarityInterpreter` no longer produces `.ambiguous` itself (a named head category
    /// aggregates instead — see `AskClarityEngineHeadCategoryAggregationTests`), but the planner
    /// must still handle it correctly wherever a category match resolves that way, so this drives
    /// it directly with a hand-built query.
    func testAmbiguousCategoryMatchAsksForClarificationRatherThanGuessing() {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        context.insert(head); context.insert(groceries); context.insert(restaurants)

        var query = AskClarityQuery()
        query.metric = .spending
        query.categoryMatch = .ambiguous(phrase: "food", candidates: [groceries, restaurants])

        guard case .needsClarification(let headline) = AskClarityPlanner.plan(for: query, context: .empty, today: today) else {
            return XCTFail("an ambiguous category match must ask for clarification, never guess")
        }
        XCTAssertTrue(headline.contains("Groceries"), headline)
        XCTAssertTrue(headline.contains("Restaurants"), headline)
    }

    /// "gadgets" isn't a real category, so "restaurants than gadgets" never forms a two-sided
    /// comparison (both sides must resolve) — it degrades to a plain question about the one side
    /// that *does* match, rather than erroring or fabricating a comparison against nothing.
    func testCategoryComparisonWhereOneSideDoesNotMatchDegradesToASingleCategoryQuestion() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let entry = TestSupport.makeEntry(amount: 150, date: testDate(2025, 5, 10), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(entry)

        let result = AskClarityEngine.respond(
            to: "Did I spend more on restaurants than gadgets last month?", context: .empty, entries: [entry],
            budgets: [], headCategories: [head], settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("Restaurants"), result.answer.headline)
        XCTAssertTrue(result.answer.headline.contains("150"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.contains("gadgets"), result.answer.headline)
    }

    /// A comparison plan is still subject to the same unsupported-period rule as everything else
    /// — never silently answered as if "this year" meant the current month.
    func testCategoryComparisonWithAnUnsupportedPeriodReportsUnsupportedNotAGuess() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let entry = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(groceries); context.insert(entry)

        let result = AskClarityEngine.respond(
            to: "Did I spend more on restaurants than groceries this year?", context: .empty, entries: [entry],
            budgets: [], headCategories: [head], settings: testSettings(), today: today
        )

        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains(AskClarityInterpreter.supportedPeriodsDescription), result.answer.headline)
    }

    /// Equal spend on both sides is a tie, not a false "yes" or "no."
    func testEqualSpendOnBothCategoriesReportsATieNotAFalseWinner() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let e1 = TestSupport.makeEntry(amount: 100, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        let e2 = TestSupport.makeEntry(amount: 100, date: testDate(2025, 6, 12), type: .expense, category: groceries, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(groceries); context.insert(e1); context.insert(e2)

        let result = AskClarityEngine.respond(
            to: "Did I spend more on restaurants than groceries this month?", context: .empty, entries: [e1, e2],
            budgets: [], headCategories: [head], settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.lowercased().contains("same"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.hasPrefix("Yes"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.hasPrefix("No"), result.answer.headline)
    }
}

// MARK: - Interpreter: breakdown / trend

final class AskClarityInterpreterBreakdownTrendTests: XCTestCase {
    func testBreakdownPhrasesAreDetected() {
        XCTAssertTrue(AskClarityInterpreter.interpret("Give me a breakdown of my spending this month", categories: [], context: .empty, today: today)?.wantsBreakdown ?? false)
        XCTAssertTrue(AskClarityInterpreter.interpret("How does my spending split by category this month?", categories: [], context: .empty, today: today)?.wantsBreakdown ?? false)
        XCTAssertFalse(AskClarityInterpreter.interpret("How much did I spend this month?", categories: [], context: .empty, today: today)?.wantsBreakdown ?? true)
    }

    func testBareTrendKeywordSetsWantsTrendWithNoExplicitSpan() {
        let query = AskClarityInterpreter.interpret("What's my spending trend?", categories: [], context: .empty, today: today)
        XCTAssertTrue(query?.wantsTrend ?? false)
        XCTAssertNil(query?.trendSpan)
    }

    func testExplicitMonthSpanPhraseSetsTrendSpanAndDefaultsThePeriod() {
        let query = AskClarityInterpreter.interpret("Show me my spending over the last 6 months", categories: [], context: .empty, today: today)
        XCTAssertTrue(query?.wantsTrend ?? false)
        XCTAssertEqual(query?.trendSpan, 6)
        guard case .supported(let period) = query?.periodMatch else { return XCTFail("should default the base period to this month") }
        XCTAssertEqual(period.kind, .thisMonth)
    }

    /// "Past N weeks" is ambiguous between two real meanings — a per-week *trend* ("trending over
    /// the past 3 weeks") or a single *window* to total ("how much did I spend the past 3 weeks,"
    /// see `AskClarityInterpreterDateRangeTests`). Weeks only count as a trend span when an
    /// explicit trend cue is also present; bare "past 3 weeks" alone is a date range instead (see
    /// `parseTrend`'s doc comment for the full reasoning). Months have no such competing meaning,
    /// so they need no cue.
    func testWeekSpanOnlyCountsAsATrendWhenATrendCueIsAlsoPresent() {
        let withCue = AskClarityInterpreter.interpret("Show me my spending trend over the past 3 weeks", categories: [], context: .empty, today: today)
        XCTAssertTrue(withCue?.wantsTrend ?? false)
        XCTAssertEqual(withCue?.trendSpan, 3)
        guard case .supported(let period) = withCue?.periodMatch else { return XCTFail() }
        XCTAssertEqual(period.kind, .thisWeek)

        let withoutCue = AskClarityInterpreter.interpret("Spending over the past 3 weeks", categories: [], context: .empty, today: today)
        XCTAssertFalse(withoutCue?.wantsTrend ?? true, "no 'trend' word — this is a plain date-range period, not a trend")
    }

    func testNumberWordSpanIsRecognizedJustLikeADigit() {
        let query = AskClarityInterpreter.interpret("Spending trend for the last three months", categories: [], context: .empty, today: today)
        XCTAssertEqual(query?.trendSpan, 3)
    }

    func testAnExplicitPeriodIsNeverOverriddenByTheTrendSpanDefault() {
        let query = AskClarityInterpreter.interpret("Spending trend in January", categories: [], context: .empty, today: today)
        guard case .supported(let period) = query?.periodMatch, case .specificMonth = period.kind else {
            return XCTFail("an explicitly-named month should win over the trend span's own period default")
        }
    }
}

// MARK: - Interpreter: date ranges

final class AskClarityInterpreterDateRangeTests: XCTestCase {
    func testConcreteDateAlreadyPassedThisYearResolvesWithinThisYear() {
        let query = AskClarityInterpreter.interpret("How much did I spend on June 5?", categories: [], context: .empty, today: today)
        guard case .supported(let period) = query?.periodMatch, let bounds = dateRangeBounds(period.kind) else {
            return XCTFail("should resolve to a date range")
        }
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: bounds.start), DateComponents(year: 2025, month: 6, day: 5))
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: bounds.end), DateComponents(year: 2025, month: 6, day: 6))
    }

    /// "December 25" hasn't happened yet this year relative to June 20 — must resolve to last
    /// December, not a future date, the same rule an explicit month name already follows.
    func testConcreteDateNotYetReachedThisYearRollsBackToLastYear() {
        let query = AskClarityInterpreter.interpret("How much did I spend on December 25?", categories: [], context: .empty, today: today)
        guard case .supported(let period) = query?.periodMatch, let bounds = dateRangeBounds(period.kind) else {
            return XCTFail("should resolve to a date range")
        }
        XCTAssertEqual(Calendar.current.component(.year, from: bounds.start), 2024)
        XCTAssertEqual(Calendar.current.component(.month, from: bounds.start), 12)
        XCTAssertEqual(Calendar.current.component(.day, from: bounds.start), 25)
    }

    func testExplicitTwoSidedRangeResolvesBothEndsInTheSameRolledBackYear() {
        let query = AskClarityInterpreter.interpret("September 5 to September 18", categories: [], context: .empty, today: today)
        guard case .supported(let period) = query?.periodMatch, let bounds = dateRangeBounds(period.kind) else {
            return XCTFail("should resolve to a date range")
        }
        // September hasn't happened yet this year (relative to June 20), so both ends roll back
        // to the same September 2024 — never a mismatched pair from two different years.
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: bounds.start), DateComponents(year: 2024, month: 9, day: 5))
        // `end` is exclusive, so September 18 (the last included day) is stored as September 19.
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: bounds.end), DateComponents(year: 2024, month: 9, day: 19))
    }

    func testRangeWhoseEndComesBeforeItsStartAsksForClarification() {
        let query = AskClarityInterpreter.interpret("September 18 to September 5", categories: [], context: .empty, today: today)
        guard case .ambiguous = query?.periodMatch else {
            return XCTFail("an end date before the start date must never be silently guessed at")
        }
    }

    func testInvalidDayOfMonthAsksForClarificationRatherThanOverflowingIntoTheNextMonth() {
        let query = AskClarityInterpreter.interpret("How much did I spend on September 31?", categories: [], context: .empty, today: today)
        guard case .ambiguous = query?.periodMatch else {
            return XCTFail("September only has 30 days — this must never silently normalize into October 1")
        }
    }

    func testLastNDaysIsExactlyThatManyDaysEndingToday() {
        let query = AskClarityInterpreter.interpret("How much did I spend in the last 7 days?", categories: [], context: .empty, today: today)
        guard case .supported(let period) = query?.periodMatch, let bounds = dateRangeBounds(period.kind) else {
            return XCTFail("should resolve to a date range")
        }
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: bounds.start), DateComponents(year: 2025, month: 6, day: 14))
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: bounds.end), DateComponents(year: 2025, month: 6, day: 21))
    }

    func testLast30DaysCrossesTheMonthBoundaryCorrectly() {
        let query = AskClarityInterpreter.interpret("How much did I spend in the last 30 days?", categories: [], context: .empty, today: today)
        guard case .supported(let period) = query?.periodMatch, let bounds = dateRangeBounds(period.kind) else {
            return XCTFail("should resolve to a date range")
        }
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: bounds.start), DateComponents(year: 2025, month: 5, day: 22))
    }

    func testPastNWeeksWithNoTrendCueResolvesToNTimesSevenDays() {
        let query = AskClarityInterpreter.interpret("How much did I spend in the past 2 weeks?", categories: [], context: .empty, today: today)
        guard case .supported(let period) = query?.periodMatch, let bounds = dateRangeBounds(period.kind) else {
            return XCTFail("should resolve to a date range")
        }
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: bounds.start), DateComponents(year: 2025, month: 6, day: 7))
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: bounds.end), DateComponents(year: 2025, month: 6, day: 21))
    }

    func testFirstTwoWeeksOfAMonthCoversFourteenDaysFromItsStart() {
        let query = AskClarityInterpreter.interpret("How much did I spend in the first two weeks of September?", categories: [], context: .empty, today: today)
        guard case .supported(let period) = query?.periodMatch, let bounds = dateRangeBounds(period.kind) else {
            return XCTFail("should resolve to a date range")
        }
        // September hasn't happened yet this year, so this rolls back to September 2024.
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: bounds.start), DateComponents(year: 2024, month: 9, day: 1))
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: bounds.end), DateComponents(year: 2024, month: 9, day: 15))
    }

    func testFirstWeeksCountBeyondTheSaneCapAsksForClarification() {
        let query = AskClarityInterpreter.interpret("The first 10 weeks of September", categories: [], context: .empty, today: today)
        guard case .ambiguous = query?.periodMatch else {
            return XCTFail("a month doesn't have 10 weeks — this must be flagged, not silently spill into other months")
        }
    }

    func testUnparsableCountInATrailingWindowPhraseAsksForClarification() {
        let query = AskClarityInterpreter.interpret("How much did I spend in the last several days?", categories: [], context: .empty, today: today)
        guard case .ambiguous = query?.periodMatch else {
            return XCTFail("'last <something> days' is clearly attempting a window, so an unparsable count should ask for clarification rather than being silently dropped")
        }
    }

    /// A plain month name with no day number must keep resolving to the whole month exactly as
    /// before — the new date-range parsing runs first (to intercept "September 5"-style phrases)
    /// but must never swallow a bare month name in the process.
    func testBareMonthNameStillResolvesToTheWholeMonth() {
        let query = AskClarityInterpreter.interpret("How much did I spend in September?", categories: [], context: .empty, today: today)
        guard case .supported(let period) = query?.periodMatch, case .specificMonth = period.kind else {
            return XCTFail("a bare month name should still resolve to the whole month, not a date range")
        }
    }
}

// MARK: - Engine: date ranges

final class AskClarityEngineDateRangeTests: XCTestCase {
    func testSpendingOnASpecificDateOnlyCountsThatDay() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let dayBefore = TestSupport.makeEntry(amount: 999, date: testDate(2025, 6, 4), type: .expense, category: dining, wallet: wallet)
        let theDay = TestSupport.makeEntry(amount: 45, date: testDate(2025, 6, 5), type: .expense, category: dining, wallet: wallet)
        let dayAfter = TestSupport.makeEntry(amount: 999, date: testDate(2025, 6, 6), type: .expense, category: dining, wallet: wallet)
        let entries = [dayBefore, theDay, dayAfter]
        context.insert(wallet); context.insert(head); context.insert(dining)
        entries.forEach { context.insert($0) }

        let result = AskClarityEngine.respond(to: "How much did I spend on June 5?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("45"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.contains("999"), result.answer.headline)
    }

    /// The end date of an explicit range is inclusive of that whole day — an entry dated exactly
    /// on the range's last day must still count, and the day right after must not.
    func testExplicitRangeIncludesItsLastDayButExcludesTheDayAfter() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Shopping")
        let category = TestSupport.makeCategory(name: "Electronics", headCategory: head)
        let start = TestSupport.makeEntry(amount: 40, date: testDate(2024, 9, 5), type: .expense, category: category, wallet: wallet)
        let middle = TestSupport.makeEntry(amount: 60, date: testDate(2024, 9, 12), type: .expense, category: category, wallet: wallet)
        let lastDay = TestSupport.makeEntry(amount: 90, date: testDate(2024, 9, 18), type: .expense, category: category, wallet: wallet)
        let dayAfter = TestSupport.makeEntry(amount: 999, date: testDate(2024, 9, 19), type: .expense, category: category, wallet: wallet)
        let dayBefore = TestSupport.makeEntry(amount: 999, date: testDate(2024, 9, 4), type: .expense, category: category, wallet: wallet)
        let entries = [start, middle, lastDay, dayAfter, dayBefore]
        context.insert(wallet); context.insert(head); context.insert(category)
        entries.forEach { context.insert($0) }

        let result = AskClarityEngine.respond(to: "How much did I spend from September 5 to September 18?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("190"), "40 + 60 + 90 = 190: \(result.answer.headline)") // 40+60+90
        XCTAssertFalse(result.answer.headline.contains("999"), result.answer.headline)
    }

    func testLast7DaysBoundaryIncludesExactlySevenDaysBack() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        // Exactly 7 days before June 20 is June 14 — the oldest day still inside the window.
        let sevenDaysAgo = TestSupport.makeEntry(amount: 30, date: testDate(2025, 6, 14), type: .expense, category: dining, wallet: wallet)
        let eightDaysAgo = TestSupport.makeEntry(amount: 999, date: testDate(2025, 6, 13), type: .expense, category: dining, wallet: wallet)
        let entries = [sevenDaysAgo, eightDaysAgo]
        context.insert(wallet); context.insert(head); context.insert(dining)
        entries.forEach { context.insert($0) }

        let result = AskClarityEngine.respond(to: "How much did I spend in the last 7 days?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("30"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.contains("999"), result.answer.headline)
    }

    /// "Last 30 days" from June 20 reaches back into May — the total must still be correct across
    /// that month boundary, exercising the exact concern this task calls out explicitly.
    func testLast30DaysSumsCorrectlyAcrossAMonthBoundary() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let inMay = TestSupport.makeEntry(amount: 25, date: testDate(2025, 5, 25), type: .expense, category: dining, wallet: wallet)
        let inJune = TestSupport.makeEntry(amount: 35, date: testDate(2025, 6, 10), type: .expense, category: dining, wallet: wallet)
        let tooEarly = TestSupport.makeEntry(amount: 999, date: testDate(2025, 5, 20), type: .expense, category: dining, wallet: wallet)
        let entries = [inMay, inJune, tooEarly]
        context.insert(wallet); context.insert(head); context.insert(dining)
        entries.forEach { context.insert($0) }

        let result = AskClarityEngine.respond(to: "How much did I spend in the last 30 days?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("60"), "25 + 35 = 60, crossing the May/June boundary: \(result.answer.headline)")
        XCTAssertFalse(result.answer.headline.contains("999"), result.answer.headline)
    }

    /// "The first two weeks of September," asked in June, rolls back to September of the
    /// *previous* year — a year change, not just a month change.
    func testFirstTwoWeeksOfMonthRollsBackAcrossAYearBoundary() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let withinWindow = TestSupport.makeEntry(amount: 70, date: testDate(2024, 9, 10), type: .expense, category: dining, wallet: wallet)
        let afterWindow = TestSupport.makeEntry(amount: 999, date: testDate(2024, 9, 16), type: .expense, category: dining, wallet: wallet)
        let wrongYear = TestSupport.makeEntry(amount: 999, date: testDate(2023, 9, 10), type: .expense, category: dining, wallet: wallet)
        let entries = [withinWindow, afterWindow, wrongYear]
        context.insert(wallet); context.insert(head); context.insert(dining)
        entries.forEach { context.insert($0) }

        let result = AskClarityEngine.respond(to: "How much did I spend in the first two weeks of September?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("70"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.contains("999"), result.answer.headline)
    }

    func testDateRangeWithNoMatchingSpendingReportsInsufficientDataNotAnEmptyZero() {
        let result = AskClarityEngine.respond(to: "How much did I spend in the last 7 days?", context: .empty, entries: [], budgets: [], headCategories: [], settings: testSettings(), today: today)

        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.lowercased().contains("no spending logged"), result.answer.headline)
    }

    func testInvalidDateAsksForClarificationInsteadOfDefaultingToThisMonth() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let entry = TestSupport.makeEntry(amount: 100, date: testDate(2025, 6, 10), type: .expense, wallet: wallet)
        context.insert(wallet); context.insert(entry)

        let result = AskClarityEngine.respond(to: "How much did I spend on September 31?", context: .empty, entries: [entry], budgets: [], headCategories: [], settings: testSettings(), today: today)

        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.lowercased().contains("couldn't tell"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.contains("100"), "must never silently fall back to answering about this month's spending: \(result.answer.headline)")
    }

    func testRangeEndBeforeStartAsksForClarificationInsteadOfDefaultingToThisMonth() {
        let result = AskClarityEngine.respond(to: "How much did I spend from September 18 to September 5?", context: .empty, entries: [], budgets: [], headCategories: [], settings: testSettings(), today: today)

        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.lowercased().contains("couldn't tell"), result.answer.headline)
    }

    /// Composes the new date-range period with an existing, already-supported capability
    /// (a specific category) — the same composability every other planned operation already has.
    func testDateRangeComposesWithASpecificCategory() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let restaurantEntry = TestSupport.makeEntry(amount: 55, date: testDate(2025, 6, 15), type: .expense, category: restaurants, wallet: wallet)
        let groceryEntry = TestSupport.makeEntry(amount: 999, date: testDate(2025, 6, 15), type: .expense, category: groceries, wallet: wallet)
        let entries = [restaurantEntry, groceryEntry]
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(groceries)
        entries.forEach { context.insert($0) }

        let result = AskClarityEngine.respond(to: "How much did I spend on Restaurants in the last 7 days?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("Restaurants"), result.answer.headline)
        XCTAssertTrue(result.answer.headline.contains("55"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.contains("999"), result.answer.headline)
    }

    /// Composes the new date-range period with an existing ranking operation — "top transactions"
    /// over an explicit window rather than a named one.
    func testDateRangeComposesWithTransactionRanking() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Shopping")
        let category = TestSupport.makeCategory(name: "Electronics", headCategory: head)
        let big = TestSupport.makeEntry(amount: 300, date: testDate(2025, 6, 15), type: .expense, category: category, wallet: wallet)
        let small = TestSupport.makeEntry(amount: 20, date: testDate(2025, 6, 16), type: .expense, category: category, wallet: wallet)
        let outsideWindow = TestSupport.makeEntry(amount: 999, date: testDate(2025, 6, 1), type: .expense, category: category, wallet: wallet)
        let entries = [big, small, outsideWindow]
        context.insert(wallet); context.insert(head); context.insert(category)
        entries.forEach { context.insert($0) }

        let result = AskClarityEngine.respond(to: "What was my biggest expense in the last 7 days?", context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), today: today)

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("300"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.contains("999"), result.answer.headline)
    }
}

// MARK: - Planner: category breakdown

final class AskClarityPlannerCategoryBreakdownTests: XCTestCase {
    func testGlobalBreakdownListsEveryCategoryThisMonth() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let groceriesEntry = TestSupport.makeEntry(amount: 60, date: testDate(2025, 6, 5), type: .expense, category: groceries, wallet: wallet)
        let diningEntry = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 8), type: .expense, category: dining, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(groceries); context.insert(dining)
        context.insert(groceriesEntry); context.insert(diningEntry)

        let result = AskClarityEngine.respond(
            to: "Give me a breakdown of my spending by category this month", context: .empty, entries: [groceriesEntry, diningEntry],
            budgets: [], headCategories: [head], settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.lowercased().contains("spending by category"), result.answer.headline)
        XCTAssertTrue(result.answer.supportingDetail.contains("Groceries"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("60"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("Dining"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("40"), result.answer.supportingDetail)
    }

    /// Naming a parent (head) category breaks the answer down into its own children — composing
    /// "breakdown" with the same parent/subcategory resolution every other question already uses.
    func testBreakdownOfAHeadCategoryListsOnlyItsOwnChildren() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let travelling = TestSupport.makeHeadCategory(name: "Travelling")
        let hotel = TestSupport.makeCategory(name: "Hotel", headCategory: travelling)
        let flights = TestSupport.makeCategory(name: "Flights", headCategory: travelling)
        let food = TestSupport.makeHeadCategory(name: "Food")
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: food)
        let hotelEntry = TestSupport.makeEntry(amount: 120, date: testDate(2025, 6, 5), type: .expense, category: hotel, wallet: wallet)
        let flightEntry = TestSupport.makeEntry(amount: 80, date: testDate(2025, 6, 8), type: .expense, category: flights, wallet: wallet)
        let groceriesEntry = TestSupport.makeEntry(amount: 60, date: testDate(2025, 6, 6), type: .expense, category: groceries, wallet: wallet)
        context.insert(wallet); context.insert(travelling); context.insert(hotel); context.insert(flights); context.insert(food); context.insert(groceries)
        context.insert(hotelEntry); context.insert(flightEntry); context.insert(groceriesEntry)

        let result = AskClarityEngine.respond(
            to: "How does my Travelling spending break down this month?", context: .empty, entries: [hotelEntry, flightEntry, groceriesEntry],
            budgets: [], headCategories: [travelling, food], settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("Travelling"), result.answer.headline)
        XCTAssertTrue(result.answer.supportingDetail.contains("Hotel"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("120"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("Flights"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("80"), result.answer.supportingDetail)
        XCTAssertFalse(result.answer.supportingDetail.contains("Groceries"), result.answer.supportingDetail)
    }

    /// Composes "breakdown" with a raw date-range period (as opposed to a calendar-month one) —
    /// the same two-track period resolution every other planned operation already uses.
    func testBreakdownForARawDateRangePeriod() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Shopping")
        let electronics = TestSupport.makeCategory(name: "Electronics", headCategory: head)
        let clothing = TestSupport.makeCategory(name: "Clothing", headCategory: head)
        // June 21-22, 2025 (Sat/Sun) is "this weekend" relative to today (Friday, June 20).
        let electronicsEntry = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 21), type: .expense, category: electronics, wallet: wallet)
        let clothingEntry = TestSupport.makeEntry(amount: 50, date: testDate(2025, 6, 22), type: .expense, category: clothing, wallet: wallet)
        let midWeekEntry = TestSupport.makeEntry(amount: 999, date: testDate(2025, 6, 18), type: .expense, category: electronics, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(electronics); context.insert(clothing)
        context.insert(electronicsEntry); context.insert(clothingEntry); context.insert(midWeekEntry)

        let result = AskClarityEngine.respond(
            to: "Give me a breakdown of my spending by category this weekend", context: .empty, entries: [electronicsEntry, clothingEntry, midWeekEntry],
            budgets: [], headCategories: [head], settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("this weekend"), result.answer.headline)
        XCTAssertTrue(result.answer.supportingDetail.contains("150"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("50"), result.answer.supportingDetail)
        XCTAssertFalse(result.answer.supportingDetail.contains("999"), result.answer.supportingDetail)
    }

    func testBreakdownWithNoSpendingReportsInsufficientDataRatherThanAnEmptyList() {
        let result = AskClarityEngine.respond(
            to: "Give me a breakdown of my spending by category this month", context: .empty, entries: [],
            budgets: [], headCategories: [], settings: testSettings(), today: today
        )

        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.lowercased().contains("no spending logged"), result.answer.headline)
    }
}

// MARK: - Planner: trend

final class AskClarityPlannerTrendTests: XCTestCase {
    /// A bare "trend" request (no explicit span) defaults to three periods — walking `thisMonth`
    /// -> `lastMonth` -> (bridged) the `specificMonth` two months back, so it still reaches three
    /// points even though `lastMonth` alone doesn't chain any further on its own.
    func testBareSpendingTrendDefaultsToThreeConsecutiveMonths() {
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
            to: "What's my spending trend?", context: .empty, entries: [april, may, june],
            budgets: [], headCategories: [head], settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.lowercased().contains("trend"), result.answer.headline)
        XCTAssertTrue(result.answer.supportingDetail.contains("50"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("80"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("120"), result.answer.supportingDetail)
    }

    func testExplicitSpanTrendCoversExactlyThatManyMonths() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let march = TestSupport.makeEntry(amount: 20, date: testDate(2025, 3, 15), type: .expense, category: dining, wallet: wallet)
        let april = TestSupport.makeEntry(amount: 50, date: testDate(2025, 4, 15), type: .expense, category: dining, wallet: wallet)
        let may = TestSupport.makeEntry(amount: 80, date: testDate(2025, 5, 15), type: .expense, category: dining, wallet: wallet)
        let june = TestSupport.makeEntry(amount: 120, date: testDate(2025, 6, 10), type: .expense, category: dining, wallet: wallet)
        let entries = [march, april, may, june]
        context.insert(wallet); context.insert(head); context.insert(dining)
        entries.forEach { context.insert($0) }

        let result = AskClarityEngine.respond(
            to: "Show me my spending trend over the last 4 months", context: .empty, entries: entries,
            budgets: [], headCategories: [head], settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.supportingDetail.contains("20"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("50"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("80"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("120"), result.answer.supportingDetail)
        XCTAssertFalse(result.answer.supportingDetail.contains("Only"), "all 4 requested months were available, so no shortfall note should appear: \(result.answer.supportingDetail)")
    }

    /// Composes "trend" with a specific category subject — the same per-category totals every
    /// other category-scoped question uses, just repeated across several periods.
    func testCategoryTrendOnlyCountsThatCategoryAcrossEveryPeriod() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let restaurantEntries = [
            TestSupport.makeEntry(amount: 40, date: testDate(2025, 4, 15), type: .expense, category: restaurants, wallet: wallet),
            TestSupport.makeEntry(amount: 60, date: testDate(2025, 5, 15), type: .expense, category: restaurants, wallet: wallet),
            TestSupport.makeEntry(amount: 90, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        ]
        let groceryDistractors = [
            TestSupport.makeEntry(amount: 999, date: testDate(2025, 4, 16), type: .expense, category: groceries, wallet: wallet),
            TestSupport.makeEntry(amount: 999, date: testDate(2025, 5, 16), type: .expense, category: groceries, wallet: wallet),
            TestSupport.makeEntry(amount: 999, date: testDate(2025, 6, 16), type: .expense, category: groceries, wallet: wallet)
        ]
        let entries = restaurantEntries + groceryDistractors
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(groceries)
        entries.forEach { context.insert($0) }

        let result = AskClarityEngine.respond(
            to: "What's my Restaurants spending trend the last 3 months?", context: .empty, entries: entries,
            budgets: [], headCategories: [head], settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("Restaurants"), result.answer.headline)
        XCTAssertTrue(result.answer.supportingDetail.contains("40"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("60"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("90"), result.answer.supportingDetail)
        XCTAssertFalse(result.answer.supportingDetail.contains("999"), result.answer.supportingDetail)
    }

    /// A week-based trend can only ever chain back one step (no "three weeks ago" period kind
    /// exists in this architecture) — asking for a trend anchored on an already-previous period
    /// (here, explicitly "last week," which itself has no further previous) must say so plainly
    /// rather than silently answering with just the two points it *could* compute.
    func testTrendWithoutEnoughChainableHistoryExplainsRatherThanGuessing() {
        let result = AskClarityEngine.respond(
            to: "What's my spending trend last week?", context: .empty, entries: [],
            budgets: [], headCategories: [], settings: testSettings(), today: today
        )

        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.lowercased().contains("enough consecutive periods"), result.answer.headline)
    }
}

// MARK: - Planner: plain metric / budget state composed with comparisons

final class AskClarityPlannerPlainMetricComparisonTests: XCTestCase {
    func testIncomeComparedAgainstLastMonthOnlyWhenExplicitlyRequested() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let previous = TestSupport.makeEntry(amount: 400, date: testDate(2025, 5, 15), type: .income, wallet: wallet)
        let current = TestSupport.makeEntry(amount: 650, date: testDate(2025, 6, 10), type: .income, wallet: wallet)
        context.insert(wallet); context.insert(previous); context.insert(current)

        let result = AskClarityEngine.respond(
            to: "How much income did I earn this month compared to last month?", context: .empty, entries: [previous, current],
            budgets: [], headCategories: [], settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        // Avoids a 4-digit amount so this doesn't depend on the test locale's thousands separator.
        XCTAssertTrue(result.answer.headline.contains(Decimal(650).currencyFormatted), result.answer.headline)
        XCTAssertTrue(result.answer.supportingDetail.contains("more"), result.answer.supportingDetail)
    }

    /// Remaining budget's insufficient-data check is about whether there's *any* budget/spending
    /// data at all, not whether what's left happens to be exactly zero — spending precisely down
    /// to the available amount is a perfectly real, reportable answer.
    func testRemainingBudgetExactlyZeroIsStillReportedNotTreatedAsMissingData() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let income = TestSupport.makeEntry(amount: 500, date: testDate(2025, 6, 1), type: .income, wallet: wallet)
        let expense = TestSupport.makeEntry(amount: 500, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(income); context.insert(expense)

        let result = AskClarityEngine.respond(
            to: "How much budget do I have left?", context: .empty, entries: [income, expense],
            budgets: [], headCategories: [head], settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.hasPrefix("You have"), "spending exactly down to the available amount is real data, not a missing-data case: \(result.answer.headline)")
        XCTAssertTrue(result.answer.headline.contains(Decimal(0).currencyFormatted), result.answer.headline)
    }
}
