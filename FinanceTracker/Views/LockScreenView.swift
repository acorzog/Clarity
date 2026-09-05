import SwiftUI

struct LockScreenView: View {
    let onUnlock: () -> Void

    @AppStorage("appLockUseBiometrics") private var useBiometrics = true
    @State private var pin = ""
    @State private var errorMessage: String?
    @State private var isAuthenticating = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Clarity Locked")
                .font(.title3.bold())
                .foregroundStyle(.white)

            if useBiometrics && AppLockService.biometricsAvailable {
                Button(action: authenticateWithBiometrics) {
                    Label(
                        AppLockService.biometricType == .faceID ? "Unlock with Face ID" : "Unlock with Touch ID",
                        systemImage: AppLockService.biometricType == .faceID ? "faceid" : "touchid"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(LinearGradient.emeraldSky, in: Capsule())
                }
                .disabled(isAuthenticating)
            }

            VStack(spacing: 12) {
                Text("Or enter your PIN")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))

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
                        if pin.count == 4 { submitPIN() }
                    }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Color.expenseRed)
                }
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground.ignoresSafeArea())
        .onAppear(perform: authenticateWithBiometrics)
    }

    private func authenticateWithBiometrics() {
        guard useBiometrics, AppLockService.biometricsAvailable, !isAuthenticating else { return }
        isAuthenticating = true
        Task {
            let success = await AppLockService.authenticateWithBiometrics()
            isAuthenticating = false
            if success {
                onUnlock()
            }
        }
    }

    private func submitPIN() {
        if AppLockService.verifyPIN(pin) {
            onUnlock()
        } else {
            errorMessage = "Incorrect PIN"
            pin = ""
        }
    }
}
