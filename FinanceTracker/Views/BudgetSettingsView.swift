import SwiftUI

struct BudgetSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = BudgetSettingsStore.shared

    private var startDayLabel: String {
        settings.cycleStartDay == 1 ? "First day of the month" : "Day \(settings.cycleStartDay)"
    }

    private var monthlyBudgetLabel: String {
        settings.manualMonthlyBudget > 0 ? settings.manualMonthlyBudget.currencyFormatted : "Use income"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "pencil")
                            .foregroundStyle(.white.opacity(0.4))
                        TextField("Budget name", text: $settings.name)
                            .foregroundStyle(.white)
                    }
                    .padding(.vertical, 4)

                    IconPickerRow(selection: $settings.icon)
                } header: {
                    Text("Appearance")
                }
                .listRowBackground(Color.white.opacity(0.05))

                Section {
                    NavigationLink {
                        MonthlyBudgetGoalView(amount: $settings.manualMonthlyBudget)
                    } label: {
                        HStack {
                            Text("Monthly budget").foregroundStyle(.white)
                            Spacer()
                            Text(monthlyBudgetLabel).foregroundStyle(.white.opacity(0.4))
                        }
                    }

                    NavigationLink {
                        CycleStartDayView(startDay: $settings.cycleStartDay)
                    } label: {
                        HStack {
                            Text("Starting on").foregroundStyle(.white)
                            Spacer()
                            Text(startDayLabel).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                } header: {
                    Text("Settings")
                }
                .listRowBackground(Color.white.opacity(0.05))

                Section {
                    Toggle("Include all transactions", isOn: $settings.includeUnplannedAsOtherExpenses)
                        .tint(.emerald)
                } footer: {
                    Text("Include transactions from unplanned categories as “Other Expenses.”")
                        .foregroundStyle(.white.opacity(0.4))
                }
                .listRowBackground(Color.white.opacity(0.05))

                Section {
                    Toggle("Include savings transfers", isOn: $settings.includeSavingsTransfers)
                        .tint(.emerald)
                } footer: {
                    Text("Include transfers to savings wallets.")
                        .foregroundStyle(.white.opacity(0.4))
                }
                .listRowBackground(Color.white.opacity(0.05))

                Section {
                    Toggle("Include debt transfers", isOn: $settings.includeDebtTransfers)
                        .tint(.emerald)
                } footer: {
                    Text("Include transfers to debt wallets.")
                        .foregroundStyle(.white.opacity(0.4))
                }
                .listRowBackground(Color.white.opacity(0.05))

                Section {
                    HStack {
                        Image(systemName: "person.2.fill")
                            .foregroundStyle(.white.opacity(0.3))
                        Text("Members").foregroundStyle(.white.opacity(0.4))
                        Spacer()
                        Text("Coming soon")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.3))
                    }
                } header: {
                    Text("Members")
                } footer: {
                    Text("Shared budgets aren't available yet — Clarity is currently single-user.")
                        .foregroundStyle(.white.opacity(0.4))
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Editing Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }
}

private struct IconPickerRow: View {
    @Binding var selection: BudgetIcon

    var body: some View {
        HStack(spacing: 12) {
            ForEach(BudgetIcon.allCases) { icon in
                Button {
                    selection = icon
                } label: {
                    Image(systemName: icon.rawValue)
                        .font(.title3)
                        .foregroundStyle(selection == icon ? .white : .white.opacity(0.4))
                        .frame(width: 44, height: 44)
                        .background(
                            selection == icon
                                ? AnyShapeStyle(LinearGradient.emeraldSky)
                                : AnyShapeStyle(Color.white.opacity(0.08)),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(icon.accessibilityName)
                .accessibilityAddTraits(selection == icon ? [.isSelected] : [])
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MonthlyBudgetGoalView: View {
    @Binding var amount: Decimal
    @State private var text = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(Locale.current.currencySymbol ?? "$")
                        .foregroundStyle(.white.opacity(0.4))
                    TextField("0", text: $text)
                        .keyboardType(.decimalPad)
                        .foregroundStyle(.white)
                }
            } footer: {
                Text("Used as the “Available to Spend” ceiling in Remaining when set. Leave blank to use this period's income instead.")
                    .foregroundStyle(.white.opacity(0.4))
            }
            .listRowBackground(Color.white.opacity(0.05))
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Monthly Budget")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { text = amount.editableText() }
        .onChange(of: text) { _, newValue in
            let filtered = newValue.sanitizedDecimalInput()
            if filtered != newValue {
                text = filtered
                return
            }
            amount = Decimal(decimalInput: filtered) ?? 0
        }
    }
}

private struct CycleStartDayView: View {
    @Binding var startDay: Int

    var body: some View {
        Form {
            Section {
                Picker("Starting Day", selection: $startDay) {
                    Text("First day of the month").tag(1)
                    ForEach(2...28, id: \.self) { day in
                        Text("Day \(day)").tag(day)
                    }
                }
                .pickerStyle(.inline)
                .tint(.emerald)
                .labelsHidden()
            } footer: {
                Text("Changes which transactions count toward this period in Remaining. Category limits in Plan still follow the calendar month.")
                    .foregroundStyle(.white.opacity(0.4))
            }
            .listRowBackground(Color.white.opacity(0.05))
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Starting Day")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    BudgetSettingsView()
}
