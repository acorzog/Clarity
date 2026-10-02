import XCTest
import SwiftData
@testable import FinanceTracker

/// Covers `VoiceQuickSave.save` — the immediate, no-review-step save path both `HomeView`'s
/// floating mic and `AddTransactionView`'s inline mic use. The core regression this guards: a
/// multi-clause phrase like "20 en taxi y 35 en gasolina" used to only ever fill a form with the
/// *first* clause (`AddTransactionView`) or require an explicit confirm tap (`HomeView`'s old
/// batch review) — this must save every clause, immediately, with no entry silently dropped.
final class VoiceQuickSaveTests: XCTestCase {
    private func makeExpense(
        amount: Decimal, note: String, entryType: EntryType = .expense, date: Date = .now
    ) -> ParsedVoiceExpense {
        ParsedVoiceExpense(amount: amount, note: note, date: date, categoryHint: nil, entryType: entryType)
    }

    func testSavesASingleExpenseImmediately() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)

        let entries = VoiceQuickSave.save(
            [makeExpense(amount: 20, note: "taxi")], wallet: wallet, categories: [], modelContext: context
        )

        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual(entries?.first?.amount, 20)
        XCTAssertEqual(entries?.first?.note, "taxi")
        XCTAssertTrue(entries?.first?.wallet === wallet)

        let fetched = try? context.fetch(FetchDescriptor<Entry>())
        XCTAssertEqual(fetched?.count, 1, "the entry must actually be persisted, not merely constructed")
    }

    /// The exact multi-entry regression from the Phase 7 audit and the follow-up bug report:
    /// every clause in a multi-expense phrase must be saved, not just the first.
    func testSavesEveryEntryInAMultiClausePhraseNoneDropped() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)

        let expenses = [
            makeExpense(amount: 15, note: "beers"),
            makeExpense(amount: 5, note: "supermarket")
        ]
        let entries = VoiceQuickSave.save(expenses, wallet: wallet, categories: [], modelContext: context)

        XCTAssertEqual(entries?.count, 2)
        XCTAssertEqual(Set(entries?.map(\.amount) ?? []), [15, 5])
        XCTAssertEqual(Set(entries?.map(\.note) ?? []), ["beers", "supermarket"])

        let fetched = try? context.fetch(FetchDescriptor<Entry>())
        XCTAssertEqual(fetched?.count, 2, "both entries must be persisted, not just the first")
    }

    func testMatchesAnExistingCategoryPerExpense() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Transport")
        let taxi = TestSupport.makeCategory(name: "Taxi", headCategory: head)
        context.insert(wallet); context.insert(head); context.insert(taxi)

        let entries = VoiceQuickSave.save(
            [makeExpense(amount: 20, note: "taxi")], wallet: wallet, categories: [taxi], modelContext: context
        )

        XCTAssertTrue(entries?.first?.category === taxi)
    }

    /// Never invents a category — a note with no matching rule still saves, just uncategorized,
    /// so it stays easy to spot and fix from Entries afterward (mirrors the old batch-review
    /// screen's same "no matching category" behavior).
    func testLeavesCategoryNilWhenNothingMatchesRatherThanGuessing() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Transport")
        let taxi = TestSupport.makeCategory(name: "Taxi", headCategory: head)
        context.insert(wallet); context.insert(head); context.insert(taxi)

        let entries = VoiceQuickSave.save(
            [makeExpense(amount: 15, note: "beers")], wallet: wallet, categories: [taxi], modelContext: context
        )

        XCTAssertNotNil(entries)
        XCTAssertNil(entries?.first?.category)
    }

    /// Income and expense categories are kept separate — an income-shaped expense must only ever
    /// match against income categories, never an expense one that happens to share wording.
    func testMatchesIncomeCategoryOnlyForIncomeEntries() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        let head = TestSupport.makeHeadCategory(name: "Income")
        let salary = TestSupport.makeCategory(name: "Salary", isIncome: true, headCategory: head)
        context.insert(wallet); context.insert(head); context.insert(salary)

        let entries = VoiceQuickSave.save(
            [makeExpense(amount: 1500, note: "nómina", entryType: .income)],
            wallet: wallet, categories: [salary], modelContext: context
        )

        XCTAssertEqual(entries?.first?.type, .income)
        XCTAssertTrue(entries?.first?.category === salary)
    }

    func testReturnsNilWhenThereIsNoWalletToSaveInto() {
        let context = TestSupport.makeInMemoryContext()

        let entries = VoiceQuickSave.save(
            [makeExpense(amount: 20, note: "taxi")], wallet: nil, categories: [], modelContext: context
        )

        XCTAssertNil(entries)
        let fetched = try? context.fetch(FetchDescriptor<Entry>())
        XCTAssertEqual(fetched?.count, 0, "nothing should be persisted when there's no wallet")
    }

    func testReturnsNilForAnEmptyExpenseList() {
        let context = TestSupport.makeInMemoryContext()
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)

        XCTAssertNil(VoiceQuickSave.save([], wallet: wallet, categories: [], modelContext: context))
    }
}
