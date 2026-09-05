import XCTest
@testable import FinanceTracker

final class IntentWalletResolutionTests: XCTestCase {

    // MARK: - LogExpenseIntent

    func testLogExpenseIntentExcludesArchivedWallets() {
        let archived = TestSupport.makeWallet(name: "Old", isArchived: true)
        let active = TestSupport.makeWallet(name: "Active")

        let resolved = LogExpenseIntent.resolveWallet(named: "Old", from: [archived, active])
        // The requested wallet is archived, so it falls back instead of being returned.
        XCTAssertEqual(resolved?.name, "Active")
    }

    func testLogExpenseIntentPrefersRequestedActiveWalletByName() {
        let defaultWallet = TestSupport.makeWallet(name: "Default", isDefault: true)
        let requested = TestSupport.makeWallet(name: "Vacation")

        let resolved = LogExpenseIntent.resolveWallet(named: "Vacation", from: [defaultWallet, requested])
        XCTAssertEqual(resolved?.name, "Vacation")
    }

    func testLogExpenseIntentFallsBackToDefaultWalletWhenNoneRequested() {
        let first = TestSupport.makeWallet(name: "First")
        let defaultWallet = TestSupport.makeWallet(name: "Default", isDefault: true)

        let resolved = LogExpenseIntent.resolveWallet(named: nil, from: [first, defaultWallet])
        XCTAssertEqual(resolved?.name, "Default")
    }

    func testLogExpenseIntentReturnsNilWhenAllWalletsArchived() {
        let archived = TestSupport.makeWallet(name: "Old", isArchived: true)
        XCTAssertNil(LogExpenseIntent.resolveWallet(named: nil, from: [archived]))
    }

    // MARK: - TransactionFromTextIntent

    func testTransactionFromTextIntentExcludesArchivedWallets() {
        let archivedDefault = TestSupport.makeWallet(name: "Old", isDefault: true, isArchived: true)
        let active = TestSupport.makeWallet(name: "Active")

        let resolved = TransactionFromTextIntent.resolveFallbackWallet(from: [archivedDefault, active])
        XCTAssertEqual(resolved?.name, "Active")
    }

    func testTransactionFromTextIntentPrefersDefaultWallet() {
        let first = TestSupport.makeWallet(name: "First")
        let defaultWallet = TestSupport.makeWallet(name: "Default", isDefault: true)

        let resolved = TransactionFromTextIntent.resolveFallbackWallet(from: [first, defaultWallet])
        XCTAssertEqual(resolved?.name, "Default")
    }

    func testTransactionFromTextIntentReturnsNilWhenNoActiveWallets() {
        let archived = TestSupport.makeWallet(name: "Old", isArchived: true)
        XCTAssertNil(TransactionFromTextIntent.resolveFallbackWallet(from: [archived]))
    }

    // MARK: - WalletEntityQuery

    func testWalletEntityQueryExcludesArchivedWallets() {
        let archived = TestSupport.makeWallet(name: "Old", isArchived: true)
        let active = TestSupport.makeWallet(name: "Active")

        let entities = WalletEntityQuery.makeEntities(from: [archived, active])
        XCTAssertEqual(entities.map(\.name), ["Active"])
    }

    func testWalletEntityQueryIncludesAllActiveWalletsRegardlessOfDefault() {
        let defaultWallet = TestSupport.makeWallet(name: "Default", isDefault: true)
        let other = TestSupport.makeWallet(name: "Other")

        let entities = WalletEntityQuery.makeEntities(from: [defaultWallet, other])
        XCTAssertEqual(Set(entities.map(\.name)), Set(["Default", "Other"]))
    }
}
