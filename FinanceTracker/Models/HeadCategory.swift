import Foundation
import SwiftData

@Model
final class HeadCategory {
    var name: String
    var icon: String
    var colorHex: String
    var sortOrder: Int

    /// This head category's stable cross-device identity for a future Supabase sync — see `Entry.
    /// remoteID`'s doc comment for the full rationale; the same convention applies here.
    var remoteID: UUID?
    var createdAt: Date = Date.now
    /// Bumped by hand at every intentional mutation site (see `HeadCategoryEditorView.save()`) —
    /// deliberately not a `didSet` observer, for the same recursive-mutation reason documented on
    /// `Entry.updatedAt`.
    var updatedAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \Category.headCategory)
    var categories: [Category] = []

    init(name: String, icon: String, colorHex: String, sortOrder: Int = 0, createdAt: Date = .now, updatedAt: Date = .now) {
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
