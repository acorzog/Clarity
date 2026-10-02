import Foundation
import SwiftData

@Model
final class Category {
    var name: String
    var customIcon: String?
    /// True when customIcon holds an emoji character rather than an SF Symbol name.
    var iconIsEmoji: Bool
    /// Overrides the parent HeadCategory's color when set.
    var customColorHex: String?
    var isSavings: Bool
    var isArchived: Bool
    /// Marks a category used for income entries/budgets rather than expenses.
    var isIncome: Bool
    /// Marks a category whose monthly budget is normally covered by a single matching charge
    /// (rent, a fixed accountant/"Gestor" fee, a tax bill) rather than many smaller purchases
    /// (groceries, eating out). Used only to auto-mark a new expense `Entry` as `isPlannedExpense`
    /// when its amount exactly matches this category's planned budget for the month — see
    /// `Array<Budget>.matchesFixedPlannedAmount` in `BudgetQuerying.swift`. The `= false` default
    /// here (not just on the init parameter) is required for SwiftData's lightweight migration to
    /// backfill this attribute on categories that already exist in an installed app's store.
    var isFixedPlannedCategory: Bool = false

    var headCategory: HeadCategory

    @Relationship(deleteRule: .nullify, inverse: \Entry.category)
    var entries: [Entry] = []

    @Relationship(deleteRule: .cascade, inverse: \Budget.category)
    var budgets: [Budget] = []

    init(
        name: String,
        customIcon: String? = nil,
        iconIsEmoji: Bool = false,
        customColorHex: String? = nil,
        isSavings: Bool = false,
        isArchived: Bool = false,
        isIncome: Bool = false,
        isFixedPlannedCategory: Bool = false,
        headCategory: HeadCategory
    ) {
        self.name = name
        self.customIcon = customIcon
        self.iconIsEmoji = iconIsEmoji
        self.customColorHex = customColorHex
        self.isSavings = isSavings
        self.isArchived = isArchived
        self.isIncome = isIncome
        self.isFixedPlannedCategory = isFixedPlannedCategory
        self.headCategory = headCategory
    }

    /// The category's own color if set, otherwise its HeadCategory's color.
    var resolvedColorHex: String { customColorHex ?? headCategory.colorHex }
}

extension Category {
    /// The existing "Reimburse" income category, if present — used to pre-select a sensible
    /// default for incoming shared-expense settlements without ever creating a new category.
    static func reimburse(in categories: [Category]) -> Category? {
        categories.first { $0.name == "Reimburse" && $0.isIncome && !$0.isArchived }
    }
}
