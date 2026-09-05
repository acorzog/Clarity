import AppIntents
import SwiftData

/// AppIntents-facing stand-in for `Category`, keyed by name since SwiftData's
/// `PersistentIdentifier` isn't a stable, easily-encodable entity identifier.
struct CategoryEntity: AppEntity {
    let id: String
    let name: String
    let colorHex: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Category"
    static var defaultQuery = CategoryEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct CategoryEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [CategoryEntity] {
        allEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [CategoryEntity] {
        allEntities()
    }

    func entities(matching string: String) async throws -> [CategoryEntity] {
        allEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    private func allEntities() -> [CategoryEntity] {
        let context = ModelContext(SharedModelContainer.make())
        let categories = (try? context.fetch(FetchDescriptor<Category>(sortBy: [SortDescriptor(\.name)]))) ?? []
        return categories
            .filter { !$0.isArchived && !$0.isIncome }
            .map { CategoryEntity(id: $0.name, name: $0.name, colorHex: $0.resolvedColorHex) }
    }
}
