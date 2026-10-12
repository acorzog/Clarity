import XCTest
import SwiftData
@testable import FinanceTracker

/// Regression coverage for the Phase 3C persistence audit: `HeadCategoryPickerView.confirm()` and
/// `HeadCategoryEditorView.save()` both used to mutate/insert a `HeadCategory` and then call
/// `dismiss()` with no explicit `modelContext.save()`, exactly the same bug class fixed in
/// `WalletEditorView.save()`. Those methods are private View methods and can't be called directly
/// from a test, so these tests characterize the same persistence contract the fix depends on: a
/// mutation/insert followed by an explicit `modelContext.save()` must survive a subsequent
/// `rollback()`.
final class HeadCategoryPersistenceTests: XCTestCase {
    /// Mirrors `HeadCategoryPickerView.confirm()`'s creation path.
    @MainActor
    func testCreatingAHeadCategoryPersistsAndSurvivesRollback() throws {
        let context = TestSupport.makeInMemoryContext()

        let newHead = HeadCategory(name: "Travel", icon: "airplane", colorHex: "#3B82F6", sortOrder: 0)
        context.insert(newHead)
        try context.save()

        context.rollback()

        let heads = try context.fetch(FetchDescriptor<HeadCategory>())
        XCTAssertEqual(heads.count, 1, "a saved insert must not be discarded by a later rollback")
        XCTAssertEqual(heads.first?.name, "Travel")
    }

    /// Mirrors `HeadCategoryEditorView.save()`'s edit path.
    @MainActor
    func testEditingAHeadCategoryPersistsChangedNameIconAndColor() throws {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory(name: "Old Name", colorHex: "#FFFFFF")
        context.insert(head)
        try context.save()

        head.name = "New Name"
        head.icon = "car.fill"
        head.colorHex = "#10B981"
        head.updatedAt = .now
        try context.save()

        let refetched = try XCTUnwrap(try context.fetch(FetchDescriptor<HeadCategory>()).first)
        XCTAssertEqual(refetched.name, "New Name")
        XCTAssertEqual(refetched.icon, "car.fill")
        XCTAssertEqual(refetched.colorHex, "#10B981")
    }

    @MainActor
    func testASavedHeadCategoryEditSurvivesASubsequentRollback() throws {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory(name: "Old Name")
        context.insert(head)
        try context.save()

        head.name = "New Name"
        try context.save()

        context.rollback()

        XCTAssertEqual(head.name, "New Name", "a saved mutation must not be discarded by a later rollback")
    }
}
