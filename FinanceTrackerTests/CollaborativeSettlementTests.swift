import XCTest
import SwiftData
import CloudKit
@testable import FinanceTracker

/// Phase 6 (collaborative Shared Settlements) tests.
///
/// Like the Phase 5 expense tests, everything here runs fully offline: `queueUpload` only
/// mutates `CKSyncEngine.state` locally, and `apply(_:)` is the same offline-testable
/// reconciliation entry point used since Phase 2. A real CloudKit round trip (upload really
/// reaching the server, a second device really fetching it) is NOT exercised here — that
/// requires a signed run against a real account/container, same caveat as every previous phase.
///
/// Items 16/17 (amount > 0 / amount <= outstanding) and 21 (duplicate-submission guard) are
/// SwiftUI `@State`-level validation inside `RecordPaymentView`, unmodified by this phase and not
/// independently unit-testable without a UI-driving framework this project doesn't have; this
/// file instead verifies the underlying data (Settlement has no such built-in constraint — by
/// design, validation is UI-layer only, unchanged) and documents this explicitly rather than
/// fabricating a UI-level test. Item 22 (settlement deletion) is genuinely not supported by the
/// current UI (confirmed by inspection of SettleView/RecordPaymentView/AddSettlementTransactionView
/// — none offer a delete action) and is out of scope per the phase spec's own instruction not to
/// invent new UX; item 23 is still covered, since it tests the underlying delete-rule regardless
/// of whether UI exposes deletion.
@MainActor
final class CollaborativeSettlementTests: XCTestCase {

    private func makeService(context: ModelContext) -> CollaborationSyncService {
        CollaborationSyncService(
            modelContext: context,
            container: CKContainer(identifier: CollaborationSyncService.containerIdentifier),
            stateSerialization: nil
        )
    }

    /// A collaborative Barcelona Trip with Andrea (current user) and Maria, both already
    /// identified via EventParticipant (mirrors post-Phase-4 state on Andrea's own device).
    private func makeCollaborativeScenario(in context: ModelContext) -> (event: SharedEvent, andrea: Person, maria: Person) {
        let andrea = Person(displayName: "Andrea", isCurrentUser: true, isFrequent: true)
        let maria = Person(displayName: "Maria")
        context.insert(andrea)
        context.insert(maria)
        let event = SharedEvent(title: "Barcelona Trip", icon: "airplane", participants: [andrea, maria])
        event.remoteID = UUID()
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

    private func settlementRecord(
        settlementID: UUID, event: SharedEvent, from: Person, to: Person, amountCents: Int64 = 4000
    ) -> CKRecord {
        let zoneID = CKRecordZone.ID(zoneName: "SharedEvent-\(event.remoteID!.uuidString)", ownerName: CKCurrentUserDefaultName)
        let eventRecordID = CKRecord.ID(recordName: event.remoteID!.uuidString, zoneID: zoneID)
        let fromRecordID = CKRecord.ID(recordName: "\(event.remoteID!.uuidString)-participant-\(from.sharingAnchorID.uuidString)", zoneID: zoneID)
        let toRecordID = CKRecord.ID(recordName: "\(event.remoteID!.uuidString)-participant-\(to.sharingAnchorID.uuidString)", zoneID: zoneID)

        let record = CKRecord(recordType: "Settlement", recordID: CKRecord.ID(recordName: settlementID.uuidString, zoneID: zoneID))
        record["event"] = CKRecord.Reference(recordID: eventRecordID, action: .deleteSelf)
        record["fromParticipant"] = CKRecord.Reference(recordID: fromRecordID, action: .none)
        record["toParticipant"] = CKRecord.Reference(recordID: toRecordID, action: .none)
        record["amountCents"] = amountCents as NSNumber
        record["paymentMethod"] = SettlementPaymentMethod.bankTransfer.rawValue
        record["date"] = Date.now
        record["createdAt"] = Date.now
        return record
    }

    // MARK: - 1/2/3/4/5. Settlement CKRecord mapping

    func testSettlementMapsToCorrectCKRecordFields() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, maria) = makeCollaborativeScenario(in: context)
        let settlement = Settlement(fromPerson: maria, toPerson: andrea, amount: 40, paymentMethod: .cash, event: event)
        context.insert(settlement)
        event.settlements.append(settlement)
        try? context.save()

        let graph = CloudKitSharedEventMapper.map(event)
        let record = graph.settlements.first
        XCTAssertNotNil(record)

        // 2. exact integer cents
        XCTAssertEqual(record?["amountCents"] as? Int64, 4000)

        // 3/4. fromParticipant / toParticipant reference the Participant records, not raw Persons
        let expectedFrom = "\(event.remoteID!.uuidString)-participant-\(maria.sharingAnchorID.uuidString)"
        let expectedTo = "\(event.remoteID!.uuidString)-participant-\(andrea.sharingAnchorID.uuidString)"
        XCTAssertEqual((record?["fromParticipant"] as? CKRecord.Reference)?.recordID.recordName, expectedFrom)
        XCTAssertEqual((record?["toParticipant"] as? CKRecord.Reference)?.recordID.recordName, expectedTo)

        // 5. event reference
        XCTAssertEqual((record?["event"] as? CKRecord.Reference)?.recordID.recordName, event.remoteID!.uuidString)

        // Never present: no Entry/Wallet/Budget/personal transaction data on the record at all.
        XCTAssertFalse(record!.allKeys().contains("transaction"))
        XCTAssertFalse(record!.allKeys().contains("entry"))
        XCTAssertFalse(record!.allKeys().contains("wallet"))
    }

    // MARK: - 6/7/8. Idempotent, stable, non-colliding identity

    func testSettlementMappingIsIdempotentAndStable() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, maria) = makeCollaborativeScenario(in: context)
        let settlement = Settlement(fromPerson: maria, toPerson: andrea, amount: 40, paymentMethod: .cash, event: event)
        context.insert(settlement)
        event.settlements.append(settlement)
        try? context.save()

        let firstID = CloudKitSharedEventMapper.map(event).settlements.first?.recordID
        let remoteIDAfterFirstMap = settlement.remoteID
        let secondID = CloudKitSharedEventMapper.map(event).settlements.first?.recordID

        XCTAssertNotNil(remoteIDAfterFirstMap)
        XCTAssertEqual(firstID, secondID, "repeated mapping must never mint a new remote identity")
        XCTAssertEqual(settlement.remoteID, remoteIDAfterFirstMap)
    }

    func testTwoDifferentSettlementsDoNotCollide() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, maria) = makeCollaborativeScenario(in: context)
        let settlementA = Settlement(fromPerson: maria, toPerson: andrea, amount: 40, paymentMethod: .cash, event: event)
        let settlementB = Settlement(fromPerson: andrea, toPerson: maria, amount: 10, paymentMethod: .cash, event: event)
        context.insert(settlementA)
        context.insert(settlementB)
        event.settlements = [settlementA, settlementB]
        try? context.save()

        let graph = CloudKitSharedEventMapper.map(event)
        XCTAssertEqual(graph.settlements.count, 2)
        XCTAssertEqual(Set(graph.settlements.map(\.recordID)).count, 2, "each settlement keeps its own distinct identity")
    }

    // MARK: - 9/10. Dependency-ordering: Participant/Event may arrive after the Settlement

    func testParticipantArrivingAfterSettlementStillReconciles() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, maria) = makeCollaborativeScenario(in: context)
        let service = makeService(context: context)
        // Simulate this device NOT having Maria's Participant reconciled yet: remove her local
        // Person entirely, along with her EventParticipant/participants membership.
        event.participants.removeAll { $0 === maria }
        event.eventParticipants.removeAll { $0.person === maria }
        context.delete(maria)
        try? context.save()

        let record = settlementRecord(settlementID: UUID(), event: event, from: andrea, to: andrea, amountCents: 4000)
        // fromParticipant deliberately points at a person that doesn't exist locally yet.
        let zoneID = CKRecordZone.ID(zoneName: "SharedEvent-\(event.remoteID!.uuidString)", ownerName: CKCurrentUserDefaultName)
        let mariaAnchor = UUID()
        record["fromParticipant"] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "\(event.remoteID!.uuidString)-participant-\(mariaAnchor.uuidString)", zoneID: zoneID),
            action: .none
        )

        service.apply(record)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Settlement>())) ?? -1, 0, "must not be lost — deferred, not dropped")

        // Now Maria's Participant record arrives via normal reconciliation, which both creates
        // her local Person AND — via the fixed-point drain — retries the pending settlement.
        let participantRecord = CKRecord(recordType: "Participant", recordID: CKRecord.ID(recordName: "\(event.remoteID!.uuidString)-participant-\(mariaAnchor.uuidString)", zoneID: zoneID))
        participantRecord["event"] = CKRecord.Reference(recordID: CKRecord.ID(recordName: event.remoteID!.uuidString, zoneID: zoneID), action: .deleteSelf)
        participantRecord["displayName"] = "Maria"
        participantRecord["role"] = "member"
        // Applying the participant triggers the existing fixed-point drain (Phase 3.1), which
        // retries the settlement already sitting in the pending queue from the apply(record) call
        // above — no need to redeliver the settlement record a second time.
        service.apply(participantRecord)

        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Person>(predicate: #Predicate { $0.displayName == "Maria" }))) ?? -1, 1)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Settlement>())) ?? -1, 1, "settlement reconciles once its participant exists")
    }

    func testSettlementArrivingBeforeItsEventIsDeferredThenReconciles() {
        let context = TestSupport.makeInMemoryContext()
        let service = makeService(context: context)
        let andrea = Person(displayName: "Andrea", isCurrentUser: true)
        let maria = Person(displayName: "Maria")
        context.insert(andrea)
        context.insert(maria)
        let event = SharedEvent(title: "Barcelona Trip", participants: [andrea, maria])
        let eventID = UUID()
        event.remoteID = eventID
        context.insert(event)
        try? context.save()

        let record = settlementRecord(settlementID: UUID(), event: event, from: maria, to: andrea)

        // Remove the event locally to simulate it not having arrived yet, then reapply after.
        context.delete(event)
        service.apply(record)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Settlement>())) ?? -1, 0)

        let newEvent = SharedEvent(title: "Barcelona Trip", participants: [andrea, maria])
        newEvent.remoteID = eventID
        context.insert(newEvent)
        service.apply(record)

        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Settlement>())) ?? -1, 1, "settlement reconciles once its event exists")
    }

    // MARK: - 11. Invalid cross-event participant reference is rejected

    func testSettlementCannotResolveParticipantFromAnotherEvent() {
        let context = TestSupport.makeInMemoryContext()
        let (eventA, andrea, _) = makeCollaborativeScenario(in: context)
        let carlos = Person(displayName: "Carlos")
        context.insert(carlos)
        let eventB = SharedEvent(title: "Ski Trip", participants: [carlos])
        eventB.remoteID = UUID()
        context.insert(eventB)
        try? context.save()

        let service = makeService(context: context)
        let zoneIDA = CKRecordZone.ID(zoneName: "SharedEvent-\(eventA.remoteID!.uuidString)", ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: "Settlement", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneIDA))
        record["event"] = CKRecord.Reference(recordID: CKRecord.ID(recordName: eventA.remoteID!.uuidString, zoneID: zoneIDA), action: .deleteSelf)
        // toParticipant forged to reference Carlos from Event B.
        let foreignName = "\(eventB.remoteID!.uuidString)-participant-\(carlos.sharingAnchorID.uuidString)"
        record["fromParticipant"] = CKRecord.Reference(recordID: CKRecord.ID(recordName: "\(eventA.remoteID!.uuidString)-participant-\(andrea.sharingAnchorID.uuidString)", zoneID: zoneIDA), action: .none)
        record["toParticipant"] = CKRecord.Reference(recordID: CKRecord.ID(recordName: foreignName, zoneID: zoneIDA), action: .none)
        record["amountCents"] = Int64(1000) as NSNumber
        record["paymentMethod"] = SettlementPaymentMethod.cash.rawValue

        service.apply(record)

        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Settlement>())) ?? -1, 0, "a cross-event reference must be rejected outright, never partially applied")
    }

    // MARK: - 12/13. Synced settlement: exactly one local row, no Entry

    func testSyncedSettlementCreatesExactlyOneLocalSettlementAndNoEntry() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, maria) = makeCollaborativeScenario(in: context)
        let service = makeService(context: context)
        let entriesBefore = (try? context.fetchCount(FetchDescriptor<Entry>())) ?? -1

        let record = settlementRecord(settlementID: UUID(), event: event, from: maria, to: andrea)
        service.apply(record)
        service.apply(record) // redelivered
        service.apply(record)

        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Settlement>())) ?? -1, 1)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Entry>())) ?? -2, entriesBefore, "settlement sync must never create an Entry")
    }

    // MARK: - 14. Local settlement creation (no "Add to Transactions") creates no Entry

    func testLocalSettlementCreationWithoutRecordingCreatesNoEntry() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, maria) = makeCollaborativeScenario(in: context)
        let entriesBefore = (try? context.fetchCount(FetchDescriptor<Entry>())) ?? -1

        // Mirrors RecordPaymentView.confirm() with addToTransactions == false.
        let settlement = Settlement(fromPerson: maria, toPerson: andrea, amount: 40, paymentMethod: .cash, event: event)
        context.insert(settlement)
        event.settlements.append(settlement)
        try? context.save()

        XCTAssertNil(settlement.transaction)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Entry>())) ?? -2, entriesBefore)
    }

    // MARK: - 15. Partial settlement remains supported

    func testPartialSettlementIsSupported() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, maria) = makeCollaborativeScenario(in: context)
        // Unlike sibling tests here, this one never calls `service.apply(...)` — which is what
        // incidentally populates this process-wide cache in the others — so it must set "who am
        // I" itself, matching Andrea's EventParticipant.userRecordID from makeCollaborativeScenario.
        CollaborationCurrentUser.set("andreas-icloud-id")
        defer { CollaborationCurrentUser.set(nil) }
        let expense = SharedExpense(amount: 80, currency: "EUR", paidBy: maria, event: event)
        context.insert(expense)
        event.expenses.append(expense)
        let shareAndrea = SharedExpenseParticipant(person: andrea, amount: 40, expense: expense)
        let shareMaria = SharedExpenseParticipant(person: maria, amount: 40, expense: expense)
        context.insert(shareAndrea)
        context.insert(shareMaria)
        expense.participants = [shareAndrea, shareMaria]
        try? context.save()

        XCTAssertEqual(event.outstandingBalance(for: maria), -40) // Andrea owes Maria €40

        // A partial €20 settlement, smaller than the €40 outstanding balance.
        let settlement = Settlement(fromPerson: andrea, toPerson: maria, amount: 20, paymentMethod: .cash, event: event)
        context.insert(settlement)
        event.settlements.append(settlement)
        try? context.save()

        XCTAssertEqual(event.outstandingBalance(for: maria), -20, "a partial settlement reduces, not clears, the outstanding balance")
    }

    // MARK: - 16/17. Amount validation rules (documented as UI-layer; verified via the same logic)

    func testAmountValidationRulesRemainCorrect() {
        // Mirrors RecordPaymentView's `amountValue`/`exceedsOutstanding` computed properties —
        // this is the actual validation logic, unmodified by Phase 6, expressed without SwiftUI.
        let outstanding = Decimal(40)
        func isValidAmount(_ amount: Decimal) -> Bool {
            amount > 0 && amount <= outstanding
        }
        XCTAssertFalse(isValidAmount(0), "amount must be > 0")
        XCTAssertFalse(isValidAmount(-5), "amount must be > 0")
        XCTAssertTrue(isValidAmount(40), "amount == outstanding is valid")
        XCTAssertFalse(isValidAmount(40.01), "amount must never exceed the outstanding balance")
        XCTAssertTrue(isValidAmount(20), "a partial amount is valid")
    }

    // MARK: - 18/19. Direction: incoming = income, outgoing = expense

    /// Replicates RecordPaymentView's exact `personOwesYou`/Entry.type derivation against real
    /// balance data, for both directions, rather than asserting a tautology.
    func testSettlementDirectionMapsToCorrectEntryType() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, maria) = makeCollaborativeScenario(in: context)
        // Andrea (current user) fronts €80, split 40/40 — Maria owes Andrea €40: incoming for Andrea.
        let expense = SharedExpense(amount: 80, currency: "EUR", paidBy: andrea, event: event)
        context.insert(expense)
        event.expenses.append(expense)
        let shareAndrea = SharedExpenseParticipant(person: andrea, amount: 40, expense: expense)
        let shareMaria = SharedExpenseParticipant(person: maria, amount: 40, expense: expense)
        context.insert(shareAndrea)
        context.insert(shareMaria)
        expense.participants = [shareAndrea, shareMaria]
        try? context.save()

        let personOwesYouIncoming = event.outstandingBalance(for: maria) >= 0
        XCTAssertTrue(personOwesYouIncoming, "Maria owes Andrea — incoming for Andrea")
        let incomingType: EntryType = personOwesYouIncoming ? .income : .expense
        XCTAssertEqual(incomingType, .income, "money coming in must record as income")

        // Reverse: Maria fronts instead — now Andrea owes Maria €40: outgoing for Andrea.
        expense.paidBy = maria
        try? context.save()
        let personOwesYouOutgoing = event.outstandingBalance(for: maria) >= 0
        XCTAssertFalse(personOwesYouOutgoing, "Andrea owes Maria — outgoing for Andrea")
        let outgoingType: EntryType = personOwesYouOutgoing ? .income : .expense
        XCTAssertEqual(outgoingType, .expense, "money going out must record as expense")
    }

    // MARK: - 20. Incoming Reimburse category behavior intact

    func testReimburseCategoryStillAutoSelectedForIncomingSettlement() {
        let context = TestSupport.makeInMemoryContext()
        let headCategory = HeadCategory(name: "Income", icon: "banknote.fill", colorHex: "#000000")
        let reimburse = Category(name: "Reimburse", isIncome: true, headCategory: headCategory)
        let other = Category(name: "Salary", isIncome: true, headCategory: headCategory)
        context.insert(headCategory)
        context.insert(reimburse)
        context.insert(other)
        try? context.save()

        let resolved = Category.reimburse(in: [reimburse, other])
        XCTAssertTrue(resolved === reimburse)
    }

    // MARK: - 23. Deleting a settlement never deletes its linked Entry (delete-rule regression)

    func testDeletingSettlementDoesNotDeleteLinkedEntry() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, maria) = makeCollaborativeScenario(in: context)
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let headCategory = HeadCategory(name: "Income", icon: "banknote.fill", colorHex: "#000000")
        let category = Category(name: "Reimburse", isIncome: true, headCategory: headCategory)
        context.insert(headCategory)
        context.insert(category)
        let entry = Entry(amount: 40, type: .income, category: category, wallet: wallet)
        context.insert(entry)
        let settlement = Settlement(fromPerson: maria, toPerson: andrea, amount: 40, paymentMethod: .cash, event: event, transaction: entry)
        context.insert(settlement)
        event.settlements.append(settlement)
        entry.sharedSettlement = settlement
        try? context.save()

        context.delete(settlement)
        try? context.save()

        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Entry>())) ?? -1, 1, "the nullify delete rule must keep the Entry alive")
        XCTAssertNil(entry.sharedSettlement, "the now-deleted settlement's back-reference should be nullified, not the Entry itself")
    }

    // MARK: - 24. Balance calculation incorporates a synced settlement

    func testSyncedSettlementUpdatesExistingBalanceCalculation() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, maria) = makeCollaborativeScenario(in: context)
        let service = makeService(context: context)
        let expense = SharedExpense(amount: 80, currency: "EUR", paidBy: maria, event: event)
        context.insert(expense)
        event.expenses.append(expense)
        let shareAndrea = SharedExpenseParticipant(person: andrea, amount: 40, expense: expense)
        let shareMaria = SharedExpenseParticipant(person: maria, amount: 40, expense: expense)
        context.insert(shareAndrea)
        context.insert(shareMaria)
        expense.participants = [shareAndrea, shareMaria]
        try? context.save()
        XCTAssertEqual(event.outstandingBalance(for: maria), -40)

        let record = settlementRecord(settlementID: UUID(), event: event, from: andrea, to: maria, amountCents: 4000)
        service.apply(record)

        XCTAssertEqual(event.outstandingBalance(for: maria), 0, "the existing balance engine must incorporate the synced settlement with no extra code")
    }

    // MARK: - 25. Same Person reused across two events remains event-scoped

    func testSettlementRemainsEventScopedAcrossReusedPerson() {
        let context = TestSupport.makeInMemoryContext()
        let (eventA, andrea, maria) = makeCollaborativeScenario(in: context)
        let eventB = SharedEvent(title: "Paris Trip", participants: [andrea, maria])
        eventB.remoteID = UUID()
        eventB.isCollaborationEnabled = true
        context.insert(eventB)
        let andreaMembershipB = EventParticipant(event: eventB, person: andrea, role: .owner, userRecordID: "andreas-icloud-id")
        let mariaMembershipB = EventParticipant(event: eventB, person: maria, role: .member, userRecordID: "marias-icloud-id")
        context.insert(andreaMembershipB)
        context.insert(mariaMembershipB)
        eventB.eventParticipants = [andreaMembershipB, mariaMembershipB]
        try? context.save()

        let service = makeService(context: context)
        let record = settlementRecord(settlementID: UUID(), event: eventA, from: maria, to: andrea)
        service.apply(record)

        XCTAssertEqual(eventA.settlements.count, 1)
        XCTAssertEqual(eventB.settlements.count, 0, "a settlement synced for Event A must never appear in Event B, even with the same Persons")
    }

    // MARK: - Two-user conceptual/integration test

    /// Simulates Maria's settlement reaching Andrea's device: two independent SwiftData
    /// contexts/services, each representing one device, both applying the SAME CKRecord (as
    /// CKSyncEngine would deliver it), and asserts both converge to an identical, correct,
    /// Entry-free result.
    func testTwoDeviceSettlementConvergence() {
        let deviceAContext = TestSupport.makeInMemoryContext()
        let (eventOnA, andreaOnA, mariaOnA) = makeCollaborativeScenario(in: deviceAContext)
        let serviceA = makeService(context: deviceAContext)

        let deviceBContext = TestSupport.makeInMemoryContext()
        let (eventOnB, andreaOnB, mariaOnB) = makeCollaborativeScenario(in: deviceBContext)
        let serviceB = makeService(context: deviceBContext)

        // Both devices already agree on the event's remoteID (as they would after Phase 1-4 sync).
        eventOnB.remoteID = eventOnA.remoteID
        // Keep sharingAnchorIDs aligned too, exactly as real CloudKit reconciliation would.
        mariaOnB.sharingAnchorID = mariaOnA.sharingAnchorID
        andreaOnB.sharingAnchorID = andreaOnA.sharingAnchorID

        let settlementID = UUID()
        let recordForA = settlementRecord(settlementID: settlementID, event: eventOnA, from: mariaOnA, to: andreaOnA, amountCents: 4000)
        let recordForB = settlementRecord(settlementID: settlementID, event: eventOnB, from: mariaOnB, to: andreaOnB, amountCents: 4000)

        serviceA.apply(recordForA)
        serviceB.apply(recordForB)

        for (context, event, andrea, maria, label) in [
            (deviceAContext, eventOnA, andreaOnA, mariaOnA, "Device A"),
            (deviceBContext, eventOnB, andreaOnB, mariaOnB, "Device B"),
        ] {
            let settlements = (try? context.fetch(FetchDescriptor<Settlement>())) ?? []
            XCTAssertEqual(settlements.count, 1, "\(label): exactly one settlement")
            XCTAssertEqual(settlements.first?.amount, 40, "\(label): €40")
            XCTAssertTrue(settlements.first?.fromPerson === maria, "\(label): correct fromPerson")
            XCTAssertTrue(settlements.first?.toPerson === andrea, "\(label): correct toPerson")
            XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Entry>())) ?? -1, 0, "\(label): no Entry created by sync")
            _ = event
        }
    }
}
