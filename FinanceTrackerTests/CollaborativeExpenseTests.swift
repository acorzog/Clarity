import XCTest
import SwiftData
import CloudKit
@testable import FinanceTracker

/// Phase 5 (collaborative Shared Expenses) tests.
///
/// Everything here runs fully offline: `queueUpload`/`queueDeletion`/`queueRemovalOfExpenseParticipants`
/// only mutate `CKSyncEngine.state` locally (no network — network only happens inside
/// `sendChanges()`, never called here), and `apply(_:)` is the same offline-testable
/// reconciliation entry point used since Phase 2. The one thing genuinely NOT exercised here is
/// an actual CloudKit round trip (an upload really reaching the server, a second device really
/// fetching it) — that requires a signed run against a real account/container, same caveat as
/// every previous phase.
@MainActor
final class CollaborativeExpenseTests: XCTestCase {

    private func makeService(context: ModelContext) -> CollaborationSyncService {
        CollaborationSyncService(
            modelContext: context,
            container: CKContainer(identifier: CollaborationSyncService.containerIdentifier),
            stateSerialization: nil
        )
    }

    /// A collaborative Barcelona Trip with Andrea (current user) and Maria, both already
    /// identified via EventParticipant (mirrors post-Phase-4 state on both devices).
    private func makeCollaborativeScenario(in context: ModelContext) -> (event: SharedEvent, andrea: Person, maria: Person, andreaMembership: EventParticipant, mariaMembership: EventParticipant) {
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
        return (event, andrea, maria, andreaMembership, mariaMembership)
    }

    private func expenseAndSharesRecord(
        expenseID: UUID, event: SharedEvent, payer: Person, amountCents: Int64 = 8000
    ) -> (expense: CKRecord, shares: [CKRecord]) {
        let zoneID = CKRecordZone.ID(zoneName: "SharedEvent-\(event.remoteID!.uuidString)", ownerName: CKCurrentUserDefaultName)
        let eventRecordID = CKRecord.ID(recordName: event.remoteID!.uuidString, zoneID: zoneID)
        let expenseRecordID = CKRecord.ID(recordName: expenseID.uuidString, zoneID: zoneID)
        let payerRecordID = CKRecord.ID(recordName: "\(event.remoteID!.uuidString)-participant-\(payer.sharingAnchorID.uuidString)", zoneID: zoneID)

        let expense = CKRecord(recordType: "Expense", recordID: expenseRecordID)
        expense["event"] = CKRecord.Reference(recordID: eventRecordID, action: .deleteSelf)
        expense["amountCents"] = amountCents as NSNumber
        expense["currency"] = "EUR"
        expense["note"] = "Dinner"
        expense["date"] = Date.now
        expense["splitMethod"] = SharedSplitMethod.equal.rawValue
        expense["paidBy"] = CKRecord.Reference(recordID: payerRecordID, action: .none)
        expense["categoryName"] = "Restaurant"
        expense["categoryIcon"] = "fork.knife"
        expense["categoryColorHex"] = "#FF0000"

        var shares: [CKRecord] = []
        for participant in event.participants {
            let participantRecordID = CKRecord.ID(recordName: "\(event.remoteID!.uuidString)-participant-\(participant.sharingAnchorID.uuidString)", zoneID: zoneID)
            let share = CKRecord(recordType: "ExpenseParticipant", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
            share["expense"] = CKRecord.Reference(recordID: expenseRecordID, action: .deleteSelf)
            share["participant"] = CKRecord.Reference(recordID: participantRecordID, action: .none)
            share["amountCents"] = (amountCents / Int64(event.participants.count)) as NSNumber
            shares.append(share)
        }
        return (expense, shares)
    }

    // MARK: - A/S. Local collaborative expense creation (offline, no network required)

    func testLocalCollaborativeExpenseCreationQueuesUploadWithoutNetwork() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, maria, _, _) = makeCollaborativeScenario(in: context)
        let service = makeService(context: context)

        let expense = SharedExpense(amount: 80, currency: "EUR", note: "Dinner", paidBy: maria, event: event)
        context.insert(expense)
        event.expenses.append(expense)
        let shareAndrea = SharedExpenseParticipant(person: andrea, amount: 40, expense: expense)
        let shareMaria = SharedExpenseParticipant(person: maria, amount: 40, expense: expense)
        context.insert(shareAndrea)
        context.insert(shareMaria)
        expense.participants = [shareAndrea, shareMaria]
        try? context.save()

        // queueUpload only mutates local CKSyncEngine.state — no network call.
        service.queueUpload(of: event)

        XCTAssertNotNil(expense.remoteID, "uploading mints a stable remoteID")
        let graph = CloudKitSharedEventMapper.map(event)
        XCTAssertTrue(graph.expenses.contains { $0.recordID.recordName == expense.remoteID!.uuidString })
        XCTAssertEqual(graph.expenseParticipants.count, 2)
    }

    // MARK: - B. Payer resolves to the event-scoped Participant record, not raw Person data

    func testExpensePaidByReferencesParticipantRecordNotPerson() {
        let context = TestSupport.makeInMemoryContext()
        let (event, _, maria, _, _) = makeCollaborativeScenario(in: context)

        let expense = SharedExpense(amount: 80, currency: "EUR", paidBy: maria, event: event)
        context.insert(expense)
        event.expenses.append(expense)
        try? context.save()

        let graph = CloudKitSharedEventMapper.map(event)
        let expenseRecord = graph.expenses.first { $0.recordID.recordName == expense.remoteID!.uuidString }
        let payerReference = expenseRecord?["paidBy"] as? CKRecord.Reference
        let expectedPayerName = "\(event.remoteID!.uuidString)-participant-\(maria.sharingAnchorID.uuidString)"

        XCTAssertEqual(payerReference?.recordID.recordName, expectedPayerName, "paidBy must reference the Participant record, never a raw Person identifier")
    }

    // MARK: - C. Current user's EventParticipant resolves correctly for default-payer use

    func testCurrentUsersEventParticipantResolvesForDefaultPayer() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, _, _, _) = makeCollaborativeScenario(in: context)

        // This is exactly what AddSharedExpenseView.resolveDefaultPayerIfNeeded() composes.
        let defaultPayer = event.currentParticipant(for: "andreas-icloud-id")?.person
        XCTAssertTrue(defaultPayer === andrea)
    }

    // MARK: - D/E/F. Splits remain deterministic, cent-exact, and sum exactly to the total

    func testEqualSplitIsCentExactAndSumsToTotal() {
        let shares = SharedSplitCalculator.equalSplit(total: 100, count: 3)
        XCTAssertEqual(shares, [Decimal(string: "33.34")!, Decimal(string: "33.33")!, Decimal(string: "33.33")!])
        XCTAssertEqual(shares.reduce(0, +), 100)
    }

    func testUnequalPartsSplitIsCentExactAndSumsToTotal() {
        let shares = SharedSplitCalculator.partsSplit(total: 100, parts: [1, 1, 2])
        XCTAssertEqual(shares.reduce(0, +), 100)
        XCTAssertEqual(shares[2], shares[0] + shares[1]) // the 2-part share equals the sum of two 1-part shares
    }

    // MARK: - G/H. Deterministic Expense/ExpenseParticipant identity

    func testExpenseMapsToDeterministicRecordIDAcrossRepeatedCalls() {
        let context = TestSupport.makeInMemoryContext()
        let (event, _, maria, _, _) = makeCollaborativeScenario(in: context)
        let expense = SharedExpense(amount: 80, currency: "EUR", paidBy: maria, event: event)
        context.insert(expense)
        event.expenses.append(expense)
        try? context.save()

        let firstID = CloudKitSharedEventMapper.map(event).expenses.first?.recordID
        let secondID = CloudKitSharedEventMapper.map(event).expenses.first?.recordID
        XCTAssertEqual(firstID, secondID)
    }

    func testExpenseParticipantRecordsReferenceCorrectParticipants() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, maria, _, _) = makeCollaborativeScenario(in: context)
        let expense = SharedExpense(amount: 80, currency: "EUR", paidBy: maria, event: event)
        context.insert(expense)
        event.expenses.append(expense)
        let shareAndrea = SharedExpenseParticipant(person: andrea, amount: 40, expense: expense)
        let shareMaria = SharedExpenseParticipant(person: maria, amount: 40, expense: expense)
        context.insert(shareAndrea)
        context.insert(shareMaria)
        expense.participants = [shareAndrea, shareMaria]
        try? context.save()

        let graph = CloudKitSharedEventMapper.map(event)
        let referencedNames = Set(graph.expenseParticipants.compactMap { ($0["participant"] as? CKRecord.Reference)?.recordID.recordName })
        let expectedAndrea = "\(event.remoteID!.uuidString)-participant-\(andrea.sharingAnchorID.uuidString)"
        let expectedMaria = "\(event.remoteID!.uuidString)-participant-\(maria.sharingAnchorID.uuidString)"
        XCTAssertEqual(referencedNames, [expectedAndrea, expectedMaria])
    }

    // MARK: - I. Same Expense delivered twice → one local SharedExpense

    func testSameExpenseDeliveredTwiceCreatesOnlyOneLocalExpense() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, maria, _, _) = makeCollaborativeScenario(in: context)
        let service = makeService(context: context)
        let (expenseRecord, shareRecords) = expenseAndSharesRecord(expenseID: UUID(), event: event, payer: maria)

        service.apply(expenseRecord)
        for share in shareRecords { service.apply(share) }
        service.apply(expenseRecord)
        for share in shareRecords { service.apply(share) }

        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<SharedExpense>())) ?? -1, 1)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<SharedExpenseParticipant>())) ?? -1, 2)
        _ = andrea
    }

    // MARK: - J. Concurrently created expenses never collide

    func testConcurrentlyCreatedExpensesDoNotCollide() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, maria, _, _) = makeCollaborativeScenario(in: context)
        let service = makeService(context: context)
        let sameInstant = Date.now

        // Two independently-created expenses, deliberately given the same timestamp, to prove
        // identity is never timestamp-derived — only each expense's own minted remoteID.
        let (expenseA, sharesA) = expenseAndSharesRecord(expenseID: UUID(), event: event, payer: andrea, amountCents: 1000)
        expenseA["date"] = sameInstant
        let (expenseB, sharesB) = expenseAndSharesRecord(expenseID: UUID(), event: event, payer: maria, amountCents: 8000)
        expenseB["date"] = sameInstant

        service.apply(expenseB) // arrives out of "creation order" too
        for share in sharesB { service.apply(share) }
        service.apply(expenseA)
        for share in sharesA { service.apply(share) }

        let expenses = (try? context.fetch(FetchDescriptor<SharedExpense>())) ?? []
        XCTAssertEqual(expenses.count, 2, "neither expense may overwrite the other")
        XCTAssertEqual(Set(expenses.map { $0.remoteID }).count, 2, "each keeps its own distinct identity")
    }

    // MARK: - K. Cross-event participant references are rejected

    func testExpenseCannotResolvePayerFromAnotherEvent() {
        let context = TestSupport.makeInMemoryContext()
        let (eventA, _, _, _, _) = makeCollaborativeScenario(in: context)
        let carlos = Person(displayName: "Carlos")
        context.insert(carlos)
        let eventB = SharedEvent(title: "Ski Trip", participants: [carlos])
        eventB.remoteID = UUID()
        context.insert(eventB)
        try? context.save()

        let service = makeService(context: context)
        let zoneIDA = CKRecordZone.ID(zoneName: "SharedEvent-\(eventA.remoteID!.uuidString)", ownerName: CKCurrentUserDefaultName)
        let expenseID = UUID()
        let expenseRecord = CKRecord(recordType: "Expense", recordID: CKRecord.ID(recordName: expenseID.uuidString, zoneID: zoneIDA))
        expenseRecord["event"] = CKRecord.Reference(recordID: CKRecord.ID(recordName: eventA.remoteID!.uuidString, zoneID: zoneIDA), action: .deleteSelf)
        expenseRecord["amountCents"] = Int64(1000) as NSNumber
        expenseRecord["currency"] = "EUR"
        expenseRecord["splitMethod"] = SharedSplitMethod.equal.rawValue
        // A payer reference forged to point at Event B's Carlos — even though this Expense record
        // itself lives in Event A's zone.
        let foreignPayerName = "\(eventB.remoteID!.uuidString)-participant-\(carlos.sharingAnchorID.uuidString)"
        expenseRecord["paidBy"] = CKRecord.Reference(recordID: CKRecord.ID(recordName: foreignPayerName, zoneID: zoneIDA), action: .none)

        service.apply(expenseRecord)

        let expense = try? context.fetch(FetchDescriptor<SharedExpense>()).first
        XCTAssertNotNil(expense, "the expense itself is still valid and should be created")
        XCTAssertNil(expense?.paidBy, "a cross-event payer reference must be rejected, not resolved")
    }

    func testExpenseParticipantCannotResolveFromAnotherEvent() {
        let context = TestSupport.makeInMemoryContext()
        let (eventA, andrea, _, _, _) = makeCollaborativeScenario(in: context)
        let carlos = Person(displayName: "Carlos")
        context.insert(carlos)
        let eventB = SharedEvent(title: "Ski Trip", participants: [carlos])
        eventB.remoteID = UUID()
        context.insert(eventB)
        try? context.save()

        let service = makeService(context: context)
        let zoneIDA = CKRecordZone.ID(zoneName: "SharedEvent-\(eventA.remoteID!.uuidString)", ownerName: CKCurrentUserDefaultName)
        let (expenseRecord, _) = expenseAndSharesRecord(expenseID: UUID(), event: eventA, payer: andrea)
        service.apply(expenseRecord) // establish the expense first

        let shareID = UUID()
        let shareRecord = CKRecord(recordType: "ExpenseParticipant", recordID: CKRecord.ID(recordName: shareID.uuidString, zoneID: zoneIDA))
        shareRecord["expense"] = CKRecord.Reference(recordID: expenseRecord.recordID, action: .deleteSelf)
        let foreignParticipantName = "\(eventB.remoteID!.uuidString)-participant-\(carlos.sharingAnchorID.uuidString)"
        shareRecord["participant"] = CKRecord.Reference(recordID: CKRecord.ID(recordName: foreignParticipantName, zoneID: zoneIDA), action: .none)
        shareRecord["amountCents"] = Int64(1000) as NSNumber

        service.apply(shareRecord)

        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<SharedExpenseParticipant>())) ?? -1, 0, "a cross-event participant reference must never create a local share")
    }

    // MARK: - L. Guest participants can pay and participate

    func testGuestParticipantCanBePayerAndShareParticipant() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, _, _, _) = makeCollaborativeScenario(in: context)
        let john = Person(displayName: "John")
        context.insert(john)
        event.participants.append(john)
        let guestMembership = EventParticipant(event: event, person: john) // userRecordID stays nil
        context.insert(guestMembership)
        event.eventParticipants.append(guestMembership)

        let expense = SharedExpense(amount: 20, currency: "EUR", paidBy: john, event: event)
        context.insert(expense)
        event.expenses.append(expense)
        let shareJohn = SharedExpenseParticipant(person: john, amount: 10, expense: expense)
        let shareAndrea = SharedExpenseParticipant(person: andrea, amount: 10, expense: expense)
        context.insert(shareJohn)
        context.insert(shareAndrea)
        expense.participants = [shareJohn, shareAndrea]
        try? context.save()

        XCTAssertNil(guestMembership.userRecordID)
        XCTAssertTrue(expense.paidBy === john)
        XCTAssertEqual(expense.participants.count, 2)
    }

    // MARK: - M. Removed participant's historical attribution is preserved

    func testRemovedParticipantHistoricalExpenseRemainsIntact() {
        let context = TestSupport.makeInMemoryContext()
        let (event, _, maria, _, mariaMembership) = makeCollaborativeScenario(in: context)
        let expense = SharedExpense(amount: 40, currency: "EUR", paidBy: maria, event: event)
        context.insert(expense)
        event.expenses.append(expense)
        try? context.save()

        mariaMembership.isRemoved = true

        XCTAssertTrue(expense.paidBy === maria, "historical payer attribution must survive removal")
        XCTAssertTrue(event.expenses.contains { $0 === expense })
    }

    // MARK: - N. Remote category snapshot never touches personal Category

    func testRemoteCategorySnapshotDoesNotCreateOrModifyPersonalCategory() {
        let context = TestSupport.makeInMemoryContext()
        let (event, _, maria, _, _) = makeCollaborativeScenario(in: context)
        let service = makeService(context: context)
        let categoriesBefore = (try? context.fetchCount(FetchDescriptor<FinanceTracker.Category>())) ?? -1

        let (expenseRecord, _) = expenseAndSharesRecord(expenseID: UUID(), event: event, payer: maria)
        service.apply(expenseRecord)

        let expense = try? context.fetch(FetchDescriptor<SharedExpense>()).first
        XCTAssertEqual(expense?.remoteCategoryName, "Restaurant")
        XCTAssertEqual(expense?.remoteCategoryIcon, "fork.knife")
        XCTAssertNil(expense?.category, "a remote snapshot must never resolve to a local Category")
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<FinanceTracker.Category>())) ?? -2, categoriesBefore)
    }

    // MARK: - O/P/Q. Personal Finance isolation

    func testCollaborativeExpenseReconciliationCreatesNoPersonalFinanceObjects() {
        let context = TestSupport.makeInMemoryContext()
        let (event, _, maria, _, _) = makeCollaborativeScenario(in: context)
        let service = makeService(context: context)

        let entriesBefore = (try? context.fetchCount(FetchDescriptor<Entry>())) ?? -1
        let walletsBefore = (try? context.fetchCount(FetchDescriptor<Wallet>())) ?? -1
        let budgetsBefore = (try? context.fetchCount(FetchDescriptor<Budget>())) ?? -1

        let (expenseRecord, shareRecords) = expenseAndSharesRecord(expenseID: UUID(), event: event, payer: maria)
        service.apply(expenseRecord)
        for share in shareRecords { service.apply(share) }

        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Entry>())) ?? -2, entriesBefore)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Wallet>())) ?? -2, walletsBefore)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Budget>())) ?? -2, budgetsBefore)
    }

    // MARK: - R. Settlement.transaction remains untouched by expense operations

    func testExpenseOperationsNeverTouchSettlementTransaction() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, maria, _, _) = makeCollaborativeScenario(in: context)
        let wallet = TestSupport.makeWallet()
        context.insert(wallet)
        let category = Category(name: "Reimburse", headCategory: HeadCategory(name: "Income", icon: "banknote.fill", colorHex: "#000000"))
        context.insert(category.headCategory)
        context.insert(category)
        let entry = Entry(amount: 20, type: .income, category: category, wallet: wallet)
        context.insert(entry)
        let settlement = Settlement(fromPerson: maria, toPerson: andrea, amount: 20, paymentMethod: .cash, event: event, transaction: entry)
        context.insert(settlement)
        event.settlements.append(settlement)
        try? context.save()

        let service = makeService(context: context)
        let (expenseRecord, shareRecords) = expenseAndSharesRecord(expenseID: UUID(), event: event, payer: maria)
        service.apply(expenseRecord)
        for share in shareRecords { service.apply(share) }

        XCTAssertTrue(settlement.transaction === entry)
    }

    // MARK: - T. Remote reconciliation feeds the existing balance engine

    func testRemoteExpenseReconciliationUpdatesExistingBalanceCalculation() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, maria, _, _) = makeCollaborativeScenario(in: context)
        let service = makeService(context: context)

        XCTAssertEqual(event.yourNetBalance, 0)

        let (expenseRecord, shareRecords) = expenseAndSharesRecord(expenseID: UUID(), event: event, payer: maria, amountCents: 8000)
        service.apply(expenseRecord)
        for share in shareRecords { service.apply(share) }

        // Maria paid €80, split equally: Andrea (the current user here) owes €40.
        XCTAssertEqual(event.outstandingBalance(for: maria), -40, "Andrea owes Maria €40")
        _ = andrea
    }

    // MARK: - U. Editing preserves CloudKit record identity

    func testEditingExpensePreservesItsRecordIdentity() {
        let context = TestSupport.makeInMemoryContext()
        let (event, _, maria, _, _) = makeCollaborativeScenario(in: context)
        let expense = SharedExpense(amount: 80, currency: "EUR", note: "Dinner", paidBy: maria, event: event)
        context.insert(expense)
        event.expenses.append(expense)
        try? context.save()

        let idBeforeEdit = CloudKitSharedEventMapper.map(event).expenses.first?.recordID

        expense.amount = 95
        expense.note = "Dinner (updated)"
        expense.updatedAt = .now

        let idAfterEdit = CloudKitSharedEventMapper.map(event).expenses.first?.recordID
        XCTAssertEqual(idBeforeEdit, idAfterEdit, "editing must update the same record, never create a second one")
    }

    // MARK: - V. Deletion removes only the expense's own data — never Participant/Personal Finance

    func testDeletingExpenseDoesNotDeleteParticipantOrPersonalFinanceData() {
        let context = TestSupport.makeInMemoryContext()
        let (event, andrea, maria, _, mariaMembership) = makeCollaborativeScenario(in: context)
        let expense = SharedExpense(amount: 80, currency: "EUR", paidBy: maria, event: event)
        context.insert(expense)
        event.expenses.append(expense)
        let share = SharedExpenseParticipant(person: andrea, amount: 40, expense: expense)
        context.insert(share)
        expense.participants = [share]
        try? context.save()

        let service = makeService(context: context)
        service.queueUpload(of: event) // mints expense.remoteID, matching the real pre-deletion state
        let entriesBefore = (try? context.fetchCount(FetchDescriptor<Entry>())) ?? -1

        service.queueDeletion(of: expense, from: event) // local-state-only; no network
        context.delete(expense)

        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<SharedExpense>())) ?? -1, 0)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Person>())) ?? -1, 2, "Andrea + Maria must remain")
        XCTAssertNotNil(mariaMembership.event, "the EventParticipant row itself must survive an expense deletion")
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Entry>())) ?? -2, entriesBefore)
    }
}
