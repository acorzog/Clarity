import AppIntents
import SwiftData
import WidgetKit

/// Takes a forwarded bank/wallet notification's raw text, sends it to Claude in one call to
/// extract amount/note/category, then walks the user through confirming (and correcting) each
/// extracted value before saving — all without opening Clarity. Intended to be wired into a
/// Shortcuts Automation triggered by a bank app's notification; see the in-app Automations
/// help screen (Tools > Automations) for the manual Shortcuts-side setup.
struct TransactionFromTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Transaction from Message"
    static var description = IntentDescription(
        "Reads a forwarded bank or wallet notification, extracts the amount, merchant, and category with AI, and lets you confirm before saving.",
        categoryName: "Automation"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Message Text")
    var text: String

    @Parameter(title: "Amount")
    var amount: Double?

    @Parameter(title: "Note")
    var note: String?

    @Parameter(title: "Category")
    var category: CategoryEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Log a transaction from \(\.$text)")
    }

    /// No wallet is picked explicitly in this flow, so it always falls back to the default
    /// wallet (or the first active one). Exposed for testing.
    static func resolveFallbackWallet(from wallets: [Wallet]) -> Wallet? {
        Wallet.preferredFallback(among: wallets)
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let extracted = await CategorizationService.extractTransaction(from: text) else {
            return .result(dialog: "Couldn't read a transaction from that text — try again or add it manually in Clarity.")
        }

        let context = ModelContext(SharedModelContainer.make())
        let allCategories = (try? context.fetch(FetchDescriptor<Category>(sortBy: [SortDescriptor(\.name)]))) ?? []
        let activeCategories = allCategories.filter { !$0.isArchived && !$0.isIncome }

        amount = extracted.amount.doubleValue
        note = extracted.note.isEmpty ? nil : extracted.note
        if let matchName = extracted.categoryName,
           let matched = activeCategories.first(where: { $0.name.caseInsensitiveCompare(matchName) == .orderedSame }) {
            category = CategoryEntity(id: matched.name, name: matched.name, colorHex: matched.resolvedColorHex)
        }

        let confirmedAmount = try await $amount.requestValue("Confirm the amount")
        let confirmedNote = try await $note.requestValue("Confirm the note")
        let confirmedCategory = try await $category.requestValue("Confirm the category")

        guard let categoryModel = activeCategories.first(where: { $0.name == confirmedCategory.name }) else {
            return .result(dialog: "That category isn't available anymore — add the transaction manually in Clarity.")
        }
        let allWallets = (try? context.fetch(FetchDescriptor<Wallet>(sortBy: [SortDescriptor(\.name)]))) ?? []
        guard let wallet = Self.resolveFallbackWallet(from: allWallets) else {
            return .result(dialog: "No wallet is set up in Clarity yet — open the app first to create one.")
        }

        let entry = Entry(
            amount: Decimal(confirmedAmount),
            note: confirmedNote,
            type: .expense,
            category: categoryModel,
            wallet: wallet
        )
        context.insert(entry)
        try context.save()
        WidgetCenter.shared.reloadAllTimelines()

        let displayNote = confirmedNote.isEmpty ? categoryModel.name : confirmedNote
        return .result(dialog: "Logged \(Decimal(confirmedAmount).currencyFormatted) for \(displayNote) in Clarity.")
    }
}
