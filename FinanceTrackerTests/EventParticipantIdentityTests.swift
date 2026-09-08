import XCTest
import SwiftData
import CloudKit
@testable import FinanceTracker

/// Phase 4 (event-scoped participant identity) tests.
///
/// `claimParticipant(_:in:as:)`'s success path always attempts a real `CKSyncEngine.sendChanges()`
/// network call — like `share(event:)`/`acceptShare(metadata:)` before it, that half is NOT
/// exercised here; a live CloudKit account/container is required and is explicitly out of reach
/// in this sandboxed environment. What IS fully covered offline: `currentParticipant(for:)`/
/// `unclaimedParticipants` (the query logic "Who are you?" and automatic matching are built on),
/// the already-claimed rejection (which returns before any network call), event-scoping/isolation,
/// `CloudKitSharedEventMapper.participantRecord(for:in:)`'s identity fields, and Cloud → Local
/// reconciliation of the new `EventParticipant` fields via `apply(_:)`.
@MainActor
final class EventParticipantIdentityTests: XCTestCase {

    private func makeService(context: ModelContext) -> CollaborationSyncService {
        CollaborationSyncService(
            modelContext: context,
            container: CKContainer(identifier: CollaborationSyncService.containerIdentifier),
            stateSerialization: nil
        )
    }

    private func makeCollaborativeScenario(in context: ModelContext) -> (event: SharedEvent, you: Person, maria: Person) {
        let you = Person(displayName: "You", isCurrentUser: true, isFrequent: true)
        let maria = Person(displayName: "Maria")
        context.insert(you)
        context.insert(maria)
        let event = SharedEvent(title: "Barcelona Trip", icon: "airplane", participants: [you, maria])
        context.insert(event)
        try? context.save()
        return (event, you, maria)
    }

    // MARK: - 1. Exact userRecordID match

    func testCurrentParticipantMatchesByExactUserRecordID() {
        let context = TestSupport.makeInMemoryContext()
        let (event, you, maria) = makeCollaborativeScenario(in: context)

        let youMembership = EventParticipant(event: event, person: you, role: .owner, userRecordID: "you-icloud-id")
        let mariaMembership = EventParticipant(event: event, person: maria, role: .member)
        context.insert(youMembership)
        context.insert(mariaMembership)
        event.eventParticipants = [youMembership, mariaMembership]

        XCTAssertTrue(event.currentParticipant(for: "you-icloud-id") === youMembership)
    }

    // MARK: - 2. Same displayName, different userRecordID must NOT match

    func testSameDisplayNameDifferentUserRecordIDDoesNotMatch() {
        let context = TestSupport.makeInMemoryContext()
        let (event, you, _) = makeCollaborativeScenario(in: context)

        let membership = EventParticipant(event: event, person: you, role: .owner, userRecordID: "real-icloud-id")
        context.insert(membership)
        event.eventParticipants = [membership]

        // A displayName-based (or any non-exact) match would incorrectly find `membership` here.
        XCTAssertNil(event.currentParticipant(for: "a-completely-different-icloud-id"))
    }

    // MARK: - 3. Unknown current user → identity-selection state

    func testUnknownCurrentUserYieldsIdentitySelectionState() {
        let context = TestSupport.makeInMemoryContext()
        let (event, you, maria) = makeCollaborativeScenario(in: context)

        let youMembership = EventParticipant(event: event, person: you)
        let mariaMembership = EventParticipant(event: event, person: maria)
        context.insert(youMembership)
        context.insert(mariaMembership)
        event.eventParticipants = [youMembership, mariaMembership]

        XCTAssertNil(event.currentParticipant(for: "some-unrelated-icloud-id"))
        XCTAssertEqual(event.unclaimedParticipants.count, 2, "both participants should be selectable candidates")
    }

    // MARK: - 4. Already-claimed participant cannot be claimed (offline: returns before any network call)

    func testClaimingAlreadyClaimedParticipantIsRejected() async {
        let context = TestSupport.makeInMemoryContext()
        let (event, _, maria) = makeCollaborativeScenario(in: context)
        let service = makeService(context: context)

        let mariaMembership = EventParticipant(event: event, person: maria, userRecordID: "marias-real-icloud-id")
        context.insert(mariaMembership)
        event.eventParticipants = [mariaMembership]

        let result = await service.claimParticipant(mariaMembership, in: event, as: "someone-elses-icloud-id")

        switch result {
        case .alreadyClaimedByAnother:
            break // expected
        default:
            XCTFail("expected .alreadyClaimedByAnother, got \(result)")
        }
        XCTAssertEqual(mariaMembership.userRecordID, "marias-real-icloud-id", "an already-claimed participant must never be silently overwritten")
    }

    // MARK: - 5. Claiming an unclaimed participant assigns userRecordID (local half only — see file header)

    func testClaimedParticipantIsFoundByCurrentParticipantLookup() {
        let context = TestSupport.makeInMemoryContext()
        let (event, _, maria) = makeCollaborativeScenario(in: context)

        let mariaMembership = EventParticipant(event: event, person: maria)
        context.insert(mariaMembership)
        event.eventParticipants = [mariaMembership]
        XCTAssertNil(event.currentParticipant(for: "new-icloud-id"))

        // Simulates the optimistic local half of claimParticipant(_:in:as:) — the part that
        // doesn't require network — without invoking the real network-dependent method.
        mariaMembership.userRecordID = "new-icloud-id"

        XCTAssertTrue(event.currentParticipant(for: "new-icloud-id") === mariaMembership)
        XCTAssertTrue(event.unclaimedParticipants.isEmpty)
    }

    // MARK: - 6/7. Identity remains event-scoped; the same iCloud user gets separate associations per event

    func testIdentityDoesNotLeakBetweenEvents() {
        let context = TestSupport.makeInMemoryContext()
        let (eventA, andrea, _) = makeCollaborativeScenario(in: context)
        let eventB = SharedEvent(title: "Paris Trip", participants: [andrea])
        context.insert(eventB)
        try? context.save()

        let membershipA = EventParticipant(event: eventA, person: andrea, userRecordID: "andreas-icloud-id")
        let membershipB = EventParticipant(event: eventB, person: andrea) // unclaimed in this event
        context.insert(membershipA)
        context.insert(membershipB)
        eventA.eventParticipants = [membershipA]
        eventB.eventParticipants = [membershipB]

        XCTAssertTrue(eventA.currentParticipant(for: "andreas-icloud-id") === membershipA)
        XCTAssertNil(eventB.currentParticipant(for: "andreas-icloud-id"), "the same iCloud user's claim in Event A must not leak into Event B")

        // Claiming Andrea's membership in B independently must not disturb A's association.
        membershipB.userRecordID = "andreas-icloud-id"
        XCTAssertTrue(eventB.currentParticipant(for: "andreas-icloud-id") === membershipB)
        XCTAssertTrue(eventA.currentParticipant(for: "andreas-icloud-id") === membershipA)
        XCTAssertFalse(membershipA === membershipB, "two distinct event-scoped associations, never a shared/global one")
    }

    // MARK: - 8. Guests keep userRecordID == nil

    func testGuestParticipantHasNilUserRecordID() {
        let context = TestSupport.makeInMemoryContext()
        let (event, _, _) = makeCollaborativeScenario(in: context)
        let john = Person(displayName: "John")
        context.insert(john)
        event.participants.append(john)

        let guestMembership = EventParticipant(event: event, person: john)
        context.insert(guestMembership)
        event.eventParticipants = [guestMembership]

        XCTAssertNil(guestMembership.userRecordID)
        XCTAssertTrue(event.unclaimedParticipants.contains { $0 === guestMembership })
    }

    // MARK: - 9. Settlement.transaction remains untouched by identity reconciliation

    func testSettlementTransactionUntouchedByParticipantReconciliation() {
        let context = TestSupport.makeInMemoryContext()
        let (event, you, maria) = makeCollaborativeScenario(in: context)
        event.remoteID = UUID()
        let settlement = Settlement(fromPerson: maria, toPerson: you, amount: 20, paymentMethod: .cash, event: event)
        context.insert(settlement)
        event.settlements.append(settlement)
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let category = Category(name: "Reimburse", headCategory: HeadCategory(name: "Income", icon: "banknote.fill", colorHex: "#000000"))
        context.insert(category.headCategory)
        context.insert(category)
        let entry = Entry(amount: 20, type: .income, category: category, wallet: wallet)
        context.insert(entry)
        settlement.transaction = entry
        try? context.save()

        let service = makeService(context: context)
        let zoneID = CKRecordZone.ID(zoneName: "SharedEvent-\(event.remoteID!.uuidString)", ownerName: CKCurrentUserDefaultName)
        let recordName = "\(event.remoteID!.uuidString)-participant-\(maria.sharingAnchorID.uuidString)"
        let participantRecord = CKRecord(recordType: "Participant", recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
        participantRecord["event"] = CKRecord.Reference(recordID: CKRecord.ID(recordName: event.remoteID!.uuidString, zoneID: zoneID), action: .deleteSelf)
        participantRecord["displayName"] = "Maria"
        participantRecord["role"] = "member"
        participantRecord["userRecordID"] = "marias-icloud-id"

        service.apply(participantRecord)

        XCTAssertTrue(settlement.transaction === entry, "identity reconciliation must never touch Settlement.transaction")
    }

    // MARK: - 10. Identity reconciliation never creates Personal Finance objects

    func testParticipantReconciliationNeverCreatesPersonalFinanceObjects() {
        let context = TestSupport.makeInMemoryContext()
        let (event, _, maria) = makeCollaborativeScenario(in: context)
        event.remoteID = UUID()
        try? context.save()
        let service = makeService(context: context)

        let entriesBefore = (try? context.fetchCount(FetchDescriptor<Entry>())) ?? -1
        let walletsBefore = (try? context.fetchCount(FetchDescriptor<Wallet>())) ?? -1
        let budgetsBefore = (try? context.fetchCount(FetchDescriptor<Budget>())) ?? -1
        let categoriesBefore = (try? context.fetchCount(FetchDescriptor<FinanceTracker.Category>())) ?? -1

        let zoneID = CKRecordZone.ID(zoneName: "SharedEvent-\(event.remoteID!.uuidString)", ownerName: CKCurrentUserDefaultName)
        let recordName = "\(event.remoteID!.uuidString)-participant-\(maria.sharingAnchorID.uuidString)"
        let record = CKRecord(recordType: "Participant", recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
        record["event"] = CKRecord.Reference(recordID: CKRecord.ID(recordName: event.remoteID!.uuidString, zoneID: zoneID), action: .deleteSelf)
        record["displayName"] = "Maria"
        record["role"] = "member"
        record["userRecordID"] = "marias-icloud-id"
        service.apply(record)

        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Entry>())) ?? -2, entriesBefore)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Wallet>())) ?? -2, walletsBefore)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Budget>())) ?? -2, budgetsBefore)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<FinanceTracker.Category>())) ?? -2, categoriesBefore)
    }

    // MARK: - 11. Duplicate identity claim delivery does not create duplicate Person/EventParticipant rows

    func testDuplicateParticipantRecordDeliveryDoesNotDuplicate() {
        let context = TestSupport.makeInMemoryContext()
        let (event, _, maria) = makeCollaborativeScenario(in: context)
        event.remoteID = UUID()
        try? context.save()
        let service = makeService(context: context)

        let zoneID = CKRecordZone.ID(zoneName: "SharedEvent-\(event.remoteID!.uuidString)", ownerName: CKCurrentUserDefaultName)
        let recordName = "\(event.remoteID!.uuidString)-participant-\(maria.sharingAnchorID.uuidString)"
        func makeRecord() -> CKRecord {
            let record = CKRecord(recordType: "Participant", recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
            record["event"] = CKRecord.Reference(recordID: CKRecord.ID(recordName: event.remoteID!.uuidString, zoneID: zoneID), action: .deleteSelf)
            record["displayName"] = "Maria"
            record["role"] = "member"
            record["userRecordID"] = "marias-icloud-id"
            return record
        }

        service.apply(makeRecord())
        service.apply(makeRecord())
        service.apply(makeRecord())

        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Person>())) ?? -1, 2, "You + Maria — no duplicate Person")
        XCTAssertEqual(event.eventParticipants.count, 1, "no duplicate EventParticipant for the same Participant record")
        XCTAssertEqual(event.eventParticipants.first?.userRecordID, "marias-icloud-id")
    }

    // MARK: - 12. Existing local-only SharedEvent behavior is unchanged

    func testLocalOnlySharedEventBehaviorUnchanged() {
        let context = TestSupport.makeInMemoryContext()
        let (event, _, _) = makeCollaborativeScenario(in: context)

        XCTAssertFalse(event.isCollaborationEnabled)
        XCTAssertFalse(event.isRemoteOwned)
        XCTAssertTrue(event.eventParticipants.isEmpty, "a purely local event never gains EventParticipant rows")
    }

    // MARK: - CloudKitSharedEventMapper.participantRecord(for:in:) — pure, offline

    func testParticipantRecordForIncludesIdentityFields() {
        let context = TestSupport.makeInMemoryContext()
        let (event, _, maria) = makeCollaborativeScenario(in: context)
        let membership = EventParticipant(event: event, person: maria, role: .member, userRecordID: "marias-icloud-id")
        context.insert(membership)
        event.eventParticipants = [membership]

        let record = CloudKitSharedEventMapper.participantRecord(for: maria, in: event)

        XCTAssertNotNil(record)
        XCTAssertEqual(record?["role"] as? String, "member")
        XCTAssertEqual(record?["userRecordID"] as? String, "marias-icloud-id")
        XCTAssertEqual(record?["isRemoved"] as? Int64, 0)
        XCTAssertNotNil(record?["joinedAt"])
    }

    func testParticipantRecordForReturnsNilForNonParticipant() {
        let context = TestSupport.makeInMemoryContext()
        let (event, _, _) = makeCollaborativeScenario(in: context)
        let stranger = Person(displayName: "Stranger")
        context.insert(stranger)

        XCTAssertNil(CloudKitSharedEventMapper.participantRecord(for: stranger, in: event))
    }
}
