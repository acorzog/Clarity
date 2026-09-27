import XCTest
import SwiftData
@testable import FinanceTracker

private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
}

private func testSettings() -> BudgetCalculationSettings {
    BudgetCalculationSettings(
        cycleStartDay: 1, manualMonthlyBudget: 0, includeUnplannedAsOtherExpenses: true,
        includeSavingsTransfers: false, includeDebtTransfers: true
    )
}

/// Records every call it receives and returns a fixed, injected result — never touches the
/// network. Lets tests drive `AskClarityEngine.phrasedNaturally` deterministically.
private final class StubPhrasingProvider: AskClarityPhrasingProviding {
    private let result: AskClarityPhrasedResponse?
    private(set) var callCount = 0
    private(set) var lastContext: AskClarityPhrasingContext?

    init(result: AskClarityPhrasedResponse?) {
        self.result = result
    }

    func phrase(context: AskClarityPhrasingContext) async -> AskClarityPhrasedResponse? {
        callCount += 1
        lastContext = context
        return result
    }
}

// MARK: - Fidelity validation: the core "LLM cannot change a financial value" guarantee

final class AskClarityPhrasingFidelityTests: XCTestCase {
    private let sourceContext = AskClarityPhrasingContext(
        question: "How much did I spend on restaurants this month?",
        headline: "You've spent 165,00 € on Restaurants this month.",
        supportingDetail: "That's 38% higher than last month (120,00 €).",
        hasSufficientData: true
    )

    func testANaturalRephrasingThatKeepsEveryNumberAndCategoryNamePasses() {
        let candidate = AskClarityPhrasedResponse(
            headline: "You spent 165,00 € on Restaurants this month — that's 38% more than the 120,00 € you spent last month.",
            supportingDetail: ""
        )
        XCTAssertTrue(AskClarityPhrasingFidelity.preservesFacts(context: sourceContext, candidate: candidate))
    }

    func testMovingTextBetweenHeadlineAndSupportingDetailStillPassesAsLongAsFactsSurvive() {
        // The fidelity check looks at the combined text, not each field independently, so a
        // provider is free to restructure which sentence carries which fact.
        let candidate = AskClarityPhrasedResponse(
            headline: "Restaurants came in at 165,00 € this month.",
            supportingDetail: "That's a 38% jump from 120,00 € last month."
        )
        XCTAssertTrue(AskClarityPhrasingFidelity.preservesFacts(context: sourceContext, candidate: candidate))
    }

    func testAnAlteredAmountFails() {
        // 165,00 became 150,00 — a changed financial value must never pass.
        let candidate = AskClarityPhrasedResponse(
            headline: "You spent 150,00 € on Restaurants this month — 38% more than the 120,00 € last month.",
            supportingDetail: ""
        )
        XCTAssertFalse(AskClarityPhrasingFidelity.preservesFacts(context: sourceContext, candidate: candidate))
    }

    func testAnAlteredPercentageFails() {
        let candidate = AskClarityPhrasedResponse(
            headline: "You spent 165,00 € on Restaurants this month — 50% more than the 120,00 € last month.",
            supportingDetail: ""
        )
        XCTAssertFalse(AskClarityPhrasingFidelity.preservesFacts(context: sourceContext, candidate: candidate))
    }

    func testADroppedNumberFails() {
        // The comparison figures are gone entirely — even though nothing is factually "wrong," a
        // value present in the verified source must survive into the candidate, not vanish.
        let candidate = AskClarityPhrasedResponse(headline: "You've been spending a bit more on Restaurants lately.", supportingDetail: "")
        XCTAssertFalse(AskClarityPhrasingFidelity.preservesFacts(context: sourceContext, candidate: candidate))
    }

    func testAnInventedExtraNumberFails() {
        // "40,00 €" never appeared anywhere in the verified source — fabricating an additional
        // figure must fail exactly like altering an existing one.
        let candidate = AskClarityPhrasedResponse(
            headline: "You spent 165,00 € on Restaurants this month, 38% more than the 120,00 € last month, averaging 40,00 € a week.",
            supportingDetail: ""
        )
        XCTAssertFalse(AskClarityPhrasingFidelity.preservesFacts(context: sourceContext, candidate: candidate))
    }

    func testADroppedCategoryNameFails() {
        let candidate = AskClarityPhrasedResponse(
            headline: "You spent 165,00 € this month — 38% more than the 120,00 € last month.",
            supportingDetail: ""
        )
        XCTAssertFalse(AskClarityPhrasingFidelity.preservesFacts(context: sourceContext, candidate: candidate), "dropping \"Restaurants\" entirely must fail")
    }

    func testARenamedCategoryFails() {
        // "Restaurants" silently became "Dining" — a renamed category is exactly the kind of
        // invented/modified fact this check exists to catch.
        let candidate = AskClarityPhrasedResponse(
            headline: "You spent 165,00 € on Dining this month — 38% more than the 120,00 € last month.",
            supportingDetail: ""
        )
        XCTAssertFalse(AskClarityPhrasingFidelity.preservesFacts(context: sourceContext, candidate: candidate))
    }

    func testCandidateAddingItsOwnCapitalizedSentenceOpenerStillPasses() {
        // "You" is sentence-initial/stopword-listed — a candidate must not be penalized just for
        // capitalizing ordinary words the source didn't happen to capitalize the same way.
        let candidate = AskClarityPhrasedResponse(
            headline: "You spent 165,00 € on Restaurants this month, 38% more than the 120,00 € you spent last month.",
            supportingDetail: ""
        )
        XCTAssertTrue(AskClarityPhrasingFidelity.preservesFacts(context: sourceContext, candidate: candidate))
    }

    func testEmptyCandidateHeadlineFails() {
        let candidate = AskClarityPhrasedResponse(headline: "   ", supportingDetail: "")
        XCTAssertFalse(AskClarityPhrasingFidelity.preservesFacts(context: sourceContext, candidate: candidate))
    }

    func testExcessivelyLongCandidateFails() {
        let candidate = AskClarityPhrasedResponse(
            headline: "You spent 165,00 € on Restaurants this month, 38% more than the 120,00 € last month. " + String(repeating: "This is extra padding that goes on and on. ", count: 30),
            supportingDetail: ""
        )
        XCTAssertFalse(AskClarityPhrasingFidelity.preservesFacts(context: sourceContext, candidate: candidate))
    }

    /// The requirement's explicit example: "insufficient data" must never gain a number, even one
    /// that happens to be true elsewhere — the limitation itself must survive, not be quietly
    /// resolved into an answer.
    func testInsufficientDataAnswerGainingAnyNumberFailsEvenIfNotPresentInSourceOrAbsent() {
        let insufficientContext = AskClarityPhrasingContext(
            question: "How much did I spend eating out this weekend?",
            headline: "No spending logged this weekend.",
            supportingDetail: "",
            hasSufficientData: false
        )
        let candidate = AskClarityPhrasedResponse(headline: "Looks like you didn't spend anything on that in the last 7 days.", supportingDetail: "")
        XCTAssertFalse(AskClarityPhrasingFidelity.preservesFacts(context: insufficientContext, candidate: candidate), "\"7\" is a fabricated number the source never had")
    }

    func testInsufficientDataAnswerWithNoNumbersAddedStillPasses() {
        let insufficientContext = AskClarityPhrasingContext(
            question: "How much did I spend eating out this weekend?",
            headline: "No spending logged this weekend.",
            supportingDetail: "",
            hasSufficientData: false
        )
        let candidate = AskClarityPhrasedResponse(headline: "Looks like there's no spending logged for this weekend yet.", supportingDetail: "")
        XCTAssertTrue(AskClarityPhrasingFidelity.preservesFacts(context: insufficientContext, candidate: candidate))
    }

    // MARK: Numeric token extraction

    func testNumericTokensExtractsAmountsPercentagesAndPlainNumbersSeparately() {
        let tokens = AskClarityPhrasingFidelity.numericTokens(in: "You spent 165,00 € — that's 38% more than 2 months ago.")
        XCTAssertEqual(tokens, ["165,00", "38", "2"])
    }

    func testNumericTokensIgnoresSurroundingPunctuationAndCurrencySymbols() {
        XCTAssertEqual(AskClarityPhrasingFidelity.numericTokens(in: "(120,00 €)."), ["120,00"])
    }

    func testNumericTokensTreatsAEuropeanThousandsSeparatorAsOneGluedToken() {
        XCTAssertEqual(AskClarityPhrasingFidelity.numericTokens(in: "1.234,56 €"), ["1.234,56"])
    }

    func testNumericTokensOfPlainTextIsEmpty() {
        XCTAssertEqual(AskClarityPhrasingFidelity.numericTokens(in: "No spending logged this weekend."), [])
    }
}

// MARK: - Response parsing (malformed/invalid LLM output)

final class AskClarityPhrasingResponseParserTests: XCTestCase {
    func testValidJSONParsesBothFields() {
        let json = "{\"headline\":\"You spent 165,00 € on Restaurants.\",\"supportingDetail\":\"That's up from last month.\"}"
        guard let result = AskClarityPhrasingResponseParser.parse(json) else {
            return XCTFail("valid JSON should parse")
        }
        XCTAssertEqual(result.headline, "You spent 165,00 € on Restaurants.")
        XCTAssertEqual(result.supportingDetail, "That's up from last month.")
    }

    func testMissingSupportingDetailDefaultsToEmptyString() {
        let json = "{\"headline\":\"You spent 165,00 € on Restaurants.\"}"
        XCTAssertEqual(AskClarityPhrasingResponseParser.parse(json)?.supportingDetail, "")
    }

    func testSurroundingProseAroundTheJSONObjectIsIgnored() {
        let text = "Sure!\n{\"headline\":\"You spent 40,00 € today.\",\"supportingDetail\":\"\"}\nHope that helps!"
        XCTAssertEqual(AskClarityPhrasingResponseParser.parse(text)?.headline, "You spent 40,00 € today.")
    }

    func testEmptyHeadlineReturnsNil() {
        XCTAssertNil(AskClarityPhrasingResponseParser.parse("{\"headline\":\"   \",\"supportingDetail\":\"\"}"))
    }

    func testMissingRequiredHeadlineFieldReturnsNil() {
        XCTAssertNil(AskClarityPhrasingResponseParser.parse("{\"supportingDetail\":\"x\"}"))
    }

    func testCompletelyNonJSONTextReturnsNil() {
        XCTAssertNil(AskClarityPhrasingResponseParser.parse("Sure, you spent 40,00 € today."))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(AskClarityPhrasingResponseParser.parse(""))
    }

    func testTruncatedJSONReturnsNil() {
        XCTAssertNil(AskClarityPhrasingResponseParser.parse("{\"headline\":\"You spent"))
    }
}

// MARK: - Request building (no raw financial data ever sent; deterministic decoding)

final class AskClarityPhrasingRequestBuilderTests: XCTestCase {
    func testRequestBodyContainsTheVerifiedTextButNoRawFinancialObjects() throws {
        let context = AskClarityPhrasingContext(
            question: "How much on restaurants?", headline: "You spent 165,00 € on Restaurants this month.",
            supportingDetail: "", hasSufficientData: true
        )
        guard let data = AskClarityPhrasingRequestBuilder.requestBody(context: context, model: "claude-haiku-4-5-20251001", limits: .default) else {
            return XCTFail("should build a request body")
        }
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("165,00"))
        XCTAssertTrue(json.contains("Restaurants"))
        XCTAssertTrue(json.contains("claude-haiku-4-5-20251001"))
        // No structural/type leakage — the request is built from plain strings only, never a
        // serialized `Entry`/`Category`/`Budget` object.
        XCTAssertFalse(json.contains("Entry"))
        XCTAssertFalse(json.contains("Decimal"))
    }

    func testRequestBodyUsesZeroTemperatureForDeterministicDecoding() throws {
        let context = AskClarityPhrasingContext(question: "test", headline: "test headline", supportingDetail: "", hasSufficientData: true)
        let data = try XCTUnwrap(AskClarityPhrasingRequestBuilder.requestBody(context: context, model: "m", limits: .default))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"temperature\":0"), json)
    }

    func testInstructionsForbidInventingOrChangingFinancialValues() {
        let instructions = AskClarityPhrasingRequestBuilder.instructions
        XCTAssertTrue(instructions.contains("EXACTLY"))
        XCTAssertTrue(instructions.contains("Never invent"))
    }

    func testQuestionLongerThanTheLimitIsTruncated() throws {
        let longQuestion = String(repeating: "a", count: 1000)
        var limits = AskClaritySemanticLimits.default
        limits.maxQuestionLength = 50
        let context = AskClarityPhrasingContext(question: longQuestion, headline: "h", supportingDetail: "", hasSufficientData: true)
        let data = try XCTUnwrap(AskClarityPhrasingRequestBuilder.requestBody(context: context, model: "m", limits: limits))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains(String(repeating: "a", count: 51)))
    }

    func testOutputTokenLimitIsRespected() throws {
        var limits = AskClaritySemanticLimits.default
        limits.maxOutputTokens = 123
        let context = AskClarityPhrasingContext(question: "test", headline: "h", supportingDetail: "", hasSufficientData: true)
        let data = try XCTUnwrap(AskClarityPhrasingRequestBuilder.requestBody(context: context, model: "m", limits: limits))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"max_tokens\":123"))
    }
}

// MARK: - AskClarityEngine.phrasedNaturally (end-to-end)

final class AskClarityEnginePhrasingTests: XCTestCase {
    private func realAnswerResult(amount: Decimal = 65) async -> (result: AskClarityEngine.Result, entry: Entry, head: HeadCategory) {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let entry = TestSupport.makeEntry(amount: amount, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(entry)
        let result = AskClarityEngine.respond(
            to: "How much did I spend on restaurants this month?", context: .empty, entries: [entry], budgets: [],
            headCategories: [head], settings: testSettings(), today: testDate(2025, 6, 20)
        )
        return (result, entry, head)
    }

    func testAValidFactPreservingRephrasingReplacesTheAnswerText() async {
        let (result, _, _) = await realAnswerResult()
        XCTAssertTrue(result.answer.headline.contains("65"), "sanity check on the real deterministic answer: \(result.answer.headline)")

        let rephrased = AskClarityPhrasedResponse(headline: "You've put 65,00 € towards Restaurants this month.", supportingDetail: "")
        let stub = StubPhrasingProvider(result: rephrased)
        let phrasedResult = await AskClarityEngine.phrasedNaturally(result, question: "how much on restaurants", phrasingProvider: stub)

        XCTAssertEqual(stub.callCount, 1)
        XCTAssertEqual(phrasedResult.answer.headline, rephrased.headline)
        XCTAssertEqual(phrasedResult.answer.hasSufficientData, result.answer.hasSufficientData)
        XCTAssertEqual(phrasedResult.answer.followUpSuggestions, result.answer.followUpSuggestions)
        XCTAssertEqual(phrasedResult.answer.comparisonIsFavorable, result.answer.comparisonIsFavorable)
    }

    /// The integration-level version of the core requirement: even if a provider returns a
    /// plausible-sounding rephrasing, if it changes a financial value the original, verified
    /// answer must be what the user actually sees — never the altered one.
    func testARephrasingThatAltersAFinancialValueIsRejectedAndTheOriginalAnswerIsKept() async {
        let (result, _, _) = await realAnswerResult(amount: 65)

        // 65 silently became 60 — a classic "close but wrong" LLM slip this must catch.
        let alteredRephrasing = AskClarityPhrasedResponse(headline: "You've put 60,00 € towards Restaurants this month.", supportingDetail: "")
        let stub = StubPhrasingProvider(result: alteredRephrasing)
        let phrasedResult = await AskClarityEngine.phrasedNaturally(result, question: "how much on restaurants", phrasingProvider: stub)

        XCTAssertEqual(phrasedResult.answer.headline, result.answer.headline, "must keep the original verified answer, not the altered rephrasing")
        XCTAssertTrue(phrasedResult.answer.headline.contains("65"))
        XCTAssertFalse(phrasedResult.answer.headline.contains("60"))
    }

    func testProviderFailureFallsBackToTheOriginalAnswerUnchanged() async {
        let (result, _, _) = await realAnswerResult()
        let stub = StubPhrasingProvider(result: nil)
        let phrasedResult = await AskClarityEngine.phrasedNaturally(result, question: "how much on restaurants", phrasingProvider: stub)
        XCTAssertEqual(phrasedResult.answer, result.answer)
    }

    func testExhaustedCallBudgetSkipsThePhrasingProviderEntirely() async {
        let (result, _, _) = await realAnswerResult()
        let rephrased = AskClarityPhrasedResponse(headline: "You've put 65,00 € towards Restaurants this month.", supportingDetail: "")
        let stub = StubPhrasingProvider(result: rephrased)
        let budget = AskClaritySemanticCallBudget(maxCalls: 0)
        let phrasedResult = await AskClarityEngine.phrasedNaturally(result, question: "how much on restaurants", phrasingProvider: stub, callBudget: budget)
        XCTAssertEqual(stub.callCount, 0)
        XCTAssertEqual(phrasedResult.answer, result.answer)
    }

    /// Demonstrates the "reuse the existing token safeguards" requirement concretely: the very
    /// same `AskClaritySemanticCallBudget` instance can gate both an interpretation call and a
    /// phrasing call, and its count accumulates across both purposes.
    func testTheSameCallBudgetInstanceIsSharedAcrossInterpretationAndPhrasingCalls() async {
        let budget = AskClaritySemanticCallBudget(maxCalls: 2)
        let interpretationStub = StubProviderForBudgetSharingTest()
        let localResult = AskClarityEngine.respond(
            to: "totally unparseable gibberish question", context: .empty, entries: [], budgets: [],
            headCategories: [], settings: testSettings()
        )
        let semanticResult = await AskClarityEngine.respondWithSemanticFallback(
            to: "totally unparseable gibberish question", context: .empty, entries: [], budgets: [],
            headCategories: [], settings: testSettings(), semanticProvider: interpretationStub, callBudget: budget
        )
        XCTAssertEqual(budget.callsMade, 1)

        let phrasingStub = StubPhrasingProvider(result: nil)
        _ = await AskClarityEngine.phrasedNaturally(semanticResult, question: "totally unparseable gibberish question", phrasingProvider: phrasingStub, callBudget: budget)
        XCTAssertEqual(budget.callsMade, 2, "the same budget must count both the interpretation call and the phrasing call")
        XCTAssertFalse(budget.hasRemainingCalls)
        _ = localResult // silence unused-variable warning; kept for clarity of what's being compared against
    }

    /// The provider only ever receives the question text and the answer's own already-verified
    /// display text — never a transaction, `Category`/`Entry` object, or any other raw financial
    /// data (structurally impossible, since `AskClarityPhrasingContext` has no such field, but this
    /// pins the actual values it receives so a future field addition can't quietly smuggle more in).
    func testProviderOnlyReceivesTheQuestionAndTheAlreadyVerifiedAnswerTextNeverRawData() async {
        let (result, _, _) = await realAnswerResult(amount: 123_456)
        let stub = StubPhrasingProvider(result: nil)
        _ = await AskClarityEngine.phrasedNaturally(result, question: "how much on restaurants", phrasingProvider: stub)

        let sentContext = try? XCTUnwrap(stub.lastContext)
        XCTAssertEqual(sentContext?.question, "how much on restaurants")
        XCTAssertEqual(sentContext?.headline, result.answer.headline)
        XCTAssertEqual(sentContext?.supportingDetail, result.answer.supportingDetail)
        XCTAssertEqual(sentContext?.hasSufficientData, result.answer.hasSufficientData)
        // `AskClarityPhrasingContext` has exactly these four fields — nothing else could have been
        // sent even if this test didn't check it, but this pins the actual values regardless.
    }

    /// `followUpSuggestions` must never be sent to the provider (not part of `AskClarityPhrasingContext`
    /// at all) and must never be altered by it — Claude has no way to invent a Clarity capability.
    func testFollowUpSuggestionsAreCarriedOverUnchangedAndNeverExposedToTheProvider() async {
        let originalAnswer = AskClarityAnswer(
            headline: "You've spent 65,00 € on Restaurants this month.", supportingDetail: "",
            hasSufficientData: true, followUpSuggestions: ["What about last month?", "How about Groceries?"]
        )
        let original = AskClarityEngine.Result(answer: originalAnswer, updatedContext: .empty)
        let rephrased = AskClarityPhrasedResponse(headline: "You put 65,00 € towards Restaurants this month.", supportingDetail: "")
        let stub = StubPhrasingProvider(result: rephrased)

        let phrasedResult = await AskClarityEngine.phrasedNaturally(original, question: "how much on restaurants", phrasingProvider: stub)

        XCTAssertEqual(phrasedResult.answer.followUpSuggestions, originalAnswer.followUpSuggestions)
    }
}

/// A trivial stub for `AskClaritySemanticProviding` used only to exercise call-budget sharing
/// alongside `StubPhrasingProvider` in the same test — always reports "unsupported" so the local
/// gibberish question reliably reaches (and consumes) the shared budget without depending on any
/// particular interpretation content.
private final class StubProviderForBudgetSharingTest: AskClaritySemanticProviding {
    func interpret(context: AskClaritySemanticContext) async -> AskClaritySemanticOutcome? { .unsupported }
}
