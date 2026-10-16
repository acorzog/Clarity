import XCTest
import SwiftData
@testable import FinanceTracker

// MARK: - Ask Clarity benchmark
//
// A compact, curated set of realistic financial questions exercised end-to-end against the
// *real* deterministic pipeline (`AskClarityEngine.respond`/`respondWithSemanticFallback`) —
// never a mock of the engine itself. This is deliberately NOT a replacement for the fine-grained
// unit tests elsewhere (`AskClarityEngineTests`, `AskClaritySemanticInterpreterTests`,
// `AskClarityTrendAverageComparisonTests`, …), which already cover individual parsing rules and
// calculator edge cases in much finer detail. This file's job is different: read top-to-bottom,
// it should read as a representative *sample* of what a real user might type, grouped by the
// same five categories product/QA would reason about, with the expected interpretation,
// resolution path, and (where relevant) rejection reason spelled out in each test's doc comment
// — a living, executable spec rather than an isolated assertion.
//
// Every case here is either (a) a fresh combination not exercised anywhere else in the suite
// (flagged "GAP" in its doc comment), or (b) a smoke-level sample of an already-covered shape,
// using its own distinct question/dataset so it is never a byte-for-byte duplicate of an existing
// test. No production code is touched by this file, and no case ever reaches the real network —
// semantic-fallback cases use the same hand-written `BenchmarkStubSemanticProvider` pattern
// already established in `AskClaritySemanticInterpreterTests.swift`.

private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
}

private func testSettings() -> BudgetCalculationSettings {
    BudgetCalculationSettings(
        cycleStartDay: 1, manualMonthlyBudget: 0, includeUnplannedAsOtherExpenses: true,
        includeSavingsTransfers: false, includeDebtTransfers: true
    )
}

/// Anchors every case at a fixed Friday, mid-month/mid-week — matches `AskClarityEngineTests`'
/// own convention so date-range windows never cross a year boundary by surprise.
private let today = testDate(2025, 6, 20)

/// A "every field left at its default" interpretation builder — mirrors the identically-named
/// helper already established in `AskClaritySemanticInterpreterTests.swift`, kept as a private
/// copy here (rather than exported) since Swift test targets have no mechanism to share a
/// `private` helper across files without making it part of the production module.
private func blankInterpretation(
    metric: AskClarityMetric? = nil,
    categoryName: String? = nil,
    period: AskClaritySemanticPeriod? = nil,
    wantsTrend: Bool = false,
    trendSpan: Int? = nil
) -> AskClaritySemanticInterpretation {
    AskClaritySemanticInterpretation(
        metric: metric, categoryName: categoryName, period: period, ranking: nil, budgetState: nil,
        wantsBreakdown: false, wantsTrend: wantsTrend, trendSpan: trendSpan, wantsList: false,
        wantsTransactionRanking: false, wantsAssessment: false, comparisonRequested: false
    )
}

/// Records every call it receives and returns a fixed, injected outcome — never touches the
/// network. Standing in here for "Claude," the only semantic provider this benchmark ever uses.
private final class BenchmarkStubSemanticProvider: AskClaritySemanticProviding {
    private let result: AskClaritySemanticOutcome?
    private(set) var callCount = 0

    init(result: AskClaritySemanticOutcome?) {
        self.result = result
    }

    func interpret(context: AskClaritySemanticContext) async -> AskClaritySemanticOutcome? {
        callCount += 1
        return result
    }
}

/// A minimal household fixture shared by every case in this file — one wallet, three expense
/// categories under one head category, one income category. Individual tests add whatever
/// entries their own scenario needs on top of this.
private struct BenchmarkFixture {
    let context: ModelContext
    let wallet: Wallet
    let head: HeadCategory
    let dining: FinanceTracker.Category
    let groceries: FinanceTracker.Category
    let entertainment: FinanceTracker.Category
    let incomeHead: HeadCategory
    let salary: FinanceTracker.Category

    static func make() -> BenchmarkFixture {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food & Fun")
        let dining = TestSupport.makeCategory(name: "Dining", headCategory: head)
        let groceries = TestSupport.makeCategory(name: "Groceries", headCategory: head)
        let entertainment = TestSupport.makeCategory(name: "Entertainment", headCategory: head)
        let incomeHead = TestSupport.makeHeadCategory(name: "Income")
        let salary = TestSupport.makeCategory(name: "Salary", isIncome: true, headCategory: incomeHead)
        context.insert(wallet); context.insert(head); context.insert(dining); context.insert(groceries)
        context.insert(entertainment); context.insert(incomeHead); context.insert(salary)
        return BenchmarkFixture(
            context: context, wallet: wallet, head: head, dining: dining, groceries: groceries,
            entertainment: entertainment, incomeHead: incomeHead, salary: salary
        )
    }

    var headCategories: [HeadCategory] { [head, incomeHead] }

    func insert(_ entries: [Entry]) {
        entries.forEach { context.insert($0) }
    }
}

// MARK: - 1. Consultas directas (gasto / ingreso / presupuesto)

final class AskClarityBenchmarkDirectQueriesTests: XCTestCase {
    /// Pregunta: "How much have I saved this month?"
    /// Interpretación esperada: metric = .savings, sin categoría, periodo = thisMonth.
    /// Resolución: local (palabra "saved" reconocida directamente por `parseMetric`).
    /// Resultado esperado: refleja `savingsTransfersTotal` real, nunca inventado.
    /// GAP: ninguna prueba existente ejercita "savings" como pregunta directa de principio a fin.
    func testSavingsDirectQuestionReportsTheRealSavingsTransferTotal() {
        let fixture = BenchmarkFixture.make()
        let wallet2 = TestSupport.makeWallet(name: "Savings", type: .savings)
        fixture.context.insert(wallet2)
        let transfer = TestSupport.makeEntry(amount: 300, date: testDate(2025, 6, 10), type: .transfer, wallet: fixture.wallet, destinationWallet: wallet2)
        fixture.insert([transfer])

        let result = AskClarityEngine.respond(
            to: "How much have I saved this month?", context: .empty, entries: [transfer], budgets: [],
            headCategories: fixture.headCategories, settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("300"), result.answer.headline)
    }

    /// Pregunta: "How much budget do I have left?" — con gasto que EXCEDE el presupuesto.
    /// Interpretación esperada: metric = .remainingBudget, sin categoría.
    /// Resolución: local.
    /// Resultado esperado: total negativo, redactado como "gone over," nunca como dato ausente.
    /// GAP: la prueba existente solo cubre el caso exactamente cero, no negativo.
    func testOverspentRemainingBudgetIsReportedAsGoneOverNotMissingData() {
        let fixture = BenchmarkFixture.make()
        let budget = TestSupport.makeBudget(category: fixture.dining, monthlyLimit: 100, month: 6, year: 2025)
        let overspend = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: fixture.dining, wallet: fixture.wallet)
        fixture.context.insert(budget)
        fixture.insert([overspend])

        let result = AskClarityEngine.respond(
            to: "How much budget do I have left?", context: .empty, entries: [overspend], budgets: [budget],
            headCategories: fixture.headCategories, settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("gone"), result.answer.headline)
        XCTAssertTrue(result.answer.headline.contains("50"), result.answer.headline) // 150 spent - 100 available
    }

    /// Pregunta: "How much did I spend on Entertainment this month?"
    /// Interpretación esperada: metric = .spending, category = Entertainment, period = thisMonth.
    /// Resolución: local.
    /// Resultado esperado: total real de esa categoría únicamente (no mezcla con Dining/Groceries).
    func testCategoryDirectSpendingQuestionIsolatesOnlyThatCategory() {
        let fixture = BenchmarkFixture.make()
        let entertainment = TestSupport.makeEntry(amount: 60, date: testDate(2025, 6, 12), type: .expense, category: fixture.entertainment, wallet: fixture.wallet)
        let dining = TestSupport.makeEntry(amount: 999, date: testDate(2025, 6, 12), type: .expense, category: fixture.dining, wallet: fixture.wallet)
        fixture.insert([entertainment, dining])

        let result = AskClarityEngine.respond(
            to: "How much did I spend on Entertainment this month?", context: .empty, entries: [entertainment, dining],
            budgets: [], headCategories: fixture.headCategories, settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("60"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.contains("999"), result.answer.headline)
    }

    /// Pregunta: "What's my net worth?" (sin palabra de periodo).
    /// Interpretación esperada: ninguna — "net worth" no es una métrica/categoría/periodo
    /// reconocida localmente; cae a `isUnrecognizedLocally`.
    /// Resolución: fallback semántico JUSTIFICADO — Ask Clarity no calcula patrimonio neto, así
    /// que el proveedor (aquí, un stub) confirma `.unsupported` y la app responde sin inventar
    /// una cifra de patrimonio ni mencionar "net worth" en la respuesta.
    /// Motivo de rechazo: métrica no soportada por este dominio (gasto/ingreso/presupuesto/ahorro
    /// de categorías, no activos/pasivos).
    func testNetWorthQuestionWithNoPeriodWordIsUnrecognizedLocallyAndCorrectlyDeclaredUnsupported() async {
        let fixture = BenchmarkFixture.make()
        let stub = BenchmarkStubSemanticProvider(result: .unsupported)

        let result = await AskClarityEngine.respondWithSemanticFallback(
            to: "What's my net worth?", context: .empty, entries: [], budgets: [],
            headCategories: fixture.headCategories, settings: testSettings(), today: today, semanticProvider: stub
        )

        XCTAssertEqual(stub.callCount, 1, "no local signal at all — the semantic fallback must actually be consulted")
        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertFalse(result.answer.headline.lowercased().contains("net worth"), "must never echo back an out-of-scope metric as if it had an answer: \(result.answer.headline)")
    }

    /// Pregunta: "What's my net worth this month?" — misma pregunta ajena al dominio, pero con la
    /// palabra de periodo "this month" añadida.
    /// Interpretación esperada: "this month" por sí solo basta para `hasAnySignal == true`; el
    /// metric ausente se DEFAULTEA a `.spending` (regla de `AskClarityPlanner`, paso 9: "si hay
    /// periodo pero no metric, asumir gasto"). El intérprete nunca llega a enterarse de que la
    /// pregunta trataba sobre "net worth."
    /// Resolución: LOCAL — nunca se consulta el fallback semántico.
    /// HALLAZGO DOCUMENTADO (falso reconocimiento, no corregido en esta fase): Ask Clarity
    /// responde con el total de gasto del mes como si fuera una respuesta válida a una pregunta
    /// sobre patrimonio neto, sin ninguna señal de que no entendió la verdadera intención. La
    /// sola presencia de una palabra de periodo "secuestra" cualquier pregunta ajena al dominio.
    func testNetWorthQuestionWithThisMonthIsFalselyRecognizedAsAPlainSpendingTotal() async {
        let fixture = BenchmarkFixture.make()
        let entry = TestSupport.makeEntry(amount: 40, date: today, type: .expense, category: fixture.dining, wallet: fixture.wallet)
        fixture.insert([entry])
        let stub = BenchmarkStubSemanticProvider(result: .unsupported)

        let result = await AskClarityEngine.respondWithSemanticFallback(
            to: "What's my net worth this month?", context: .empty, entries: [entry], budgets: [],
            headCategories: fixture.headCategories, settings: testSettings(), today: today, semanticProvider: stub
        )

        XCTAssertEqual(stub.callCount, 0, "the bare word \"this month\" is already local signal, so the semantic provider is never consulted — this is the finding being documented")
        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("40"), "silently answered as a plain spending total instead of recognizing the question is out of scope: \(result.answer.headline)")
    }
}

// MARK: - 2. Comparaciones entre periodos y promedios históricos

final class AskClarityBenchmarkPeriodComparisonTests: XCTestCase {
    /// Pregunta: "Did I spend more on Groceries this month than last month?"
    /// Interpretación esperada: category = Groceries, comparisonRequested = true, previousPeriod.
    /// Resolución: local.
    /// Resultado esperado: una sola categoría con `comparison == .previousPeriod` responde con el
    /// monto del periodo actual en el headline y la comparación ("$X more/less than last month
    /// ($Y)") en `supportingDetail` — el veredicto "yes/no" explícito es exclusivo de la forma
    /// categoría-vs-categoría (`categoryComparisonAnswer`), nunca aparece aquí.
    func testPreviousMonthComparisonForACategoryAnswersWithBothFigures() {
        let fixture = BenchmarkFixture.make()
        let thisMonth = TestSupport.makeEntry(amount: 220, date: testDate(2025, 6, 10), type: .expense, category: fixture.groceries, wallet: fixture.wallet)
        let lastMonth = TestSupport.makeEntry(amount: 150, date: testDate(2025, 5, 10), type: .expense, category: fixture.groceries, wallet: fixture.wallet)
        fixture.insert([thisMonth, lastMonth])

        let result = AskClarityEngine.respond(
            to: "Did I spend more on Groceries this month than last month?", context: .empty, entries: [thisMonth, lastMonth],
            budgets: [], headCategories: fixture.headCategories, settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("220"), result.answer.headline)
        XCTAssertTrue(result.answer.supportingDetail.contains("70"), result.answer.supportingDetail) // |220-150|
        XCTAssertTrue(result.answer.supportingDetail.contains("150"), result.answer.supportingDetail)
        XCTAssertEqual(result.answer.comparisonIsFavorable, false, "spending more than the comparison period is unfavorable")
    }

    /// Pregunta: "How does my Entertainment spending compare to the average of the last 5 months?"
    /// Interpretación esperada: wantsTrend + wantsAverageComparison, category = Entertainment,
    /// trendSpan = 5.
    /// Resolución: local (operación determinista `.trendAverageComparison`).
    /// Resultado esperado: desviación absoluta y porcentual reales frente al promedio histórico.
    func testEntertainmentComparedToFiveMonthAverageFlagsARealDeviation() {
        let fixture = BenchmarkFixture.make()
        var entries: [Entry] = []
        for monthOffset in 1...4 {
            let date = Calendar.current.date(byAdding: .month, value: -monthOffset, to: testDate(2025, 6, 15))!
            entries.append(TestSupport.makeEntry(amount: 40, date: date, type: .expense, category: fixture.entertainment, wallet: fixture.wallet))
        }
        entries.append(TestSupport.makeEntry(amount: 160, date: testDate(2025, 6, 10), type: .expense, category: fixture.entertainment, wallet: fixture.wallet))
        fixture.insert(entries)

        let result = AskClarityEngine.respond(
            to: "How does my Entertainment spending compare to the average of the last 5 months?", context: .empty, entries: entries,
            budgets: [], headCategories: fixture.headCategories, settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("160"), result.answer.headline)
        XCTAssertTrue(result.answer.supportingDetail.contains("40"), result.answer.supportingDetail)
        XCTAssertTrue(result.answer.supportingDetail.contains("300%"), result.answer.supportingDetail) // (160-40)/40
        XCTAssertEqual(result.answer.comparisonIsFavorable, false)
    }

    /// Pregunta: "Did I spend more on Dining than Groceries on average this month?"
    /// Interpretación esperada: el parser detecta una comparación categoría-contra-categoría
    /// ("Dining" ... "than" ... "Groceries") — `AskClarityPlanner` resuelve esa forma en su PRIMER
    /// paso (paso 0), antes de que `wantsAverageComparison` llegue a considerarse siquiera.
    /// Resolución: local, pero el resultado es una comparación de UN SOLO periodo (betweenSubjects),
    /// no un promedio histórico — la palabra "average" se ignora silenciosamente para esta forma.
    /// GAP / limitación documentada (no corregida en esta fase): Ask Clarity no soporta "categoría
    /// A vs. categoría B, comparado con su promedio histórico" — solo compara el periodo actual
    /// entre dos categorías, o una categoría contra su propio promedio, nunca ambas combinadas.
    /// Este caso prueba que el comportamiento actual (silenciosamente ignorar "average" aquí) es
    /// real y estable, no que sea el resultado ideal.
    func testCategoryVersusCategoryPhrasingSilentlyIgnoresTheAverageWordAndComparesOnlyThisMonth() {
        let fixture = BenchmarkFixture.make()
        let dining = TestSupport.makeEntry(amount: 300, date: testDate(2025, 6, 10), type: .expense, category: fixture.dining, wallet: fixture.wallet)
        let groceries = TestSupport.makeEntry(amount: 100, date: testDate(2025, 6, 10), type: .expense, category: fixture.groceries, wallet: fixture.wallet)
        fixture.insert([dining, groceries])

        let result = AskClarityEngine.respond(
            to: "Did I spend more on Dining than Groceries on average this month?", context: .empty, entries: [dining, groceries],
            budgets: [], headCategories: fixture.headCategories, settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        // A plain this-month betweenSubjects answer, not a multi-period average — "average"
        // never surfaces anywhere in the wording, confirming it was silently dropped, not honored.
        XCTAssertTrue(result.answer.headline.contains("300") && result.answer.headline.contains("100"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.lowercased().contains("average"), result.answer.headline)
    }

    /// Pregunta: "Is my income usual compared to the last 4 months?" — con una categoría de
    /// ingreso cuya `HeadCategory` se llama literalmente "Income" (un nombre de cabecera
    /// perfectamente realista que un usuario podría elegir).
    /// Interpretación esperada (real): la palabra "income" en el texto coincide con el NOMBRE de
    /// la head category "Income" (que tiene un único hijo, "Salary") — `matchCategoryName` la
    /// resuelve como una referencia de CATEGORÍA, no solo como la palabra de métrica que
    /// `parseMetric` también reconoce. El plan termina con `subjects: [Salary]`.
    /// Resolución: local.
    /// HALLAZGO DOCUMENTADO (falso reconocimiento de categoría, no corregido en esta fase): en
    /// cuanto hay un `subject` (categoría) en el plan, el ejecutor SIEMPRE usa
    /// `categoriesSpending`/`AskClarityRangeCalculator.spending`, que filtra solo
    /// `entry.type == .expense` — nunca `.income`. El resultado es un **"$0" fabricado y
    /// engañoso** para una categoría de ingreso real con movimientos, simplemente porque su head
    /// category comparte nombre con la palabra "income". Esto es más grave que una simple
    /// ambigüedad: la respuesta parece válida (sin pedir aclaración) pero es incorrecta.
    func testIncomeWordCollidingWithAHeadCategoryNameSilentlyReportsAFalseZero() {
        let fixture = BenchmarkFixture.make()
        var entries: [Entry] = []
        for monthOffset in 1...3 {
            let date = Calendar.current.date(byAdding: .month, value: -monthOffset, to: testDate(2025, 6, 15))!
            entries.append(TestSupport.makeEntry(amount: 2000, date: date, type: .income, category: fixture.salary, wallet: fixture.wallet))
        }
        entries.append(TestSupport.makeEntry(amount: 2500, date: testDate(2025, 6, 5), type: .income, category: fixture.salary, wallet: fixture.wallet))
        fixture.insert(entries)

        let result = AskClarityEngine.respond(
            to: "Is my income usual compared to the last 4 months?", context: .empty, entries: entries,
            budgets: [], headCategories: fixture.headCategories, settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("Salary"), "the word \"income\" was resolved as a reference to the one-child \"Income\" head category: \(result.answer.headline)")
        XCTAssertTrue(result.answer.headline.contains("0"), "a real $2,500 income entry is reported as $0, because the category path only ever counts expenses: \(result.answer.headline)")
    }

    /// Misma pregunta de ingreso ("Is my income usual compared to the last 4 months?"), pero sin
    /// ninguna categoría/head-category cuyo nombre colisione con "income" — aquí "Earnings"/
    /// "Paycheck" no aparecen en el texto, así que nunca se resuelve una categoría.
    /// Interpretación esperada: metric = .income (vía `parseMetric`), sin categoría — plan
    /// categoryless, `metricTotal(.income,...)` (totalIncome real, sin el filtro de gasto).
    /// Resolución: local.
    /// Resultado esperado: compara el ingreso TOTAL del mes contra el promedio de los 3 meses
    /// anteriores, con dirección correcta (más ingreso que lo habitual = favorable, al revés que
    /// el gasto) — el camino "correcto" cuando no hay colisión de nombres con el hallazgo anterior.
    func testPlainIncomeAverageComparisonWorksCorrectlyWhenNoCategoryNameCollides() {
        // A standalone fixture, deliberately WITHOUT `BenchmarkFixture`'s own "Income"/"Salary"
        // pair — reusing it here would still collide on the word "income" (as the test above
        // demonstrates) and defeat the point of this contrasting case.
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let earningsHead = TestSupport.makeHeadCategory(name: "Earnings")
        let paycheck = TestSupport.makeCategory(name: "Paycheck", isIncome: true, headCategory: earningsHead)
        context.insert(wallet); context.insert(earningsHead); context.insert(paycheck)
        var entries: [Entry] = []
        for monthOffset in 1...3 {
            let date = Calendar.current.date(byAdding: .month, value: -monthOffset, to: testDate(2025, 6, 15))!
            entries.append(TestSupport.makeEntry(amount: 2000, date: date, type: .income, category: paycheck, wallet: wallet))
        }
        entries.append(TestSupport.makeEntry(amount: 2500, date: testDate(2025, 6, 5), type: .income, category: paycheck, wallet: wallet))
        entries.forEach { context.insert($0) }

        let result = AskClarityEngine.respond(
            to: "Is my income usual compared to the last 4 months?", context: .empty, entries: entries,
            budgets: [], headCategories: [earningsHead], settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("2,500") || result.answer.headline.contains("2.500") || result.answer.headline.contains("2500"), result.answer.headline)
        XCTAssertEqual(result.answer.comparisonIsFavorable, true, "more income than usual is favorable, the opposite of spending")
    }
}

// MARK: - 3. Tendencias, variaciones y posibles anomalías

final class AskClarityBenchmarkTrendAndAnomalyTests: XCTestCase {
    /// Pregunta: "What's my Groceries spending trend the last 4 months?"
    /// Interpretación esperada: wantsTrend, sin "average"/"usual" → lista de puntos, no comparación.
    /// Resolución: local (`.trend`, no `.trendAverageComparison`).
    /// Resultado esperado: lista de 4 cifras mensuales reales, ninguna inventada.
    func testPlainGroceriesTrendListsFourRealMonthlyFigures() {
        let fixture = BenchmarkFixture.make()
        var entries: [Entry] = []
        let amounts: [Decimal] = [90, 110, 95, 130]
        for (index, amount) in amounts.enumerated() {
            let date = Calendar.current.date(byAdding: .month, value: -(3 - index), to: testDate(2025, 6, 15))!
            entries.append(TestSupport.makeEntry(amount: amount, date: date, type: .expense, category: fixture.groceries, wallet: fixture.wallet))
        }
        fixture.insert(entries)

        let result = AskClarityEngine.respond(
            to: "What's my Groceries spending trend the last 4 months?", context: .empty, entries: entries,
            budgets: [], headCategories: fixture.headCategories, settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        for amount in amounts {
            XCTAssertTrue(result.answer.supportingDetail.contains("\(amount)"), "\(amount) missing from \(result.answer.supportingDetail)")
        }
    }

    /// Pregunta: "Is my Dining spending normal compared to the last 3 months?" — SIN anomalía:
    /// el mes actual coincide casi exactamente con el promedio histórico.
    /// Interpretación esperada: wantsAverageComparison, category = Dining, trendSpan = 3.
    /// Resolución: local.
    /// Resultado esperado: diferencia porcentual pequeña, redactada como dentro de lo habitual,
    /// nunca como una anomalía fabricada solo porque la pregunta use la palabra "normal".
    func testNoRealAnomalyIsNeverFabricatedJustBecauseTheQuestionAsksAboutNormality() {
        let fixture = BenchmarkFixture.make()
        var entries: [Entry] = []
        for monthOffset in 1...2 {
            let date = Calendar.current.date(byAdding: .month, value: -monthOffset, to: testDate(2025, 6, 15))!
            entries.append(TestSupport.makeEntry(amount: 100, date: date, type: .expense, category: fixture.dining, wallet: fixture.wallet))
        }
        entries.append(TestSupport.makeEntry(amount: 102, date: testDate(2025, 6, 10), type: .expense, category: fixture.dining, wallet: fixture.wallet))
        fixture.insert(entries)

        let result = AskClarityEngine.respond(
            to: "Is my Dining spending normal compared to the last 3 months?", context: .empty, entries: entries,
            budgets: [], headCategories: fixture.headCategories, settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.supportingDetail.contains("2%"), result.answer.supportingDetail) // (102-100)/100
    }

    /// Pregunta: "Compare my Hobbies spending to the average of the last 3 months" aplicada a una
    /// categoría de GASTO recién creada (sin historial real) — deliberadamente una categoría de
    /// gasto, no de ingreso, para aislar el caso de "cero histórico real" del hallazgo de la
    /// colisión ingreso/categoría documentado arriba (`testIncomeWordCollidingWith...`).
    /// Interpretación esperada: wantsAverageComparison, category = Hobbies, metric = .spending.
    /// Resolución: local.
    /// Resultado esperado: promedio = 0 (todos los meses anteriores sin movimientos reales en esa
    /// categoría), reportado con una frase explícita de "no hay promedio con qué comparar," nunca
    /// un porcentaje inventado.
    func testBrandNewExpenseCategoryComparedToAverageReportsNoPriorDataWithoutFabricatingAPercentage() {
        let fixture = BenchmarkFixture.make()
        let hobbies = TestSupport.makeCategory(name: "Hobbies", headCategory: fixture.head)
        fixture.context.insert(hobbies)
        let entry = TestSupport.makeEntry(amount: 50, date: testDate(2025, 6, 10), type: .expense, category: hobbies, wallet: fixture.wallet)
        fixture.insert([entry])

        let result = AskClarityEngine.respond(
            to: "Compare my Hobbies spending to the average of the last 3 months", context: .empty, entries: [entry],
            budgets: [], headCategories: fixture.headCategories, settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("50"), result.answer.headline)
        XCTAssertTrue(result.answer.supportingDetail.contains("no") && result.answer.supportingDetail.contains("average"), result.answer.supportingDetail)
        XCTAssertFalse(result.answer.supportingDetail.contains("%"), result.answer.supportingDetail)
    }
}

// MARK: - 4. Contexto conversacional y referencias ambiguas

final class AskClarityBenchmarkConversationalTests: XCTestCase {
    /// Turno 1: "Compare my Dining spending to the average of the last 4 months" (local,
    /// `.trendAverageComparison`). Turno 2: "What about last month?" (seguimiento mínimo,
    /// hereda categoría/métrica del contexto, pero pide un periodo concreto nuevo).
    /// Interpretación esperada del turno 2: categoría heredada = Dining, metric heredado =
    /// spending, periodo explícito = lastMonth → una pregunta de MONTO PLANO para ese mes, no
    /// una segunda comparación contra el promedio (el turno 2 no repite "average"/"usual").
    /// Resolución: local en ambos turnos.
    /// GAP: ninguna prueba existente encadena una respuesta de `trendAverageComparison` con un
    /// seguimiento de solo-periodo; confirma que el contexto se actualiza correctamente después
    /// de esa operación nueva, igual que ya ocurre tras una pregunta de monto plano.
    func testFollowUpAfterAnAverageComparisonInheritsCategoryAndAnswersThePlainAmountForTheNewPeriod() {
        let fixture = BenchmarkFixture.make()
        var entries: [Entry] = []
        for monthOffset in 1...3 {
            let date = Calendar.current.date(byAdding: .month, value: -monthOffset, to: testDate(2025, 6, 15))!
            entries.append(TestSupport.makeEntry(amount: 100, date: date, type: .expense, category: fixture.dining, wallet: fixture.wallet))
        }
        entries.append(TestSupport.makeEntry(amount: 300, date: testDate(2025, 6, 10), type: .expense, category: fixture.dining, wallet: fixture.wallet))
        fixture.insert(entries)

        let turn1 = AskClarityEngine.respond(
            to: "Compare my Dining spending to the average of the last 4 months", context: .empty, entries: entries,
            budgets: [], headCategories: fixture.headCategories, settings: testSettings(), today: today
        )
        XCTAssertTrue(turn1.answer.headline.contains("300"), turn1.answer.headline)

        let turn2 = AskClarityEngine.respond(
            to: "What about last month?", context: turn1.updatedContext, entries: entries,
            budgets: [], headCategories: fixture.headCategories, settings: testSettings(), today: today
        )
        XCTAssertTrue(turn2.answer.hasSufficientData)
        XCTAssertTrue(turn2.answer.headline.contains("Dining"), "must still be about Dining, inherited from turn 1: \(turn2.answer.headline)")
        XCTAssertTrue(turn2.answer.headline.contains("100"), "last month's own plain figure (100), not another average comparison: \(turn2.answer.headline)")
    }

    /// Turno 1: una pregunta sin señal local alguna, respondida vía fallback semántico con un
    /// resultado `.composed` (comparación actual-vs-promedio producida por dos tool calls
    /// paralelos simulados). Turno 2: "What about last month?" — un seguimiento mínimo.
    /// Interpretación esperada del turno 2: al no haber categoría/metric propios, dependería
    /// enteramente de lo que el turno 1 haya guardado en el contexto de sesión.
    /// Resolución: local en el turno 2 (tiene señal de periodo propia: "last month").
    /// LIMITACIÓN DOCUMENTADA (no corregida en esta fase): `AskClaritySemanticComposition.respond`
    /// devuelve el `context` SIN modificar (ver su propio comentario: "a semantic interpretation
    /// never participates in... context inheritance"), así que el turno 2 NO hereda la categoría
    /// de la comparación `.composed` del turno 1 — termina siendo un total plano de gasto de todo
    /// el mes pasado, no "Dining el mes pasado" como un usuario probablemente esperaría. Esta
    /// prueba fija ese comportamiento actual para que un cambio futuro sea una decisión explícita,
    /// no una regresión silenciosa.
    /// GAP: ninguna prueba existente encadena un resultado `.composed` con un seguimiento.
    func testFollowUpAfterAComposedAnswerDoesNotInheritItsCategoryBecauseComposedNeverUpdatesContext() async {
        let fixture = BenchmarkFixture.make()
        let diningThisMonth = TestSupport.makeEntry(amount: 300, date: testDate(2025, 6, 10), type: .expense, category: fixture.dining, wallet: fixture.wallet)
        let groceriesLastMonth = TestSupport.makeEntry(amount: 50, date: testDate(2025, 5, 10), type: .expense, category: fixture.groceries, wallet: fixture.wallet)
        var entries = [diningThisMonth, groceriesLastMonth]
        for monthOffset in 1...3 {
            let date = Calendar.current.date(byAdding: .month, value: -monthOffset, to: testDate(2025, 6, 15))!
            entries.append(TestSupport.makeEntry(amount: 100, date: date, type: .expense, category: fixture.dining, wallet: fixture.wallet))
        }
        fixture.insert(entries)

        let current = blankInterpretation(metric: .spending, categoryName: "Dining", period: .named(.thisMonth))
        let trend = blankInterpretation(metric: .spending, categoryName: "Dining", wantsTrend: true, trendSpan: 4)
        let stub = BenchmarkStubSemanticProvider(result: .composed(current, trend))

        let turn1 = await AskClarityEngine.respondWithSemanticFallback(
            to: "I've been treating myself to eating out, how unusual is that", context: .empty, entries: entries,
            budgets: [], headCategories: fixture.headCategories, settings: testSettings(), today: today, semanticProvider: stub
        )
        XCTAssertTrue(turn1.answer.headline.contains("300"), turn1.answer.headline)

        let turn2 = AskClarityEngine.respond(
            to: "What about last month?", context: turn1.updatedContext, entries: entries,
            budgets: [], headCategories: fixture.headCategories, settings: testSettings(), today: today
        )
        XCTAssertTrue(turn2.answer.hasSufficientData)
        XCTAssertFalse(turn2.answer.headline.contains("Dining"), "documents the current limitation: a .composed answer never updates session context, so this follow-up can't know the prior turn was about Dining: \(turn2.answer.headline)")
    }

    /// Turno 1: "Is Dining over budget?" (budgetState, categoría explícita). Turno 2: "What about
    /// Groceries?" (seguimiento mínimo que cambia de categoría, mantiene la misma pregunta
    /// implícita de estado de presupuesto).
    /// Interpretación esperada del turno 2: la categoría cambia a Groceries; el tipo de pregunta
    /// (budgetState) NO se hereda — `isMinimalFollowUp` solo hereda categoría/metric/periodo, no
    /// `budgetState` — así que el turno 2 responde como una pregunta de MONTO PLANO para
    /// Groceries, no como un segundo chequeo de presupuesto.
    /// Resolución: local en ambos turnos.
    /// GAP: combinación categoría-presupuesto → categoría-monto no estaba cubierta explícitamente.
    func testSwitchingCategoryAfterABudgetStateQuestionDoesNotCarryTheBudgetStateIntent() {
        let fixture = BenchmarkFixture.make()
        let budget = TestSupport.makeBudget(category: fixture.dining, monthlyLimit: 100, month: 6, year: 2025)
        let diningSpend = TestSupport.makeEntry(amount: 150, date: testDate(2025, 6, 10), type: .expense, category: fixture.dining, wallet: fixture.wallet)
        let groceriesSpend = TestSupport.makeEntry(amount: 75, date: testDate(2025, 6, 10), type: .expense, category: fixture.groceries, wallet: fixture.wallet)
        fixture.context.insert(budget)
        fixture.insert([diningSpend, groceriesSpend])

        let turn1 = AskClarityEngine.respond(
            to: "Is Dining over budget?", context: .empty, entries: [diningSpend, groceriesSpend], budgets: [budget],
            headCategories: fixture.headCategories, settings: testSettings(), today: today
        )
        XCTAssertTrue(turn1.answer.headline.lowercased().contains("over budget"), turn1.answer.headline)

        let turn2 = AskClarityEngine.respond(
            to: "What about Groceries?", context: turn1.updatedContext, entries: [diningSpend, groceriesSpend], budgets: [budget],
            headCategories: fixture.headCategories, settings: testSettings(), today: today
        )
        XCTAssertTrue(turn2.answer.hasSufficientData)
        XCTAssertTrue(turn2.answer.headline.contains("Groceries"), turn2.answer.headline)
        XCTAssertTrue(turn2.answer.headline.contains("75"), turn2.answer.headline)
        XCTAssertFalse(turn2.answer.headline.lowercased().contains("budget"), "budgetState intent is never carried by a minimal category-swap follow-up: \(turn2.answer.headline)")
    }

    /// Pregunta aislada, SIN turno previo: "What about last week?" — un fragmento que solo tiene
    /// sentido como continuación, pero llega como el primer mensaje de la conversación
    /// (`context: .empty`).
    /// Interpretación esperada: periodo = lastWeek reconocido; categoría/metric no heredados (no
    /// hay nada que heredar) → pregunta de gasto total de la semana pasada.
    /// Resolución: local — nunca debe fallar o caer al fallback semántico solo por carecer de
    /// contexto previo.
    func testMinimalFollowUpPhrasingAsTheVeryFirstMessageStillAnswersGracefully() {
        let fixture = BenchmarkFixture.make()
        let lastWeekEntry = TestSupport.makeEntry(amount: 45, date: testDate(2025, 6, 14), type: .expense, category: fixture.groceries, wallet: fixture.wallet)
        fixture.insert([lastWeekEntry])

        let result = AskClarityEngine.respond(
            to: "What about last week?", context: .empty, entries: [lastWeekEntry], budgets: [],
            headCategories: fixture.headCategories, settings: testSettings(), today: today
        )

        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("45"), result.answer.headline)
    }
}

// MARK: - 5. Datos insuficientes, categorías inexistentes, métricas incompatibles

final class AskClarityBenchmarkRejectionTests: XCTestCase {
    /// Pregunta: "How much did I spend on Yachting this month?"
    /// Interpretación esperada: frase tras "on" reconocida como candidata a categoría, pero
    /// "Yachting" no coincide con ninguna categoría/head-category real.
    /// Resolución: local.
    /// Motivo de rechazo: `.notFound(phrase: "yachting")` — nunca se adivina ni se ofrece el
    /// total de otra categoría parecida.
    func testNonexistentCategoryIsRejectedByNameNotGuessedAtASimilarOne() {
        let fixture = BenchmarkFixture.make()
        let diningSpend = TestSupport.makeEntry(amount: 999, date: testDate(2025, 6, 10), type: .expense, category: fixture.dining, wallet: fixture.wallet)
        fixture.insert([diningSpend])

        let result = AskClarityEngine.respond(
            to: "How much did I spend on Yachting this month?", context: .empty, entries: [diningSpend], budgets: [],
            headCategories: fixture.headCategories, settings: testSettings(), today: today
        )

        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.lowercased().contains("yachting"), result.answer.headline)
        XCTAssertFalse(result.answer.headline.contains("999"), "must never silently substitute a real category's total: \(result.answer.headline)")
    }

    /// Pregunta sin NINGUNA señal local ("totally random musings about my day") cuyo proveedor
    /// semántico (simulado) devuelve un periodo que `AskClaritySemanticQueryBuilder` no puede
    /// resolver (mes inexistente "Smarch").
    /// Interpretación esperada: el parser local no reconoce nada → se consulta el fallback;
    /// `AskClaritySemanticOutcome.understood` llega con un `period.specificMonth(monthName:
    /// "Smarch")` que no es un mes real.
    /// Resolución: fallback semántico JUSTIFICADO (cero señal local), pero su resultado se
    /// DESCARTA por completo (nunca se construye una `AskClarityQuery` con un mes inventado) →
    /// se cae a la respuesta local genérica de "no pude entender," nunca a un periodo fabricado.
    /// Motivo de rechazo: periodo no resoluble, ni local ni semánticamente.
    /// GAP: la cobertura existente separa "periodo no soportado" (camino local) de "fallo del
    /// proveedor" (camino semántico), pero no un `.understood` semánticamente válido en forma que
    /// aun así no logra construir una `AskClarityQuery` real.
    func testSemanticOutcomeWithAnUnresolvablePeriodIsDiscardedRatherThanFabricatingOne() async {
        let fixture = BenchmarkFixture.make()
        let interpretation = blankInterpretation(metric: .spending, period: .specificMonth(monthName: "Smarch"))
        let stub = BenchmarkStubSemanticProvider(result: .understood(interpretation))

        let result = await AskClarityEngine.respondWithSemanticFallback(
            to: "totally random musings about my day", context: .empty, entries: [], budgets: [],
            headCategories: fixture.headCategories, settings: testSettings(), today: today, semanticProvider: stub
        )

        XCTAssertEqual(stub.callCount, 1)
        XCTAssertFalse(result.answer.hasSufficientData)
        XCTAssertEqual(result.answer.headline, "I couldn't find a supported way to answer that yet.")
    }

    /// Pregunta completamente ajena al dominio: "What's the weather like today?"
    /// Interpretación esperada: ninguna señal local salvo, potencialmente, la palabra "today"
    /// como periodo — pero sin metric/categoría/ranking/etc., así que de todas formas no hay
    /// suficiente para responder localmente de forma significativa... salvo que SÍ hay señal
    /// local (periodMatch=.supported(today)), así que `isUnrecognizedLocally` sería FALSO y el
    /// proveedor semántico NUNCA se consulta — la pregunta se responde (incorrectamente, desde
    /// el punto de vista del usuario) como un total de gasto de "today."
    /// LIMITACIÓN DOCUMENTADA (no corregida en esta fase): una palabra de periodo aislada
    /// ("today") dentro de una pregunta genuinamente ajena al dominio ("the weather... today")
    /// es suficiente para que el intérprete local la trate como "entendida" y nunca la escale al
    /// fallback semántico, aunque el resto de la frase no tenga nada que ver con finanzas.
    func testWeatherQuestionWithTheWordTodayIsAnsweredLocallyAsATotalRatherThanEscalated() async {
        let fixture = BenchmarkFixture.make()
        let entry = TestSupport.makeEntry(amount: 25, date: today, type: .expense, category: fixture.dining, wallet: fixture.wallet)
        fixture.insert([entry])
        let stub = BenchmarkStubSemanticProvider(result: .unsupported)

        let result = await AskClarityEngine.respondWithSemanticFallback(
            to: "What's the weather like today?", context: .empty, entries: [entry], budgets: [],
            headCategories: fixture.headCategories, settings: testSettings(), today: today, semanticProvider: stub
        )

        XCTAssertEqual(stub.callCount, 0, "the bare word \"today\" is already local signal, so the semantic provider is never consulted — this is the limitation being documented")
        XCTAssertTrue(result.answer.hasSufficientData)
        XCTAssertTrue(result.answer.headline.contains("25"), result.answer.headline)
    }
}
