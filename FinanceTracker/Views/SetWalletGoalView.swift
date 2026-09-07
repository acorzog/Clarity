import SwiftUI

struct SetWalletGoalView: View {
    let wallet: Wallet

    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @FocusState private var amountFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                HStack(spacing: 4) {
                    TextField("0", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .focused($amountFieldFocused)
                        .onChange(of: amountText) { _, newValue in
                            let filtered = newValue.sanitizedDecimalInput()
                            if filtered != newValue { amountText = filtered }
                        }
                    Text(Locale.current.currencySymbol ?? "$")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
                .padding(.top, 32)

                Button {
                    let trimmed = amountText.trimmingCharacters(in: .whitespaces)
                    wallet.goalAmount = trimmed.isEmpty ? nil : Decimal(decimalInput: trimmed)
                    dismiss()
                } label: {
                    Text("Save")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal)

                Spacer()
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Set Goal Amount")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if let goal = wallet.goalAmount, goal > 0 {
                amountText = goal.editableText()
            }
            amountFieldFocused = true
        }
    }
}
