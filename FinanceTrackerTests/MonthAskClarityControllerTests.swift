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

/// Mirrors `AskClarityFullPipelineTests`' identical stub exactly — same seam, so this file needs no
/// network/URLSession mocking of its own.
private final class StubSemanticProvider: AskClaritySemanticProviding {
    private let result: AskClaritySemanticOutcome?
    private(set) var callCount = 0

    init(result: AskClaritySemanticOutcome?) { self.result = result }

    func interpret(context: AskClaritySemanticContext) async -> AskClaritySemanticOutcome? {
        callCount += 1
        return result
    }
}

private func blankInterpretation(
    metric: AskClarityMetric? = nil, categoryName: String? = nil, period: AskClaritySemanticPeriod? = nil
) -> AskClaritySemanticInterpretation {
    AskClaritySemanticInterpretation(
        metric: metric, categoryName: categoryName, period: period, ranking: nil, budgetState: nil,
        wantsBreakdown: false, wantsTrend: false, trendSpan: nil, wantsList: false,
        wantsTransactionRanking: false, wantsAssessment: false, comparisonRequested: false
    )
}

@MainActor
final class MonthAskClarityControllerTests: XCTestCase {

    // MARK: - anchorDate: scoping "this month"/"today" to the screen's selected month

    func testAnchorDateForTheRealCurrentMonthReturnsNowUnchanged() {
        let now = testDate(2025, 6, 15)
        XCTAssertEqual(MonthAskClarityController.anchorDate(for: now, now: now), now)
    }

    func testAnchorDateForAPastMonthResolvesInsideThatMonthNotToday() {
        let now = testDate(2025, 6, 15)
        let pastMonth = testDate(2025, 3, 1)
        let anchor = MonthAskClarityController.anchorDate(for: pastMonth, now: now)
        XCTAssertTrue(Calendar.current.isDate(anchor, equalTo: pastMonth, toGranularity: .month))
        XCTAssertNotEqual(anchor, now)
    }

    // MARK: - ask: empty input / no-op guards

    func testAskWithBlankTextDoesNothing() async {
        let controller = MonthAskClarityController(semanticProvider: StubSemanticProvider(result: nil))
        await controller.ask(
            "   ", month: testDate(2025, 6, 1), entries: [], budgets: [], headCategories: [], settings: testSettings()
        )
        XCTAssertNil(controller.answered)
    }

    // MARK: - ask: a locally-understood question never touches the AI provider

    func testLocallyUnderstoodQuestionNeverCallsTheSemanticProviderAndIsNotMarkedAIAssisted() async throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let entry = TestSupport.makeEntry(amount: 65, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(entry)

        let semanticStub = StubSemanticProvider(result: nil) // must never be called
        let controller = MonthAskClarityController(semanticProvider: semanticStub)

        await controller.ask(
            "How much did I spend on restaurants this month?", month: testDate(2025, 6, 1),
            entries: [entry], budgets: [], headCategories: [head], settings: testSettings()
        )

        let answered = try XCTUnwrap(controller.answered)
        XCTAssertEqual(semanticStub.callCount, 0, "a locally-understood question must never call the AI provider")
        XCTAssertFalse(answered.wasAIAssisted)
        XCTAssertTrue(answered.answer.hasSufficientData)
        XCTAssertFalse(controller.isAsking, "must be reset to false once the call completes")
    }

    // MARK: - ask: an unrecognized question falls back to the AI provider and is labeled as such

    func testUnrecognizedQuestionFallsBackToTheSemanticProviderAndIsMarkedAIAssisted() async throws {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let restaurants = TestSupport.makeCategory(name: "Restaurants", headCategory: head)
        let entry = TestSupport.makeEntry(amount: 65, date: testDate(2025, 6, 10), type: .expense, category: restaurants, wallet: wallet)
        context.insert(wallet); context.insert(head); context.insert(restaurants); context.insert(entry)

        let interpretation = blankInterpretation(metric: .spending, categoryName: "Restaurants", period: .named(.thisMonth))
        let semanticStub = StubSemanticProvider(result: .understood(interpretation))
        let controller = MonthAskClarityController(semanticProvider: semanticStub)

        await controller.ask(
            "I've been treating myself to eating out, curious what that's run me", month: testDate(2025, 6, 1),
            entries: [entry], budgets: [], headCategories: [head], settings: testSettings()
        )

        let answered = try XCTUnwrap(controller.answered)
        XCTAssertEqual(semanticStub.callCount, 1)
        XCTAssertTrue(answered.wasAIAssisted)
        XCTAssertTrue(answered.answer.hasSufficientData)
    }

    // MARK: - ask: a provider failure (network/missing key/timeout) falls back silently, never mislabeled

    func testSemanticProviderFailureKeepsTheLocalFallbackWithoutMarkingAIAssisted() async throws {
        let semanticStub = StubSemanticProvider(result: nil) // simulates no key / network failure / timeout
        let controller = MonthAskClarityController(semanticProvider: semanticStub)

        await controller.ask(
            "asdkfj qwerty lorem ipsum", month: testDate(2025, 6, 1),
            entries: [], budgets: [], headCategories: [], settings: testSettings()
        )

        let answered = try XCTUnwrap(controller.answered)
        XCTAssertEqual(semanticStub.callCount, 1, "must still try, since the deterministic pass found nothing")
        XCTAssertFalse(answered.wasAIAssisted, "a provider failure must never be presented as an AI-assisted answer")
        XCTAssertFalse(answered.answer.hasSufficientData)
    }

    // MARK: - ask: a month with no data at all still answers gracefully, never crashes/hangs

    func testAskingAboutAMonthWithNoDataProducesAGracefulAnswer() async throws {
        let controller = MonthAskClarityController(semanticProvider: StubSemanticProvider(result: nil))

        await controller.ask(
            "How much did I spend this month?", month: testDate(2025, 6, 1),
            entries: [], budgets: [], headCategories: [], settings: testSettings()
        )

        let answered = try XCTUnwrap(controller.answered)
        XCTAssertFalse(answered.answer.headline.isEmpty)
    }

    // MARK: - reset

    func testResetClearsTheAnsweredQuestion() async throws {
        let controller = MonthAskClarityController(semanticProvider: StubSemanticProvider(result: nil))
        await controller.ask(
            "asdkfj qwerty", month: testDate(2025, 6, 1), entries: [], budgets: [], headCategories: [], settings: testSettings()
        )
        XCTAssertNotNil(controller.answered)

        controller.reset()

        XCTAssertNil(controller.answered)
    }
}
