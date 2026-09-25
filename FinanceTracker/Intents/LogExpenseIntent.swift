import AppIntents
import SwiftData
import WidgetKit

/// The generic "New Transaction" action — runnable from Shortcuts, Siri, an Automation, or the
/// Action Button without opening Clarity first. `amount` and `note` are both required, so
/// Shortcuts' own native parameter-filling UI prompts for whichever one isn't already provided by
/// the automation — the same reliable mechanism that already prompted for `amount` alone before
/// this change.
///
/// `note` deliberately being required (not optional) is the fix for a real reliability gap: an
/// *optional* parameter left unset used to only get asked for via an interactive `requestValue`
/// call inside `perform()`, and iOS can silently suppress that kind of mid-run interactive prompt
/// for an Automation with "Ask Before Running" turned off (the common setup for a bank/wallet
/// notification or Apple Pay trigger) — so the expense would silently save with no category, with
/// no visible sign anything had gone wrong. A required parameter doesn't have this problem:
/// Shortcuts resolves it up front, the same way it already reliably resolves `amount`.
///
/// Categorization: if `category` isn't set explicitly, `note` (a merchant name or short
/// description) is looked up via `CategorizationService.suggestCategory`, which tries a fast
/// local/offline name match against the user's real categories before ever falling back to an AI
/// guess — so this resolves instantly and without a network call for the common case.
struct LogExpenseIntent: AppIntent {
    static var title: LocalizedStringResource = "New Transaction"
    static var description = IntentDescription(
        "Logs a new expense in Clarity, categorized from a merchant/note you provide.",
        categoryName: "Transactions"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Amount")
    var amount: Double

    /// Merchant name or short description — e.g. piped in from a Shortcuts Automation off a
    /// bank/wallet notification, or typed/dictated when run interactively. Required so Shortcuts
    /// always resolves it up front; see the type-level doc comment for why.
    @Parameter(title: "Merchant / Note")
    var note: String

    @Parameter(title: "Category")
    var category: CategoryEntity?

    @Parameter(title: "Wallet")
    var wallet: WalletEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) for \(\.$note) in Clarity")
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

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedCategory == nil, !trimmedNote.isEmpty {
            CategorizationService.modelContext = context
            resolvedCategory = await CategorizationService.suggestCategory(for: trimmedNote)
        }

        let entry = Entry(
            amount: Decimal(amount),
            note: note,
            type: .expense,
            category: resolvedCategory,
            wallet: resolvedWallet
        )
        context.insert(entry)
        try context.save()
        WidgetCenter.shared.reloadAllTimelines()

        let noteSuffix = trimmedNote.isEmpty ? "" : " for \(trimmedNote)"
        let categorySuffix = resolvedCategory.map { " under \($0.name)" } ?? ""
        return .result(dialog: "Logged \(Decimal(amount).currencyFormatted)\(noteSuffix)\(categorySuffix) in Clarity.")
    }
}
