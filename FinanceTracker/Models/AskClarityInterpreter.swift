import Foundation

// MARK: - Entities
//
// "Ask Clarity" understands questions by extracting reusable financial *concepts* (a metric, a
// category, a time period, a ranking, a direction, a budget state) from free-typed text, then
// composing whichever existing calculation those concepts imply — rather than matching whole
// sentences against a fixed list, which is what this file replaces. Still a deterministic, local,
// controlled keyword lookup (never a language model or network call) — just one that recognizes
// parts of a question instead of only the whole thing.

/// What number the user is asking about.
enum AskClarityMetric: Equatable {
    case spending
    case income
    /// "How much budget do I have left" — `PeriodSpendingSummary.totalLeft`, not a category total.
    case remainingBudget
    /// "How much have I saved" — `PeriodSpendingSummary.savingsTransfersTotal`.
    case savings
}

/// A time period `AskClarityInterpreter` can recognize. `.today`/`.yesterday`/`.thisWeek`/
/// `.lastWeek` resolve to a raw date range (`AskClarityRangeCalculator`); the month-based cases
/// route through the existing month-anchored calculators (`BudgetCalculator`/
/// `ExplainMyMonthCalculator`) instead, since budgets themselves are calendar-month concepts.
enum AskClarityPeriodKind: Equatable {
    case today
    case yesterday
    case thisWeek
    case lastWeek
    /// Saturday + Sunday of the current Monday-first week.
    case thisWeekend
    /// Saturday + Sunday of the week before the current one.
    case lastWeekend
    case thisMonth
    case lastMonth
    /// An explicit past/future calendar month by name (first-of-month `Date`) — "in January."
    case specificMonth(Date)
    /// An explicit date range resolved once, at parse time — "September 5," "September 5 to
    /// September 18," "last 7 days," "the first two weeks of September." `end` is exclusive,
    /// matching every other raw range in this file (`>= start && < end`). Always a raw range
    /// (`isMonthBased == false`) — never routes through the budget-cycle-aware month calculators,
    /// preserving the existing calendar-period/raw-range split rather than blurring it.
    case dateRange(start: Date, end: Date)

    static func == (lhs: AskClarityPeriodKind, rhs: AskClarityPeriodKind) -> Bool {
        switch (lhs, rhs) {
        case (.today, .today), (.yesterday, .yesterday), (.thisWeek, .thisWeek), (.lastWeek, .lastWeek),
             (.thisWeekend, .thisWeekend), (.lastWeekend, .lastWeekend),
             (.thisMonth, .thisMonth), (.lastMonth, .lastMonth):
            return true
        case let (.specificMonth(a), .specificMonth(b)):
            return Calendar.current.isDate(a, equalTo: b, toGranularity: .month)
        case let (.dateRange(s1, e1), .dateRange(s2, e2)):
            return s1 == s2 && e1 == e2
        default:
            return false
        }
    }
}

struct AskClarityPeriod: Equatable {
    let kind: AskClarityPeriodKind
    /// User-facing phrase — "today," "this week," "January 2025," etc.
    let label: String
}

/// A period phrase either resolves to something `Ask Clarity` can compute, is recognized as a
/// period-shaped phrase it deliberately doesn't support yet (e.g. "this year"), or is a date/date-
/// range-shaped phrase that can't be resolved *safely* (an invalid calendar date, a range whose
/// end comes before its start). Neither of the latter two ever silently falls back to a guess —
/// `.unsupported` is answered with what *is* supported; `.ambiguous` asks the user to clarify,
/// mirroring `AskClarityCategoryMatch.ambiguous`'s own never-guess rule for categories.
enum AskClarityPeriodMatch: Equatable {
    case supported(AskClarityPeriod)
    case unsupported(String)
    case ambiguous(String)
}

enum AskClarityRanking: Equatable {
    case highest
    case lowest
}

enum AskClarityChangeDirection: Equatable {
    case increased
    case decreased
}

enum AskClarityBudgetStateQuery: Equatable {
    case overBudget
    case approachingLimit
    case withinBudget
}

/// How a category phrase in the question resolved against the user's actual categories — never
/// invented, only ever one of these outcomes.
enum AskClarityCategoryMatch: Equatable {
    case resolved(Category)
    /// The phrase explicitly named a `HeadCategory` that has more than one child — e.g.
    /// "Travelling" covering Flights, Hotel, Activities, etc. The answer aggregates across every
    /// child rather than asking which one was meant: naming the parent is itself the user's
    /// choice to see the combined total, not an ambiguous question.
    case resolvedHeadCategory(HeadCategory, categories: [Category])
    /// Kept for a genuinely ambiguous phrase that doesn't clearly name one specific category or
    /// head category (`parseCategory` no longer produces this for a named head category — see
    /// `resolvedHeadCategory` above — but the type stays available for that narrower case).
    case ambiguous(phrase: String, candidates: [Category])
    /// A category-shaped phrase (typically after "on"/"for"/"in") matched nothing at all.
    case notFound(phrase: String)

    static func == (lhs: AskClarityCategoryMatch, rhs: AskClarityCategoryMatch) -> Bool {
        switch (lhs, rhs) {
        case let (.resolved(a), .resolved(b)):
            return a === b
        case let (.resolvedHeadCategory(h1, c1), .resolvedHeadCategory(h2, c2)):
            return h1 === h2 && c1.map(\.persistentModelID) == c2.map(\.persistentModelID)
        case let (.ambiguous(p1, c1), .ambiguous(p2, c2)):
            return p1 == p2 && c1.map(\.persistentModelID) == c2.map(\.persistentModelID)
        case let (.notFound(a), .notFound(b)):
            return a == b
        default:
            return false
        }
    }
}

/// Two category-shaped phrases joined by "than" — "restaurants than groceries" — recognized as a
/// single two-sided comparison rather than one category phrase that happens to contain the word
/// "than". Both sides must independently resolve to a real category or head category; if either
/// doesn't, this simply isn't produced (see `AskClarityInterpreter.parseCategoryComparison`), so a
/// plain single-category question with an unrelated "than" elsewhere in it is never mistaken for one.
struct AskClarityCategoryComparisonQuery: Equatable {
    let first: AskClarityCategoryMatch
    let second: AskClarityCategoryMatch
}

/// One interpreted question — every field is a recognized concept, never a formatted sentence.
/// `AskClarityEngine` composes these into a calculation; `nil` fields simply weren't mentioned.
struct AskClarityQuery: Equatable {
    var metric: AskClarityMetric?
    var categoryMatch: AskClarityCategoryMatch?
    /// "Did I spend more on restaurants than groceries?" — set instead of `categoryMatch` (never
    /// both) when the question names two categories to compare directly against each other.
    var categoryComparison: AskClarityCategoryComparisonQuery?
    var periodMatch: AskClarityPeriodMatch?
    var comparisonRequested = false
    var ranking: AskClarityRanking?
    var direction: AskClarityChangeDirection?
    var budgetState: AskClarityBudgetStateQuery?
    var wantsWhyExplanation = false
    var wantsReduceAdvice = false
    /// "Show me my biggest spending *categories*" (plural) vs. a single top category/transaction.
    var wantsList = false
    /// "What was my biggest *expense*" — a single transaction, not a category total.
    var wantsTransactionRanking = false
    /// "Am I spending *too much* on X" — asks for a judgment, not just a figure.
    var wantsAssessment = false
    /// "What changed compared with last month" — a general category-change summary, distinct
    /// from `comparisonRequested` alone (which also covers "did I spend more this month than
    /// last month," a *total*-spending question that must not be routed here).
    var wantsChangeSummary = false
    /// "Breakdown of my spending," "how does my Travelling spending break down" — every
    /// category's amount for the period (`.categoryBreakdown`), as opposed to just the top one(s)
    /// (`wantsList`/ranking) or one aggregated total.
    var wantsBreakdown = false
    /// "Spending trend," "how has my income trended the last 6 months" — the same metric/subject
    /// computed across several consecutive equivalent periods (`.trend`) instead of just one.
    var wantsTrend = false
    /// The explicit period count named alongside `wantsTrend` (e.g. "the last 6 months") — `nil`
    /// when `wantsTrend` came from a bare keyword ("trend," "month by month") with no number
    /// named, letting `AskClarityExecutor` fall back to its own default span.
    var trendSpan: Int?
    /// "that," "it," "this category" — a pronoun standing in for the previous turn's subject.
    var usedContextualReference = false
    /// True when nothing about this question stands on its own (no metric/ranking/direction/
    /// budget-state/why/reduce/assessment/list of its own) — a fragment that only makes sense as
    /// a continuation. `AskClarityEngine.effectivePeriod` uses this the same way this file uses
    /// it for category/metric inheritance, so all three fields inherit under one shared rule.
    var isMinimalFollowUp = false
}

/// Lightweight, session-only memory of the last resolved subject — enables follow-ups like "and
/// last month?" to understand what "that" refers to. Never persisted beyond the current `AskClarityView`
/// instance (no `UserDefaults`/SwiftData row) — a fresh app launch or leaving the screen starts clean.
struct AskClaritySessionContext: Equatable {
    var lastCategory: Category?
    var lastMetric: AskClarityMetric?
    var lastPeriod: AskClarityPeriod?
    /// The number `lastMetric`/`lastCategory`/`lastPeriod` actually resolved to, so a follow-up in
    /// a *different* period can say "€29 less than this month (€186)" instead of only restating
    /// the new figure.
    var lastAnswerValue: Decimal?
    /// The stable comparison baseline for a chain of period-only follow-ups about the same
    /// category — set the first time a category is asked about, and deliberately left unchanged
    /// across a run of period swaps for that same category ("this week" -> "last week" -> "last
    /// month"), so every follow-up in the chain compares against that one original figure
    /// instead of silently drifting to compare against whatever the immediately-preceding turn
    /// happened to show. Reset the moment the category changes; see `AskClarityEngine.
    /// categoryAmountAnswer`'s doc comment for the full rationale.
    var anchorCategory: Category?
    var anchorPeriod: AskClarityPeriod?
    var anchorAnswerValue: Decimal?

    static let empty = AskClaritySessionContext()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.lastCategory === rhs.lastCategory && lhs.lastMetric == rhs.lastMetric
            && lhs.lastPeriod == rhs.lastPeriod && lhs.lastAnswerValue == rhs.lastAnswerValue
            && lhs.anchorCategory === rhs.anchorCategory && lhs.anchorPeriod == rhs.anchorPeriod
            && lhs.anchorAnswerValue == rhs.anchorAnswerValue
    }
}

/// Parses free-typed (or tapped-suggestion) text into an `AskClarityQuery`. Pure text-in,
/// entities-out — no calculation happens here; see `AskClarityEngine` for that. Deliberately a
/// keyword/phrase recognizer, not a language model: every check below is a literal, auditable
/// substring or whole-word match, so the exact set of things this can and can't understand is
/// always inspectable in this file.
enum AskClarityInterpreter {
    static let supportedPeriodsDescription = "today, yesterday, this week, last week, this weekend, last weekend, this month, and last month"

    /// Shared wording for a `.ambiguous` period match — used by both `AskClarityPlanner` and
    /// `AskClarityEngine.resolve` so the two paths never drift into two different phrasings of the
    /// same clarification request.
    static func dateRangeClarificationHeadline(for phrase: String) -> String {
        "I couldn't tell exactly what dates \"\(phrase)\" means — try something like \"September 5\" or \"September 5 to September 18.\""
    }

    static func interpret(
        _ rawText: String,
        categories: [Category],
        context: AskClaritySessionContext,
        today: Date = .now,
        calendar: Calendar = .current
    ) -> AskClarityQuery? {
        let normalized = normalize(rawText)
        guard !normalized.isEmpty else { return nil }

        var query = AskClarityQuery()
        query.periodMatch = parsePeriod(normalized, today: today, calendar: calendar)
        query.metric = parseMetric(normalized)
        query.ranking = parseRanking(normalized)
        query.direction = parseDirection(normalized)
        query.budgetState = parseBudgetState(normalized)
        query.comparisonRequested = hasComparisonMarker(normalized) || parseComparisonWords(normalized)
        query.wantsWhyExplanation = containsAny(normalized, ["why"])
        query.wantsReduceAdvice = parseReduceAdvice(normalized)
        query.wantsList = normalized.contains("categories") || normalized.contains("expenses")
        query.wantsTransactionRanking = parseTransactionRanking(normalized)
        query.wantsAssessment = containsAny(normalized, ["too much", "overspending on", "too high", "excessive", "spending a lot on"])
        query.wantsChangeSummary = containsAny(normalized, ["what changed", "what's changed", "what has changed"])
        query.wantsBreakdown = parseBreakdown(normalized)
        let trendMatch = parseTrend(normalized)
        query.wantsTrend = trendMatch.wantsTrend
        query.trendSpan = trendMatch.span
        // "the last 3 weeks"/"the past 6 months" itself names the base period for the trend
        // chain — only applied when nothing else already pinned a period, exactly like every
        // other inference in this function.
        if query.periodMatch == nil, let unit = trendMatch.unit {
            query.periodMatch = .supported(unit == "week" ? AskClarityPeriod(kind: .thisWeek, label: "this week") : AskClarityPeriod(kind: .thisMonth, label: "this month"))
        }

        let usedContextualReference = parseContextualReference(normalized)
        query.usedContextualReference = usedContextualReference

        // A minimal follow-up — no ranking/direction/budget-state/why/reduce/assessment of its
        // own, i.e. nothing that would make this a self-contained new question — inherits
        // whatever it doesn't itself specify from the previous turn, pronoun or not: "And
        // restaurants?" (new category, same period), "What about last week?" (new period, same
        // category), "And last month?" (same as both, just the period). `AskClarityEngine` reuses
        // this same flag for period inheritance, so all three fields follow one consistent rule.
        let isMinimalFollowUp = query.metric == nil && query.ranking == nil && query.direction == nil
            && query.budgetState == nil && !query.wantsWhyExplanation && !query.wantsReduceAdvice
            && !query.wantsAssessment && !query.wantsList && !query.wantsChangeSummary
            && !query.wantsBreakdown && !query.wantsTrend
        query.isMinimalFollowUp = isMinimalFollowUp
        let shouldInheritContext = usedContextualReference || isMinimalFollowUp

        if let comparison = parseCategoryComparison(normalized, categories: categories) {
            query.categoryComparison = comparison
        } else if let categoryMatch = parseCategory(normalized, categories: categories) {
            query.categoryMatch = categoryMatch
        } else if shouldInheritContext, let lastCategory = context.lastCategory {
            query.categoryMatch = .resolved(lastCategory)
        }

        if query.metric == nil, shouldInheritContext, let lastMetric = context.lastMetric {
            query.metric = lastMetric
        }

        let hasAnySignal = query.metric != nil || query.categoryMatch != nil || query.categoryComparison != nil
            || query.ranking != nil || query.direction != nil || query.budgetState != nil || query.wantsWhyExplanation
            || query.wantsReduceAdvice || query.periodMatch != nil || query.comparisonRequested
            || query.wantsChangeSummary || query.wantsBreakdown || query.wantsTrend
        guard hasAnySignal else { return nil }

        return query
    }

    // MARK: - Normalization

    private static func normalize(_ text: String) -> String {
        var lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while lowered.hasSuffix("?") || lowered.hasSuffix(".") || lowered.hasSuffix("!") { lowered.removeLast() }
        while lowered.contains("  ") { lowered = lowered.replacingOccurrences(of: "  ", with: " ") }
        return lowered
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { String($0) })
    }

    /// Multi-word phrases are checked by substring (their own spaces already delimit them
    /// correctly); single-word keywords are checked by exact word membership so a short keyword
    /// like "top" can't fire on an unrelated word that merely contains it (e.g. "stop").
    private static func containsAny(_ text: String, _ phrases: [String]) -> Bool {
        let wordSet = words(text)
        return phrases.contains { phrase in
            phrase.contains(" ") ? text.contains(phrase) : wordSet.contains(phrase)
        }
    }

    // MARK: - Period

    private static let comparisonMarkerPhrases = [
        "compared to last month", "compared with last month", "compare to last month", "compare with last month",
        "vs last month", "vs. last month", "versus last month", "than last month",
        "compared to this month", "compared with this month", "than this month",
        "compared to last week", "compared with last week", "than last week"
    ]

    private static func hasComparisonMarker(_ text: String) -> Bool {
        comparisonMarkerPhrases.contains { text.contains($0) }
    }

    private static func maskComparisonMarkers(_ text: String) -> String {
        comparisonMarkerPhrases.reduce(text) { $0.replacingOccurrences(of: $1, with: " ") }
    }

    /// Case-insensitive lookup of a full month name's 1-based number — `nil` for anything that
    /// isn't one of the twelve. Internal (not `private`) so `AskClaritySemanticQueryBuilder` can
    /// validate a semantic provider's `monthName` against the exact same vocabulary the
    /// deterministic interpreter itself recognizes, rather than a second copy of this list.
    static func monthNumber(named name: String) -> Int? {
        monthNames.first { $0.name == name.lowercased() }?.number
    }

    private static let monthNames: [(name: String, number: Int)] = [
        ("january", 1), ("february", 2), ("march", 3), ("april", 4), ("may", 5), ("june", 6),
        ("july", 7), ("august", 8), ("september", 9), ("october", 10), ("november", 11), ("december", 12)
    ]

    private static let unsupportedPeriodPhrases = [
        "this year", "last year", "this quarter", "last quarter", "year to date", "ytd",
        "all time", "past year"
    ]

    private static func parsePeriod(_ text: String, today: Date, calendar: Calendar) -> AskClarityPeriodMatch? {
        // Weekend phrases are checked before *anything* week-related — "this weekend" and "last
        // weekend" both contain "this week"/"last week" as substrings, so checking those first
        // would silently misread a weekend question as a whole-week one.
        if text.contains("this weekend") {
            return .supported(AskClarityPeriod(kind: .thisWeekend, label: "this weekend"))
        }
        if text.contains("last weekend") {
            return .supported(AskClarityPeriod(kind: .lastWeekend, label: "last weekend"))
        }

        // "this month ... last month" (either order) means "this month, vs. last month" — the
        // primary subject stays the current period; the comparison itself is a separate signal.
        if text.contains("this month") && text.contains("last month") {
            return .supported(AskClarityPeriod(kind: .thisMonth, label: "this month"))
        }
        if text.contains("this week") && text.contains("last week") {
            return .supported(AskClarityPeriod(kind: .thisWeek, label: "this week"))
        }

        let masked = maskComparisonMarkers(text)

        if masked.contains("yesterday") {
            return .supported(AskClarityPeriod(kind: .yesterday, label: "yesterday"))
        }
        if masked.contains("today") {
            return .supported(AskClarityPeriod(kind: .today, label: "today"))
        }
        if masked.contains("last week") {
            return .supported(AskClarityPeriod(kind: .lastWeek, label: "last week"))
        }
        if masked.contains("this week") {
            return .supported(AskClarityPeriod(kind: .thisWeek, label: "this week"))
        }
        if masked.contains("last month") {
            return .supported(AskClarityPeriod(kind: .lastMonth, label: "last month"))
        }
        if masked.contains("this month") {
            return .supported(AskClarityPeriod(kind: .thisMonth, label: "this month"))
        }

        // A date/date-range-shaped phrase ("September 5," "September 5 to September 18," "last 7
        // days," "the first two weeks of September") is checked before the bare month-name loop
        // just below it — several of these forms contain a bare month name themselves ("September
        // 5"), which the bare-month loop would otherwise swallow as "the whole month of September."
        if let dateRangeMatch = parseDateRangePhrase(masked, today: today, calendar: calendar) {
            return dateRangeMatch
        }

        for entry in monthNames where masked.contains(entry.name) {
            guard let candidate = resolveMonthStart(month: entry.number, today: today, calendar: calendar) else { continue }
            let label = candidate.formatted(.dateTime.month(.wide).year())
            return .supported(AskClarityPeriod(kind: .specificMonth(candidate), label: label))
        }

        if let phrase = unsupportedPeriodPhrases.first(where: { masked.contains($0) }) {
            return .unsupported(phrase)
        }

        return nil
    }

    /// The first-of-month `Date` a bare month name resolves to — "most recent past (or current)
    /// occurrence," rolling back a year if that month hasn't happened yet this year. Shared by the
    /// plain "in January" form above and the date-range parsers below (`resolveDate`, "the first
    /// two weeks of September"), so both use the exact same convention for what a bare month name
    /// means. Internal (not `private`) so `AskClaritySemanticQueryBuilder` resolves a semantic
    /// provider's `specificMonth` the exact same way, rather than a second copy of this rule.
    static func resolveMonthStart(month: Int, today: Date, calendar: Calendar) -> Date? {
        let todayComponents = calendar.dateComponents([.year, .month], from: today)
        guard let todayMonthStart = calendar.date(from: todayComponents) else { return nil }
        var components = DateComponents(year: todayComponents.year, month: month, day: 1)
        guard var candidate = calendar.date(from: components) else { return nil }
        if candidate > todayMonthStart {
            components.year = (todayComponents.year ?? 0) - 1
            candidate = calendar.date(from: components) ?? candidate
        }
        return candidate
    }

    // MARK: - Date ranges
    //
    // An explicit `DateRange` — a concrete date, an explicit two-sided range, a trailing "last N
    // days/weeks" window, or "the first N weeks of <month>" — resolved once, here, into a
    // `AskClarityPeriodKind.dateRange`'s concrete `start`/`end`. Every form is still a raw range
    // (never month-based), so it flows through exactly the same `AskClarityRangeCalculator`/
    // `dateBounds`/`calendarBounds` path `.today`/`.thisWeek`/etc. already use — no new financial
    // calculation, just a new way to arrive at a `start`/`end` pair. A phrase that's clearly
    // *attempting* a date (a month name immediately followed by a number, or a "last/past N
    // day(s)/week(s)" shape) but can't be resolved safely — an invalid day-of-month, a range whose
    // end comes before its start — reports `.ambiguous` rather than silently falling through, so
    // the user is asked to clarify instead of the question being quietly dropped or misread.

    private static func parseDateRangePhrase(_ text: String, today: Date, calendar: Calendar) -> AskClarityPeriodMatch? {
        if let explicit = parseExplicitDateRange(text, today: today, calendar: calendar) { return explicit }
        if let firstWeeks = parseFirstWeeksOfMonth(text, today: today, calendar: calendar) { return firstWeeks }
        if let trailingWindow = parseTrailingWindow(text, today: today, calendar: calendar) { return trailingWindow }
        return nil
    }

    /// A single "<Month> <day>" occurrence anywhere in `text`, e.g. "september 5" inside "how much
    /// did i spend on september 5". Purely syntactic — doesn't validate the day is real for that
    /// month (`resolveDate` does); a coarse `1...31` filter here just avoids treating an unrelated
    /// number (a year, an amount) immediately after a month name as a day.
    private static func parseMonthDay(_ text: String) -> (month: Int, day: Int)? {
        let tokens = text.split(separator: " ").map(String.init)
        for index in tokens.indices {
            guard let monthEntry = monthNames.first(where: { $0.name == tokens[index] }), index + 1 < tokens.count else { continue }
            guard let day = Int(stripOrdinalSuffix(tokens[index + 1])), (1...31).contains(day) else { continue }
            return (monthEntry.number, day)
        }
        return nil
    }

    private static func stripOrdinalSuffix(_ token: String) -> String {
        for suffix in ["st", "nd", "rd", "th"] where token.hasSuffix(suffix) {
            return String(token.dropLast(suffix.count))
        }
        return token
    }

    /// The concrete `Date` "<month> <day>" resolves to — "most recent past (or current)
    /// occurrence," the same rule `resolveMonthStart` uses for a bare month name, applied to the
    /// full day. `nil` means the day genuinely isn't valid for that month in either candidate year
    /// (e.g. day 31 of a 30-day month) — never a partially-applied guess.
    private static func resolveDate(month: Int, day: Int, today: Date, calendar: Calendar) -> Date? {
        func candidate(year: Int) -> Date? {
            guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return nil }
            guard let dayRange = calendar.range(of: .day, in: .month, for: monthStart), dayRange.contains(day) else { return nil }
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        }
        let todayYear = calendar.component(.year, from: today)
        let todayStart = calendar.startOfDay(for: today)
        if let thisYear = candidate(year: todayYear) {
            return thisYear <= todayStart ? thisYear : (candidate(year: todayYear - 1) ?? thisYear)
        }
        return candidate(year: todayYear - 1)
    }

    /// A single day's label always carries its year ("September 5, 2025") for clarity, matching
    /// `specificMonth`'s own always-year-included convention; a multi-day range shows the year only
    /// once, on its end date ("September 5 to September 18, 2025"). Internal (not `private`) so
    /// `AskClaritySemanticQueryBuilder` labels a semantic provider's date range identically.
    static func dateRangeLabel(start: Date, end: Date, calendar: Calendar) -> String {
        let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: end) ?? end
        if calendar.isDate(start, inSameDayAs: inclusiveEnd) {
            return start.formatted(.dateTime.month(.wide).day().year())
        }
        let startText = start.formatted(.dateTime.month(.wide).day())
        let endText = inclusiveEnd.formatted(.dateTime.month(.wide).day().year())
        return "\(startText) to \(endText)"
    }

    private static func monthDayPhrase(_ monthDay: (month: Int, day: Int)) -> String {
        let name = monthNames.first { $0.number == monthDay.month }?.name.capitalized ?? "?"
        return "\(name) \(monthDay.day)"
    }

    /// "September 5" (a single day) or "September 5 to September 18" (an explicit two-sided
    /// range) — the "to" form is tried first since it's the more specific shape.
    private static func parseExplicitDateRange(_ text: String, today: Date, calendar: Calendar) -> AskClarityPeriodMatch? {
        if let range = text.range(of: " to ") {
            let beforeText = String(text[..<range.lowerBound])
            let afterText = String(text[range.upperBound...])
            guard let beforeDay = parseMonthDay(beforeText), let afterDay = parseMonthDay(afterText) else {
                // Not both sides date-shaped — some other, unrelated use of " to " in the
                // question. Left untouched rather than guessed at.
                return nil
            }
            let phrase = "\(monthDayPhrase(beforeDay)) to \(monthDayPhrase(afterDay))"
            guard
                let start = resolveDate(month: beforeDay.month, day: beforeDay.day, today: today, calendar: calendar),
                let end = resolveDate(month: afterDay.month, day: afterDay.day, today: today, calendar: calendar),
                let endExclusive = calendar.date(byAdding: .day, value: 1, to: end),
                start < endExclusive
            else {
                return .ambiguous(phrase)
            }
            return .supported(AskClarityPeriod(kind: .dateRange(start: start, end: endExclusive), label: dateRangeLabel(start: start, end: endExclusive, calendar: calendar)))
        }

        guard let monthDay = parseMonthDay(text) else { return nil }
        guard
            let start = resolveDate(month: monthDay.month, day: monthDay.day, today: today, calendar: calendar),
            let end = calendar.date(byAdding: .day, value: 1, to: start)
        else {
            return .ambiguous(monthDayPhrase(monthDay))
        }
        return .supported(AskClarityPeriod(kind: .dateRange(start: start, end: end), label: dateRangeLabel(start: start, end: end, calendar: calendar)))
    }

    private static let maxFirstWeeksCount = 4

    /// "The first two weeks of September" — the first `count * 7` days of that month, starting
    /// from its first day. A simple day-count definition (not weekday-aligned calendar weeks),
    /// matching this file's existing preference for auditable arithmetic over calendar nuance.
    private static func parseFirstWeeksOfMonth(_ text: String, today: Date, calendar: Calendar) -> AskClarityPeriodMatch? {
        let tokens = text.split(separator: " ").map(String.init)
        guard let firstIndex = tokens.firstIndex(of: "first"), firstIndex + 4 < tokens.count else { return nil }
        let countToken = tokens[firstIndex + 1]
        let weekToken = tokens[firstIndex + 2]
        guard weekToken == "week" || weekToken == "weeks" else { return nil }
        guard tokens[firstIndex + 3] == "of" else { return nil }
        let monthToken = tokens[firstIndex + 4]
        guard let monthEntry = monthNames.first(where: { $0.name == monthToken }) else { return nil }
        guard let count = Int(countToken) ?? trendNumberWords[countToken], count >= 1 else { return nil }

        let phrase = tokens[firstIndex...min(firstIndex + 4, tokens.count - 1)].joined(separator: " ")
        guard count <= maxFirstWeeksCount else { return .ambiguous(phrase) }
        guard
            let monthStart = resolveMonthStart(month: monthEntry.number, today: today, calendar: calendar),
            let end = calendar.date(byAdding: .day, value: count * 7, to: monthStart)
        else {
            return .ambiguous(phrase)
        }
        let label = "the first \(count) week\(count == 1 ? "" : "s") of \(monthStart.formatted(.dateTime.month(.wide).year()))"
        return .supported(AskClarityPeriod(kind: .dateRange(start: monthStart, end: end), label: label))
    }

    /// A sanity cap on "last/past N days/weeks" — generous enough for any realistic question
    /// (a year), but never an unbounded window from a mistyped number.
    private static let maxDateRangeDaySpan = 366

    /// "Last 7 days," "last 30 days," "past 2 weeks" — a trailing window of `count * daysPerUnit`
    /// days ending today (inclusive of today, matching `.thisWeek`/`.today`'s own "includes today"
    /// convention). The weeks form defers to `parseTrend` instead whenever a trend cue is also
    /// present in the question — see `parseTrend`'s doc comment for why.
    private static func parseTrailingWindow(_ text: String, today: Date, calendar: Calendar) -> AskClarityPeriodMatch? {
        let hasTrendCue = containsAny(text, trendKeywordPhrases)
        let tokens = text.split(separator: " ").map(String.init)
        for index in tokens.indices {
            guard tokens[index] == "last" || tokens[index] == "past", index + 2 < tokens.count else { continue }
            let numberToken = tokens[index + 1]
            let unitToken = tokens[index + 2]
            let daysPerUnit: Int
            let unitWord: String
            if unitToken == "day" || unitToken == "days" {
                daysPerUnit = 1
                unitWord = "day"
            } else if unitToken == "week" || unitToken == "weeks" {
                guard !hasTrendCue else { continue }
                daysPerUnit = 7
                unitWord = "week"
            } else {
                continue
            }
            let phrase = "\(tokens[index]) \(numberToken) \(unitToken)"
            guard let count = Int(numberToken) ?? trendNumberWords[numberToken], count >= 1 else { return .ambiguous(phrase) }
            let totalDays = count * daysPerUnit
            guard totalDays <= maxDateRangeDaySpan else { return .ambiguous(phrase) }
            let todayStart = calendar.startOfDay(for: today)
            guard
                let end = calendar.date(byAdding: .day, value: 1, to: todayStart),
                let start = calendar.date(byAdding: .day, value: -(totalDays - 1), to: todayStart)
            else {
                return .ambiguous(phrase)
            }
            let label = "the last \(count) \(unitWord)\(count == 1 ? "" : "s")"
            return .supported(AskClarityPeriod(kind: .dateRange(start: start, end: end), label: label))
        }
        return nil
    }

    // MARK: - Metric

    private static func parseMetric(_ text: String) -> AskClarityMetric? {
        if containsAny(text, ["left to spend", "budget left", "left in my budget", "remaining budget", "how much budget"]) {
            return .remainingBudget
        }
        if containsAny(text, ["saved", "savings", "available"]) {
            return .savings
        }
        if containsAny(text, ["income", "earned", "earnings", "salary"]) {
            return .income
        }
        if containsAny(text, ["spend", "spent", "spending", "expense", "expenses", "cost"]) {
            return .spending
        }
        return nil
    }

    // MARK: - Ranking / direction / budget state

    private static func parseRanking(_ text: String) -> AskClarityRanking? {
        if containsAny(text, ["most", "biggest", "highest", "largest", "top"]) { return .highest }
        if containsAny(text, ["least", "smallest", "lowest"]) { return .lowest }
        return nil
    }

    private static func parseDirection(_ text: String) -> AskClarityChangeDirection? {
        if containsAny(text, ["increased", "increase", "went up", "gone up", "rising", "risen", "grew"]) { return .increased }
        if containsAny(text, ["decreased", "decrease", "went down", "gone down", "dropped", "fell", "declined"]) { return .decreased }
        return nil
    }

    private static func parseBudgetState(_ text: String) -> AskClarityBudgetStateQuery? {
        if containsAny(text, ["over budget", "over my budget", "over their budget", "overspending", "exceeded"]) { return .overBudget }
        if containsAny(text, ["approaching", "close to my budget", "close to the limit", "near my budget", "almost over"]) { return .approachingLimit }
        if containsAny(text, ["within budget", "within my budget", "under budget", "on track"]) { return .withinBudget }
        return nil
    }

    private static func parseComparisonWords(_ text: String) -> Bool {
        containsAny(text, ["compare", "compared", "comparison", "difference", "more than", "less than"])
    }

    private static func parseReduceAdvice(_ text: String) -> Bool {
        containsAny(text, ["where could i reduce", "where can i reduce", "reduce spending", "cut back", "save money", "lower my spending", "where should i cut"])
    }

    private static func parseTransactionRanking(_ text: String) -> Bool {
        let wordSet = words(text)
        return (wordSet.contains("expense") || wordSet.contains("expenses"))
            && !wordSet.contains("category") && !wordSet.contains("categories")
    }

    // MARK: - Breakdown / trend

    private static func parseBreakdown(_ text: String) -> Bool {
        containsAny(text, ["breakdown", "break down", "broken down", "by category", "split by category", "each category"])
    }

    private static let trendKeywordPhrases = [
        "trend", "trending", "over time", "month by month", "week by week", "day by day",
        "each month", "each week", "per month", "per week"
    ]

    /// Narrow, curated vocabulary — matches this file's existing style (e.g. `nameVariants`)
    /// rather than a general number parser. Two through twelve covers every realistic "last N
    /// months/weeks" phrasing; anything larger is capped by `maxTrendSpan` anyway.
    private static let trendNumberWords: [String: Int] = [
        "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12
    ]

    private static let maxTrendSpan = 12

    /// Recognizes a bare trend request ("spending trend," "month by month") or one naming an
    /// explicit span ("the last 6 months," "past 3 weeks"). `unit` (only set for the explicit-span
    /// form) tells `interpret` which period kind to default `periodMatch` to when nothing else
    /// already named one — "week"/"month" only, matching the two chainable period families
    /// `AskClarityPeriodKind.previousEquivalent` actually supports.
    ///
    /// "Last/past N months" needs no explicit trend cue elsewhere in the question — a month-count
    /// span has no other meaning in this file. "Last/past N *weeks*" is different: `parsePeriod`'s
    /// `parseTrailingWindow` now also recognizes that exact phrase as a literal date-range period
    /// ("the past 2 weeks" as a single window to total, not a per-week trend) — so here, the weeks
    /// form only counts as a trend span when an explicit trend cue (`trendKeywordPhrases`) is also
    /// present ("spending *trend* over the past 3 weeks"); bare "past 3 weeks" alone is left for
    /// `parseTrailingWindow` to claim instead.
    private static func parseTrend(_ text: String) -> (wantsTrend: Bool, span: Int?, unit: String?) {
        let hasCue = containsAny(text, trendKeywordPhrases)
        let tokens = text.split(separator: " ").map(String.init)
        for index in tokens.indices {
            guard tokens[index] == "last" || tokens[index] == "past", index + 2 < tokens.count else { continue }
            let numberToken = tokens[index + 1]
            let unitToken = tokens[index + 2]
            guard let count = Int(numberToken) ?? trendNumberWords[numberToken], count >= 2 else { continue }
            if unitToken == "month" || unitToken == "months" {
                return (true, min(count, maxTrendSpan), "month")
            }
            if hasCue, unitToken == "week" || unitToken == "weeks" {
                return (true, min(count, maxTrendSpan), "week")
            }
        }
        if hasCue {
            return (true, nil, nil)
        }
        return (false, nil, nil)
    }

    private static func parseContextualReference(_ text: String) -> Bool {
        let wordSet = words(text)
        return wordSet.contains("that") || wordSet.contains("it") || text.contains("this category") || text.contains("same category")
    }

    // MARK: - Category

    private static let categoryStopMarkers = [" in ", " this ", " last ", " today", " yesterday", " compared", " vs", " versus", " than"]

    /// "On"/"for"/"in" is genuinely ambiguous in English — it can introduce a category ("spend on
    /// *restaurants*") or a date/date-range ("spend on *June 5*," "spend in *the last 7 days*").
    /// Checked against the raw, not-yet-truncated phrase right after the preposition, so a date
    /// phrase is never even offered up to `categoryStopMarkers`' truncation (which would otherwise
    /// mangle "the last 7 days" down to a bogus leftover "the" once it stops at " last ").
    private static func looksLikePeriodPhraseStart(_ phrase: String) -> Bool {
        let trimmed = phrase.trimmingCharacters(in: .whitespaces)
        if trimmed == "today" || trimmed.hasPrefix("today ") { return true }
        if trimmed == "yesterday" || trimmed.hasPrefix("yesterday ") { return true }
        for prefix in ["this ", "last ", "past ", "the last ", "the first "] where trimmed.hasPrefix(prefix) {
            return true
        }
        return monthNames.contains { trimmed == $0.name || trimmed.hasPrefix($0.name + " ") }
    }

    private static func extractPrepositionalCategoryPhrase(_ text: String) -> String? {
        for preposition in [" on ", " for ", " in "] {
            guard let range = text.range(of: preposition) else { continue }
            var phrase = String(text[range.upperBound...])
            guard !looksLikePeriodPhraseStart(phrase) else { continue }
            for marker in categoryStopMarkers {
                if let stopRange = phrase.range(of: marker) {
                    phrase = String(phrase[..<stopRange.lowerBound])
                }
            }
            phrase = phrase.trimmingCharacters(in: .whitespaces)
            guard phrase.count > 1 else { continue }
            return phrase
        }
        return nil
    }

    /// Spelling/short-form variants that should still resolve to a given (single-word) category
    /// or head-category name — narrowly curated per name, not a general stemmer, so a variant is
    /// only recognized where it unambiguously means that one name. Add an entry here only for a
    /// name actually known to have this kind of variant in practice.
    private static let nameVariants: [String: Set<String>] = [
        "travelling": ["travelling", "traveling", "travel"]
    ]

    private static func nameMatches(_ name: String, text: String, wordSet: Set<String>) -> Bool {
        let lowered = name.lowercased()
        if lowered.contains(" ") { return text.contains(lowered) }
        if wordSet.contains(lowered) { return true }
        if let variants = nameVariants[lowered] { return !variants.isDisjoint(with: wordSet) }
        return false
    }

    /// Matches a category or head-category name anywhere within `text` — the reusable core of
    /// `parseCategory`, factored out so `parseCategoryComparison` can run it independently over
    /// each side of a "than" split without re-detecting the whole-question preposition phrase
    /// (step 3 below), which only makes sense against the complete question. Internal (not
    /// `private`) so `AskClaritySemanticQueryBuilder` resolves a semantic provider's
    /// `categoryName` through this exact same matching (including head-category aggregation),
    /// never a second copy of it.
    static func matchCategoryName(in text: String, categories: [Category]) -> AskClarityCategoryMatch? {
        let wordSet = words(text)

        // 1. Exact category name — longest name first so a more specific name (e.g. "Fast Food")
        //    wins over a shorter one it happens to contain.
        for category in categories.sorted(by: { $0.name.count > $1.name.count }) {
            if nameMatches(category.name, text: text, wordSet: wordSet) {
                return .resolved(category)
            }
        }

        // 2. Head-category name — naming the parent (e.g. "Travelling" covering Flights, Hotel,
        //    Activities, ...) aggregates across every child rather than asking which one was
        //    meant: the user chose to name the group, so the group is the answer. Resolved
        //    outright (as that one category, not a group) when the head has exactly one child.
        var seenHeads = Set<ObjectIdentifier>()
        var uniqueHeads: [HeadCategory] = []
        for category in categories {
            let id = ObjectIdentifier(category.headCategory)
            guard !seenHeads.contains(id) else { continue }
            seenHeads.insert(id)
            uniqueHeads.append(category.headCategory)
        }
        let byHead = Dictionary(grouping: categories) { ObjectIdentifier($0.headCategory) }

        for head in uniqueHeads.sorted(by: { $0.name.count > $1.name.count }) {
            guard nameMatches(head.name, text: text, wordSet: wordSet) else { continue }
            let children = byHead[ObjectIdentifier(head)] ?? []
            if children.count == 1, let only = children.first {
                return .resolved(only)
            } else if children.count > 1 {
                return .resolvedHeadCategory(head, categories: children)
            }
        }

        return nil
    }

    private static func parseCategory(_ text: String, categories: [Category]) -> AskClarityCategoryMatch? {
        if let match = matchCategoryName(in: text, categories: categories) {
            return match
        }

        // A preposition clearly introduced a category phrase, but nothing matched it.
        if let phrase = extractPrepositionalCategoryPhrase(text) {
            return .notFound(phrase: phrase)
        }

        return nil
    }

    /// "Did I spend more on restaurants than groceries [last month]?" — splits on " than " and
    /// requires *both* sides to independently name a real category or head category before
    /// treating this as a comparison at all. A question that merely contains "than" elsewhere
    /// (e.g. one of `comparisonMarkerPhrases`, like "...than last month") won't have a matching
    /// category on the far side of the split, so it safely falls through to plain single-category
    /// parsing instead.
    private static func parseCategoryComparison(_ text: String, categories: [Category]) -> AskClarityCategoryComparisonQuery? {
        guard let range = text.range(of: " than ") else { return nil }
        let before = String(text[..<range.lowerBound])
        let after = String(text[range.upperBound...])
        guard
            let first = matchCategoryName(in: before, categories: categories),
            let second = matchCategoryName(in: after, categories: categories),
            first != second
        else { return nil }
        return AskClarityCategoryComparisonQuery(first: first, second: second)
    }
}
