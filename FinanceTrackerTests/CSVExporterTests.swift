import XCTest
@testable import FinanceTracker

final class CSVExporterTests: XCTestCase {

    private func makeEntry(note: String, amount: Decimal = 12.5) -> Entry {
        let wallet = TestSupport.makeWallet(name: "Cash")
        return Entry(amount: amount, date: .now, note: note, type: .expense, wallet: wallet)
    }

    func testEscapesCommaInNote() {
        let csv = CSVExporter.makeCSV(entries: [makeEntry(note: "Coffee, tea")])
        let dataLine = csv.split(separator: "\n").last!
        XCTAssertTrue(dataLine.contains("\"Coffee, tea\""))
    }

    func testEscapesQuotesInNote() {
        let csv = CSVExporter.makeCSV(entries: [makeEntry(note: "12\" pizza")])
        let dataLine = csv.split(separator: "\n").last!
        // A literal quote is escaped by doubling, and the whole field is wrapped in quotes.
        XCTAssertTrue(dataLine.contains("\"12\"\" pizza\""))
    }

    func testEscapesNewlineInNote() {
        let csv = CSVExporter.makeCSV(entries: [makeEntry(note: "Line one\nLine two")])
        // The note's embedded newline must be quoted so it isn't mistaken for a row break,
        // and it must be the final (quoted) field on the data row.
        XCTAssertTrue(csv.hasSuffix("\"Line one\nLine two\""))
    }

    func testFieldWithoutSpecialCharactersIsNotQuoted() {
        let csv = CSVExporter.makeCSV(entries: [makeEntry(note: "Groceries")])
        let dataLine = csv.split(separator: "\n").last!
        XCTAssertTrue(dataLine.contains(",Groceries"))
        XCTAssertFalse(dataLine.contains("\"Groceries\""))
    }

    func testEscapesCommaAndQuoteTogether() {
        let csv = CSVExporter.makeCSV(entries: [makeEntry(note: "\"Best\", ever")])
        let dataLine = csv.split(separator: "\n").last!
        XCTAssertTrue(dataLine.contains("\"\"\"Best\"\", ever\""))
    }
}
