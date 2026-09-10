import SwiftUI

/// The consolidated "label — value — chevron" form row that opens a picker sheet. Before this
/// component, four byte-identical private `SelectionRow` structs existed independently in
/// `AddTransactionView.swift`, `RecordPaymentView.swift`, `AddSharedExpenseView.swift`, and
/// `AddSettlementTransactionView.swift` — verified identical during the Phase 2A-2 audit, so
/// this consolidation changes zero behavior at any of its four call sites.
struct SelectionRow: View {
    let title: String
    let iconName: String?
    let iconColorHex: String?
    let valueName: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.textPrimary)
                Spacer()
                if let valueName {
                    if let iconName {
                        Image(systemName: iconName)
                            .foregroundStyle(iconColorHex.map { Color(hex: $0) } ?? .textPrimary)
                    }
                    Text(valueName)
                        .foregroundStyle(.textSecondary)
                } else {
                    Text("Select")
                        .foregroundStyle(.textTertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.textTertiary)
            }
            .contentShape(Rectangle())
            .frame(minHeight: 44)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(valueName ?? "Not selected")
        .accessibilityHint("Double tap to change")
    }
}
