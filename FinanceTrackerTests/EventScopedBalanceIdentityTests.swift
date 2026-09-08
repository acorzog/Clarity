import XCTest
import SwiftData
import CloudKit
@testable import FinanceTracker

/// Tests for the fix making `SharedEventQuerying`'s `currentUser`/`otherParticipants` (and
/// therefore every balance calculation built on them) resolve via event-scoped `EventParticipant`
/// identity for collaborative events, while local-only events keep the original
/// `Person.isCurrentUser` behavior unchanged.
///
/// `CollaborationCurrentUser` is a process-wide cache, so every test explicitly sets it at the
/// start and resets it to `nil` in a `defer`, to stay independent of test execution order.
@MainActor
final class EventScopedBalanceIdentityTests: XCTestCase {

    override func tearDown() {
        CollaborationCurrentUser.set(nil)
        super.tearDown()
    }

    /// A collaborative event where NEITHER participant has `Person.isCurrentUser == true` — the
    /// real shape of a pure recipient device's synced event (its own local "You" bookkeeping
    /// Person was never added to this event's participants at all).
    private func makeRecipientScenario(in context: ModelContext) -> (event: SharedEvent, andrea: Person, maria: Person) {
        let andrea = Person(displayName: "Andrea") // NOT isCurrentUser — a synced Person
        let maria = Person(displayName: "Maria")   // NOT isCurrentUser — a synced Person
        context.insert(andrea)
        context.insert(maria)
        let event = SharedEvent(title: "Barcelona Trip", participants: [andrea, maria])
        event.isCollaborationEnabled = true
        context.insert(event)
        let andreaMembership = EventParticipant(event: event, person: andrea, role: .owner, userRecordID: "andreas-icloud-id")
        let mariaMembership = EventParticipant(event: event, person: maria, role: .member, userRecordID: "marias-icloud-id")
        context.insert(andreaMembership)
        context.insert(mariaMembership)
        event.eventParticipants = [andreaMembership, mariaMembership]
        try? context.save()
        return (event, andrea, maria)
    }

    // MARK: - currentUser resolution

    func testCollaborativeEventResolvesCurrentUserViaEventParticipantEvenWithoutIsCurrentUserFlag() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, _) = makeRecipientScenario(in: context)
        CollaborationCurrentUser.set("andreas-icloud-id")

        XCTAssertTrue(event.currentUser === andrea, "must resolve via EventParticipant, not Person.isCurrentUser")
    }

    func testCollaborativeEventCurrentUserIsNilWhenCacheUnset() {
        let context = TestSupport.makeInMemoryContext()
        let (event, _, _) = makeRecipientScenario(in: context)
        CollaborationCurrentUser.set(nil)

        XCTAssertNil(event.currentUser, "identity unknown must never silently guess a participant")
    }

    func testCollaborativeEventCurrentUserIsNilForUnmatchedCachedID() {
        let context = TestSupport.makeInMemoryContext()
        let (event, _, _) = makeRecipientScenario(in: context)
        CollaborationCurrentUser.set("some-unrelated-icloud-id")

        XCTAssertNil(event.currentUser)
    }

    func testLocalOnlyEventKeepsPersonIsCurrentUserBehaviorEvenWithCachePopulated() {
        let context = TestSupport.makeInMemoryContext()
        let you = Person(displayName: "Andrea", isCurrentUser: true)
        let maria = Person(displayName: "Maria")
        context.insert(you)
        context.insert(maria)
        let event = SharedEvent(title: "Dinner Split", participants: [you, maria])
        // isCollaborationEnabled stays false.
        context.insert(event)

        // Even with a cached identity present (e.g. left over from viewing a different,
        // collaborative event), a local-only event must never consult it.
        CollaborationCurrentUser.set("some-icloud-id-that-matches-nothing-here")

        XCTAssertTrue(event.currentUser === you)
    }

    // MARK: - otherParticipants

    func testOtherParticipantsExcludesTheEventScopedCurrentUser() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, maria) = makeRecipientScenario(in: context)
        CollaborationCurrentUser.set("marias-icloud-id")

        XCTAssertEqual(event.otherParticipants, [andrea])
        XCTAssertFalse(event.otherParticipants.contains { $0 === maria }, "must never include yourself")
    }

    // MARK: - Full balance engine on a pure-recipient scenario (the actual bug being fixed)

    func testBalanceCalculationsWorkForARecipientWithNoIsCurrentUserPerson() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, maria) = makeRecipientScenario(in: context)
        // Maria (viewing this on her own device) fronts €80, split equally.
        let expense = SharedExpense(amount: 80, currency: "EUR", paidBy: maria, event: event)
        context.insert(expense)
        event.expenses.append(expense)
        let shareAndrea = SharedExpenseParticipant(person: andrea, amount: 40, expense: expense)
        let shareMaria = SharedExpenseParticipant(person: maria, amount: 40, expense: expense)
        context.insert(shareAndrea)
        context.insert(shareMaria)
        expense.participants = [shareAndrea, shareMaria]
        try? context.save()

        // Before this fix, on a device where neither Person is isCurrentUser-flagged, every one
        // of these would silently return 0/empty regardless of real data.
        CollaborationCurrentUser.set("marias-icloud-id")

        XCTAssertEqual(event.youPaid, 80)
        XCTAssertEqual(event.yourShare, 40)
        XCTAssertEqual(event.yourNetBalance, 40, "Maria fronted more than her share — the group owes her")
        XCTAssertEqual(event.outstandingBalance(for: andrea), 40, "Andrea (the other participant) owes Maria €40 — positive means they owe the current user")
        XCTAssertEqual(event.balances.count, 1)
        XCTAssertEqual(event.balances.first?.amount, 40)
        XCTAssertEqual(event.outstandingNetBalance, 40, "must always equal yourNetBalance")
        XCTAssertFalse(event.isFullySettled)
    }

    func testBalancesConvergeIdenticallyRegardlessOfWhichDeviceIsViewing() {
        // Andrea's device: a local-only event where she IS isCurrentUser-flagged locally (she
        // created it) — deliberately NOT marked collaborationEnabled, since a collaborative event
        // resolves identity exclusively through EventParticipant (see `currentUser`'s doc) and
        // Andrea has no EventParticipant row set up on this side of the test.
        let contextA = TestSupport.makeInMemoryContext()
        let andreaOnA = Person(displayName: "Andrea", isCurrentUser: true)
        let mariaOnA = Person(displayName: "Maria")
        contextA.insert(andreaOnA)
        contextA.insert(mariaOnA)
        let eventOnA = SharedEvent(title: "Barcelona Trip", participants: [andreaOnA, mariaOnA])
        contextA.insert(eventOnA)
        let expenseA = SharedExpense(amount: 80, currency: "EUR", paidBy: mariaOnA, event: eventOnA)
        contextA.insert(expenseA)
        eventOnA.expenses.append(expenseA)
        let shareAndreaA = SharedExpenseParticipant(person: andreaOnA, amount: 40, expense: expenseA)
        let shareMariaA = SharedExpenseParticipant(person: mariaOnA, amount: 40, expense: expenseA)
        contextA.insert(shareAndreaA)
        contextA.insert(shareMariaA)
        expenseA.participants = [shareAndreaA, shareMariaA]
        try? contextA.save()

        // Maria's device: her local "You" Person was never added to this synced event at all —
        // only the fix under test lets her balances resolve correctly.
        let contextB = TestSupport.makeInMemoryContext()
        let (eventOnB, andreaOnB, mariaOnB) = makeRecipientScenario(in: contextB)
        let expenseB = SharedExpense(amount: 80, currency: "EUR", paidBy: mariaOnB, event: eventOnB)
        contextB.insert(expenseB)
        eventOnB.expenses.append(expenseB)
        let shareAndreaB = SharedExpenseParticipant(person: andreaOnB, amount: 40, expense: expenseB)
        let shareMariaB = SharedExpenseParticipant(person: mariaOnB, amount: 40, expense: expenseB)
        contextB.insert(shareAndreaB)
        contextB.insert(shareMariaB)
        expenseB.participants = [shareAndreaB, shareMariaB]
        try? contextB.save()
        CollaborationCurrentUser.set("marias-icloud-id")

        // Both devices must agree on Andrea's outstanding position relative to "you" on each
        // device — Andrea sees "Maria owes nothing to me / I owe Maria €40" from her own
        // perspective; Maria sees the mirror. Here we assert each device's own `yourNetBalance`
        // matches what that device's own user actually experiences.
        XCTAssertEqual(eventOnA.yourNetBalance, -40, "Andrea owes into the group")
        XCTAssertEqual(eventOnB.yourNetBalance, 40, "Maria is owed by the group")
    }

    // MARK: - Cache invalidation on iCloud account change

    /// NOTE (discovered while verifying the CloudKit deactivation build): this test constructs a
    /// real `CollaborationSyncService`/`CKContainer` — the only way to exercise the account-change
    /// observer registered inside its `init`. In a process that lacks the
    /// `com.apple.developer.icloud-services` entitlement (as this app deliberately does while
    /// `CollaborationFeatureFlag.isEnabled == false`), the CloudKit daemon aborts the host process
    /// with "your process must have a com.apple.developer.icloud-services entitlement" the moment
    /// the container is used — this is correct, expected OS behavior, not a bug in this test or in
    /// `CollaborationSyncService`. Like every other Phase 2–6.1 test that constructs a live
    /// service, this one is only safely runnable once CloudKit is reactivated (see
    /// `CollaborationFeatureFlag`) in a properly entitled build.
    func testAccountChangeInvalidatesCachedIdentity() async {
        let context = TestSupport.makeInMemoryContext()
        let service = CollaborationSyncService(
            modelContext: context,
            container: CKContainer(identifier: CollaborationSyncService.containerIdentifier),
            stateSerialization: nil
        )
        _ = service // keep the instance (and its notification observer) alive for the test
        CollaborationCurrentUser.set("some-icloud-id")
        XCTAssertEqual(CollaborationCurrentUser.userRecordID, "some-icloud-id")

        NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
        // The observer is registered with queue: .main, so its closure runs as a separate main
        // run-loop turn, not inline with post() — give it a chance to execute before asserting.
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(CollaborationCurrentUser.userRecordID, "a stale identity after switching accounts would make every balance wrong, not just a label")
    }
}
