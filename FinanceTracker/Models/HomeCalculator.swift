import Foundation
import SwiftData

/// Direction of change for a Home "What's Different?" observation — presentation-independent;
/// the view layer maps this to `DeltaIndicator.Direction`. See `CLARITY_HOME_SPEC.md` §6.
enum InsightDirection: Equatable {
    case up
    case down
}

/// How much attention a "What's Different?" observation deserves — used to rank and cap the
/// list to the top few shown on Home (`CLARITY_HOME_SPEC.md` §6, "Density").
enum InsightSeverity: Int, Comparable, Equatable {
    case informational = 0
    case caution = 1
    case warning = 2

    static func < (lhs: InsightSeverity, rhs: InsightSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What kind of deterministic observation this is — lets the view route a tap without
/// re-deriving that from the insight's subject string.
enum WhatsDifferentKind: Equatable {
    case categoryChange
    case incomeChange
    case overPace
    case overPlan
}

/// One deterministic "What's Different?" observation — see `CLARITY_HOME_SPEC.md` §6. Every
/// field is already computed; the view only formats/phrases it, never recomputes it.
struct WhatsDifferentInsight: Identifiable {
    let id: String
    let kind: WhatsDifferentKind
    /// The subject of the observation — a head category name, or "Income" for the income
    /// insight. Empty for `.overPace`, which has no single subject.
    let subject: String
    /// The category this observation is about, for display (icon/color) only — `nil` for
    /// `.incomeChange`/`.overPace`, which aren't tied to a single category.
    let headCategory: HeadCategory?
    let direction: InsightDirection
    /// Fractional change vs. the comparison this insight is based on — the prior month for
    /// `.categoryChange`/`.incomeChange`, the plan for `.overPlan`. `nil` for `.overPace`, which
    /// has no single subject to compute a fraction against.
    let magnitudeFraction: Double?
    /// Absolute currency difference vs. that same comparison (prior month's actual, or planned
    /// amount) — both already computed by `periodSpendingSummary`, just threaded through here
    /// rather than recalculated. `nil` for `.incomeChange`/`.overPace`.
    let amountDifference: Decimal?
    let severity: InsightSeverity
    /// Whether this change is good news, bad news, or neither — decided here (an expense
    /// category rising is unfavorable; income rising is favorable), not inferred by the view
    /// from direction alone.
    let isFavorable: Bool?
}

/// How the current period's cumulative spend compares to its straight-line pace — the input to
/// Home's Forecast preview (`CLARITY_HOME_SPEC.md` §10). Deliberately coarse: this is not a
/// forecast, just a same-period pace comparison, matching `BudgetCalculator.spendingPace`'s own
/// "not a statistical forecast" framing.
enum ForecastPaceState: Equatable {
    /// No budgeted total this period, or no data point for today yet.
    case insufficientData
    /// Cumulative actual spend is at or below the straight-line pace line.
    case onTrack
    /// Cumulative actual spend is ahead of the straight-line pace line.
    case aheadOfPace
}

/// One unsettled Shared event's net outstanding balance — see `CLARITY_HOME_SPEC.md` §7.
/// Positive `amount` means the current user is owed money overall in this event; negative means
/// they owe. Reuses `SharedEvent.outstandingNetBalance` verbatim — no new balance math.
struct UpcomingSharedBalance: Identifiable {
    let event: SharedEvent
    var id: PersistentIdentifier { event.persistentModelID }
    var amount: Decimal { event.outstandingNetBalance }
}

/// Home-specific deterministic calculations layered on top of `BudgetCalculator`'s existing
/// output types — never re-derives budget/spending math itself. Pure, deterministic, SwiftUI-
/// independent, matching `BudgetCalculator`'s own architecture. See `CLARITY_HOME_SPEC.md` §17:
/// "No calculation may be added directly to a Home SwiftUI view."
enum HomeCalculator {
    /// The period-over-period change a category/income insight must clear to be shown —
    /// `CLARITY_HOME_SPEC.md` §6 / §22 Open Decision 4. Recorded here as the initial, centralized,
    /// testable value the spec asked for; not yet product-reviewed.
    static let whatsDifferentThreshold: Double = 0.15

    /// Maximum insights shown on Home at once (`CLARITY_HOME_SPEC.md` §6, "Density").
    static let maxWhatsDifferentInsights = 3

    /// Deterministic "What's Different?" observations for `month`, ranked most-severe-then-
    /// largest-magnitude first and capped to `maxWhatsDifferentInsights`. Reuses
    /// `BudgetCalculator.periodSpendingSummary`/`.spendingPace` for both the current and prior
    /// period — never reads `Entry` directly beyond passing it through to those functions, so
    /// budget eligibility (`Models/BudgetEligibility.swift`) is inherited automatically.
    static func whatsDifferentInsights(
        month: Date,
        entries: [Entry],
        budgets: [Budget],
        headCategories: [HeadCategory],
        settings: BudgetCalculationSettings,
        calendar: Calendar = .current,
        today: Date = .now,
        threshold: Double = whatsDifferentThreshold
    ) -> [WhatsDifferentInsight] {
        guard let previousMonth = calendar.date(byAdding: .month, value: -1, to: month) else { return [] }

        let current = BudgetCalculator.periodSpendingSummary(
            month: month, entries: entries, budgets: budgets, headCategories: headCategories,
            settings: settings, respectHiddenCategories: true, calendar: calendar
        )
        let previous = BudgetCalculator.periodSpendingSummary(
            month: previousMonth, entries: entries, budgets: budgets, headCategories: headCategories,
            settings: settings, respectHiddenCategories: true, calendar: calendar
        )

        var insights: [WhatsDifferentInsight] = []

        for currentHead in current.byHeadCategory {
            if
                let previousHead = previous.byHeadCategory.first(where: { $0.headCategory === currentHead.headCategory }),
                previousHead.actual > 0
            {
                let fraction = ((currentHead.actual - previousHead.actual) / previousHead.actual).doubleValue
                if abs(fraction) >= threshold {
                    insights.append(WhatsDifferentInsight(
                        id: "category-\(currentHead.headCategory.persistentModelID)",
                        kind: .categoryChange,
                        subject: currentHead.headCategory.name,
                        headCategory: currentHead.headCategory,
                        direction: fraction > 0 ? .up : .down,
                        magnitudeFraction: abs(fraction),
                        amountDifference: currentHead.actual - previousHead.actual,
                        severity: .informational,
                        isFavorable: fraction > 0 ? false : true
                    ))
                }
            }

            if currentHead.planned > 0 && currentHead.actual > currentHead.planned {
                insights.append(WhatsDifferentInsight(
                    id: "overplan-\(currentHead.headCategory.persistentModelID)",
                    kind: .overPlan,
                    subject: currentHead.headCategory.name,
                    headCategory: currentHead.headCategory,
                    direction: .up,
                    magnitudeFraction: (-currentHead.remaining / currentHead.planned).doubleValue,
                    amountDifference: -currentHead.remaining,
                    severity: .warning,
                    isFavorable: false
                ))
            }
        }

        if previous.totalIncome > 0 {
            let fraction = ((current.totalIncome - previous.totalIncome) / previous.totalIncome).doubleValue
            if abs(fraction) >= threshold {
                insights.append(WhatsDifferentInsight(
                    id: "income",
                    kind: .incomeChange,
                    subject: "Income",
                    headCategory: nil,
                    direction: fraction > 0 ? .up : .down,
                    magnitudeFraction: abs(fraction),
                    amountDifference: nil,
                    severity: .informational,
                    isFavorable: fraction > 0 ? true : false
                ))
            }
        }

        if current.totalBudgeted > 0 {
            let pace = BudgetCalculator.spendingPace(
                month: month, entries: entries, settings: settings,
                totalPlanned: current.totalBudgeted, calendar: calendar, today: today
            )
            if let latest = pace.last(where: { $0.actual != nil }), let actual = latest.actual, actual > latest.onPace {
                insights.append(WhatsDifferentInsight(
                    id: "pace",
                    kind: .overPace,
                    subject: "",
                    headCategory: nil,
                    direction: .up,
                    magnitudeFraction: nil,
                    amountDifference: nil,
                    severity: .caution,
                    isFavorable: false
                ))
            }
        }

        return Array(
            insights
                .sorted { lhs, rhs in
                    if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                    return (lhs.magnitudeFraction ?? 0) > (rhs.magnitudeFraction ?? 0)
                }
                .prefix(maxWhatsDifferentInsights)
        )
    }

    /// Whether the current period's spend is tracking ahead of, or within, its straight-line
    /// pace — Home's Forecast preview input. Reuses `BudgetCalculator.spendingPace`'s output
    /// verbatim; adds no new spend calculation of its own, and is not a projection of any kind.
    static func forecastPaceState(pace: [DailyPacePoint]) -> ForecastPaceState {
        guard
            let latest = pace.last(where: { $0.actual != nil }),
            let actual = latest.actual,
            latest.onPace > 0
        else { return .insufficientData }
        return actual > latest.onPace ? .aheadOfPace : .onTrack
    }

    /// Maximum Upcoming rows shown on Home (`CLARITY_HOME_SPEC.md` §7, "Content rules").
    static let maxUpcomingItems = 3

    /// Every non-fully-settled Shared event's net outstanding balance, most-outstanding-first —
    /// see `CLARITY_HOME_SPEC.md` §7. V1 Upcoming's only data source; reuses `SharedEvent.
    /// isFullySettled`/`.outstandingNetBalance` (`Models/SharedEventQuerying.swift`) exactly, and
    /// never creates or modifies a `SharedExpense`/`Entry`.
    static func upcomingSharedBalances(events: [SharedEvent]) -> [UpcomingSharedBalance] {
        events
            .filter { !$0.isFullySettled }
            .map { UpcomingSharedBalance(event: $0) }
            .filter { $0.amount != 0 }
            .sorted { abs($0.amount) > abs($1.amount) }
    }

    /// `totalLeft` divided evenly across the days remaining (today included) until `periodEnd` —
    /// Home's "≈ X per day" chip. `periodEnd` is exclusive, matching `PeriodSpendingSummary.
    /// period` (a `DateInterval`) and `periodRangeText`'s own handling of it elsewhere, so the day
    /// count already comes out correct whether the period is a plain calendar month (28/29/30/31
    /// days) or a custom budget cycle. `nil` when there's nothing meaningful to show — the period
    /// has already ended, or there's nothing left to spend.
    static func averageDailyAllowance(
        totalLeft: Decimal, periodEnd: Date, today: Date = .now, calendar: Calendar = .current
    ) -> Decimal? {
        guard totalLeft > 0 else { return nil }
        let daysRemaining = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: today), to: calendar.startOfDay(for: periodEnd)
        ).day ?? 0
        guard daysRemaining > 0 else { return nil }
        return totalLeft / Decimal(daysRemaining)
    }
}
