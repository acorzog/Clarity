import Foundation

// MARK: - Semantic interpretation types
//
// Phase 5: an optional, LLM-backed *second* interpreter for "Ask Clarity," consulted only when
// the fully local, deterministic `AskClarityInterpreter` finds no signal at all in a question
// (see `AskClarityEngine.respondWithSemanticFallback`). Everything in this file is provider-
// agnostic — it knows nothing about Anthropic, networking, or API keys (see
// `AnthropicClaritySemanticProvider.swift` for that). What it defines is the tiny, fully-
// validated shape any semantic provider's output must already be in by the time it reaches
// `AskClaritySemanticQueryBuilder`, and how that shape becomes the exact same `AskClarityQuery`
// the deterministic interpreter itself produces — reusing its category/period resolution rather
// than a second copy of that logic. No financial calculation happens anywhere in this file: it
// only ever decides *what* is being asked, never *how much* the answer is.

/// What a semantic provider decided about one question — a closed, three-way outcome rather than a
/// single "supported" bool, so "this is genuinely outside Clarity" (`.unsupported`) and "this is
/// about Clarity data but too ambiguous to map safely" (`.needsClarification`) are never conflated.
/// A provider (or a sampling fluke) guessing between two plausible readings of the same question —
/// the instability this type exists to close off — must instead say so explicitly via
/// `.needsClarification`, never silently pick one.
enum AskClaritySemanticOutcome: Equatable {
    case understood(AskClaritySemanticInterpretation)
    case unsupported
    case needsClarification
}

/// The tiny, fully-validated slice of `AskClarityQuery` a semantic interpretation is allowed to
/// express — every field mirrors one the deterministic `AskClarityInterpreter` already recognizes,
/// and nothing else (no raw text, no free-form fields). Built once, by
/// `AskClaritySemanticResponseParser.parse(_:)`, from a provider's raw output; every field is
/// already checked against this app's real vocabulary by the time this struct exists, so nothing
/// downstream needs to "trust the model." Only ever exists wrapped in `AskClaritySemanticOutcome.
/// understood` — there is no "unsupported" instance of this type any more (see `AskClaritySemanticOutcome`).
struct AskClaritySemanticInterpretation: Equatable {
    let metric: AskClarityMetric?
    /// Must exactly name one of the categories/head categories this app actually has — resolved
    /// through the exact same `AskClarityInterpreter.matchCategoryName` the deterministic path
    /// uses. The provider never sees a real `Category` object, only names.
    let categoryName: String?
    let period: AskClaritySemanticPeriod?
    let ranking: AskClarityRanking?
    let budgetState: AskClarityBudgetStateQuery?
    let wantsBreakdown: Bool
    let wantsTrend: Bool
    let trendSpan: Int?
    let wantsList: Bool
    let wantsTransactionRanking: Bool
    let wantsAssessment: Bool
    let comparisonRequested: Bool
}

/// The period half of `AskClaritySemanticInterpretation` — its own small enum (not a raw
/// `AskClarityPeriodKind`/`Date`) so a malformed date string is rejected right at the parsing
/// boundary, before any `Date` construction is attempted.
enum AskClaritySemanticPeriod: Equatable {
    /// One of the eight fixed named periods — no resolution needed beyond a label lookup.
    case named(AskClaritySemanticNamedPeriod)
    /// A bare month name ("September") — resolved the same "most recent past-or-current
    /// occurrence" way `AskClarityInterpreter.resolveMonthStart` already does for the local path.
    case specificMonth(monthName: String)
    /// `"YYYY-MM-DD"` on both ends, `endDate` *inclusive* (more natural for a model to reason
    /// about than this app's own internal exclusive-end convention — the query builder converts).
    case dateRange(startDate: String, endDate: String)
}

enum AskClaritySemanticNamedPeriod: String, Equatable {
    case today, yesterday, thisWeek, lastWeek, thisWeekend, lastWeekend, thisMonth, lastMonth

    var periodKind: AskClarityPeriodKind {
        switch self {
        case .today: return .today
        case .yesterday: return .yesterday
        case .thisWeek: return .thisWeek
        case .lastWeek: return .lastWeek
        case .thisWeekend: return .thisWeekend
        case .lastWeekend: return .lastWeekend
        case .thisMonth: return .thisMonth
        case .lastMonth: return .lastMonth
        }
    }

    /// Matches the literal label `AskClarityInterpreter.parsePeriod` already uses for the same
    /// kind — not re-derived logic, just the same fixed strings kept in sync by hand (there are
    /// only eight, and both sides are in this one module).
    var label: String {
        switch self {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .thisWeek: return "this week"
        case .lastWeek: return "last week"
        case .thisWeekend: return "this weekend"
        case .lastWeekend: return "last weekend"
        case .thisMonth: return "this month"
        case .lastMonth: return "last month"
        }
    }
}

// MARK: - Query builder

/// Converts a validated `AskClaritySemanticInterpretation` into the exact same `AskClarityQuery`
/// shape the deterministic `AskClarityInterpreter` produces — reusing its own category/period
/// resolution helpers (`AskClarityInterpreter.matchCategoryName`, `.resolveMonthStart`,
/// `.dateRangeLabel`) rather than a second copy of that logic, so a category or period resolves
/// identically no matter which interpreter recognized the question. Every failure path returns
/// `nil` — an unresolvable category name, an invalid calendar date, a malformed or backwards
/// range — never silently guessed at, exactly like the deterministic interpreter's own rules.
/// Once a `AskClarityQuery` comes out of this, it is indistinguishable from one the deterministic
/// interpreter built, and is handled by `AskClarityPlanner`/`AskClarityExecutor` identically.
enum AskClaritySemanticQueryBuilder {
    /// `question` is the original raw text — used only to enforce `AskClaritySemanticAmbiguityRules`
    /// (e.g. forcing "recently"/"lately"/"recent" to the same fixed period regardless of what the
    /// provider itself returned for `interpretation.period`); it plays no other role here and is
    /// never sent anywhere past this point.
    static func buildQuery(
        from interpretation: AskClaritySemanticInterpretation,
        question: String,
        categories: [Category],
        today: Date,
        calendar: Calendar = .current
    ) -> AskClarityQuery? {
        var query = AskClarityQuery()
        query.metric = interpretation.metric
        query.ranking = interpretation.ranking
        query.budgetState = interpretation.budgetState
        query.wantsBreakdown = interpretation.wantsBreakdown
        query.wantsTrend = interpretation.wantsTrend
        query.trendSpan = interpretation.trendSpan
        query.wantsList = interpretation.wantsList
        query.wantsTransactionRanking = interpretation.wantsTransactionRanking
        query.wantsAssessment = interpretation.wantsAssessment
        query.comparisonRequested = interpretation.comparisonRequested

        if let categoryName = interpretation.categoryName {
            // `matchCategoryName` expects already-lowercased input — the deterministic path only
            // ever calls it after `normalize(rawText)` has lowercased the whole question; a
            // semantic provider's `categoryName` keeps its original casing ("Restaurants"), so it
            // needs the same lowercasing applied here before matching against it.
            guard let match = AskClarityInterpreter.matchCategoryName(in: categoryName.lowercased(), categories: categories) else {
                // Named a category that doesn't resolve to any real category/head category —
                // never guessed at; the whole interpretation is discarded, not partially used.
                return nil
            }
            query.categoryMatch = match
        }

        let stabilizedPeriod = AskClaritySemanticAmbiguityRules.stabilizedPeriod(interpretation.period, forQuestion: question)
        if let stabilizedPeriod {
            guard let periodMatch = resolvePeriod(stabilizedPeriod, today: today, calendar: calendar) else { return nil }
            query.periodMatch = periodMatch
        }

        // A semantic interpretation is always a fresh, self-contained question — it never
        // participates in the deterministic path's pronoun/minimal-follow-up context inheritance
        // (that's a text-shape signal the LLM never sees or produces), so both flags stay false.
        query.usedContextualReference = false
        query.isMinimalFollowUp = false

        let hasAnySignal = query.metric != nil || query.categoryMatch != nil || query.ranking != nil
            || query.budgetState != nil || query.periodMatch != nil || query.comparisonRequested
            || query.wantsBreakdown || query.wantsTrend || query.wantsAssessment
        guard hasAnySignal else { return nil }

        return query
    }

    private static func resolvePeriod(_ period: AskClaritySemanticPeriod, today: Date, calendar: Calendar) -> AskClarityPeriodMatch? {
        switch period {
        case .named(let named):
            return .supported(AskClarityPeriod(kind: named.periodKind, label: named.label))

        case .specificMonth(let monthName):
            guard
                let monthNumber = AskClarityInterpreter.monthNumber(named: monthName),
                let candidate = AskClarityInterpreter.resolveMonthStart(month: monthNumber, today: today, calendar: calendar)
            else { return nil }
            let label = candidate.formatted(.dateTime.month(.wide).year())
            return .supported(AskClarityPeriod(kind: .specificMonth(candidate), label: label))

        case .dateRange(let startDateString, let endDateString):
            guard
                let start = Self.parseISODate(startDateString, calendar: calendar),
                let endInclusive = Self.parseISODate(endDateString, calendar: calendar),
                let end = calendar.date(byAdding: .day, value: 1, to: endInclusive),
                start < end
            else { return nil }
            let label = AskClarityInterpreter.dateRangeLabel(start: start, end: end, calendar: calendar)
            return .supported(AskClarityPeriod(kind: .dateRange(start: start, end: end), label: label))
        }
    }

    private static func parseISODate(_ string: String, calendar: Calendar) -> Date? {
        guard string.count == 10 else { return nil } // strict "YYYY-MM-DD", never a looser format
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }
}

// MARK: - Ambiguity stabilization

/// Fixed, code-level (not prompt-level) rules for words whose calendar meaning must never depend
/// on model sampling. `AskClaritySemanticRequestBuilder.instructions` already tells the model the
/// same rule, but wording alone only makes a period *likely* consistent across calls (even at
/// temperature 0, the API gives no hard determinism guarantee) — this enum makes it *actually*
/// consistent, by overriding whatever period a provider returned whenever one of these words is
/// present, rather than trusting the model to have applied its own instructions correctly and
/// identically every time. This is the single place "same question -> same query" is enforced.
enum AskClaritySemanticAmbiguityRules {
    /// "recently"/"lately"/"recent" have no single safe meaning across Clarity's period vocabulary
    /// (a plausible reading could span days or months) — Clarity fixes them, once, to `thisWeek`:
    /// short enough to actually mean "recently," never `thisWeekend`/`thisMonth`/anything else.
    private static let fixedRecentPeriodWords: Set<String> = ["recently", "lately", "recent"]
    private static let fixedRecentPeriod = AskClaritySemanticPeriod.named(.thisWeek)

    /// Returns `interpretation.period` unchanged unless `question` contains one of the fixed-period
    /// trigger words as a whole word, in which case it always returns the same fixed period —
    /// regardless of what the provider itself claimed, and regardless of whether the provider named
    /// a period at all.
    static func stabilizedPeriod(_ period: AskClaritySemanticPeriod?, forQuestion question: String) -> AskClaritySemanticPeriod? {
        let words = Set(question.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        guard words.contains(where: fixedRecentPeriodWords.contains) else { return period }
        return fixedRecentPeriod
    }
}

// MARK: - Provider abstraction

/// What a semantic provider needs to classify one question — deliberately tiny: the raw question,
/// today's date, and the category *names* the provider is allowed to reference back. Never a
/// transaction, budget, amount, or any other financial figure — the semantic layer classifies
/// *what* is being asked, never *how much* the answer is; that stays entirely on-device, in
/// `AskClarityExecutor` and the calculators it composes.
struct AskClaritySemanticContext {
    let question: String
    let today: Date
    /// Every non-archived category/head-category name the user actually has — the *only* names a
    /// provider is allowed to reference back in `AskClaritySemanticInterpretation.categoryName`.
    let availableCategoryNames: [String]
}

/// Abstraction over "turn a free-form financial question into a small structured
/// `AskClaritySemanticInterpretation`" — kept as a protocol so the concrete provider (Anthropic
/// today, see `AnthropicClaritySemanticProvider`) can be swapped or stubbed in tests without
/// touching `AskClarityEngine`. Implementations must never throw past this boundary (fail safe:
/// return `nil`) and must never retry internally — `AskClarityEngine.respondWithSemanticFallback`
/// already calls this at most once per question.
protocol AskClaritySemanticProviding {
    /// `nil` means the provider itself failed (network error, missing key, malformed reply) — a
    /// genuinely indeterminate result, distinct from `.unsupported`/`.needsClarification`, which
    /// are valid, confident answers the provider gave about the question itself.
    func interpret(context: AskClaritySemanticContext) async -> AskClaritySemanticOutcome?
}

/// Hard caps on what a single semantic-interpretation call can cost, independent of which
/// provider is behind `AskClaritySemanticProviding` — in request size, response size, and call
/// frequency. Every default here is deliberately conservative: this is a one-shot classification
/// call, not a conversation, so there's no legitimate reason for it to be large or frequent.
struct AskClaritySemanticLimits {
    /// A question longer than this is truncated before it's ever sent — never rejected outright,
    /// since a long question is still worth a best-effort classification attempt.
    var maxQuestionLength = 300
    /// Caps how many category names are sent if a user has an unusually large category list —
    /// keeps the request small regardless of account size.
    var maxCategoryNames = 60
    var maxOutputTokens = 300
    /// Calls allowed per `AskClaritySemanticCallBudget` instance — see its own doc comment.
    var maxCallsPerSession = 20

    static let `default` = AskClaritySemanticLimits()
}

/// A simple per-session call counter — the "don't let this run away on cost across a whole
/// conversation" safeguard, consulted by `AskClarityEngine.respondWithSemanticFallback` *before*
/// ever calling the provider for a given question. (The *single-call-per-question* guarantee is
/// separate and unconditional — `respondWithSemanticFallback` itself never calls a provider more
/// than once no matter what this budget says; this only caps calls *across* questions.) One
/// instance is meant to live for as long as a conversation session does; a fresh session gets a
/// fresh budget. Not thread-safe beyond the main actor — matches how `AskClarityView`'s own
/// `@State` is already only ever touched from the main thread.
final class AskClaritySemanticCallBudget {
    private let maxCalls: Int
    private(set) var callsMade = 0

    init(maxCalls: Int = AskClaritySemanticLimits.default.maxCallsPerSession) {
        self.maxCalls = maxCalls
    }

    var hasRemainingCalls: Bool { callsMade < maxCalls }

    /// Records an attempted call regardless of whether it ultimately succeeded — a failed call
    /// still cost a network round-trip (and, if it reached the provider, tokens), so it still
    /// counts against the budget rather than letting a persistently-failing provider be retried
    /// forever across a long session.
    func recordCall() { callsMade += 1 }
}
