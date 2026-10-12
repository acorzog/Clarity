import Foundation
import SwiftData

@Model
final class Budget {
    var monthlyLimit: Decimal
    var month: Int
    var year: Int
    /// Hides the category from the Plan tab for this specific month without discarding
    /// the entered amount, so it can reappear (with its old amount) in a later month.
    var isHidden: Bool = false
    /// A "Fixed" planned amount (rent, subscriptions) automatically carries forward to any later
    /// month that has no entry of its own yet — see `Array<Budget>.amount(for:month:)`. A
    /// "Variable" one (the default, unchanged prior behavior) never carries forward; each month
    /// starts blank until set explicitly.
    var isFixed: Bool = false

    /// This budget's stable cross-device identity for Supabase sync — see `Entry.remoteID`'s doc
    /// comment for the full rationale; the same convention applies here.
    var remoteID: UUID?
    var createdAt: Date = Date.now
    /// Bumped by hand at every intentional mutation site, following the same explicit-bump
    /// convention `Entry`/`Wallet`/`Category`/`HeadCategory` already use.
    var updatedAt: Date = Date.now

    var category: Category

    init(
        category: Category,
        monthlyLimit: Decimal,
        month: Int,
        year: Int,
        isHidden: Bool = false,
        isFixed: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.category = category
        self.monthlyLimit = monthlyLimit
        self.month = month
        self.year = year
        self.isHidden = isHidden
        self.isFixed = isFixed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
