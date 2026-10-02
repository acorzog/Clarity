import UserNotifications

/// Posts a local push notification confirming a transaction Clarity just logged on its own —
/// e.g. from `LogExpenseIntent`, run silently from a Shortcuts Automation with no app UI open.
/// Without this, a silently-run automation gives no visible sign anything happened until the
/// person next opens the app; this closes that gap the same way any other background-logged
/// transaction (Apple Pay, a bank notification) should be confirmed.
enum TransactionConfirmationNotifier {
    /// Best-effort, fire-and-forget — called once at app launch. Never blocks or surfaces UI of
    /// its own; if the person denies the permission, `notifyLogged` below silently does nothing
    /// (posting to an unauthorized `UNUserNotificationCenter` is a no-op, not an error).
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Confirms a transaction was just logged. Best-effort like the rest of this intent's
    /// Shortcuts-facing behavior — never throws, never blocks `perform()` on the outcome.
    static func notifyLogged(amount: Decimal, merchant: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Transaction Logged"
        let trimmedMerchant = merchant?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        content.body = trimmedMerchant.isEmpty
            ? "Logged \(amount.currencyFormatted) in Clarity."
            : "Logged \(amount.currencyFormatted) at \(trimmedMerchant) in Clarity."
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
