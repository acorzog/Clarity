import Foundation
import SwiftData

/// A savings/accumulation target — see `CLARITY_GOALS_ARCHITECTURE.md`. Phase 2L: model and
/// persistence only. Progress is deliberately **not** stored here — `currentAmount`/
/// `remainingAmount`/`isCompleted` are all derived from `contributions` (the sum of their
/// `amount`s), matching `Wallet.balance`'s own "derive, never cache" precedent. That derivation
/// is `GoalCalculator`'s job (Phase 2M) — this model exists only to hold the facts it needs.
///
/// V1 supports exactly one goal type — savings/accumulation. No `GoalType` enum exists; a second
/// type (debt-reduction, net-worth) is out of scope and would need its own architecture pass
/// (`CLARITY_GOALS_ARCHITECTURE.md` §4).
@Model
final class Goal {
    var name: String
    /// SF Symbol name — matches `HeadCategory`/`Wallet`/`SharedEvent`'s existing icon convention.
    var icon: String
    var colorHex: String
    var targetAmount: Decimal
    var createdAt: Date
    /// Matches `HeadCategory.sortOrder`/`Wallet.sortOrder`'s existing ordering convention.
    var sortOrder: Int = 0
    /// Hides/de-emphasizes the goal without discarding it or its contribution history — matches
    /// `Wallet.isArchived`/`Category.isArchived` exactly. Archiving never touches `contributions`
    /// or the `Entry` rows they reference.
    var isArchived: Bool = false
    /// `nil` = no deadline ("someday" savings), a fully valid, common V1 state — never mandatory.
    var targetDate: Date?

    /// Strictly a display/context reference — e.g. "this goal is associated with Emergency
    /// Fund." **Never** a source of progress: `GoalCalculator` (Phase 2M) must never read this
    /// wallet's `.balance`, `.includeInNetWorth`, `.isArchived`, `.type`, or its entries.
    /// Deliberately a plain property (no `@Relationship` here) — the formal inverse,
    /// `Wallet.goalReferences`, carries the `.nullify` delete rule, matching this codebase's
    /// established convention that the to-many side of a relationship owns the `@Relationship`
    /// declaration (e.g. `Wallet.entries`/`Entry.wallet`, `Category.budgets`/`Budget.category`).
    /// See `Wallet.goalReferences`'s doc comment for the delete-rule rationale.
    var contextWallet: Wallet?

    /// Cascade: a `GoalContribution` has no meaning without its `Goal`, exactly like
    /// `Category.budgets` cascading when a `Category` is deleted (both are lightweight metadata
    /// rows, not financial transactions). This cascade stops at `GoalContribution` — it never
    /// reaches the `Entry` a contribution references, since that link is `.nullify` in the other
    /// direction (see `GoalContribution.transaction`). Deleting a `Goal` therefore can never
    /// delete a transaction.
    @Relationship(deleteRule: .cascade, inverse: \GoalContribution.goal)
    var contributions: [GoalContribution] = []

    init(
        name: String,
        icon: String,
        colorHex: String,
        targetAmount: Decimal,
        createdAt: Date = .now,
        sortOrder: Int = 0,
        isArchived: Bool = false,
        targetDate: Date? = nil,
        contextWallet: Wallet? = nil
    ) {
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.targetAmount = targetAmount
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.isArchived = isArchived
        self.targetDate = targetDate
        self.contextWallet = contextWallet
    }
}

/// One explicit, user-confirmed contribution toward a `Goal` — see
/// `CLARITY_GOALS_ARCHITECTURE.md` §9/§18. V1 rules, as of Phase 2N-C0:
///
/// 1. **No partial-contribution splitting.** `Entry.goalContribution` is a to-one (not to-many)
///    relationship, so a single `Entry` can back at most one `GoalContribution` — structurally
///    guaranteed by the relationship's cardinality, the same way `Entry.sharedSettlement` already
///    guarantees an `Entry` backs at most one `Settlement`. (Closed, Phase 2L — unchanged.)
/// 2. **Manual (unlinked) contributions are first-class.** A `GoalContribution` may be created
///    with or without a real `Entry` — both are permanent, equally valid states, not a degraded/
///    upgraded pair. (Reopened and reversed, Phase 2N-C Pre-Work; implemented here.)
@Model
final class GoalContribution {
    /// Signed — positive is a deposit toward the goal, negative is a withdrawal. Independently
    /// specified at creation, not required to equal `transaction`'s own `amount` when a link
    /// exists — the same `Entry` might only partially fund this goal (e.g. a portion of a
    /// paycheck).
    var amount: Decimal
    var date: Date
    /// Optional free-text note — the manual-contribution counterpart to a linked `Entry`'s own
    /// `note`, since a manual deposit has no transaction to carry context (`CLARITY_GOALS_UX_SPEC.md`
    /// §12/§15, Phase 2N-C1). Purely descriptive; never read by `GoalCalculator`.
    var note: String?

    var goal: Goal

    /// Genuinely optional — a manual contribution (`transaction == nil` from creation) and a
    /// linked contribution are both first-class, permanent states (`CLARITY_GOALS_ARCHITECTURE.md`
    /// §9/§18, Phase 2N-C Pre-Work). When a link exists, this mirrors `Settlement.transaction`/
    /// `Entry.sharedSettlement`'s exact shape (`Settlement.swift`).
    ///
    /// Deleting the referenced `Entry` nullifies this property to `nil` rather than deleting this
    /// `GoalContribution` row — so an `Entry` deletion can never cascade into deleting unrelated
    /// `Goal` data. The resulting state is **not** a residual/invalidated record — it becomes
    /// indistinguishable from a contribution that was manual from the start, and keeps counting
    /// toward progress exactly as before (`GoalCalculator.progress` applies no `transaction`-based
    /// filter — see its own doc comment).
    @Relationship(deleteRule: .nullify, inverse: \Entry.goalContribution)
    var transaction: Entry?

    init(amount: Decimal, date: Date = .now, goal: Goal, transaction: Entry? = nil, note: String? = nil) {
        self.amount = amount
        self.date = date
        self.goal = goal
        self.transaction = transaction
        self.note = note
    }
}
