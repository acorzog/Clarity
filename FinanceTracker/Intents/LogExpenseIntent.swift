import AppIntents
import SwiftData
import WidgetKit

/// The generic "New Transaction" action — runnable from Shortcuts, Siri, an Automation, or the
/// Action Button without opening Clarity first. Only `amount` is a required parameter, so an
/// unattended Automation (a bank/wallet notification or Apple Pay trigger with "Ask Before
/// Running" off — nobody there to answer a prompt) can never stall waiting on input it has no way
/// to supply.
///
/// This intent went through two wrong fixes for the same underlying problem before landing here,
/// worth recording so neither gets reintroduced:
///  1. Originally, an unset `note` was asked for via a separate, *interactive* `categoryHint`
///     parameter (`requestValue` called mid-`perform()`). iOS can silently suppress that kind of
///     mid-run prompt for an unattended Automation, so the expense would save with no category
///     and no visible sign anything had gone wrong.
///  2. The attempted fix made `note` itself a *required* `@Parameter` instead, reasoning that
///     Shortcuts resolves required parameters up front, the same reliable way it already resolves
///     `amount`. In practice this broke unattended automations outright instead: Shortcuts still
///     has to actually collect that text from somewhere, and a bank-notification trigger has no
///     text to give it and no one present to type it, so the run stalls/fails on that missing
///     required input — exactly the "shortcut doesn't run anymore" regression this fixes.
///
/// The actual fix: `note` stays optional, and — critically — is never the subject of an
/// interactive prompt of its own. Categorization below only ever runs when `note` already happens
/// to be filled in (by the automation itself, or by whoever typed/dictated it interactively); when
/// it isn't, the transaction simply saves without a category rather than blocking on one.
struct LogExpenseIntent: AppIntent {
    static var title: LocalizedStringResource = "New Transaction"
    static var description = IntentDescription(
        "Logs a new expense in Clarity, categorized from a merchant/note if one is provided.",
        categoryName: "Transactions"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Amount")
    var amount: Double

    /// Merchant name or short description — e.g. piped in from a Shortcuts Automation off a
    /// bank/wallet notification, or typed/dictated when run interactively. Optional, and never
    /// prompted for on its own; see the type-level doc comment for why.
    @Parameter(title: "Note")
    var note: String?

    @Parameter(title: "Category")
    var category: CategoryEntity?

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

        // Best-effort, and only ever from a `note` that's already filled in — never an interactive
        // prompt of its own (see the type-level doc comment for why that broke unattended runs).
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if resolvedCategory == nil, !trimmedNote.isEmpty {
            CategorizationService.modelContext = context
            resolvedCategory = await CategorizationService.suggestCategory(for: trimmedNote)
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

        let noteSuffix = trimmedNote.isEmpty ? "" : " for \(trimmedNote)"
        let categorySuffix = resolvedCategory.map { " under \($0.name)" } ?? ""
        return .result(dialog: "Logged \(Decimal(amount).currencyFormatted)\(noteSuffix)\(categorySuffix) in Clarity.")
    }
}
