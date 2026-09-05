import AppIntents
import SwiftData

/// AppIntents-facing stand-in for `Wallet`, keyed by name (see `CategoryEntity`).
struct WalletEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Wallet"
    static var defaultQuery = WalletEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct WalletEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [WalletEntity] {
        allEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [WalletEntity] {
        allEntities()
    }

    func entities(matching string: String) async throws -> [WalletEntity] {
        allEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    /// Active wallets exposed to Shortcuts, pickable by name. Exposed for testing.
    static func makeEntities(from wallets: [Wallet]) -> [WalletEntity] {
        Wallet.active(in: wallets).map { WalletEntity(id: $0.name, name: $0.name) }
    }

    private func allEntities() -> [WalletEntity] {
        let context = ModelContext(SharedModelContainer.make())
        let wallets = (try? context.fetch(FetchDescriptor<Wallet>(sortBy: [SortDescriptor(\.name)]))) ?? []
        return Self.makeEntities(from: wallets)
    }
}
