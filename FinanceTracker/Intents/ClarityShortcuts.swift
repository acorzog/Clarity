import AppIntents

/// Surfaces Clarity's intents in Shortcuts/Siri search, and lets the system suggest them for
/// Automations and the Action Button without the user having to open the app first.
struct ClarityShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogExpenseIntent(),
            phrases: [
                "New transaction in \(.applicationName)",
                "Log an expense in \(.applicationName)"
            ],
            shortTitle: "New Transaction",
            systemImageName: "plus.circle.fill"
        )
        AppShortcut(
            intent: TransactionFromTextIntent(),
            phrases: [
                "Transaction from message in \(.applicationName)",
                "Log a transaction from text in \(.applicationName)"
            ],
            shortTitle: "Transaction from Message",
            systemImageName: "text.bubble.fill"
        )
    }
}
