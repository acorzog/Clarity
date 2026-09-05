import SwiftUI
import SwiftData

struct ExportCSVView: View {
    @Query(sort: \Entry.date) private var allEntries: [Entry]

    @State private var startDate: Date
    @State private var endDate: Date
    @State private var exportURL: URL?

    init() {
        let calendar = Calendar.current
        let now = Date.now
        let monthInterval = calendar.dateInterval(of: .month, for: now)
        let lastDayOfMonth = monthInterval.flatMap { calendar.date(byAdding: .day, value: -1, to: $0.end) } ?? now

        _startDate = State(initialValue: Date.startOfMonth(for: now))
        _endDate = State(initialValue: lastDayOfMonth)
    }

    private var rangeStart: Date { Calendar.current.startOfDay(for: min(startDate, endDate)) }
    private var rangeEnd: Date {
        let dayAfterEnd = Calendar.current.date(byAdding: .day, value: 1, to: max(startDate, endDate)) ?? endDate
        return Calendar.current.startOfDay(for: dayAfterEnd)
    }

    private var entriesInRange: [Entry] {
        allEntries.filter { $0.date >= rangeStart && $0.date < rangeEnd }
    }

    private var foundText: String {
        let count = entriesInRange.count
        return "Found \(count) transaction\(count == 1 ? "" : "s")"
    }

    var body: some View {
        Form {
            Section("Date Range") {
                DatePicker("From", selection: $startDate, displayedComponents: .date)
                DatePicker("To", selection: $endDate, displayedComponents: .date)
            }
            .listRowBackground(Color.white.opacity(0.05))
            .onChange(of: startDate) { regenerate() }
            .onChange(of: endDate) { regenerate() }

            Section {
                if entriesInRange.isEmpty {
                    Text("No transactions in this date range")
                        .foregroundStyle(.white.opacity(0.4))
                } else if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Export", systemImage: "square.and.arrow.up")
                            .foregroundStyle(Color.emerald)
                    }
                }
            } footer: {
                Text(foundText)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .listRowBackground(Color.white.opacity(0.05))
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Export CSV")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: regenerate)
    }

    private func regenerate() {
        guard !entriesInRange.isEmpty else {
            exportURL = nil
            return
        }
        exportURL = CSVExporter.writeToTemporaryFile(
            entries: entriesInRange,
            startDate: rangeStart,
            endDate: max(startDate, endDate)
        )
    }
}
