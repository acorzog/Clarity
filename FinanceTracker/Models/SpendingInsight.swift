import Foundation
import SwiftData

/// Caches the AI-generated spending summary for a single calendar month so it's only
/// regenerated on explicit refresh, not on every app launch.
@Model
final class SpendingInsight {
    var month: Int
    var year: Int
    var summary: String
    var generatedAt: Date

    init(month: Int, year: Int, summary: String, generatedAt: Date = .now) {
        self.month = month
        self.year = year
        self.summary = summary
        self.generatedAt = generatedAt
    }
}
