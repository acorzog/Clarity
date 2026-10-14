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

// MARK: - Tool-use response parsing (malformed/invalid/adversarial model output)

/// Builds the exact Decodable shape a live Anthropic tool-use response takes, from a terse test
/// DSL — one `(name, inputJSON)` pair per `tool_use` block Claude is simulated to have made.
private func toolUseResponse(stopReason: String = "tool_use", calls: [(name: String, input: String)]) -> AskClarityToolUseMessagesResponse {
    let blocks = calls.map { "{\"type\":\"tool_use\",\"name\":\"\($0.name)\",\"input\":\($0.input)}" }.joined(separator: ",")
    let json = "{\"stop_reason\":\"\(stopReason)\",\"content\":[\(blocks)]}"
    return try! JSONDecoder().decode(AskClarityToolUseMessagesResponse.self, from: Data(json.utf8))
}

final class AskClarityToolUseResponseParserTests: XCTestCase {
    func testOneUnderstoodCallParsesEveryField() {
        let response = toolUseResponse(calls: [(
            "classify_understood_question",
            """
            {"metric":"spending","categoryName":"Restaurants","period":{"kind":"named","value":"thisMonth"},\
            "comparisonRequested":true}
            """
        )])
        guard case .understood(let result) = AskClarityToolUseResponseParser.parse(response) else {
            return XCTFail("a single classify_understood_question call should parse to .understood")
        }
        XCTAssertEqual(result.metric, .spending)
        XCTAssertEqual(result.categoryName, "Restaurants")
        XCTAssertEqual(result.period, .named(.thisMonth))
        XCTAssertTrue(result.comparisonRequested)
    }

    func testNoToolCallsAtAllReturnsNil() {
        // Should never happen with `tool_choice: {"type":"any"}`, but a provider that still
        // replies with plain text instead of a tool call must fail safe, not crash.
        let response = toolUseResponse(calls: [])
        XCTAssertNil(AskClarityToolUseResponseParser.parse(response))
    }

    func testUnsupportedCallAloneReturnsUnsupported() {
        let response = toolUseResponse(calls: [("classify_unsupported_question", "{}")])
        XCTAssertEqual(AskClarityToolUseResponseParser.parse(response), .unsupported)
    }

    func testNeedsClarificationCallAloneReturnsNeedsClarification() {
        let response = toolUseResponse(calls: [("classify_needs_clarification", "{}")])
        XCTAssertEqual(AskClarityToolUseResponseParser.parse(response), .needsClarification)
    }

    /// A hallucinated tool name outside the fixed three-tool catalog — never trusted, even if
    /// `input` happens to decode cleanly; the whole response is discarded.
    func testUnknownToolNameReturnsNil() {
        let response = toolUseResponse(calls: [("delete_all_transactions", "{}")])
        XCTAssertNil(AskClarityToolUseResponseParser.parse(response))
    }

    /// `classify_unsupported_question`/`classify_needs_clarification` must never be mixed with
    /// another call in the same response — each is only ever a sole, terminal classification.
    func testUnsupportedMixedWithAnotherCallReturnsNil() {
        let response = toolUseResponse(calls: [
            ("classify_unsupported_question", "{}"),
            ("classify_understood_question", "{\"metric\":\"spending\"}")
        ])
        XCTAssertNil(AskClarityToolUseResponseParser.parse(response))
    }

    func testUnsupportedMixedWithNeedsClarificationReturnsNil() {
        let response = toolUseResponse(calls: [
            ("classify_unsupported_question", "{}"),
            ("classify_needs_clarification", "{}")
        ])
        XCTAssertNil(AskClarityToolUseResponseParser.parse(response))
    }

    /// A `max_tokens` stop means a tool's `input` may have been truncated mid-generation — never
    /// trust a possibly-partial classification, even if what arrived happens to decode cleanly.
    func testMaxTokensStopReasonReturnsNilEvenWithAnOtherwiseValidCall() {
        let response = toolUseResponse(stopReason: "max_tokens", calls: [("classify_understood_question", "{\"metric\":\"spending\"}")])
        XCTAssertNil(AskClarityToolUseResponseParser.parse(response))
    }

    /// A hallucinated enum value outside the vocabulary given in the schema — must be dropped
    /// (treated as "not mentioned"), never passed through as if it were real.
    func testUnrecognizedEnumValueIsDroppedNotGuessed() {
        let response = toolUseResponse(calls: [("classify_understood_question", "{\"metric\":\"cryptocurrency\",\"ranking\":\"medium\"}")])
        guard case .understood(let result) = AskClarityToolUseResponseParser.parse(response) else {
            return XCTFail("should still parse — just with the bad fields dropped")
        }
        XCTAssertNil(result.metric)
        XCTAssertNil(result.ranking)
    }

    func testUnrecognizedPeriodKindIsDropped() {
        let response = toolUseResponse(calls: [("classify_understood_question", "{\"period\":{\"kind\":\"nextDecade\",\"value\":\"today\"}}")])
        guard case .understood(let result) = AskClarityToolUseResponseParser.parse(response) else {
            return XCTFail("should still parse")
        }
        XCTAssertNil(result.period)
    }

    func testDateRangePeriodParsesBothDates() {
        let response = toolUseResponse(calls: [("classify_understood_question", "{\"period\":{\"kind\":\"dateRange\",\"startDate\":\"2025-09-05\",\"endDate\":\"2025-09-18\"}}")])
        guard case .understood(let result) = AskClarityToolUseResponseParser.parse(response), case .dateRange(let start, let end) = result.period else {
            return XCTFail("should parse a dateRange period")
        }
        XCTAssertEqual(start, "2025-09-05")
        XCTAssertEqual(end, "2025-09-18")
    }

    func testTrendSpanIsClampedToASaneRange() {
        let response = toolUseResponse(calls: [("classify_understood_question", "{\"wantsTrend\":true,\"trendSpan\":9999}")])
        guard case .understood(let result) = AskClarityToolUseResponseParser.parse(response) else {
            return XCTFail("should still parse")
        }
        XCTAssertEqual(result.trendSpan, 24)
    }

    func testEmptyCategoryNameIsTreatedAsNilNotAnEmptyMatch() {
        let response = toolUseResponse(calls: [("classify_understood_question", "{\"categoryName\":\"   \"}")])
        guard case .understood(let result) = AskClarityToolUseResponseParser.parse(response) else {
            return XCTFail("should still parse")
        }
        XCTAssertNil(result.categoryName)
    }

    // MARK: Two-step composition (the one new multi-call shape this phase adds)

    func testTwoValidUnderstoodCallsParseToComposed() {
        let response = toolUseResponse(calls: [
            ("classify_understood_question", "{\"metric\":\"spending\",\"categoryName\":\"Restaurants\",\"period\":{\"kind\":\"named\",\"value\":\"thisMonth\"}}"),
            ("classify_understood_question", "{\"metric\":\"spending\",\"categoryName\":\"Restaurants\",\"wantsTrend\":true,\"trendSpan\":6}")
        ])
        guard case .composed(let first, let second) = AskClarityToolUseResponseParser.parse(response) else {
            return XCTFail("two valid classify_understood_question calls should parse to .composed")
        }
        XCTAssertTrue([first, second].contains { $0.wantsTrend && $0.trendSpan == 6 })
        XCTAssertTrue([first, second].contains { !$0.wantsTrend })
    }

    /// Enforces the hard architectural cap — never more than `maxToolCallsPerQuestion` (2) tool
    /// calls are ever acted on, no matter how many a provider sends.
    func testThreeToolCallsExceedsTheLimitAndReturnsNil() {
        let response = toolUseResponse(calls: [
            ("classify_understood_question", "{\"metric\":\"spending\"}"),
            ("classify_understood_question", "{\"metric\":\"income\"}"),
            ("classify_understood_question", "{\"metric\":\"savings\"}")
        ])
        XCTAssertNil(AskClarityToolUseResponseParser.parse(response))
    }

    /// If either of the two calls fails to validate, the whole response is discarded — never
    /// partially trust the one call that did parse alongside a discarded invalid one.
    func testTwoCallsWhereOneHasOnlyInvalidFieldsStillParsesSinceEveryFieldIsOptional() {
        // Every field on `classify_understood_question` is optional, so an "empty" call is still
        // a *valid* (if empty) interpretation — this is intentionally distinct from a truly
        // malformed/undecodable input, which the JSONDecoder step itself would reject outright.
        let response = toolUseResponse(calls: [
            ("classify_understood_question", "{\"metric\":\"spending\"}"),
            ("classify_understood_question", "{}")
        ])
        guard case .composed = AskClarityToolUseResponseParser.parse(response) else {
            return XCTFail("two structurally-valid (if one is empty) calls should still compose")
        }
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

// MARK: - Tool-use request building (no financial data ever sent; deterministic decoding)

final class AskClarityToolUseRequestBuilderTests: XCTestCase {
    func testRequestBodyContainsNoFinancialAmounts() throws {
        let context = AskClaritySemanticContext(question: "How much did I spend on restaurants?", today: today, availableCategoryNames: ["Restaurants", "Groceries"])
        guard let data = AskClarityToolUseRequestBuilder.requestBody(context: context, model: "claude-haiku-4-5-20251001", limits: .default) else {
            return XCTFail("should build a request body")
        }
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        // The request is entirely text/schema (question + category names + tool definitions) —
        // there is no numeric amount field in the wire format at all (enforced by
        // `AskClaritySemanticContext`'s own type, which has no such field to serialize), so this
        // is really pinning the shape rather than scanning for a stray number. `Entry`/`Decimal`,
        // which would only ever appear from an accidental change that started serializing real
        // transaction data, are the actual red flags checked here.
        XCTAssertTrue(json.contains("Restaurants"))
        XCTAssertTrue(json.contains("claude-haiku-4-5-20251001"))
        XCTAssertFalse(json.contains("Entry"))
        XCTAssertFalse(json.contains("Decimal"))
    }

    /// Determinism requirement: decoding must be as close to deterministic as the API allows.
    func testRequestBodyUsesZeroTemperatureForDeterministicDecoding() throws {
        let context = AskClaritySemanticContext(question: "test", today: today, availableCategoryNames: [])
        let data = try XCTUnwrap(AskClarityToolUseRequestBuilder.requestBody(context: context, model: "m", limits: .default))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"temperature\":0"), json)
    }

    /// This phase's whole point: classification must be expressed as native Anthropic tool use,
    /// not a free-text JSON contract — pin the actual wire fields that make it so.
    func testRequestBodyDeclaresTheThreeToolCatalogAndForcesAToolCall() throws {
        let context = AskClaritySemanticContext(question: "test", today: today, availableCategoryNames: [])
        let data = try XCTUnwrap(AskClarityToolUseRequestBuilder.requestBody(context: context, model: "m", limits: .default))
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((body["tool_choice"] as? [String: String])?["type"], "any")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["classify_understood_question", "classify_unsupported_question", "classify_needs_clarification"])
        // Every tool declares a schema that forbids fields outside its own vocabulary.
        for tool in tools {
            let schema = try XCTUnwrap(tool["input_schema"] as? [String: Any])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        }
    }

    /// The prompt itself must state the fixed word rules a JSON Schema can't express — belt-and-
    /// suspenders alongside the code-level override in `AskClaritySemanticAmbiguityRules`.
    func testSystemPromptDefinesAFixedMappingForRecentlyLatelyAndRecent() {
        let instructions = AskClarityToolUseRequestBuilder.systemPrompt
        XCTAssertTrue(instructions.contains("\"recently\""))
        XCTAssertTrue(instructions.contains("\"lately\""))
        XCTAssertTrue(instructions.contains("\"recent\""))
        XCTAssertTrue(instructions.contains("thisWeek"))
    }

    func testQuestionLongerThanTheLimitIsTruncated() throws {
        let longQuestion = String(repeating: "a", count: 1000)
        var limits = AskClaritySemanticLimits.default
        limits.maxQuestionLength = 50
        let context = AskClaritySemanticContext(question: longQuestion, today: today, availableCategoryNames: [])
        let data = try XCTUnwrap(AskClarityToolUseRequestBuilder.requestBody(context: context, model: "m", limits: limits))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains(String(repeating: "a", count: 51)))
    }

    func testCategoryListLongerThanTheLimitIsCapped() throws {
        var limits = AskClaritySemanticLimits.default
        limits.maxCategoryNames = 2
        let context = AskClaritySemanticContext(question: "test", today: today, availableCategoryNames: ["One", "Two", "Three", "Four"])
        let data = try XCTUnwrap(AskClarityToolUseRequestBuilder.requestBody(context: context, model: "m", limits: limits))
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
        let data = try XCTUnwrap(AskClarityToolUseRequestBuilder.requestBody(context: context, model: "m", limits: limits))
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

    func testCompositionAllowedBecomesFalseOnceFailuresReachTheLimit() {
        let budget = AskClaritySemanticCallBudget(maxCompositionFailures: 2)
        XCTAssertTrue(budget.compositionAllowed)
        budget.recordCompositionFailure()
        XCTAssertTrue(budget.compositionAllowed)
        budget.recordCompositionFailure()
        XCTAssertFalse(budget.compositionAllowed)
    }

    func testZeroMaxCompositionFailuresNeverAllowsComposition() {
        let budget = AskClaritySemanticCallBudget(maxCompositionFailures: 0)
        XCTAssertFalse(budget.compositionAllowed)
    }
}

// MARK: - Semantic composition (the two-step "current vs. trailing average" shape)

final class AskClaritySemanticCompositionTests: XCTestCase {
    /// The canonical motivating example: "compare this month's dining to the last 6 months."
    func testCurrentAmountComparedAgainstTrendAverageProducesACorrectComposedAnswer() async {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        // Five historical months at 100, plus the current month (June) at 300 — a clear anomaly.
        var entries: [Entry] = []
        for monthOffset in 1...5 {
            let date = Calendar.current.date(byAdding: .month, value: -monthOffset, to: testDate(2025, 6, 15))!
            entries.append(TestSupport.makeEntry(amount: 100, date: date, type: .expense, category: restaurants, wallet: wallet))
        }
        entries.append(TestSupport.makeEntry(amount: 300, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet))
        context.insert(wallet); context.insert(head); context.insert(restaurants)
        entries.forEach { context.insert($0) }

        let current = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let trend = blankInterpretation(metric: .spending, categoryName: "Restaurants", wantsTrend: true, trendSpan: 6)

        let result = AskClaritySemanticComposition.respond(
            first: current, second: trend, question: "compare this month's dining to the last 6 months",
            context: .empty, entries: entries, budgets: [], headCategories: [head], settings: testSettings(), calendar: .current, today: testDate(2025, 6, 20)
        )
        guard let result else { return XCTFail("a well-formed current+trend pair for the same category must compose") }
        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("300"), result.answer.headline)
        XCTAssertTrue(result.answer.headline.contains("100"), result.answer.headline)
        XCTAssertEqual(result.answer.comparisonIsFavorable, false, "spending more than usual is unfavorable")
        XCTAssertTrue(result.answer.supportingDetail.contains("higher"), result.answer.supportingDetail)
    }

    /// Order must not matter — the composer identifies roles by field content, not position.
    func testRoleAssignmentIsOrderIndependent() async {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        var entries: [Entry] = []
        for monthOffset in 1...5 {
            let date = Calendar.current.date(byAdding: .month, value: -monthOffset, to: testDate(2025, 6, 15))!
            entries.append(TestSupport.makeEntry(amount: 100, date: date, type: .expense, category: restaurants, wallet: wallet))
        }
        entries.append(TestSupport.makeEntry(amount: 300, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet))
        context.insert(wallet); context.insert(head); context.insert(restaurants)
        entries.forEach { context.insert($0) }

        let current = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let trend = blankInterpretation(metric: .spending, categoryName: "Restaurants", wantsTrend: true, trendSpan: 6)

        let swapped = AskClaritySemanticComposition.respond(
            first: trend, second: current, question: "test", context: .empty, entries: entries, budgets: [],
            headCategories: [head], settings: testSettings(), calendar: .current, today: testDate(2025, 6, 20)
        )
        XCTAssertNotNil(swapped)
    }

    /// Two trend requests, or two plain amounts — anything other than exactly one trend side and
    /// one plain side — is never guessed into a shape.
    func testTwoTrendCallsNeverCompose() async {
        let trendA = blankInterpretation(metric: .spending, categoryName: "Restaurants", wantsTrend: true, trendSpan: 6)
        let trendB = blankInterpretation(metric: .spending, categoryName: "Restaurants", wantsTrend: true, trendSpan: 3)
        let result = AskClaritySemanticComposition.respond(
            first: trendA, second: trendB, question: "test", context: .empty, entries: [], budgets: [],
            headCategories: [], settings: testSettings(), calendar: .current, today: today
        )
        XCTAssertNil(result)
    }

    func testTwoPlainAmountsNeverCompose() async {
        let a = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let b = blankInterpretation(metric: .spending, categoryName: "Groceries", period: .named(.thisMonth))
        let result = AskClaritySemanticComposition.respond(
            first: a, second: b, question: "test", context: .empty, entries: [], budgets: [],
            headCategories: [], settings: testSettings(), calendar: .current, today: today
        )
        XCTAssertNil(result)
    }

    /// Different subjects (category A's current figure vs. category B's trend) must never be
    /// composed against each other — this is never a cross-category average.
    func testMismatchedSubjectsNeverCompose() async {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        context.insert(head); context.insert(restaurants); context.insert(groceries)

        let current = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let trend = blankInterpretation(metric: .spending, categoryName: "Groceries", wantsTrend: true, trendSpan: 6)
        let result = AskClaritySemanticComposition.respond(
            first: current, second: trend, question: "test", context: .empty, entries: [], budgets: [],
            headCategories: [head], settings: testSettings(), calendar: .current, today: today
        )
        XCTAssertNil(result)
    }

    /// Fewer than two usable historical points (e.g. a brand-new category) means "average" isn't
    /// meaningful yet — never fabricated from a single point.
    func testInsufficientHistoryNeverComposes() async {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let entry = TestSupport.makeEntry(amount: 50, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(entry)

        let current = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let trend = blankInterpretation(metric: .spending, categoryName: "Restaurants", wantsTrend: true, trendSpan: 6)
        let result = AskClaritySemanticComposition.respond(
            first: current, second: trend, question: "test", context: .empty, entries: [entry], budgets: [],
            headCategories: [head], settings: testSettings(), calendar: .current, today: testDate(2025, 6, 20)
        )
        XCTAssertNil(result)
    }

    /// Consistency with the deterministic path: `trendSpan: 2` is the minimum valid span (one
    /// historical period, right before the current one) — the semantic path must honor that exact
    /// window too, not reject it against some larger, unrelated fixed minimum.
    func testMinimumValidTrendSpanOfTwoComposesWithExactlyOneHistoricalPoint() async {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let may = TestSupport.makeEntry(amount: 80, date: testDate(2025, 5, 15), type: .expense, category: restaurants, wallet: wallet)
        let june = TestSupport.makeEntry(amount: 120, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(may); context.insert(june)

        let current = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let trend = blankInterpretation(metric: .spending, categoryName: "Restaurants", wantsTrend: true, trendSpan: 2)
        let result = AskClaritySemanticComposition.respond(
            first: current, second: trend, question: "test", context: .empty, entries: [may, june], budgets: [],
            headCategories: [head], settings: testSettings(), calendar: .current, today: testDate(2025, 6, 20)
        )
        guard let result else { return XCTFail("exactly the requested 2-period window (1 historical point) must compose") }
        XCTAssertTrue(result.answer.headline.contains("80"), result.answer.headline)
    }
}

// MARK: - End-to-end `.composed` wiring through `respondWithSemanticFallback`

final class AskClarityEngineComposedFallbackTests: XCTestCase {
    private func makeFixture() -> (context: ModelContext, wallet: Wallet, head: HeadCategory, category: FinanceTracker.Category, entries: [Entry]) {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        var entries: [Entry] = []
        for monthOffset in 1...5 {
            let date = Calendar.current.date(byAdding: .month, value: -monthOffset, to: testDate(2025, 6, 15))!
            entries.append(TestSupport.makeEntry(amount: 100, date: date, type: .expense, category: restaurants, wallet: wallet))
        }
        entries.append(TestSupport.makeEntry(amount: 300, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet))
        context.insert(wallet); context.insert(head); context.insert(restaurants)
        entries.forEach { context.insert($0) }
        return (context, wallet, head, restaurants, entries)
    }

    func testComposedOutcomeProducesTheComposedAnswerEndToEnd() async {
        let fixture = makeFixture()
        let current = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let trend = blankInterpretation(metric: .spending, categoryName: "Restaurants", wantsTrend: true, trendSpan: 6)
        let stub = StubSemanticProvider(result: .composed(current, trend))

        let result = await AskClarityEngine.respondWithSemanticFallback(
            to: "I've been treating myself to eating out, curious how unusual that is", context: .empty, entries: fixture.entries, budgets: [],
            headCategories: [fixture.head], settings: testSettings(), today: testDate(2025, 6, 20), semanticProvider: stub
        )
        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("300"), result.answer.headline)
    }

    /// A `.composed` outcome that doesn't match the one recognized shape degrades to the local
    /// unknown answer — never a guess, and never a crash.
    func testUnrecognizedComposedShapeFallsBackToTheLocalUnknownAnswer() async {
        let a = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let b = blankInterpretation(metric: .income, categoryName: "Restaurants", period: .named(.lastMonth))
        let stub = StubSemanticProvider(result: .composed(a, b))

        let result = await AskClarityEngine.respondWithSemanticFallback(
            to: "gibberish", context: .empty, entries: [], budgets: [], headCategories: [],
            settings: testSettings(), today: today, semanticProvider: stub
        )
        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertEqual(result.answer.headline, "I couldn't find a supported way to answer that yet.")
    }

    /// Once a session's composition-failure budget is exhausted, a `.composed` outcome degrades
    /// to its first interpretation alone (the same single-step answer `.understood` would give),
    /// never attempting composition again and never a second network call.
    func testExhaustedCompositionBudgetDegradesToTheFirstInterpretationAlone() async {
        let fixture = makeFixture()
        let current = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let trend = blankInterpretation(metric: .spending, categoryName: "Restaurants", wantsTrend: true, trendSpan: 6)
        let stub = StubSemanticProvider(result: .composed(current, trend))
        let budget = AskClaritySemanticCallBudget(maxCompositionFailures: 0)

        let result = await AskClarityEngine.respondWithSemanticFallback(
            to: "I've been treating myself to eating out, curious how unusual that is", context: .empty, entries: fixture.entries, budgets: [],
            headCategories: [fixture.head], settings: testSettings(), today: testDate(2025, 6, 20), semanticProvider: stub, callBudget: budget
        )
        // Degrades to the plain "this month" amount (300) rather than the composed comparison.
        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("300"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.contains("average"), result.answer.headline)
    }

    /// A composition that fails to produce an answer (e.g. a `.composed` pair that doesn't match
    /// the one recognized shape) must count against the session's composition-failure budget —
    /// never retried for this question, and counted so a persistently-misbehaving provider is
    /// eventually shut off from the composed path for the rest of the session.
    func testAFailedCompositionIsRecordedAgainstTheBudget() async {
        let a = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let b = blankInterpretation(metric: .income, categoryName: "Restaurants", period: .named(.lastMonth))
        let stub = StubSemanticProvider(result: .composed(a, b))
        let budget = AskClaritySemanticCallBudget(maxCompositionFailures: 1)

        _ = await AskClarityEngine.respondWithSemanticFallback(
            to: "gibberish", context: .empty, entries: [], budgets: [], headCategories: [],
            settings: testSettings(), today: today, semanticProvider: stub, callBudget: budget
        )
        XCTAssertFalse(budget.compositionAllowed, "one unrecognized composition shape should have consumed the single allowed failure")
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
        let response = toolUseResponse(calls: [(
            "classify_understood_question",
            """
            {"metric":"spending","categoryName":"Restaurants","period":{"kind":"named","value":"thisMonth"},\
            "comparisonRequested":true}
            """
        )])
        let results = (0..<25).map { _ in AskClarityToolUseResponseParser.parse(response) }
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
