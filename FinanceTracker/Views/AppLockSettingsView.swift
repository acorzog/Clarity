import SwiftUI

struct AppLockSettingsView: View {
    @AppStorage("appLockEnabled") private var lockEnabled = false
    @AppStorage("appLockUseBiometrics") private var useBiometrics = true
    @State private var isPINSet = AppLockService.isPINSet
    @State private var showingSetPIN = false
    @State private var showingChangePIN = false
    @State private var showingDisableConfirmation = false

    var body: some View {
        Form {
            Section {
                Toggle("Require Passcode", isOn: Binding(
                    get: { lockEnabled },
                    set: { newValue in
                        if newValue {
                            if isPINSet {
                                lockEnabled = true
                            } else {
                                // Must set a PIN before the lock can be turned on.
                                showingSetPIN = true
                            }
                        } else {
                            // Clearing the PIN is a real, silent-feeling side effect of what looks
                            // like a plain switch — confirm before committing it, matching the
                            // app's explicit-destructive-action-confirms convention.
                            showingDisableConfirmation = true
                        }
                    }
                ))
                .tint(.emerald)
            } footer: {
                Text("Require Face ID or a PIN to open Clarity.")
                    .foregroundStyle(.white.opacity(0.4))
            }
            .listRowBackground(Color.white.opacity(0.05))

            if lockEnabled {
                if AppLockService.biometricsAvailable {
                    Section {
                        Toggle(
                            AppLockService.biometricType == .faceID ? "Use Face ID" : "Use Touch ID",
                            isOn: $useBiometrics
                        )
                        .tint(.emerald)
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                }

                Section {
                    Button("Change PIN") {
                        showingChangePIN = true
                    }
                    .buttonStyle(.claritySecondary)
                    .listRowInsets(EdgeInsets())
                }
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("App Lock")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingSetPIN) {
            SetPINView {
                isPINSet = true
                lockEnabled = true
            }
        }
        .sheet(isPresented: $showingChangePIN) {
            SetPINView {
                isPINSet = true
            }
        }
        .alert("Turn Off Passcode?", isPresented: $showingDisableConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Turn Off", role: .destructive) {
                lockEnabled = false
                AppLockService.clearPIN()
                isPINSet = false
            }
        } message: {
            Text("This will remove your current PIN. You'll need to set a new one to turn Require Passcode back on.")
        }
    }
}
