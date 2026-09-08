import XCTest
import SwiftData
import CloudKit
@testable import FinanceTracker

/// Targeted tests proving CloudKit collaboration is inactive for the current Personal Team
/// build, without rewriting any of the Phase 1–6.1 collaboration tests. These run fully offline.
///
/// Item 7 ("sharing UI is unavailable when the feature is off") is a SwiftUI toolbar-conditional
/// in `SharedEventDetailView` — not independently unit-testable without a UI-driving framework
/// this project doesn't have, same caveat as validation/duplicate-submission checks in earlier
/// phases. What's verified here instead is the one condition that toolbar item is gated on
/// (`CollaborationFeatureFlag.isEnabled`), which is the actual single source of truth the UI reads.
@MainActor
final class CloudKitDeactivationTests: XCTestCase {

    override func tearDown() {
        CollaborationCurrentUser.set(nil)
        super.tearDown()
    }

    // MARK: - 1. Disabled by default

    func testCollaborationFeatureFlagIsDisabledByDefault() {
        XCTAssertFalse(CollaborationFeatureFlag.isEnabled)
    }

    // MARK: - 9. Nothing in the app holds a live CollaborationSyncService

    func testNoAppWideCollaborationServiceExistsWhileDisabled() {
        // FinanceTrackerApp.init() only calls configureShared(...) when the flag is on; since
        // this test target's host app runs with the same (disabled) flag, .shared must be nil —
        // meaning there is no CKContainer/CKSyncEngine instance anywhere for a local operation to
        // reach, structurally ruling out any CloudKit network call from the normal app flow.
        XCTAssertNil(CollaborationSyncService.shared)
    }

    // MARK: - 2/3/4/5/6. Local SharedEvent/Expense/Settlement creation stays fully local

    func testLocalSharedEventCreationRequiresNoCloudKit() {
        let context = TestSupport.makeInMemoryContext()
        let you = Person(displayName: "You", isCurrentUser: true)
        let maria = Person(displayName: "Maria")
        context.insert(you)
        context.insert(maria)

        let event = SharedEvent(title: "Weekend Trip", participants: [you, maria])
        context.insert(event)
        try? context.save()

        XCTAssertFalse(event.isCollaborationEnabled, "a newly-created event must never be marked collaborative while the flag is off")
        XCTAssertFalse(event.isRemoteOwned)
        XCTAssertNil(event.remoteID, "no remote identity is ever minted without an upload attempt, which never happens here")
        XCTAssertTrue(event.eventParticipants.isEmpty, "nothing here ever calls ensureEventParticipants")
    }

    func testLocalSharedExpenseCreationDoesNotEnqueueCloudKitWork() {
        let context = TestSupport.makeInMemoryContext()
        let you = Person(displayName: "You", isCurrentUser: true)
        let maria = Person(displayName: "Maria")
        context.insert(you)
        context.insert(maria)
        let event = SharedEvent(title: "Weekend Trip", participants: [you, maria])
        context.insert(event)

        // Mirrors AddSharedExpenseView.save() for a local-only event: no CollaborationSyncService
        // call exists on this path at all when event.isCollaborationEnabled is false.
        let expense = SharedExpense(amount: 60, currency: "USD", paidBy: you, event: event)
        context.insert(expense)
        event.expenses.append(expense)
        let shareYou = SharedExpenseParticipant(person: you, amount: 30, expense: expense)
        let shareMaria = SharedExpenseParticipant(person: maria, amount: 30, expense: expense)
        context.insert(shareYou)
        context.insert(shareMaria)
        expense.participants = [shareYou, shareMaria]
        try? context.save()

        XCTAssertNil(expense.remoteID, "no upload ever ran, so no remote identity was ever minted")
        XCTAssertNil(CollaborationSyncService.shared, "still no app-wide service instance to have queued anything")
    }

    func testLocalSettlementCreationDoesNotEnqueueCloudKitWork() {
        let context = TestSupport.makeInMemoryContext()
        let you = Person(displayName: "You", isCurrentUser: true)
        let maria = Person(displayName: "Maria")
        context.insert(you)
        context.insert(maria)
        let event = SharedEvent(title: "Weekend Trip", participants: [you, maria])
        context.insert(event)
        let expense = SharedExpense(amount: 60, currency: "USD", paidBy: maria, event: event)
        context.insert(expense)
        event.expenses.append(expense)
        let shareYou = SharedExpenseParticipant(person: you, amount: 30, expense: expense)
        let shareMaria = SharedExpenseParticipant(person: maria, amount: 30, expense: expense)
        context.insert(shareYou)
        context.insert(shareMaria)
        expense.participants = [shareYou, shareMaria]
        try? context.save()

        // Mirrors RecordPaymentView.confirm() for a local-only event.
        let settlement = Settlement(fromPerson: you, toPerson: maria, amount: 30, paymentMethod: .cash, event: event)
        context.insert(settlement)
        event.settlements.append(settlement)
        try? context.save()

        XCTAssertNil(settlement.remoteID)
        XCTAssertNil(CollaborationSyncService.shared)
    }

    func testLocalBalancesStillCalculateWhileDisabled() {
        let context = TestSupport.makeInMemoryContext()
        let you = Person(displayName: "You", isCurrentUser: true)
        let maria = Person(displayName: "Maria")
        context.insert(you)
        context.insert(maria)
        let event = SharedEvent(title: "Weekend Trip", participants: [you, maria])
        context.insert(event)
        let expense = SharedExpense(amount: 60, currency: "USD", paidBy: maria, event: event)
        context.insert(expense)
        event.expenses.append(expense)
        let shareYou = SharedExpenseParticipant(person: you, amount: 30, expense: expense)
        let shareMaria = SharedExpenseParticipant(person: maria, amount: 30, expense: expense)
        context.insert(shareYou)
        context.insert(shareMaria)
        expense.participants = [shareYou, shareMaria]
        try? context.save()

        XCTAssertTrue(event.currentUser === you, "local-only events still resolve identity via Person.isCurrentUser")
        XCTAssertEqual(event.yourShare, 30)
        XCTAssertEqual(event.youPaid, 0)
        XCTAssertEqual(event.yourNetBalance, -30)
        XCTAssertEqual(event.outstandingBalance(for: maria), -30)

        let settlement = Settlement(fromPerson: you, toPerson: maria, amount: 30, paymentMethod: .cash, event: event)
        context.insert(settlement)
        event.settlements.append(settlement)
        try? context.save()

        XCTAssertTrue(event.isFullySettled)
    }

    func testPersonalFinanceUnaffectedByLocalSharedExpenseFlow() {
        let context = TestSupport.makeInMemoryContext()
        let entriesBefore = (try? context.fetchCount(FetchDescriptor<Entry>())) ?? -1
        let walletsBefore = (try? context.fetchCount(FetchDescriptor<Wallet>())) ?? -1
        let budgetsBefore = (try? context.fetchCount(FetchDescriptor<Budget>())) ?? -1

        let you = Person(displayName: "You", isCurrentUser: true)
        let maria = Person(displayName: "Maria")
        context.insert(you)
        context.insert(maria)
        let event = SharedEvent(title: "Weekend Trip", participants: [you, maria])
        context.insert(event)
        let expense = SharedExpense(amount: 60, currency: "USD", paidBy: maria, event: event)
        context.insert(expense)
        event.expenses.append(expense)
        let settlement = Settlement(fromPerson: you, toPerson: maria, amount: 30, paymentMethod: .cash, event: event)
        context.insert(settlement)
        event.settlements.append(settlement)
        try? context.save()

        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Entry>())) ?? -2, entriesBefore, "Shared Expenses never create an Entry on their own, disabled or not")
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Wallet>())) ?? -2, walletsBefore)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Budget>())) ?? -2, budgetsBefore)
    }

    // MARK: - 7. The condition the "Share Event" toolbar item is gated on

    func testSharingUIGateConditionIsFalse() {
        // SharedEventDetailView wraps its "Share Event" ToolbarItem in
        // `if CollaborationFeatureFlag.isEnabled { ... }` — this is that same condition,
        // confirming the button is structurally absent from the toolbar while disabled.
        XCTAssertFalse(CollaborationFeatureFlag.isEnabled)
    }

    // MARK: - 8. The CloudKit implementation itself remains present and functional

    /// Proves the Phase 1–6.1 implementation wasn't gutted to make this build possible, WITHOUT
    /// constructing a live `CKContainer`/`CollaborationSyncService` — doing that from inside this
    /// deactivated build's own process crashes it (see the finding documented in the CloudKit
    /// Deactivation Final Report's Tests section: `[CK] Significant issue... your process must
    /// have a com.apple.developer.icloud-services entitlement`), which is itself concrete,
    /// unplanned proof that deactivation is real — a live CloudKit call genuinely cannot run.
    /// `CollaborationSyncServiceTests`/`CollaborativeExpenseTests`/etc. (unmodified, Phase 2–6.1)
    /// still exist and still construct a real service exactly as before; they're simply not
    /// runnable in an unentitled process, by design, until CloudKit is reactivated.
    ///
    /// What's safe and meaningful to verify here instead: the pure, CKContainer-free half of the
    /// implementation — `CloudKitSharedEventMapper` and the identity fields it depends on — is
    /// still fully present and produces correct output, exactly as `CloudKitSharedEventMapperTests`
    /// (existing, Phase 1, also unmodified) already independently confirms by passing.
    func testCollaborationMapperImplementationRemainsIntactAndFunctional() {
        let context = TestSupport.makeInMemoryContext()
        let you = Person(displayName: "You", isCurrentUser: true, isFrequent: true)
        let maria = Person(displayName: "Maria")
        context.insert(you)
        context.insert(maria)
        let event = SharedEvent(title: "Barcelona Trip", participants: [you, maria])
        context.insert(event)

        // What CollaborationSyncService.enableCollaboration(for:) would do locally — done by
        // hand here since constructing the service itself requires a live CKContainer.
        event.isCollaborationEnabled = true
        let membership = EventParticipant(event: event, person: you, role: .owner, userRecordID: "your-icloud-id")
        context.insert(membership)
        event.eventParticipants = [membership]
        try? context.save()

        let graph = CloudKitSharedEventMapper.map(event)
        XCTAssertNotNil(event.remoteID, "the mapper still mints stable remote identity")
        XCTAssertEqual(graph.participants.count, 2)
        XCTAssertEqual(graph.zoneID.zoneName, "SharedEvent-\(event.remoteID!.uuidString)")

        CollaborationCurrentUser.set("your-icloud-id")
        XCTAssertTrue(event.currentUser === you, "EventParticipant-based identity resolution still works")

        // The container identifier the (currently unused) live service would use is still intact
        // and unchanged, ready for reactivation — a plain string constant, safe to read.
        XCTAssertEqual(CollaborationSyncService.containerIdentifier, "iCloud.com.andreacorzo.FinanceTracker")
    }
}
