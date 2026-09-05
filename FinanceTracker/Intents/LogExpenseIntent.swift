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
        return .result(dialog: "Logged \(Decimal(amount).currencyFormatted)\(noteSuffix) in Clarity.")
    }
}
