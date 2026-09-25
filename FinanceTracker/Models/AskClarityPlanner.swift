import Foundation

/// The resolved subject of a category-scoped question — either one specific category, or a
/// named head category aggregated across all of its children (`AskClarityCategoryMatch.
/// resolvedHeadCategory`). Lets a plain amount question ("how much did I spend on Travelling")
/// share the exact same calculation path as a single-category one ("...on Hotel"), just summed
/// over more than one `Category`.
struct AskClaritySubject {
    let name: String
    let categories: [Category]
    /// Set only when this subject is one specific `Category` — an aggregate has none, since
    /// `AskClaritySessionContext.lastCategory` can only remember one concrete category for a
    /// later follow-up to resolve; an aggregate subject simply isn't remembered that way.
    let singleCategory: Category?
}

/// What `AskClarityExecutor` should compute. Every field is data — no calculation happens while
/// building one; see `AskClarityPlanner.plan(for:context:today:calendar:)`.
struct AskClarityPlan {
    let operation: AskClarityPlanOperation
    let metric: AskClarityMetric
    /// One subject for a plain amount question, two for a category-vs-category comparison
    /// (`comparison == .betweenSubjects`), empty for a ranking (which considers every category),
    /// a plain metric total (no category named), or a global category breakdown.
    let subjects: [AskClaritySubject]
    let period: AskClarityPeriod
    let comparison: AskClarityPlanComparison?
    let ranking: AskClarityPlanRanking?
    /// Only set for `.budgetState` — which state was asked about ("over budget," "within
    /// budget," ...). `subjects.first?.singleCategory` (when present) scopes it to one category;
    /// otherwise it's a global "which categories are X" question.
    let budgetState: AskClarityBudgetStateQuery?
    /// Only set for `.trend` — how many consecutive equivalent periods to compute, oldest to
    /// newest. `nil` lets `AskClarityExecutor` apply its own default span.
    let trendSpan: Int?

    /// A `let` stored property with an inline default value is excluded from Swift's synthesized
    /// memberwise initializer entirely (it can never be overridden, not merely defaulted) — so
    /// `budgetState`/`trendSpan` need this explicit initializer to stay optional at every other
    /// call site while still being settable at the two that need them.
    init(
        operation: AskClarityPlanOperation, metric: AskClarityMetric, subjects: [AskClaritySubject], period: AskClarityPeriod,
        comparison: AskClarityPlanComparison?, ranking: AskClarityPlanRanking?,
        budgetState: AskClarityBudgetStateQuery? = nil, trendSpan: Int? = nil
    ) {
        self.operation = operation
        self.metric = metric
        self.subjects = subjects
        self.period = period
        self.comparison = comparison
        self.ranking = ranking
        self.budgetState = budgetState
        self.trendSpan = trendSpan
    }
}

enum AskClarityPlanOperation: Equatable {
    /// A single figure — one subject's spend, or (with `subjects.count == 2` and `comparison ==
    /// .betweenSubjects`) two subjects' spend side by side. Also covers a plain metric total with
    /// no category at all (`subjects.isEmpty`) — spending, income, remaining budget, or savings.
    case amount
    case rankCategories
    case rankTransactions
    /// "Which categories are over budget," "is Restaurants over budget" — reuses
    /// `BudgetCalculator.periodSpendingSummary`/`OverviewCalculator.categorySpendingHealth`
    /// exactly as the plain amount/ranking operations reuse their own calculators.
    case budgetState
    /// Every category's amount for the period — the full list, not just the top one(s)
    /// (`.rankCategories`) — optionally scoped to one head category's own children.
    case categoryBreakdown
    /// The same metric/subject computed across several consecutive equivalent periods.
    case trend
}

enum AskClarityPlanComparison: Equatable {
    /// Compare the subject's amount against the previous equivalent period.
    case previousPeriod
    /// Compare `subjects[0]`'s amount against `subjects[1]`'s, same period — "restaurants than
    /// groceries."
    case betweenSubjects
}

struct AskClarityPlanRanking: Equatable {
    let direction: AskClarityRanking
    /// "Show me my biggest spending *categories*/*expenses*" (plural) — a short list, not just
    /// the single winner.
    let wantsList: Bool
}

/// The outcome of planning a query — either a computable `AskClarityPlan`, an explicit reason it
/// can't be computed yet (never silently guessed past), or `.legacyFallback` for question shapes
/// this planner doesn't express as a `Plan` yet (see its case doc below).
enum AskClarityPlanningResult {
    case plan(AskClarityPlan)
    /// The category phrase matched more than one category and none was named specifically enough
    /// — `headline` is the ready-to-show clarifying question.
    case needsClarification(headline: String)
    /// A category-shaped phrase matched nothing the user actually has.
    case categoryNotFound(phrase: String)
    /// The period phrase is recognized but deliberately unsupported (e.g. "this year") — must
    /// never be silently answered as if it meant the current month.
    case unsupportedPeriod
    /// Why, reduce-advice, assessment, direction/"what changed," and ranking-*by-change* questions
    /// aren't expressed as a `Plan` in this pass — `AskClarityEngine.resolve` still answers these
    /// directly, exactly as before. Not a failure, a scoping boundary.
    case legacyFallback
}

/// Turns an interpreted `AskClarityQuery` into an explicit `AskClarityPlan` — the **plan** stage
/// between **interpret** (`AskClarityInterpreter`) and **execute** (`AskClarityExecutor`). Decides
/// *what* needs computing (metric, subject(s), period, comparison, ranking) without computing
/// anything itself; mirrors `AskClarityEngine.resolve`'s own dispatch order exactly, so a query
/// shape not yet migrated to a `Plan` falls through to `.legacyFallback` and is answered identically
/// to before.
enum AskClarityPlanner {
    static func plan(
        for query: AskClarityQuery,
        context: AskClaritySessionContext,
        today: Date = .now,
        calendar: Calendar = .current
    ) -> AskClarityPlanningResult {
        // 0. Category vs. category comparison — "restaurants than groceries" — a distinct
        //    two-subject shape checked first since nothing else in this function (or the legacy
        //    dispatcher) expresses it.
        if let comparison = query.categoryComparison {
            if let blocked = clarification(for: comparison.first) { return blocked }
            if let blocked = clarification(for: comparison.second) { return blocked }
            if let blocked = periodProblem(query.periodMatch) { return blocked }
            guard let first = subject(for: comparison.first), let second = subject(for: comparison.second) else {
                return .legacyFallback
            }
            let period = effectivePeriod(query: query, context: context, today: today, calendar: calendar)
            return .plan(AskClarityPlan(operation: .amount, metric: .spending, subjects: [first, second], period: period, comparison: .betweenSubjects, ranking: nil))
        }

        // 1. Category resolution problems come first — never guess past an ambiguity or a miss.
        if let categoryMatch = query.categoryMatch, let blocked = clarification(for: categoryMatch) {
            return blocked
        }

        // 2. An explicitly-unsupported period is stated plainly, or a date/date-range-shaped
        //    phrase couldn't be resolved safely (an invalid day, a range ending before it starts).
        if let blocked = periodProblem(query.periodMatch) { return blocked }

        let period = effectivePeriod(query: query, context: context, today: today, calendar: calendar)
        let resolvedCategory: Category? = {
            if case .resolved(let category) = query.categoryMatch { return category }
            return nil
        }()
        let resolvedSubject = query.categoryMatch.flatMap(subject(for:))

        // 3. Budget-state questions ("which categories are over budget," "is Restaurants over
        //    budget"). Only a single, specifically-named category counts here (`resolvedCategory`,
        //    never an aggregate) — matches every other budget-state-shaped concept in this file.
        if let budgetState = query.budgetState {
            let subjects: [AskClaritySubject] = resolvedCategory.map { [AskClaritySubject(name: $0.name, categories: [$0], singleCategory: $0)] } ?? []
            return .plan(AskClarityPlan(operation: .budgetState, metric: .spending, subjects: subjects, period: period, comparison: nil, ranking: nil, budgetState: budgetState))
        }

        // 4. Ranking questions. Plain category/transaction ranking is planned; ranking *by
        //    change* (ranking + direction together, e.g. "which category increased the most")
        //    stays legacy — it's a different calculation (`ExplainMyMonthCalculator`), not an
        //    amount ranking.
        if let ranking = query.ranking, resolvedCategory == nil {
            if query.wantsTransactionRanking {
                return .plan(AskClarityPlan(
                    operation: .rankTransactions, metric: .spending, subjects: [], period: period,
                    comparison: nil, ranking: AskClarityPlanRanking(direction: ranking, wantsList: query.wantsList)
                ))
            }
            if query.direction != nil { return .legacyFallback }
            return .plan(AskClarityPlan(
                operation: .rankCategories, metric: .spending, subjects: [], period: period,
                comparison: nil, ranking: AskClarityPlanRanking(direction: ranking, wantsList: query.wantsList)
            ))
        }

        // 5. Direction-only / "what changed" — not yet planned.
        if query.direction != nil, query.ranking == nil { return .legacyFallback }
        if query.wantsChangeSummary, resolvedCategory == nil { return .legacyFallback }

        // 6/7. Why / reduce-advice — not yet planned.
        if query.wantsWhyExplanation, resolvedCategory == nil { return .legacyFallback }
        if query.wantsReduceAdvice { return .legacyFallback }

        // 7a. Trend questions ("spending trend," "how has my income trended the last 6
        //     months") — checked before the plain-amount/breakdown cases below since a trend
        //     request can name a category (or aggregate) the exact same way they do, but needs
        //     the whole chain of periods rather than just one.
        if query.wantsTrend {
            let metric = query.metric ?? .spending
            let subjects: [AskClaritySubject] = resolvedSubject.map { [$0] } ?? []
            return .plan(AskClarityPlan(operation: .trend, metric: metric, subjects: subjects, period: period, comparison: nil, ranking: nil, trendSpan: query.trendSpan))
        }

        // 7b. Category breakdown ("breakdown of my spending," "how does my Travelling spending
        //     break down") — every category's amount for the period, optionally scoped to one
        //     head category's own children. `resolvedCategory == nil` excludes a single specific
        //     leaf category (nothing to break down there) — that degrades to the plain amount in
        //     step 8 below instead, exactly as if `wantsBreakdown` hadn't been said at all.
        if query.wantsBreakdown, resolvedCategory == nil {
            let subjects: [AskClaritySubject] = resolvedSubject.map { [$0] } ?? []
            return .plan(AskClarityPlan(operation: .categoryBreakdown, metric: .spending, subjects: subjects, period: period, comparison: nil, ranking: nil))
        }

        // 8. A specific category or an aggregated head category. Assessment ("am I spending too
        //    much on X") stays legacy — it's a budget lookup, not a plain amount.
        if let resolvedSubject {
            if query.wantsAssessment, resolvedSubject.singleCategory != nil { return .legacyFallback }
            let comparison: AskClarityPlanComparison? = query.comparisonRequested ? .previousPeriod : nil
            return .plan(AskClarityPlan(operation: .amount, metric: .spending, subjects: [resolvedSubject], period: period, comparison: comparison, ranking: nil))
        }

        // 9. A plain metric, no category (total spending/income/remaining budget/savings).
        //    Spending keeps its existing quirk of comparing against the previous period by
        //    default whenever the period itself is "this month," even without an explicit
        //    "compared to" — matching this metric's own pre-Planner behavior exactly. The other
        //    three metrics only compare when the question explicitly asks for it (income), or
        //    don't support a period comparison at all yet (remaining budget/savings — see
        //    `AskClarityExecutor.executePlainMetricAmount`).
        if let metric = query.metric ?? (query.periodMatch != nil ? .spending : nil) {
            let comparison: AskClarityPlanComparison?
            switch metric {
            case .spending: comparison = (query.comparisonRequested || period.kind == .thisMonth) ? .previousPeriod : nil
            case .income: comparison = query.comparisonRequested ? .previousPeriod : nil
            case .remainingBudget, .savings: comparison = nil
            }
            return .plan(AskClarityPlan(operation: .amount, metric: metric, subjects: [], period: period, comparison: comparison, ranking: nil))
        }

        return .legacyFallback
    }

    /// Same inheritance rule the interpreter uses for category/metric — see `AskClarityQuery.
    /// isMinimalFollowUp`'s doc comment. Shared with `AskClarityEngine.resolve`'s legacy path so
    /// period resolution has one definition regardless of which path answers the question.
    static func effectivePeriod(query: AskClarityQuery, context: AskClaritySessionContext, today: Date, calendar: Calendar) -> AskClarityPeriod {
        if case .supported(let period) = query.periodMatch {
            return period
        }
        if (query.usedContextualReference || query.isMinimalFollowUp), let lastPeriod = context.lastPeriod {
            return lastPeriod
        }
        return AskClarityPeriod(kind: .thisMonth, label: "this month")
    }

    private static func subject(for match: AskClarityCategoryMatch) -> AskClaritySubject? {
        switch match {
        case .resolved(let category):
            return AskClaritySubject(name: category.name, categories: [category], singleCategory: category)
        case .resolvedHeadCategory(let head, let categories):
            return AskClaritySubject(name: head.name, categories: categories, singleCategory: nil)
        case .ambiguous, .notFound:
            return nil
        }
    }

    private static func periodProblem(_ periodMatch: AskClarityPeriodMatch?) -> AskClarityPlanningResult? {
        switch periodMatch {
        case .unsupported: return .unsupportedPeriod
        case .ambiguous(let phrase): return .needsClarification(headline: AskClarityInterpreter.dateRangeClarificationHeadline(for: phrase))
        case .supported, nil: return nil
        }
    }

    private static func clarification(for match: AskClarityCategoryMatch) -> AskClarityPlanningResult? {
        switch match {
        case .ambiguous(_, let candidates):
            let names = candidates.map(\.name).joined(separator: " or ")
            return .needsClarification(headline: "Do you mean \(names)?")
        case .notFound(let phrase):
            return .categoryNotFound(phrase: phrase)
        case .resolved, .resolvedHeadCategory:
            return nil
        }
    }
}
