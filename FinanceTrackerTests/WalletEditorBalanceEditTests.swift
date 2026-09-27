import XCTest
@testable import FinanceTracker

/// Regression coverage for the "brand-new wallet's balance gets logged as a fake transaction"
/// bug: editing a wallet with no real transaction history must set `startingBalance` directly,
/// never insert a "Balance adjustment" `Entry` — that behavior is reserved for a wallet that
/// already has real activity behind it, where a manual correction should be auditable.
final class WalletEditorBalanceEditTests: XCTestCase {
    // MARK: No real history yet — always sets startingBalance directly, never an Entry

    func testANewlyCreatedWalletWithNoHistorySetsStartingBalanceDirectly() {
        let outcome = WalletEditorView.resolveBalanceEdit(desiredBalance: -3000, currentBalance: 0, hasRealHistory: false)
        XCTAssertEqual(outcome, .setStartingBalanceDirectly(-3000))
    }

    /// The exact scenario reported: a credit card wallet created with balance 0, then edited to
    /// -3000 before any real transaction ever touched it — must never produce a "Balance
    /// adjustment" Entry, regardless of how large or negative the typed balance is.
    func testSettingANegativeStartingBalanceOnAHistorylessWalletNeverLogsAnEntry() {
        let outcome = WalletEditorView.resolveBalanceEdit(desiredBalance: -3000, currentBalance: 0, hasRealHistory: false)
        guard case .setStartingBalanceDirectly = outcome else {
            return XCTFail("must set startingBalance directly, never log an adjustment: \(outcome)")
        }
    }

    /// The second half of the reported scenario: editing that same historyless wallet's balance
    /// again (e.g. -3000 -> +3000) must still set `startingBalance` directly — never compute a
    /// delta-based adjustment Entry (which is what previously produced the spurious "+6000"
    /// income entry the user saw).
    func testEditingAHistorylessWalletsBalanceAgainStillSetsStartingBalanceDirectlyNotADelta() {
        let outcome = WalletEditorView.resolveBalanceEdit(desiredBalance: 3000, currentBalance: -3000, hasRealHistory: false)
        XCTAssertEqual(outcome, .setStartingBalanceDirectly(3000), "must be the plain typed value, never a computed delta (which would be 6000)")
    }

    func testHistorylessWalletWithUnchangedBalanceStillSetsStartingBalanceDirectly() {
        // Even a no-op edit (typed value equals current) goes through the direct-assignment path
        // for a historyless wallet — there's no delta concept to short-circuit on here, since
        // there's nothing to compare against that would ever produce an Entry regardless.
        let outcome = WalletEditorView.resolveBalanceEdit(desiredBalance: 500, currentBalance: 500, hasRealHistory: false)
        XCTAssertEqual(outcome, .setStartingBalanceDirectly(500))
    }

    // MARK: Real history present — logs an auditable adjustment Entry instead

    func testAWalletWithRealHistoryLogsAnIncomeAdjustmentWhenBalanceIncreases() {
        let outcome = WalletEditorView.resolveBalanceEdit(desiredBalance: 500, currentBalance: 300, hasRealHistory: true)
        XCTAssertEqual(outcome, .logAdjustmentEntry(amount: 200, type: .income))
    }

    func testAWalletWithRealHistoryLogsAnExpenseAdjustmentWhenBalanceDecreases() {
        let outcome = WalletEditorView.resolveBalanceEdit(desiredBalance: 100, currentBalance: 300, hasRealHistory: true)
        XCTAssertEqual(outcome, .logAdjustmentEntry(amount: 200, type: .expense))
    }

    func testAWalletWithRealHistoryAndNoActualBalanceChangeLogsNothing() {
        let outcome = WalletEditorView.resolveBalanceEdit(desiredBalance: 300, currentBalance: 300, hasRealHistory: true)
        XCTAssertEqual(outcome, .noChange)
    }

    /// The adjustment amount is always the magnitude of the delta, never negative — `Entry.amount`
    /// is a plain positive magnitude, with sign conveyed entirely by `type`.
    func testAdjustmentAmountIsAlwaysAPositiveMagnitude() {
        let decreaseOutcome = WalletEditorView.resolveBalanceEdit(desiredBalance: -3000, currentBalance: 3000, hasRealHistory: true)
        guard case .logAdjustmentEntry(let amount, let type) = decreaseOutcome else {
            return XCTFail("expected a logged adjustment: \(decreaseOutcome)")
        }
        XCTAssertEqual(amount, 6000)
        XCTAssertEqual(type, .expense)
        XCTAssertGreaterThan(amount, 0)
    }
}
