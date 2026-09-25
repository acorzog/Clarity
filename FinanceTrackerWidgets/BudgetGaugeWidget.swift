import WidgetKit
import SwiftUI
import SwiftData

struct BudgetGaugeEntry: TimelineEntry {
    let date: Date
    /// Same meaning as `PeriodSpendingSummary.totalAvailable` — the manual/income/planned-budget
    /// fallback chain `RemainingView` uses, not simply the raw planned-budget total.
    let available: Decimal
    let spent: Decimal
}

struct BudgetGaugeProvider: TimelineProvider {
    func placeholder(in context: Context) -> BudgetGaugeEntry {
        BudgetGaugeEntry(date: .now, available: 1000, spent: 400)
    }

    func getSnapshot(in context: Context, completion: @escaping (BudgetGaugeEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : BudgetGaugeDataSource.currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BudgetGaugeEntry>) -> Void) {
        let entry = BudgetGaugeDataSource.currentEntry()
        let nextRefresh = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? Date.now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

/// Kept outside `BudgetGaugeProvider` because `TimelineProvider` declares its own
/// associated type named `Entry`, which would shadow the SwiftData `Entry` model
/// used here if this fetch logic lived inside the provider's scope.
///
/// Uses the same `BudgetCalculator.periodSpendingSummary` — with the same
/// `BudgetCalculationSettings(from: BudgetSettingsStore.shared)` — as `RemainingView`, so this
/// widget's "Left" figure can no longer independently disagree with the in-app Remaining gauge
/// (see `CLARITY_PHASE_1_CALCULATION_PROPOSAL.md`). `BudgetSettingsStore` reads from the shared
/// App Group `UserDefaults` suite, so this process sees the same cycle/manual-budget/include
/// settings the app does.
private enum BudgetGaugeDataSource {
    static func currentEntry() -> BudgetGaugeEntry {
        let month = Date.startOfMonth()
        let context = ModelContext(SharedModelContainer.make())

        guard
            let budgets = try? context.fetch(FetchDescriptor<Budget>()),
            let entries = try? context.fetch(FetchDescriptor<Entry>()),
            let headCategories = try? context.fetch(FetchDescriptor<HeadCategory>())
        else {
            return BudgetGaugeEntry(date: .now, available: 0, spent: 0)
        }

        let summary = BudgetCalculator.periodSpendingSummary(
            month: month,
            entries: entries,
            budgets: budgets,
            headCategories: headCategories,
            settings: BudgetCalculationSettings(from: BudgetSettingsStore.shared),
            respectHiddenCategories: true
        )

        return BudgetGaugeEntry(date: .now, available: summary.totalAvailable, spent: summary.totalSpent)
    }
}

struct BudgetGaugeWidgetView: View {
    let entry: BudgetGaugeEntry

    private var left: Decimal { entry.available - entry.spent }
    private var progress: Double {
        guard entry.available > 0 else { return 0 }
        return min(max((entry.spent / entry.available).doubleValue, 0), 1)
    }
    private var ringColor: Color {
        guard entry.available > 0 else { return .white.opacity(0.3) }
        return GaugeThreshold.color(forProgress: progress)
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text("Left")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(left.currencyFormatted)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
            }
            .padding(6)

            Text("Budget")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding()
        .containerBackground(for: .widget) {
            Color.appBackground
        }
    }
}

struct BudgetGaugeWidget: Widget {
    let kind = "BudgetGaugeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BudgetGaugeProvider()) { entry in
            BudgetGaugeWidgetView(entry: entry)
        }
        .configurationDisplayName("Budget")
        .description("See how much you have left to spend this month.")
        .supportedFamilies([.systemSmall])
    }
}

#Preview(as: .systemSmall) {
    BudgetGaugeWidget()
} timeline: {
    BudgetGaugeEntry(date: .now, available: 1000, spent: 400)
}
