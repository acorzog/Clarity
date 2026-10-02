import XCTest
@testable import FinanceTracker

final class CategorizationServiceTests: XCTestCase {

    // MARK: - VoiceExpenseParser

    func testVoiceExpenseParserParsesEnglishTaxiExpense() {
        let result = VoiceExpenseParser.parse("20 euros on taxi")

        XCTAssertEqual(result?.amount, 20)
        XCTAssertEqual(result?.note, "taxi")
        XCTAssertEqual(result?.categoryHint, .transport)
    }

    func testVoiceExpenseParserParsesSpanishMercadonaExpenseWithCommaDecimal() {
        let result = VoiceExpenseParser.parse("5,50 euros en Mercadona")

        XCTAssertEqual(result?.amount, Decimal(string: "5.50"))
        XCTAssertEqual(result?.note, "Mercadona")
        XCTAssertEqual(result?.categoryHint, .groceries)
    }

    func testVoiceExpenseParserExtractsSpokenDateAndRemovesItFromNote() {
        let result = VoiceExpenseParser.parse("12 euros in bread 20 of September")
        let calendar = Calendar.current

        XCTAssertEqual(result?.amount, 12)
        XCTAssertEqual(result?.note, "bread")
        XCTAssertEqual(result.map { calendar.component(.day, from: $0.date) }, 20)
        XCTAssertEqual(result.map { calendar.component(.month, from: $0.date) }, 9)
    }

    func testVoiceExpenseParserExtractsSpanishSpokenDate() {
        let result = VoiceExpenseParser.parse("12 euros en pan 20 de septiembre")
        let calendar = Calendar.current

        XCTAssertEqual(result?.note, "pan")
        XCTAssertEqual(result.map { calendar.component(.day, from: $0.date) }, 20)
        XCTAssertEqual(result.map { calendar.component(.month, from: $0.date) }, 9)
    }

    // MARK: - Relative and weekday dates

    /// A fixed Wednesday, so weekday-reference expectations below don't depend on when the
    /// test suite happens to run.
    private func referenceDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func day(_ date: Date) -> Int { Calendar.current.component(.day, from: date) }
    private func month(_ date: Date) -> Int { Calendar.current.component(.month, from: date) }
    private func year(_ date: Date) -> Int { Calendar.current.component(.year, from: date) }

    func testVoiceExpenseParserRecognizesTodayYesterdayTomorrow() {
        let now = referenceDate(2026, 1, 7)

        let todayResult = VoiceExpenseParser.parse("20 euros on taxi today", referenceDate: now)
        let yesterdayResult = VoiceExpenseParser.parse("20 euros on taxi ayer", referenceDate: now)
        let tomorrowResult = VoiceExpenseParser.parse("20 euros on taxi tomorrow", referenceDate: now)

        XCTAssertEqual(todayResult?.date, Calendar.current.startOfDay(for: now))
        XCTAssertEqual(yesterdayResult?.date, Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: now)))
        XCTAssertEqual(tomorrowResult?.date, Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)))
        XCTAssertEqual(todayResult?.note, "taxi", "the relative-day word must be removed from the note")
    }

    /// "20 euros on taxi tomorrow" spoken on the last day of the year must roll over into
    /// January of the following year — proves the relative-day math reuses `Calendar`'s own
    /// day arithmetic rather than any hand-rolled month/year logic.
    func testVoiceExpenseParserTomorrowRollsOverIntoTheNextYear() {
        let now = referenceDate(2025, 12, 31)
        let result = VoiceExpenseParser.parse("20 euros on taxi tomorrow", referenceDate: now)

        XCTAssertEqual(result.map { self.day($0.date) }, 1)
        XCTAssertEqual(result.map { self.month($0.date) }, 1)
        XCTAssertEqual(result.map { self.year($0.date) }, 2026)
    }

    /// Symmetric case: "yesterday" spoken on the first day of the year rolls back into
    /// December of the previous year.
    func testVoiceExpenseParserYesterdayRollsBackIntoThePreviousYear() {
        let now = referenceDate(2026, 1, 1)
        let result = VoiceExpenseParser.parse("20 euros on taxi yesterday", referenceDate: now)

        XCTAssertEqual(result.map { self.day($0.date) }, 31)
        XCTAssertEqual(result.map { self.month($0.date) }, 12)
        XCTAssertEqual(result.map { self.year($0.date) }, 2025)
    }

    /// An unqualified weekday ("el lunes") means the nearest occurrence on or before today —
    /// the natural reading for something already spent. `now` is a Wednesday; the preceding
    /// Monday is 2026-01-05.
    func testVoiceExpenseParserBareWeekdayResolvesToTheNearestPastOccurrence() {
        let now = referenceDate(2026, 1, 7)
        let result = VoiceExpenseParser.parse("20 euros en taxi el lunes", referenceDate: now)

        XCTAssertEqual(result.map { self.day($0.date) }, 5)
        XCTAssertEqual(result.map { self.month($0.date) }, 1)
        XCTAssertEqual(result?.note, "taxi")
    }

    /// "last Friday" must mean the most recent Friday strictly before today, even though the
    /// unqualified form above would already land on-or-before today — 2026-01-02.
    func testVoiceExpenseParserLastWeekdayResolvesToTheMostRecentPastOccurrence() {
        let now = referenceDate(2026, 1, 7)
        let result = VoiceExpenseParser.parse("20 euros on taxi last Friday", referenceDate: now)

        XCTAssertEqual(result.map { self.day($0.date) }, 2)
        XCTAssertEqual(result.map { self.month($0.date) }, 1)
    }

    /// "next Monday" must mean the following week's Monday, 2026-01-12 — not the Monday that
    /// already passed this week.
    func testVoiceExpenseParserNextWeekdayResolvesToTheUpcomingOccurrence() {
        let now = referenceDate(2026, 1, 7)
        let result = VoiceExpenseParser.parse("20 euros on taxi next Monday", referenceDate: now)

        XCTAssertEqual(result.map { self.day($0.date) }, 12)
        XCTAssertEqual(result.map { self.month($0.date) }, 1)
    }

    /// No recognizable date reference at all must keep the existing safe default
    /// (`referenceDate`, `.now` in production) rather than inventing one.
    func testVoiceExpenseParserWithNoDateReferenceDefaultsToReferenceDate() {
        let now = referenceDate(2026, 3, 15)
        let result = VoiceExpenseParser.parse("20 euros on taxi", referenceDate: now)

        XCTAssertEqual(result?.date, now)
    }

    /// Each clause names its own day, so a mixed income/expense phrase must give each entry its
    /// own date rather than sharing one across the whole utterance.
    func testVoiceExpenseParserParseAllGivesEachClauseItsOwnDate() {
        let now = referenceDate(2026, 1, 7)
        let expenses = VoiceExpenseParser.parseAll("15 en taxi ayer y 25 en supermercado hoy", referenceDate: now)

        XCTAssertEqual(expenses.map(\.amount), [15, 25])
        XCTAssertEqual(expenses.map { self.day($0.date) }, [6, 7])
    }

    /// A date said once, outside any individual clause, still applies to every clause that
    /// didn't name its own day — preserves the original "shared trailing date" behavior.
    func testVoiceExpenseParserParseAllAppliesATrailingSharedDateToEveryClauseWithoutItsOwn() {
        let now = referenceDate(2026, 1, 7)
        let expenses = VoiceExpenseParser.parseAll("15 en taxi y 25 en supermercado, 20 de septiembre", referenceDate: now)

        XCTAssertEqual(expenses.map(\.amount), [15, 25])
        XCTAssertEqual(expenses.map { self.day($0.date) }, [20, 20])
        XCTAssertEqual(expenses.map { self.month($0.date) }, [9, 9])
    }

    func testVoiceExpenseParserParsesTwoSpanishExpenses() {
        let expenses = VoiceExpenseParser.parseAll("15 en taxi y 25 en supermercado")

        XCTAssertEqual(expenses.map(\.amount), [15, 25])
        XCTAssertEqual(expenses.map(\.note), ["taxi", "supermercado"])
        XCTAssertEqual(expenses.map(\.categoryHint), [.transport, .groceries])
    }

    func testVoiceExpenseParserMatchesOnlyAnExistingUserCategory() {
        let groceries = makeCategory("Groceries")
        let transport = makeCategory("Transport")

        XCTAssertEqual(
            VoiceExpenseParser.categoryMatch(for: .groceries, in: [transport, groceries])?.name,
            groceries.name
        )
        XCTAssertEqual(
            VoiceExpenseParser.categoryMatch(for: .transport, in: [groceries, transport])?.name,
            transport.name
        )
    }

    func testVoiceExpenseParserMapsBreadToGroceriesAndTaxiToTaxiCategory() {
        let groceries = makeCategory("Groceries")
        let taxi = makeCategory("Taxi")
        let other = makeCategory("Miscellaneous")

        XCTAssertEqual(
            VoiceExpenseParser.categoryMatch(for: "bread", in: [other, groceries, taxi])?.name,
            groceries.name
        )
        XCTAssertEqual(
            VoiceExpenseParser.categoryMatch(for: "Taxi ride", in: [other, groceries, taxi])?.name,
            taxi.name
        )
    }

    // MARK: - Semantic/context category matching

    /// "cenar fuera" (dining out) isn't an exact keyword the way "restaurant" is, but its verb
    /// "cenar" should still resolve to an existing Restaurants category.
    func testVoiceExpenseParserMatchesDiningOutPhraseToRestaurants() {
        let restaurants = makeCategory("Restaurants")
        let groceries = makeCategory("Groceries")

        XCTAssertEqual(
            VoiceExpenseParser.categoryMatch(for: "cenar fuera con amigos", in: [groceries, restaurants])?.name,
            restaurants.name
        )
    }

    /// "vuelo" (flight) should resolve to the user's own more specific Flights subcategory
    /// rather than only the broader Travelling head category.
    func testVoiceExpenseParserMatchesFlightWordToFlightsSubcategory() {
        let travelling = TestSupport.makeHeadCategory(name: "Travelling")
        let flights = TestSupport.makeCategory(name: "Flights", headCategory: travelling)
        let hotels = TestSupport.makeCategory(name: "Hotels", headCategory: travelling)

        XCTAssertEqual(
            VoiceExpenseParser.categoryMatch(for: "vuelo a Roma", in: [flights, hotels])?.name,
            flights.name
        )
    }

    /// A bare mention of the parent/head concept ("viaje"/"travel"), with no specific word like
    /// "vuelo", must not force a guess at a particular subcategory — it should only resolve when
    /// the person has an actual category named that generic thing, via `localCategoryMatch`.
    func testVoiceExpenseParserBareParentCategoryWordDoesNotForceASubcategory() {
        let travelling = TestSupport.makeHeadCategory(name: "Travelling")
        let flights = TestSupport.makeCategory(name: "Flights", headCategory: travelling)
        let travel = TestSupport.makeCategory(name: "Travel", headCategory: travelling)

        // "travel" must appear literally in the note for `localCategoryMatch` to find it —
        // this isolates "a bare parent word resolves via the person's own category name" from
        // any language-specific keyword-table behavior.
        XCTAssertEqual(
            VoiceExpenseParser.categoryMatch(for: "travel to Rome", in: [flights, travel])?.name,
            travel.name,
            "a generic travel word should match the person's own 'Travel' category, not be guessed into Flights"
        )
    }

    /// "Uber" should still resolve when the person only has a broader Transportation category,
    /// not just a literal "Taxi" one.
    func testVoiceExpenseParserFallsBackToBroaderTransportationWhenNoTaxiCategoryExists() {
        let transportation = makeCategory("Transportation")

        XCTAssertEqual(
            VoiceExpenseParser.categoryMatch(for: "Uber", in: [transportation])?.name,
            transportation.name
        )
    }

    /// When both a specific "Taxi" category and a broader "Transportation" one exist, the more
    /// specific one still wins — matches the existing precedent in
    /// `testVoiceExpenseParserMapsBreadToGroceriesAndTaxiToTaxiCategory`.
    func testVoiceExpenseParserPrefersSpecificTaxiCategoryOverBroaderTransportationWhenBothExist() {
        let taxi = makeCategory("Taxi")
        let transportation = makeCategory("Transportation")

        XCTAssertEqual(
            VoiceExpenseParser.categoryMatch(for: "Uber", in: [transportation, taxi])?.name,
            taxi.name
        )
    }

    /// A specific brand/merchant word ("Mercadona") is trusted over a merely generic word that
    /// happens to also be present ("comida") — this is the spec's own worked example.
    func testVoiceExpenseParserGroceryPurchaseAtMercadonaIsNotConfusedWithRestaurants() {
        let groceries = makeCategory("Groceries")
        let restaurants = makeCategory("Restaurants")

        XCTAssertEqual(
            VoiceExpenseParser.categoryMatch(for: "compré comida en Mercadona", in: [restaurants, groceries])?.name,
            groceries.name
        )
    }

    /// Two equally generic words that each point at a genuinely different existing category must
    /// not be silently resolved — the person should pick in the review step instead.
    func testVoiceExpenseParserLeavesAmbiguousGenericWordsUnresolved() {
        let restaurants = makeCategory("Restaurants")
        let coffee = makeCategory("Coffee & Snacks")

        XCTAssertNil(VoiceExpenseParser.categoryMatch(for: "desayuno y cena con la familia", in: [restaurants, coffee]))
    }

    /// Real Santander notification merchant text ("CONSUM V.CARTAG") — the bank truncates/
    /// abbreviates it, but "consum" alone (a Spanish supermarket chain) is enough to resolve to
    /// Groceries via the strong-word table, same as "Mercadona" above.
    func testVoiceExpenseParserResolvesConsumMerchantTextToGroceries() {
        let groceries = makeCategory("Groceries")
        let restaurants = makeCategory("Restaurants")

        XCTAssertEqual(
            VoiceExpenseParser.categoryMatch(for: "CONSUM", in: [restaurants, groceries])?.name,
            groceries.name
        )
    }

    /// Real Santander notification merchant text ("FGV VALENCIA SI") — FGV is Valencia's public
    /// transit operator (metro/tram), matched against the user's actual "Public Transit" category
    /// name from their real category list.
    func testVoiceExpenseParserResolvesFGVMerchantTextToPublicTransit() {
        let publicTransit = makeCategory("Public Transit")
        let taxi = makeCategory("Taxi")

        XCTAssertEqual(
            VoiceExpenseParser.categoryMatch(for: "FGV VALENCIA SI", in: [taxi, publicTransit])?.name,
            publicTransit.name
        )
    }

    /// Income and expense categories are kept separate by the caller filtering the candidate
    /// list (see `AddTransactionView`/`HomeView`) — an expense-shaped note must never resolve to
    /// an income category even if both happen to be passed in together.
    func testVoiceExpenseParserNeverMatchesAnIncomeCategoryForAnExpenseWord() {
        let salary = makeCategory("Salary", isIncome: true)
        let taxi = makeCategory("Taxi")

        XCTAssertEqual(VoiceExpenseParser.categoryMatch(for: "Uber", in: [salary, taxi])?.name, taxi.name)
    }

    func testVoiceExpenseParserRejectsMissingOrZeroAmount() {
        XCTAssertNil(VoiceExpenseParser.parse("taxi"))
        XCTAssertNil(VoiceExpenseParser.parse("0 euros on taxi"))
    }

    /// Empty/whitespace-only speech — a press that captured no recognizable audio at all — must
    /// never be treated as "an expense with an empty note"; it's simply nothing to act on.
    func testVoiceExpenseParserRejectsEmptyAndWhitespaceOnlyText() {
        XCTAssertNil(VoiceExpenseParser.parse(""))
        XCTAssertNil(VoiceExpenseParser.parse("   "))
        XCTAssertEqual(VoiceExpenseParser.parseAll(""), [])
        XCTAssertEqual(VoiceExpenseParser.parseAll("   "), [])
    }

    /// Recognized speech that isn't shaped like an expense at all (no leading amount) must fail
    /// to parse rather than guessing — this is the regression the "didn't catch an expense in
    /// that" feedback in `AddTransactionView`/`HomeView` exists to surface to the user.
    func testVoiceExpenseParserRejectsTextWithNoLeadingAmount() {
        XCTAssertNil(VoiceExpenseParser.parse("what's the weather today"))
        XCTAssertEqual(VoiceExpenseParser.parseAll("what's the weather today"), [])
    }

    // MARK: - Amount before or after the note

    func testVoiceExpenseParserAcceptsTheAmountAtTheEndOfThePhrase() {
        let result = VoiceExpenseParser.parse("taxi 20 euros")

        XCTAssertEqual(result?.amount, 20)
        XCTAssertEqual(result?.note, "taxi")
        XCTAssertEqual(result?.entryType, .expense)
    }

    func testVoiceExpenseParserAcceptsAVerbBeforeALeadingAmount() {
        let result = VoiceExpenseParser.parse("gasté 20 euros en taxi")

        XCTAssertEqual(result?.amount, 20)
        XCTAssertEqual(result?.note, "taxi")
        XCTAssertEqual(result?.entryType, .expense)
    }

    // MARK: - Spoken income

    func testVoiceExpenseParserRecognizesReceivedIncomeWithANote() {
        let result = VoiceExpenseParser.parse("recibí 1500 euros de nómina")

        XCTAssertEqual(result?.amount, 1500)
        XCTAssertEqual(result?.note, "nómina")
        XCTAssertEqual(result?.entryType, .income)
    }

    func testVoiceExpenseParserRecognizesCobreAsIncomeWithNoNote() {
        let result = VoiceExpenseParser.parse("cobré 500 euros")

        XCTAssertEqual(result?.amount, 500)
        XCTAssertEqual(result?.entryType, .income)
        XCTAssertEqual(result?.note, "Income")
    }

    func testVoiceExpenseParserRecognizesMeIngresaronAsIncome() {
        let result = VoiceExpenseParser.parse("me ingresaron 800 euros")

        XCTAssertEqual(result?.amount, 800)
        XCTAssertEqual(result?.entryType, .income)
    }

    func testVoiceExpenseParserPlainExpensePhraseStillDefaultsToExpense() {
        XCTAssertEqual(VoiceExpenseParser.parse("20 euros on taxi")?.entryType, .expense)
    }

    // MARK: - Note cleanup (Phase 7A) — verb detection after a leading date, new verbs, trailing connectors

    /// "Ayer pagué…" — a leading date word must not block the verb behind it from ever being
    /// recognized. Regression for the Phase 7 audit: previously the verb had to be the literal
    /// first token, so "pagué" was left in the note and the date was extracted separately.
    func testVoiceExpenseParserRecognizesAnExpenseVerbAfterALeadingDateWord() {
        let now = referenceDate(2026, 1, 7)
        let result = VoiceExpenseParser.parse("Ayer pagué 40 euros por cenar", referenceDate: now)

        XCTAssertEqual(result?.amount, 40)
        XCTAssertEqual(result?.note, "cenar")
        XCTAssertEqual(result?.entryType, .expense)
        XCTAssertEqual(result.map { self.day($0.date) }, 6, "the date word before the verb must still be recognized")
    }

    /// Same fix, "Hoy gasté…" — the other relative-day word tested in the audit.
    func testVoiceExpenseParserRecognizesAnExpenseVerbAfterHoy() {
        let now = referenceDate(2026, 1, 7)
        let result = VoiceExpenseParser.parse("Hoy gasté 20 en café", referenceDate: now)

        XCTAssertEqual(result?.amount, 20)
        XCTAssertEqual(result?.note, "café")
        XCTAssertEqual(result.map { self.day($0.date) }, 7)
    }

    /// "compré"/"compre" recognized as an expense verb, and no longer left polluting the note.
    func testVoiceExpenseParserRecognizesCompreAsAnExpenseVerb() {
        let result = VoiceExpenseParser.parse("compré 12 euros en pan")

        XCTAssertEqual(result?.amount, 12)
        XCTAssertEqual(result?.note, "pan")
        XCTAssertEqual(result?.entryType, .expense)
    }

    /// "costó"/"costo" recognized as an expense verb when it leads the clause.
    func testVoiceExpenseParserRecognizesCostoAsAnExpenseVerb() {
        let result = VoiceExpenseParser.parse("costó 120 euros el vuelo")

        XCTAssertEqual(result?.amount, 120)
        XCTAssertEqual(result?.note, "el vuelo")
        XCTAssertEqual(result?.entryType, .expense)
    }

    /// A trailing dangling connector left once an amount that trailed the note (with a connector
    /// in between) is removed — "Mercadona por 32 euros" must not leave "Mercadona por".
    func testVoiceExpenseParserStripsATrailingDanglingConnector() {
        let now = referenceDate(2026, 1, 7)
        let result = VoiceExpenseParser.parse("Hoy compré comida en Mercadona por 32 euros", referenceDate: now)

        XCTAssertEqual(result?.amount, 32)
        XCTAssertEqual(result?.note, "comida en Mercadona")
        XCTAssertEqual(result?.entryType, .expense)
        XCTAssertEqual(result.map { self.day($0.date) }, 7)
    }

    /// End-to-end version of the Mercadona/comida case from the Phase 7 audit: with the note now
    /// cleanly "comida en Mercadona" (rather than "compré comida en Mercadona por"), category
    /// resolution reaches Groceries deterministically via the strong "mercadona" signal, not by
    /// coincidentally surviving inside a noisy note.
    func testVoiceExpenseParserMercadonaPurchaseResolvesToGroceriesWithACleanNote() {
        let groceries = makeCategory("Groceries")
        let restaurants = makeCategory("Restaurants")
        let now = referenceDate(2026, 1, 7)

        let result = VoiceExpenseParser.parse("Hoy compré comida en Mercadona por 32 euros", referenceDate: now)

        XCTAssertEqual(result?.note, "comida en Mercadona")
        XCTAssertEqual(
            result.flatMap { VoiceExpenseParser.categoryMatch(for: $0.note, in: [restaurants, groceries]) }?.name,
            groceries.name
        )
    }

    /// Multi-clause version from the audit: each clause's verb is still stripped after splitting,
    /// even though the date word only appeared once at the very start of the whole phrase.
    func testVoiceExpenseParserParseAllStripsTheVerbFromEachClauseAfterALeadingDateWord() {
        let now = referenceDate(2026, 1, 7)
        let expenses = VoiceExpenseParser.parseAll("Ayer gasté 20 en café y hoy 35 en gasolina", referenceDate: now)

        XCTAssertEqual(expenses.map(\.amount), [20, 35])
        XCTAssertEqual(expenses.map(\.note), ["café", "gasolina"])
        XCTAssertEqual(expenses.map { self.day($0.date) }, [6, 7])
    }

    func testVoiceExpenseParserMatchesSalaryCategoryForIncomeNote() {
        let salary = makeCategory("Salary", isIncome: true)

        XCTAssertEqual(VoiceExpenseParser.categoryMatch(for: "nómina", in: [salary])?.name, salary.name)
    }

    // MARK: - parseAll with mixed income/expense clauses

    func testVoiceExpenseParserParseAllHandlesAnIncomeAndAnExpenseInOnePhrase() {
        let expenses = VoiceExpenseParser.parseAll("recibí 1500 euros de nómina y gasté 20 euros en taxi")

        XCTAssertEqual(expenses.map(\.entryType), [.income, .expense])
        XCTAssertEqual(expenses.map(\.amount), [1500, 20])
        XCTAssertEqual(expenses.map(\.note), ["nómina", "taxi"])
    }

    /// A single, non-multi phrase must produce exactly the same result through `parseAll` as
    /// through `parse` directly — the two code paths must never silently disagree.
    func testVoiceExpenseParserParseAllDegeneratesToParseForASingleExpense() {
        let expenses = VoiceExpenseParser.parseAll("20 euros on taxi")
        let single = VoiceExpenseParser.parse("20 euros on taxi")

        XCTAssertEqual(expenses.count, 1)
        // Compares everything but `date` (each call resolves its own `.now`, a handful of
        // microseconds apart) — `amount`/`note`/`categoryHint` must still agree exactly.
        XCTAssertEqual(expenses.first?.amount, single?.amount)
        XCTAssertEqual(expenses.first?.note, single?.note)
        XCTAssertEqual(expenses.first?.categoryHint, single?.categoryHint)
    }

    func testVoiceExpenseParserParseAllReturnsEmptyForUnparseableText() {
        XCTAssertEqual(VoiceExpenseParser.parseAll(""), [])
        XCTAssertEqual(VoiceExpenseParser.parseAll("taxi"), [])
    }

    /// Regression test: a category named "Training" (e.g. a gym/personal-development category)
    /// must never be matched by the transport hint's "train" candidate just because "training"
    /// contains those same characters — matching is whole-word, not a raw substring check. Uses
    /// the hint overload directly (not the note-string overload, which tries the separate,
    /// pre-existing `localCategoryMatch` heuristic first — out of scope for this fix).
    func testVoiceExpenseParserCategoryHintNeverMatchesAnUnrelatedCategoryBySubstring() {
        let training = makeCategory("Training")

        XCTAssertNil(VoiceExpenseParser.categoryMatch(for: .transport, in: [training]))
    }

    /// Same regression, exercised through the note-string overload's keyword-rule table (which
    /// maps "tren" — Spanish for train — to the categoryNames ["train", "public transit"] via
    /// `category(namedLike:)`). "tren" isn't a substring of "training" (or vice versa), so this
    /// specifically isolates the fixed whole-word matching from `localCategoryMatch`'s own,
    /// separate, pre-existing substring behavior.
    func testVoiceExpenseParserRuleTableNeverMatchesAnUnrelatedCategoryBySubstring() {
        let training = makeCategory("Training")

        XCTAssertNil(VoiceExpenseParser.categoryMatch(for: "tren", in: [training]))
    }

    /// Regression test: "Fast Food"/"Car Insurance" genuinely contain "food"/"car" as whole
    /// words, so no substring-vs-whole-word distinction can save them — the fix is that the
    /// hint's own candidate list no longer includes such overly generic single words at all.
    func testVoiceExpenseParserCategoryHintDoesNotFallBackToOverlyGenericWords() {
        let fastFood = makeCategory("Fast Food")
        let carInsurance = makeCategory("Car Insurance")

        XCTAssertNil(VoiceExpenseParser.categoryMatch(for: .groceries, in: [fastFood]))
        XCTAssertNil(VoiceExpenseParser.categoryMatch(for: .transport, in: [carInsurance]))
    }

    /// A specific, unambiguous candidate ("groceries"/"taxi") must still match a category whose
    /// name is exactly that word, or contains it as one of its own whole words.
    func testVoiceExpenseParserCategoryHintStillMatchesSpecificWholeWordCandidates() {
        let groceries = makeCategory("Home Groceries")
        let taxi = makeCategory("Taxi")

        XCTAssertEqual(VoiceExpenseParser.categoryMatch(for: .groceries, in: [groceries])?.name, groceries.name)
        XCTAssertEqual(VoiceExpenseParser.categoryMatch(for: .transport, in: [taxi])?.name, taxi.name)
    }

    // MARK: - localCategoryMatch (deterministic, offline)

    private func makeCategory(_ name: String, isIncome: Bool = false, isArchived: Bool = false) -> FinanceTracker.Category {
        let head = TestSupport.makeHeadCategory(name: "Head")
        return TestSupport.makeCategory(name: name, isIncome: isIncome, isArchived: isArchived, headCategory: head)
    }

    func testLocalCategoryMatchFindsExactCaseInsensitiveName() {
        let rent = makeCategory("Rent")
        let groceries = makeCategory("Groceries")

        let result = CategorizationService.localCategoryMatch(for: "rent", in: [rent, groceries])

        XCTAssertEqual(result?.name, rent.name)
    }

    func testLocalCategoryMatchFindsCategoryNameAsSubstringOfNote() {
        let restaurants = makeCategory("Restaurants")

        let result = CategorizationService.localCategoryMatch(for: "Dinner at a nice restaurants downtown", in: [restaurants])

        XCTAssertEqual(result?.name, restaurants.name)
    }

    func testLocalCategoryMatchFindsShortNoteInsideLongerCategoryName() {
        let gym = makeCategory("Gym Membership")

        let result = CategorizationService.localCategoryMatch(for: "Gym", in: [gym])

        XCTAssertEqual(result?.name, gym.name)
    }

    func testLocalCategoryMatchPrefersLongestMatchingCategoryName() {
        let food = makeCategory("Food")
        let fastFood = makeCategory("Fast Food")

        let result = CategorizationService.localCategoryMatch(for: "Fast Food delivery", in: [food, fastFood])

        XCTAssertEqual(result?.name, fastFood.name, "the more specific, longer-named category should win over a shorter coincidental match")
    }

    func testLocalCategoryMatchReturnsNilWhenNothingMatches() {
        let rent = makeCategory("Rent")

        let result = CategorizationService.localCategoryMatch(for: "random unrelated text", in: [rent])

        XCTAssertNil(result)
    }

    func testLocalCategoryMatchReturnsNilForEmptyNote() {
        let rent = makeCategory("Rent")
        XCTAssertNil(CategorizationService.localCategoryMatch(for: "   ", in: [rent]))
    }

    func testLocalCategoryMatchReturnsNilForEmptyCategoryList() {
        XCTAssertNil(CategorizationService.localCategoryMatch(for: "rent", in: []))
    }

    func testLocalCategoryMatchNeverInventsACategoryOutsideTheProvidedList() {
        let rent = makeCategory("Rent")
        let result = CategorizationService.localCategoryMatch(for: "completely unrelated to rent or anything else", in: [rent])
        // Either nil, or one of the categories actually passed in — never a fabricated result.
        XCTAssertTrue(result == nil || result === rent)
    }

    // MARK: - suggestCategory uses the local match before requiring an API key

    func testSuggestCategoryReturnsLocalMatchWithoutNetworkOrAPIKey() async {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory(name: "Housing")
        let rent = TestSupport.makeCategory(name: "Rent", headCategory: head)
        context.insert(head); context.insert(rent)
        try? context.save()

        let previousContext = CategorizationService.modelContext
        CategorizationService.modelContext = context
        defer { CategorizationService.modelContext = previousContext }

        // This test target has no real ANTHROPIC_API_KEY configured, so this can only pass if
        // the category resolved via the local/offline match — the AI branch would return nil
        // (no `apiKey`) rather than throw, but it would never produce this specific category.
        let result = await CategorizationService.suggestCategory(for: "Rent payment")

        XCTAssertEqual(result?.name, rent.name)
    }

    // MARK: - Empty text

    func testSuggestCategoryReturnsNilForEmptyText() async {
        let result = await CategorizationService.suggestCategory(for: "")
        XCTAssertNil(result)
    }

    func testSuggestCategoryReturnsNilForWhitespaceOnlyText() async {
        let result = await CategorizationService.suggestCategory(for: "   \n  ")
        XCTAssertNil(result)
    }

    func testExtractTransactionReturnsNilForEmptyText() async {
        let result = await CategorizationService.extractTransaction(from: "")
        XCTAssertNil(result)
    }

    // MARK: - Malformed JSON (parseExtraction)

    func testParseExtractionReturnsNilForPlainText() {
        XCTAssertNil(CategorizationService.parseExtraction("not json at all"))
    }

    func testParseExtractionReturnsNilForTruncatedJSON() {
        XCTAssertNil(CategorizationService.parseExtraction("{\"amount\": 12.5, \"note\": \"Coffee\""))
    }

    func testParseExtractionReturnsNilWhenAmountMissing() {
        XCTAssertNil(CategorizationService.parseExtraction("{\"note\": \"Coffee\", \"category\": null}"))
    }

    func testParseExtractionReturnsNilForNonPositiveAmount() {
        XCTAssertNil(CategorizationService.parseExtraction("{\"amount\": 0, \"note\": \"Coffee\"}"))
        XCTAssertNil(CategorizationService.parseExtraction("{\"amount\": -5, \"note\": \"Coffee\"}"))
    }

    func testParseExtractionSucceedsForWellFormedJSON() {
        let result = CategorizationService.parseExtraction("{\"amount\": 12.5, \"note\": \"Coffee\", \"category\": \"Dining\"}")
        XCTAssertEqual(result?.amount, 12.5)
        XCTAssertEqual(result?.note, "Coffee")
        XCTAssertEqual(result?.categoryName, "Dining")
    }

    // MARK: - Placeholder API key

    func testSanitizedAPIKeyReturnsNilForPlaceholder() {
        XCTAssertNil(CategorizationService.sanitizedAPIKey(from: "INSERT_YOUR_ANTHROPIC_API_KEY_HERE"))
    }

    func testSanitizedAPIKeyReturnsNilForEmptyOrMissing() {
        XCTAssertNil(CategorizationService.sanitizedAPIKey(from: ""))
        XCTAssertNil(CategorizationService.sanitizedAPIKey(from: "   "))
        XCTAssertNil(CategorizationService.sanitizedAPIKey(from: nil))
    }

    func testSanitizedAPIKeyReturnsTrimmedRealKey() {
        XCTAssertEqual(CategorizationService.sanitizedAPIKey(from: "  sk-real-key  "), "sk-real-key")
    }
}
