import Foundation

// MARK: - Request building (pure, testable without any network access)

/// Builds the exact request body sent to Anthropic for one semantic-interpretation call — a pure
/// function so its output can be inspected in tests without a live network call. Never includes a
/// transaction, budget, amount, or any other financial figure — only the question text, today's
/// date, and category *names* (see `AskClaritySemanticContext`).
enum AskClaritySemanticRequestBuilder {
    /// Field-by-field rules for the JSON Claude must reply with. Mirrors
    /// `AskClaritySemanticResponseParser`'s `RawInterpretation` exactly — if one changes, the
    /// other must too.
    static let instructions = """
    You are a strict semantic classifier for a personal finance app called Clarity. You never \
    calculate amounts, balances, or totals — those are computed entirely outside of you, by the \
    app's own deterministic engine, from the user's real transaction data, which you never see. \
    You never answer general-knowledge questions, hold a conversation, or act as an assistant for \
    anything outside this one task.

    Your only job: read one financial question about the user's own Clarity data and map it onto \
    the fixed vocabulary below. Reply with ONLY a single-line JSON object, no markdown formatting, \
    no explanation, in exactly this shape:

    {"supported":<bool>,"metric":<string|null>,"categoryName":<string|null>,"period":<object|null>,\
    "ranking":<string|null>,"budgetState":<string|null>,"wantsBreakdown":<bool>,"wantsTrend":<bool>,\
    "trendSpan":<int|null>,"wantsList":<bool>,"wantsTransactionRanking":<bool>,\
    "wantsAssessment":<bool>,"comparisonRequested":<bool>}

    Field rules — follow these exactly, never invent a value outside them:
    - "metric": one of "spending","income","remainingBudget","savings", or null if no metric was named.
    - "categoryName": copied EXACTLY (same spelling/casing) from the provided category list if the \
    question is about one specific category, else null. Never invent a name that isn't in the list.
    - "period": null if no time period was mentioned, or one of:
      {"kind":"named","value":"today"|"yesterday"|"thisWeek"|"lastWeek"|"thisWeekend"|"lastWeekend"|"thisMonth"|"lastMonth"}
      {"kind":"specificMonth","monthName":"<full month name, e.g. September>"}
      {"kind":"dateRange","startDate":"YYYY-MM-DD","endDate":"YYYY-MM-DD"} (endDate inclusive)
    - "ranking": "highest" or "lowest" if the question asks for a top/bottom category or expense, else null.
    - "budgetState": "overBudget","approachingLimit", or "withinBudget" if the question asks about \
    budget status, else null.
    - "wantsBreakdown": true only if the question asks for a full breakdown/split by category.
    - "wantsTrend": true only if the question asks how something changed/trended over several periods.
    - "trendSpan": an integer period count if a specific one was named ("the last 6 months" -> 6), else null.
    - "wantsList": true if the question asks for a plural list ("categories","expenses") rather than one figure.
    - "wantsTransactionRanking": true if the question is about a single transaction/expense, not a category total.
    - "wantsAssessment": true if the question asks for a judgment ("am I spending too much on X").
    - "comparisonRequested": true if the question asks to compare against a previous period.

    Set "supported" to false (and leave every other field at its default: null, or false) whenever \
    the question is not about the user's own Clarity financial data, is a general-knowledge or \
    unrelated question, asks you to do something other than classify (e.g. calculate, chat, give \
    advice outside this vocabulary), or you cannot confidently map it onto the vocabulary above. \
    When in doubt, set "supported" to false rather than guessing.
    """

    /// `nil` only on a JSON-encoding failure (should not happen for this fixed shape) — never a
    /// validation failure, since everything here is already-trusted local data.
    static func requestBody(context: AskClaritySemanticContext, model: String, limits: AskClaritySemanticLimits) -> Data? {
        let truncatedQuestion = String(context.question.prefix(limits.maxQuestionLength))
        let categoryNames = Array(context.availableCategoryNames.prefix(limits.maxCategoryNames))
        let todayString = Self.dateOnlyFormatter.string(from: context.today)

        let userMessage = """
        \(instructions)

        Today's date: \(todayString)
        Available category names: \(categoryNames.isEmpty ? "(none)" : categoryNames.joined(separator: ", "))

        Question: "\(truncatedQuestion)"
        """

        let body = AskClaritySemanticMessagesRequest(
            model: model,
            maxTokens: limits.maxOutputTokens,
            messages: [.init(role: "user", content: userMessage)],
            outputConfig: .init(effort: "low")
        )
        return try? JSONEncoder().encode(body)
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - Response parsing (pure, testable without any network access)

/// Parses and *validates* a provider's raw text reply into an `AskClaritySemanticInterpretation`
/// — every enum-shaped field is checked against this app's real vocabulary here; an unrecognized
/// string (a hallucinated value outside what the prompt described), a malformed date, or any
/// decode failure at all returns `nil` (or folds the field to `nil`/`false`) rather than a
/// partially-trusted result passing further down the pipeline.
enum AskClaritySemanticResponseParser {
    /// Locates the first top-level `{...}` object in `rawText` (mirrors `CategorizationService.
    /// parseExtraction`'s own technique for extracting JSON from a model reply) and decodes it.
    static func parse(_ rawText: String) -> AskClaritySemanticInterpretation? {
        guard
            let jsonStart = rawText.firstIndex(of: "{"),
            let jsonEnd = rawText.lastIndex(of: "}"),
            jsonStart < jsonEnd,
            let data = rawText[jsonStart...jsonEnd].data(using: .utf8),
            let raw = try? JSONDecoder().decode(RawInterpretation.self, from: data)
        else { return nil }

        guard raw.supported else { return .unsupported }

        let metric = raw.metric.flatMap(AskClarityMetric.init(semanticRawValue:))
        let ranking = raw.ranking.flatMap(AskClarityRanking.init(semanticRawValue:))
        let budgetState = raw.budgetState.flatMap(AskClarityBudgetStateQuery.init(semanticRawValue:))
        let period = raw.period.flatMap(AskClaritySemanticPeriod.init(raw:))
        let trimmedCategoryName = raw.categoryName?.trimmingCharacters(in: .whitespacesAndNewlines)
        // A sane bound on a period count — the deterministic interpreter caps at 12 for the same
        // reason (`AskClarityInterpreter`'s own `maxTrendSpan`); never a runaway or negative value.
        let trendSpan = raw.trendSpan.map { max(1, min($0, 24)) }

        return AskClaritySemanticInterpretation(
            supported: true,
            metric: metric,
            categoryName: (trimmedCategoryName?.isEmpty ?? true) ? nil : trimmedCategoryName,
            period: period,
            ranking: ranking,
            budgetState: budgetState,
            wantsBreakdown: raw.wantsBreakdown ?? false,
            wantsTrend: raw.wantsTrend ?? false,
            trendSpan: trendSpan,
            wantsList: raw.wantsList ?? false,
            wantsTransactionRanking: raw.wantsTransactionRanking ?? false,
            wantsAssessment: raw.wantsAssessment ?? false,
            comparisonRequested: raw.comparisonRequested ?? false
        )
    }
}

private struct RawInterpretation: Decodable {
    let supported: Bool
    let metric: String?
    let categoryName: String?
    let period: RawPeriod?
    let ranking: String?
    let budgetState: String?
    let wantsBreakdown: Bool?
    let wantsTrend: Bool?
    let trendSpan: Int?
    let wantsList: Bool?
    let wantsTransactionRanking: Bool?
    let wantsAssessment: Bool?
    let comparisonRequested: Bool?
}

private struct RawPeriod: Decodable {
    let kind: String
    let value: String?
    let monthName: String?
    let startDate: String?
    let endDate: String?
}

private extension AskClaritySemanticPeriod {
    init?(raw: RawPeriod) {
        switch raw.kind {
        case "named":
            guard let value = raw.value, let named = AskClaritySemanticNamedPeriod(rawValue: value) else { return nil }
            self = .named(named)
        case "specificMonth":
            guard let monthName = raw.monthName?.trimmingCharacters(in: .whitespacesAndNewlines), !monthName.isEmpty else { return nil }
            self = .specificMonth(monthName: monthName)
        case "dateRange":
            guard
                let start = raw.startDate?.trimmingCharacters(in: .whitespacesAndNewlines), !start.isEmpty,
                let end = raw.endDate?.trimmingCharacters(in: .whitespacesAndNewlines), !end.isEmpty
            else { return nil }
            self = .dateRange(startDate: start, endDate: end)
        default:
            return nil
        }
    }
}

private extension AskClarityMetric {
    init?(semanticRawValue: String) {
        switch semanticRawValue {
        case "spending": self = .spending
        case "income": self = .income
        case "remainingBudget": self = .remainingBudget
        case "savings": self = .savings
        default: return nil
        }
    }
}

private extension AskClarityRanking {
    init?(semanticRawValue: String) {
        switch semanticRawValue {
        case "highest": self = .highest
        case "lowest": self = .lowest
        default: return nil
        }
    }
}

private extension AskClarityBudgetStateQuery {
    init?(semanticRawValue: String) {
        switch semanticRawValue {
        case "overBudget": self = .overBudget
        case "approachingLimit": self = .approachingLimit
        case "withinBudget": self = .withinBudget
        default: return nil
        }
    }
}

// MARK: - Wire models

/// Mirrors `CategorizationService`'s own (file-private) request/response shape exactly — this
/// app's existing convention for calling the Anthropic Messages API — redeclared here rather than
/// shared since the original types aren't exposed outside their file.
private struct AskClaritySemanticMessagesRequest: Encodable {
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

private struct AskClaritySemanticMessagesResponse: Decodable {
    let content: [ContentBlock]

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
}

// MARK: - Provider

/// The production `AskClaritySemanticProviding` — calls the Anthropic Messages API with a small,
/// low-cost model appropriate for a single-question classification call (not the flagship model
/// `CategorizationService`/`SpendingInsightsService` use for richer generation tasks), asks for a
/// strict single-line JSON classification, and fails safe (returns `nil`) on absolutely any
/// problem: missing/placeholder API key, network failure, non-2xx response, malformed JSON, or a
/// value outside this app's own vocabulary. Never retries on its own — `AskClarityEngine.
/// respondWithSemanticFallback` already only calls this once per question, and this type adds no
/// retry loop on top of that.
///
/// Never touches `SwiftData`, `Entry`, `Budget`, or any Decimal amount — its only input is
/// `AskClaritySemanticContext` (question text + category *names* + today's date), and its only
/// output is the tiny, fully-validated `AskClaritySemanticInterpretation`. All financial
/// calculation still happens exactly where it always has — `AskClarityExecutor`, via the existing
/// calculators — this type has no way to reach that code at all.
final class AnthropicClaritySemanticProvider: AskClaritySemanticProviding {
    /// A low-cost, low-latency model — appropriate for a single-question classification call.
    private static let model = "claude-haiku-4-5-20251001"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private let limits: AskClaritySemanticLimits
    private let session: URLSession

    init(limits: AskClaritySemanticLimits = .default, session: URLSession? = nil) {
        self.limits = limits
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // Short, fixed timeouts — a semantic classification call that hasn't returned quickly
            // has no business hanging the conversation; the caller already treats any failure
            // (including a timeout) as "fall back to the local 'I couldn't understand that' answer".
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 10
            self.session = URLSession(configuration: configuration)
        }
    }

    func interpret(context: AskClaritySemanticContext) async -> AskClaritySemanticInterpretation? {
        let trimmedQuestion = context.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else { return nil }
        guard let apiKey = Self.apiKey else { return nil }
        guard let bodyData = AskClaritySemanticRequestBuilder.requestBody(context: context, model: Self.model, limits: limits) else {
            return nil
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = bodyData

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(AskClaritySemanticMessagesResponse.self, from: data)
            guard let text = decoded.content.first(where: { $0.type == "text" })?.text else { return nil }
            return AskClaritySemanticResponseParser.parse(text)
        } catch {
            // Network failure, decode failure, cancellation, timeout — all "no interpretation
            // available"; the caller already falls back to the local "I couldn't understand that"
            // answer, so nothing here ever surfaces as a crash or an unhandled error.
            return nil
        }
    }

    // MARK: - API key

    /// Reads `ANTHROPIC_API_KEY` from `Secrets.plist` (gitignored) — the exact same convention
    /// `CategorizationService`/`SpendingInsightsService` already use, including
    /// `CategorizationService.sanitizedAPIKey` for the empty/placeholder-value check, so there's
    /// only ever one definition of "is there really a usable key" in this app.
    private static var apiKey: String? {
        guard
            let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            let key = plist["ANTHROPIC_API_KEY"] as? String
        else { return nil }
        return CategorizationService.sanitizedAPIKey(from: key)
    }
}
