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

/// A "supported=true but every field left at default" interpretation — a convenience for tests
/// that only care about a handful of fields, since `AskClaritySemanticInterpretation` no longer
/// has a `supported` field to construct around (see `AskClaritySemanticOutcome`).
private func blankInterpretation(
    metric: AskClarityMetric? = nil,
    categoryName: String? = nil,
    period: AskClaritySemanticPeriod? = nil,
    ranking: AskClarityRanking? = nil,
    budgetState: AskClarityBudgetStateQuery? = nil,
    wantsBreakdown: Bool = false,
    wantsTrend: Bool = false,
    trendSpan: Int? = nil,
    wantsList: Bool = false,
    wantsTransactionRanking: Bool = false,
    wantsAssessment: Bool = false,
    comparisonRequested: Bool = false
) -> AskClaritySemanticInterpretation {
    AskClaritySemanticInterpretation(
        metric: metric, categoryName: categoryName, period: period, ranking: ranking, budgetState: budgetState,
        wantsBreakdown: wantsBreakdown, wantsTrend: wantsTrend, trendSpan: trendSpan, wantsList: wantsList,
        wantsTransactionRanking: wantsTransactionRanking, wantsAssessment: wantsAssessment, comparisonRequested: comparisonRequested
    )
}

/// Records every call it receives and returns a fixed, injected result — never touches the
/// network. Lets tests drive `AskClarityEngine.respondWithSemanticFallback` deterministically and
/// verify exactly how many times (if any) the semantic layer was actually consulted.
private final class StubSemanticProvider: AskClaritySemanticProviding {
    private let result: AskClaritySemanticOutcome?
    private(set) var callCount = 0
    private(set) var lastContext: AskClaritySemanticContext?

    init(result: AskClaritySemanticOutcome?) {
        self.result = result
    }

    func interpret(context: AskClaritySemanticContext) async -> AskClaritySemanticOutcome? {
        callCount += 1
        lastContext = context
        return result
    }
}

// MARK: - Response parsing (malformed/invalid LLM output)

final class AskClaritySemanticResponseParserTests: XCTestCase {
    func testValidJSONParsesEveryField() {
        let json = """
        {"result":"understood","metric":"spending","categoryName":"Restaurants",\
        "period":{"kind":"named","value":"thisMonth"},"ranking":null,"budgetState":null,\
        "wantsBreakdown":false,"wantsTrend":false,"trendSpan":null,"wantsList":false,\
        "wantsTransactionRanking":false,"wantsAssessment":false,"comparisonRequested":true}
        """
        guard case .understood(let result) = AskClaritySemanticResponseParser.parse(json) else {
            return XCTFail("valid JSON should parse to .understood")
        }
        XCTAssertEqual(result.metric, .spending)
        XCTAssertEqual(result.categoryName, "Restaurants")
        XCTAssertEqual(result.period, .named(.thisMonth))
        XCTAssertTrue(result.comparisonRequested)
    }

    func testSurroundingProseAroundTheJSONObjectIsIgnored() {
        // Mirrors `CategorizationService.parseExtraction`'s own tolerance for a model that adds
        // stray text around the JSON despite being asked not to.
        let text = "Sure, here you go:\n{\"result\":\"understood\",\"metric\":\"income\"} — hope that helps!"
        guard case .understood(let result) = AskClaritySemanticResponseParser.parse(text) else {
            return XCTFail("should still parse to .understood")
        }
        XCTAssertEqual(result.metric, .income)
    }

    func testCompletelyNonJSONTextReturnsNil() {
        XCTAssertNil(AskClaritySemanticResponseParser.parse("I'm not sure how to answer that."))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(AskClaritySemanticResponseParser.parse(""))
    }

    func testTruncatedJSONReturnsNil() {
        XCTAssertNil(AskClaritySemanticResponseParser.parse("{\"result\":\"understood\",\"metric\":\"spend"))
    }

    func testMissingRequiredResultFieldReturnsNil() {
        XCTAssertNil(AskClaritySemanticResponseParser.parse("{\"metric\":\"spending\"}"))
    }

    func testResultUnsupportedIgnoresEveryOtherField() {
        // Even if a model sets result=unsupported but still fills in other fields (contradictory
        // output), the parser must not act on any of them — `.unsupported` carries no fields at all.
        let json = "{\"result\":\"unsupported\",\"metric\":\"spending\",\"categoryName\":\"Anything\"}"
        XCTAssertEqual(AskClaritySemanticResponseParser.parse(json), .unsupported)
    }

    /// The new three-way outcome this phase adds: an in-scope-but-ambiguous question must produce
    /// its own distinct result, never silently folded into `.unsupported` or a guessed `.understood`.
    func testResultNeedsClarificationIsReturnedAsItsOwnDistinctOutcome() {
        let json = "{\"result\":\"needsClarification\",\"metric\":\"spending\"}"
        XCTAssertEqual(AskClaritySemanticResponseParser.parse(json), .needsClarification)
    }

    /// A hallucinated "result" value outside the fixed three — never guessed at; treated exactly
    /// like a provider failure (nil), not defaulted to any of the three real outcomes.
    func testUnrecognizedResultValueReturnsNilRatherThanGuessingAnOutcome() {
        XCTAssertNil(AskClaritySemanticResponseParser.parse("{\"result\":\"maybe\"}"))
    }

    /// A hallucinated enum value outside the vocabulary given in the prompt — must be dropped
    /// (treated as "not mentioned"), never passed through as if it were real.
    func testUnrecognizedEnumValueIsDroppedNotGuessed() {
        let json = "{\"result\":\"understood\",\"metric\":\"cryptocurrency\",\"ranking\":\"medium\"}"
        guard case .understood(let result) = AskClaritySemanticResponseParser.parse(json) else {
            return XCTFail("should still parse — just with the bad fields dropped")
        }
        XCTAssertNil(result.metric)
        XCTAssertNil(result.ranking)
    }

    func testUnrecognizedPeriodKindIsDropped() {
        let json = "{\"result\":\"understood\",\"period\":{\"kind\":\"nextDecade\",\"value\":\"today\"}}"
        guard case .understood(let result) = AskClaritySemanticResponseParser.parse(json) else {
            return XCTFail("should still parse")
        }
        XCTAssertNil(result.period)
    }

    func testNamedPeriodWithMissingValueIsDropped() {
        let json = "{\"result\":\"understood\",\"period\":{\"kind\":\"named\"}}"
        guard case .understood(let result) = AskClaritySemanticResponseParser.parse(json) else {
            return XCTFail("should still parse")
        }
        XCTAssertNil(result.period)
    }

    func testDateRangePeriodParsesBothDates() {
        let json = "{\"result\":\"understood\",\"period\":{\"kind\":\"dateRange\",\"startDate\":\"2025-09-05\",\"endDate\":\"2025-09-18\"}}"
        guard case .understood(let result) = AskClaritySemanticResponseParser.parse(json), case .dateRange(let start, let end) = result.period else {
            return XCTFail("should parse a dateRange period")
        }
        XCTAssertEqual(start, "2025-09-05")
        XCTAssertEqual(end, "2025-09-18")
    }

    func testTrendSpanIsClampedToASaneRange() {
        let json = "{\"result\":\"understood\",\"wantsTrend\":true,\"trendSpan\":9999}"
        guard case .understood(let result) = AskClaritySemanticResponseParser.parse(json) else {
            return XCTFail("should still parse")
        }
        XCTAssertEqual(result.trendSpan, 24)
    }

    func testEmptyCategoryNameIsTreatedAsNilNotAnEmptyMatch() {
        let json = "{\"result\":\"understood\",\"categoryName\":\"   \"}"
        guard case .understood(let result) = AskClaritySemanticResponseParser.parse(json) else {
            return XCTFail("should still parse")
        }
        XCTAssertNil(result.categoryName)
    }
}

// MARK: - Query building (Claude output -> AskClarityQuery -> existing Planner/Executor)

final class AskClaritySemanticQueryBuilderTests: XCTestCase {
    func testInterpretationWithNoSignalProducesNoQuery() {
        // Every field left at its default — nothing to actually plan.
        let interpretation = blankInterpretation()
        XCTAssertNil(AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, question: "test", categories: [], today: today))
    }

    func testCategoryNameThatMatchesARealCategoryResolvesToIt() {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        context.insert(head); context.insert(restaurants)

        let interpretation = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        guard let query = AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, question: "how much on restaurants this month", categories: [restaurants], today: today) else {
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
        let interpretation = blankInterpretation(metric: .spending, categoryName: "Nonexistent Category")
        XCTAssertNil(AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, question: "test", categories: [], today: today))
    }

    func testSpecificMonthPeriodResolvesTheSameWayTheLocalInterpreterDoes() {
        let interpretation = blankInterpretation(metric: .spending, period: .specificMonth(monthName: "September"))
        guard let query = AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, question: "how much in september", categories: [], today: today) else {
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
        let interpretation = blankInterpretation(metric: .spending, period: .specificMonth(monthName: "Smarch"))
        XCTAssertNil(AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, question: "test", categories: [], today: today))
    }

    func testDateRangePeriodResolvesWithTheEndDateInclusive() {
        let interpretation = blankInterpretation(metric: .spending, period: .dateRange(startDate: "2025-06-05", endDate: "2025-06-18"))
        guard let query = AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, question: "test", categories: [], today: today) else {
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
        let interpretation = blankInterpretation(metric: .spending, period: .dateRange(startDate: "2025-06-18", endDate: "2025-06-05"))
        XCTAssertNil(AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, question: "test", categories: [], today: today))
    }

    func testMalformedDateStringProducesNoQuery() {
        let interpretation = blankInterpretation(metric: .spending, period: .dateRange(startDate: "not-a-date", endDate: "2025-06-05"))
        XCTAssertNil(AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, question: "test", categories: [], today: today))
    }

    /// A built query behaves identically to a locally-interpreted one once handed to the
    /// existing `AskClarityPlanner` — a trend/breakdown/budget-state request from Claude is
    /// planned exactly like the same request typed in the deterministic vocabulary.
    func testBuiltQueryPlansExactlyLikeALocallyInterpretedOne() {
        let interpretation = blankInterpretation(period: .named(.thisMonth), budgetState: .overBudget)
        guard let query = AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, question: "am I over budget this month", categories: [], today: today) else {
            return XCTFail("should build a query")
        }
        guard case .plan(let plan) = AskClarityPlanner.plan(for: query, context: .empty, today: today) else {
            return XCTFail("should produce a Plan, exactly like the deterministic path does for the same concepts")
        }
        XCTAssertEqual(plan.operation, .budgetState)
        XCTAssertEqual(plan.budgetState, .overBudget)
    }

    // MARK: Ambiguity stabilization ("recently"/"lately"/"recent" always mean the same period)

    func testRecentlyAlwaysMapsToTheFixedThisWeekPeriodEvenWhenTheModelClaimedSomethingElse() {
        // The (simulated) model claims "thisMonth" — the fixed word rule must override it anyway.
        let interpretation = blankInterpretation(metric: .spending, period: .named(.thisMonth))
        guard let query = AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, question: "Where did most of my money go recently?", categories: [], today: today) else {
            return XCTFail("should build a query")
        }
        guard case .supported(let period) = query.periodMatch else { return XCTFail() }
        XCTAssertEqual(period.kind, .thisWeek)
    }

    func testLatelyAndRecentAlsoMapToTheSameFixedThisWeekPeriod() {
        for word in ["lately", "recent"] {
            let interpretation = blankInterpretation(metric: .spending, period: nil)
            guard let query = AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, question: "How much have I spent \(word)?", categories: [], today: today) else {
                return XCTFail("should build a query for \"\(word)\"")
            }
            guard case .supported(let period) = query.periodMatch else { return XCTFail("no period resolved for \"\(word)\"") }
            XCTAssertEqual(period.kind, .thisWeek, "\"\(word)\" should map to thisWeek")
        }
    }

    func testQuestionsWithoutAFixedWordKeepWhateverPeriodTheModelReturned() {
        let interpretation = blankInterpretation(metric: .spending, period: .named(.thisMonth))
        guard let query = AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, question: "How much did I spend this month?", categories: [], today: today) else {
            return XCTFail("should build a query")
        }
        guard case .supported(let period) = query.periodMatch else { return XCTFail() }
        XCTAssertEqual(period.kind, .thisMonth)
    }

    /// "recent" must match as a whole word only — a question that merely contains "recent" as a
    /// substring of an unrelated word must not trigger the override.
    func testFixedWordMatchingIsWholeWordNotSubstring() {
        let interpretation = blankInterpretation(metric: .spending, period: .named(.thisMonth))
        guard let query = AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, question: "How much did I spend on recreational activities this month?", categories: [], today: today) else {
            return XCTFail("should build a query")
        }
        guard case .supported(let period) = query.periodMatch else { return XCTFail() }
        XCTAssertEqual(period.kind, .thisMonth, "\"recreational\" contains \"recent\" as a substring but is a different word and must not trigger the override")
    }
}

// MARK: - Request building (no financial data ever sent; deterministic decoding)

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

    /// Determinism requirement: decoding must be as close to deterministic as the API allows.
    func testRequestBodyUsesZeroTemperatureForDeterministicDecoding() throws {
        let context = AskClaritySemanticContext(question: "test", today: today, availableCategoryNames: [])
        let data = try XCTUnwrap(AskClaritySemanticRequestBuilder.requestBody(context: context, model: "m", limits: .default))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"temperature\":0"), json)
    }

    /// The prompt itself must state the fixed word rules this phase adds — belt-and-suspenders
    /// alongside the code-level override in `AskClaritySemanticAmbiguityRules`.
    func testInstructionsDefineAFixedMappingForRecentlyLatelyAndRecent() {
        let instructions = AskClaritySemanticRequestBuilder.instructions
        XCTAssertTrue(instructions.contains("\"recently\""))
        XCTAssertTrue(instructions.contains("\"lately\""))
        XCTAssertTrue(instructions.contains("\"recent\""))
        XCTAssertTrue(instructions.contains("thisWeek"))
    }

    func testInstructionsDefineTheThreeWayResultVocabularyIncludingNeedsClarification() {
        let instructions = AskClaritySemanticRequestBuilder.instructions
        XCTAssertTrue(instructions.contains("needsClarification"))
        XCTAssertTrue(instructions.contains("unsupported"))
        XCTAssertTrue(instructions.contains("understood"))
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

        let interpretation = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let stub = StubSemanticProvider(result: .understood(interpretation))

        // A phrasing the deterministic keyword interpreter has no vocabulary for at all.
        let result = await AskClarityEngine.respondWithSemanticFallback(
            to: "I've been treating myself to eating out, curious what that's run me", context: .empty,
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
        let interpretation = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))

        func runWithAmount(_ amount: Decimal) async -> String {
            let context = TestSupport.makeInMemoryContext()
            let wallet = TestSupport.makeWallet()
            let head = TestSupport.makeHeadCategory(name: "Food")
            let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
            let entry = TestSupport.makeEntry(amount: amount, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
            context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(entry)
            let stub = StubSemanticProvider(result: .understood(interpretation))
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

    /// The new three-way outcome this phase adds: `.needsClarification` must produce a distinct
    /// answer from plain `.unsupported` — the point is that the user gets asked to be more
    /// specific, not told the question is out of scope entirely — and the message must be a fixed,
    /// locally-authored string, never text composed by Claude (no LLM response generation yet).
    func testNeedsClarificationProducesADistinctLocallyAuthoredClarificationAnswer() async {
        let stub = StubSemanticProvider(result: .needsClarification)
        let result = await AskClarityEngine.respondWithSemanticFallback(
            to: "how's my money situation these days", context: .empty, entries: [], budgets: [], headCategories: [],
            settings: testSettings(), today: today, semanticProvider: stub
        )
        XCTAssertEqual(stub.callCount, 1)
        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertNotEqual(result.answer.headline, "I couldn't find a supported way to answer that yet.", "must read differently from the plain unsupported/unrecognized answer")
        XCTAssertFalse(result.answer.headline.isEmpty)
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
        let interpretation = blankInterpretation(metric: .spending, categoryName: "Made Up Category")
        let stub = StubSemanticProvider(result: .understood(interpretation))
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

// MARK: - Determinism ("same question -> same query," run repeatedly)

final class AskClaritySemanticDeterminismTests: XCTestCase {
    /// Pure-function determinism: the parser is ordinary code, not sampling — this guards against
    /// an accidental source of instability creeping in (e.g. `Set`/`Dictionary` iteration order,
    /// a stray `Date.now`/UUID) by proving the exact same raw reply really does parse to the exact
    /// same outcome, every time, many times in a row.
    func testParsingTheSameRawReplyRepeatedlyAlwaysProducesTheSameOutcome() {
        let json = """
        {"result":"understood","metric":"spending","categoryName":"Restaurants",\
        "period":{"kind":"named","value":"thisMonth"},"ranking":null,"budgetState":null,\
        "wantsBreakdown":false,"wantsTrend":false,"trendSpan":null,"wantsList":false,\
        "wantsTransactionRanking":false,"wantsAssessment":false,"comparisonRequested":true}
        """
        let results = (0..<25).map { _ in AskClaritySemanticResponseParser.parse(json) }
        XCTAssertTrue(results.allSatisfy { $0 == results[0] }, "identical raw text must always parse to the identical outcome")
    }

    func testBuildingAQueryFromTheSameInterpretationRepeatedlyAlwaysProducesAnEquivalentQuery() {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        context.insert(head); context.insert(restaurants)

        let interpretation = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let queries = (0..<25).compactMap { _ in
            AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, question: "How much on restaurants this month?", categories: [restaurants], today: today)
        }
        XCTAssertEqual(queries.count, 25)
        XCTAssertTrue(queries.allSatisfy { $0.metric == queries[0].metric && $0.periodMatch == queries[0].periodMatch })
        XCTAssertTrue(queries.allSatisfy {
            guard case .resolved(let category) = $0.categoryMatch else { return false }
            return category === restaurants
        })
    }

    /// The end-to-end pipeline a real user session drives: same stubbed provider output, same
    /// local data, called many times in a row — every resulting answer must be identical
    /// (headline, supportingDetail, hasSufficientData), never varying run to run.
    func testTheFullFallbackPipelineProducesAnIdenticalAnswerAcrossManyRepeatedCalls() async {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let entry = TestSupport.makeEntry(amount: 65, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(entry)

        let interpretation = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let question = "I've been treating myself to eating out, curious what that's run me"

        var headlines: [String] = []
        for _ in 0..<10 {
            let stub = StubSemanticProvider(result: .understood(interpretation))
            let result = await AskClarityEngine.respondWithSemanticFallback(
                to: question, context: .empty, entries: [entry], budgets: [], headCategories: [head],
                settings: testSettings(), today: today, semanticProvider: stub
            )
            headlines.append(result.answer.headline)
        }
        XCTAssertEqual(Set(headlines).count, 1, "the exact same question and stubbed interpretation must never produce two different answers: \(headlines)")
    }

    /// "recently"/"lately"/"recent" specifically — the requirement this phase adds: these words
    /// must resolve to the same period no matter what a (simulated) noisy/inconsistent model
    /// claims from call to call, proving the override in `AskClaritySemanticAmbiguityRules` — not
    /// the model's own consistency — is what actually guarantees this.
    func testRecentlyResolvesToTheSamePeriodEvenWhenTheSimulatedModelDisagreesWithItselfBetweenCalls() {
        let noisyPeriods: [AskClaritySemanticPeriod?] = [.named(.thisMonth), .named(.thisWeekend), nil, .named(.lastWeek), .named(.thisWeek)]
        let resolvedPeriods: [AskClarityPeriodKind?] = noisyPeriods.map { period in
            let interpretation = blankInterpretation(metric: .spending, period: period, ranking: .highest, wantsBreakdown: true, wantsList: true)
            let query = AskClaritySemanticQueryBuilder.buildQuery(from: interpretation, question: "Where did most of my money go recently?", categories: [], today: today)
            guard case .supported(let resolved) = query?.periodMatch else { return nil }
            return resolved.kind
        }
        XCTAssertEqual(resolvedPeriods, Array(repeating: AskClarityPeriodKind.thisWeek, count: noisyPeriods.count), "every simulated call must resolve to the same fixed period regardless of what period the model itself claimed")
    }
}

// MARK: - UI conversation flow (the exact sequence `AskClarityView` drives)
//
// `AskClarityView` has no view model — `respondWithSemanticFallback` is called directly from its
// (private) `performAsk`, threading `context`/`callBudget` across turns exactly as simulated below.
// These tests exercise that same multi-turn sequence with a stub provider, since there's no
// ViewInspector/snapshot harness in this target to drive the SwiftUI view itself.
final class AskClarityViewConversationFlowTests: XCTestCase {
    /// Mirrors a user asking a locally-understood question, then a follow-up only the semantic
    /// layer can parse, in the same conversation — the kind of sequence a real `AskClarityView`
    /// session produces one `ask(_:)` call at a time.
    func testASessionCanMixLocallyUnderstoodAndSemanticallyFallenBackQuestionsWhileSharingOneCallBudget() async {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let entry = TestSupport.makeEntry(amount: 65, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(entry)

        let interpretation = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let stub = StubSemanticProvider(result: .understood(interpretation))
        // One shared `AskClaritySemanticCallBudget`, exactly like the single `@State` instance
        // `AskClarityView` holds for the life of a conversation.
        let sessionBudget = AskClaritySemanticCallBudget()
        var sessionContext = AskClaritySessionContext.empty

        // Turn 1 — a question the deterministic interpreter already understands (a budget-state
        // question with no budgeted categories at all, deliberately: unlike a plain metric
        // question, this leaves `context` unchanged, so turn 2 below is tested with genuinely no
        // inherited signal to lean on — see `AskClarityInterpreter`'s "minimal follow-up" context
        // inheritance, which would otherwise silently answer turn 2 locally too).
        let turn1 = await AskClarityEngine.respondWithSemanticFallback(
            to: "Am I within my budget?", context: sessionContext, entries: [entry], budgets: [],
            headCategories: [head], settings: testSettings(), today: today, semanticProvider: stub, callBudget: sessionBudget
        )
        sessionContext = turn1.updatedContext
        XCTAssertEqual(stub.callCount, 0, "turn 1 is locally understood — must not touch the semantic layer")

        // Turn 2 — a phrasing with no local signal, in the same session.
        let turn2 = await AskClarityEngine.respondWithSemanticFallback(
            to: "I've been treating myself to eating out, curious what that's run me", context: sessionContext,
            entries: [entry], budgets: [], headCategories: [head], settings: testSettings(), today: today,
            semanticProvider: stub, callBudget: sessionBudget
        )
        sessionContext = turn2.updatedContext
        XCTAssertEqual(stub.callCount, 1)
        XCTAssertTrue(turn2.answer.hasSufficientData)
        XCTAssertTrue(turn2.answer.headline.contains("65"), turn2.answer.headline)
        XCTAssertEqual(sessionBudget.callsMade, 1, "the same budget instance must carry its count across turns, exactly like the view's own @State")
    }

    /// Simulates the "New conversation" toolbar action, which — per `AskClarityView` — resets both
    /// `context` and `callBudget` to fresh instances. A budget exhausted in the prior conversation
    /// must not carry over into the new one.
    func testStartingANewConversationResetsTheCallBudgetJustLikeTheNewConversationButtonDoes() async {
        let stub = StubSemanticProvider(result: .unsupported)
        var callBudget = AskClaritySemanticCallBudget(maxCalls: 1)

        _ = await AskClarityEngine.respondWithSemanticFallback(
            to: "gibberish one", context: .empty, entries: [], budgets: [], headCategories: [],
            settings: testSettings(), today: today, semanticProvider: stub, callBudget: callBudget
        )
        XCTAssertEqual(stub.callCount, 1)
        XCTAssertFalse(callBudget.hasRemainingCalls, "budget should be exhausted after one call with maxCalls: 1")

        // "New conversation" — a fresh `AskClaritySemanticCallBudget()`, the same as the toolbar
        // button assigning a new instance to `@State private var callBudget`.
        callBudget = AskClaritySemanticCallBudget(maxCalls: 1)

        _ = await AskClarityEngine.respondWithSemanticFallback(
            to: "gibberish two", context: .empty, entries: [], budgets: [], headCategories: [],
            settings: testSettings(), today: today, semanticProvider: stub, callBudget: callBudget
        )
        XCTAssertEqual(stub.callCount, 2, "a fresh conversation's budget must allow a call again, unaffected by the previous conversation's exhausted one")
    }

    /// `AskClarityView.performAsk` guards against overlap with `guard !isAsking else { return }` —
    /// a concurrent call while one is already in flight must not reach the provider a second time.
    /// This reproduces that guard directly against the engine call it wraps.
    func testConcurrentAsksForTheSameConversationDoNotEachConsumeTheCallBudgetUnboundedly() async {
        let stub = StubSemanticProvider(result: .unsupported)
        let callBudget = AskClaritySemanticCallBudget(maxCalls: 5)

        async let first = AskClarityEngine.respondWithSemanticFallback(
            to: "gibberish A", context: .empty, entries: [], budgets: [], headCategories: [],
            settings: testSettings(), today: today, semanticProvider: stub, callBudget: callBudget
        )
        async let second = AskClarityEngine.respondWithSemanticFallback(
            to: "gibberish B", context: .empty, entries: [], budgets: [], headCategories: [],
            settings: testSettings(), today: today, semanticProvider: stub, callBudget: callBudget
        )
        _ = await (first, second)

        // Both questions are distinct and each locally unrecognized, so the engine itself calls the
        // provider for each (the overlap guard lives in the view, not the engine) — but the shared
        // budget must still account for exactly as many calls as were actually made, never more.
        XCTAssertEqual(stub.callCount, 2)
        XCTAssertEqual(callBudget.callsMade, 2)
    }
}
