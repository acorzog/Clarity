import Foundation
import SwiftData

@Model
final class Budget {
    var monthlyLimit: Decimal
    var month: Int
    var year: Int

    var category: Category

    init(category: Category, monthlyLimit: Decimal, month: Int, year: Int) {
        self.category = category
        self.monthlyLimit = monthlyLimit
        self.month = month
        self.year = year
    }
}
