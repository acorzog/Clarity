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

    /// Same idea as `note` — a merchant name a Shortcuts Automation can supply on its own (e.g.
    /// a payee parsed out of a bank/wallet notification) without a human present to type one in.
    /// Kept as a separate optional parameter, distinct from `note`, purely so an Automation can
    /// wire a structured "merchant" value from its trigger without needing free-text `note`
    /// plumbing of its own. Same rule as `note` applies: optional, never the subject of an
    /// interactive prompt, and never required for a run to complete — see the type-level doc
    /// comment. There's no dedicated `merchant` field on `Entry` yet, so this is folded into
    /// `note` at save time via `resolveEffectiveNote`.
    @Parameter(title: "Merchant")
    var merchant: String?

    @Parameter(title: "Category")
    var category: CategoryEntity?

    @Parameter(title: "Wallet")
    var wallet: WalletEntity?

    /// Only `amount` is in the summary sentence itself (see the type-level doc comment for why
    /// none of these ever become required or interactive), but `merchant`/`note`/`category`/
    /// `wallet` are listed here too so Shortcuts renders them as configurable fields on the
    /// action at all — a parameter left out of `parameterSummary` entirely gets no editable slot
    /// in the Shortcuts UI, even though it still works fine when set programmatically (Siri, an
    /// Automation's own variable wiring). This is purely a Shortcuts-editor visibility fix; it
    /// doesn't change `perform()` or any parameter's optionality.
    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) in Clarity") {
            \.$merchant
            \.$note
            \.$category
            \.$wallet
        }
    }

    /// Picks the wallet to log into: the explicitly requested one by name if it's still active,
    /// otherwise the default wallet, otherwise the first active wallet. Exposed for testing.
    static func resolveWallet(named requestedName: String?, from wallets: [Wallet]) -> Wallet? {
        if let requestedName, let named = Wallet.active(in: wallets).first(where: { $0.name == requestedName }) {
            return named
        }
        return Wallet.preferredFallback(among: wallets)
    }

    /// Folds `merchant` and `note` into the single text Clarity actually saves/categorizes from,
    /// since `Entry` has no separate `merchant` field yet. `merchant` wins when both are present
    /// (it's the more structured of the two); either one alone is used as-is; neither present (or
    /// both blank) reproduces the exact pre-`merchant` behavior — an empty string. Exposed for
    /// testing.
    static func resolveEffectiveNote(note: String?, merchant: String?) -> String {
        let trimmedMerchant = merchant?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedMerchant.isEmpty {
            return trimmedMerchant
        }
        return note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // A source that can't actually supply an amount (e.g. Shortcuts' "Get Transaction →
        // Amount" coming back empty because Apple's own Wallet doesn't recognize the merchant)
        // silently resolves the required `amount` parameter to 0 rather than failing the run —
        // there's no error to catch here, just a number that's clearly not a real transaction.
        // Saving that anyway would be worse than not saving at all: a 0.00, uncategorized entry
        // reads as "this got logged correctly" while actually hiding that the real charge never
        // made it in. Refusing to save is the same "don't block/corrupt on missing input"
        // principle `merchant`/`note` already follow above, applied to `amount` too.
        guard amount > 0 else {
            return .result(dialog: "Couldn't log this transaction — the amount wasn't captured. Add it manually in Clarity.")
        }

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

        // Best-effort, and only ever from text that's already filled in (merchant, or note as a
        // fallback) — never an interactive prompt of its own (see the type-level doc comment for
        // why that broke unattended runs).
        let trimmedNote = Self.resolveEffectiveNote(note: note, merchant: merchant)
        if resolvedCategory == nil, !trimmedNote.isEmpty {
            CategorizationService.modelContext = context
            resolvedCategory = await CategorizationService.suggestCategory(for: trimmedNote)
        }

        // Same fallback order as categorization above, but preserving `note` exactly as typed
        // (untrimmed) when there's no merchant — byte-for-byte the same `note ?? ""` this saved
        // before `merchant` existed.
        let trimmedMerchant = merchant?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let savedNote = trimmedMerchant.isEmpty ? (note ?? "") : trimmedMerchant

        // Same auto-mark `AddTransactionView`/`TransactionSaving.createEntry` apply — a Fixed
        // Planned category (rent, a fixed accountant fee) whose exact budgeted amount landed here
        // shouldn't need a human to mark it Planned by hand just because this came in via
        // Shortcuts instead of the app. See `matchesFixedPlannedAmount`'s doc comment.
        let now = Date.now
        let allBudgets = (try? context.fetch(FetchDescriptor<Budget>())) ?? []
        let autoPlanned = allBudgets.matchesFixedPlannedAmount(Decimal(amount), for: resolvedCategory, month: now)

        let entry = Entry(
            amount: Decimal(amount),
            date: now,
            note: savedNote,
            type: .expense,
            category: resolvedCategory,
            wallet: resolvedWallet,
            isPlannedExpense: autoPlanned
        )
        context.insert(entry)
        try context.save()
        WidgetCenter.shared.reloadAllTimelines()
        // A Shortcuts Automation typically runs with no app UI open and "Notify"/"Show When Run"
        // off (so it doesn't interrupt); without this, the only sign anything happened is
        // whatever's visible next time the person opens Clarity themselves.
        TransactionConfirmationNotifier.notifyLogged(amount: Decimal(amount), merchant: trimmedNote)

        let noteSuffix = trimmedNote.isEmpty ? "" : " for \(trimmedNote)"
        let categorySuffix = resolvedCategory.map { " under \($0.name)" } ?? ""
        return .result(dialog: "Logged \(Decimal(amount).currencyFormatted)\(noteSuffix)\(categorySuffix) in Clarity.")
    }
}
