import XCTest
@testable import FinanceTracker

final class CategorizationServiceTests: XCTestCase {

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
