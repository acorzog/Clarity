import XCTest
@testable import FinanceTracker

/// Focused tests for `CalendarView.dayAccessibilityLabel` — the pure, presentation-only helper
/// giving each Money Calendar day cell a combined VoiceOver label based on that day's spending.
///
/// Date/currency text is computed via the same formatting calls the label itself uses, rather
/// than hardcoded — both are locale-dependent (confirmed: the test environment's locale renders
/// "16 September", not "September 16"), so hardcoding one particular ordering would make these
/// tests locale-fragile without actually testing `dayAccessibilityLabel`'s own logic.
///
/// `CalendarView.dailySpending`/`.monthEntries` themselves are not covered here: they're `@Query`-
/// backed computed properties on the view struct, requiring a live SwiftUI/SwiftData environment
/// to resolve — the budget-eligible/expense-only filtering they apply is exercised instead via
/// `EntryQuerying`/`BudgetEligibility`'s own existing tests, which this view reuses verbatim.
final class CalendarAccessibilityTests: XCTestCase {
    private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).day())
    }

    func testNoSpendingProducesNoSpendingLabelWhenNil() {
        let day = testDate(2026, 9, 16)
        let label = CalendarView.dayAccessibilityLabel(for: day, spent: nil)
        XCTAssertEqual(label, "\(dateText(day)), no spending")
    }

    func testNoSpendingProducesNoSpendingLabelWhenZero() {
        // `dailySpending` never actually stores a literal `0` (it omits the day entirely), but
        // the label helper is defensive about it regardless — a day passed `0` must read
        // identically to a day passed `nil`.
        let day = testDate(2026, 9, 16)
        XCTAssertEqual(
            CalendarView.dayAccessibilityLabel(for: day, spent: 0),
            CalendarView.dayAccessibilityLabel(for: day, spent: nil)
        )
    }

    func testPositiveSpendingProducesSpentLabelWithMagnitudeOnly() {
        let day = testDate(2026, 9, 15)
        let spent: Decimal = 45
        let label = CalendarView.dayAccessibilityLabel(for: day, spent: spent)
        XCTAssertEqual(label, "\(dateText(day)), \(spent.currencyFormatted) spent")
        XCTAssertFalse(label.contains("no spending"))
        // Spending is always a positive magnitude in this view — never a signed/negative amount.
        XCTAssertFalse(label.contains("-"))
    }

    func testLabelIncludesTheCorrectDate() {
        let day = testDate(2026, 1, 3)
        let label = CalendarView.dayAccessibilityLabel(for: day, spent: 10)
        XCTAssertTrue(label.hasPrefix(dateText(day)))
    }

    /// The smallest possible positive spend must still read as "spent," not "no spending" — the
    /// `spent > 0` guard is a strict inequality, so this pins the exact boundary rather than just
    /// a comfortably-positive amount like the other tests here.
    func testSmallestPositiveSpendingStillProducesSpentLabel() {
        let day = testDate(2026, 9, 15)
        let label = CalendarView.dayAccessibilityLabel(for: day, spent: 0.01)
        XCTAssertFalse(label.contains("no spending"))
        XCTAssertTrue(label.contains("spent"))
    }

    /// Both states (no spending / spent an amount) must be distinguishable from the label text
    /// alone — i.e. the meaning must not depend on the day cell's color tint, which VoiceOver
    /// never announces.
    func testSpendingStateIsCarriedByWordsNotColor() {
        let day = testDate(2026, 9, 20)
        let noSpending = CalendarView.dayAccessibilityLabel(for: day, spent: nil)
        let spent = CalendarView.dayAccessibilityLabel(for: day, spent: 30)

        XCTAssertNotEqual(noSpending, spent)
        XCTAssertTrue(noSpending.contains("no spending"))
        XCTAssertTrue(spent.contains("spent"))
    }
}
