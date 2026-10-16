import Foundation

// MARK: - Tool catalog (pure data — no network access)

/// The fixed set of tools Claude may call to classify one question — never more than these three,
/// never a hallucinated name. Mirrors `AskClaritySemanticOutcome` exactly: one tool per outcome
/// case, with `.understood` the only one `AskClarityToolUseResponseParser` allows to be called
/// twice (see its own description below for the one two-step shape Phase 1 recognizes).
private enum AskClarityToolName: String {
    case understood = "classify_understood_question"
    case unsupported = "classify_unsupported_question"
    case needsClarification = "classify_needs_clarification"
}

/// Builds the exact tool-use request sent to Anthropic for one semantic-interpretation call — a
/// pure function so its output can be inspected in tests without a live network call. Never
/// includes a transaction, budget, amount, or any other financial figure — only the question
/// text, today's date, and category *names* (see `AskClaritySemanticContext`). Classification is
/// expressed as native Anthropic tool use (`tools`/`tool_choice`, `tool_use` content blocks in the
/// response) rather than a free-text JSON contract — the model's reply shape is constrained by the
/// Messages API itself, not only by a prompt instruction.
enum AskClarityToolUseRequestBuilder {
    /// What a JSON Schema can't express — fixed word rules that must never vary between calls, and
    /// the instruction to prefer `classify_needs_clarification` over guessing. Everything else
    /// (the field vocabulary itself) lives in `toolDefinitions`'s own `input_schema`s instead of
    /// prose, so there is no second, prose copy of the field rules to drift out of sync.
    static let systemPrompt = """
    You are a strict semantic classifier for a personal finance app called Clarity. You never \
    calculate amounts, balances, or totals — those are computed entirely outside of you, by the \
    app's own deterministic engine, from the user's real transaction data, which you never see. \
    You never answer general-knowledge questions, hold a conversation, or act as an assistant for \
    anything outside this one task.

    Classify the question by calling exactly one of your three tools, following each tool's own \
    description. Call "classify_understood_question" a second time, in parallel with the first, \
    ONLY for the specific two-step pattern its own description names — never for any other \
    reason, and never call any tool more than twice in total.

    Fixed word rules — these never vary between calls, and override your own judgment:
    - "recently", "lately", and "recent" ALWAYS mean exactly {"kind":"named","value":"thisWeek"}. \
    Never map them to any other period — this is a fixed definition in Clarity, not a judgment \
    call you make per question.
    - "a lot", "too much", "excessive", and similar intensifiers about spending always set \
    "wantsAssessment" to true. They are never a period, a category, or a numeric value.
    - Prefer "classify_needs_clarification" over guessing whenever a detail (which period, which \
    category, what's actually being asked) has no single safe reading and isn't covered by a \
    fixed word rule above — consistency across identical or near-identical questions matters more \
    than answering every question.
    """

    /// `nil` only on a JSON-serialization failure (should not happen for this fixed shape) — never
    /// a validation failure, since everything here is already-trusted local data.
    static func requestBody(context: AskClaritySemanticContext, model: String, limits: AskClaritySemanticLimits) -> Data? {
        let truncatedQuestion = String(context.question.prefix(limits.maxQuestionLength))
        let categoryNames = Array(context.availableCategoryNames.prefix(limits.maxCategoryNames))
        let todayString = Self.dateOnlyFormatter.string(from: context.today)

        let userMessage = """
        Today's date: \(todayString)
        Available category names: \(categoryNames.isEmpty ? "(none)" : categoryNames.joined(separator: ", "))

        Question: "\(truncatedQuestion)"
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": limits.maxOutputTokens,
            // Minimizes (never fully guarantees) sampling variability between identical calls —
            // same role this played in the prior prompt-JSON contract.
            "temperature": 0,
            "system": systemPrompt,
            // Forces at least one tool call every time — this provider's only job is
            // classification, so a plain-text reply would mean nothing downstream can use.
            "tool_choice": ["type": "any"],
            "tools": toolDefinitions,
            "messages": [["role": "user", "content": userMessage]]
        ]
        guard JSONSerialization.isValidJSONObject(body) else { return nil }
        return try? JSONSerialization.data(withJSONObject: body)
    }

    private static let periodSchema: [String: Any] = [
        "type": "object",
        "description": "Omit entirely if no time period was mentioned.",
        "properties": [
            "kind": ["type": "string", "enum": ["named", "specificMonth", "dateRange"]],
            "value": ["type": "string", "enum": ["today", "yesterday", "thisWeek", "lastWeek", "thisWeekend", "lastWeekend", "thisMonth", "lastMonth"], "description": "Required when kind is \"named\"."],
            "monthName": ["type": "string", "description": "Full month name (e.g. \"September\") — required when kind is \"specificMonth\"."],
            "startDate": ["type": "string", "description": "\"YYYY-MM-DD\" — required when kind is \"dateRange\"."],
            "endDate": ["type": "string", "description": "\"YYYY-MM-DD\", inclusive — required when kind is \"dateRange\"."]
        ],
        "required": ["kind"],
        "additionalProperties": false
    ]

    private static let understoodSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "metric": ["type": "string", "enum": ["spending", "income", "remainingBudget", "savings"]],
            "categoryName": ["type": "string", "description": "Copied EXACTLY (same spelling/casing) from the provided category list — never invent a name that isn't in the list."],
            "period": periodSchema,
            "ranking": ["type": "string", "enum": ["highest", "lowest"], "description": "Set only if the question asks for a top/bottom category or expense."],
            "budgetState": ["type": "string", "enum": ["overBudget", "approachingLimit", "withinBudget"], "description": "Set only if the question asks about budget status."],
            "wantsBreakdown": ["type": "boolean", "description": "True only if the question asks for a full breakdown/split by category."],
            "wantsTrend": ["type": "boolean", "description": "True only if the question asks how something changed/trended over several periods."],
            "trendSpan": ["type": "integer", "description": "Period count if a specific one was named (\"the last 6 months\" -> 6)."],
            "wantsList": ["type": "boolean", "description": "True if the question asks for a plural list rather than one figure."],
            "wantsTransactionRanking": ["type": "boolean", "description": "True if the question is about a single transaction/expense, not a category total."],
            "wantsAssessment": ["type": "boolean", "description": "True if the question asks for a judgment (\"am I spending too much on X\")."],
            "comparisonRequested": ["type": "boolean", "description": "True if the question asks to compare against a previous period."]
        ],
        "additionalProperties": false
    ]

    private static let toolDefinitions: [[String: Any]] = [
        [
            "name": AskClarityToolName.understood.rawValue,
            "description": """
            Classify ONE self-contained reading of the user's question into Clarity's fixed \
            vocabulary — every field is optional, set only the ones the question actually names. \
            Call this once for an ordinary single-step question. Call it a SECOND time, in \
            parallel with the first, only when the question explicitly asks to compare one \
            period's figure against a trailing multi-period average or trend for the exact same \
            metric and category (e.g. "compare this month's dining to the last 6 months" or "is \
            this higher than usual for groceries"). In that exact case, one call should describe \
            the single period being asked about, and the other should set wantsTrend=true with a \
            trendSpan (e.g. 6) for that same metric and category. Never call this tool for any \
            other reason, and never call it more than twice.
            """,
            "input_schema": understoodSchema
        ],
        [
            "name": AskClarityToolName.unsupported.rawValue,
            "description": "Call with no arguments if the question is not about the user's own Clarity financial data at all — general knowledge, small talk, or asking you to do something other than classify (e.g. calculate, give advice, chat).",
            "input_schema": ["type": "object", "properties": [String: Any](), "additionalProperties": false]
        ],
        [
            "name": AskClarityToolName.needsClarification.rawValue,
            "description": "Call with no arguments if the question IS about Clarity data, but some required detail (which period, which category, what's actually being asked) has no single safe reading and isn't covered by a fixed word rule. Prefer this over guessing.",
            "input_schema": ["type": "object", "properties": [String: Any](), "additionalProperties": false]
        ]
    ]

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - Tool-use response parsing (pure, testable without any network access)

/// Parses and *validates* one tool-use response into an `AskClaritySemanticOutcome` — every
/// field is checked against this app's real vocabulary here, exactly as the prior prompt-JSON
/// parser did; an unrecognized tool name, an unrecognized enum value, a malformed date, a
/// `max_tokens`-truncated response, or any decode failure at all returns `nil` (or folds the
/// field to `nil`/`false`) rather than letting a partially-trusted result pass further down the
/// pipeline. Never trusts the model just because its *shape* matched the schema — the schema
/// only constrains what Claude is syntactically able to send, not whether every value in it is
/// one this app actually has.
enum AskClarityToolUseResponseParser {
    /// `limits` is the same `AskClaritySemanticLimits` the originating request was built with
    /// (defaults to `.default` only for call sites — e.g. existing tests — that never configured
    /// a custom instance) — never a second, independent copy of the cap, so a caller that tunes
    /// `maxToolCallsPerQuestion` is actually enforced here, not just reflected in the request body.
    static func parse(_ response: AskClarityToolUseMessagesResponse, limits: AskClaritySemanticLimits = .default) -> AskClaritySemanticOutcome? {
        // A `max_tokens` stop means a tool's `input` may have been cut off mid-generation — never
        // trust a possibly-truncated classification rather than risk silently acting on a partial
        // category name or period.
        guard response.stopReason != "max_tokens" else { return nil }

        let toolUses = response.content.filter { $0.type == "tool_use" }
        guard !toolUses.isEmpty, toolUses.count <= limits.maxToolCallsPerQuestion else { return nil }

        let names = toolUses.compactMap { $0.name.flatMap(AskClarityToolName.init(rawValue:)) }
        // A tool name outside this app's own three-tool catalog — never trust a hallucinated or
        // malformed call; discard the whole response rather than use the calls that did parse.
        guard names.count == toolUses.count else { return nil }

        if names.contains(.unsupported) {
            guard names == [.unsupported] else { return nil } // never mixed with anything else
            return .unsupported
        }
        if names.contains(.needsClarification) {
            guard names == [.needsClarification] else { return nil }
            return .needsClarification
        }
        guard names.allSatisfy({ $0 == .understood }) else { return nil }

        let interpretations = toolUses.compactMap { $0.input.flatMap(interpretation(from:)) }
        // Any single call failing validation invalidates the whole response — never partially
        // trust one valid call alongside a discarded invalid one.
        guard interpretations.count == toolUses.count, !interpretations.isEmpty else { return nil }

        switch interpretations.count {
        case 1: return .understood(interpretations[0])
        case 2: return .composed(interpretations[0], interpretations[1])
        default: return nil // guarded unreachable by maxToolCallsPerQuestion above
        }
    }

    private static func interpretation(from raw: RawToolInput) -> AskClaritySemanticInterpretation? {
        let metric = raw.metric.flatMap(AskClarityMetric.init(semanticRawValue:))
        let ranking = raw.ranking.flatMap(AskClarityRanking.init(semanticRawValue:))
        let budgetState = raw.budgetState.flatMap(AskClarityBudgetStateQuery.init(semanticRawValue:))
        let period = raw.period.flatMap(AskClaritySemanticPeriod.init(raw:))
        let trimmedCategoryName = raw.categoryName?.trimmingCharacters(in: .whitespacesAndNewlines)
        // A sane bound on a period count — the deterministic interpreter caps at 12 for the same
        // reason (`AskClarityInterpreter`'s own `maxTrendSpan`); never a runaway or negative value.
        let trendSpan = raw.trendSpan.map { max(1, min($0, 24)) }

        return AskClaritySemanticInterpretation(
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

/// Internal (not `private`) — nested inside `AskClarityToolUseMessagesResponse.ContentBlock`
/// below, which must be at least as visible as `AskClarityToolUseResponseParser` itself.
struct RawToolInput: Decodable {
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

struct RawPeriod: Decodable {
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

// MARK: - Tool-use wire models

/// The subset of a Messages API response this provider's `interpret` call needs — `stopReason` to
/// reject a possibly-truncated `tool_use` input, `content` for the `tool_use` blocks themselves.
/// Internal (not `private`) so `AskClarityToolUseResponseParser` can take it as a parameter while
/// staying a pure, no-network function the tests call directly.
struct AskClarityToolUseMessagesResponse: Decodable {
    let stopReason: String?
    let content: [ContentBlock]

    enum CodingKeys: String, CodingKey {
        case stopReason = "stop_reason"
        case content
    }

    struct ContentBlock: Decodable {
        let type: String
        let name: String?
        /// Present only on a `classify_understood_question` call — the other two tools always
        /// take an empty object, which still decodes here (every field optional) as all-`nil`.
        let input: RawToolInput?
    }
}

// MARK: - Response phrasing (pure, testable without any network access)

/// Builds the request for turning one already-verified `AskClarityAnswer` into a more natural
/// rephrasing — mirrors `AskClarityToolUseRequestBuilder`'s own privacy conventions exactly, but
/// deliberately keeps its prior plain-text/JSON-prompt contract: this is a short wording pass with
/// no classification vocabulary to validate, so there is nothing tool use would add here. Never
/// includes a transaction, `Category` object, or any other raw financial data — only the two text
/// fields a user would already see, plus their original question (see `AskClarityPhrasingContext`).
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

// MARK: - Wire models (phrasing call only — interpret uses `AskClarityToolUseMessagesResponse`)

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
/// `SpendingInsightsService` use for richer generation tasks). `interpret` uses native Anthropic
/// tool use (`tools`/`tool_choice`, parsing `tool_use` content blocks) to classify a question —
/// the Messages API itself constrains the reply shape, rather than only a prompt instruction;
/// `phrase` is unchanged, a short text/JSON-prompt wording pass with no classification vocabulary
/// to gain from tool use. Both concerns share the exact same networking, API key handling, and
/// timeout policy (`sendRequest(_:)` below) — genuinely one Anthropic provider serving two
/// purposes, not two parallel implementations. Fails safe (returns `nil`) on absolutely any
/// problem: missing/placeholder API key, network failure, non-2xx response, malformed JSON, a
/// `max_tokens` truncation, an unrecognized tool name, or a value outside this app's own
/// vocabulary. Never retries on its own — callers (`AskClarityEngine.respondWithSemanticFallback`/
/// `.phrasedNaturally`) already only call each method once per question, and this type adds no
/// retry loop on top of that.
///
/// Never touches `SwiftData`, `Entry`, `Budget`, or any Decimal amount — `interpret`'s only input
/// is `AskClaritySemanticContext` (question text + category *names* + today's date) and `phrase`'s
/// only input is `AskClarityPhrasingContext` (question text + an already-verified answer's own
/// display text). No tool result is ever sent back to Claude for a second turn: a tool call here
/// *is* the classification output, not an instruction to execute something whose result Claude
/// then reasons over — so the one financial figure a tool call could ever lead to (computed by
/// `AskClarityExecutor`/`AskClaritySemanticComposition`, strictly after this provider returns)
/// never enters the request/response cycle at all. All financial calculation still happens exactly
/// where it always has — this type has no way to reach that code at all, and `phrase` in
/// particular never sees anything that could let it invent a number in the first place.
final class AnthropicClaritySemanticProvider: AskClaritySemanticProviding, AskClarityPhrasingProviding {
    /// A low-cost, low-latency model — appropriate for both a single-question classification call
    /// and a short wording pass. Supports native tool use (confirmed against the live API).
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
        guard let bodyData = AskClarityToolUseRequestBuilder.requestBody(context: context, model: Self.model, limits: limits) else {
            return nil
        }
        guard let response = await sendToolUseMessage(bodyData) else { return nil }
        return AskClarityToolUseResponseParser.parse(response, limits: limits)
    }

    func phrase(context: AskClarityPhrasingContext) async -> AskClarityPhrasedResponse? {
        guard !context.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let bodyData = AskClarityPhrasingRequestBuilder.requestBody(context: context, model: Self.model, limits: limits) else {
            return nil
        }
        guard let text = await sendMessage(bodyData) else { return nil }
        return AskClarityPhrasingResponseParser.parse(text)
    }

    /// The one place this provider ever touches the network — shared by `sendMessage` and
    /// `sendToolUseMessage` alike, so the API key check, headers, timeout policy, and transport
    /// error handling exist exactly once. Returns the raw response body on any 2xx response; `nil`
    /// on absolutely anything else (missing key, network failure, non-2xx, cancellation, timeout).
    private func sendRequest(_ bodyData: Data) async -> Data? {
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
            return data
        } catch {
            // Network failure, cancellation, timeout — all "nothing usable came back"; every
            // caller already falls back to its own existing deterministic answer, so nothing here
            // ever surfaces as a crash or an unhandled error.
            return nil
        }
    }

    /// Used by `phrase` only — decodes the plain-text reply `AskClarityPhrasingResponseParser`
    /// expects.
    private func sendMessage(_ bodyData: Data) async -> String? {
        guard let data = await sendRequest(bodyData) else { return nil }
        guard let decoded = try? JSONDecoder().decode(AskClaritySemanticMessagesResponse.self, from: data) else { return nil }
        return decoded.content.first(where: { $0.type == "text" })?.text
    }

    /// Used by `interpret` only — decodes the full tool-use response shape
    /// `AskClarityToolUseResponseParser` validates.
    private func sendToolUseMessage(_ bodyData: Data) async -> AskClarityToolUseMessagesResponse? {
        guard let data = await sendRequest(bodyData) else { return nil }
        return try? JSONDecoder().decode(AskClarityToolUseMessagesResponse.self, from: data)
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
