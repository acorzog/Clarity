import Foundation

/// Currencies the amount-formatting setting can choose between.
enum SupportedCurrency: String, CaseIterable, Identifiable, Codable {
    case eur = "EUR"
    case usd = "USD"
    case gbp = "GBP"
    case cop = "COP"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .eur: return "Euro"
        case .usd: return "US Dollar"
        case .gbp: return "British Pound"
        case .cop: return "Colombian Peso"
        }
    }

    var flag: String {
        switch self {
        case .eur: return "🇪🇺"
        case .usd: return "🇺🇸"
        case .gbp: return "🇬🇧"
        case .cop: return "🇨🇴"
        }
    }
}

/// Persists app-wide amount-formatting and default-category preferences, set from the
/// Overview settings sheet's "Currency" / "Decimals" / "Default Categories" sections.
final class AppPreferencesStore: ObservableObject {
    static let shared = AppPreferencesStore()

    @Published var currency: SupportedCurrency {
        didSet { defaults.set(currency.rawValue, forKey: Keys.currency) }
    }
    /// Forces 2 decimal places in every formatted amount, even for a currency (like COP) whose
    /// natural default is 0.
    @Published var showDoubleDecimals: Bool {
        didSet { defaults.set(showDoubleDecimals, forKey: Keys.showDoubleDecimals) }
    }
    /// Rounds to whole numbers in headline summary totals only (Income/Expenses/Left, Net
    /// Worth and other wallet-type totals) — itemized transaction amounts keep full precision.
    @Published var roundDecimalsInSummaries: Bool {
        didSet { defaults.set(roundDecimalsInSummaries, forKey: Keys.roundDecimalsInSummaries) }
    }
    /// Category name pre-selected when starting a new Expense entry — nil leaves the picker
    /// blank, matching the previous behavior.
    @Published var defaultExpenseCategoryName: String? {
        didSet { defaults.set(defaultExpenseCategoryName, forKey: Keys.defaultExpenseCategoryName) }
    }
    /// Same as `defaultExpenseCategoryName`, for a new Income entry.
    @Published var defaultIncomeCategoryName: String? {
        didSet { defaults.set(defaultIncomeCategoryName, forKey: Keys.defaultIncomeCategoryName) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let currency = "appPreferencesCurrency"
        static let showDoubleDecimals = "appPreferencesShowDoubleDecimals"
        static let roundDecimalsInSummaries = "appPreferencesRoundDecimalsInSummaries"
        static let defaultExpenseCategoryName = "appPreferencesDefaultExpenseCategoryName"
        static let defaultIncomeCategoryName = "appPreferencesDefaultIncomeCategoryName"
    }

    private init() {
        let defaults = UserDefaults.standard

        if let saved = defaults.string(forKey: Keys.currency), let match = SupportedCurrency(rawValue: saved) {
            currency = match
        } else if let systemCode = Locale.current.currency?.identifier, let match = SupportedCurrency(rawValue: systemCode) {
            currency = match
        } else {
            currency = .eur
        }

        showDoubleDecimals = defaults.object(forKey: Keys.showDoubleDecimals) as? Bool ?? false
        roundDecimalsInSummaries = defaults.object(forKey: Keys.roundDecimalsInSummaries) as? Bool ?? false
        defaultExpenseCategoryName = defaults.string(forKey: Keys.defaultExpenseCategoryName)
        defaultIncomeCategoryName = defaults.string(forKey: Keys.defaultIncomeCategoryName)
    }
}
