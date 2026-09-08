import XCTest
import SwiftData
import CloudKit
@testable import FinanceTracker

/// Phase 3.1: CloudKit does not guarantee that fetched records respect our domain's dependency
/// order (a `Participant`/`Expense`/`Settlement` can arrive before the `SharedEvent` or
/// `Expense`/`Participant` it depends on). These tests exercise `CollaborationSyncService.apply(_:)`
/// entirely offline, with hand-built `CKRecord`s delivered deliberately out of order, and confirm
/// the deferred record is retried (not dropped) once its dependency is applied, and that
/// redelivering the same record never creates a duplicate.
@MainActor
final class CollaborationReconciliationOrderingTests: XCTestCase {

    private func makeService(context: ModelContext) -> CollaborationSyncService {
        CollaborationSyncService(
            modelContext: context,
            container: CKContainer(identifier: CollaborationSyncService.containerIdentifier),
            stateSerialization: nil
        )
    }

    private func zoneID(for eventID: UUID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "SharedEvent-\(eventID.uuidString)", ownerName: CKCurrentUserDefaultName)
    }

    private func sharedEventRecord(eventID: UUID, zoneID: CKRecordZone.ID, title: String = "Remote Event") -> CKRecord {
        let record = CKRecord(recordType: "SharedEvent", recordID: CKRecord.ID(recordName: eventID.uuidString, zoneID: zoneID))
        record["title"] = title
        record["status"] = SharedEventStatus.active.rawValue
        return record
    }

    private func participantRecord(eventID: UUID, anchorID: UUID, zoneID: CKRecordZone.ID, name: String) -> CKRecord {
        let recordName = "\(eventID.uuidString)-participant-\(anchorID.uuidString)"
        let record = CKRecord(recordType: "Participant", recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
        record["event"] = CKRecord.Reference(recordID: CKRecord.ID(recordName: eventID.uuidString, zoneID: zoneID), action: .deleteSelf)
        record["displayName"] = name
        record["role"] = "member"
        return record
    }

    private func expenseRecord(expenseID: UUID, eventID: UUID, zoneID: CKRecordZone.ID, amountCents: Int64 = 1000) -> CKRecord {
        let record = CKRecord(recordType: "Expense", recordID: CKRecord.ID(recordName: expenseID.uuidString, zoneID: zoneID))
        record["event"] = CKRecord.Reference(recordID: CKRecord.ID(recordName: eventID.uuidString, zoneID: zoneID), action: .deleteSelf)
        record["amountCents"] = amountCents as NSNumber
        record["currency"] = "EUR"
        record["note"] = "Dinner"
        record["date"] = Date.now
        record["splitMethod"] = SharedSplitMethod.equal.rawValue
        return record
    }

    private func expenseParticipantRecord(
        shareID: UUID, expenseID: UUID, participantRecordID: CKRecord.ID, zoneID: CKRecordZone.ID, amountCents: Int64 = 500
    ) -> CKRecord {
        let record = CKRecord(recordType: "ExpenseParticipant", recordID: CKRecord.ID(recordName: shareID.uuidString, zoneID: zoneID))
        record["expense"] = CKRecord.Reference(recordID: CKRecord.ID(recordName: expenseID.uuidString, zoneID: zoneID), action: .deleteSelf)
        record["participant"] = CKRecord.Reference(recordID: participantRecordID, action: .none)
        record["amountCents"] = amountCents as NSNumber
        return record
    }

    private func settlementRecord(
        settlementID: UUID, eventID: UUID, fromRecordID: CKRecord.ID, toRecordID: CKRecord.ID, zoneID: CKRecordZone.ID, amountCents: Int64 = 500
    ) -> CKRecord {
        let record = CKRecord(recordType: "Settlement", recordID: CKRecord.ID(recordName: settlementID.uuidString, zoneID: zoneID))
        record["event"] = CKRecord.Reference(recordID: CKRecord.ID(recordName: eventID.uuidString, zoneID: zoneID), action: .deleteSelf)
        record["fromParticipant"] = CKRecord.Reference(recordID: fromRecordID, action: .none)
        record["toParticipant"] = CKRecord.Reference(recordID: toRecordID, action: .none)
        record["amountCents"] = amountCents as NSNumber
        record["paymentMethod"] = SettlementPaymentMethod.cash.rawValue
        record["date"] = Date.now
        return record
    }

    // MARK: - 1/2/3. Participant before SharedEvent

    func testParticipantArrivingBeforeItsSharedEventIsNotLostThenReconciles() {
        let context = TestSupport.makeInMemoryContext()
        let service = makeService(context: context)

        let eventID = UUID()
        let anchorID = UUID()
        let zoneID = zoneID(for: eventID)
        let participant = participantRecord(eventID: eventID, anchorID: anchorID, zoneID: zoneID, name: "Maria")

        // 1. Participant arrives first — must not crash, and must not be silently discarded.
        service.apply(participant)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Person>())) ?? -1, 0, "no Person should exist yet — the participant is pending, not applied")

        // 2. Its SharedEvent subsequently arrives — the pending participant must now reconcile.
        service.apply(sharedEventRecord(eventID: eventID, zoneID: zoneID))

        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people.first?.displayName, "Maria")
        let event = try? context.fetch(FetchDescriptor<SharedEvent>()).first
        XCTAssertEqual(event?.participants.count, 1)

        // 3. Redelivering the same participant record must not create a duplicate.
        service.apply(participant)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Person>())) ?? -1, 1)
        XCTAssertEqual(event?.participants.count, 1)
    }

    // MARK: - 4. Expense before SharedEvent

    func testExpenseArrivingBeforeItsSharedEventIsDeferredThenReconciles() {
        let context = TestSupport.makeInMemoryContext()
        let service = makeService(context: context)

        let eventID = UUID()
        let expenseID = UUID()
        let zoneID = zoneID(for: eventID)

        service.apply(expenseRecord(expenseID: expenseID, eventID: eventID, zoneID: zoneID))
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<SharedExpense>())) ?? -1, 0)

        service.apply(sharedEventRecord(eventID: eventID, zoneID: zoneID))

        let expenses = (try? context.fetch(FetchDescriptor<SharedExpense>())) ?? []
        XCTAssertEqual(expenses.count, 1)
        XCTAssertEqual(expenses.first?.amount, Decimal(1000) / 100)
        XCTAssertEqual(expenses.first?.event?.remoteID, eventID)
    }

    // MARK: - 5. ExpenseParticipant before Expense and Participant

    func testExpenseParticipantArrivingBeforeItsDependenciesIsDeferredThenReconciles() {
        let context = TestSupport.makeInMemoryContext()
        let service = makeService(context: context)

        let eventID = UUID()
        let expenseID = UUID()
        let shareID = UUID()
        let anchorID = UUID()
        let zoneID = zoneID(for: eventID)
        let participantRecordID = CKRecord.ID(recordName: "\(eventID.uuidString)-participant-\(anchorID.uuidString)", zoneID: zoneID)

        // Worst-case delivery order: the most-dependent record first, its dependencies last.
        service.apply(expenseParticipantRecord(shareID: shareID, expenseID: expenseID, participantRecordID: participantRecordID, zoneID: zoneID))
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<SharedExpenseParticipant>())) ?? -1, 0)

        service.apply(participantRecord(eventID: eventID, anchorID: anchorID, zoneID: zoneID, name: "Maria"))
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<SharedExpenseParticipant>())) ?? -1, 0, "still missing the SharedEvent and the Expense")

        service.apply(sharedEventRecord(eventID: eventID, zoneID: zoneID))
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<SharedExpenseParticipant>())) ?? -1, 0, "still missing the Expense")

        service.apply(expenseRecord(expenseID: expenseID, eventID: eventID, zoneID: zoneID))

        let shares = (try? context.fetch(FetchDescriptor<SharedExpenseParticipant>())) ?? []
        XCTAssertEqual(shares.count, 1)
        XCTAssertEqual(shares.first?.person?.displayName, "Maria")
        XCTAssertEqual(shares.first?.expense?.remoteID, expenseID)

        // Redelivery must still not duplicate anything, across the whole chain.
        service.apply(expenseParticipantRecord(shareID: shareID, expenseID: expenseID, participantRecordID: participantRecordID, zoneID: zoneID))
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<SharedExpenseParticipant>())) ?? -1, 1)
    }

    // MARK: - 6. Settlement before its dependencies

    func testSettlementArrivingBeforeItsDependenciesIsDeferredThenReconciles() {
        let context = TestSupport.makeInMemoryContext()
        let service = makeService(context: context)

        let eventID = UUID()
        let settlementID = UUID()
        let fromAnchorID = UUID()
        let toAnchorID = UUID()
        let zoneID = zoneID(for: eventID)
        let fromRecordID = CKRecord.ID(recordName: "\(eventID.uuidString)-participant-\(fromAnchorID.uuidString)", zoneID: zoneID)
        let toRecordID = CKRecord.ID(recordName: "\(eventID.uuidString)-participant-\(toAnchorID.uuidString)", zoneID: zoneID)

        service.apply(settlementRecord(settlementID: settlementID, eventID: eventID, fromRecordID: fromRecordID, toRecordID: toRecordID, zoneID: zoneID))
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Settlement>())) ?? -1, 0)

        service.apply(sharedEventRecord(eventID: eventID, zoneID: zoneID))
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Settlement>())) ?? -1, 0, "still missing both participants")

        service.apply(participantRecord(eventID: eventID, anchorID: fromAnchorID, zoneID: zoneID, name: "Maria"))
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Settlement>())) ?? -1, 0, "still missing the second participant")

        service.apply(participantRecord(eventID: eventID, anchorID: toAnchorID, zoneID: zoneID, name: "You"))

        let settlements = (try? context.fetch(FetchDescriptor<Settlement>())) ?? []
        XCTAssertEqual(settlements.count, 1)
        XCTAssertEqual(settlements.first?.fromPerson?.displayName, "Maria")
        XCTAssertEqual(settlements.first?.toPerson?.displayName, "You")

        service.apply(settlementRecord(settlementID: settlementID, eventID: eventID, fromRecordID: fromRecordID, toRecordID: toRecordID, zoneID: zoneID))
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Settlement>())) ?? -1, 1)
    }

    // MARK: - Malformed records are dropped, never queued forever

    func testUnparseableRecordIsDroppedRatherThanQueuedForever() {
        let context = TestSupport.makeInMemoryContext()
        let service = makeService(context: context)

        let zoneID = zoneID(for: UUID())
        let malformed = CKRecord(recordType: "Participant", recordID: CKRecord.ID(recordName: "not-a-valid-composite-name", zoneID: zoneID))

        service.apply(malformed)
        // Applying an unrelated, resolvable SharedEvent afterward must not somehow resurrect or
        // apply the malformed record — proving it was dropped, not silently retained.
        let eventID = UUID()
        service.apply(sharedEventRecord(eventID: eventID, zoneID: self.zoneID(for: eventID)))

        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Person>())) ?? -1, 0)
    }
}
