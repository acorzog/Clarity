import Foundation

/// The one piece of arithmetic behind "compared to my average over the last N periods," computed
/// once here and reused by both the deterministic path (`AskClarityExecutor.
/// executeTrendAverageComparison` → `AskClarityEngine.respondToTrendAverageComparison`) and the
/// semantic-fallback composition (`AskClaritySemanticComposition`) — never two independent copies
/// of "average the history, then compare." Pure and synchronous: every input is already a
/// computed `Decimal`, nothing here touches `Entry`/`Budget`/SwiftData or does its own date math.
struct AskClarityTrendAverageComparison {
    /// The period being asked about.
    let currentAmount: Decimal
    /// The arithmetic mean of `periodsAveraged` consecutive equivalent periods immediately before
    /// the current one — never includes the current period's own point.
    let average: Decimal
    /// How many historical points went into `average` — always `>= minimumPeriods`.
    let periodsAveraged: Int
    let absoluteDifference: Decimal
    let isHigher: Bool
    /// `(currentAmount - average) / abs(average)` — a signed ratio (not already multiplied by
    /// 100): positive when `currentAmount` is higher than `average`, negative when lower, always
    /// agreeing with `isHigher`'s own sign. Divides by `abs(average)`, not `average` itself,
    /// specifically so a *negative* average (a real possibility for `.remainingBudget`, which can
    /// be over budget on average) never flips that sign relationship — dividing by a negative
    /// number would otherwise invert "higher" into a negative percentage and vice versa. `nil`
    /// only when `average == 0` — a percentage deviation from zero is mathematically undefined,
    /// never fabricated as `0%` or an arbitrarily large number. Callers must handle this case with
    /// an explicit, honest message instead of a percentage.
    let percentDifference: Double?

    /// `nil` only when `historicalPoints` (after excluding any point matching `currentPeriodLabel`)
    /// has fewer than `minimumPeriods` entries — there simply isn't enough history yet for
    /// "average" to mean anything, and that must be reported as its own clear outcome rather than
    /// silently averaging one or two points, or falling through to a generic "didn't understand"
    /// answer. Callers should derive `minimumPeriods` from whatever window the question itself
    /// asked for (e.g. "the last 6 periods" implies 5 historical points are required, not an
    /// unrelated fixed constant) — see `AskClarityEngine.respondToTrendAverageComparison` and
    /// `AskClaritySemanticComposition` for how each path derives it. The default of `2` here is
    /// only a fallback for callers with no explicit window to derive from.
    static func compute(
        currentAmount: Decimal,
        currentPeriodLabel: String,
        historicalPoints: [(period: AskClarityPeriod, amount: Decimal)],
        minimumPeriods: Int = 2
    ) -> AskClarityTrendAverageComparison? {
        let historical = historicalPoints.filter { $0.period.label != currentPeriodLabel }
        guard historical.count >= minimumPeriods else { return nil }

        let total = historical.reduce(Decimal(0)) { $0 + $1.amount }
        let average = total / Decimal(historical.count)
        let isHigher = currentAmount > average
        let absoluteDifference = abs(currentAmount - average)
        let percentDifference: Double? = average == 0 ? nil : ((currentAmount - average) / abs(average)).doubleValue

        return AskClarityTrendAverageComparison(
            currentAmount: currentAmount, average: average, periodsAveraged: historical.count,
            absoluteDifference: absoluteDifference, isHigher: isHigher, percentDifference: percentDifference
        )
    }
}
