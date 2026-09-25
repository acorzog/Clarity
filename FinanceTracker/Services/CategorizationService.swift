import Foundation
import SwiftData

/// Suggests a Category for a transaction note/merchant string — first with a deterministic,
/// offline name match against the user's real categories (`localCategoryMatch`), falling back to
/// asking the Claude API to pick the best match only when that finds nothing. Best-effort UX
/// only — every failure path (missing key, offline, malformed response) returns nil rather than
/// throwing or crashing, and neither path ever invents a category name outside the user's own.
enum CategorizationService {
    /// Set once at launch from FinanceTrackerApp.init() — see `SeedData.seedIfNeeded` call site.
    static var modelContext: ModelContext?

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-opus-5"

    static func suggestCategory(for note: String, isIncome: Bool = false) async -> Category? {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNote.isEmpty else { return nil }
        guard let modelContext else { return nil }

        guard
            let headCategories = try? modelContext.fetch(
                FetchDescriptor<HeadCategory>(sortBy: [SortDescriptor(\.sortOrder)])
            )
        else { return nil }

        var promptLines: [String] = []
        var allCategories: [Category] = []
        for head in headCategories {
            let activeCategories = head.categories
                .filter { !$0.isArchived && $0.isIncome == isIncome }
                .sorted { $0.name < $1.name }
            guard !activeCategories.isEmpty else { continue }
            promptLines.append("\(head.name): \(activeCategories.map(\.name).joined(separator: ", "))")
            allCategories.append(contentsOf: activeCategories)
        }
        guard !allCategories.isEmpty else { return nil }

        // Deterministic, offline pass first — see `localCategoryMatch`. Only falls through to
        // the AI suggestion below when nothing in the user's own category names obviously
        // matches, so the common "the merchant/description already names a category" case
        // (e.g. "Rent", "Gym membership") resolves instantly, with no network call and no API
        // key required — important for a Shortcuts Automation that may run unattended.
        if let localMatch = localCategoryMatch(for: trimmedNote, in: allCategories) {
            return localMatch
        }

        guard let apiKey else { return nil }

        let prompt = """
        You categorize personal finance transactions. Given a transaction note or merchant \
        name, pick the single best matching category from the list below.

        Categories, grouped by head category:
        \(promptLines.joined(separator: "\n"))

        Transaction note: "\(trimmedNote)"

        Reply with ONLY the exact category name from the list above that best matches — \
        nothing else, no punctuation, no explanation. If nothing fits reasonably well, reply \
        with exactly: None
        """

        guard let suggestionText = await requestSuggestion(prompt: prompt, apiKey: apiKey) else {
            return nil
        }

        if let matched = matchCategory(named: suggestionText, in: allCategories) {
            return matched
        }
        return allCategories.first { $0.name.caseInsensitiveCompare("Miscellaneous") == .orderedSame }
    }

    // MARK: - Transaction extraction (from forwarded bank/wallet text)

    /// Sends a forwarded bank/wallet notification (SMS, push body, etc.) to Claude in a single
    /// call and asks it to extract amount, merchant/note, and best-matching category as JSON.
    /// Best-effort like `suggestCategory` — returns nil on any failure rather than throwing.
    static func extractTransaction(from rawText: String) async -> ExtractedTransaction? {
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }
        guard let apiKey else { return nil }

        var categoryNames: [String] = []
        if let modelContext,
           let headCategories = try? modelContext.fetch(
               FetchDescriptor<HeadCategory>(sortBy: [SortDescriptor(\.sortOrder)])
           ) {
            for head in headCategories {
                categoryNames.append(
                    contentsOf: head.categories
                        .filter { !$0.isArchived && !$0.isIncome }
                        .map(\.name)
                )
            }
        }
        let categoryList = categoryNames.isEmpty ? "(none available)" : categoryNames.joined(separator: ", ")

        let prompt = """
        Extract transaction details from this forwarded bank or wallet notification text \
        (SMS, push notification, email snippet, etc.). Reply with ONLY a single-line JSON \
        object, no markdown formatting, no explanation, in exactly this shape:
        {"amount": <number>, "note": "<merchant or short description>", "category": "<name or null>"}

        Rules:
        - "amount" must be a plain positive number (no currency symbol, no thousands separator).
        - "note" should be a short merchant name or description suitable as a transaction note.
        - "category" must be exactly one of these names if one clearly fits, otherwise null: \(categoryList)

        Text:
        \"\"\"
        \(trimmedText)
        \"\"\"
        """

        guard let responseText = await requestSuggestion(prompt: prompt, apiKey: apiKey, maxTokens: 200) else {
            return nil
        }
        return parseExtraction(responseText)
    }

    /// Exposed (rather than private) so tests can exercise malformed-JSON handling directly.
    static func parseExtraction(_ text: String) -> ExtractedTransaction? {
        guard
            let jsonStart = text.firstIndex(of: "{"),
            let jsonEnd = text.lastIndex(of: "}"),
            let data = text[jsonStart...jsonEnd].data(using: .utf8),
            let raw = try? JSONDecoder().decode(RawExtraction.self, from: data),
            raw.amount > 0
        else { return nil }

        return ExtractedTransaction(
            amount: Decimal(raw.amount),
            note: raw.note.trimmingCharacters(in: .whitespacesAndNewlines),
            categoryName: raw.category?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Networking

    private static func requestSuggestion(prompt: String, apiKey: String, maxTokens: Int = 20) async -> String? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body = MessagesRequest(
            model: model,
            maxTokens: maxTokens,
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
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // Network failure, decoding failure, cancellation — all treated as "no suggestion".
            return nil
        }
    }

    // MARK: - Matching

    /// Deterministic, offline category match: does an active category's own name appear as a
    /// case-insensitive substring of `note` (or vice versa — covers a short note like "Gym"
    /// matching a longer category name like "Gym Membership")? Reuses the caller's real
    /// `Category` rows exactly as `matchCategory(named:in:)` does — never invents a name, only
    /// ever returns one of `categories`. Internal (not `private`) so it's directly unit-testable
    /// without a `ModelContext`.
    ///
    /// When more than one category matches, the longest matching category name wins, so a more
    /// specific category (e.g. "Fast Food") is preferred over a shorter, coincidentally-matching
    /// one (e.g. "Food"). Exposed as its own function (rather than folded into `suggestCategory`)
    /// so it stays testable as a pure function and so `suggestCategory` can try it before ever
    /// requiring an API key.
    static func localCategoryMatch(for note: String, in categories: [Category]) -> Category? {
        let normalizedNote = note.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedNote.isEmpty else { return nil }

        let matches = categories.compactMap { category -> (Category, Int)? in
            let normalizedName = category.name.lowercased()
            guard !normalizedName.isEmpty else { return nil }
            guard normalizedNote.contains(normalizedName) || normalizedName.contains(normalizedNote) else { return nil }
            return (category, normalizedName.count)
        }

        return matches.max { $0.1 < $1.1 }?.0
    }

    private static func matchCategory(named suggestion: String, in categories: [Category]) -> Category? {
        let normalized = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.caseInsensitiveCompare("None") != .orderedSame else {
            return nil
        }
        return categories.first { $0.name.caseInsensitiveCompare(normalized) == .orderedSame }
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

        return sanitizedAPIKey(from: key)
    }

    /// nil for an empty/whitespace-only key or the still-unfilled placeholder; the trimmed key otherwise.
    /// Exposed (rather than private) so tests can cover the placeholder case without a Secrets.plist.
    static func sanitizedAPIKey(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "INSERT_YOUR_ANTHROPIC_API_KEY_HERE" else { return nil }
        return trimmed
    }
}

/// Result of `CategorizationService.extractTransaction(from:)`.
struct ExtractedTransaction {
    let amount: Decimal
    let note: String
    /// Name of the best-matching existing category, or nil if none fit well.
    let categoryName: String?
}

private struct RawExtraction: Decodable {
    let amount: Double
    let note: String
    let category: String?
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
