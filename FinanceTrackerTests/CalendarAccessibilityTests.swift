import XCTest
@testable import FinanceTracker

/// Focused tests for `CalendarView.dayAccessibilityLabel` — the pure, presentation-only helper
/// added in Phase 2E to give each Calendar day cell a combined VoiceOver label. See
/// `CLARITY_OVERVIEW_ACTIVITY_UX_SPEC.md` §8/§14/§16.
///
/// Date/currency text is computed via the same formatting calls the label itself uses, rather
/// than hardcoded — both are locale-dependent (confirmed: the test environment's locale renders
/// "16 September", not "September 16"), so hardcoding one particular ordering would make these
/// tests locale-fragile without actually testing `dayAccessibilityLabel`'s own logic.
///
/// `CalendarView.dailyTotals`/`.monthEntries` themselves are not covered here: they're `@Query`-
/// backed computed properties on the view struct, requiring a live SwiftUI/SwiftData environment
/// to resolve, and this phase does not restructure that (out of scope — see the Phase 2E report's
/// Tests section for why cross-surface semantics 7-9 are verified by code inspection instead).
final class CalendarAccessibilityTests: XCTestCase {
    private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).day())
    }

    func testEmptyDayProducesNoActivityLabel() {
        let day = testDate(2026, 9, 16)
        let label = CalendarView.dayAccessibilityLabel(for: day, net: nil)
        XCTAssertEqual(label, "\(dateText(day)), no activity")
    }

    func testPositiveNetProducesNetIncomeLabel() {
        let day = testDate(2026, 9, 14)
        let net: Decimal = 123
        let label = CalendarView.dayAccessibilityLabel(for: day, net: net)
        XCTAssertEqual(label, "\(dateText(day)), net income \(net.currencyFormatted)")
        XCTAssertFalse(label.contains("expense"))
        XCTAssertFalse(label.contains("no activity"))
    }

    func testNegativeNetProducesNetExpenseLabel() {
        let day = testDate(2026, 9, 15)
        let net: Decimal = -45
        let label = CalendarView.dayAccessibilityLabel(for: day, net: net)
        XCTAssertEqual(label, "\(dateText(day)), net expense \(Decimal(45).currencyFormatted)")
        XCTAssertFalse(label.contains("income"))
        // The spoken amount must be positive magnitude ("expense 45", not "expense -45") —
        // the word "expense" already carries the sign.
        XCTAssertFalse(label.contains("-"))
    }

    func testZeroNetWithActivityIsDistinguishedFromNoActivity() {
        let day = testDate(2026, 9, 17)
        let zeroNetWithActivity = CalendarView.dayAccessibilityLabel(for: day, net: 0)
        let noActivity = CalendarView.dayAccessibilityLabel(for: day, net: nil)

        XCTAssertEqual(zeroNetWithActivity, "\(dateText(day)), activity, net zero")
        XCTAssertNotEqual(zeroNetWithActivity, noActivity)
        XCTAssertTrue(zeroNetWithActivity.contains("activity"))
        XCTAssertFalse(noActivity.contains("net zero"))
    }

    func testLabelIncludesTheCorrectDate() {
        let day = testDate(2026, 1, 3)
        let label = CalendarView.dayAccessibilityLabel(for: day, net: 10)
        XCTAssertTrue(label.hasPrefix(dateText(day)))
    }

    /// The four financial states (no activity / net zero / net income / net expense) must be
    /// distinguishable from the label text alone — i.e. the meaning must not depend on the
    /// day cell's color tint, which VoiceOver never announces.
    func testFinancialMeaningIsCarriedByWordsNotColor() {
        let day = testDate(2026, 9, 20)
        let labels = [
            CalendarView.dayAccessibilityLabel(for: day, net: nil),
            CalendarView.dayAccessibilityLabel(for: day, net: 0),
            CalendarView.dayAccessibilityLabel(for: day, net: 30),
            CalendarView.dayAccessibilityLabel(for: day, net: -30)
        ]

        // All four are unique strings, each carrying its own meaning in words.
        XCTAssertEqual(Set(labels).count, labels.count)
        XCTAssertTrue(labels[0].contains("no activity"))
        XCTAssertTrue(labels[1].contains("activity, net zero"))
        XCTAssertTrue(labels[2].contains("net income"))
        XCTAssertTrue(labels[3].contains("net expense"))
    }

    // MARK: - hasOffsettingActivity (Phase 2J — zero-net-day visual indicator)

    func testHasOffsettingActivityIsFalseForNoActivity() {
        XCTAssertFalse(CalendarView.hasOffsettingActivity(net: nil))
    }

    func testHasOffsettingActivityIsTrueForZeroNet() {
        XCTAssertTrue(CalendarView.hasOffsettingActivity(net: 0))
    }

    func testHasOffsettingActivityIsFalseForNonZeroNet() {
        XCTAssertFalse(CalendarView.hasOffsettingActivity(net: 30))
        XCTAssertFalse(CalendarView.hasOffsettingActivity(net: -30))
    }
}
