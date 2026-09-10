import XCTest
@testable import FinanceTracker

/// Focused tests for `BudgetSettingsStore.readManualMonthlyBudget(from:)` (Phase 2N-G) — proves
/// representative `Decimal` values survive persist/reload without the precision loss the previous
/// `Decimal → Double → Decimal` round trip risked. Exercises the real read path against an
/// isolated, throwaway `UserDefaults` suite (never the live App-Group-backed singleton), writing
/// values the same way `manualMonthlyBudget`'s `didSet` does (`"\(decimal)"`) rather than
/// constructing the live `BudgetSettingsStore.shared` and risking cross-test state leakage.
final class BudgetSettingsPersistenceTests: XCTestCase {
    /// Must match `BudgetSettingsStore.Keys.manualMonthlyBudget` (private, so duplicated here by
    /// necessity) — a mismatch would make every test below fail loudly (`readManualMonthlyBudget`
    /// falling through to its `0`-default path), not silently pass, so this duplication is safe.
    private let key = "budgetManualMonthlyBudget"
    private let suiteName = "BudgetSettingsPersistenceTests"

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func roundTrip(_ value: Decimal) -> Decimal {
        defaults.set("\(value)", forKey: key)
        return BudgetSettingsStore.readManualMonthlyBudget(from: defaults)
    }

    func testWholeNumberSurvivesRoundTrip() {
        XCTAssertEqual(roundTrip(1500), 1500)
    }

    func testTwoDecimalPlacesSurviveRoundTrip() {
        XCTAssertEqual(roundTrip(Decimal(string: "1234.56")!), Decimal(string: "1234.56")!)
    }

    /// The exact shape of value that previously risked precision loss through a `Double`
    /// intermediate (the same class of value already found to fail for Goals' contribution sums).
    func testValuesPronetoFloatingPointRoundingSurviveExactly() {
        let value = Decimal(string: "33.33")! + Decimal(string: "33.33")! + Decimal(string: "33.34")!
        XCTAssertEqual(roundTrip(value), Decimal(string: "100.00")!)
    }

    func testZeroSurvivesRoundTrip() {
        XCTAssertEqual(roundTrip(0), 0)
    }

    func testLargeValueSurvivesRoundTrip() {
        XCTAssertEqual(roundTrip(Decimal(string: "987654.32")!), Decimal(string: "987654.32")!)
    }

    /// Absent key (never set) must still yield `0` — the existing "0 = no manual override"
    /// semantics, unchanged by this fix.
    func testAbsentKeyDefaultsToZero() {
        XCTAssertEqual(BudgetSettingsStore.readManualMonthlyBudget(from: defaults), 0)
    }

    /// Backward compatibility: a value saved by the previous `Double`-based format (before this
    /// fix shipped) must still be read correctly, not silently reset to 0.
    func testLegacyDoubleEncodedValueIsStillReadCorrectly() {
        defaults.set(1500.0, forKey: key)
        XCTAssertEqual(BudgetSettingsStore.readManualMonthlyBudget(from: defaults), 1500)
    }
}
