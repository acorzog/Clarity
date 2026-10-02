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
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(LinearGradient.emeraldSky)
            Text("Voice Expense")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text("Open to record")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding()
        .containerBackground(for: .widget) {
            Color.appBackground
        }
        .widgetURL(URL(string: "financetracker://voice-expense"))
    }
}

struct QuickLogWidget: Widget {
    let kind = "QuickLogWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickLogProvider()) { entry in
            QuickLogWidgetView(entry: entry)
        }
        .configurationDisplayName("Voice Expense")
        .description("Open Clarity and record an expense by voice.")
        .supportedFamilies([.systemSmall])
    }
}

#Preview(as: .systemSmall) {
    QuickLogWidget()
} timeline: {
    QuickLogEntry(date: .now)
}
