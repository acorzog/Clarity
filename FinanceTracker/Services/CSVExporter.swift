import Foundation

enum CSVExporter {
    private static let header = "Date,Amount,Type,Category,Head Category,Wallet,Note"

    static func makeCSV(entries: [Entry]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var lines = [header]
        for entry in entries {
            let fields = [
                formatter.string(from: entry.date),
                entry.amount.currencyFormatted,
                entry.type.rawValue,
                entry.category?.name ?? "",
                entry.category?.headCategory.name ?? "",
                entry.wallet.name,
                entry.note
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// Writes the CSV to a temp file suitable for handing to a share sheet. Returns nil if the
    /// write fails (e.g. disk full) rather than throwing — export is best-effort UX, not critical.
    static func writeToTemporaryFile(entries: [Entry], startDate: Date, endDate: Date) -> URL? {
        let csv = makeCSV(entries: entries)

        let nameFormatter = DateFormatter()
        nameFormatter.dateFormat = "yyyy-MM-dd"
        let filename = "Clarity-\(nameFormatter.string(from: startDate))-to-\(nameFormatter.string(from: endDate)).csv"

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
