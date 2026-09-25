import Foundation

/// SF Symbol choices offered in the Budget tab's Appearance icon picker.
enum BudgetIcon: String, CaseIterable, Identifiable, Codable {
    case house = "house.fill"
    case heart = "heart.fill"
    case people = "person.2.fill"
    case cash = "banknote.fill"
    case car = "car.fill"
    case trophy = "trophy.fill"

    var id: String { rawValue }

    /// VoiceOver name — the selected state in `IconPickerRow` is otherwise conveyed only by a
    /// fill-color/gradient change, which carries no meaning to VoiceOver at all (Phase 2J).
    var accessibilityName: String {
        switch self {
        case .house: "House"
        case .heart: "Heart"
        case .people: "People"
        case .cash: "Cash"
        case .car: "Car"
        case .trophy: "Trophy"
        }
    }
}

/// Persists customization + calculation preferences for the Budget tab ("Editing Budget" sheet).
final class BudgetSettingsStore: ObservableObject {
    static let shared = BudgetSettingsStore()

    @Published var name: String {
        didSet { defaults.set(name, forKey: Keys.name) }
    }
    @Published var icon: BudgetIcon {
        didSet { defaults.set(icon.rawValue, forKey: Keys.icon) }
    }
    /// Day of month (1-28) the budget period starts on for Remaining. 1 = ordinary calendar month.
    @Published var cycleStartDay: Int {
        didSet { defaults.set(cycleStartDay, forKey: Keys.cycleStartDay) }
    }
    /// Manual "Left to Spend" ceiling. Takes priority over income when > 0. Persisted as a
    /// string-encoded `Decimal` (Phase 2N-G) — `"\(decimal)"`/`Decimal(string:)` always use "."
    /// as the decimal separator regardless of locale, so this round-trips exactly, unlike the
    /// `Decimal → Double → Decimal` path this replaces, which could lose precision.
    @Published var manualMonthlyBudget: Decimal {
        didSet { defaults.set("\(manualMonthlyBudget)", forKey: Keys.manualMonthlyBudget) }
    }
    @Published var includeUnplannedAsOtherExpenses: Bool {
        didSet { defaults.set(includeUnplannedAsOtherExpenses, forKey: Keys.includeUnplanned) }
    }
    @Published var includeSavingsTransfers: Bool {
        didSet { defaults.set(includeSavingsTransfers, forKey: Keys.includeSavings) }
    }
    @Published var includeDebtTransfers: Bool {
        didSet { defaults.set(includeDebtTransfers, forKey: Keys.includeDebt) }
    }

    // App-Group-scoped (not `.standard`) so the widget extension — a separate process — reads
    // the same cycle/manual-budget/include-toggle settings as the app, letting
    // `BudgetGaugeWidget` compute the identical `PeriodSpendingSummary` Remaining shows. Falls
    // back to `.standard` only if the App Group container is ever unavailable, matching the
    // fatalError-free, best-effort posture the rest of this store already has.
    private let defaults = UserDefaults(suiteName: SharedModelContainer.appGroupID) ?? .standard

    private enum Keys {
        static let name = "budgetName"
        static let icon = "budgetIcon"
        static let cycleStartDay = "budgetCycleStartDay"
        static let manualMonthlyBudget = "budgetManualMonthlyBudget"
        static let includeUnplanned = "budgetIncludeUnplanned"
        static let includeSavings = "budgetIncludeSavingsTransfers"
        static let includeDebt = "budgetIncludeDebtTransfers"
    }

    private init() {
        let defaults = UserDefaults(suiteName: SharedModelContainer.appGroupID) ?? .standard
        Self.migrateFromStandardDefaultsIfNeeded(into: defaults)
        // Default changed from "Budget" to "Plan" in Phase 2J, to match the primary tab's own
        // name — see `CLARITY_V1_POLISH_REPORT.md` §8. Safe: `Keys.name` in `UserDefaults` is
        // only ever written by this property's `didSet`, which (per Swift's definite-
        // initialization rules) does not fire for this very assignment — so the key stays absent
        // for every user who has never actually typed a custom name in `BudgetSettingsView`,
        // letting this fallback change take effect for them without touching anyone's real
        // customization (including a user who deliberately kept/retyped "Budget" themselves,
        // whose choice is indistinguishable from any other custom value once written).
        name = defaults.string(forKey: Keys.name) ?? "Plan"
        icon = BudgetIcon(rawValue: defaults.string(forKey: Keys.icon) ?? "") ?? .house

        let savedDay = defaults.object(forKey: Keys.cycleStartDay) as? Int ?? 1
        cycleStartDay = min(max(savedDay, 1), 28)

        manualMonthlyBudget = Self.readManualMonthlyBudget(from: defaults)

        includeUnplannedAsOtherExpenses = defaults.object(forKey: Keys.includeUnplanned) as? Bool ?? true
        includeSavingsTransfers = defaults.object(forKey: Keys.includeSavings) as? Bool ?? false
        includeDebtTransfers = defaults.object(forKey: Keys.includeDebt) as? Bool ?? true
    }

    /// Reads the persisted manual budget losslessly via its string-encoded `Decimal`
    /// representation (Phase 2N-G — replaces a `Decimal → Double → Decimal` round trip that could
    /// lose precision). Falls back to the legacy `Double`-encoded value for a user who saved one
    /// before this fix, so an existing override is never silently reset to 0 — the very next edit
    /// re-saves it in the new, lossless format. Absent key (never set) correctly yields `0` either
    /// way, preserving the existing "0 = no override" semantics.
    ///
    /// Internal (not `private`), matching this key's storage format (`"\(Decimal)"`, written by
    /// `manualMonthlyBudget`'s `didSet`) so `BudgetSettingsPersistenceTests` can exercise the real
    /// read path against an isolated `UserDefaults` suite, without touching the live singleton's
    /// App-Group storage.
    static func readManualMonthlyBudget(from defaults: UserDefaults) -> Decimal {
        if let stored = defaults.string(forKey: Keys.manualMonthlyBudget), let value = Decimal(string: stored) {
            return value
        }
        return Decimal(defaults.double(forKey: Keys.manualMonthlyBudget))
    }

    /// One-time copy of any pre-Phase-1 values from `UserDefaults.standard` into the App-Group
    /// suite this store now reads from, so a user who already configured these settings (before
    /// they moved to the shared suite so the widget could see them) doesn't see them silently
    /// reset to defaults on upgrade. Never overwrites a value already present in `appGroupDefaults`
    /// — e.g. from a previous run of this same migration, or the widget having written first.
    private static func migrateFromStandardDefaultsIfNeeded(into appGroupDefaults: UserDefaults) {
        let standardDefaults = UserDefaults.standard
        let keys = [
            Keys.name, Keys.icon, Keys.cycleStartDay, Keys.manualMonthlyBudget,
            Keys.includeUnplanned, Keys.includeSavings, Keys.includeDebt
        ]
        for key in keys where appGroupDefaults.object(forKey: key) == nil {
            guard let value = standardDefaults.object(forKey: key) else { continue }
            appGroupDefaults.set(value, forKey: key)
        }
    }
}
