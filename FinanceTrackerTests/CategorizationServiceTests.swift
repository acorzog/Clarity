import XCTest
@testable import FinanceTracker

final class CategorizationServiceTests: XCTestCase {

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
