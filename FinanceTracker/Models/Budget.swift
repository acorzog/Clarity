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

    var category: Category

    init(category: Category, monthlyLimit: Decimal, month: Int, year: Int, isHidden: Bool = false) {
        self.category = category
        self.monthlyLimit = monthlyLimit
        self.month = month
        self.year = year
        self.isHidden = isHidden
    }
}
