import XCTest
import SwiftData
import CloudKit
@testable import FinanceTracker

final class CloudKitSharedEventMapperTests: XCTestCase {

    /// Builds a small Barcelona-Trip-shaped graph: You + Maria, one Hotel expense split evenly
    /// between them, and a settlement from Maria back to You.
    private func makeScenario(in context: ModelContext) -> (event: SharedEvent, you: Person, maria: Person, expense: SharedExpense) {
        let headCategory = HeadCategory(name: "Travel", icon: "airplane", colorHex: "#6366F1")
        let category = Category(name: "Hotel", customIcon: "bed.double.fill", headCategory: headCategory)
        context.insert(headCategory)
        context.insert(category)

        let you = Person(displayName: "You", isCurrentUser: true, isFrequent: true)
        let maria = Person(displayName: "Maria")
        context.insert(you)
        context.insert(maria)

        let event = SharedEvent(title: "Barcelona Trip", icon: "airplane", participants: [you, maria])
        context.insert(event)

        let expense = SharedExpense(amount: 100, currency: "EUR", category: category, paidBy: you, event: event)
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

        try? context.save()
        return (event, you, maria, expense)
    }

    func testSharedEventRecordCarriesCoreFields() {
        let context = TestSupport.makeInMemoryContext()
        let (event, _, _, _) = makeScenario(in: context)

        let graph = CloudKitSharedEventMapper.map(event)

        XCTAssertEqual(graph.event.recordType, CloudKitSharedEventMapper.RecordType.sharedEvent)
        XCTAssertEqual(graph.event["title"] as? String, "Barcelona Trip")
        XCTAssertEqual(graph.event["status"] as? String, SharedEventStatus.active.rawValue)
        XCTAssertNotNil(event.remoteID, "mapping must mint and persist a remoteID")
        XCTAssertEqual(graph.zoneID.zoneName, "SharedEvent-\(event.remoteID!.uuidString)")
    }

    func testParticipantRecordsCarryRoleAndDisplayName() {
        let context = TestSupport.makeInMemoryContext()
        let (event, you, maria, _) = makeScenario(in: context)

        let graph = CloudKitSharedEventMapper.map(event)

        XCTAssertEqual(graph.participants.count, 2)
        let owner = graph.participants.first { ($0["displayName"] as? String) == you.displayName }
        let member = graph.participants.first { ($0["displayName"] as? String) == maria.displayName }
        XCTAssertEqual(owner?["role"] as? String, "owner")
        XCTAssertEqual(member?["role"] as? String, "member")
        graph.participants.forEach { XCTAssertEqual($0.recordType, CloudKitSharedEventMapper.RecordType.participant) }
    }

    func testExpenseRecordDenormalizesCategoryAndConvertsAmountToCents() {
        let context = TestSupport.makeInMemoryContext()
        let (event, you, _, _) = makeScenario(in: context)

        let graph = CloudKitSharedEventMapper.map(event)

        XCTAssertEqual(graph.expenses.count, 1)
        let expenseRecord = graph.expenses[0]
        XCTAssertEqual(expenseRecord.recordType, CloudKitSharedEventMapper.RecordType.expense)
        XCTAssertEqual(expenseRecord["amountCents"] as? Int64, 10000)
        XCTAssertEqual(expenseRecord["categoryName"] as? String, "Hotel")
        XCTAssertEqual(expenseRecord["categoryIcon"] as? String, "bed.double.fill")

        // paidBy must reference the payer's own Participant record, not a raw Person.
        let paidByReference = expenseRecord["paidBy"] as? CKRecord.Reference
        let ownerParticipant = graph.participants.first { ($0["displayName"] as? String) == you.displayName }
        XCTAssertEqual(paidByReference?.recordID, ownerParticipant?.recordID)
    }

    func testExpenseParticipantSharesSumToExpenseAmount() {
        let context = TestSupport.makeInMemoryContext()
        let (event, _, _, _) = makeScenario(in: context)

        let graph = CloudKitSharedEventMapper.map(event)

        XCTAssertEqual(graph.expenseParticipants.count, 2)
        let total = graph.expenseParticipants.reduce(0) { $0 + (($1["amountCents"] as? Int64) ?? 0) }
        XCTAssertEqual(total, 10000)
        graph.expenseParticipants.forEach {
            XCTAssertEqual($0.recordType, CloudKitSharedEventMapper.RecordType.expenseParticipant)
            XCTAssertNotNil($0["expense"] as? CKRecord.Reference)
            XCTAssertNotNil($0["participant"] as? CKRecord.Reference)
        }
    }

    func testSettlementRecordReferencesBothParticipants() {
        let context = TestSupport.makeInMemoryContext()
        let (event, you, maria, _) = makeScenario(in: context)

        let graph = CloudKitSharedEventMapper.map(event)

        XCTAssertEqual(graph.settlements.count, 1)
        let settlementRecord = graph.settlements[0]
        XCTAssertEqual(settlementRecord["amountCents"] as? Int64, 2000)
        XCTAssertEqual(settlementRecord["paymentMethod"] as? String, SettlementPaymentMethod.cash.rawValue)

        let fromReference = settlementRecord["fromParticipant"] as? CKRecord.Reference
        let toReference = settlementRecord["toParticipant"] as? CKRecord.Reference
        let mariaParticipant = graph.participants.first { ($0["displayName"] as? String) == maria.displayName }
        let youParticipant = graph.participants.first { ($0["displayName"] as? String) == you.displayName }
        XCTAssertEqual(fromReference?.recordID, mariaParticipant?.recordID)
        XCTAssertEqual(toReference?.recordID, youParticipant?.recordID)

        // The bridge to personal finance must never appear in the shared record.
        XCTAssertFalse(settlementRecord.allKeys().contains("transaction"))
    }

    func testMappingTwiceIsIdempotent() {
        let context = TestSupport.makeInMemoryContext()
        let (event, _, _, expense) = makeScenario(in: context)

        let first = CloudKitSharedEventMapper.map(event)
        let eventRemoteIDAfterFirst = event.remoteID
        let expenseRemoteIDAfterFirst = expense.remoteID

        let second = CloudKitSharedEventMapper.map(event)

        XCTAssertEqual(event.remoteID, eventRemoteIDAfterFirst, "remoteID must not be re-minted on a second mapping")
        XCTAssertEqual(expense.remoteID, expenseRemoteIDAfterFirst)
        XCTAssertEqual(first.event.recordID, second.event.recordID)
        XCTAssertEqual(first.expenses.first?.recordID, second.expenses.first?.recordID)
        XCTAssertEqual(
            Set(first.participants.map(\.recordID)),
            Set(second.participants.map(\.recordID)),
            "the same Person in the same event must resolve to the same Participant record across calls"
        )
    }

    func testPersonReusedAcrossTwoEventsGetsDistinctParticipantRecords() {
        let context = TestSupport.makeInMemoryContext()
        let (barcelonaEvent, you, maria, _) = makeScenario(in: context)

        let skiTrip = SharedEvent(title: "Ski Trip", icon: "figure.skiing.downhill", participants: [you, maria])
        context.insert(skiTrip)
        try? context.save()

        let barcelonaGraph = CloudKitSharedEventMapper.map(barcelonaEvent)
        let skiGraph = CloudKitSharedEventMapper.map(skiTrip)

        // Same Maria, two different events -> two different zones, two different Participant records.
        XCTAssertNotEqual(barcelonaGraph.zoneID, skiGraph.zoneID)
        let mariaInBarcelona = barcelonaGraph.participants.first { ($0["displayName"] as? String) == maria.displayName }
        let mariaInSki = skiGraph.participants.first { ($0["displayName"] as? String) == maria.displayName }
        XCTAssertNotEqual(mariaInBarcelona?.recordID, mariaInSki?.recordID)
    }
}
