import SwiftUI

struct SetPINView: View {
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .enter
    @State private var firstPIN = ""
    @State private var pin = ""
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private enum Step {
        case enter
        case confirm

        var prompt: String {
            switch self {
            case .enter: "Enter a 4-digit PIN"
            case .confirm: "Confirm your PIN"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "lock.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(LinearGradient.emeraldSky)

                Text(step.prompt)
                    .font(.headline)
                    .foregroundStyle(.white)

                SecureField("····", text: $pin)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 160)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .focused($focused)
                    .onChange(of: pin) { _, newValue in
                        let filtered = String(newValue.filter(\.isNumber).prefix(4))
                        if filtered != newValue { pin = filtered }
                        if pin.count == 4 { handleComplete() }
                    }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Color.expenseRed)
                }

                Spacer()
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Color.appBackground.ignoresSafeArea())
            .foregroundStyle(.white)
            .navigationTitle("Set PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
        .preferredColorScheme(.dark)
    }

    private func handleComplete() {
        switch step {
        case .enter:
            firstPIN = pin
            pin = ""
            step = .confirm
        case .confirm:
            if pin == firstPIN {
                AppLockService.setPIN(pin)
                onComplete()
                dismiss()
            } else {
                errorMessage = "PINs didn't match — try again."
                firstPIN = ""
                pin = ""
                step = .enter
            }
        }
    }
}
