import SwiftUI
import SwiftData

@main
struct FinanceTrackerApp: App {
    private let container: ModelContainer

    init() {
        container = SharedModelContainer.make()
        SeedData.seedIfNeeded(context: container.mainContext)
        CategorizationService.modelContext = container.mainContext
        SpendingInsightsService.modelContext = container.mainContext
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
