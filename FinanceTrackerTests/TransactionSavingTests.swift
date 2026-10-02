import XCTest
import SwiftData
@testable import FinanceTracker

/// Covers `TransactionSaving.createEntry` — the single, shared entry-construction path
/// `AddTransactionView.save()` and Home's voice-expense batch review (`VoiceExpenseBatchReviewView
/// .save()`) both now use, added so voice input no longer maintains a second, parallel save
/// implementation. See `Models/Entry.swift`.
final class TransactionSavingTests: XCTestCase {
    private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testCreateEntryInsertsANewEntryWithTheGivenFields() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        context.insert(wallet); context.insert(head); context.insert(category)

        let entry = TransactionSaving.createEntry(
            amount: 42, date: testDate(2025, 6, 10), note: "Taxi", type: .expense,
            category: category, wallet: wallet, modelContext: context
        )

        XCTAssertEqual(entry.amount, 42)
        XCTAssertEqual(entry.note, "Taxi")
        XCTAssertEqual(entry.type, .expense)
        XCTAssertTrue(entry.category === category)
        XCTAssertTrue(entry.wallet === wallet)

        let fetched = try? context.fetch(FetchDescriptor<Entry>())
        XCTAssertEqual(fetched?.count, 1, "the entry must actually be inserted into the context, not merely constructed")
    }

    /// Mirrors the voice flow's real shape: a merchant `VoiceExpenseParser.categoryMatch` didn't
    /// recognize still produces a perfectly valid, savable expense — matching the app's existing
    /// `LogExpenseIntent` precedent of never blocking a save on a missing category.
    func testCreateEntryAllowsANilCategory() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)

        let entry = TransactionSaving.createEntry(
            amount: 15, note: "Unknown merchant", type: .expense, category: nil, wallet: wallet, modelContext: context
        )

        XCTAssertNil(entry.category)
    }

    func testCreateEntryNeverAssignsACategoryToATransfer() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Food")
        let category = TestSupport.makeCategory(name: "Dining", headCategory: head)
        context.insert(wallet); context.insert(head); context.insert(category)

        let entry = TransactionSaving.createEntry(
            amount: 100, type: .transfer, category: category, wallet: wallet, modelContext: context
        )

        XCTAssertNil(entry.category, "a transfer must never carry a category, even if one is passed in")
    }

    /// The exact shape `VoiceExpenseBatchReviewView.save()` uses: several `createEntry` calls
    /// (one per spoken expense) followed by a single `modelContext.save()` for the whole batch —
    /// the regression this guards is the batch view silently reverting to its own, divergent
    /// insert logic instead of this shared helper.
    func testCreateEntrySupportsSavingSeveralEntriesInOneBatch() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)

        for amount: Decimal in [20, 35, 25] {
            TransactionSaving.createEntry(amount: amount, note: "Voice expense", type: .expense, category: nil, wallet: wallet, modelContext: context)
        }
        XCTAssertNoThrow(try context.save())

        let fetched = try? context.fetch(FetchDescriptor<Entry>())
        XCTAssertEqual(fetched?.count, 3)
        XCTAssertEqual(Set(fetched?.map(\.amount) ?? []), [20, 35, 25])
    }
}
