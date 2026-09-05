import Foundation
import SwiftData

@Model
final class HeadCategory {
    var name: String
    var icon: String
    var colorHex: String
    var sortOrder: Int

    @Relationship(deleteRule: .cascade, inverse: \Category.headCategory)
    var categories: [Category] = []

    init(name: String, icon: String, colorHex: String, sortOrder: Int = 0) {
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.sortOrder = sortOrder
    }
}
