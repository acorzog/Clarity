import XCTest
import SwiftData
@testable import FinanceTracker

/// Regression coverage for the Phase 3C persistence audit: `CategoryEditorView.save()` (both its
/// create and edit branches) and `PlanView.addCategory()` all used to mutate/insert a `Category`
/// and then return/dismiss with no explicit `modelContext.save()` — the same bug class fixed in
/// `WalletEditorView.save()`. Those methods are private View methods and can't be called directly
/// from a test, so these tests characterize the same persistence contract the fix depends on: a
/// mutation/insert followed by an explicit `modelContext.save()` must survive a subsequent
/// `rollback()`.
final class CategoryPersistenceTests: XCTestCase {
    /// Mirrors `CategoryEditorView.save()`'s new-category branch.
    @MainActor
    func testCreatingACategoryPersistsAndSurvivesRollback() throws {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        try context.save()

        let newCategory = FinanceTracker.Category(
            name: "Groceries", customIcon: "cart.fill", iconIsEmoji: false, customColorHex: "#22C55E",
            isSavings: false, isArchived: false, isIncome: false, isFixedPlannedCategory: false, headCategory: head
        )
        context.insert(newCategory)
        try context.save()

        context.rollback()

        let categories = try context.fetch(FetchDescriptor<FinanceTracker.Category>())
        XCTAssertEqual(categories.count, 1, "a saved insert must not be discarded by a later rollback")
        XCTAssertEqual(categories.first?.name, "Groceries")
    }

    /// Mirrors `CategoryEditorView.save()`'s existing-category edit branch.
    @MainActor
    func testEditingACategoryPersistsChangedFieldsAndSurvivesRollback() throws {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        let category = TestSupport.makeCategory(name: "Old Name", headCategory: head)
        context.insert(category)
        try context.save()

        category.name = "New Name"
        category.customColorHex = "#F59E0B"
        category.isSavings = true
        category.updatedAt = .now
        try context.save()

        context.rollback()

        XCTAssertEqual(category.name, "New Name", "a saved mutation must not be discarded by a later rollback")
        XCTAssertEqual(category.customColorHex, "#F59E0B")
        XCTAssertTrue(category.isSavings)
    }

    /// Mirrors `PlanView.addCategory()`'s quick-create path — a distinct call site from
    /// `CategoryEditorView`'s creation branch, with the same missing-save bug.
    @MainActor
    func testQuickCreatingACategoryFromPlanPersistsAndSurvivesRollback() throws {
        let context = TestSupport.makeInMemoryContext()
        let head = TestSupport.makeHeadCategory()
        context.insert(head)
        try context.save()

        let category = FinanceTracker.Category(name: "New Category", isIncome: false, headCategory: head)
        context.insert(category)
        try context.save()

        context.rollback()

        let categories = try context.fetch(FetchDescriptor<FinanceTracker.Category>())
        XCTAssertEqual(categories.count, 1, "a saved quick-created category must not be discarded by a later rollback")
        XCTAssertEqual(categories.first?.name, "New Category")
    }
}
