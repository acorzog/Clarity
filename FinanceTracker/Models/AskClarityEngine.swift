import Foundation

/// One answer "Ask Clarity" gives — every field is pre-computed data; the view only displays it.
/// `hasSufficientData == false` covers three distinct situations the headline itself explains:
/// the question needs data that doesn't exist yet, the period/combination asked for isn't
/// supported yet, or the category phrase was ambiguous/unmatched — see `AskClarityEngine`.
struct AskClarityAnswer: Equatable {
    let headline: String
    let supportingDetail: String
    let hasSufficientData: Bool
    /// Up to a few relevant next questions, shown as tappable chips under this answer — discovery
    /// aids, never a restriction on what can be typed. Empty when nothing specific applies.
    let followUpSuggestions: [String]
    /// Presentation classification for `supportingDetail` when it states a comparison — `true`
    /// for good news (spending down, within budget), `false` for bad news (spending up, over
    /// budget), `nil` when `supportingDetail` isn't a favorable/unfavorable comparison at all
    /// (or is empty). Purely how the view colors the detail text; never changes which numbers
    /// are computed or shown.
    let comparisonIsFavorable: Bool?

    init(headline: String, supportingDetail: String = "", hasSufficientData: Bool, followUpSuggestions: [String] = [], comparisonIsFavorable: Bool? = nil) {
        self.headline = headline
        self.supportingDetail = supportingDetail
        self.hasSufficientData = hasSufficientData
        self.followUpSuggestions = followUpSuggestions
        self.comparisonIsFavorable = comparisonIsFavorable
    }
}

/// Budget-eligible totals for a raw date range (day/week granularity) — the same eligibility rule
/// every other spending total in the app uses (`Models/BudgetEligibility.swift`), just windowed
/// differently than the calendar-month calculators. Never a second definition of "what counts as
/// spending"; `start`/`end` are always used half-open (`>= start && < end`), matching
/// `ClarityScoreCalculator`/`CalendarView`'s own day-window convention.
enum AskClarityRangeCalculator {
    static func spending(from start: Date, to end: Date, entries: [Entry], category: Category? = nil) -> Decimal {
        entries
            .filter { $0.date >= start && $0.date < end && $0.type == .expense }
            .budgetEligible
            .filter { category == nil || $0.category === category }
            .totalExpenses
    }

    static func income(from start: Date, to end: Date, entries: [Entry]) -> Decimal {
        entries
            .filter { $0.date >= start && $0.date < end && $0.type == .income }
            .budgetEligible
            .totalIncome
    }

    /// Per-category expense totals for a raw date range, highest-spend-first.
    static func categoryTotals(from start: Date, to end: Date, entries: [Entry]) -> [(category: Category, amount: Decimal)] {
        let eligible = entries.filter { $0.date >= start && $0.date < end && $0.type == .expense }.budgetEligible
        var sums: [ObjectIdentifier: Decimal] = [:]
        var lookup: [ObjectIdentifier: Category] = [:]
        for entry in eligible {
            guard let category = entry.category else { continue }
            let id = ObjectIdentifier(category)
            sums[id, default: 0] += entry.amount
            lookup[id] = category
        }
        return sums.compactMap { id, amount in lookup[id].map { (category: $0, amount: amount) } }
            .sorted { $0.amount > $1.amount }
    }

    /// The single largest (or smallest) budget-eligible expense entry in the range.
    static func topExpense(from start: Date, to end: Date, entries: [Entry], smallest: Bool = false) -> Entry? {
        let eligible = entries.filter { $0.date >= start && $0.date < end && $0.type == .expense }.budgetEligible
        return smallest ? eligible.min(by: { $0.amount < $1.amount }) : eligible.max(by: { $0.amount < $1.amount })
    }

    /// Up to `limit` largest (or smallest) budget-eligible expense entries in the range,
    /// highest-first (or lowest-first) — the list form of `topExpense`, for a plural "show me my
    /// biggest expenses" question rather than a single top transaction.
    static func topExpenses(from start: Date, to end: Date, entries: [Entry], limit: Int, smallest: Bool = false) -> [Entry] {
        let eligible = entries.filter { $0.date >= start && $0.date < end && $0.type == .expense }.budgetEligible
        let sorted = smallest ? eligible.sorted { $0.amount < $1.amount } : eligible.sorted { $0.amount > $1.amount }
        return Array(sorted.prefix(limit))
    }
}

/// Internal (not `private`) so `AskClarityExecutor` — which computes plan results against raw
/// date ranges — can also read `isMonthBased`/`rawRange`/`previousEquivalent` without a second
/// copy of this period-kind logic.
extension AskClarityPeriodKind {
    /// Raw date bounds for the non-month periods; `nil` for month-based kinds, which route
    /// through the month calculators instead (see `AskClarityEngine.monthDate(for:today:calendar:)`).
    func rawRange(today: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        var weekCalendar = calendar
        weekCalendar.firstWeekday = 2 // Monday — matches CalendarView's own week convention.

        switch self {
        case .today:
            let start = calendar.startOfDay(for: today)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return (start, end)
        case .yesterday:
            let todayStart = calendar.startOfDay(for: today)
            guard let start = calendar.date(byAdding: .day, value: -1, to: todayStart) else { return nil }
            return (start, todayStart)
        case .thisWeek:
            guard let interval = weekCalendar.dateInterval(of: .weekOfYear, for: today) else { return nil }
            return (interval.start, interval.end)
        case .lastWeek:
            guard
                let weekAgo = calendar.date(byAdding: .day, value: -7, to: today),
                let interval = weekCalendar.dateInterval(of: .weekOfYear, for: weekAgo)
            else { return nil }
            return (interval.start, interval.end)
        case .thisWeekend:
            // The Monday-first week interval is [Monday, next Monday) — the weekend is its last
            // two days, Saturday and Sunday.
            guard
                let interval = weekCalendar.dateInterval(of: .weekOfYear, for: today),
                let start = calendar.date(byAdding: .day, value: -2, to: interval.end)
            else { return nil }
            return (start, interval.end)
        case .lastWeekend:
            guard
                let weekAgo = calendar.date(byAdding: .day, value: -7, to: today),
                let interval = weekCalendar.dateInterval(of: .weekOfYear, for: weekAgo),
                let start = calendar.date(byAdding: .day, value: -2, to: interval.end)
            else { return nil }
            return (start, interval.end)
        case .dateRange(let start, let end):
            // Already resolved to concrete bounds at parse time (`AskClarityInterpreter.
            // parseDateRangePhrase`) — `today` is unused here, same as every other case that
            // ignores it once it no longer needs it.
            return (start, end)
        case .thisMonth, .lastMonth, .specificMonth:
            return nil
        }
    }

    var isMonthBased: Bool {
        switch self {
        case .thisMonth, .lastMonth, .specificMonth: return true
        case .today, .yesterday, .thisWeek, .lastWeek, .thisWeekend, .lastWeekend, .dateRange: return false
        }
    }

    /// The equivalent *previous* period, for a plain (non-contextual) comparison — "yesterday" ->
    /// the day before, "this week" -> last week, "this month" -> last month, etc.
    /// `nil` when there's no equivalent-previous-period within the currently-supported set —
    /// e.g. "the day before yesterday" and "the week before last" are deliberately out of scope
    /// (see `AskClarityInterpreter.supportedPeriodsDescription`), so no comparison is attempted
    /// rather than misrepresenting some other range as one. `.yesterday`/`.lastWeek` must never
    /// route through `.specificMonth` here — that case is a calendar-month anchor everywhere else
    /// in this file, so reusing it for a single day would silently compute a whole month's total.
    func previousEquivalent(today: Date, calendar: Calendar) -> (kind: AskClarityPeriodKind, label: String)? {
        switch self {
        case .today: return (.yesterday, "yesterday")
        case .yesterday: return nil
        case .thisWeek: return (.lastWeek, "last week")
        case .lastWeek: return nil
        case .thisWeekend: return (.lastWeekend, "last weekend")
        case .lastWeekend: return nil
        case .thisMonth: return (.lastMonth, "last month")
        case .lastMonth: return nil
        case .specificMonth(let date):
            guard let previous = calendar.date(byAdding: .month, value: -1, to: date) else { return nil }
            return (.specificMonth(previous), previous.formatted(.dateTime.month(.wide).year()))
        case .dateRange:
            // No single obvious convention for what comes "before" an arbitrary explicit range
            // ("September 5 to September 18") — the same span shifted back? The prior calendar
            // month's same days? Rather than guess one, this stays unsupported, exactly like every
            // other already-`nil` case above; a `.dateRange`-based comparison or trend simply isn't
            // offered yet.
            return nil
        }
    }
}

/// Computes answers by composing existing calculation layers — `BudgetCalculator.
/// periodSpendingSummary`, `OverviewCalculator.categorySpendingHealth`, `ExplainMyMonthCalculator.
/// explain`, and `AskClarityRangeCalculator` (itself only a differently-windowed `.budgetEligible`
/// filter, not a new spend/budget rule) — never a new financial calculation. Every financial
/// figure this type ever returns is still computed exactly this way, whether the question that
/// produced it was interpreted locally or (see `respondWithSemanticFallback`) by an LLM that only
/// ever chooses among this app's own already-supported concepts — no calculation ever happens
/// outside this deterministic layer. `respond(to:...)` itself remains fully local, synchronous,
/// SwiftUI-independent, and still local-first: no network call, no language model.
///
/// `respond` is the top of four explicit stages: **interpret** (`AskClarityInterpreter`, text ->
/// `AskClarityQuery`), **plan** (`AskClarityPlanner`, query -> an `AskClarityPlan` describing what
/// needs computing, or a reason it can't be planned), **execute** (`AskClarityExecutor`, plan ->
/// raw numbers, via the calculators above), and **respond** (this file, raw numbers -> a worded
/// `AskClarityAnswer`). Not every question shape is expressed as a `Plan` yet — `AskClarityPlanner`
/// returns `.legacyFallback` for the ones that aren't (why, reduce-advice, assessment,
/// direction/change-ranking questions), and those still run through `resolve` below exactly as
/// before; the split only applies to the shapes `AskClarityPlanner` recognizes.
enum AskClarityEngine {
    struct Result {
        let answer: AskClarityAnswer
        let updatedContext: AskClaritySessionContext
    }

    static func respond(
        to text: String,
        context: AskClaritySessionContext,
        entries: [Entry],
        budgets: [Budget],
        headCategories: [HeadCategory],
        settings: BudgetCalculationSettings,
        calendar: Calendar = .current,
        today: Date = .now
    ) -> Result {
        let categories = headCategories.flatMap { $0.categories.filter { !$0.isArchived } }

        guard let query = AskClarityInterpreter.interpret(text, categories: categories, context: context, today: today, calendar: calendar) else {
            return Result(answer: unknownAnswer(), updatedContext: context)
        }

        return respond(toQuery: query, context: context, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
    }

    /// The shared tail of `respond(to:...)` — everything from an already-interpreted
    /// `AskClarityQuery` onward. Factored out (rather than inlined in `respond(to:...)`) so
    /// `respondWithSemanticFallback` can feed it a query built from an LLM's structured
    /// interpretation instead of the deterministic one, without a second copy of this dispatch.
    static func respond(
        toQuery query: AskClarityQuery,
        context: AskClaritySessionContext,
        entries: [Entry],
        budgets: [Budget],
        headCategories: [HeadCategory],
        settings: BudgetCalculationSettings,
        calendar: Calendar,
        today: Date
    ) -> Result {
        switch AskClarityPlanner.plan(for: query, context: context, today: today, calendar: calendar) {
        case .plan(let plan):
            let execution = AskClarityExecutor.execute(plan: plan, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
            return respond(toPlan: plan, execution: execution, context: context)
        case .needsClarification(let headline):
            return Result(answer: AskClarityAnswer(headline: headline, hasSufficientData: false), updatedContext: context)
        case .categoryNotFound(let phrase):
            return Result(
                answer: AskClarityAnswer(headline: "I don't have a category called \"\(phrase)\".", hasSufficientData: false),
                updatedContext: context
            )
        case .unsupportedPeriod:
            return Result(
                answer: AskClarityAnswer(headline: "I can currently analyze \(AskClarityInterpreter.supportedPeriodsDescription).", hasSufficientData: false),
                updatedContext: context
            )
        case .legacyFallback:
            return resolve(query: query, context: context, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
        }
    }

    /// `true` only for the two "found no signal at all" outcomes in the whole local pipeline —
    /// `unknownAnswer()` (`AskClarityInterpreter.interpret` returned `nil`) and `resolve`'s own
    /// final catch-all (every dispatch branch fell through). Never `true` for a legitimate,
    /// understood-but-unanswerable case. Internal (not `private`) so `AskClarityEngine+
    /// SemanticFallback.swift` — kept in its own file, out of the Widgets target, since it's the
    /// one part of Ask Clarity that reaches for the network — can use it without a second copy.
    static func isUnrecognizedLocally(_ answer: AskClarityAnswer) -> Bool {
        answer.headline == unknownAnswer().headline
            || answer.headline == "I recognized part of that question, but not enough to answer it yet."
    }

    // MARK: - Respond (planned operations)

    private static func respond(toPlan plan: AskClarityPlan, execution: AskClarityExecutionResult, context: AskClaritySessionContext) -> Result {
        switch plan.operation {
        case .amount:
            return respondToAmount(plan: plan, execution: execution, context: context)
        case .rankCategories:
            return respondToCategoryRanking(plan: plan, execution: execution, context: context)
        case .rankTransactions:
            return respondToTransactionRanking(plan: plan, execution: execution, context: context)
        case .budgetState:
            return respondToBudgetState(plan: plan, execution: execution, context: context)
        case .categoryBreakdown:
            return respondToCategoryBreakdown(plan: plan, execution: execution, context: context)
        case .trend:
            return respondToTrend(plan: plan, execution: execution, context: context)
        }
    }

    private static func respondToAmount(plan: AskClarityPlan, execution: AskClarityExecutionResult, context: AskClaritySessionContext) -> Result {
        guard case .amount(let primary, let secondary, let previousPeriod, let hasData) = execution else {
            return Result(answer: AskClarityAnswer(headline: "I couldn't resolve that period.", hasSufficientData: false), updatedContext: context)
        }

        if plan.comparison == .betweenSubjects, plan.subjects.count == 2, let secondary {
            return categoryComparisonAnswer(plan: plan, first: primary, second: secondary, context: context)
        }
        guard let subject = plan.subjects.first else {
            return plainMetricAnswer(plan: plan, amount: primary, previousPeriod: previousPeriod, hasData: hasData, context: context)
        }
        return categoryAmountAnswer(subject: subject, period: plan.period, amount: primary, previousPeriod: previousPeriod, context: context)
    }

    /// A total with no category named — spending, income, remaining budget, or savings. Wording
    /// preserved exactly from this feature's pre-`Plan` behavior (formerly `AskClarityEngine.
    /// resolve`'s `metricAnswer`/`totalSpendingAnswer`/`incomeAnswer`/`budgetOrSavingsAnswer`).
    private static func plainMetricAnswer(
        plan: AskClarityPlan, amount: Decimal, previousPeriod: (amount: Decimal, label: String)?, hasData: Bool, context: AskClaritySessionContext
    ) -> Result {
        switch plan.metric {
        case .spending:
            guard amount > 0 else {
                return Result(answer: AskClarityAnswer(headline: "No spending logged \(plan.period.label).", hasSufficientData: false), updatedContext: context)
            }
            var detail = ""
            var isFavorable: Bool?
            if let previousPeriod {
                (detail, isFavorable) = comparisonSentence(current: amount, currentLabel: nil, previous: previousPeriod.amount, previousLabel: previousPeriod.label)
            }
            let headline = "You spent \(amount.currencyFormatted) \(plan.period.label)."
            let updated = updatedContext(from: context, category: nil, metric: .spending, period: plan.period, value: amount)
            let followUps = ["Where am I spending the most?", "Am I within my budget?"]
            return Result(
                answer: AskClarityAnswer(headline: headline, supportingDetail: detail, hasSufficientData: true, followUpSuggestions: followUps, comparisonIsFavorable: isFavorable),
                updatedContext: updated
            )

        case .income:
            guard amount > 0 else {
                return Result(answer: AskClarityAnswer(headline: "No income logged \(plan.period.label).", hasSufficientData: false), updatedContext: context)
            }
            var detail = ""
            var isFavorable: Bool?
            if let previousPeriod {
                (detail, isFavorable) = comparisonSentence(current: amount, currentLabel: nil, previous: previousPeriod.amount, previousLabel: previousPeriod.label)
            }
            let updated = updatedContext(from: context, category: nil, metric: .income, period: plan.period, value: amount)
            return Result(
                answer: AskClarityAnswer(headline: "You received \(amount.currencyFormatted) in income \(plan.period.label).", supportingDetail: detail, hasSufficientData: true, comparisonIsFavorable: isFavorable),
                updatedContext: updated
            )

        case .remainingBudget:
            guard hasData else {
                return Result(answer: AskClarityAnswer(headline: "No budget or spending data yet \(plan.period.label).", hasSufficientData: false), updatedContext: context)
            }
            let headline = amount >= 0
                ? "You have \(amount.currencyFormatted) left to spend \(plan.period.label)."
                : "You've gone \(abs(amount).currencyFormatted) over what's available \(plan.period.label)."
            return Result(answer: AskClarityAnswer(headline: headline, hasSufficientData: true), updatedContext: context)

        case .savings:
            guard amount > 0 else {
                return Result(answer: AskClarityAnswer(headline: "No savings transfers logged \(plan.period.label).", hasSufficientData: false), updatedContext: context)
            }
            return Result(answer: AskClarityAnswer(headline: "You've moved \(amount.currencyFormatted) into savings \(plan.period.label).", hasSufficientData: true), updatedContext: context)
        }
    }

    // MARK: - Respond (budget state)

    private static func respondToBudgetState(plan: AskClarityPlan, execution: AskClarityExecutionResult, context: AskClaritySessionContext) -> Result {
        guard case .budgetState(let categoryRow, let health) = execution else {
            return Result(
                answer: AskClarityAnswer(headline: "Budget status is tracked monthly — I can check this month or last month, not \(plan.period.label).", hasSufficientData: false),
                updatedContext: context
            )
        }
        guard let targetBudgetState = plan.budgetState else {
            return Result(answer: AskClarityAnswer(headline: "I couldn't resolve that period.", hasSufficientData: false), updatedContext: context)
        }

        if let category = plan.subjects.first?.singleCategory {
            guard let row = categoryRow, row.planned > 0 else {
                return Result(
                    answer: AskClarityAnswer(headline: "\(category.name) doesn't have a budget set for \(plan.period.label).", hasSufficientData: false),
                    updatedContext: context
                )
            }
            let progress = (row.actual / row.planned).doubleValue
            let state = BudgetHealthState.forProgress(progress)
            let headline: String
            switch state {
            case .overBudget: headline = "Yes — \(category.name) is over budget \(plan.period.label)."
            case .approachingLimit: headline = "\(category.name) is approaching its limit \(plan.period.label)."
            case .onTrack: headline = "No — \(category.name) is within budget \(plan.period.label)."
            }
            let detail = "\(row.actual.currencyFormatted) of \(row.planned.currencyFormatted) spent (\(progress.formatted(.percent.precision(.fractionLength(0)))))."
            let updated = updatedContext(from: context, category: category, metric: .spending, period: plan.period, value: row.actual)
            let followUps = ["How much was \(category.name) last month?", "What did I spend the most on?"]
            return Result(
                answer: AskClarityAnswer(headline: headline, supportingDetail: detail, hasSufficientData: true, followUpSuggestions: followUps, comparisonIsFavorable: state != .overBudget),
                updatedContext: updated
            )
        }

        // No budgeted categories at all is a different situation from "budgeted, but none happen
        // to be in the asked-about state" — the former must say plainly that there isn't enough
        // budget configured to answer, not "no categories are within budget," which reads as
        // though every category was checked and failed rather than that none exist to check.
        guard !health.isEmpty else {
            return Result(
                answer: AskClarityAnswer(headline: "You haven't budgeted any categories yet, so there's nothing to check \(plan.period.label).", hasSufficientData: false),
                updatedContext: context
            )
        }

        let target = targetState(for: targetBudgetState)
        let matches = health.filter { $0.state == target }

        guard !matches.isEmpty else {
            return Result(
                answer: AskClarityAnswer(headline: "No budgeted categories are \(stateDescription(target)) \(plan.period.label).", hasSufficientData: true),
                updatedContext: context
            )
        }

        let headline = matches.count == 1
            ? "\(matches[0].category.name) is \(stateDescription(target)) \(plan.period.label)."
            : "\(matches.map(\.category.name).joined(separator: ", ")) are \(stateDescription(target)) \(plan.period.label)."
        let detail = matches.map { "\($0.category.name): \($0.spent.currencyFormatted) of \($0.budgeted.currencyFormatted)" }.joined(separator: "; ")
        return Result(answer: AskClarityAnswer(headline: headline, supportingDetail: detail, hasSufficientData: true), updatedContext: context)
    }

    private static func targetState(for budgetState: AskClarityBudgetStateQuery) -> BudgetHealthState {
        switch budgetState {
        case .overBudget: return .overBudget
        case .approachingLimit: return .approachingLimit
        case .withinBudget: return .onTrack
        }
    }

    // MARK: - Respond (category breakdown)

    private static func respondToCategoryBreakdown(plan: AskClarityPlan, execution: AskClarityExecutionResult, context: AskClaritySessionContext) -> Result {
        guard case .categoryRanking(let rows) = execution, !rows.isEmpty else {
            return Result(answer: AskClarityAnswer(headline: "No spending logged \(plan.period.label) to break down.", hasSufficientData: false), updatedContext: context)
        }

        let subjectName = plan.subjects.first?.name
        let cap = 10
        let shown = Array(rows.prefix(cap))
        let headline = subjectName.map { "Here's how your \($0) spending breaks down \(plan.period.label):" }
            ?? "Here's your spending by category \(plan.period.label):"
        var lines = shown.map { "\($0.category.name): \($0.amount.currencyFormatted)" }
        if rows.count > cap {
            let shownTotal = shown.reduce(Decimal(0)) { $0 + $1.amount }
            let total = rows.reduce(Decimal(0)) { $0 + $1.amount }
            lines.append("+ \(rows.count - cap) more (\((total - shownTotal).currencyFormatted))")
        }
        return Result(answer: AskClarityAnswer(headline: headline, supportingDetail: lines.joined(separator: "\n"), hasSufficientData: true), updatedContext: context)
    }

    // MARK: - Respond (trend)

    private static func respondToTrend(plan: AskClarityPlan, execution: AskClarityExecutionResult, context: AskClaritySessionContext) -> Result {
        guard case .trend(let points) = execution, points.count >= 2 else {
            return Result(
                answer: AskClarityAnswer(
                    headline: "I don't have enough consecutive periods to show a trend for \(plan.period.label) — try \"this month\" or a specific month instead.",
                    hasSufficientData: false
                ),
                updatedContext: context
            )
        }

        let subjectName = plan.subjects.first?.name
        let metricNoun = metricNoun(for: plan.metric)
        let headline = subjectName.map { "Here's your \($0) \(metricNoun) trend:" } ?? "Here's your \(metricNoun) trend:"
        var lines = points.map { "\($0.period.label.capitalized): \($0.amount.currencyFormatted)" }
        if let requested = plan.trendSpan, requested > points.count {
            lines.append("(Only \(points.count) consecutive periods are available for this period type.)")
        }

        var updated = context
        if let category = plan.subjects.first?.singleCategory, let last = points.last {
            updated = updatedContext(from: context, category: category, metric: plan.metric, period: plan.period, value: last.amount)
        }
        return Result(answer: AskClarityAnswer(headline: headline, supportingDetail: lines.joined(separator: "\n"), hasSufficientData: true), updatedContext: updated)
    }

    private static func metricNoun(for metric: AskClarityMetric) -> String {
        switch metric {
        case .spending: return "spending"
        case .income: return "income"
        case .remainingBudget: return "remaining budget"
        case .savings: return "savings"
        }
    }

    /// "Did I spend more on restaurants than groceries?" — a direct yes/no framed around
    /// `plan.subjects[0]` (the side named before "than," matching how the question itself was
    /// phrased), plus both figures so the answer is checkable on its own.
    private static func categoryComparisonAnswer(plan: AskClarityPlan, first: Decimal, second: Decimal, context: AskClaritySessionContext) -> Result {
        let subjectA = plan.subjects[0]
        let subjectB = plan.subjects[1]
        let period = plan.period
        let diff = abs(first - second)

        let headline: String
        let detail: String
        if first == second {
            headline = "You spent the same on \(subjectA.name) and \(subjectB.name) \(period.label) — \(first.currencyFormatted) each."
            detail = ""
        } else if first > second {
            headline = "Yes — you spent more on \(subjectA.name) (\(first.currencyFormatted)) than \(subjectB.name) (\(second.currencyFormatted)) \(period.label)."
            detail = "\(diff.currencyFormatted) more on \(subjectA.name)."
        } else {
            headline = "No — you actually spent less on \(subjectA.name) (\(first.currencyFormatted)) than \(subjectB.name) (\(second.currencyFormatted)) \(period.label)."
            detail = "\(diff.currencyFormatted) more on \(subjectB.name)."
        }

        let updated = updatedContext(from: context, category: subjectA.singleCategory, metric: .spending, period: period, value: first)
        let followUps = ["How much was \(subjectA.name) last month?", "How much was \(subjectB.name) last month?"]
        return Result(
            answer: AskClarityAnswer(headline: headline, supportingDetail: detail, hasSufficientData: true, followUpSuggestions: followUps),
            updatedContext: updated
        )
    }

    private static func respondToCategoryRanking(plan: AskClarityPlan, execution: AskClarityExecutionResult, context: AskClaritySessionContext) -> Result {
        guard case .categoryRanking(let rows) = execution, !rows.isEmpty, let ranking = plan.ranking else {
            return Result(answer: AskClarityAnswer(headline: "No spending logged \(plan.period.label) to rank.", hasSufficientData: false), updatedContext: context)
        }
        let ordered = ranking.direction == .highest ? rows : rows.reversed()

        if ranking.wantsList {
            let top = Array(ordered.prefix(3))
            let headline = "Your \(ranking.direction == .highest ? "biggest" : "smallest") spending categories \(plan.period.label):"
            let detail = top.enumerated().map { "\($0.offset + 1). \($0.element.category.name) — \($0.element.amount.currencyFormatted)" }.joined(separator: "\n")
            return Result(answer: AskClarityAnswer(headline: headline, supportingDetail: detail, hasSufficientData: true), updatedContext: context)
        }

        guard let winner = ordered.first else {
            return Result(answer: AskClarityAnswer(headline: "No spending logged \(plan.period.label) to rank.", hasSufficientData: false), updatedContext: context)
        }
        let headline = "\(winner.category.name) is where you're spending the \(ranking.direction == .highest ? "most" : "least") \(plan.period.label) — \(winner.amount.currencyFormatted)."
        let updated = updatedContext(from: context, category: winner.category, metric: .spending, period: plan.period, value: winner.amount)
        let followUps = ["How much was \(winner.category.name) last month?", "Is \(winner.category.name) over budget?"]
        return Result(answer: AskClarityAnswer(headline: headline, hasSufficientData: true, followUpSuggestions: followUps), updatedContext: updated)
    }

    private static func respondToTransactionRanking(plan: AskClarityPlan, execution: AskClarityExecutionResult, context: AskClaritySessionContext) -> Result {
        guard case .transactionRanking(let list) = execution, !list.isEmpty, let ranking = plan.ranking else {
            return Result(answer: AskClarityAnswer(headline: "No expenses logged \(plan.period.label).", hasSufficientData: false), updatedContext: context)
        }

        if ranking.wantsList {
            let headline = "Your \(ranking.direction == .highest ? "biggest" : "smallest") expenses \(plan.period.label):"
            let detail = list.enumerated().map { "\($0.offset + 1). \($0.element.amount.currencyFormatted) — \($0.element.category?.name ?? "Uncategorized")" }.joined(separator: "\n")
            return Result(answer: AskClarityAnswer(headline: headline, supportingDetail: detail, hasSufficientData: true), updatedContext: context)
        }

        guard let top = list.first else {
            return Result(answer: AskClarityAnswer(headline: "No expenses logged \(plan.period.label).", hasSufficientData: false), updatedContext: context)
        }
        let categoryName = top.category?.name ?? "Uncategorized"
        let headline = "Your \(ranking.direction == .highest ? "biggest" : "smallest") expense \(plan.period.label) was \(top.amount.currencyFormatted) (\(categoryName))."
        let updated = top.category.map { updatedContext(from: context, category: $0, metric: .spending, period: plan.period) } ?? context
        let followUps = top.category.map { ["How much did I spend on \($0.name)?"] } ?? []
        return Result(answer: AskClarityAnswer(headline: headline, hasSufficientData: true, followUpSuggestions: followUps), updatedContext: updated)
    }

    private static func unknownAnswer() -> AskClarityAnswer {
        AskClarityAnswer(
            headline: "I couldn't find a supported way to answer that yet.",
            supportingDetail: "Try asking about spending, income, budget status, or a specific category — the chips below are examples, not the only things I can answer.",
            hasSufficientData: false
        )
    }

    // MARK: - Dispatch

    private static func resolve(
        query: AskClarityQuery,
        context: AskClaritySessionContext,
        entries: [Entry],
        budgets: [Budget],
        headCategories: [HeadCategory],
        settings: BudgetCalculationSettings,
        calendar: Calendar,
        today: Date
    ) -> Result {
        // 1. Category resolution problems come first — never guess past an ambiguity or a miss.
        if let categoryMatch = query.categoryMatch {
            switch categoryMatch {
            case .ambiguous(let phrase, let candidates):
                let names = candidates.map(\.name).joined(separator: " or ")
                return Result(
                    answer: AskClarityAnswer(headline: "Do you mean \(names)?", hasSufficientData: false),
                    updatedContext: context
                )
            case .notFound(let phrase):
                return Result(
                    answer: AskClarityAnswer(headline: "I don't have a category called \"\(phrase)\".", hasSufficientData: false),
                    updatedContext: context
                )
            case .resolved, .resolvedHeadCategory:
                break
            }
        }

        // 2. An explicitly-unsupported period is stated plainly — never silently answered as if
        //    the user meant the current month. Or a date/date-range-shaped phrase that couldn't
        //    be resolved safely — asked to be clarified instead of guessed at or dropped.
        if case .ambiguous(let phrase) = query.periodMatch {
            return Result(
                answer: AskClarityAnswer(headline: AskClarityInterpreter.dateRangeClarificationHeadline(for: phrase), hasSufficientData: false),
                updatedContext: context
            )
        }
        if case .unsupported = query.periodMatch {
            return Result(
                answer: AskClarityAnswer(headline: "I can currently analyze \(AskClarityInterpreter.supportedPeriodsDescription).", hasSufficientData: false),
                updatedContext: context
            )
        }

        let period = AskClarityPlanner.effectivePeriod(query: query, context: context, today: today, calendar: calendar)
        // Only a single, specifically-named category — a `.resolvedHeadCategory` aggregate
        // intentionally doesn't count here, so ranking/direction/budget-state questions (which
        // all expect one concrete category) fall back to their no-category behavior for an
        // aggregate rather than guessing which single child was meant. Only the plain amount
        // question (step 8, via `resolvedSubject`) understands an aggregate.
        let resolvedCategory: Category? = {
            if case .resolved(let category) = query.categoryMatch { return category }
            return nil
        }()
        let resolvedSubject: AskClaritySubject? = {
            switch query.categoryMatch {
            case .resolved(let category):
                return AskClaritySubject(name: category.name, categories: [category], singleCategory: category)
            case .resolvedHeadCategory(let head, let categories):
                return AskClaritySubject(name: head.name, categories: categories, singleCategory: nil)
            default:
                return nil
            }
        }()

        // 4. Ranking questions ("most," "biggest," "top categories," "biggest expense"). Plain
        //    category/transaction ranking is always planned by `AskClarityPlanner` before `resolve`
        //    is reached (see `AskClarityEngine.respond`) — only ranking *by change* (ranking +
        //    direction together) still lands here.
        if let ranking = query.ranking, resolvedCategory == nil {
            if let direction = query.direction {
                return categoryChangeRankingAnswer(
                    ranking: ranking, direction: direction, period: period, context: context,
                    entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today
                )
            }
            return Result(answer: unknownAnswer(), updatedContext: context)
        }

        // 5. Direction-only ("which categories increased," "what changed compared with last month").
        if let direction = query.direction, query.ranking == nil {
            return directionAnswer(
                direction: direction, category: resolvedCategory, period: period, context: context,
                entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today
            )
        }
        if query.wantsChangeSummary, resolvedCategory == nil {
            // "What changed compared with last month?" — no explicit direction word at all, so
            // this is deliberately gated on `wantsChangeSummary` (not the broader
            // `comparisonRequested`), which also covers "did I spend more this month than last
            // month" — a *total*-spending comparison that belongs in the planned `.amount`
            // operation instead (see `AskClarityPlanner`'s step 9).
            return directionAnswer(
                direction: nil, category: nil, period: period, context: context,
                entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today
            )
        }

        // 6. "Why am I spending more/less this month?"
        if query.wantsWhyExplanation, resolvedCategory == nil {
            return whyAnswer(period: period, context: context, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
        }

        // 7. "Where could I reduce spending?"
        if query.wantsReduceAdvice {
            return reduceSpendingAnswer(period: period, context: context, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
        }

        // 8. A specific category or an aggregated head category with an assessment ("am I
        //    spending too much on X") — a plain category amount (no assessment) is always planned
        //    by `AskClarityPlanner` before `resolve` is reached; only the assessment case, which
        //    is a budget lookup rather than a plain total, still lands here.
        if let subject = resolvedSubject {
            if query.wantsAssessment, let category = subject.singleCategory {
                return assessmentAnswer(category: category, period: period, context: context, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
            }
            return Result(answer: unknownAnswer(), updatedContext: context)
        }

        // 9. A plain metric, no category — total spending/income/remaining budget/savings, and
        //    budget-state questions ("which categories are over budget") — are always planned by
        //    `AskClarityPlanner` before `resolve` is reached, so reaching here means no metric,
        //    category, ranking, direction, budget-state, why, or reduce-advice signal was found.
        return Result(
            answer: AskClarityAnswer(
                headline: "I recognized part of that question, but not enough to answer it yet.",
                supportingDetail: "Try naming a metric (spending, income, budget) or a category.",
                hasSufficientData: false
            ),
            updatedContext: context
        )
    }

    // MARK: - Period resolution

    /// The calendar-month `Date` (first-of-month) a month-based period kind refers to — `nil` for
    /// the raw-range kinds, which never reach this. Internal (not `private`) so `AskClarityExecutor`
    /// can resolve the same month `Date` for a planned amount/ranking without a second copy of
    /// this mapping.
    static func monthDate(for kind: AskClarityPeriodKind, today: Date, calendar: Calendar) -> Date? {
        switch kind {
        case .thisMonth: return Date.startOfMonth(for: today, calendar: calendar)
        case .lastMonth: return calendar.date(byAdding: .month, value: -1, to: Date.startOfMonth(for: today, calendar: calendar))
        case .specificMonth(let date): return date
        case .today, .yesterday, .thisWeek, .lastWeek, .thisWeekend, .lastWeekend, .dateRange: return nil
        }
    }

    private static func stateDescription(_ state: BudgetHealthState) -> String {
        switch state {
        case .overBudget: return "over budget"
        case .approachingLimit: return "approaching their limit"
        case .onTrack: return "within budget"
        }
    }

    // MARK: - 5. Category ranking by change
    //
    // Plain category ranking and transaction ranking ("what was my biggest expense") are handled
    // by `AskClarityPlanner`/`AskClarityExecutor`/`AskClarityEngine.respondToCategoryRanking`/
    // `respondToTransactionRanking` before `resolve` is reached — only ranking *by change*
    // (ranking + direction together, e.g. "which category increased the most") still lands here.

    private static func categoryChangeRankingAnswer(
        ranking: AskClarityRanking, direction: AskClarityChangeDirection, period: AskClarityPeriod, context: AskClaritySessionContext,
        entries: [Entry], budgets: [Budget], headCategories: [HeadCategory], settings: BudgetCalculationSettings, calendar: Calendar, today: Date
    ) -> Result {
        guard period.kind.isMonthBased, let month = monthDate(for: period.kind, today: today, calendar: calendar) else {
            return Result(
                answer: AskClarityAnswer(headline: "I can compare category changes month to month, not for \(period.label) yet.", hasSufficientData: false),
                updatedContext: context
            )
        }
        let explanation = ExplainMyMonthCalculator.explain(month: month, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
        guard explanation.previousMonthComparison != nil else {
            return Result(answer: AskClarityAnswer(headline: "Not enough history yet to compare category changes.", hasSufficientData: false), updatedContext: context)
        }
        let wantedFavorable = direction == .decreased
        let candidates = explanation.notableCategoryChanges.filter { $0.isFavorable == wantedFavorable }
        guard let winner = candidates.max(by: { ($0.magnitudeFraction ?? 0) < ($1.magnitudeFraction ?? 0) }) else {
            return Result(answer: AskClarityAnswer(headline: "No category \(direction == .increased ? "increased" : "decreased") significantly compared to last month.", hasSufficientData: true), updatedContext: context)
        }
        let percent = (winner.magnitudeFraction ?? 0).formatted(.percent.precision(.fractionLength(0)))
        let headline = "\(winner.subject) \(direction == .increased ? "increased" : "decreased") the most, \(percent) compared to last month."

        // Looked up by name so a follow-up like "Is that over budget?" can resolve `winner`'s
        // actual `Category` — `notableCategoryChanges` itself only carries the name as a String.
        let winnerCategory = headCategories.flatMap { $0.categories }.first { $0.name == winner.subject }
        let updated = winnerCategory.map { updatedContext(from: context, category: $0, metric: .spending, period: period, value: nil) } ?? context
        let followUps = ["Is \(winner.subject) over budget?", "How much did I spend on \(winner.subject)?"]
        return Result(answer: AskClarityAnswer(headline: headline, hasSufficientData: true, followUpSuggestions: followUps), updatedContext: updated)
    }

    // MARK: - 5. Direction-only

    private static func directionAnswer(
        direction: AskClarityChangeDirection?, category: Category?, period: AskClarityPeriod, context: AskClaritySessionContext,
        entries: [Entry], budgets: [Budget], headCategories: [HeadCategory], settings: BudgetCalculationSettings, calendar: Calendar, today: Date
    ) -> Result {
        guard period.kind.isMonthBased, let month = monthDate(for: period.kind, today: today, calendar: calendar) else {
            return Result(answer: AskClarityAnswer(headline: "I can compare category changes month to month, not for \(period.label) yet.", hasSufficientData: false), updatedContext: context)
        }
        let explanation = ExplainMyMonthCalculator.explain(month: month, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
        guard explanation.previousMonthComparison != nil else {
            return Result(answer: AskClarityAnswer(headline: "Not enough history yet — last month has no comparable spending logged.", hasSufficientData: false), updatedContext: context)
        }

        if let category {
            guard let change = explanation.notableCategoryChanges.first(where: { $0.subject == category.name }) else {
                return Result(answer: AskClarityAnswer(headline: "\(category.name) didn't change significantly compared to last month.", hasSufficientData: true), updatedContext: context)
            }
            let percent = (change.magnitudeFraction ?? 0).formatted(.percent.precision(.fractionLength(0)))
            let word = change.direction == .up ? "increased" : "decreased"
            return Result(answer: AskClarityAnswer(headline: "\(category.name) \(word) \(percent) compared to last month.", hasSufficientData: true), updatedContext: context)
        }

        let matches = direction.map { wanted in explanation.notableCategoryChanges.filter { ($0.direction == .up) == (wanted == .increased) } } ?? explanation.notableCategoryChanges

        guard !matches.isEmpty else {
            let word = direction == .decreased ? "decreased" : "changed"
            return Result(answer: AskClarityAnswer(headline: "No categories \(word) significantly compared to last month.", hasSufficientData: true), updatedContext: context)
        }
        let names = matches.map(\.subject).joined(separator: ", ")
        let detail = matches.map { "\($0.subject) \($0.direction == .up ? "+" : "-")\(($0.magnitudeFraction ?? 0).formatted(.percent.precision(.fractionLength(0))))" }.joined(separator: ", ")
        let verb = direction == .decreased ? "decreased" : (direction == .increased ? "increased" : "changed")
        return Result(answer: AskClarityAnswer(headline: "\(names) \(verb) compared to last month.", supportingDetail: detail, hasSufficientData: true), updatedContext: context)
    }

    // MARK: - 6. Why

    private static func whyAnswer(
        period: AskClarityPeriod, context: AskClaritySessionContext, entries: [Entry], budgets: [Budget], headCategories: [HeadCategory], settings: BudgetCalculationSettings, calendar: Calendar, today: Date
    ) -> Result {
        guard period.kind.isMonthBased, let month = monthDate(for: period.kind, today: today, calendar: calendar) else {
            return Result(answer: AskClarityAnswer(headline: "I can explain month-to-month changes, not for \(period.label) yet.", hasSufficientData: false), updatedContext: context)
        }
        let explanation = ExplainMyMonthCalculator.explain(month: month, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
        guard let comparison = explanation.previousMonthComparison else {
            return Result(answer: AskClarityAnswer(headline: "Not enough history yet — last month has no comparable spending logged.", hasSufficientData: false), updatedContext: context)
        }

        let percent = abs(comparison.fraction).formatted(.percent.precision(.fractionLength(0)))
        if comparison.direction == .down {
            return Result(
                answer: AskClarityAnswer(
                    headline: "Actually, you spent \(percent) less this month (\(comparison.currentTotal.currencyFormatted) vs. \(comparison.previousTotal.currencyFormatted)), not more.",
                    hasSufficientData: true, comparisonIsFavorable: true
                ),
                updatedContext: context
            )
        }

        let increases = explanation.notableCategoryChanges.filter { $0.isFavorable == false }.sorted { ($0.magnitudeFraction ?? 0) > ($1.magnitudeFraction ?? 0) }
        let headline = "You spent \(percent) more this month (\(comparison.currentTotal.currencyFormatted) vs. \(comparison.previousTotal.currencyFormatted))."
        guard !increases.isEmpty else {
            return Result(
                answer: AskClarityAnswer(headline: headline, supportingDetail: "No single category stands out — the increase is spread across several categories.", hasSufficientData: true, comparisonIsFavorable: false),
                updatedContext: context
            )
        }
        let detail = "Biggest contributors: " + increases.prefix(3).map { "\($0.subject) (+\(($0.magnitudeFraction ?? 0).formatted(.percent.precision(.fractionLength(0)))))" }.joined(separator: ", ")
        let followUps = increases.prefix(2).map { "How much was \($0.subject) last month?" }
        return Result(
            answer: AskClarityAnswer(headline: headline, supportingDetail: detail, hasSufficientData: true, followUpSuggestions: Array(followUps), comparisonIsFavorable: false),
            updatedContext: context
        )
    }

    // MARK: - 7. Where could I reduce spending

    private static func reduceSpendingAnswer(
        period: AskClarityPeriod, context: AskClaritySessionContext, entries: [Entry], budgets: [Budget], headCategories: [HeadCategory], settings: BudgetCalculationSettings, calendar: Calendar, today: Date
    ) -> Result {
        guard period.kind.isMonthBased, let month = monthDate(for: period.kind, today: today, calendar: calendar) else {
            return Result(answer: AskClarityAnswer(headline: "I can suggest this at a monthly level, not for \(period.label) yet.", hasSufficientData: false), updatedContext: context)
        }
        let explanation = ExplainMyMonthCalculator.explain(month: month, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
        guard explanation.hasActivity else {
            return Result(answer: AskClarityAnswer(headline: "No spending logged yet \(period.label) to look at.", hasSufficientData: false), updatedContext: context)
        }

        var lines: [String] = []
        var names: [String] = []
        var seen = Set<String>()

        for row in explanation.budgetPerformance?.overBudgetCategories ?? [] {
            guard seen.insert(row.category.name).inserted else { continue }
            lines.append("\(row.category.name): \((row.spent - row.budgeted).currencyFormatted) over its \(row.budgeted.currencyFormatted) budget")
            names.append(row.category.name)
        }
        for change in explanation.notableCategoryChanges.filter({ $0.isFavorable == false }).sorted(by: { ($0.magnitudeFraction ?? 0) > ($1.magnitudeFraction ?? 0) }) {
            guard seen.insert(change.subject).inserted else { continue }
            lines.append("\(change.subject): up \(((change.magnitudeFraction ?? 0)).formatted(.percent.precision(.fractionLength(0)))) vs. last month")
            names.append(change.subject)
        }

        guard !lines.isEmpty else {
            return Result(
                answer: AskClarityAnswer(headline: "Nothing stands out — no category is over budget or notably higher than last month.", hasSufficientData: true, comparisonIsFavorable: true),
                updatedContext: context
            )
        }

        let followUps = names.prefix(2).map { "Why did \($0) increase?" }
        return Result(
            answer: AskClarityAnswer(
                headline: "A few places to look:", supportingDetail: lines.prefix(3).joined(separator: "\n"),
                hasSufficientData: true, followUpSuggestions: Array(followUps), comparisonIsFavorable: false
            ),
            updatedContext: context
        )
    }

    // MARK: - Respond (category amount) / 8. Assessment

    /// Handles both a single category ("Hotel") and an aggregated head category ("Travelling" =
    /// Flights + Hotel + Activities + ...) through the same path — `subject.categories` is
    /// `[category]` for the former, every child for the latter. `amount`/`previousPeriod` are
    /// already computed by `AskClarityExecutor`; this only decides which comparison (if any) to
    /// show and how to word the answer.
    ///
    /// The comparison baseline is `context`'s *anchor*, not simply "whatever the previous turn
    /// showed": a chain of period-only follow-ups about the same category ("this week" -> "last
    /// week" -> "last month") all compare against the one figure first shown for that category,
    /// set once and deliberately left unchanged as the chain continues. Without this, the
    /// baseline silently drifts to compare against whatever was asked immediately before —
    /// concretely, "restaurants this month" (€20) -> "and last week" (€0, correctly "€20 less
    /// than this month") -> "and last month" would otherwise compare against *last week's* €0
    /// instead of this month's €20, producing an unhelpful "same as last week" — rather than a
    /// single, predictable rule: always compare against the figure this category's chain started
    /// from. The anchor resets the moment the category itself changes.
    private static func categoryAmountAnswer(
        subject: AskClaritySubject, period: AskClarityPeriod, amount: Decimal, previousPeriod: (amount: Decimal, label: String)?, context: AskClaritySessionContext
    ) -> Result {
        let anchor: (period: AskClarityPeriod, value: Decimal)?
        if let singleCategory = subject.singleCategory, let anchorCategory = context.anchorCategory, anchorCategory === singleCategory,
           let anchorPeriod = context.anchorPeriod, let anchorValue = context.anchorAnswerValue {
            anchor = (anchorPeriod, anchorValue)
        } else {
            anchor = nil
        }

        var detail = ""
        var isFavorable: Bool?

        if let anchor, anchor.period.kind != period.kind {
            (detail, isFavorable) = comparisonSentence(current: amount, currentLabel: nil, previous: anchor.value, previousLabel: anchor.period.label)
        } else if let previousPeriod {
            (detail, isFavorable) = comparisonSentence(current: amount, currentLabel: nil, previous: previousPeriod.amount, previousLabel: previousPeriod.label)
        }

        let headline = "You spent \(amount.currencyFormatted) on \(subject.name) \(period.label)."
        var updated = updatedContext(from: context, category: subject.singleCategory, metric: .spending, period: period, value: amount)

        let sameSubjectAsAnchor: Bool = {
            guard let singleCategory = subject.singleCategory, let anchorCategory = context.anchorCategory else { return false }
            return singleCategory === anchorCategory
        }()
        if !sameSubjectAsAnchor {
            // A new subject (or an aggregate, which has no single `Category` to anchor on)
            // starts its own fresh anchor right here, at this period/value.
            updated.anchorCategory = subject.singleCategory
            updated.anchorPeriod = subject.singleCategory != nil ? period : nil
            updated.anchorAnswerValue = subject.singleCategory != nil ? amount : nil
        }

        var followUps = ["Is \(subject.name) over budget?"]
        followUps.append(period.kind == .lastMonth ? "How much is \(subject.name) this month?" : "How much was \(subject.name) last month?")
        return Result(
            answer: AskClarityAnswer(headline: headline, supportingDetail: detail, hasSufficientData: true, followUpSuggestions: followUps, comparisonIsFavorable: isFavorable),
            updatedContext: updated
        )
    }

    private static func assessmentAnswer(
        category: Category, period: AskClarityPeriod, context: AskClaritySessionContext,
        entries: [Entry], budgets: [Budget], headCategories: [HeadCategory], settings: BudgetCalculationSettings, calendar: Calendar, today: Date
    ) -> Result {
        guard period.kind.isMonthBased, let month = monthDate(for: period.kind, today: today, calendar: calendar) else {
            return Result(answer: AskClarityAnswer(headline: "I can assess this at a monthly level, not for \(period.label) yet.", hasSufficientData: false), updatedContext: context)
        }
        let summary = BudgetCalculator.periodSpendingSummary(month: month, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, respectHiddenCategories: true, calendar: calendar)
        guard let row = summary.byCategory.first(where: { $0.category === category }), row.actual > 0 else {
            return Result(answer: AskClarityAnswer(headline: "No spending logged for \(category.name) \(period.label).", hasSufficientData: false), updatedContext: context)
        }

        let observed = "You've spent \(row.actual.currencyFormatted) on \(category.name) \(period.label)."
        let updated = updatedContext(from: context, category: category, metric: .spending, period: period, value: row.actual)
        let followUps = ["How much was \(category.name) last month?", "Where could I reduce spending?"]

        if row.planned > 0 {
            let progress = (row.actual / row.planned).doubleValue
            let state = BudgetHealthState.forProgress(progress)
            let comparison = "That's \(progress.formatted(.percent.precision(.fractionLength(0)))) of your \(row.planned.currencyFormatted) budget."
            let interpretation: String
            switch state {
            case .overBudget: interpretation = "You're over budget for this category."
            case .approachingLimit: interpretation = "You're approaching your limit for this category."
            case .onTrack: interpretation = "You're within budget for this category."
            }
            return Result(
                answer: AskClarityAnswer(headline: observed, supportingDetail: "\(comparison) \(interpretation)", hasSufficientData: true, followUpSuggestions: followUps, comparisonIsFavorable: state != .overBudget),
                updatedContext: updated
            )
        }

        guard
            let previousMonth = calendar.date(byAdding: .month, value: -1, to: month)
        else {
            return Result(answer: AskClarityAnswer(headline: observed, supportingDetail: "\(category.name) isn't budgeted, so there's nothing to compare it against yet.", hasSufficientData: true, followUpSuggestions: followUps), updatedContext: updated)
        }
        let previousSummary = BudgetCalculator.periodSpendingSummary(month: previousMonth, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, respectHiddenCategories: true, calendar: calendar)
        guard let previousActual = previousSummary.byCategory.first(where: { $0.category === category })?.actual, previousActual > 0 else {
            return Result(answer: AskClarityAnswer(headline: observed, supportingDetail: "\(category.name) isn't budgeted, and there's no prior month to compare against yet.", hasSufficientData: true, followUpSuggestions: followUps), updatedContext: updated)
        }
        let fraction = ((row.actual - previousActual) / previousActual).doubleValue
        let comparison = "That's \(abs(fraction).formatted(.percent.precision(.fractionLength(0)))) \(fraction >= 0 ? "higher" : "lower") than last month (\(previousActual.currencyFormatted))."
        let interpretation = fraction >= HomeCalculator.whatsDifferentThreshold
            ? "That's a notable increase."
            : (fraction <= -HomeCalculator.whatsDifferentThreshold ? "That's a notable decrease." : "That's roughly in line with last month.")
        return Result(
            answer: AskClarityAnswer(headline: observed, supportingDetail: "\(comparison) \(interpretation)", hasSufficientData: true, followUpSuggestions: followUps, comparisonIsFavorable: fraction <= 0),
            updatedContext: updated
        )
    }

    // MARK: - Shared helpers

    static func dateBounds(for kind: AskClarityPeriodKind, today: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        kind.rawRange(today: today, calendar: calendar)
    }

    /// Real date bounds for *any* period kind, including month-based ones — a plain calendar-
    /// month interval, matching `SpendingInsightsCardView.topTransactions`'s own `.inMonth`
    /// convention for a raw entry scan. Only used where budget-cycle awareness doesn't apply
    /// (transaction-level ranking has no budget concept) — `categorySpending`/`totalSpending`
    /// deliberately keep routing month-based periods through `periodSpendingSummary` instead, so
    /// they still respect `settings.cycleStartDay`.
    static func calendarBounds(for kind: AskClarityPeriodKind, today: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        if let raw = kind.rawRange(today: today, calendar: calendar) { return raw }
        guard
            let month = monthDate(for: kind, today: today, calendar: calendar),
            let interval = calendar.dateInterval(of: .month, for: month)
        else { return nil }
        return (interval.start, interval.end)
    }

    /// Summed across every category in `categories` — `[category]` for a plain single-category
    /// question, or a head category's full child list for an aggregate one ("Travelling"). Reuses
    /// the exact same per-category totals (`periodSpendingSummary.byCategory` / `AskClarityRangeCalculator.
    /// spending`) either way, just summed over more than one when there's more than one.
    static func categoriesSpending(
        categories: [Category], period: AskClarityPeriod, entries: [Entry], budgets: [Budget], headCategories: [HeadCategory], settings: BudgetCalculationSettings, calendar: Calendar, today: Date
    ) -> Decimal? {
        if period.kind.isMonthBased {
            guard let month = monthDate(for: period.kind, today: today, calendar: calendar) else { return nil }
            let summary = BudgetCalculator.periodSpendingSummary(month: month, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, respectHiddenCategories: true, calendar: calendar)
            let categoryIDs = Set(categories.map(ObjectIdentifier.init))
            return summary.byCategory.filter { categoryIDs.contains(ObjectIdentifier($0.category)) }.reduce(Decimal(0)) { $0 + $1.actual }
        }
        guard let (start, end) = dateBounds(for: period.kind, today: today, calendar: calendar) else { return nil }
        return categories.reduce(Decimal(0)) { $0 + AskClarityRangeCalculator.spending(from: start, to: end, entries: entries, category: $1) }
    }

    /// Internal (not `private`) so `AskClarityExecutor`'s plain-metric/trend branches can reuse it
    /// rather than re-deriving a spending total a second way.
    static func totalSpending(
        period: AskClarityPeriod, entries: [Entry], budgets: [Budget], headCategories: [HeadCategory], settings: BudgetCalculationSettings, calendar: Calendar, today: Date
    ) -> Decimal? {
        if period.kind.isMonthBased {
            guard let month = monthDate(for: period.kind, today: today, calendar: calendar) else { return nil }
            return BudgetCalculator.periodSpendingSummary(month: month, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, respectHiddenCategories: true, calendar: calendar).totalSpent
        }
        guard let (start, end) = dateBounds(for: period.kind, today: today, calendar: calendar) else { return nil }
        return AskClarityRangeCalculator.spending(from: start, to: end, entries: entries)
    }

    /// Total income for a period — respects `settings.cycleStartDay` for month-based periods via
    /// `periodSpendingSummary`, exactly like every other budget-period figure, rather than a raw
    /// entry scan across the calendar month.
    static func totalIncome(
        period: AskClarityPeriod, entries: [Entry], budgets: [Budget], headCategories: [HeadCategory], settings: BudgetCalculationSettings, calendar: Calendar, today: Date
    ) -> Decimal? {
        if period.kind.isMonthBased {
            guard let month = monthDate(for: period.kind, today: today, calendar: calendar) else { return nil }
            return BudgetCalculator.periodSpendingSummary(month: month, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, respectHiddenCategories: true, calendar: calendar).totalIncome
        }
        guard let (start, end) = dateBounds(for: period.kind, today: today, calendar: calendar) else { return nil }
        return AskClarityRangeCalculator.income(from: start, to: end, entries: entries)
    }

    /// A plain (no-category) total for any of the four metrics, for one period — the single
    /// dispatch point `AskClarityExecutor`'s trend/comparison branches share so a "spending trend"
    /// and an "income trend" walk the exact same chain-building code. Remaining budget/savings
    /// route through `periodSpendingSummary` directly here (not a separate helper) since, unlike
    /// the plain single-period answer, a trend point has no need for the richer "is there any
    /// data at all" distinction — a real `0` is just as valid a trend point as any other amount.
    static func metricTotal(
        metric: AskClarityMetric, period: AskClarityPeriod, entries: [Entry], budgets: [Budget], headCategories: [HeadCategory], settings: BudgetCalculationSettings, calendar: Calendar, today: Date
    ) -> Decimal? {
        switch metric {
        case .spending:
            return totalSpending(period: period, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
        case .income:
            return totalIncome(period: period, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today)
        case .remainingBudget:
            guard period.kind.isMonthBased, let month = monthDate(for: period.kind, today: today, calendar: calendar) else { return nil }
            return BudgetCalculator.periodSpendingSummary(month: month, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, respectHiddenCategories: true, calendar: calendar).totalLeft
        case .savings:
            guard period.kind.isMonthBased, let month = monthDate(for: period.kind, today: today, calendar: calendar) else { return nil }
            return BudgetCalculator.periodSpendingSummary(month: month, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, respectHiddenCategories: true, calendar: calendar).savingsTransfersTotal
        }
    }

    /// The previous equivalent period's category spend, for a plain (non-contextual) comparison.
    static func previousPeriodAmount(
        categories: [Category], period: AskClarityPeriod, entries: [Entry], budgets: [Budget], headCategories: [HeadCategory], settings: BudgetCalculationSettings, calendar: Calendar, today: Date
    ) -> (amount: Decimal, label: String)? {
        guard let (previousKind, label) = period.kind.previousEquivalent(today: today, calendar: calendar) else { return nil }
        let previousPeriod = AskClarityPeriod(kind: previousKind, label: label)
        guard let amount = categoriesSpending(categories: categories, period: previousPeriod, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today) else { return nil }
        return (amount, label)
    }

    /// The previous equivalent period's plain metric total (spending or income — the only two
    /// metrics a plain-total comparison is currently wired for; see `AskClarityPlanner`'s step 9).
    static func previousMetricPeriodTotal(
        metric: AskClarityMetric, period: AskClarityPeriod, entries: [Entry], budgets: [Budget], headCategories: [HeadCategory], settings: BudgetCalculationSettings, calendar: Calendar, today: Date
    ) -> (amount: Decimal, label: String)? {
        guard let (previousKind, label) = period.kind.previousEquivalent(today: today, calendar: calendar) else { return nil }
        let previousPeriod = AskClarityPeriod(kind: previousKind, label: label)
        guard let amount = metricTotal(metric: metric, period: previousPeriod, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today), amount > 0 else { return nil }
        return (amount, label)
    }

    /// `isFavorable` is spending-shaped: less than the comparison point reads as good news, more
    /// reads as bad news, an exact match is neutral. Every current call site is a spending
    /// figure, so this single convention is correct everywhere it's used.
    private static func comparisonSentence(current: Decimal, currentLabel: String?, previous: Decimal, previousLabel: String) -> (text: String, isFavorable: Bool?) {
        let diff = abs(current - previous)
        if diff == 0 {
            return ("Same as \(previousLabel).", nil)
        }
        let isMore = current > previous
        let word = isMore ? "more" : "less"
        return ("\(diff.currencyFormatted) \(word) than \(previousLabel) (\(previous.currencyFormatted)).", !isMore)
    }

    private static func updatedContext(from context: AskClaritySessionContext, category: Category?, metric: AskClarityMetric, period: AskClarityPeriod, value: Decimal? = nil) -> AskClaritySessionContext {
        var updated = context
        updated.lastCategory = category
        updated.lastMetric = metric
        updated.lastPeriod = period
        updated.lastAnswerValue = value
        return updated
    }
}
