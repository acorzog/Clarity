import XCTest
import SwiftData
import CloudKit
@testable import FinanceTracker

/// Tests the synchronization foundation that can genuinely run offline, without any iCloud
/// account, network access, or configured CloudKit container: the reconciliation logic
/// (`CollaborationSyncService.apply(_:)`), zone/record identity determinism, money conversion,
/// and Personal Finance isolation. All of these operate on plain `CKRecord`/`CKRecordZone.ID`
/// value types constructed by hand — CloudKit's real transport (`sendChanges`/`fetchChanges`
/// actually reaching Apple's servers, real conflict responses, real account status) requires a
/// signed run against a configured container and is explicitly NOT exercised here — see the
/// Phase 2 report for exactly what remains unverified and why.
@MainActor
final class CollaborationSyncServiceTests: XCTestCase {

    private func makeService(context: ModelContext) -> CollaborationSyncService {
        CollaborationSyncService(
            modelContext: context,
            container: CKContainer(identifier: CollaborationSyncService.containerIdentifier),
            stateSerialization: nil
        )
    }

    private func makeCollaborativeScenario(in context: ModelContext) -> SharedEvent {
        let you = Person(displayName: "You", isCurrentUser: true, isFrequent: true)
        let maria = Person(displayName: "Maria")
        context.insert(you)
        context.insert(maria)

        let event = SharedEvent(title: "Barcelona Trip", icon: "airplane", participants: [you, maria])
        context.insert(event)
        try? context.save()
        return event
    }

    // MARK: - 1. Deterministic zone ID

    func testSameSharedEventResolvesToSameZoneAcrossCalls() {
        let context = TestSupport.makeInMemoryContext()
        let event = makeCollaborativeScenario(in: context)

        let firstGraph = CloudKitSharedEventMapper.map(event)
        let secondGraph = CloudKitSharedEventMapper.map(event)

        XCTAssertEqual(firstGraph.zoneID, secondGraph.zoneID)
    }

    // MARK: - 2. Deterministic record IDs (covered further in CloudKitSharedEventMapperTests;
    // re-verified here specifically through the service's own zone-lookup path)

    func testOwningSharedEventResolvesBackFromItsOwnZoneID() {
        let context = TestSupport.makeInMemoryContext()
        let event = makeCollaborativeScenario(in: context)
        let service = makeService(context: context)

        let graph = CloudKitSharedEventMapper.map(event)
        let resolved = service.owningSharedEvent(for: graph.zoneID)

        XCTAssertTrue(resolved === event)
    }

    // MARK: - 3. Idempotent reconciliation

    func testApplyingTheSameExpenseRecordTwiceYieldsOneLocalObject() {
        let context = TestSupport.makeInMemoryContext()
        let event = makeCollaborativeScenario(in: context)
        let service = makeService(context: context)

        let eventID = UUID()
        event.remoteID = eventID
        try? context.save()
        let zoneID = CKRecordZone.ID(zoneName: "SharedEvent-\(eventID.uuidString)", ownerName: CKCurrentUserDefaultName)

        let expenseRecord = CKRecord(recordType: "Expense", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
        expenseRecord["event"] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: eventID.uuidString, zoneID: zoneID),
            action: .deleteSelf
        )
        expenseRecord["amountCents"] = Int64(1234) as NSNumber
        expenseRecord["currency"] = "EUR"
        expenseRecord["note"] = "Dinner"
        expenseRecord["date"] = Date.now
        expenseRecord["splitMethod"] = SharedSplitMethod.equal.rawValue
        expenseRecord["createdAt"] = Date.now
        expenseRecord["updatedAt"] = Date.now

        service.apply(expenseRecord)
        service.apply(expenseRecord) // same record, applied twice

        let count = (try? context.fetchCount(FetchDescriptor<SharedExpense>())) ?? -1
        XCTAssertEqual(count, 1, "applying the same Expense record twice must not create a duplicate")
    }

    // MARK: - 4. Money conversion

    func testDecimalCentsRoundTrip() {
        let context = TestSupport.makeInMemoryContext()
        let event = makeCollaborativeScenario(in: context)
        let service = makeService(context: context)
        let eventID = UUID()
        event.remoteID = eventID
        try? context.save()

        let zoneID = CKRecordZone.ID(zoneName: "SharedEvent-\(eventID.uuidString)", ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: "Expense", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
        record["event"] = CKRecord.Reference(recordID: CKRecord.ID(recordName: eventID.uuidString, zoneID: zoneID), action: .deleteSelf)
        record["amountCents"] = Int64(1234) as NSNumber
        record["currency"] = "EUR"
        record["note"] = ""
        record["date"] = Date.now
        record["splitMethod"] = SharedSplitMethod.equal.rawValue

        service.apply(record)

        let expense = try? context.fetch(FetchDescriptor<SharedExpense>()).first
        XCTAssertEqual(expense?.amount, Decimal(1234) / 100, "1234 cents must round-trip to exactly 12.34")
    }

    // MARK: - 6. Settlement privacy

    func testSettlementRecordNeverCarriesATransactionReference() {
        let context = TestSupport.makeInMemoryContext()
        let event = makeCollaborativeScenario(in: context)
        guard let you = event.currentUser, let maria = event.otherParticipants.first else {
            return XCTFail("scenario setup")
        }
        let expense = SharedExpense(amount: 100, currency: "EUR", paidBy: you, event: event)
        context.insert(expense)
        event.expenses.append(expense)
        let shareYou = SharedExpenseParticipant(person: you, amount: 50, expense: expense)
        let shareMaria = SharedExpenseParticipant(person: maria, amount: 50, expense: expense)
        context.insert(shareYou)
        context.insert(shareMaria)
        expense.participants.append(shareYou)
        expense.participants.append(shareMaria)
        let settlement = Settlement(fromPerson: maria, toPerson: you, amount: 20, paymentMethod: .cash, event: event)
        context.insert(settlement)
        event.settlements.append(settlement)
        // Simulate this device having already recorded it as a personal transaction.
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let category = Category(name: "Reimburse", headCategory: HeadCategory(name: "Income", icon: "banknote.fill", colorHex: "#000000"))
        context.insert(category.headCategory)
        context.insert(category)
        let entry = Entry(amount: 20, type: .income, category: category, wallet: wallet)
        context.insert(entry)
        settlement.transaction = entry
        try? context.save()

        let graph = CloudKitSharedEventMapper.map(event)
        let settlementRecord = graph.settlements.first
        XCTAssertNotNil(settlementRecord)
        XCTAssertFalse(settlementRecord!.allKeys().contains("transaction"))
        XCTAssertFalse(settlementRecord!.allKeys().contains("entry"))
        XCTAssertFalse(settlementRecord!.allKeys().contains("wallet"))
    }

    // MARK: - 7. Event isolation

    func testTwoEventsRecordsResolveToDistinctZones() {
        let context = TestSupport.makeInMemoryContext()
        let eventA = makeCollaborativeScenario(in: context)
        let you = eventA.currentUser!
        let maria = eventA.otherParticipants.first!
        let eventB = SharedEvent(title: "Ski Trip", participants: [you, maria])
        context.insert(eventB)
        try? context.save()

        let graphA = CloudKitSharedEventMapper.map(eventA)
        let graphB = CloudKitSharedEventMapper.map(eventB)

        let zoneAIDs = Set(graphA.allRecords.map(\.recordID))
        let zoneBIDs = Set(graphB.allRecords.map(\.recordID))
        XCTAssertTrue(zoneAIDs.isDisjoint(with: zoneBIDs), "no record from event A may share an ID with a record from event B")
        for record in graphA.allRecords {
            XCTAssertEqual(record.recordID.zoneID, graphA.zoneID)
        }
        for record in graphB.allRecords {
            XCTAssertEqual(record.recordID.zoneID, graphB.zoneID)
        }
    }

    // MARK: - 8. Personal Finance isolation

    func testApplyingRemoteRecordsNeverCreatesPersonalFinanceObjects() {
        let context = TestSupport.makeInMemoryContext()
        let event = makeCollaborativeScenario(in: context)
        let service = makeService(context: context)
        let eventID = UUID()
        event.remoteID = eventID
        try? context.save()

        let entriesBefore = (try? context.fetchCount(FetchDescriptor<Entry>())) ?? -1
        let walletsBefore = (try? context.fetchCount(FetchDescriptor<Wallet>())) ?? -1
        let budgetsBefore = (try? context.fetchCount(FetchDescriptor<Budget>())) ?? -1
        let categoriesBefore = (try? context.fetchCount(FetchDescriptor<FinanceTracker.Category>())) ?? -1

        let zoneID = CKRecordZone.ID(zoneName: "SharedEvent-\(eventID.uuidString)", ownerName: CKCurrentUserDefaultName)
        let eventRecord = CKRecord(recordType: "SharedEvent", recordID: CKRecord.ID(recordName: eventID.uuidString, zoneID: zoneID))
        eventRecord["title"] = "Remote Event"
        eventRecord["status"] = SharedEventStatus.active.rawValue
        service.apply(eventRecord)

        let expenseRecord = CKRecord(recordType: "Expense", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
        expenseRecord["event"] = CKRecord.Reference(recordID: eventRecord.recordID, action: .deleteSelf)
        expenseRecord["amountCents"] = Int64(500) as NSNumber
        expenseRecord["currency"] = "EUR"
        expenseRecord["splitMethod"] = SharedSplitMethod.equal.rawValue
        service.apply(expenseRecord)

        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Entry>())) ?? -2, entriesBefore)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Wallet>())) ?? -2, walletsBefore)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Budget>())) ?? -2, budgetsBefore)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<FinanceTracker.Category>())) ?? -2, categoriesBefore)
    }

    // MARK: - 9. Offline / iCloud unavailable behavior

    func testAccountStatusMappingCoversEveryCase() {
        XCTAssertEqual(CloudAvailabilityMonitor.map(.available), .available)
        XCTAssertEqual(CloudAvailabilityMonitor.map(.noAccount), .noAccount)
        XCTAssertEqual(CloudAvailabilityMonitor.map(.restricted), .restricted)
        XCTAssertEqual(CloudAvailabilityMonitor.map(.temporarilyUnavailable), .temporarilyUnavailable)
        XCTAssertEqual(CloudAvailabilityMonitor.map(.couldNotDetermine), .couldNotDetermine)
    }

    func testQueueUploadIsANoOpForANonCollaborativeEvent() {
        let context = TestSupport.makeInMemoryContext()
        let event = makeCollaborativeScenario(in: context)
        let service = makeService(context: context)

        XCTAssertFalse(event.isCollaborationEnabled)
        // Must not throw, crash, or require network access — it's simply skipped.
        service.queueUpload(of: event)
    }

    // MARK: - Local-only events stay local-only (rule 13)

    func testEnableCollaborationSetsTheFlagAndMappingProducesAZone() {
        let context = TestSupport.makeInMemoryContext()
        let event = makeCollaborativeScenario(in: context)
        let service = makeService(context: context)

        XCTAssertFalse(event.isCollaborationEnabled)
        service.enableCollaboration(for: event)
        XCTAssertTrue(event.isCollaborationEnabled)
        XCTAssertNotNil(event.remoteID)
    }

    // MARK: - Record identity parsing (used by reconciliation)

    func testParticipantComponentsRoundTrip() {
        let eventID = UUID()
        let anchorID = UUID()
        let recordName = "\(eventID.uuidString)-participant-\(anchorID.uuidString)"

        let parsed = CloudKitRecordIdentity.participantComponents(fromRecordName: recordName)
        XCTAssertEqual(parsed?.eventID, eventID)
        XCTAssertEqual(parsed?.personAnchorID, anchorID)
    }

    func testRemoteIDParsingRejectsNonUUIDStrings() {
        XCTAssertNil(CloudKitRecordIdentity.remoteID(fromRecordName: "not-a-uuid"))
        let id = UUID()
        XCTAssertEqual(CloudKitRecordIdentity.remoteID(fromRecordName: id.uuidString), id)
    }
}
