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
    anything outside this one task. You are a classifier, not a guesser: when a detail is genuinely \
    ambiguous, you say so instead of picking one of several plausible readings.

    Your only job: read one financial question about the user's own Clarity data and map it onto \
    the fixed vocabulary below. Reply with ONLY a single-line JSON object, no markdown formatting, \
    no explanation, in exactly this shape:

    {"result":<string>,"metric":<string|null>,"categoryName":<string|null>,"period":<object|null>,\
    "ranking":<string|null>,"budgetState":<string|null>,"wantsBreakdown":<bool>,"wantsTrend":<bool>,\
    "trendSpan":<int|null>,"wantsList":<bool>,"wantsTransactionRanking":<bool>,\
    "wantsAssessment":<bool>,"comparisonRequested":<bool>}

    Field rules — follow these exactly, never invent a value outside them:
    - "result": exactly one of "understood", "unsupported", or "needsClarification" — see below.
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

    Fixed word rules — these never vary between calls, and override your own judgment:
    - "recently", "lately", and "recent" ALWAYS mean exactly {"kind":"named","value":"thisWeek"}. \
    Never map them to any other period (not "thisWeekend", not "thisMonth", not anything else) — \
    this is a fixed definition in Clarity, not a judgment call you make per question.
    - "a lot", "too much", "excessive", and similar intensifiers about spending always set \
    "wantsAssessment" to true. They are never a period, a category, or a numeric value.

    Deciding "result":
    - "unsupported": the question is not about the user's own Clarity financial data — general \
    knowledge, small talk, or asking you to do something other than classify (e.g. calculate, give \
    advice, chat).
    - "needsClarification": the question IS about the user's own Clarity data, but some required \
    detail (which period, which category, what's actually being asked) has no single safe reading \
    under the field rules above and isn't covered by a fixed word rule either — for example a \
    vague time reference with no fixed mapping, or a category-like word that doesn't match any \
    name in the provided list closely enough to be confident. Prefer this over guessing.
    - "understood": you can confidently fill in every field above from the fixed vocabulary and \
    fixed word rules, with nothing left to guess.
    When any field would otherwise require a guess between more than one plausible value, use \
    "needsClarification" instead of picking one — consistency across identical or near-identical \
    questions matters more than answering every question.
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
            // Minimizes (never fully guarantees — the API documents no hard determinism promise
            // even at 0) sampling variability between identical calls; `AskClaritySemanticAmbiguityRules`
            // is the actual guarantee for the specific words that must never vary, this is
            // defense in depth for everything else.
            temperature: 0
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
    /// `nil` covers every malformed case (no JSON found, decode failure, an unrecognized `"result"`
    /// string the model hallucinated) — those are provider failures, not a valid three-way answer,
    /// so they're indistinguishable from a network error by the time they reach the caller.
    static func parse(_ rawText: String) -> AskClaritySemanticOutcome? {
        guard
            let jsonStart = rawText.firstIndex(of: "{"),
            let jsonEnd = rawText.lastIndex(of: "}"),
            jsonStart < jsonEnd,
            let data = rawText[jsonStart...jsonEnd].data(using: .utf8),
            let raw = try? JSONDecoder().decode(RawInterpretation.self, from: data)
        else { return nil }

        switch raw.result {
        case "unsupported": return .unsupported
        case "needsClarification": return .needsClarification
        case "understood": break
        default: return nil // hallucinated a value outside the fixed three — never guessed at
        }

        let metric = raw.metric.flatMap(AskClarityMetric.init(semanticRawValue:))
        let ranking = raw.ranking.flatMap(AskClarityRanking.init(semanticRawValue:))
        let budgetState = raw.budgetState.flatMap(AskClarityBudgetStateQuery.init(semanticRawValue:))
        let period = raw.period.flatMap(AskClaritySemanticPeriod.init(raw:))
        let trimmedCategoryName = raw.categoryName?.trimmingCharacters(in: .whitespacesAndNewlines)
        // A sane bound on a period count — the deterministic interpreter caps at 12 for the same
        // reason (`AskClarityInterpreter`'s own `maxTrendSpan`); never a runaway or negative value.
        let trendSpan = raw.trendSpan.map { max(1, min($0, 24)) }

        let interpretation = AskClaritySemanticInterpretation(
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
        return .understood(interpretation)
    }
}

private struct RawInterpretation: Decodable {
    let result: String
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

// MARK: - Response phrasing (pure, testable without any network access)

/// Builds the request for turning one already-verified `AskClarityAnswer` into a more natural
/// rephrasing — mirrors `AskClaritySemanticRequestBuilder`'s own shape and conventions exactly.
/// Never includes a transaction, `Category` object, or any other raw financial data — only the two
/// text fields a user would already see, plus their original question (see
/// `AskClarityPhrasingContext`).
enum AskClarityPhrasingRequestBuilder {
    static let instructions = """
    You are a wording assistant for a personal finance app called Clarity. You never calculate, \
    look up, or have access to any financial data yourself — every number, category name, date, \
    and period below has ALREADY been computed and verified by Clarity's own deterministic engine, \
    from the user's real data, which you never see. Your only job is to rephrase the given answer \
    into a short, natural, conversational reply to the user's question. You never answer \
    general-knowledge questions, hold a conversation about anything else, or act as an assistant \
    for anything outside this one wording task.

    Rules — follow these exactly:
    - Copy every number, amount, percentage, and currency figure EXACTLY character-for-character \
    as given in the verified headline/supporting detail below — never round, recompute, reformat, \
    or invent one, and never drop one that was given.
    - Never invent, rename, or omit a category name, period, or date that appears in the verified \
    text below.
    - Never add financial advice, warnings, or suggestions unless the verified text already \
    contains them.
    - If the verified text says data is insufficient, unavailable, or not found, your reply must \
    also convey that — never fill in a number or invent an answer instead.
    - Keep it short: one or two natural sentences, conversational in tone, addressing what the \
    user actually asked, not a longer essay than the original.
    - Never mention anything outside of Clarity's own financial data — you are not a general \
    assistant and this is not a conversation about anything else.

    Reply with ONLY a single-line JSON object, no markdown formatting, no explanation, in exactly \
    this shape:

    {"headline":"<string>","supportingDetail":"<string>"}

    "supportingDetail" may be an empty string "" if everything reads naturally as one line in \
    "headline" alone — do not pad it just to fill the field.
    """

    static func requestBody(context: AskClarityPhrasingContext, model: String, limits: AskClaritySemanticLimits) -> Data? {
        let truncatedQuestion = String(context.question.prefix(limits.maxQuestionLength))

        let userMessage = """
        \(instructions)

        User's question: "\(truncatedQuestion)"
        Verified headline: "\(context.headline)"
        Verified supporting detail: "\(context.supportingDetail.isEmpty ? "(none)" : context.supportingDetail)"
        Data sufficient: \(context.hasSufficientData)
        """

        let body = AskClaritySemanticMessagesRequest(
            model: model,
            maxTokens: limits.maxOutputTokens,
            messages: [.init(role: "user", content: userMessage)],
            temperature: 0
        )
        return try? JSONEncoder().encode(body)
    }
}

/// Parses a provider's raw text reply into an `AskClarityPhrasedResponse` — note this parser only
/// validates *shape* (valid JSON, a non-empty headline); it deliberately does not attempt to
/// validate the wording's factual content itself, since that is exactly what
/// `AskClarityPhrasingFidelity.preservesFacts` does next, against the original verified text this
/// parser never even sees.
enum AskClarityPhrasingResponseParser {
    static func parse(_ rawText: String) -> AskClarityPhrasedResponse? {
        guard
            let jsonStart = rawText.firstIndex(of: "{"),
            let jsonEnd = rawText.lastIndex(of: "}"),
            jsonStart < jsonEnd,
            let data = rawText[jsonStart...jsonEnd].data(using: .utf8),
            let raw = try? JSONDecoder().decode(RawPhrasedResponse.self, from: data)
        else { return nil }

        let headline = raw.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !headline.isEmpty else { return nil }
        let supportingDetail = (raw.supportingDetail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return AskClarityPhrasedResponse(headline: headline, supportingDetail: supportingDetail)
    }
}

private struct RawPhrasedResponse: Decodable {
    let headline: String
    let supportingDetail: String?
}

// MARK: - Wire models

/// Mirrors `CategorizationService`'s own (file-private) request/response shape — redeclared here
/// rather than shared since the original types aren't exposed outside their file. Deliberately
/// omits `output_config`/`effort`: that field is specific to `CategorizationService`/
/// `SpendingInsightsService`'s `claude-opus-5` calls, and the Messages API rejects it outright for
/// `claude-haiku-4-5-20251001` ("This model does not support the effort parameter") — confirmed
/// against the live API during manual validation of this provider.
private struct AskClaritySemanticMessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let messages: [Message]
    let temperature: Double

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case messages
        case temperature
    }

    struct Message: Encodable {
        let role: String
        let content: String
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

/// The production `AskClaritySemanticProviding` *and* `AskClarityPhrasingProviding` — calls the
/// Anthropic Messages API with a small, low-cost model appropriate for both a single-question
/// classification call and a short wording pass (not the flagship model `CategorizationService`/
/// `SpendingInsightsService` use for richer generation tasks). Both concerns share the exact same
/// networking, API key handling, and timeout policy (`sendMessage(_:)` below) — genuinely one
/// Anthropic provider serving two purposes, not two parallel implementations. Fails safe (returns
/// `nil`) on absolutely any problem: missing/placeholder API key, network failure, non-2xx
/// response, malformed JSON, or a value outside this app's own vocabulary. Never retries on its
/// own — callers (`AskClarityEngine.respondWithSemanticFallback`/`.phrasedNaturally`) already only
/// call each method once per question, and this type adds no retry loop on top of that.
///
/// Never touches `SwiftData`, `Entry`, `Budget`, or any Decimal amount — `interpret`'s only input
/// is `AskClaritySemanticContext` (question text + category *names* + today's date) and `phrase`'s
/// only input is `AskClarityPhrasingContext` (question text + an already-verified answer's own
/// display text). All financial calculation still happens exactly where it always has —
/// `AskClarityExecutor`, via the existing calculators — this type has no way to reach that code at
/// all, and `phrase` in particular never sees anything that could let it invent a number in the
/// first place.
final class AnthropicClaritySemanticProvider: AskClaritySemanticProviding, AskClarityPhrasingProviding {
    /// A low-cost, low-latency model — appropriate for both a single-question classification call
    /// and a short wording pass.
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
            // Short, fixed timeouts — neither a classification call nor a wording pass has any
            // business hanging the conversation; callers already treat any failure (including a
            // timeout) as "fall back to the existing deterministic answer".
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 10
            self.session = URLSession(configuration: configuration)
        }
    }

    func interpret(context: AskClaritySemanticContext) async -> AskClaritySemanticOutcome? {
        let trimmedQuestion = context.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else { return nil }
        guard let bodyData = AskClaritySemanticRequestBuilder.requestBody(context: context, model: Self.model, limits: limits) else {
            return nil
        }
        guard let text = await sendMessage(bodyData) else { return nil }
        return AskClaritySemanticResponseParser.parse(text)
    }

    func phrase(context: AskClarityPhrasingContext) async -> AskClarityPhrasedResponse? {
        guard !context.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let bodyData = AskClarityPhrasingRequestBuilder.requestBody(context: context, model: Self.model, limits: limits) else {
            return nil
        }
        guard let text = await sendMessage(bodyData) else { return nil }
        return AskClarityPhrasingResponseParser.parse(text)
    }

    /// The one place this provider ever touches the network — shared by `interpret` and `phrase`
    /// alike, so the API key check, headers, timeout policy, and error handling exist exactly once.
    private func sendMessage(_ bodyData: Data) async -> String? {
        guard let apiKey = Self.apiKey else { return nil }

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
            return decoded.content.first(where: { $0.type == "text" })?.text
        } catch {
            // Network failure, decode failure, cancellation, timeout — all "nothing usable came
            // back"; every caller already falls back to its own existing deterministic answer, so
            // nothing here ever surfaces as a crash or an unhandled error.
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
