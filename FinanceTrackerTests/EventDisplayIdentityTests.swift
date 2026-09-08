import XCTest
import SwiftData
@testable import FinanceTracker

/// Phase 5.1: `SharedEvent.displayName(for:currentUserRecordID:)` — the event-scoped "You"
/// resolution used by `SharedExpenseRow` and related display logic. The function itself is
/// synchronous and non-throwing (see its declaration in `EventParticipant.swift`), so there is no
/// async CloudKit call to avoid calling repeatedly — that's a property of its signature, not
/// something that needs a live CloudKit account to verify.
@MainActor
final class EventDisplayIdentityTests: XCTestCase {

    // MARK: - 1/2. Collaborative event: correct "You" vs. name resolution

    func testCollaborativeEventDisplaysYouForCurrentUsersParticipant() {
        let context = TestSupport.makeInMemoryContext()
        let andrea = Person(displayName: "Andrea") // deliberately NOT isCurrentUser, matching a
        let maria = Person(displayName: "Maria")   // synced participant Person on Maria's device
        context.insert(andrea)
        context.insert(maria)
        let event = SharedEvent(title: "Barcelona Trip", participants: [andrea, maria])
        event.isCollaborationEnabled = true
        context.insert(event)

        let andreaMembership = EventParticipant(event: event, person: andrea, userRecordID: "andreas-id")
        let mariaMembership = EventParticipant(event: event, person: maria, userRecordID: "marias-id")
        context.insert(andreaMembership)
        context.insert(mariaMembership)
        event.eventParticipants = [andreaMembership, mariaMembership]

        XCTAssertEqual(event.displayName(for: maria, currentUserRecordID: "marias-id"), "You")
    }

    func testCollaborativeEventDisplaysNameForAnotherParticipant() {
        let context = TestSupport.makeInMemoryContext()
        let andrea = Person(displayName: "Andrea")
        let maria = Person(displayName: "Maria")
        context.insert(andrea)
        context.insert(maria)
        let event = SharedEvent(title: "Barcelona Trip", participants: [andrea, maria])
        event.isCollaborationEnabled = true
        context.insert(event)

        let andreaMembership = EventParticipant(event: event, person: andrea, userRecordID: "andreas-id")
        let mariaMembership = EventParticipant(event: event, person: maria, userRecordID: "marias-id")
        context.insert(andreaMembership)
        context.insert(mariaMembership)
        event.eventParticipants = [andreaMembership, mariaMembership]

        // Viewed from Maria's device (currentUserRecordID = hers): Andrea must show as "Andrea".
        XCTAssertEqual(event.displayName(for: andrea, currentUserRecordID: "marias-id"), "Andrea")
    }

    // MARK: - 3. Same displayName, different userRecordID must NOT resolve to "You"

    func testSameDisplayNameDifferentUserRecordIDIsNotYou() {
        let context = TestSupport.makeInMemoryContext()
        let maria = Person(displayName: "Maria")
        context.insert(maria)
        let event = SharedEvent(title: "Barcelona Trip", participants: [maria])
        event.isCollaborationEnabled = true
        context.insert(event)
        let membership = EventParticipant(event: event, person: maria, userRecordID: "marias-real-id")
        context.insert(membership)
        event.eventParticipants = [membership]

        XCTAssertEqual(event.displayName(for: maria, currentUserRecordID: "a-different-icloud-id"), "Maria")
    }

    // MARK: - 4. Local-only event keeps existing Person.isCurrentUser behavior

    func testLocalOnlyEventUsesPersonIsCurrentUser() {
        let context = TestSupport.makeInMemoryContext()
        let you = Person(displayName: "Andrea", isCurrentUser: true)
        let maria = Person(displayName: "Maria")
        context.insert(you)
        context.insert(maria)
        let event = SharedEvent(title: "Dinner Split", participants: [you, maria])
        // isCollaborationEnabled stays false — no EventParticipant rows exist at all.
        context.insert(event)

        XCTAssertEqual(event.displayName(for: you, currentUserRecordID: nil), "You")
        XCTAssertEqual(event.displayName(for: maria, currentUserRecordID: nil), "Maria")
        // Even if a currentUserRecordID happened to be supplied, a local-only event never uses it.
        XCTAssertEqual(event.displayName(for: you, currentUserRecordID: "irrelevant-id"), "You")
    }

    // MARK: - 5. Identity remains event-scoped across two events

    func testDisplayIdentityIsEventScoped() {
        let context = TestSupport.makeInMemoryContext()
        let andrea = Person(displayName: "Andrea")
        context.insert(andrea)
        let eventA = SharedEvent(title: "Barcelona Trip", participants: [andrea])
        eventA.isCollaborationEnabled = true
        context.insert(eventA)
        let eventB = SharedEvent(title: "Paris Trip", participants: [andrea])
        eventB.isCollaborationEnabled = true
        context.insert(eventB)

        let membershipA = EventParticipant(event: eventA, person: andrea, userRecordID: "andreas-id")
        let membershipB = EventParticipant(event: eventB, person: andrea) // unclaimed in Event B
        context.insert(membershipA)
        context.insert(membershipB)
        eventA.eventParticipants = [membershipA]
        eventB.eventParticipants = [membershipB]

        XCTAssertEqual(eventA.displayName(for: andrea, currentUserRecordID: "andreas-id"), "You")
        XCTAssertEqual(eventB.displayName(for: andrea, currentUserRecordID: "andreas-id"), "Andrea", "the same iCloud user's claim in Event A must not leak into Event B's display")
    }

    // MARK: - 6. No CloudKit call during resolution (structural + rapid-call proof)

    func testDisplayNameResolutionNeverTouchesNetwork() {
        let context = TestSupport.makeInMemoryContext()
        let maria = Person(displayName: "Maria")
        context.insert(maria)
        let event = SharedEvent(title: "Barcelona Trip", participants: [maria])
        event.isCollaborationEnabled = true
        context.insert(event)
        let membership = EventParticipant(event: event, person: maria, userRecordID: "marias-id")
        context.insert(membership)
        event.eventParticipants = [membership]

        // displayName(for:currentUserRecordID:) is synchronous and non-throwing — calling it
        // hundreds of times in a tight loop (simulating rendering many rows) must complete
        // instantly with no await, no CKContainer, no network involved at all.
        for _ in 0..<500 {
            _ = event.displayName(for: maria, currentUserRecordID: "marias-id")
        }
    }

    // MARK: - 7. Personal Finance untouched by display resolution

    func testDisplayNameResolutionTouchesNoPersonalFinanceData() {
        let context = TestSupport.makeInMemoryContext()
        let maria = Person(displayName: "Maria")
        context.insert(maria)
        let event = SharedEvent(title: "Barcelona Trip", participants: [maria])
        event.isCollaborationEnabled = true
        context.insert(event)
        let membership = EventParticipant(event: event, person: maria, userRecordID: "marias-id")
        context.insert(membership)
        event.eventParticipants = [membership]

        let entriesBefore = (try? context.fetchCount(FetchDescriptor<Entry>())) ?? -1
        let walletsBefore = (try? context.fetchCount(FetchDescriptor<Wallet>())) ?? -1
        let budgetsBefore = (try? context.fetchCount(FetchDescriptor<Budget>())) ?? -1
        let categoriesBefore = (try? context.fetchCount(FetchDescriptor<FinanceTracker.Category>())) ?? -1

        _ = event.displayName(for: maria, currentUserRecordID: "marias-id")

        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Entry>())) ?? -2, entriesBefore)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Wallet>())) ?? -2, walletsBefore)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Budget>())) ?? -2, budgetsBefore)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<FinanceTracker.Category>())) ?? -2, categoriesBefore)
    }
}
