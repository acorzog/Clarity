import WidgetKit
import SwiftUI

struct QuickLogEntry: TimelineEntry {
    let date: Date
}

struct QuickLogProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickLogEntry {
        QuickLogEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickLogEntry) -> Void) {
        completion(QuickLogEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickLogEntry>) -> Void) {
        completion(Timeline(entries: [QuickLogEntry(date: .now)], policy: .never))
    }
}

struct QuickLogWidgetView: View {
    let entry: QuickLogEntry

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(LinearGradient.emeraldSky)
            Text("Add Expense")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text("Quick Log")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding()
        .containerBackground(for: .widget) {
            Color.appBackground
        }
        .widgetURL(URL(string: "financetracker://add-transaction"))
    }
}

struct QuickLogWidget: Widget {
    let kind = "QuickLogWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickLogProvider()) { entry in
            QuickLogWidgetView(entry: entry)
        }
        .configurationDisplayName("Quick Log")
        .description("Jump straight to adding a new transaction.")
        .supportedFamilies([.systemSmall])
    }
}

#Preview(as: .systemSmall) {
    QuickLogWidget()
} timeline: {
    QuickLogEntry(date: .now)
}
