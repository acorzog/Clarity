import Foundation

/// A toggleable, reorderable card shown on the Overview tab's "Overview" sub-tab.
enum OverviewCard: String, CaseIterable, Identifiable, Codable {
    case insights
    case summary
    case trends
    case calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insights: "Spending Insights"
        case .summary: "Income & Expenses"
        case .trends: "Trends & Top Categories"
        case .calendar: "Calendar"
        }
    }

    var icon: String {
        switch self {
        case .insights: "sparkles"
        case .summary: "chart.bar.fill"
        case .trends: "chart.line.uptrend.xyaxis"
        case .calendar: "calendar"
        }
    }
}

/// Persists per-user visibility and ordering preferences for the Overview tab's sections.
final class OverviewSettingsStore: ObservableObject {
    static let shared = OverviewSettingsStore()

    @Published var cardOrder: [OverviewCard] {
        didSet { defaults.set(cardOrder.map(\.rawValue), forKey: Keys.cardOrder) }
    }
    @Published var hiddenCards: Set<OverviewCard> {
        didSet { defaults.set(hiddenCards.map(\.rawValue), forKey: Keys.hiddenCards) }
    }
    @Published var showSpendingBreakdown: Bool {
        didSet { defaults.set(showSpendingBreakdown, forKey: Keys.showSpendingBreakdown) }
    }
    @Published var showListSummary: Bool {
        didSet { defaults.set(showListSummary, forKey: Keys.showListSummary) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let cardOrder = "overviewCardOrder"
        static let hiddenCards = "overviewHiddenCards"
        static let showSpendingBreakdown = "overviewShowSpendingBreakdown"
        static let showListSummary = "overviewShowListSummary"
    }

    private init() {
        let defaults = UserDefaults.standard

        if let savedOrder = defaults.stringArray(forKey: Keys.cardOrder) {
            let saved = savedOrder.compactMap(OverviewCard.init(rawValue:))
            let missing = OverviewCard.allCases.filter { !saved.contains($0) }
            cardOrder = saved + missing
        } else {
            cardOrder = OverviewCard.allCases
        }

        let savedHidden = defaults.stringArray(forKey: Keys.hiddenCards) ?? []
        hiddenCards = Set(savedHidden.compactMap(OverviewCard.init(rawValue:)))

        showSpendingBreakdown = defaults.object(forKey: Keys.showSpendingBreakdown) as? Bool ?? true
        showListSummary = defaults.object(forKey: Keys.showListSummary) as? Bool ?? true
    }

    var visibleCards: [OverviewCard] {
        cardOrder.filter { !hiddenCards.contains($0) }
    }

    func isVisible(_ card: OverviewCard) -> Bool { !hiddenCards.contains(card) }

    func toggleVisibility(_ card: OverviewCard) {
        if hiddenCards.contains(card) {
            hiddenCards.remove(card)
        } else {
            hiddenCards.insert(card)
        }
    }

    func moveCards(fromOffsets source: IndexSet, toOffset destination: Int) {
        cardOrder.move(fromOffsets: source, toOffset: destination)
    }
}
