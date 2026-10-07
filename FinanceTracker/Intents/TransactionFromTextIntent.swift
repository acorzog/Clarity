import AppIntents
import SwiftData
import WidgetKit

/// Takes a forwarded bank/wallet notification's raw text, sends it to Claude in one call to
/// extract amount/note/category, and saves it directly — all without opening Clarity.
/// Intended to be wired into a Shortcuts Automation triggered by a bank app's notification; see
/// the in-app Automations help screen (Tools > Automations) for the manual Shortcuts-side setup.
///
/// Deliberately never prompts interactively for amount/note/category — same lesson `LogExpenseIntent`
/// documents at its own type level: this intent's whole reason to exist is an unattended
/// Automation (no app UI, usually "Ask Before Running" off, nobody present to answer a prompt).
/// An earlier version called `requestValue()` on each extracted field as a "confirm before
/// saving" step; iOS can silently stall/fail that kind of mid-run prompt for an unattended
/// Automation, so the run would stall or fail with the extracted transaction never saved and no
/// visible error. The fix is the same as `LogExpenseIntent`'s: use whatever Claude extracted
/// directly, and only ever fall back to a dialog explaining why nothing was saved — never block
/// on a human being there to answer.
struct TransactionFromTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Transaction from Message"
    static var description = IntentDescription(
        "Reads a forwarded bank or wallet notification and logs the amount, merchant, and category with AI — no confirmation step, so it works from an unattended Automation.",
        categoryName: "Automation"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Message Text")
    var text: String

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
        guard extracted.amount > 0 else {
            return .result(dialog: "Couldn't log this transaction — the amount wasn't captured. Add it manually in Clarity.")
        }

        // A failure here used to crash this extension process outright via `fatalError` — see
        // `SharedModelContainer.make()`'s doc comment. Falling back to a dialog instead means a
        // transient hiccup reads as "this run failed," not "the shortcut is broken."
        guard let container = try? SharedModelContainer.make() else {
            return .result(dialog: "Couldn't reach Clarity's data right now — try again in a moment.")
        }
        let context = ModelContext(container)
        let allCategories = (try? context.fetch(FetchDescriptor<Category>(sortBy: [SortDescriptor(\.name)]))) ?? []
        let activeCategories = allCategories.filter { !$0.isArchived && !$0.isIncome }

        // Best-effort match against Claude's suggested category name; no match (including no
        // category suggested at all) just saves uncategorized rather than blocking on a choice.
        let matchedCategory = extracted.categoryName.flatMap { matchName in
            activeCategories.first { $0.name.caseInsensitiveCompare(matchName) == .orderedSame }
        }

        let allWallets = (try? context.fetch(FetchDescriptor<Wallet>(sortBy: [SortDescriptor(\.name)]))) ?? []
        guard let wallet = Self.resolveFallbackWallet(from: allWallets) else {
            return .result(dialog: "No wallet is set up in Clarity yet — open the app first to create one.")
        }

        // Same auto-mark `AddTransactionView`/`LogExpenseIntent` apply — see
        // `matchesFixedPlannedAmount`'s doc comment.
        let now = Date.now
        let allBudgets = (try? context.fetch(FetchDescriptor<Budget>())) ?? []
        let autoPlanned = allBudgets.matchesFixedPlannedAmount(extracted.amount, for: matchedCategory, month: now)

        let entry = Entry(
            amount: extracted.amount,
            date: now,
            note: extracted.note,
            type: .expense,
            category: matchedCategory,
            wallet: wallet,
            isPlannedExpense: autoPlanned
        )
        context.insert(entry)
        try context.save()
        WidgetCenter.shared.reloadAllTimelines()
        // Same reasoning as `LogExpenseIntent`: this typically runs with no app UI open and
        // nothing else to show that it actually happened.
        TransactionConfirmationNotifier.notifyLogged(amount: extracted.amount, merchant: extracted.note)

        let displayNote = extracted.note.isEmpty ? (matchedCategory?.name ?? "") : extracted.note
        let noteSuffix = displayNote.isEmpty ? "" : " for \(displayNote)"
        return .result(dialog: "Logged \(extracted.amount.currencyFormatted)\(noteSuffix) in Clarity.")
    }
}
