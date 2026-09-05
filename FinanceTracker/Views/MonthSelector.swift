import SwiftUI

struct MonthSelector: View {
    @Binding var month: Date

    var body: some View {
        HStack {
            Button {
                shift(-1)
            } label: {
                Image(systemName: "chevron.left")
            }

            Spacer()

            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
                .foregroundStyle(.white)

            Spacer()

            Button {
                shift(1)
            } label: {
                Image(systemName: "chevron.right")
            }
        }
        .foregroundStyle(.white.opacity(0.6))
    }

    private func shift(_ value: Int) {
        if let newMonth = Calendar.current.date(byAdding: .month, value: value, to: month) {
            month = newMonth
        }
    }
}
