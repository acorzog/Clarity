import XCTest
import SwiftData
@testable import FinanceTracker

/// Covers the Phase 4D fix to `SeedData.seedIfNeeded`'s persistence gap identified in this
/// phase's duplicate-category audit: the empty-store gate (`fetchCount(HeadCategory) == 0`) only
/// prevents re-seeding if a successful seed is actually durable before the next launch re-checks
/// it. Before this fix, `seedIfNeeded` inserted its ~80 objects but never called `context.save()`
/// — if the process died before SwiftData's autosave (or some unrelated later save) happened to
/// commit them, the next launch's gate saw an empty store and reseeded a whole new generation.
/// These tests use two separate `ModelContext`s against the *same* underlying in-memory store
/// (via `TestSupport.makeInMemoryContainer()`) to stand in for "this launch" vs. "the next
/// launch," without needing a real process restart.
final class SeedDataTests: XCTestCase {

    /// The core fix: a seed must reach the shared store immediately, not depend on autosave
    /// timing — so a second, independent context opened against the same store sees it right
    /// away and does not insert a second generation.
    @MainActor
    func testSeedPersistsImmediatelyAndAFreshContextDoesNotReseed() throws {
        let container = TestSupport.makeInMemoryContainer()
        let firstLaunchContext = ModelContext(container)
        try SeedData.seedIfNeeded(context: firstLaunchContext)

        // Stands in for "the next launch" — a context that never saw `firstLaunchContext`'s
        // in-memory pending state, only whatever actually reached the store.
        let nextLaunchContext = ModelContext(container)
        try SeedData.seedIfNeeded(context: nextLaunchContext)

        let headCategories = try nextLaunchContext.fetch(FetchDescriptor<HeadCategory>())
        let wallets = try nextLaunchContext.fetch(FetchDescriptor<Wallet>())
        XCTAssertEqual(headCategories.count, 11, "the first seed's HeadCategories must already be durable, so the second call sees them and skips")
        XCTAssertEqual(wallets.count, 1, "the first seed's default Wallet must already be durable too")
    }

    /// Calling `seedIfNeeded` twice on the very same context (no intervening save at all) must
    /// still produce exactly one generation — `fetchCount` sees the first call's pending inserts
    /// directly, so the second call's gate is never fooled even before any save happens.
    @MainActor
    func testCallingSeedTwiceOnTheSameContextIsIdempotent() throws {
        let context = TestSupport.makeInMemoryContext()

        try SeedData.seedIfNeeded(context: context)
        try SeedData.seedIfNeeded(context: context)

        let headCategories = try context.fetch(FetchDescriptor<HeadCategory>())
        let wallets = try context.fetch(FetchDescriptor<Wallet>())
        XCTAssertEqual(headCategories.count, 11)
        XCTAssertEqual(wallets.count, 1)
    }

    /// The exact scenario from the audit, made explicit: seed, save, then re-check from a fresh
    /// context on the same store — only one generation of HeadCategories/Categories/Wallet must
    /// ever exist, never a second accumulated alongside it.
    @MainActor
    func testSeedFollowedBySaveThenFreshContextProducesOnlyOneGeneration() throws {
        let container = TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        try SeedData.seedIfNeeded(context: context)
        // Explicit — proves the fix itself: `seedIfNeeded` must have already saved on its own,
        // but calling save again here is harmless and keeps this test's intent self-evident even
        // if that internal behavior ever changes.
        try context.save()

        let freshContext = ModelContext(container)
        try SeedData.seedIfNeeded(context: freshContext)

        let headCategories = try freshContext.fetch(FetchDescriptor<HeadCategory>())
        let categories = try freshContext.fetch(FetchDescriptor<FinanceTracker.Category>())
        let wallets = try freshContext.fetch(FetchDescriptor<Wallet>())
        XCTAssertEqual(headCategories.count, 11, "exactly one generation of HeadCategories must exist")
        XCTAssertEqual(Set(categories.map(\.name)).count, categories.count, "no category name should appear twice — a second generation would duplicate every name")
        XCTAssertEqual(wallets.count, 1, "exactly one default Wallet must exist")
    }
}
