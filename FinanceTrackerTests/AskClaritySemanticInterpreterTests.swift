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

private let today = testDate(2025, 6, 20)

/// Records every call it receives and returns a fixed, injected result — never touches the
/// network. Lets tests drive `AskClarityEngine.respondWithSemanticFallback` deterministically and
/// verify exactly how many times (if any) the semantic layer was actually consulted.
private final class StubSemanticProvider: AskClaritySemanticProviding {
    private let result: AskClaritySemanticInterpretation?
    private(set) var callCount = 0
    private(set) var lastContext: AskClaritySemanticContext?

    init(result: AskClaritySemanticInterpretation?) {
        self.result = result
    }

    func interpret(context: AskClaritySemanticContext) async -> AskClaritySemanticInterpretation? {
        callCount += 1
        lastContext = context
        return result
    }
}

// MARK: - Response parsing (malformed/invalid LLM output)

final class AskClaritySemanticResponseParserTests: XCTestCase {
    func testValidJSONParsesEveryField() {
        let json = """
        {"supported":true,"metric":"spending","categoryName":"Restaurants",\
        "period":{"kind":"named","value":"thisMonth"},"ranking":null,"budgetState":null,\
        "wantsBreakdown":false,"wantsTrend":false,"trendSpan":null,"wantsList":false,\
        "wantsTransactionRanking":false,"wantsAssessment":false,"comparisonRequested":true}
        """
        guard let result = AskClaritySemanticResponseParser.parse(json) else {
            return XCTFail("valid JSON should parse")
        }
        XCTAssertTrue(result.supported)
        XCTAssertEqual(result.metric, .spending)
        XCTAssertEqual(result.categoryName, "Restaurants")
        XCTAssertEqual(result.period, .named(.thisMonth))
        XCTAssertTrue(result.comparisonRequested)
    }

    func testSurroundingProseAroundTheJSONObjectIsIgnored() {
        // Mirrors `CategorizationService.parseExtraction`'s own tolerance for a model that adds
        // stray text around the JSON despite being asked not to.
        let text = "Sure, here you go:\n{\"supported\":true,\"metric\":\"income\"} — hope that helps!"
        XCTAssertEqual(AskClaritySemanticResponseParser.parse(text)?.metric, .income)
    }

    func testCompletelyNonJSONTextReturnsNil() {
        XCTAssertNil(AskClaritySemanticResponseParser.parse("I'm not sure how to answer that."))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(AskClaritySemanticResponseParser.parse(""))
    }

    func testTruncatedJSONReturnsNil() {
        XCTAssertNil(AskClaritySemanticResponseParser.parse("{\"supported\":true,\"metric\":\"spend"))
    }

    func testMissingRequiredSupportedFieldReturnsNil() {
        XCTAssertNil(AskClaritySemanticResponseParser.parse("{\"metric\":\"spending\"}"))
    }

    func testSupportedFalseIgnoresEveryOtherField() {
        // Even if a model sets supported=false but still fills in other fields (contradictory
        // output), the parser must not act on any of them.
        let json = "{\"supported\":false,\"metric\":\"spending\",\"categoryName\":\"Anything\"}"
        let result = AskClaritySemanticResponseParser.parse(json)
        XCTAssertEqual(result, .unsupported)
    }

    /// A hallucinated enum value outside the vocabulary given in the prompt — must be dropped
    /// (treated as "not mentioned"), never passed through as if it were real.
    func testUnrecognizedEnumValueIsDroppedNotGuessed() {
        let json = "{\"supported\":true,\"metric\":\"cryptocurrency\",\"ranking\":\"medium\"}"
        guard let result = AskClaritySemanticResponseParser.parse(json) else {
            return XCTFail("should still parse — just with the bad fields dropped")
        }
        XCTAssertNil(result.metric)
        XCTAssertNil(result.ranking)
    }

    func testUnrecognizedPeriodKindIsDropped() {
        let json = "{\"supported\":true,\"period\":{\"kind\":\"nextDecade\",\"value\":\"today\"}}"
        XCTAssertNil(AskClaritySemanticResponseParser.parse(json)?.period)
    }

    func testNamedPeriodWithMissingValueIsDropped() {
        let json = "{\"supported\":true,\"period\":{\"kind\":\"named\"}}"
        XCTAssertNil(AskClaritySemanticResponseParser.parse(json)?.period)
    }

    func testDateRangePeriodParsesBothDates() {
        let json = "{\"supported\":true,\"period\":{\"kind\":\"dateRange\",\"startDate\":\"2025-09-05\",\"endDate\":\"2025-09-18\"}}"
        guard case .dateRange(let start, let end) = AskClaritySemanticResponseParser.parse(json)?.period else {
            return XCTFail("should parse a dateRange period")
        }
        XCTAssertEqual(start, "2025-09-05")
        XCTAssertEqual(end, "2025-09-18")
    }

    func testTrendSpanIsClampedToASaneRange() {
        let json = "{\"supported\":true,\"wantsTrend\":true,\"trendSpan\":9999}"
        XCTAssertEqual(AskClaritySemanticResponseParser.parse(json)?.trendSpan, 24)
    }

    func testEmptyCategoryNameIsTreatedAsNilNotAnEmptyMatch() {
        let json = "{\"supported\":true,\"categoryName\":\"   \"}"
        XCTAssertNil(AskClaritySemanticResponseParser.parse(json)?.categoryName)
    }
}

// MARK: - Query building (Claude output -> AskClarityQuery -> existing Planner/Executor)

final class AskClaritySemanticQueryBuilderTests: XCTestCase {
    func testUnsupportedInterpretationProducesNoQuery() {
        XCTAssertNil(AskClaritySemanticQueryBuilder.buildQuery(from: .unsupported, categories: [], today: today))
    }

    func testValidInterpretationWithNoSignalProducesNoQuery() {
        // supported=true but every field left at its default — nothing to actually plan.
        let interpretation = AskClaritySemanticInterpretation(
            supported: true, metric: nil, categoryName: nil, period: nil, ranking: nil, budgetState: nil,
            wantsBreakdown: false, wantsTrend: false, trendSpan: nil, wantsList: false,
            wantsTransactionRanking: false, wantsAssessment: false, comparisonRequested: false
        )
        XCTAssertNil(AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, categories: [], today: today))
    }

    func testCategoryNameThatMatchesARealCategoryResolvesToIt() {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        context.insert(head); context.insert(restaurants)

        let interpretation = AskClaritySemanticInterpretation(
            supported: true, metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth), ranking: nil,
            budgetState: nil, wantsBreakdown: false, wantsTrend: false, trendSpan: nil, wantsList: false,
            wantsTransactionRanking: false, wantsAssessment: false, comparisonRequested: false
        )
        guard let query = AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, categories: [restaurants], today: today) else {
            return XCTFail("should build a query")
        }
        guard case .resolved(let category) = query.categoryMatch else { return XCTFail("category should resolve") }
        XCTAssertTrue(category === restaurants)
        XCTAssertEqual(query.metric, .spending)
        guard case .supported(let period) = query.periodMatch else { return XCTFail() }
        XCTAssertEqual(period.kind, .thisMonth)
    }

    /// A category name the model invented (not in the list it was given) must never be guessed
    /// at or silently dropped in favor of an unscoped question — the whole interpretation is
    /// rejected instead, exactly like the deterministic interpreter's own "notFound" rule.
    func testHallucinatedCategoryNameProducesNoQuery() {
        let interpretation = AskClaritySemanticInterpretation(
            supported: true, metric: .spending, categoryName: "Nonexistent Category", period: nil, ranking: nil,
            budgetState: nil, wantsBreakdown: false, wantsTrend: false, trendSpan: nil, wantsList: false,
            wantsTransactionRanking: false, wantsAssessment: false, comparisonRequested: false
        )
        XCTAssertNil(AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, categories: [], today: today))
    }

    func testSpecificMonthPeriodResolvesTheSameWayTheLocalInterpreterDoes() {
        let interpretation = AskClaritySemanticInterpretation(
            supported: true, metric: .spending, categoryName: nil, period: .specificMonth(monthName: "September"),
            ranking: nil, budgetState: nil, wantsBreakdown: false, wantsTrend: false, trendSpan: nil, wantsList: false,
            wantsTransactionRanking: false, wantsAssessment: false, comparisonRequested: false
        )
        guard let query = AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, categories: [], today: today) else {
            return XCTFail("should build a query")
        }
        guard case .supported(let period) = query.periodMatch, case .specificMonth(let date) = period.kind else {
            return XCTFail("should resolve to a specific month")
        }
        // September hasn't happened yet this year (today is June 20, 2025) — rolls back to 2024,
        // the exact same rule the deterministic interpreter's `resolveMonthStart` applies.
        XCTAssertEqual(Calendar.current.component(.year, from: date), 2024)
    }

    func testUnrecognizedMonthNameProducesNoQuery() {
        let interpretation = AskClaritySemanticInterpretation(
            supported: true, metric: .spending, categoryName: nil, period: .specificMonth(monthName: "Smarch"),
            ranking: nil, budgetState: nil, wantsBreakdown: false, wantsTrend: false, trendSpan: nil, wantsList: false,
            wantsTransactionRanking: false, wantsAssessment: false, comparisonRequested: false
        )
        XCTAssertNil(AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, categories: [], today: today))
    }

    func testDateRangePeriodResolvesWithTheEndDateInclusive() {
        let interpretation = AskClaritySemanticInterpretation(
            supported: true, metric: .spending, categoryName: nil,
            period: .dateRange(startDate: "2025-06-05", endDate: "2025-06-18"), ranking: nil, budgetState: nil,
            wantsBreakdown: false, wantsTrend: false, trendSpan: nil, wantsList: false,
            wantsTransactionRanking: false, wantsAssessment: false, comparisonRequested: false
        )
        guard let query = AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, categories: [], today: today) else {
            return XCTFail("should build a query")
        }
        guard case .supported(let period) = query.periodMatch, case .dateRange(let start, let end) = period.kind else {
            return XCTFail("should resolve to a date range")
        }
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: start), DateComponents(year: 2025, month: 6, day: 5))
        // End is exclusive internally — June 18 (inclusive per the schema) becomes June 19.
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: end), DateComponents(year: 2025, month: 6, day: 19))
    }

    func testDateRangeWithEndBeforeStartProducesNoQuery() {
        let interpretation = AskClaritySemanticInterpretation(
            supported: true, metric: .spending, categoryName: nil,
            period: .dateRange(startDate: "2025-06-18", endDate: "2025-06-05"), ranking: nil, budgetState: nil,
            wantsBreakdown: false, wantsTrend: false, trendSpan: nil, wantsList: false,
            wantsTransactionRanking: false, wantsAssessment: false, comparisonRequested: false
        )
        XCTAssertNil(AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, categories: [], today: today))
    }

    func testMalformedDateStringProducesNoQuery() {
        let interpretation = AskClaritySemanticInterpretation(
            supported: true, metric: .spending, categoryName: nil,
            period: .dateRange(startDate: "not-a-date", endDate: "2025-06-05"), ranking: nil, budgetState: nil,
            wantsBreakdown: false, wantsTrend: false, trendSpan: nil, wantsList: false,
            wantsTransactionRanking: false, wantsAssessment: false, comparisonRequested: false
        )
        XCTAssertNil(AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, categories: [], today: today))
    }

    /// A built query behaves identically to a locally-interpreted one once handed to the
    /// existing `AskClarityPlanner` — a trend/breakdown/budget-state request from Claude is
    /// planned exactly like the same request typed in the deterministic vocabulary.
    func testBuiltQueryPlansExactlyLikeALocallyInterpretedOne() {
        let interpretation = AskClaritySemanticInterpretation(
            supported: true, metric: nil, categoryName: nil, period: .named(.thisMonth), ranking: nil,
            budgetState: .overBudget, wantsBreakdown: false, wantsTrend: false, trendSpan: nil, wantsList: false,
            wantsTransactionRanking: false, wantsAssessment: false, comparisonRequested: false
        )
        guard let query = AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, categories: [], today: today) else {
            return XCTFail("should build a query")
        }
        guard case .plan(let plan) = AskClarityPlanner.plan(for: query, context: .empty, today: today) else {
            return XCTFail("should produce a Plan, exactly like the deterministic path does for the same concepts")
        }
        XCTAssertEqual(plan.operation, .budgetState)
        XCTAssertEqual(plan.budgetState, .overBudget)
    }
}

// MARK: - Request building (no financial data ever sent)

final class AskClaritySemanticRequestBuilderTests: XCTestCase {
    func testRequestBodyContainsNoFinancialAmounts() throws {
        let context = AskClaritySemanticContext(question: "How much did I spend on restaurants?", today: today, availableCategoryNames: ["Restaurants", "Groceries"])
        guard let data = AskClaritySemanticRequestBuilder.requestBody(context: context, model: "claude-haiku-4-5-20251001", limits: .default) else {
            return XCTFail("should build a request body")
        }
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        // The request is entirely text (question + category names + vocabulary instructions) —
        // there is no numeric amount field in the wire format at all (enforced by
        // `AskClaritySemanticContext`'s own type, which has no such field to serialize), so this
        // is really pinning the shape rather than scanning for a stray number. "Budget" itself
        // legitimately appears as part of the "budgetState" vocabulary description, so that's not
        // a leak — `Entry`/`Decimal`, which would only ever appear from an accidental change that
        // started serializing real transaction data, are the actual red flags checked here.
        XCTAssertTrue(json.contains("Restaurants"))
        XCTAssertTrue(json.contains("claude-haiku-4-5-20251001"))
        XCTAssertFalse(json.contains("Entry"))
        XCTAssertFalse(json.contains("Decimal"))
    }

    func testQuestionLongerThanTheLimitIsTruncated() throws {
        let longQuestion = String(repeating: "a", count: 1000)
        var limits = AskClaritySemanticLimits.default
        limits.maxQuestionLength = 50
        let context = AskClaritySemanticContext(question: longQuestion, today: today, availableCategoryNames: [])
        let data = try XCTUnwrap(AskClaritySemanticRequestBuilder.requestBody(context: context, model: "m", limits: limits))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains(String(repeating: "a", count: 51)))
    }

    func testCategoryListLongerThanTheLimitIsCapped() throws {
        var limits = AskClaritySemanticLimits.default
        limits.maxCategoryNames = 2
        let context = AskClaritySemanticContext(question: "test", today: today, availableCategoryNames: ["One", "Two", "Three", "Four"])
        let data = try XCTUnwrap(AskClaritySemanticRequestBuilder.requestBody(context: context, model: "m", limits: limits))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("One"))
        XCTAssertTrue(json.contains("Two"))
        XCTAssertFalse(json.contains("Three"))
        XCTAssertFalse(json.contains("Four"))
    }

    func testOutputTokenLimitIsRespected() throws {
        var limits = AskClaritySemanticLimits.default
        limits.maxOutputTokens = 123
        let context = AskClaritySemanticContext(question: "test", today: today, availableCategoryNames: [])
        let data = try XCTUnwrap(AskClaritySemanticRequestBuilder.requestBody(context: context, model: "m", limits: limits))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"max_tokens\":123"))
    }
}

// MARK: - Call budget

final class AskClaritySemanticCallBudgetTests: XCTestCase {
    func testHasRemainingCallsBecomesFalseOnceTheLimitIsReached() {
        let budget = AskClaritySemanticCallBudget(maxCalls: 2)
        XCTAssertTrue(budget.hasRemainingCalls)
        budget.recordCall()
        XCTAssertTrue(budget.hasRemainingCalls)
        budget.recordCall()
        XCTAssertFalse(budget.hasRemainingCalls)
    }

    func testZeroMaxCallsNeverAllowsACall() {
        let budget = AskClaritySemanticCallBudget(maxCalls: 0)
        XCTAssertFalse(budget.hasRemainingCalls)
    }
}

// MARK: - AskClarityEngine.respondWithSemanticFallback (end-to-end)

final class AskClarityEngineSemanticFallbackTests: XCTestCase {
    func testLocallyUnderstoodQuestionNeverConsultsTheSemanticProvider() async {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let entry = TestSupport.makeEntry(amount: 40, date: testDate(2025, 6, 10), type: .expense, category: category, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(category); context.insert(entry)

        let stub = StubSemanticProvider(result: nil)
        let result = await AskClarityEngine.respondWithSemanticFallback(
            to: "How much did I spend this month?", context: .empty, entries: [entry], budgets: [],
            headCategories: [head], settings: testSettings(), today: today, semanticProvider: stub
        )

        XCTAssertEqual(stub.callCount, 0, "the deterministic interpreter already understood this question — the LLM must never be consulted")
        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("40"), result.answer.headline)
    }

    /// The core round-trip this phase adds: a question the deterministic interpreter can't parse
    /// at all, classified by a (stubbed) semantic provider, converted into a real `AskClarityQuery`,
    /// and answered through the *unchanged* `AskClarityPlanner`/`AskClarityExecutor`/calculators —
    /// the same real spending figure a locally-understood question would produce.
    func testUnrecognizedQuestionFallsThroughToTheSemanticProviderAndIsAnsweredForReal() async {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let entry = TestSupport.makeEntry(amount: 65, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(entry)

        let interpretation = AskClaritySemanticInterpretation(
            supported: true, metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth), ranking: nil,
            budgetState: nil, wantsBreakdown: false, wantsTrend: false, trendSpan: nil, wantsList: false,
            wantsTransactionRanking: false, wantsAssessment: false, comparisonRequested: false
        )
        let stub = StubSemanticProvider(result: interpretation)

        // A phrasing the deterministic keyword interpreter has no vocabulary for at all.
        let result = await AskClarityEngine.respondWithSemanticFallback(
            to: "I've been treating myself to eating out lately, curious what that's run me", context: .empty,
            entries: [entry], budgets: [], headCategories: [head], settings: testSettings(), today: today, semanticProvider: stub
        )

        XCTAssertEqual(stub.callCount, 1)
        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("Restaurants"), result.answer.headline)
        XCTAssertTrue(result.answer.headline.contains("65"), result.answer.headline)
    }

    /// The exact same semantic interpretation, run against two different sets of real entries,
    /// must produce two different (and each *correct*) amounts — proving the number in the
    /// answer is computed locally from real data every time, never supplied by the semantic layer
    /// (whose interpretation schema has no amount/total field at all to supply one from).
    func testTheFinalAmountAlwaysComesFromRealLocalDataNeverFromTheSemanticLayer() async {
        let interpretation = AskClaritySemanticInterpretation(
            supported: true, metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth), ranking: nil,
            budgetState: nil, wantsBreakdown: false, wantsTrend: false, trendSpan: nil, wantsList: false,
            wantsTransactionRanking: false, wantsAssessment: false, comparisonRequested: false
        )

        func runWithAmount(_ amount: Decimal) async -> String {
            let context = TestSupport.makeInMemoryContext()
            let wallet = TestSupport.makeWallet()
            let head = TestSupport.makeHeadCategory(name: "Food")
            let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
            let entry = TestSupport.makeEntry(amount: amount, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
            context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(entry)
            let stub = StubSemanticProvider(result: interpretation)
            let result = await AskClarityEngine.respondWithSemanticFallback(
                to: "eating out spend", context: .empty, entries: [entry], budgets: [], headCategories: [head],
                settings: testSettings(), today: today, semanticProvider: stub
            )
            return result.answer.headline
        }

        let headlineA = await runWithAmount(30)
        let headlineB = await runWithAmount(90)
        XCTAssertTrue(headlineA.contains("30"), headlineA)
        XCTAssertTrue(headlineB.contains("90"), headlineB)
        XCTAssertNotEqual(headlineA, headlineB)
    }

    func testSemanticProviderUnsupportedFallsBackToTheLocalUnknownAnswer() async {
        let stub = StubSemanticProvider(result: .unsupported)
        let result = await AskClarityEngine.respondWithSemanticFallback(
            to: "What's the capital of France?", context: .empty, entries: [], budgets: [], headCategories: [],
            settings: testSettings(), today: today, semanticProvider: stub
        )
        XCTAssertEqual(stub.callCount, 1)
        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertFalse(result.answer.headline.contains("France"), "must never answer a general-knowledge question: \(result.answer.headline)")
    }

    /// Simulates every real-world failure mode a provider can hit (missing API key, offline,
    /// non-2xx response, malformed reply) — `AskClaritySemanticProviding.interpret` returns `nil`
    /// in all of them, and the app must keep working with the local answer regardless.
    func testProviderFailureFallsBackSafelyToTheLocalUnknownAnswer() async {
        let stub = StubSemanticProvider(result: nil)
        let result = await AskClarityEngine.respondWithSemanticFallback(
            to: "totally unparseable gibberish question", context: .empty, entries: [], budgets: [], headCategories: [],
            settings: testSettings(), today: today, semanticProvider: stub
        )
        XCTAssertEqual(stub.callCount, 1)
        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertEqual(result.answer.headline, "I couldn't find a supported way to answer that yet.")
    }

    /// A hallucinated category name (not in the list the provider was given) must degrade to the
    /// same local "couldn't understand" answer, never a guess.
    func testInterpretationThatCannotBuildAQueryFallsBackToTheLocalUnknownAnswer() async {
        let interpretation = AskClaritySemanticInterpretation(
            supported: true, metric: .spending, categoryName: "Made Up Category", period: nil, ranking: nil,
            budgetState: nil, wantsBreakdown: false, wantsTrend: false, trendSpan: nil, wantsList: false,
            wantsTransactionRanking: false, wantsAssessment: false, comparisonRequested: false
        )
        let stub = StubSemanticProvider(result: interpretation)
        let result = await AskClarityEngine.respondWithSemanticFallback(
            to: "what about that", context: .empty, entries: [], budgets: [], headCategories: [],
            settings: testSettings(), today: today, semanticProvider: stub
        )
        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertEqual(result.answer.headline, "I couldn't find a supported way to answer that yet.")
    }

    func testExhaustedCallBudgetPreventsCallingTheProviderAtAll() async {
        let stub = StubSemanticProvider(result: .unsupported)
        let budget = AskClaritySemanticCallBudget(maxCalls: 0)
        let result = await AskClarityEngine.respondWithSemanticFallback(
            to: "totally unparseable gibberish question", context: .empty, entries: [], budgets: [], headCategories: [],
            settings: testSettings(), today: today, semanticProvider: stub, callBudget: budget
        )
        XCTAssertEqual(stub.callCount, 0)
        XCTAssertFalse(result.answer.hasSufficientData)
    }

    func testCallBudgetIsConsumedAcrossCalls() async {
        let stub = StubSemanticProvider(result: .unsupported)
        let budget = AskClaritySemanticCallBudget(maxCalls: 1)

        _ = await AskClarityEngine.respondWithSemanticFallback(
            to: "gibberish one", context: .empty, entries: [], budgets: [], headCategories: [],
            settings: testSettings(), today: today, semanticProvider: stub, callBudget: budget
        )
        XCTAssertEqual(stub.callCount, 1)

        _ = await AskClarityEngine.respondWithSemanticFallback(
            to: "gibberish two", context: .empty, entries: [], budgets: [], headCategories: [],
            settings: testSettings(), today: today, semanticProvider: stub, callBudget: budget
        )
        XCTAssertEqual(stub.callCount, 1, "the budget was already exhausted by the first call — a second gibberish question must not call the provider again")
    }

    /// The provider only ever receives the question text, today's date, and category *names* —
    /// never entries, budgets, or any Decimal amount (structurally impossible, since
    /// `AskClaritySemanticContext` simply has no such field, but this pins the actual values it
    /// does receive so a future field addition can't quietly smuggle financial data in).
    func testProviderOnlyReceivesQuestionTextAndCategoryNamesNeverFinancialData() async {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let secretEntry = TestSupport.makeEntry(amount: 123_456, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(secretEntry)

        let stub = StubSemanticProvider(result: .unsupported)
        _ = await AskClarityEngine.respondWithSemanticFallback(
            to: "gibberish question", context: .empty, entries: [secretEntry], budgets: [], headCategories: [head],
            settings: testSettings(), today: today, semanticProvider: stub
        )

        let sentContext = try? XCTUnwrap(stub.lastContext)
        XCTAssertEqual(sentContext?.question, "gibberish question")
        XCTAssertEqual(sentContext?.availableCategoryNames, ["Restaurants"])
        // `AskClaritySemanticContext` has no field capable of carrying `secretEntry`'s 123,456
        // amount at all — this is enforced by its type, not by this assertion, but the point
        // stands: nothing observable here ever mentions that figure.
    }
}
