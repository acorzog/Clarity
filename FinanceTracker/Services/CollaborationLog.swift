import Foundation
import os

/// Structured logging for the Shared Expenses collaboration/sync layer only. Deliberately
/// separate from Personal Finance, which has no logging today and shouldn't gain any as a
/// side effect of this feature.
///
/// Never log financial amounts, wallet balances, or other Personal Finance content — only
/// structural sync facts (record/zone counts, record names, CloudKit error codes) needed to
/// diagnose a sync problem. `record.recordID.recordName` is safe to log: it's a locally-minted
/// UUID or a UUID pair, not user content.
enum CollaborationLog {
    private static let logger = Logger(subsystem: "com.andreacorzo.FinanceTracker", category: "Collaboration")

    static func log(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
