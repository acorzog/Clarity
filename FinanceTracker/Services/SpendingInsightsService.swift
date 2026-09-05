import Foundation
import SwiftData

/// Generates a short natural-language summary of a month's spending by asking the Claude API,
/// from pre-aggregated totals only (category totals and category+amount transaction pairs) —
/// never raw transaction notes. Best-effort like `CategorizationService`: every failure path
/// (missing key, offline, malformed response) returns nil rather than throwing or crashing.
/// Results are cached per month in SwiftData so they aren't regenerated on every app launch.
enum SpendingInsightsService {
    /// Set once at launch from FinanceTrackerApp.init() — see `SeedData.seedIfNeeded` call site.
    static var modelContext: ModelContext?

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-opus-5"

    struct CategoryAmount {
        let name: String
        let currentTotal: Decimal
        /// This category's total for the prior month, if it had any spend.
        let previousTotal: Decimal?
    }

    struct TransactionAmount {
        let category: String
        let amount: Decimal
    }

    /// Pre-aggregated inputs for one month. Deliberately excludes raw transaction notes.
    struct MonthlyAggregates {
        let month: Date
        let topCategories: [CategoryAmount]
        let topTransactions: [TransactionAmount]
        let currentMonthTotal: Decimal
        let previousMonthTotal: Decimal?
        let budgetTotal: Decimal?
    }

    // MARK: - Cache

    /// Returns the cached summary for `month`, if one has already been generated. Does not call the API.
    static func cachedSummary(for month: Date) -> String? {
        guard let modelContext else { return nil }
        let (targetMonth, targetYear) = month.monthYearComponents
        let descriptor = FetchDescriptor<SpendingInsight>(
            predicate: #Predicate { $0.month == targetMonth && $0.year == targetYear }
        )
        return (try? modelContext.fetch(descriptor))?.first?.summary
    }

    private static func cache(_ summary: String, for month: Date) {
        guard let modelContext else { return }
        let (targetMonth, targetYear) = month.monthYearComponents
        let descriptor = FetchDescriptor<SpendingInsight>(
            predicate: #Predicate { $0.month == targetMonth && $0.year == targetYear }
        )
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.summary = summary
            existing.generatedAt = .now
        } else {
            modelContext.insert(SpendingInsight(month: targetMonth, year: targetYear, summary: summary))
        }
        try? modelContext.save()
    }

    // MARK: - Generation

    /// Calls Claude to generate a fresh summary for the given month's aggregates and caches the
    /// result, overwriting any previously cached summary for that month.
    static func generateSummary(for aggregates: MonthlyAggregates) async -> String? {
        guard let apiKey else { return nil }
        guard let text = await requestSummary(prompt: buildPrompt(from: aggregates), apiKey: apiKey) else {
            return nil
        }
        cache(text, for: aggregates.month)
        return text
    }

    private static func buildPrompt(from aggregates: MonthlyAggregates) -> String {
        var lines: [String] = []

        lines.append("Top spending categories this month:")
        for category in aggregates.topCategories {
            if let previous = category.previousTotal {
                lines.append("- \(category.name): \(category.currentTotal.currencyFormatted) (last month: \(previous.currencyFormatted))")
            } else {
                lines.append("- \(category.name): \(category.currentTotal.currencyFormatted) (no spend last month)")
            }
        }

        lines.append("")
        lines.append("Top individual transactions this month (category and amount only):")
        for transaction in aggregates.topTransactions {
            lines.append("- \(transaction.category): \(transaction.amount.currencyFormatted)")
        }

        lines.append("")
        lines.append("Total spending this month: \(aggregates.currentMonthTotal.currencyFormatted)")
        if let previousMonthTotal = aggregates.previousMonthTotal {
            lines.append("Total spending last month: \(previousMonthTotal.currencyFormatted)")
        }
        if let budgetTotal = aggregates.budgetTotal {
            lines.append("Total monthly budget: \(budgetTotal.currencyFormatted)")
        }

        return """
        You are a personal finance assistant. Based only on the pre-aggregated numbers below, \
        write a short summary of this month's spending.

        \(lines.joined(separator: "\n"))

        Write 2-4 short sentences covering, where the data supports it: the single biggest \
        expense, any category that's notably up compared to last month, and whether spending is \
        tracking above or below budget. Be direct and specific with numbers. Do not invent any \
        figures not given above. Reply with ONLY the summary text — no heading, no bullet points, \
        no markdown.
        """
    }

    // MARK: - Networking

    private static func requestSummary(prompt: String, apiKey: String) async -> String? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body = MessagesRequest(
            model: model,
            maxTokens: 300,
            messages: [.init(role: "user", content: prompt)],
            outputConfig: .init(effort: "low")
        )

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
            guard let text = decoded.content.first(where: { $0.type == "text" })?.text else {
                return nil
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            // Network failure, decoding failure, cancellation — all treated as "no summary".
            return nil
        }
    }

    // MARK: - API key

    /// Reads ANTHROPIC_API_KEY from Secrets.plist (gitignored). Returns nil if the file is
    /// missing, malformed, empty, or still holds the placeholder value.
    private static var apiKey: String? {
        guard
            let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            let key = plist["ANTHROPIC_API_KEY"] as? String
        else { return nil }

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "INSERT_YOUR_ANTHROPIC_API_KEY_HERE" else { return nil }
        return trimmed
    }
}

// MARK: - Request/response models

private struct MessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let messages: [Message]
    let outputConfig: OutputConfig

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case messages
        case outputConfig = "output_config"
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct OutputConfig: Encodable {
        let effort: String
    }
}

private struct MessagesResponse: Decodable {
    let content: [ContentBlock]

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
}
