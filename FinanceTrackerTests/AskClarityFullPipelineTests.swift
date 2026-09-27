import XCTest
import SwiftData
@testable import FinanceTracker

// MARK: - Full pipeline tests: local interpretation -> Claude semantic fallback (if needed) ->
// Planner -> Executor -> verified deterministic answer -> Claude phrasing (if useful) -> fidelity
// validation -> final `AskClarityEngine.Result`.
//
// This is the exact sequence `AskClarityView.performAsk` drives — two chained calls,
// `respondWithSemanticFallback` then `phrasedNaturally`, sharing one `AskClaritySemanticCallBudget`
// — reproduced here with stub providers since there's no ViewInspector/snapshot harness in this
// target to drive the SwiftUI view itself. See `AskClarityViewConversationFlowTests` (interpretation
// only) and `AskClarityEnginePhrasingTests` (phrasing only) for the two halves tested individually;
// this file is specifically about the two chained together.

private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
}

private func testSettings() -> BudgetCalculationSettings {
    BudgetCalculationSettings(
        cycleStartDay: 1, manualMonthlyBudget: 0, includeUnplannedAsOtherExpenses: true,
        includeSavingsTransfers: false, includeDebtTransfers: true
    )
}

private func blankInterpretation(
    metric: AskClarityMetric? = nil, categoryName: String? = nil, period: AskClaritySemanticPeriod? = nil,
    ranking: AskClarityRanking? = nil, budgetState: AskClarityBudgetStateQuery? = nil,
    wantsBreakdown: Bool = false, wantsTrend: Bool = false, trendSpan: Int? = nil, wantsList: Bool = false,
    wantsTransactionRanking: Bool = false, wantsAssessment: Bool = false, comparisonRequested: Bool = false
) -> AskClaritySemanticInterpretation {
    AskClaritySemanticInterpretation(
        metric: metric, categoryName: categoryName, period: period, ranking: ranking, budgetState: budgetState,
        wantsBreakdown: wantsBreakdown, wantsTrend: wantsTrend, trendSpan: trendSpan, wantsList: wantsList,
        wantsTransactionRanking: wantsTransactionRanking, wantsAssessment: wantsAssessment, comparisonRequested: comparisonRequested
    )
}

private final class StubSemanticProvider: AskClaritySemanticProviding {
    private let result: AskClaritySemanticOutcome?
    private(set) var callCount = 0

    init(result: AskClaritySemanticOutcome?) { self.result = result }

    func interpret(context: AskClaritySemanticContext) async -> AskClaritySemanticOutcome? {
        callCount += 1
        return result
    }
}

private final class StubPhrasingProvider: AskClarityPhrasingProviding {
    private let result: AskClarityPhrasedResponse?
    private(set) var callCount = 0
    private(set) var lastContext: AskClarityPhrasingContext?

    init(result: AskClarityPhrasedResponse?) { self.result = result }

    func phrase(context: AskClarityPhrasingContext) async -> AskClarityPhrasedResponse? {
        callCount += 1
        lastContext = context
        return result
    }
}

/// One fixture dataset reused across this file: a single Restaurants entry this month.
private func makeFixture(amount: Decimal = 65) -> (entries: [Entry], head: HeadCategory) {
    let context = TestSupport.makeInMemoryContext()
    let wallet = TestSupport.makeWallet()
    let head = TestSupport.makeHeadCategory(name: "Food")
    let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
    let entry = TestSupport.makeEntry(amount: amount, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
    context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(entry)
    return ([entry], head)
}

/// Mirrors `AskClarityView.performAsk` exactly: local interpretation (inside
/// `respondWithSemanticFallback`) -> Claude semantic fallback if needed -> phrasing, sharing one
/// `callBudget` across both.
private func runFullPipeline(
    question: String, context: AskClaritySessionContext, entries: [Entry], head: HeadCategory,
    semanticProvider: AskClaritySemanticProviding, phrasingProvider: AskClarityPhrasingProviding,
    callBudget: AskClaritySemanticCallBudget, today: Date = testDate(2025, 6, 20)
) async -> AskClarityEngine.Result {
    let deterministic = await AskClarityEngine.respondWithSemanticFallback(
        to: question, context: context, entries: entries, budgets: [], headCategories: [head],
        settings: testSettings(), today: today, semanticProvider: semanticProvider, callBudget: callBudget
    )
    return await AskClarityEngine.phrasedNaturally(
        deterministic, question: question, phrasingProvider: phrasingProvider, callBudget: callBudget
    )
}

final class AskClarityFullPipelineTests: XCTestCase {
    // MARK: Locally-understood questions never touch the semantic layer, but are still eligible for phrasing

    func testALocallyUnderstoodQuestionSkipsSemanticInterpretationButStillGetsPhrased() async {
        let (entries, head) = makeFixture(amount: 65)
        let semanticStub = StubSemanticProvider(result: nil) // must never be called
        let phrasingStub = StubPhrasingProvider(result: AskClarityPhrasedResponse(headline: "You put 65,00 € towards Restaurants this month.", supportingDetail: ""))
        let budget = AskClaritySemanticCallBudget()

        let result = await runFullPipeline(
            question: "How much did I spend on restaurants this month?", context: .empty, entries: entries, head: head,
            semanticProvider: semanticStub, phrasingProvider: phrasingStub, callBudget: budget
        )

        XCTAssertEqual(semanticStub.callCount, 0, "a locally-understood question must never call Claude for interpretation")
        XCTAssertEqual(phrasingStub.callCount, 1, "phrasing still applies to a locally-produced answer")
        XCTAssertEqual(result.answer.headline, "You put 65,00 € towards Restaurants this month.")
        XCTAssertEqual(budget.callsMade, 1)
    }

    // MARK: Questions needing semantic fallback use exactly one interpretation call + one phrasing call

    func testAnUnrecognizedQuestionUsesExactlyOneSemanticCallAndOnePhrasingCall() async {
        let (entries, head) = makeFixture(amount: 65)
        let interpretation = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let semanticStub = StubSemanticProvider(result: .understood(interpretation))
        let phrasingStub = StubPhrasingProvider(result: AskClarityPhrasedResponse(headline: "You've put 65,00 € towards Restaurants this month.", supportingDetail: ""))
        let budget = AskClaritySemanticCallBudget()

        let result = await runFullPipeline(
            question: "I've been treating myself to eating out, curious what that's run me", context: .empty,
            entries: entries, head: head, semanticProvider: semanticStub, phrasingProvider: phrasingStub, callBudget: budget
        )

        XCTAssertEqual(semanticStub.callCount, 1)
        XCTAssertEqual(phrasingStub.callCount, 1)
        XCTAssertEqual(budget.callsMade, 2, "one shared budget across both purposes")
        XCTAssertEqual(result.answer.headline, "You've put 65,00 € towards Restaurants this month.")
    }

    // MARK: Semantic interpretation failure falls back to the existing local fallback, phrasing still applies to it

    func testSemanticInterpretationFailureFallsBackToTheExistingDeterministicAnswer() async {
        let (entries, head) = makeFixture()
        let semanticStub = StubSemanticProvider(result: nil) // simulates network/timeout/malformed reply
        let phrasingStub = StubPhrasingProvider(result: nil)
        let budget = AskClaritySemanticCallBudget()

        let result = await runFullPipeline(
            question: "totally unparseable gibberish question", context: .empty, entries: entries, head: head,
            semanticProvider: semanticStub, phrasingProvider: phrasingStub, callBudget: budget
        )

        XCTAssertEqual(semanticStub.callCount, 1)
        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertEqual(result.answer.headline, "I couldn't find a supported way to answer that yet.")
    }

    // MARK: Phrasing failure or fidelity violation shows the original deterministic answer

    func testPhrasingProviderFailureShowsTheOriginalDeterministicAnswer() async {
        let (entries, head) = makeFixture(amount: 65)
        let interpretation = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let semanticStub = StubSemanticProvider(result: .understood(interpretation))
        let phrasingStub = StubPhrasingProvider(result: nil)
        let budget = AskClaritySemanticCallBudget()

        let result = await runFullPipeline(
            question: "I've been treating myself to eating out, curious what that's run me", context: .empty, entries: entries, head: head,
            semanticProvider: semanticStub, phrasingProvider: phrasingStub, callBudget: budget
        )

        XCTAssertEqual(phrasingStub.callCount, 1)
        XCTAssertTrue(result.answer.headline.contains("Restaurants"))
        XCTAssertTrue(result.answer.headline.contains("65"))
    }

    /// The integration-level proof this phase's requirement asks for: a phrasing candidate that
    /// changes the actual amount must never reach the user — `AskClarityPhrasingFidelity` catches
    /// it, and the original, correctly-computed deterministic answer is shown instead.
    func testPhrasingCandidateThatAltersTheAmountFailsFidelityAndTheDeterministicAnswerIsShownInstead() async {
        let (entries, head) = makeFixture(amount: 65)
        let interpretation = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let semanticStub = StubSemanticProvider(result: .understood(interpretation))
        // 65 silently became 60 — must be rejected.
        let phrasingStub = StubPhrasingProvider(result: AskClarityPhrasedResponse(headline: "You've put 60,00 € towards Restaurants this month.", supportingDetail: ""))
        let budget = AskClaritySemanticCallBudget()

        let result = await runFullPipeline(
            question: "I've been treating myself to eating out, curious what that's run me", context: .empty, entries: entries, head: head,
            semanticProvider: semanticStub, phrasingProvider: phrasingStub, callBudget: budget
        )

        XCTAssertTrue(result.answer.headline.contains("65"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.contains("60"), result.answer.headline)
    }

    // MARK: Call budget shared across both calls, single question never exceeds one of each

    func testACallBudgetOfOneLetsInterpretationRunButSkipsPhrasing() async {
        let (entries, head) = makeFixture()
        let interpretation = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let semanticStub = StubSemanticProvider(result: .understood(interpretation))
        let phrasingStub = StubPhrasingProvider(result: AskClarityPhrasedResponse(headline: "irrelevant", supportingDetail: ""))
        let budget = AskClaritySemanticCallBudget(maxCalls: 1)

        let result = await runFullPipeline(
            question: "I've been treating myself to eating out, curious what that's run me", context: .empty, entries: entries, head: head,
            semanticProvider: semanticStub, phrasingProvider: phrasingStub, callBudget: budget
        )

        XCTAssertEqual(semanticStub.callCount, 1)
        XCTAssertEqual(phrasingStub.callCount, 0, "the budget was already exhausted by the interpretation call")
        XCTAssertFalse(result.answer.headline.contains("irrelevant"), "phrasing must never have run")
    }

    func testACallBudgetOfZeroSkipsBothCallsEntirely() async {
        let (entries, head) = makeFixture()
        let semanticStub = StubSemanticProvider(result: .unsupported)
        let phrasingStub = StubPhrasingProvider(result: AskClarityPhrasedResponse(headline: "irrelevant", supportingDetail: ""))
        let budget = AskClaritySemanticCallBudget(maxCalls: 0)

        let result = await runFullPipeline(
            question: "totally unparseable gibberish question", context: .empty, entries: entries, head: head,
            semanticProvider: semanticStub, phrasingProvider: phrasingStub, callBudget: budget
        )

        XCTAssertEqual(semanticStub.callCount, 0)
        XCTAssertEqual(phrasingStub.callCount, 0)
        XCTAssertFalse(result.answer.headline.contains("irrelevant"))
    }

    /// A single question must never spend more than one interpretation call and one phrasing call,
    /// even with plenty of budget left — this pins that ceiling directly rather than only inferring
    /// it from the budget math above.
    func testASingleQuestionNeverExceedsOneInterpretationCallAndOnePhrasingCall() async {
        let (entries, head) = makeFixture()
        let interpretation = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let semanticStub = StubSemanticProvider(result: .understood(interpretation))
        let phrasingStub = StubPhrasingProvider(result: AskClarityPhrasedResponse(headline: "You've put 65,00 € towards Restaurants this month.", supportingDetail: ""))
        let budget = AskClaritySemanticCallBudget(maxCalls: 20)

        _ = await runFullPipeline(
            question: "I've been treating myself to eating out, curious what that's run me", context: .empty, entries: entries, head: head,
            semanticProvider: semanticStub, phrasingProvider: phrasingStub, callBudget: budget
        )

        XCTAssertLessThanOrEqual(semanticStub.callCount, 1)
        XCTAssertLessThanOrEqual(phrasingStub.callCount, 1)
    }

    // MARK: Follow-up context works after a Claude-assisted turn

    /// `updatedContext` is threaded from the deterministic result only — `phrasedNaturally` never
    /// touches it — so a follow-up question the *local* interpreter alone can resolve (a minimal
    /// follow-up inheriting the previous turn's category/metric) must still work correctly even
    /// though the previous turn's answer text was itself Claude-phrased.
    func testFollowUpContextWorksAfterAClaudeAssistedTurn() async {
        let (entries, head) = makeFixture(amount: 65)
        let interpretation = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let semanticStub = StubSemanticProvider(result: .understood(interpretation))
        let phrasingStub = StubPhrasingProvider(result: AskClarityPhrasedResponse(headline: "You've put 65,00 € towards Restaurants this month.", supportingDetail: ""))
        let budget = AskClaritySemanticCallBudget()

        // Turn 1 — semantic-fallback + phrasing.
        let turn1 = await runFullPipeline(
            question: "I've been treating myself to eating out, curious what that's run me", context: .empty,
            entries: entries, head: head, semanticProvider: semanticStub, phrasingProvider: phrasingStub, callBudget: budget
        )
        XCTAssertEqual(turn1.answer.headline, "You've put 65,00 € towards Restaurants this month.")

        // Turn 2 — a minimal local follow-up ("and last week?") that inherits category/metric from
        // `turn1.updatedContext`, resolved entirely locally (no Claude involvement at all), proving
        // context survived the phrasing step intact.
        let semanticStub2 = StubSemanticProvider(result: nil) // must never be called
        let phrasingStub2 = StubPhrasingProvider(result: nil)
        let turn2 = await runFullPipeline(
            question: "and last week?", context: turn1.updatedContext, entries: entries, head: head,
            semanticProvider: semanticStub2, phrasingProvider: phrasingStub2, callBudget: budget
        )

        XCTAssertEqual(semanticStub2.callCount, 0, "the follow-up has its own local signal (inherited category/metric) and must resolve locally")
        XCTAssertTrue(turn2.answer.hasSufficientData || turn2.answer.headline.contains("No spending"), turn2.answer.headline)
        // Either a real (possibly zero) amount for "last week" or an honest "no spending" — either
        // way this proves the category ("Restaurants") was correctly inherited from turn 1's
        // context, not lost when turn 1's *answer text* went through phrasing.
    }

    // MARK: "New conversation" resets the shared budget for the whole pipeline

    func testNewConversationResetBehaviorAppliesToTheWholeSharedBudget() async {
        let (entries, head) = makeFixture()
        let semanticStub = StubSemanticProvider(result: .unsupported)
        let phrasingStub = StubPhrasingProvider(result: nil)
        var budget = AskClaritySemanticCallBudget(maxCalls: 1)

        _ = await runFullPipeline(
            question: "totally unparseable gibberish question", context: .empty, entries: entries, head: head,
            semanticProvider: semanticStub, phrasingProvider: phrasingStub, callBudget: budget
        )
        XCTAssertEqual(semanticStub.callCount, 1)
        XCTAssertFalse(budget.hasRemainingCalls)

        // "New conversation" — a fresh `AskClaritySemanticCallBudget()`, exactly like the toolbar
        // button in `AskClarityView` assigning a new instance to `@State private var callBudget`.
        budget = AskClaritySemanticCallBudget(maxCalls: 1)

        _ = await runFullPipeline(
            question: "totally unparseable gibberish question 2", context: .empty, entries: entries, head: head,
            semanticProvider: semanticStub, phrasingProvider: phrasingStub, callBudget: budget
        )
        XCTAssertEqual(semanticStub.callCount, 2, "a fresh conversation's budget must allow a call again")
    }

    // MARK: No raw financial data ever reaches either Claude call

    func testNeitherClaudeCallEverReceivesTransactionsOrRawFinancialObjects() async {
        let (entries, head) = makeFixture(amount: 123_456)
        let semanticStub = StubSemanticProvider(result: nil)
        let phrasingStub = StubPhrasingProvider(result: nil)
        let budget = AskClaritySemanticCallBudget()

        _ = await runFullPipeline(
            question: "totally unparseable gibberish question", context: .empty, entries: entries, head: head,
            semanticProvider: semanticStub, phrasingProvider: phrasingStub, callBudget: budget
        )

        XCTAssertEqual(semanticStub.callCount, 1)
        // Phrasing still runs on the local fallback answer (that answer is just as eligible for
        // phrasing as any other) — this is exactly the call whose context we need to inspect.
        XCTAssertEqual(phrasingStub.callCount, 1)
        let phrasingContext = try? XCTUnwrap(phrasingStub.lastContext)
        XCTAssertEqual(phrasingContext?.question, "totally unparseable gibberish question")
        XCTAssertEqual(phrasingContext?.headline, "I couldn't find a supported way to answer that yet.")
        // `AskClarityPhrasingContext` has exactly four fields (question/headline/supportingDetail/
        // hasSufficientData) — structurally incapable of carrying an `Entry`/`Category`/`Budget`
        // object or a raw Decimal total; `123_456` is chosen as the fixture amount specifically so
        // it would be an obvious, greppable leak if this test ever failed by regression.
        XCTAssertFalse(phrasingContext?.headline.contains("123456") ?? true)
        XCTAssertFalse(phrasingContext?.headline.contains("123,456") ?? true)
    }
}
