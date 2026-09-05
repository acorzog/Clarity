import WidgetKit
import SwiftUI
import SwiftData

struct BudgetGaugeEntry: TimelineEntry {
    let date: Date
    let budgeted: Decimal
    let spent: Decimal
}

struct BudgetGaugeProvider: TimelineProvider {
    func placeholder(in context: Context) -> BudgetGaugeEntry {
        BudgetGaugeEntry(date: .now, budgeted: 1000, spent: 400)
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
private enum BudgetGaugeDataSource {
    static func currentEntry() -> BudgetGaugeEntry {
        let month = Date.startOfMonth()
        let (m, y) = month.monthYearComponents

        let context = ModelContext(SharedModelContainer.make())

        guard
            let budgets = try? context.fetch(FetchDescriptor<Budget>()),
            let entries = try? context.fetch(FetchDescriptor<Entry>())
        else {
            return BudgetGaugeEntry(date: .now, budgeted: 0, spent: 0)
        }

        let budgeted = budgets
            .filter { $0.month == m && $0.year == y && !$0.category.isIncome }
            .reduce(Decimal(0)) { $0 + $1.monthlyLimit }
        let spent = entries
            .filter { $0.type == .expense && $0.isIn(month: month) }
            .reduce(Decimal(0)) { $0 + $1.amount }

        return BudgetGaugeEntry(date: .now, budgeted: budgeted, spent: spent)
    }
}

struct BudgetGaugeWidgetView: View {
    let entry: BudgetGaugeEntry

    private var left: Decimal { entry.budgeted - entry.spent }
    private var progress: Double {
        guard entry.budgeted > 0 else { return 0 }
        return min(max((entry.spent / entry.budgeted).doubleValue, 0), 1)
    }
    private var ringColor: Color {
        guard entry.budgeted > 0 else { return .white.opacity(0.3) }
        if progress >= 1 { return .expenseRed }
        if progress >= 0.85 { return Color(red: 0.98, green: 0.68, blue: 0.16) }
        return .emerald
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
    BudgetGaugeEntry(date: .now, budgeted: 1000, spent: 400)
}
