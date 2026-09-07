import AppIntents
import SwiftData
import WidgetKit

/// The generic "New Transaction" action — runnable from Shortcuts, Siri, an Automation, or the
/// Action Button without opening Clarity first. Missing required parameters (amount) are
/// prompted for by the system automatically.
struct LogExpenseIntent: AppIntent {
    static var title: LocalizedStringResource = "New Transaction"
    static var description = IntentDescription(
        "Logs a new expense in Clarity.",
        categoryName: "Transactions"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Amount")
    var amount: Double

    @Parameter(title: "Note")
    var note: String?

    @Parameter(title: "Category")
    var category: CategoryEntity?

    /// Free-text category guess (e.g. "eating out", "dentist") asked for when `category` isn't
    /// already set — matched against the real categories with `CategorizationService` instead of
    /// requiring the caller to know an exact category name.
    @Parameter(title: "What's this for?")
    var categoryHint: String?

    @Parameter(title: "Wallet")
    var wallet: WalletEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) in Clarity")
    }

    /// Picks the wallet to log into: the explicitly requested one by name if it's still active,
    /// otherwise the default wallet, otherwise the first active wallet. Exposed for testing.
    static func resolveWallet(named requestedName: String?, from wallets: [Wallet]) -> Wallet? {
        if let requestedName, let named = Wallet.active(in: wallets).first(where: { $0.name == requestedName }) {
            return named
        }
        return Wallet.preferredFallback(among: wallets)
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = ModelContext(SharedModelContainer.make())

        let allWallets = (try? context.fetch(FetchDescriptor<Wallet>(sortBy: [SortDescriptor(\.name)]))) ?? []
        guard let resolvedWallet = Self.resolveWallet(named: wallet?.name, from: allWallets) else {
            return .result(dialog: "No wallet is set up in Clarity yet — open the app first to create one.")
        }

        var resolvedCategory: Category?
        if let categoryName = category?.name {
            resolvedCategory = try? context.fetch(
                FetchDescriptor<Category>(predicate: #Predicate { $0.name == categoryName })
            ).first
        }

        // No explicit category was passed in (the common case when this runs from Siri/the
        // Action Button) — ask for a free-text guess and match it to a real category instead of
        // making the caller pick an exact name from a list. This step is best-effort: if the
        // prompt can't be completed (cancelled, dismissed, or unavailable in a background/NFC
        // automation that isn't fully interactive), `try?` swallows the error so the expense
        // still gets logged with no category rather than silently failing to save at all.
        if resolvedCategory == nil,
           let hint = try? await $categoryHint.requestValue("What's this for? (e.g. restaurant, groceries, dentist)"),
           !hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            CategorizationService.modelContext = context
            resolvedCategory = await CategorizationService.suggestCategory(for: hint)
            if note == nil || note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                note = hint
            }
        }

        let entry = Entry(
            amount: Decimal(amount),
            note: note ?? "",
            type: .expense,
            category: resolvedCategory,
            wallet: resolvedWallet
        )
        context.insert(entry)
        try context.save()
        WidgetCenter.shared.reloadAllTimelines()

        let noteSuffix = note.map { " for \($0)" } ?? ""
        let categorySuffix = resolvedCategory.map { " under \($0.name)" } ?? ""
        return .result(dialog: "Logged \(Decimal(amount).currencyFormatted)\(noteSuffix)\(categorySuffix) in Clarity.")
    }
}
