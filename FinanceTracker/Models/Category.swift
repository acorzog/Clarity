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
        headCategory: HeadCategory
    ) {
        self.name = name
        self.customIcon = customIcon
        self.iconIsEmoji = iconIsEmoji
        self.customColorHex = customColorHex
        self.isSavings = isSavings
        self.isArchived = isArchived
        self.isIncome = isIncome
        self.headCategory = headCategory
    }

    /// The category's own color if set, otherwise its HeadCategory's color.
    var resolvedColorHex: String { customColorHex ?? headCategory.colorHex }
}
